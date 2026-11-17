// Where there are no process groups or jobs — a program built for a browser —
// stopping a program is stopping it alone, if one could be started at all.

//go:build !unix && !windows

package hive

import "os/exec"

func termTreePrepare(cmd *exec.Cmd) {}

func termTreeAdopt(cmd *exec.Cmd, done chan struct{}) func() {
	return func() { cmd.Process.Kill() }
}
