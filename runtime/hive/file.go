package hive

import (
	"os"
	"sort"
	"strings"
)

type FileFileError struct {
	Reason  string
	Path    string
	Message string
}

func fileError(path string, err error) FileFileError {
	reason := "Io"
	if os.IsNotExist(err) {
		reason = "NotFound"
	} else if os.IsPermission(err) {
		reason = "Permission"
	} else if os.IsExist(err) {
		reason = "Exists"
	}
	return FileFileError{Reason: reason, Path: path, Message: err.Error()}
}

func FileRead(path string) Result[string, FileFileError] {
	data, err := os.ReadFile(path)
	if err != nil {
		return Err[string, FileFileError](fileError(path, err))
	}
	return Ok[string, FileFileError](string(data))
}

// Splits on newlines, dropping the empty piece a trailing newline leaves
// and any Windows carriage returns.
func FileLines(path string) Result[[]string, FileFileError] {
	read := FileRead(path)
	if read.IsError() {
		return Err[[]string, FileFileError](read.Err())
	}
	text := strings.ReplaceAll(read.Ok(), "\r\n", "\n")
	text = strings.TrimSuffix(text, "\n")
	if text == "" {
		return Ok[[]string, FileFileError]([]string{})
	}
	return Ok[[]string, FileFileError](strings.Split(text, "\n"))
}

func FileWrite(path, contents string) Result[int, FileFileError] {
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	return Ok[int, FileFileError](len(contents))
}

func FileAppend(path, contents string) Result[int, FileFileError] {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	defer f.Close()
	n, err := f.WriteString(contents)
	if err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	return Ok[int, FileFileError](n)
}

func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func FileSize(path string) Result[int, FileFileError] {
	info, err := os.Stat(path)
	if err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	return Ok[int, FileFileError](int(info.Size()))
}

func FileDelete(path string) Result[bool, FileFileError] {
	if err := os.Remove(path); err != nil {
		return Err[bool, FileFileError](fileError(path, err))
	}
	return Ok[bool, FileFileError](true)
}

// Sorted, and without any leading path.
func FileList(path string) Result[[]string, FileFileError] {
	entries, err := os.ReadDir(path)
	if err != nil {
		return Err[[]string, FileFileError](fileError(path, err))
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return Ok[[]string, FileFileError](out)
}

// Creates a directory along with any missing parents, and is not an error
// when it is already there.
func FileMakeDir(path string) Result[bool, FileFileError] {
	if err := os.MkdirAll(path, 0o755); err != nil {
		return Err[bool, FileFileError](fileError(path, err))
	}
	return Ok[bool, FileFileError](true)
}

func FileCopy(from, to string) Result[int, FileFileError] {
	read := FileRead(from)
	if read.IsError() {
		return Err[int, FileFileError](read.Err())
	}
	return FileWrite(to, read.Ok())
}

func FileMove(from, to string) Result[bool, FileFileError] {
	if err := os.Rename(from, to); err != nil {
		return Err[bool, FileFileError](fileError(from, err))
	}
	return Ok[bool, FileFileError](true)
}
