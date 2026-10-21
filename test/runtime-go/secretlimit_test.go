//go:build linux && (amd64 || arm64)

package hive

import (
	"bufio"
	"strings"
	"syscall"
	"testing"
)

const rlimitMemlock = 8

// noLockedMemoryLeft leaves the process no more locked memory than it holds,
// until the test ends.
func noLockedMemoryLeft(t *testing.T) {
	t.Helper()
	if syscall.Geteuid() == 0 {
		t.Skip("root locks memory past any limit")
	}
	var was syscall.Rlimit
	if err := syscall.Getrlimit(rlimitMemlock, &was); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Setrlimit(rlimitMemlock, &syscall.Rlimit{Cur: 0, Max: was.Max}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Setrlimit(rlimitMemlock, &was) })
}

func TestPastTheLockLimitHideAnswersAnError(t *testing.T) {
	noLockedMemoryLeft(t)
	got := Hide(string(make([]byte, 4*secretArenaSize)))
	if !got.IsError() || got.Err().Reason != "LimitExceeded" {
		t.Fatalf("hiding past the limit answered %v", got)
	}
	if Reveal(Bypass("still")) != "still" {
		t.Fatalf("bypass needed locked memory")
	}
}

// Longer than an arena, so neither locked twin can fit it in one already open.
func TestPastTheLockLimitTheBypassCallsStillAnswer(t *testing.T) {
	noLockedMemoryLeft(t)
	long := strings.Repeat("x", 4*secretArenaSize)

	sealed := CryptoEncrypt(Bypass(long), Bypass("pw"))
	if got := CryptoDecrypt(sealed, Bypass("pw")); !got.IsError() || got.Err().Reason != "LimitExceeded" {
		t.Fatalf("decrypting past the limit answered %v", got)
	}
	if got := CryptoDecryptBypass(sealed, Bypass("pw")); got.IsError() || Reveal(got.Ok()) != long {
		t.Fatalf("decryptBypass needed locked memory")
	}

	was := termInput
	defer func() { termInput = was }()
	termInput = bufio.NewReader(strings.NewReader(long + "\n" + long + "\n"))
	if got := TermReadSecret(); !got.IsError() || got.Err().Reason != "LimitExceeded" {
		t.Fatalf("reading past the limit answered %v", got)
	}
	if Reveal(TermReadSecretBypass()) != long {
		t.Fatalf("readSecretBypass needed locked memory")
	}
}
