// The engine, as a process: frames in on one pipe, the picture out through memory
// both hold. Vulkan is tried first and OpenGL after it.

//go:build windows || (linux && !android)

package hive

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
)

type uiEngine struct {
	mu   sync.Mutex
	cmd  *exec.Cmd
	in   io.WriteCloser
	gone bool
	out  *bufio.Reader

	held   *uiEngineShared
	spare  *uiEngineShared
	shares int

	painted func(serial uint32, wide, tall int, micros int)
	spent   func(name string)
	stale   func()
	resync  func()
	picture func(path string) (int, int, []byte)
	label   func(words, colour string)
	died    func()
}

func uiEngineStart(path string) (*uiEngine, error) {
	if path == "" {
		return nil, errors.New("this program carries no engine to draw a scene with")
	}
	if os.Getenv("HIVE_SCENE") != "opengl" {
		if e, err := uiEngineRun(path); err == nil {
			return e, nil
		}
	}
	return uiEngineRun(path, "--opengl")
}

func uiEngineRun(path string, args ...string) (*uiEngine, error) {
	cmd := exec.Command(path, args...)
	uiEngineQuiet(cmd)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if os.Getenv("HIVE_SCENE_LOG") != "" {
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	e := &uiEngine{cmd: cmd, in: in, out: bufio.NewReaderSize(out, 1<<16)}
	if why := e.begin(); why != "" {
		e.close()
		return nil, errors.New(why)
	}
	return e, nil
}

func (e *uiEngine) begin() string {
	var head [5]byte
	if _, err := io.ReadFull(e.out, head[:]); err != nil {
		return "the scene's engine stopped before it started"
	}
	body := make([]byte, binary.LittleEndian.Uint32(head[1:]))
	if _, err := io.ReadFull(e.out, body); err != nil || head[0] != 'R' {
		return "the scene's engine could not start: " + string(body)
	}
	return ""
}

func (e *uiEngine) heed() { go e.listen(e.out) }

func (e *uiEngine) say(kind byte, parts ...[]byte) {
	size := 0
	for _, p := range parts {
		size += len(p)
	}
	head := [5]byte{kind}
	binary.LittleEndian.PutUint32(head[1:], uint32(size))
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.gone {
		return
	}
	if _, err := e.in.Write(head[:]); err != nil {
		e.gone = true
		return
	}
	for _, p := range parts {
		if _, err := e.in.Write(p); err != nil {
			e.gone = true
			return
		}
	}
}

func uiEngineU32(values ...int) []byte {
	out := make([]byte, 0, len(values)*4)
	for _, v := range values {
		out = binary.LittleEndian.AppendUint32(out, uint32(v))
	}
	return out
}

func uiEngineNamed(s string) []byte {
	out := binary.LittleEndian.AppendUint16(nil, uint16(len(s)))
	return append(out, s...)
}

func (e *uiEngine) frame(payload []byte) { e.say('S', payload[1:]) }

func (e *uiEngine) stream(what byte, name string, rest []byte) {
	e.say('A', []byte{what}, uiEngineNamed(name), rest)
}

func (e *uiEngine) size(sheetWide, sheetTall, drawnWide, drawnTall int) bool {
	e.mu.Lock()
	e.shares++
	serial := e.shares
	e.mu.Unlock()
	next, err := uiEngineShare(sheetWide*sheetTall*4, serial)
	if err != nil {
		return false
	}
	e.say('Z', uiEngineU32(sheetWide, sheetTall, drawnWide, drawnTall), []byte(next.name))
	e.mu.Lock()
	if e.spare != nil {
		e.spare.close()
	}
	e.spare = e.held
	e.held = next
	e.mu.Unlock()
	return true
}

func (e *uiEngine) insets(boxes [][4]int) {
	body := []byte{byte(len(boxes))}
	for _, b := range boxes {
		body = append(body, uiEngineU32(b[0], b[1], b[2], b[3])...)
	}
	e.say('I', body)
}

func (e *uiEngine) draw(serial uint32) { e.say('D', uiEngineU32(int(serial))) }

func (e *uiEngine) pixels() []byte {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.held == nil {
		return nil
	}
	return e.held.bytes
}

func (e *uiEngine) labelled(words, colour string, wide, tall int, rgba []byte) {
	e.say('l', uiEngineNamed(words), uiEngineNamed(colour), uiEngineU32(wide, tall), rgba)
}

func (e *uiEngine) close() {
	e.say('Q')
	e.mu.Lock()
	e.gone = true
	e.in.Close()
	for _, s := range []*uiEngineShared{e.held, e.spare} {
		if s != nil {
			s.close()
		}
	}
	e.held, e.spare = nil, nil
	e.mu.Unlock()
	go e.cmd.Wait()
}

func (e *uiEngine) listen(out *bufio.Reader) {
	defer func() {
		e.mu.Lock()
		gone := e.gone
		e.gone = true
		e.mu.Unlock()
		if !gone && e.died != nil {
			e.died()
		}
	}()
	var head [5]byte
	for {
		if _, err := io.ReadFull(out, head[:]); err != nil {
			return
		}
		body := make([]byte, binary.LittleEndian.Uint32(head[1:]))
		if _, err := io.ReadFull(out, body); err != nil {
			return
		}
		switch head[0] {
		case 'P':
			if len(body) >= 16 && e.painted != nil {
				e.painted(binary.LittleEndian.Uint32(body), int(binary.LittleEndian.Uint32(body[4:])),
					int(binary.LittleEndian.Uint32(body[8:])), int(binary.LittleEndian.Uint32(body[12:])))
			}
		case 'N':
			if e.resync != nil {
				e.resync()
			}
		case 'C':
			if e.stale != nil {
				e.stale()
			}
		case 'p':
			go e.answerPicture(string(body))
		case 'f':
			go e.answerFile(string(body))
		case 'a':
			if e.spent != nil {
				e.spent(string(body))
			}
		case 't':
			id := string(body)
			uiTerrainLock.Lock()
			data := uiTerrainData[id]
			uiTerrainLock.Unlock()
			e.say('t', uiEngineNamed(id), data)
		case 'l':
			if len(body) >= 2 && e.label != nil {
				n := int(binary.LittleEndian.Uint16(body))
				if 2+n <= len(body) {
					e.label(string(body[2:2+n]), string(body[2+n:]))
				}
			}
		}
	}
}

func (e *uiEngine) answerPicture(path string) {
	wide, tall, rgba := 0, 0, []byte(nil)
	if e.picture != nil {
		wide, tall, rgba = e.picture(path)
	}
	e.say('p', uiEngineNamed(path), uiEngineU32(wide, tall), rgba)
}

var uiEngineRead = func(path string) ([]byte, bool) {
	if uiAssets == nil || path == "" {
		return nil, false
	}
	body, err := uiAssets.ReadFile("assets/" + path)
	return body, err == nil
}

func (e *uiEngine) answerFile(path string) {
	body, ok := uiEngineRead(path)
	found := byte(0)
	if ok {
		found = 1
	}
	e.say('f', uiEngineNamed(path), []byte{found}, body)
}
