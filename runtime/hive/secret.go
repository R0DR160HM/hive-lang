// The Go behind `hide`: memory the operating system will not swap out, handed
// out a Secret at a time. Locking is the one part that differs per platform.
package hive

import (
	"os"
	"runtime"
	"sync"
	"unsafe"
)

// Locked memory comes in arenas of whole pages, so unlocking one never unlocks
// a page something else still needs. A Secret is a slot in one.
//
// ponytail: an arena is unlocked only once every slot in it is dead; a free list would reuse slots sooner.
const secretArenaSize = 16 << 10

type secretArena struct {
	mem  []byte
	used int
	live int
}

type secretSlot struct {
	arena *secretArena
	b     []byte
}

var (
	secretMu   sync.Mutex
	secretOpen *secretArena
	secretPage = os.Getpagesize()
)

func Hide(text string) Result[Secret, SecretError] {
	s, err := newSecret(len(text))
	if err != nil {
		return Err[Secret, SecretError](*err)
	}
	copy(s.bytes(), text)
	return Ok[Secret, SecretError](s)
}

func HideWith[T any](x T, put func(*[]byte, T)) Result[Secret, SecretError] {
	var b []byte
	put(&b, x)
	s, err := hideBytes(b)
	if err != nil {
		return Err[Secret, SecretError](*err)
	}
	return Ok[Secret, SecretError](s)
}

func hideBytes(b []byte) (Secret, *SecretError) {
	defer clear(b)
	s, err := newSecret(len(b))
	if err == nil {
		copy(s.bytes(), b)
	}
	return s, err
}

// newSecret is n zero bytes of locked memory for its caller to fill, cleared
// once nothing holds the Secret any more.
func newSecret(n int) (Secret, *SecretError) {
	if n == 0 {
		return Secret{p: new([]byte)}, nil
	}
	secretMu.Lock()
	size := (n + 15) &^ 15
	a := secretOpen
	if a == nil || a.used+size > len(a.mem) {
		mem, err := lockedPages(max(size, secretArenaSize))
		if err != nil {
			secretMu.Unlock()
			return Secret{}, err
		}
		if a != nil && a.live == 0 {
			unlockMemory(a.mem)
		}
		a = &secretArena{mem: mem}
		secretOpen = a
	}
	b := a.mem[a.used : a.used+n : a.used+n]
	a.used += size
	a.live++
	secretMu.Unlock()
	s := Secret{p: &b}
	runtime.AddCleanup(s.p, releaseSecret, secretSlot{a, b})
	return s, nil
}

func releaseSecret(slot secretSlot) {
	clear(slot.b)
	secretMu.Lock()
	defer secretMu.Unlock()
	a := slot.arena
	a.live--
	if a.live > 0 {
		return
	}
	if a == secretOpen {
		a.used = 0
		return
	}
	unlockMemory(a.mem)
}

// unlockedSecret is newSecret for the calls that bypass the lock.
func unlockedSecret(n int) (Secret, *SecretError) {
	return bypassed(make([]byte, n)), nil
}

// lockedPages is n bytes, rounded up to whole pages, that will not be swapped
// out, or why they cannot be had.
func lockedPages(n int) ([]byte, *SecretError) {
	n = (n + secretPage - 1) / secretPage * secretPage
	raw := make([]byte, n+secretPage)
	skip := (secretPage - int(uintptr(unsafe.Pointer(&raw[0]))%uintptr(secretPage))) % secretPage
	mem := raw[skip : skip+n : skip+n]
	if err := lockMemory(mem); err != nil {
		reason := "LimitExceeded"
		if !secretLockable {
			reason = "Unsupported"
		}
		return nil, &SecretError{Reason: reason, Message: "cannot keep a Secret out of swap: " + err.Error()}
	}
	return mem, nil
}
