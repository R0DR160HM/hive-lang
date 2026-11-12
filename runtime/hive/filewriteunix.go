// Permissions on a unix: the mode, which is the whole of it.

//go:build !windows

package hive

import "os"

// What a secret is written with: this user reads and writes it, everybody else
// has no access at all.
const secretMode = 0o600

// openPrivate opens path for writing, creating it when absent, with nobody but
// this user allowed near it.
//
// The chmod is for a file that was already there — a mode handed to OpenFile
// applies only to one it creates. A umask cannot widen either: it only ever
// clears further bits.
func openPrivate(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, secretMode)
	if err != nil {
		return nil, err
	}
	if err := f.Chmod(secretMode); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
