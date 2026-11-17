// A started program on Unix leads a process group of its own, so stopping it
// reaches everything it started: asked to end, then, a moment later, made to.

//go:build unix

package hive

import (
	"os/exec"
	"syscall"
	"time"
)

func termTreePrepare(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func termTreeAdopt(cmd *exec.Cmd, done chan struct{}) func() {
	group := cmd.Process.Pid
	return func() {
		syscall.Kill(-group, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
		syscall.Kill(-group, syscall.SIGKILL)
	}
}
