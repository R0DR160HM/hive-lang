// The Go for `hive.file.xlsx(<path>)` and `hive.file.ods(<path>)`: a workbook is a
// zip archive of XML, and both formats are read out of one without a dependency.
// Both answer with one Table per sheet, in document order.
package hive

import (
	"archive/zip"
	"encoding/xml"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// The zip container both formats share
// ---------------------------------------------------------------------------
func openSheets(path string) (*zip.ReadCloser, *FileTableError) {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return nil, &FileTableError{Path: path, Message: err.Error()}
	}
	return archive, nil
}

// sheetsMember reads one entry out of the archive. A nil result with no error
// means the archive simply has no such entry, which several of them are allowed
// to be (a workbook with no strings has no sharedStrings.xml).
func sheetsMember(archive *zip.ReadCloser, name string) ([]byte, error) {
	for _, entry := range archive.File {
		if entry.Name == name {
			reader, err := entry.Open()
			if err != nil {
				return nil, err
			}
			defer reader.Close()
			return io.ReadAll(reader)
		}
	}
	return nil, nil
}

// padTable squares a sheet off into a Table. Spreadsheets store no trailing
// blanks, so rows arrive at whatever length their last filled cell reached,
// while a Table's readers expect a rectangle. Every row is copied, so repeated
// rows never share storage.
//
// ---------------------------------------------------------------------------
// xlsx
// ---------------------------------------------------------------------------
func padTable(rows [][]string) Table {
	width := 0
	for _, row := range rows {
		if len(row) > width {
			width = len(row)
		}
	}
	table := make(Table, 0, len(rows))
	for _, row := range rows {
		padded := make([]string, width)
		copy(padded, row)
		table = append(table, padded)
	}
	return table
}

// Element and attribute names are matched on their local part, so the file's
// choice of namespace prefixes does not matter.
type xlsxWorkbook struct {
	Sheets []struct {
		Name string `xml:"name,attr"`
		ID   string `xml:"id,attr"`
	} `xml:"sheets>sheet"`
}

type xlsxRels struct {
	Relationships []struct {
		ID     string `xml:"Id,attr"`
		Target string `xml:"Target,attr"`
	} `xml:"Relationship"`
}

// xlsxText is a string that may be split into styled runs; the runs matter only
// in that their text has to be stitched back together.
type xlsxText struct {
	Plain string `xml:"t"`
	Runs  []struct {
		Text string `xml:"t"`
	} `xml:"r"`
}

func (t xlsxText) String() string {
	if len(t.Runs) == 0 {
		return t.Plain
	}
	var out strings.Builder
	for _, run := range t.Runs {
		out.WriteString(run.Text)
	}
	return out.String()
}

type xlsxSharedStrings struct {
	Items []xlsxText `xml:"si"`
}

type xlsxStyles struct {
	Formats []struct {
		ID   string `xml:"numFmtId,attr"`
		Code string `xml:"formatCode,attr"`
	} `xml:"numFmts>numFmt"`
	CellFormats []struct {
		FormatID string `xml:"numFmtId,attr"`
	} `xml:"cellXfs>xf"`
}

type xlsxCell struct {
	Ref    string   `xml:"r,attr"`
	Type   string   `xml:"t,attr"`
	Style  string   `xml:"s,attr"`
	Value  string   `xml:"v"`
	Inline xlsxText `xml:"is"`
}

type xlsxRow struct {
	Cells []xlsxCell `xml:"c"`
}

type xlsxWorksheet struct {
	Rows []xlsxRow `xml:"sheetData>row"`
}

// What a cell's number format renders: a calendar date, a clock time, both, or
// neither. This is the only thing that distinguishes a date from the plain
// number xlsx actually stores for it.
type xlsxFormatKind struct {
	date  bool
	clock bool
}

