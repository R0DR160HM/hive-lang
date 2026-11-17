package hive

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

// The test binary started again plays one of these, named by HIVE_TEST_ROLE:
// an echo that ends with status 3 when its input does, a sleeper, and a parent
// that starts a sleeper of its own, says its id, and sleeps.
func TestHelperProcess(t *testing.T) {
	switch os.Getenv("HIVE_TEST_ROLE") {
	case "echo":
		lines := bufio.NewScanner(os.Stdin)
		for lines.Scan() {
			fmt.Println("heard " + lines.Text())
		}
		fmt.Fprint(os.Stderr, "and that was all")
		os.Exit(3)
	case "sleeper":
		time.Sleep(time.Minute)
		os.Exit(0)
	case "parent":
		child := exec.Command(os.Args[0], "-test.run=^TestHelperProcess$")
		child.Env = append(os.Environ(), "HIVE_TEST_ROLE=sleeper")
		if err := child.Start(); err != nil {
			fmt.Println("could not start: " + err.Error())
			os.Exit(1)
		}
		fmt.Println(child.Process.Pid)
		time.Sleep(time.Minute)
		os.Exit(0)
	}
}

func helper(t *testing.T, role string) TermProcess {
	t.Helper()
	env := NewDict[string, string]()
	env.Set("HIVE_TEST_ROLE", role)
	started := TermStartWith(os.Args[0], []string{"-test.run=^TestHelperProcess$"}, "", env)
	p, ok := okOf(started)
	if !ok {
		t.Fatalf("could not start the %s: %+v", role, started)
	}
	return p
}

// Written to, read from as it answers, its input closed, and its status read —
// with what it wrote to standard error in the same stream, last line and all.
func TestAConversation(t *testing.T) {
	p := helper(t, "echo")
	for _, word := range []string{"one", "two"} {
		if n, ok := okOf(TermProcessSend(p, word+"\n")); !ok || n != len(word)+1 {
			t.Fatalf("sending %q: %d", word, n)
		}
		if line, ok := okOf(TermProcessReceiveLine(p)); !ok || line != "heard "+word {
			t.Fatalf("after %q read %q", word, line)
		}
	}
	TermProcessCloseInput(p)
	if line, ok := okOf(TermProcessReceiveLine(p)); !ok || line != "and that was all" {
		t.Errorf("the last line read %q", line)
	}
	if why, ok := errOf(TermProcessReceiveLine(p)); !ok || why.Reason != "Closed" || why.Message != "the program's output has ended" {
		t.Errorf("past the end: %+v", why)
	}
	if code := TermProcessWait(p); code != 3 {
		t.Errorf("its status was %d", code)
	}
	if why, ok := errOf(TermProcessSend(p, "late\n")); !ok || why.Reason != "Closed" {
		t.Errorf("sending to a program that has ended: %+v", why)
	}
}

// Stopping a program stops what it started too, and it answers -1.
func TestKillTakesEverythingItStartedDown(t *testing.T) {
	p := helper(t, "parent")
	said, ok := okOf(TermProcessReceiveLine(p))
	grandchild, err := strconv.Atoi(said)
	if !ok || err != nil {
		t.Fatalf("the parent said %q", said)
	}
	if !alive(grandchild) {
		t.Fatal("the grandchild was never running")
	}
	TermProcessKill(p)
	if code := TermProcessWait(p); code != -1 {
		t.Errorf("a stopped program's status was %d", code)
	}
	if why, ok := errOf(TermProcessReceiveLine(p)); !ok || why.Message != "the program was stopped" {
		t.Errorf("reading it afterwards: %+v", why)
	}
	deadline := time.Now().Add(5 * time.Second)
	for alive(grandchild) {
		if time.Now().After(deadline) {
			t.Fatal("what it started is still running")
		}
		time.Sleep(50 * time.Millisecond)
	}
	TermProcessKill(p)
}

// The end of this program stops whatever it started that is still running.
func TestTheEndOfTheProgramStopsWhatItStarted(t *testing.T) {
	p := helper(t, "sleeper")
	Ending()
	select {
	case <-p.run.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the sleeper outlived the end of the program")
	}
}

func TestAProcessWithNothingBehindIt(t *testing.T) {
	var p TermProcess
	if why, ok := errOf(TermProcessReceive(p, 10)); !ok || why.Reason != "Closed" {
		t.Errorf("receive: %+v", why)
	}
	if why, ok := errOf(TermProcessSend(p, "x")); !ok || why.Reason != "Closed" {
		t.Errorf("send: %+v", why)
	}
	if code := TermProcessWait(p); code != -1 {
		t.Errorf("wait: %d", code)
	}
	TermProcessKill(p)
	TermProcessCloseInput(p)
}

func TestAProgramThatCannotStartIsAnExecError(t *testing.T) {
	why, ok := errOf(TermStart("no-such-program-anywhere-hive", nil, ""))
	if !ok || why.Code != -1 || why.Command != "no-such-program-anywhere-hive" {
		t.Errorf("read %+v", why)
	}
}
