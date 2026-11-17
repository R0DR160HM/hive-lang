// The Go for hive.file.asset: a file from the program's own assets/ directory,
// read out of the executable, where the build put it.
package hive

import (
	"errors"
	"io/fs"
	"strings"
)

func FileAsset(path string) Result[string, FileFileError] {
	name := strings.TrimPrefix(strings.ReplaceAll(path, "\\", "/"), "./")
	if programAssets == nil {
		return Err[string, FileFileError](FileFileError{Reason: "NotFound", Path: path, Message: "the program was built with no assets/ directory beside it"})
	}
	body, err := programAssets.ReadFile("assets/" + name)
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrInvalid) {
		return Err[string, FileFileError](FileFileError{Reason: "NotFound", Path: path, Message: "assets/" + name + " was not built into the program"})
	}
	if err != nil {
		return Err[string, FileFileError](FileFileError{Reason: "Io", Path: path, Message: err.Error()})
	}
	return Ok[string, FileFileError](string(body))
}
