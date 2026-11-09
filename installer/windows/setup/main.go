// hive-setup runs the custom actions of hive-windows.msi, which carries it
// without installing it:
//
//	hive-setup fetch <version> <dir> <uilevel>   put that release's hive.exe in dir
//	hive-setup path add <dir>                     put dir on the user's PATH unless it is on a PATH
//	hive-setup path remove                        take off the PATH what "path add" put there
//	hive-setup go                                 offer to install Go if it is missing
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	isWow64Process2          = kernel32.NewProc("IsWow64Process2")
	expandEnvironmentStrings = kernel32.NewProc("ExpandEnvironmentStringsW")
	user32                   = syscall.NewLazyDLL("user32.dll")
	messageBox               = user32.NewProc("MessageBoxW")
)

func main() {
	if len(os.Args) == 5 && os.Args[1] == "fetch" {
		err := fetchHive(os.Args[2], filepath.Clean(os.Args[3]))
		if err != nil {
			record(err)
			if level, _ := strconv.Atoi(os.Args[4]); level > 3 {
				tell("Hive could not be installed: " + err.Error())
			}
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "path" && os.Args[2] == "add" {
		finish(addToPath(filepath.Clean(os.Args[3])))
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "path" && os.Args[2] == "remove" {
		finish(removeFromPath())
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "go" {
		finish(offerGo())
		return
	}
	fmt.Fprintln(os.Stderr, "usage: hive-setup fetch <version> <dir> <uilevel> | path add <dir> | path remove | go")
	os.Exit(2)
}

func finish(err error) {
	if err != nil {
		record(err)
		os.Exit(1)
	}
}

// A failing EXE custom action shows only a generic error, so the reason goes here.
func record(err error) {
	log, open := os.OpenFile(filepath.Join(os.TempDir(), "hive-setup.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if open != nil {
		return
	}
	defer log.Close()
	fmt.Fprintf(log, "%s %s: %v\n", time.Now().Format(time.RFC3339), strings.Join(os.Args[1:], " "), err)
}

// An x64 helper on an Arm64 machine still has to fetch the arm64 compiler.
func nativeArch() string {
	if isWow64Process2.Find() == nil {
		process, _ := syscall.GetCurrentProcess()
		var running, native uint16
		ok, _, _ := isWow64Process2.Call(uintptr(process), uintptr(unsafe.Pointer(&running)), uintptr(unsafe.Pointer(&native)))
		if ok != 0 {
			switch native {
			case 0xAA64:
				return "arm64"
			case 0x8664:
				return "amd64"
			}
		}
	}
	return runtime.GOARCH
}

// The PATH a terminal opened now would have; this process's own predates the install.
func freshPath() []string {
	system := registryString(syscall.HKEY_LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, "Path")
	user := registryString(syscall.HKEY_CURRENT_USER, `Environment`, "Path")
	var dirs []string
	for _, list := range []string{system, user, os.Getenv("PATH")} {
		for _, dir := range strings.Split(list, ";") {
			if dir = strings.TrimSpace(dir); dir != "" {
				dirs = append(dirs, dir)
			}
		}
	}
	return dirs
}

func registryString(root syscall.Handle, path string, name string) string {
	value, kind := registryValue(root, path, name)
	if kind == syscall.REG_EXPAND_SZ {
		return expand(value)
	}
	return value
}

// registryValue is a string value as stored, unexpanded, and its type; 0 when absent.
func registryValue(root syscall.Handle, path string, name string) (string, uint32) {
	var key syscall.Handle
	if syscall.RegOpenKeyEx(root, syscall.StringToUTF16Ptr(path), 0, syscall.KEY_READ, &key) != nil {
		return "", 0
	}
	defer syscall.RegCloseKey(key)
	var kind, size uint32
	if syscall.RegQueryValueEx(key, syscall.StringToUTF16Ptr(name), nil, &kind, nil, &size) != nil || size == 0 {
		return "", 0
	}
	buffer := make([]uint16, size/2+1)
	if syscall.RegQueryValueEx(key, syscall.StringToUTF16Ptr(name), nil, &kind, (*byte)(unsafe.Pointer(&buffer[0])), &size) != nil {
		return "", 0
	}
	return syscall.UTF16ToString(buffer), kind
}

func expand(value string) string {
	source := syscall.StringToUTF16Ptr(value)
	size, _, _ := expandEnvironmentStrings.Call(uintptr(unsafe.Pointer(source)), 0, 0)
	if size == 0 {
		return value
	}
	buffer := make([]uint16, size)
	if done, _, _ := expandEnvironmentStrings.Call(uintptr(unsafe.Pointer(source)), uintptr(unsafe.Pointer(&buffer[0])), size); done == 0 {
		return value
	}
	return syscall.UTF16ToString(buffer)
}

// This program has no console, so a command it runs must not open one either.
func quietly(name string, args ...string) *exec.Cmd {
	command := exec.Command(name, args...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	return command
}

const (
	mbOK           = 0x0
	mbYesNo        = 0x4
	mbIconQuestion = 0x20
	mbIconWarning  = 0x30
	mbForeground   = 0x10000
	mbTopmost      = 0x40000
	idYes          = 6
)

func ask(question string) bool {
	return show(question, mbYesNo|mbIconQuestion|mbForeground|mbTopmost) == idYes
}

func tell(message string) {
	show(message, mbOK|mbIconWarning|mbForeground|mbTopmost)
}

func show(text string, style uintptr) uintptr {
	answer, _, _ := messageBox.Call(0, uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(text))), uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr("Hive"))), style)
	return answer
}
