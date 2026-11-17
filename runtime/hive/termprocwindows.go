// A started program on Windows goes in a job of its own, and so does everything
// it starts. Stopping it ends the job; and the job ends by itself when this
// program does, however it ends — a crash included — because its last handle
// closes with it.

//go:build windows

package hive

import (
	"os/exec"
	"strconv"
	"syscall"
	"unsafe"
)

var (
	procCreateJobObjectW         = kernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = kernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = kernel32.NewProc("AssignProcessToJobObject")
	procTerminateJobObject       = kernel32.NewProc("TerminateJobObject")
)

const (
	jobExtendedLimitInformation = 9
	jobKillOnJobClose           = 0x2000
	processTerminate            = 0x0001
	processSetQuota             = 0x0100
)

type jobBasicLimit struct {
	perProcessUserTimeLimit int64
	perJobUserTimeLimit     int64
	limitFlags              uint32
	minimumWorkingSetSize   uintptr
	maximumWorkingSetSize   uintptr
	activeProcessLimit      uint32
	affinity                uintptr
	priorityClass           uint32
	schedulingClass         uint32
}

type jobExtendedLimit struct {
	basic                 jobBasicLimit
	io                    [6]uint64
	processMemoryLimit    uintptr
	jobMemoryLimit        uintptr
	peakProcessMemoryUsed uintptr
	peakJobMemoryUsed     uintptr
}

func termTreePrepare(cmd *exec.Cmd) {}

// termTreeAdopt puts the program in its job. Where the system will not have it,
// stopping it falls back on taskkill, which follows the tree from the program
// down — as far as every parent in it is still alive.
func termTreeAdopt(cmd *exec.Cmd, done chan struct{}) func() {
	pid := cmd.Process.Pid
	fallback := func() {
		exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(pid)).Run()
		cmd.Process.Kill()
	}
	job, _, _ := procCreateJobObjectW.Call(0, 0)
	if job == 0 {
		return fallback
	}
	var limits jobExtendedLimit
	limits.basic.limitFlags = jobKillOnJobClose
	set, _, _ := procSetInformationJobObject.Call(job, jobExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), unsafe.Sizeof(limits))
	assigned := uintptr(0)
	if process, err := syscall.OpenProcess(processSetQuota|processTerminate, false, uint32(pid)); err == nil {
		assigned, _, _ = procAssignProcessToJobObject.Call(job, uintptr(process))
		syscall.CloseHandle(process)
	}
	if set == 0 || assigned == 0 {
		syscall.CloseHandle(syscall.Handle(job))
		return fallback
	}
	return func() { procTerminateJobObject.Call(job, 1) }
}
