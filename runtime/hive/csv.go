package hive

import (
	"encoding/csv"
	"os"
	"strings"
)

// ReadCsv reads a UTF-8 separated-value file and hands its rows back as a
// Table. An empty separator leaves the comma encoding/csv starts with.
//
// Rows are read at the length they have: a ragged file is a table with ragged
// rows rather than an error about a file the program can perfectly well read.
func ReadCsv(path string, separator string) Result[Table, FileTableError] {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Err[Table, FileTableError](FileTableError{Path: path, Message: err.Error()})
	}
	reader := csv.NewReader(strings.NewReader(strings.TrimPrefix(string(raw), "\uFEFF")))
	reader.FieldsPerRecord = -1
	if len([]rune(separator)) > 1 {
		return Err[Table, FileTableError](FileTableError{Path: path, Message: "a separator is one character, and \"" + separator + "\" is more"})
	}
	if len(separator) > 0 {
		reader.Comma = []rune(separator)[0]
	}
	rows, err := reader.ReadAll()
	if err != nil {
		return Err[Table, FileTableError](FileTableError{Path: path, Message: err.Error()})
	}
	return Ok[Table, FileTableError](rows)
}