// ReadXlsx reads every sheet of an .xlsx workbook, in workbook order, and hands
// back one Table per sheet. Backs hive.file.xlsx.
//
// Which part holds each sheet. Absent or unreadable relationships fall back
// to the conventional sheetN.xml numbering below.
func ReadXlsx(path string) Result[[]Table, FileTableError] {
	fail := func(message string) Result[[]Table, FileTableError] {
		return Err[[]Table, FileTableError](FileTableError{Path: path, Message: message})
	}
	archive, openErr := openSheets(path)
	if openErr != nil {
		return Err[[]Table, FileTableError](*openErr)
	}
	defer archive.Close()

	workbookXML, err := sheetsMember(archive, "xl/workbook.xml")
	if err != nil {
		return fail(err.Error())
	}
	if workbookXML == nil {
		return fail("this is not an xlsx workbook: xl/workbook.xml is missing")
	}
	var workbook xlsxWorkbook
	if err := xml.Unmarshal(workbookXML, &workbook); err != nil {
		return fail("xl/workbook.xml is malformed: " + err.Error())
	}

	targets := map[string]string{}
	if relsXML, err := sheetsMember(archive, "xl/_rels/workbook.xml.rels"); err == nil && relsXML != nil {
		var rels xlsxRels
		if xml.Unmarshal(relsXML, &rels) == nil {
			for _, rel := range rels.Relationships {
				targets[rel.ID] = xlsxPartPath(rel.Target)
			}
		}
	}

	var shared []xlsxText
	if sharedXML, err := sheetsMember(archive, "xl/sharedStrings.xml"); err == nil && sharedXML != nil {
		var strings xlsxSharedStrings
		if xml.Unmarshal(sharedXML, &strings) == nil {
			shared = strings.Items
		}
	}

	var kinds []xlsxFormatKind
	if stylesXML, err := sheetsMember(archive, "xl/styles.xml"); err == nil && stylesXML != nil {
		var styles xlsxStyles
		if xml.Unmarshal(stylesXML, &styles) == nil {
			kinds = xlsxFormatKinds(styles)
		}
	}

	tables := []Table{}
	for i, sheet := range workbook.Sheets {
		part, ok := targets[sheet.ID]
		if !ok {
			part = "xl/worksheets/sheet" + strconv.Itoa(i+1) + ".xml"
		}
		sheetXML, err := sheetsMember(archive, part)
		if err != nil {
			return fail(err.Error())
		}

		// A sheet whose part is missing still holds its place in the workbook.
		if sheetXML == nil {
			tables = append(tables, Table{})
			continue
		}
		var worksheet xlsxWorksheet
		if err := xml.Unmarshal(sheetXML, &worksheet); err != nil {
			return fail(part + " is malformed: " + err.Error())
		}
		rows := [][]string{}
		for _, row := range worksheet.Rows {
			rows = append(rows, xlsxRowCells(row, shared, kinds))
		}
		tables = append(tables, padTable(rows))
	}
	return Ok[[]Table, FileTableError](tables)
}

// A relationship target is relative to xl/ unless it is rooted at the archive.
func xlsxPartPath(target string) string {
	if strings.HasPrefix(target, "/") {
		return strings.TrimPrefix(target, "/")
	}
	return "xl/" + target
}

// xlsxRowCells places a row's cells at the columns their references name, since
// a row stores only the cells that hold something.
func xlsxRowCells(
	row xlsxRow,
	shared []xlsxText,
	kinds []xlsxFormatKind,
) []string {
	cells := []string{}
	for _, cell := range row.Cells {
		at := xlsxColumn(cell.Ref)
		if at < 0 {
			at = len(cells)
		}
		for len(cells) <= at {
			cells = append(cells, "")
		}
		cells[at] = xlsxCellText(cell, shared, kinds)
	}
	return cells
}

// The column a cell reference names: "A1" -> 0, "AB7" -> 27. A reference with no
// leading letters yields -1, meaning "wherever we had reached".
//
// An index into the workbook's shared string table.
//
// A formula's cached string result, an error text, or an ISO date.
func xlsxColumn(ref string) int {
	column := 0
	for i := 0; i < len(ref); i++ {
		letter := ref[i]
		if letter < 'A' || letter > 'Z' {
			break
		}
		column = column*26 + int(letter-'A'+1)
	}
	return column - 1
}

func xlsxCellText(
	cell xlsxCell,
	shared []xlsxText,
	kinds []xlsxFormatKind,
) string {
	switch cell.Type {
	case "s":
		if at, err := strconv.Atoi(cell.Value); err == nil && at >= 0 && at < len(shared) {
			return shared[at].String()
		}
		return ""
	case "inlineStr":
		return cell.Inline.String()
	case "b":
		if cell.Value == "1" {
			return "true"
		}
		return "false"
	case "str", "e", "d":
		return cell.Value
	}

	// A number, which is also how a date is stored: only the cell's format says
	// which of the two it is meant to be.
	if at, err := strconv.Atoi(cell.Style); err == nil && at >= 0 && at < len(kinds) {
		if text, ok := xlsxDateText(cell.Value, kinds[at]); ok {
			return text
		}
	}
	return cell.Value
}

