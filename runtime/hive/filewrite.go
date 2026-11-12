// The Go for `hive.file.writeSecret`: `hive.file.write` with the file left
// readable by this user alone. What only-this-user means is the one thing that
// differs between platforms, so the opening of the file is a file per platform
// and everything after it is shared.
package hive

import (
	"os"
	"runtime"
)

// FileWriteSecret replaces a file with contents, creating it when absent, and
// leaves it readable by this user alone. Backs hive.file.writeSecret.
//
// Who may read it is settled before any of the secret is in it, and a file that
// was already there is narrowed rather than trusted: the permissions it happened
// to carry are no claim about who should see what is going into it now.
func FileWriteSecret(path string, contents Secret) Result[int, FileFileError] {
	defer runtime.KeepAlive(contents)
	f, err := openPrivate(path)
	if err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	written, err := replaceContents(f, contents.bytes())
	if closed := f.Close(); err == nil {
		err = closed
	}
	if err != nil {
		return Err[int, FileFileError](fileError(path, err))
	}
	return Ok[int, FileFileError](written)
}

// Emptying first is what makes this a replacement: without it a shorter secret
// would leave the tail of the longer one it replaced.
func replaceContents(f *os.File, contents []byte) (int, error) {
	if err := f.Truncate(0); err != nil {
		return 0, err
	}
	return f.Write(contents)
}
