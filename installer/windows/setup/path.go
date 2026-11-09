package main

import (
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const (
	userEnvironment   = `Environment`
	systemEnvironment = `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`
	hiveKey           = `Software\Hive`
	// What this installer added to the user's PATH, so uninstalling removes only that.
	addedEntry = "PathEntry"
)

var (
	advapi32           = syscall.NewLazyDLL("advapi32.dll")
	regCreateKeyEx     = advapi32.NewProc("RegCreateKeyExW")
	regSetValueEx      = advapi32.NewProc("RegSetValueExW")
	regDeleteValue     = advapi32.NewProc("RegDeleteValueW")
	sendMessageTimeout = user32.NewProc("SendMessageTimeoutW")
)

func addToPath(dir string) error {
	dir = filepath.Clean(dir)
	for _, entry := range freshPath() {
		if samePlace(entry, dir) {
			return nil
		}
	}
	raw, kind := registryValue(syscall.HKEY_CURRENT_USER, userEnvironment, "Path")
	if kind != syscall.REG_SZ {
		kind = syscall.REG_EXPAND_SZ
	}
	if err := setRegistryString(syscall.HKEY_CURRENT_USER, userEnvironment, "Path", withEntry(raw, dir), kind); err != nil {
		return err
	}
	if err := setRegistryString(syscall.HKEY_CURRENT_USER, hiveKey, addedEntry, dir, syscall.REG_SZ); err != nil {
		return err
	}
	announceEnvironment()
	return nil
}

func removeFromPath() error {
	entry, _ := registryValue(syscall.HKEY_CURRENT_USER, hiveKey, addedEntry)
	if entry == "" {
		return nil
	}
	raw, kind := registryValue(syscall.HKEY_CURRENT_USER, userEnvironment, "Path")
	if kind != syscall.REG_SZ {
		kind = syscall.REG_EXPAND_SZ
	}
	if err := setRegistryString(syscall.HKEY_CURRENT_USER, userEnvironment, "Path", withoutEntry(raw, entry, expand), kind); err != nil {
		return err
	}
	deleteRegistryValue(syscall.HKEY_CURRENT_USER, hiveKey, addedEntry)
	announceEnvironment()
	return nil
}

// withEntry and withoutEntry undo each other exactly, a trailing `;` included.
func withEntry(raw string, dir string) string {
	if raw == "" {
		return dir
	}
	if strings.HasSuffix(raw, ";") {
		return raw + dir + ";"
	}
	return raw + ";" + dir
}

func withoutEntry(raw string, entry string, expand func(string) string) string {
	var kept []string
	for _, part := range strings.Split(raw, ";") {
		if part == "" || !samePlace(expand(part), entry) {
			kept = append(kept, part)
		}
	}
	return strings.Join(kept, ";")
}

func samePlace(a string, b string) bool {
	return strings.EqualFold(comparable(a), comparable(b))
}

func comparable(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	return strings.TrimRight(filepath.Clean(path), `\/`)
}

func setRegistryString(root syscall.Handle, path string, name string, value string, kind uint32) error {
	var key syscall.Handle
	const keySetValue = 0x0002
	if rc, _, _ := regCreateKeyEx.Call(uintptr(root), uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(path))), 0, 0, 0, keySetValue, 0, uintptr(unsafe.Pointer(&key)), 0); rc != 0 {
		return syscall.Errno(rc)
	}
	defer syscall.RegCloseKey(key)
	data := syscall.StringToUTF16(value)
	rc, _, _ := regSetValueEx.Call(uintptr(key), uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(name))), 0, uintptr(kind), uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
	if rc != 0 {
		return syscall.Errno(rc)
	}
	return nil
}

func deleteRegistryValue(root syscall.Handle, path string, name string) {
	var key syscall.Handle
	const keySetValue = 0x0002
	if syscall.RegOpenKeyEx(root, syscall.StringToUTF16Ptr(path), 0, keySetValue, &key) != nil {
		return
	}
	defer syscall.RegCloseKey(key)
	regDeleteValue.Call(uintptr(key), uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(name))))
}

// Without this, terminals opened from Explorer keep the old PATH until sign-out.
func announceEnvironment() {
	const broadcast, settingChange, abortIfHung = 0xffff, 0x001A, 0x0002
	var result uintptr
	sendMessageTimeout.Call(broadcast, settingChange, 0, uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr("Environment"))), abortIfHung, 5000, uintptr(unsafe.Pointer(&result)))
}