// xlsxFormatKinds resolves every cell format the workbook defines down to what
// it renders, so a cell's style index answers the question directly.
func xlsxFormatKinds(styles xlsxStyles) []xlsxFormatKind {
	codes := map[string]string{}
	for _, format := range styles.Formats {
		codes[format.ID] = format.Code
	}
	kinds := make([]xlsxFormatKind, 0, len(styles.CellFormats))
	for _, format := range styles.CellFormats {
		if code, ok := codes[format.FormatID]; ok {
			kinds = append(kinds, xlsxCodeKind(code))
			continue
		}
		kinds = append(kinds, xlsxBuiltinKind(format.FormatID))
	}
	return kinds
}

// The date and time formats every xlsx carries without defining them.
func xlsxBuiltinKind(id string) xlsxFormatKind {
	switch id {
	case "14", "15", "16", "17":
		return xlsxFormatKind{date: true}
	case "18", "19", "20", "21", "45", "46", "47":
		return xlsxFormatKind{clock: true}
	case "22":
		return xlsxFormatKind{date: true, clock: true}
	}
	return xlsxFormatKind{}
}

// A custom format renders a date when it positions any date or time field.
// Quoted literals, [...] sections and backslash escapes are dropped first: each
// can hold letters that would otherwise read as fields.
func xlsxCodeKind(code string) xlsxFormatKind {
	var fields strings.Builder
	quoted := false
	bracketed := false
	for i := 0; i < len(code); i++ {
		letter := code[i]
		switch {
		case letter == '"':
			quoted = !quoted
		case letter == '[':
			bracketed = true
		case letter == ']':
			bracketed = false
		case quoted || bracketed:
		case letter == '\\':
			i++
		default:
			fields.WriteByte(letter)
		}
	}
	bare := strings.ToLower(fields.String())
	kind := xlsxFormatKind{}
	if strings.ContainsAny(bare, "yd") {
		kind.date = true
	}
	if strings.ContainsAny(bare, "hs") {
		kind.clock = true
	}

	// m is minutes beside an hour and months everywhere else.
	if strings.Contains(bare, "m") && !kind.date && !kind.clock {
		kind.date = true
	}
	return kind
}

// xlsxEpoch is the day before serial 1, so serial 1 lands on 1900-01-01.
var xlsxEpoch = time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)

// xlsxDateText renders a stored day count as a date, a time, or both, according
// to what the cell's format asks for. It reports false when the format wants
// neither, which is how an ordinary number passes through untouched.
func xlsxDateText(raw string, kind xlsxFormatKind) (string, bool) {
	if !kind.date && !kind.clock {
		return "", false
	}
	serial, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return "", false
	}
	days := int(serial)
	moment := xlsxEpoch.AddDate(0, 0, days)

	// Excel counts a 1900-02-29 that never happened, so every serial before it
	// is a day behind.
	if days < 60 {
		moment = moment.AddDate(0, 0, 1)
	}
	seconds := int((serial-float64(days))*86400 + 0.5)
	moment = moment.Add(time.Duration(seconds) * time.Second)
	switch {
	case kind.date && kind.clock:
		return moment.Format("2006-01-02 15:04:05"), true
	case kind.date:
		return moment.Format("2006-01-02"), true
	}
	return moment.Format("15:04:05"), true
}

// ---------------------------------------------------------------------------
// ods
// ---------------------------------------------------------------------------
type odsContent struct {
	Tables []odsTable `xml:"body>spreadsheet>table"`
}

type odsTable struct {
	Name string   `xml:"name,attr"`
	Rows []odsRow `xml:"table-row"`
}

type odsRow struct {
	Repeated string    `xml:"number-rows-repeated,attr"`
	Cells    []odsCell `xml:"table-cell"`
}

type odsCell struct {
	Repeated   string   `xml:"number-columns-repeated,attr"`
	ValueType  string   `xml:"value-type,attr"`
	Value      string   `xml:"value,attr"`
	DateValue  string   `xml:"date-value,attr"`
	TimeValue  string   `xml:"time-value,attr"`
	BoolValue  string   `xml:"boolean-value,attr"`
	Paragraphs []string `xml:"p"`
}

