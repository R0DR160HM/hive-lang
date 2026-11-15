package hive

import (
	"strconv"
	"testing"
)

// One connection, so an in-memory database is the same one for every statement.
func memory(t *testing.T) SqlSqlConnection {
	opened := SqlPool(SqlDatabaseDriver{Name: "sqlite"}, ":memory:", 1, 1)
	if opened.IsError() {
		t.Fatalf("open: %v", opened.Err())
	}
	t.Cleanup(func() { SqlClose(opened.Ok()) })
	return opened.Ok()
}

func ran(t *testing.T, conn SqlSqlConnection, text string, args ...any) int {
	t.Helper()
	got := SqlExec(conn, SqlFragment{Text: text, Args: args})
	if got.IsError() {
		t.Fatalf("%s: %v", text, got.Err())
	}
	return got.Ok()
}

func names(t *testing.T, conn SqlSqlConnection) []string {
	t.Helper()
	got := SqlRows(conn, SqlFragment{Text: "SELECT name FROM bees ORDER BY name"}, nil,
		func(cells []string) (string, error) { return cells[0], nil })
	if got.IsError() {
		t.Fatalf("select: %v", got.Err())
	}
	return got.Ok()
}

// **A statement is prepared the first time its text is run, and that one is run
// from then on.** Parsing it again was most of what a short statement cost, and
// a query declaration writes the same text on every call.
func TestAStatementIsPreparedOnceAndKept(t *testing.T) {
	conn := memory(t)
	ran(t, conn, "CREATE TABLE bees (name TEXT)")
	for _, name := range []string{"ada", "bea", "cy"} {
		if ran(t, conn, "INSERT INTO bees (name) VALUES (?)", name) != 1 {
			t.Fatalf("inserting %s touched no row", name)
		}
	}
	if got := names(t, conn); len(got) != 3 || got[0] != "ada" || got[2] != "cy" {
		t.Fatalf("the rows are %v", got)
	}
	names(t, conn)

	// The table, the insert and the select: three texts, however often each ran.
	if kept := conn.kept.count.Load(); kept != 3 {
		t.Fatalf("%d statements are kept, where 3 texts were run", kept)
	}
}

// **A script of several statements runs whole**, prepared or not: the schema a
// program opens with is one.
func TestAScriptRunsEveryStatementInIt(t *testing.T) {
	conn := memory(t)
	script := "BEGIN; CREATE TABLE bees (name TEXT); INSERT INTO bees (name) VALUES ('ada'); COMMIT;"
	ran(t, conn, script)
	if got := names(t, conn); len(got) != 1 || got[0] != "ada" {
		t.Fatalf("after the script the rows are %v", got)
	}
}

// **Past the limit a new text runs unprepared**, as every one used to, so a
// program that writes texts without end is slower rather than larger.
func TestPastTheLimitAStatementStillRuns(t *testing.T) {
	conn := memory(t)
	ran(t, conn, "CREATE TABLE bees (name TEXT)")
	conn.kept.count.Store(sqlPreparedLimit)
	for i := 0; i < 3; i++ {
		ran(t, conn, "INSERT INTO bees (name) VALUES ('bee "+strconv.Itoa(i)+"')")
	}
	if got := names(t, conn); len(got) != 3 {
		t.Fatalf("the rows are %v", got)
	}
	if kept := conn.kept.count.Load(); kept != sqlPreparedLimit {
		t.Fatalf("%d statements are kept, past a limit of %d", kept, sqlPreparedLimit)
	}
}

// **A statement that is wrong fails as a Statement**, with what the database
// said of it, and is not kept.
func TestAWrongStatementFailsWhereItAlwaysDid(t *testing.T) {
	conn := memory(t)
	got := SqlExec(conn, SqlFragment{Text: "INSERT INTO nowhere VALUES (1)"})
	if !got.IsError() || got.Err().Reason != "Statement" {
		t.Fatalf("a statement against no table answered %v", got)
	}
	if kept := conn.kept.count.Load(); kept != 0 {
		t.Fatalf("%d statements are kept, where the only one was refused", kept)
	}
}
