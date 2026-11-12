// The Go for `hive.sql`. The one module that carries a dependency: the drivers.
// SQLite is modernc's pure Go, so a local database needs nothing installed;
// PostgreSQL is lib/pq. A program that never opens a connection carries neither.
package hive

import (
	"database/sql"
	"strconv"
	"strings"

	_ "github.com/lib/pq"
	_ "modernc.org/sqlite"
)

// SqlDatabaseDriver selects the SQL driver a connection uses. Build it with
// hive.sql.SqlDatabaseDriver.SQLite(), .PostgreSQL() or .Other(name).
type SqlDatabaseDriver struct {
	Name string
}

// SqlSqlError describes a failed database operation. Reason names a variant of
// hive.sql.SqlError — "Connection", "Statement", "Shape" or "Convert" — so a
// caller can tell a database that is down from a value that did not fit.
type SqlSqlError struct {
	Reason  string
	Message string
}

func (e SqlSqlError) Error() string {
	return "hive: sql error (" + e.Reason + "): " + e.Message
}

// SqlFragment is a piece of SQL text together with the values its placeholders
// bind to. A query declaration builds one; nothing a caller supplies ever
// reaches Text, which is what makes the text mean only what the query says.
type SqlFragment struct {
	Text string
	Args []any
}

// SqlJoin combines the fragments a where block collected. No fragments means
// empty text, so the clause disappears rather than leaving a dangling
// connective; more than one is parenthesised when asked.
func SqlJoin(parts []SqlFragment, sep string, paren bool) SqlFragment {
	if len(parts) == 0 {
		return SqlFragment{}
	}
	texts := make([]string, len(parts))
	args := []any{}
	for i, p := range parts {
		texts[i] = p.Text
		args = append(args, p.Args...)
	}
	text := strings.Join(texts, sep)
	if paren && len(parts) > 1 {
		text = "(" + text + ")"
	}
	return SqlFragment{Text: text, Args: args}
}

