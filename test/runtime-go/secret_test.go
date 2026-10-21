package hive

import (
	"bufio"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestADroppedSecretIsCleared(t *testing.T) {
	s := Hide("hunter2").Ok()
	held := s.bytes()
	s = Secret{}
	deadline := time.Now().Add(5 * time.Second)
	for string(held) != "\x00\x00\x00\x00\x00\x00\x00" {
		if time.Now().After(deadline) {
			t.Fatalf("still holds %q after it was dropped", held)
		}
		runtime.GC()
		time.Sleep(time.Millisecond)
	}
}

func TestAnArenaIsUnlockedOnceEmpty(t *testing.T) {
	first := Hide("x").Ok()
	arena := secretOpen
	for secretOpen == arena {
		Hide(string(make([]byte, secretArenaSize/4)))
	}
	runtime.KeepAlive(first)
	first = Secret{}
	deadline := time.Now().Add(5 * time.Second)
	for {
		secretMu.Lock()
		live := arena.live
		secretMu.Unlock()
		if live == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d secrets still counted in a full arena", live)
		}
		runtime.GC()
		time.Sleep(time.Millisecond)
	}
}

func TestEqualityIsByContent(t *testing.T) {
	if !Eq(Hide("a").Ok(), Bypass("a")) || Eq(Bypass("a"), Bypass("b")) || Eq(Bypass("a"), Bypass("ab")) {
		t.Fatalf("== compared something other than what the secrets hold")
	}
	if Show(Bypass("a")) != "<secret>" {
		t.Fatalf("a secret printed as %q", Show(Bypass("a")))
	}
}

func TestReadSecretBypassReadsTheLineReadSecretWould(t *testing.T) {
	was := termInput
	defer func() { termInput = was }()
	termInput = bufio.NewReader(strings.NewReader("hunter2\r\nhunter2\r\n"))
	if got := TermReadSecret(); got.IsError() || Reveal(got.Ok()) != "hunter2" {
		t.Fatalf("readSecret answered %v", got)
	}
	if got := Reveal(TermReadSecretBypass()); got != "hunter2" {
		t.Fatalf("readSecretBypass read %q", got)
	}
}
