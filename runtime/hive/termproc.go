// The Go for hive.term.start: a program that runs alongside this one, its output
// read while it runs, its input written, and the whole of it stopped — what it
// started included. Taking a program and everything it started down differs per
// platform, and the tags atop termprocunix.go, termprocwindows.go and
// termprocother.go leave two of them out of the build.
//
// A started program is this one's: whatever is still running of it is stopped
// when this program ends — main returning, a panic, hive.term.exit, or an
// interrupt.
package hive

import (
	"bufio"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

var processes struct {
	mu      sync.Mutex
	started []*termRun
}

func TermStart(command string, arguments []string, directory string) Result[TermProcess, TermExecError] {
	return TermStartWith(command, arguments, directory, NewDict[string, string]())
}

// TermStartWith starts the command and answers at once. Its output and its
// errors go down one pipe, in the order it wrote them, as hive.term.exec hands
// them over.
func TermStartWith(command string, arguments []string, directory string, environment Dict[string, string]) Result[TermProcess, TermExecError] {
	failed := func(err error) Result[TermProcess, TermExecError] {
		return Err[TermProcess, TermExecError](TermExecError{Command: command, Code: -1, Message: err.Error()})
	}
	cmd := exec.Command(command, arguments...)
	if directory != "" {
		cmd.Dir = directory
	}
	cmd.Env = termEnvironment(environment)
	pipe, written, err := os.Pipe()
	if err != nil {
		return failed(err)
	}
	cmd.Stdout, cmd.Stderr = written, written
	input, err := cmd.StdinPipe()
	if err != nil {
		pipe.Close()
		written.Close()
		return failed(err)
	}
	termTreePrepare(cmd)
	if err := cmd.Start(); err != nil {
		pipe.Close()
		written.Close()
		input.Close()
		return failed(err)
	}
	written.Close()
	run := &termRun{cmd: cmd, output: bufio.NewReader(pipe), pipe: pipe, input: input, done: make(chan struct{})}
	run.killTree = termTreeAdopt(cmd, run.done)
	go func() {
		err := cmd.Wait()
		if err != nil {
			run.code = -1
			if exited, ok := err.(*exec.ExitError); ok {
				run.code = exited.ExitCode()
			}
		}
		close(run.done)
	}()
	termKeep(run)
	return Ok[TermProcess, TermExecError](TermProcess{Id: cmd.Process.Pid, run: run})
}

// termKeep remembers a started program so the end of this one stops it, and the
// first time, sees that an interrupt ends this program that way too rather than
// leaving its programs behind.
func termKeep(run *termRun) {
	processes.mu.Lock()
	first := len(processes.started) == 0
	processes.started = append(processes.started, run)
	processes.mu.Unlock()
	if !first {
		return
	}
	atEnd(func() {
		processes.mu.Lock()
		all := processes.started
		processes.started = nil
		processes.mu.Unlock()
		for _, each := range all {
			each.stop()
		}
	})
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		Ending()
		os.Exit(130)
	}()
}

func termNoProgram() TermProcessError {
	return TermProcessError{Reason: "Closed", Message: "the process has no program behind it"}
}

// TermProcessReceive answers with at most limit bytes of what the program wrote,
// whatever has arrived.
func TermProcessReceive(p TermProcess, limit int) Result[string, TermProcessError] {
	run := p.run
	if run == nil {
		return Err[string, TermProcessError](termNoProgram())
	}
	if limit <= 0 {
		return Ok[string, TermProcessError]("")
	}
	run.reading.Lock()
	defer run.reading.Unlock()
	if run.stopped.Load() {
		return Err[string, TermProcessError](run.failure(os.ErrClosed))
	}
	buf := make([]byte, limit)
	for {
		n, err := run.output.Read(buf)
		if n > 0 {
			return Ok[string, TermProcessError](string(buf[:n]))
		}
		if err != nil {
			return Err[string, TermProcessError](run.failure(err))
		}
	}
}

// TermProcessReceiveLine answers with the next line the program wrote, without
// its "\n" or "\r\n"; a last line with no newline is a line all the same.
func TermProcessReceiveLine(p TermProcess) Result[string, TermProcessError] {
	run := p.run
	if run == nil {
		return Err[string, TermProcessError](termNoProgram())
	}
	run.reading.Lock()
	defer run.reading.Unlock()
	if run.stopped.Load() {
		return Err[string, TermProcessError](run.failure(os.ErrClosed))
	}
	line, err := run.output.ReadString('\n')
	if err == nil || (errors.Is(err, io.EOF) && line != "" && !run.stopped.Load()) {
		return Ok[string, TermProcessError](strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r"))
	}
	return Err[string, TermProcessError](run.failure(err))
}

// The output ends when the program, and everything it started that holds it,
// has ended — or when it was stopped, after which nothing more is read from it.
func (run *termRun) failure(err error) TermProcessError {
	if run.stopped.Load() || errors.Is(err, os.ErrClosed) {
		return TermProcessError{Reason: "Closed", Message: "the program was stopped"}
	}
	if errors.Is(err, io.EOF) {
		return TermProcessError{Reason: "Closed", Message: "the program's output has ended"}
	}
	return TermProcessError{Reason: "Receive", Message: err.Error()}
}

func TermProcessSend(p TermProcess, text string) Result[int, TermProcessError] {
	run := p.run
	if run == nil {
		return Err[int, TermProcessError](termNoProgram())
	}
	run.sending.Lock()
	defer run.sending.Unlock()
	n, err := io.WriteString(run.input, text)
	if err == nil {
		return Ok[int, TermProcessError](n)
	}
	select {
	case <-run.done:
		return Err[int, TermProcessError](TermProcessError{Reason: "Closed", Message: "the program has ended"})
	default:
	}
	if run.inputClosed.Load() || run.stopped.Load() || errors.Is(err, os.ErrClosed) {
		return Err[int, TermProcessError](TermProcessError{Reason: "Closed", Message: "the program's input was closed"})
	}
	return Err[int, TermProcessError](TermProcessError{Reason: "Send", Message: err.Error()})
}

// TermProcessCloseInput is the end of what the program will be sent: one that
// reads until there is no more, as sort and wc do, then finishes.
func TermProcessCloseInput(p TermProcess) {
	if p.run != nil {
		p.run.inputClosed.Store(true)
		p.run.input.Close()
	}
}

// TermProcessWait blocks for the program to end and answers with its status:
// -1 for one hive.term.processKill stopped, or one that could not say.
func TermProcessWait(p TermProcess) int {
	if p.run == nil {
		return -1
	}
	<-p.run.done
	if p.run.killed.Load() {
		return -1
	}
	return p.run.code
}

// TermProcessKill stops the program and everything it started, and answers once
// it has ended.
func TermProcessKill(p TermProcess) {
	if p.run != nil {
		p.run.stop()
	}
}

func (run *termRun) stop() {
	if run.stopped.Swap(true) {
		run.ended()
		return
	}
	select {
	case <-run.done:
	default:
		run.killed.Store(true)
	}
	run.killTree()
	run.ended()
	run.input.Close()
	run.pipe.Close()
}

// ended waits for the program to be gone, but not for ever: one the system will
// not let go of is not a reason for this program never to end.
func (run *termRun) ended() {
	select {
	case <-run.done:
	case <-time.After(5 * time.Second):
	}
}