// A repeat count this large is the format padding a sheet out to its full width
// or height rather than real repeated data, so it is treated as one cell.
const odsMaxRepeat = 4096

// ReadOds reads every table of an OpenDocument spreadsheet, in document order,
// and hands back one Table per table. Backs hive.file.ods.
func ReadOds(path string) Result[[]Table, FileTableError] {
	fail := func(message string) Result[[]Table, FileTableError] {
		return Err[[]Table, FileTableError](FileTableError{Path: path, Message: message})
	}
	archive, openErr := openSheets(path)
	if openErr != nil {
		return Err[[]Table, FileTableError](*openErr)
	}
	defer archive.Close()

	contentXML, err := sheetsMember(archive, "content.xml")
	if err != nil {
		return fail(err.Error())
	}
	if contentXML == nil {
		return fail("this is not an ods spreadsheet: content.xml is missing")
	}
	var content odsContent
	if err := xml.Unmarshal(contentXML, &content); err != nil {
		return fail("content.xml is malformed: " + err.Error())
	}
	tables := []Table{}
	for _, table := range content.Tables {
		tables = append(tables, padTable(odsRows(table)))
	}
	return Ok[[]Table, FileTableError](tables)
}

// odsRows expands a table's repeat counts. Runs of empty rows are held back and
// only written out once something non-empty follows, so a sheet padded to a
// million rows still reads as the handful of rows it really holds.
func odsRows(table odsTable) [][]string {
	rows := [][]string{}
	blank := 0
	for _, row := range table.Rows {
		cells := odsRowCells(row)
		repeat := odsRepeat(row.Repeated)
		if len(cells) == 0 {
			blank += repeat
			continue
		}
		for ; blank > 0; blank-- {
			rows = append(rows, []string{})
		}
		for i := 0; i < repeat; i++ {
			rows = append(rows, cells)
		}
	}
	return rows
}

// The same holding-back applies across a row, where trailing blank cells are
// how the format pads out to the sheet's width.
func odsRowCells(row odsRow) []string {
	cells := []string{}
	blank := 0
	for _, cell := range row.Cells {
		repeat := odsRepeat(cell.Repeated)
		text := odsCellText(cell)
		if text == "" {
			blank += repeat
			continue
		}
		for ; blank > 0; blank-- {
			cells = append(cells, "")
		}
		for i := 0; i < repeat; i++ {
			cells = append(cells, text)
		}
	}
	return cells
}

func odsRepeat(value string) int {
	if value == "" {
		return 1
	}
	repeat, err := strconv.Atoi(value)
	if err != nil || repeat < 1 || repeat > odsMaxRepeat {
		return 1
	}
	return repeat
}

// An ods stores real dates and numbers alongside the text it displays, so unlike
// xlsx there is no serial arithmetic to undo here.
func odsCellText(cell odsCell) string {
	switch cell.ValueType {
	case "float", "percentage", "currency":
		return cell.Value
	case "boolean":
		return cell.BoolValue
	case "date":
		return odsDateText(cell.DateValue)
	case "time":
		return odsTimeText(cell.TimeValue)
	}
	return strings.Join(cell.Paragraphs, "\n")
}

// A midnight timestamp is a plain date; anything else keeps its time.
func odsDateText(value string) string {
	at := strings.IndexByte(value, 'T')
	if at < 0 {
		return value
	}
	clock := value[at+1:]
	if clock == "" || clock == "00:00:00" {
		return value[:at]
	}
	return value[:at] + " " + clock
}

// An ods time is an ISO-8601 duration, "PT14H30M00S".
func odsTimeText(value string) string {
	rest := strings.TrimPrefix(strings.TrimPrefix(value, "P"), "T")
	hours, minutes, seconds := 0, 0, 0
	digits := ""
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case 'H':
			hours, _ = strconv.Atoi(digits)
			digits = ""
		case 'M':
			minutes, _ = strconv.Atoi(digits)
			digits = ""
		case 'S':
			whole := digits
			if dot := strings.IndexByte(whole, '.'); dot >= 0 {
				whole = whole[:dot]
			}
			seconds, _ = strconv.Atoi(whole)
			digits = ""
		default:
			digits += string(rest[i])
		}
	}
	return fmt.Sprintf("%02d:%02d:%02d", hours, minutes, seconds)
}