// Queries are built with ? placeholders; PostgreSQL wants $1, $2, ... instead.
// Rewriting here rather than at build time is what lets one query declaration
// serve every driver.
func sqlPlaceholders(conn SqlSqlConnection, text string) string {
	if conn.driver != "postgres" {
		return text
	}
	var b strings.Builder
	n := 0
	for _, r := range text {
		if r == '?' {
			n++
			b.WriteString("$" + strconv.Itoa(n))
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// SqlExec runs a statement that returns no rows and reports how many it
// affected — which is how a delete says whether it matched anything.
func SqlExec(conn SqlSqlConnection, stmt SqlFragment) Result[int, SqlSqlError] {
	if conn.db == nil {
		return Err[int, SqlSqlError](SqlSqlError{Reason: "Connection", Message: "connection is not open"})
	}
	res, err := conn.db.Exec(sqlPlaceholders(conn, stmt.Text), stmt.Args...)
	if err != nil {
		return Err[int, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	n, err := res.RowsAffected()
	if err != nil {

		// A driver that cannot count is not a failure of the statement itself.
		return Ok[int, SqlSqlError](0)
	}
	return Ok[int, SqlSqlError](int(n))
}

// SqlRows runs a query and maps every row through row, which the compiler
// derived from the type the query declared. fields are that type's fields in
// the order row reads them, and each is found among the columns by name, so
// the order of a SELECT is the query's own business. A single column has no
// name to be found by, and comes with nil. A cell that does not fit its field
// stops the read and comes back as an error, rather than becoming a zero.
func SqlRows[T any](
	conn SqlSqlConnection,
	stmt SqlFragment,
	fields []string,
	row func([]string) (T, error),
) Result[[]T, SqlSqlError] {
	out := []T{}
	if conn.db == nil {
		return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Connection", Message: "connection is not open"})
	}
	rows, err := conn.db.Query(sqlPlaceholders(conn, stmt.Text), stmt.Args...)
	if err != nil {
		return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	at, why := sqlColumnsFor(fields, cols)
	if why != "" {
		return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Shape", Message: why})
	}
	for rows.Next() {
		cells := make([]sql.NullString, len(cols))
		ptrs := make([]any, len(cols))
		for i := range cells {
			ptrs[i] = &cells[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
		}
		flat := make([]string, len(at))
		for i, c := range at {
			if cells[c].Valid {
				flat[i] = cells[c].String
			}
		}
		v, err := row(flat)
		if err != nil {
			if se, ok := err.(SqlSqlError); ok {
				return Err[[]T, SqlSqlError](se)
			}
			return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Convert", Message: err.Error()})
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return Err[[]T, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	return Ok[[]T, SqlSqlError](out)
}

// sqlColumnsFor finds the column that fills each field, or says why it could
// not. Every column has to fill a field and every field has to be filled,
// exactly once; anything else is a query whose result does not have its rows'
// shape. That is decided from the column names alone, before a row is read,
// so an empty table is no reason for a wrong query to pass.
//
// A name matches in any case. PostgreSQL folds a name nobody quoted to lower
// case and SQLite keeps it as written, so `AS userId` comes back as `userid`
// from one and as `userId` from the other, and one declaration has to read
// both. A column spelt exactly like a field is that field's before it is
// another's that differs only in case.
func sqlColumnsFor(fields []string, cols []string) ([]int, string) {
	if fields == nil {
		if len(cols) != 1 {
			return nil, "expected 1 column but the query answered with " + strconv.Itoa(len(cols))
		}
		return []int{0}, ""
	}
	at := make([]int, len(fields))
	for i := range at {
		at[i] = -1
	}
	for c, name := range cols {
		f := sqlFieldNamed(fields, name)
		if f < 0 {
			return nil, "column " + name + " fills no field of the row (" + strings.Join(fields, ", ") +
				"): name it after the field it fills, with AS"
		}
		if at[f] >= 0 {
			return nil, "columns " + cols[at[f]] + " and " + name + " both fill the field " + fields[f]
		}
		at[f] = c
	}
	for f, c := range at {
		if c < 0 {
			return nil, "no column fills the field " + fields[f] + ": the query answered with " +
				strings.Join(cols, ", ")
		}
	}
	return at, ""
}

func sqlFieldNamed(fields []string, name string) int {
	for i, f := range fields {
		if f == name {
			return i
		}
	}
	for i, f := range fields {
		if strings.EqualFold(f, name) {
			return i
		}
	}
	return -1
}

func sqlCellError(column, value, want string) error {
	return SqlSqlError{
		Reason:  "Convert",
		Message: "column " + column + " held " + strconv.Quote(value) + ", which is not " + want,
	}
}

// The cell conversions a generated row mapper uses. A Str needs no converting,
// but it keeps the same shape as the others so the generated code is uniform.
func SqlCellStr(cell string, column string) (string, error) {
	_ = column
	return cell, nil
}

func SqlCellInt(cell string, column string) (int, error) {
	v, err := strconv.Atoi(strings.TrimSpace(cell))
	if err != nil {
		return 0, sqlCellError(column, cell, "an Int")
	}
	return v, nil
}

func SqlCellSized[T Whole](cell string, column string, signed bool, bits int, name string) (T, error) {
	text := strings.TrimSpace(cell)
	if signed {
		if n, err := strconv.ParseInt(text, 10, bits); err == nil {
			return T(n), nil
		}
	} else if n, err := strconv.ParseUint(text, 10, bits); err == nil {
		return T(n), nil
	}
	return 0, sqlCellError(column, cell, "a "+name)
}

func SqlCellFloat32(cell string, column string) (float32, error) {
	v, err := strconv.ParseFloat(strings.TrimSpace(cell), 32)
	if err != nil {
		return 0, sqlCellError(column, cell, "a Float32")
	}
	return float32(v), nil
}

func SqlCellFloat(cell string, column string) (float64, error) {
	v, err := strconv.ParseFloat(strings.TrimSpace(cell), 64)
	if err != nil {
		return 0, sqlCellError(column, cell, "a Float")
	}
	return v, nil
}

// Booleans have no single spelling across databases: SQLite stores 0/1,
// PostgreSQL answers t/f, and some schemas keep the word. All of them are
// accepted; anything else is an error rather than a silent false.
func SqlCellBool(cell string, column string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(cell)) {
	case "1", "t", "true", "y", "yes":
		return true, nil
	case "0", "f", "false", "n", "no":
		return false, nil
	}
	return false, sqlCellError(column, cell, "a Bool")
}

// SqlSqlConnection is a handle to an open database. The underlying *sql.DB is a
// connection pool, so a single SqlSqlConnection is safe for concurrent use.
type SqlSqlConnection struct {
	db *sql.DB

	// Which driver this connection speaks, so placeholders can be written in the
	// dialect it expects.
	driver string
}

// sqlDriverName maps a SqlDatabaseDriver onto the registered database/sql driver.
func sqlDriverName(d SqlDatabaseDriver) string {
	switch d.Name {
	case "sqlite":
		return "sqlite"
	case "postgres":
		return "postgres"
	default:
		return d.Name
	}
}

// SqlConnect opens a pooled connection to the database at connString and
// verifies it with a ping.
func SqlConnect(driver SqlDatabaseDriver, connString string) Result[SqlSqlConnection, SqlSqlError] {
	db, err := sql.Open(sqlDriverName(driver), connString)
	if err != nil {
		return Err[SqlSqlConnection, SqlSqlError](SqlSqlError{Reason: "Connection", Message: err.Error()})
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return Err[SqlSqlConnection, SqlSqlError](SqlSqlError{Reason: "Connection", Message: err.Error()})
	}
	return Ok[SqlSqlConnection, SqlSqlError](SqlSqlConnection{db: db, driver: sqlDriverName(driver)})
}

// SqlPool is SqlConnect with explicit pool limits (max open and idle
// connections).
func SqlPool(driver SqlDatabaseDriver, connString string, maxOpen int, maxIdle int) Result[SqlSqlConnection, SqlSqlError] {
	res := SqlConnect(driver, connString)
	if res.IsError() {
		return res
	}
	conn := res.Ok()
	conn.db.SetMaxOpenConns(maxOpen)
	conn.db.SetMaxIdleConns(maxIdle)
	return Ok[SqlSqlConnection, SqlSqlError](conn)
}

// SqlClose releases a connection pool. It is safe to call more than once.
func SqlClose(conn SqlSqlConnection) {
	if conn.db != nil {
		conn.db.Close()
	}
}

// SqlQuery runs any SQL statement and returns its result as a Table. A query
// that returns rows yields a header row of column names followed by one row
// per result row; a statement that returns no rows yields an empty table.
func SqlQuery(conn SqlSqlConnection, query string) Result[Table, SqlSqlError] {
	if conn.db == nil {
		return Err[Table, SqlSqlError](SqlSqlError{Reason: "Connection", Message: "connection is not open"})
	}
	return sqlTable(conn.db.Query(query))
}

func SqlTable(conn SqlSqlConnection, stmt SqlFragment) Result[Table, SqlSqlError] {
	if conn.db == nil {
		return Err[Table, SqlSqlError](SqlSqlError{Reason: "Connection", Message: "connection is not open"})
	}
	return sqlTable(conn.db.Query(sqlPlaceholders(conn, stmt.Text), stmt.Args...))
}

func sqlTable(rows *sql.Rows, err error) Result[Table, SqlSqlError] {
	if err != nil {
		return Err[Table, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Err[Table, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	if len(cols) == 0 {
		return Ok[Table, SqlSqlError](Table{})
	}
	table := Table{cols}
	for rows.Next() {
		cells := make([]sql.NullString, len(cols))
		ptrs := make([]any, len(cols))
		for i := range cells {
			ptrs[i] = &cells[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Err[Table, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
		}
		row := make([]string, len(cols))
		for i, c := range cells {
			if c.Valid {
				row[i] = c.String
			}
		}
		table = append(table, row)
	}
	if err := rows.Err(); err != nil {
		return Err[Table, SqlSqlError](SqlSqlError{Reason: "Statement", Message: err.Error()})
	}
	return Ok[Table, SqlSqlError](table)
}
