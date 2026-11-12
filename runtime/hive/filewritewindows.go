// The same on Windows, where it is an access list rather than a mode: the one
// file right granted to the one SID this process is running as.

//go:build windows

package hive

import (
	"os"
	"syscall"
	"unsafe"
)

// The access list a secret is written under, as SDDL, waiting for the user's own
// SID. FA is every right a file has; P protects the list from inheritance,
// without which whatever the containing folder hands down is added to it.
//
// The right to set that list on a file that already existed.
//
// Which part of a descriptor is being set, and that it stops inheriting.
const secretDacl = "D:P(A;;FA;;;"

const (
	writeDac      = 0x00040000
	daclSecurity  = 0x00000004
	protectedDacl = 0x80000000

	// A file, and the one revision SDDL has.
	seFileObject  = 1
	sddlRevision1 = 1
)

var (
	advapi32               = syscall.NewLazyDLL("advapi32.dll")
	procDescriptorFromSddl = advapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procDescriptorDacl     = advapi32.NewProc("GetSecurityDescriptorDacl")
	procSetSecurityInfo    = advapi32.NewProc("SetSecurityInfo")
)

// openPrivate opens path for writing, creating it when absent, with nobody but
// this user allowed near it. Windows has no mode bits worth the name — a chmod
// moves the read-only flag and nothing else — so the access list is written out
// in full.
func openPrivate(path string) (*os.File, error) {
	descriptor, err := privateDescriptor()
	if err != nil {
		return nil, err
	}
	defer syscall.LocalFree(syscall.Handle(descriptor))
	f, err := createPrivate(path, descriptor)
	if err != nil {
		return nil, err
	}

	// A descriptor handed to CreateFile is used only for a file it creates, so a
	// file that was already there is narrowed here instead.
	if err := narrowToOwner(f, descriptor); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// privateDescriptor is a security descriptor granting this user everything and
// everybody else nothing. The caller frees it with LocalFree.
func privateDescriptor() (uintptr, error) {
	sid, err := currentUserSid()
	if err != nil {
		return 0, err
	}
	sddl, err := syscall.UTF16PtrFromString(secretDacl + sid + ")")
	if err != nil {
		return 0, err
	}
	var descriptor uintptr
	done, _, err := procDescriptorFromSddl.Call(
		uintptr(unsafe.Pointer(sddl)),
		sddlRevision1,
		uintptr(unsafe.Pointer(&descriptor)),
		0,
	)
	if done == 0 {
		return 0, err
	}
	return descriptor, nil
}

// currentUserSid is who this process is running as, spelled as an access list
// names a user.
func currentUserSid() (string, error) {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return "", err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return "", err
	}
	return user.User.Sid.String()
}

// createPrivate opens the file, creating it with the list already on it and
// asking for the right to set that list on one that was already there. A file
// owned by somebody else fails here rather than being written in the clear.
func createPrivate(path string, descriptor uintptr) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	security := syscall.SecurityAttributes{SecurityDescriptor: descriptor}
	security.Length = uint32(unsafe.Sizeof(security))
	handle, err := syscall.CreateFile(
		name,
		syscall.GENERIC_WRITE|writeDac,
		0,
		&security,
		syscall.OPEN_ALWAYS,
		syscall.FILE_ATTRIBUTE_NORMAL,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), path), nil
}

// narrowToOwner puts the descriptor's access list on an open file.
func narrowToOwner(f *os.File, descriptor uintptr) error {
	var present, defaulted int32
	var dacl uintptr
	done, _, err := procDescriptorDacl.Call(
		descriptor,
		uintptr(unsafe.Pointer(&present)),
		uintptr(unsafe.Pointer(&dacl)),
		uintptr(unsafe.Pointer(&defaulted)),
	)
	if done == 0 {
		return err
	}

	// SetSecurityInfo answers with an error code rather than a flag, and zero is
	// the one that means it worked.
	code, _, _ := procSetSecurityInfo.Call(
		f.Fd(),
		seFileObject,
		daclSecurity|protectedDacl,
		0,
		0,
		dacl,
		0,
	)
	if code != 0 {
		return syscall.Errno(code)
	}
	return nil
}
