// X11 over its own socket, which XWayland serves on a Wayland desktop.

//go:build linux && !android

package hive

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
)

func init() {
	uiNativePainter = func() uiPainter {
		return &uixWindow{n: uiNewNative(), woke: make(chan struct{}, 1), themed: make(chan bool, 1),
			inbox: make(chan func(), 256)}
	}
}

var uixLE = binary.LittleEndian

type uixReply struct {
	seq    uint16
	data   []byte
	failed bool
}

type uixScreen struct {
	root, visual uint32
	depth        byte
	width        int
	height       int
}

type uixConn struct {
	conn    net.Conn
	out     *bufio.Writer
	seq     uint16
	maxLen  int
	msbPix  bool
	idBase  uint32
	idInc   uint32
	idNext  uint32
	minCode byte
	maxCode byte
	screen  uixScreen

	replies chan uixReply
	mu      sync.Mutex
	queue   [][]byte
	ready   chan struct{}
	dead    chan struct{}
}

func uixDial() (*uixConn, error) {
	display := os.Getenv("DISPLAY")
	colon := strings.LastIndexByte(display, ':')
	if colon < 0 {
		return nil, errors.New("no display")
	}
	host, rest := display[:colon], display[colon+1:]
	number, screenPart, _ := strings.Cut(rest, ".")
	if _, err := strconv.Atoi(number); err != nil {
		return nil, errors.New("no display")
	}
	screenIndex, _ := strconv.Atoi(screenPart)
	var conn net.Conn
	var err error
	local := host == "" || host == "unix" || strings.HasPrefix(host, "/")
	if local {
		path := "/tmp/.X11-unix/X" + number
		if strings.HasPrefix(host, "/") {
			path = display
		}
		conn, err = net.DialTimeout("unix", path, 2*time.Second)
		if err != nil {
			conn, err = net.DialTimeout("unix", "@"+path, 2*time.Second)
		}
	} else {
		port, _ := strconv.Atoi(number)
		conn, err = net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(6000+port)), 2*time.Second)
	}
	if err != nil {
		return nil, err
	}
	c := &uixConn{conn: conn, out: bufio.NewWriterSize(conn, 1<<16), replies: make(chan uixReply, 64),
		ready: make(chan struct{}, 1), dead: make(chan struct{})}
	name, data := uixCookie(local, host, number)
	if err := c.handshake(name, data, screenIndex); err != nil {
		conn.Close()
		return nil, err
	}
	go c.read()
	return c, nil
}

func uixCookie(local bool, host, number string) (string, []byte) {
	path := os.Getenv("XAUTHORITY")
	if path == "" {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, ".Xauthority")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", nil
	}
	hostname, _ := os.Hostname()
	be := binary.BigEndian
	field := func(at int) ([]byte, int, bool) {
		if at+2 > len(raw) {
			return nil, at, false
		}
		n := int(be.Uint16(raw[at:]))
		if at+2+n > len(raw) {
			return nil, at, false
		}
		return raw[at+2 : at+2+n], at + 2 + n, true
	}
	for at := 0; at+2 <= len(raw); {
		family := be.Uint16(raw[at:])
		address, next, ok1 := field(at + 2)
		num, next, ok2 := field(next)
		kind, next, ok3 := field(next)
		secret, next, ok4 := field(next)
		if !ok1 || !ok2 || !ok3 || !ok4 {
			break
		}
		at = next
		if string(kind) != "MIT-MAGIC-COOKIE-1" || (len(num) > 0 && string(num) != number) {
			continue
		}
		mine := local || host == "localhost" || host == "127.0.0.1" || host == hostname
		switch {
		case family == 65535:
		case family == 256 && mine && string(address) == hostname:
		case family != 256 && !local:
		default:
			continue
		}
		return string(kind), secret
	}
	return "", nil
}

func uixPad(n int) int { return (4 - n%4) % 4 }

func (c *uixConn) handshake(name string, data []byte, screenIndex int) error {
	var b bytes.Buffer
	b.Write([]byte{'l', 0, 11, 0, 0, 0})
	binary.Write(&b, uixLE, uint16(len(name)))
	binary.Write(&b, uixLE, uint16(len(data)))
	b.Write([]byte{0, 0})
	b.WriteString(name)
	b.Write(make([]byte, uixPad(len(name))))
	b.Write(data)
	b.Write(make([]byte, uixPad(len(data))))
	c.conn.SetDeadline(time.Now().Add(5 * time.Second))
	defer c.conn.SetDeadline(time.Time{})
	if _, err := c.conn.Write(b.Bytes()); err != nil {
		return err
	}
	head := make([]byte, 8)
	if _, err := io.ReadFull(c.conn, head); err != nil {
		return err
	}
	body := make([]byte, int(uixLE.Uint16(head[6:]))*4)
	if _, err := io.ReadFull(c.conn, body); err != nil {
		return err
	}
	if head[0] != 1 {
		return errors.New("the display refused the connection")
	}
	if len(body) < 32 {
		return errors.New("short setup")
	}
	c.idBase = uixLE.Uint32(body[4:])
	mask := uixLE.Uint32(body[8:])
	c.idInc = mask & -mask
	vendor := int(uixLE.Uint16(body[16:]))
	c.maxLen = int(uixLE.Uint16(body[18:])) * 4
	screens := int(body[20])
	formats := int(body[21])
	c.msbPix = body[22] == 1
	c.minCode, c.maxCode = body[26], body[27]
	at := 32 + vendor + uixPad(vendor)
	bpp := map[byte]byte{}
	for i := 0; i < formats && at+8 <= len(body); i++ {
		bpp[body[at]] = body[at+1]
		at += 8
	}
	for s := 0; s < screens && at+40 <= len(body); s++ {
		sc := uixScreen{
			root:   uixLE.Uint32(body[at:]),
			width:  int(uixLE.Uint16(body[at+20:])),
			height: int(uixLE.Uint16(body[at+22:])),
			visual: uixLE.Uint32(body[at+32:]),
			depth:  body[at+38],
		}
		depths := int(body[at+39])
		at += 40
		trueColour := false
		for d := 0; d < depths && at+8 <= len(body); d++ {
			depth := body[at]
			visuals := int(uixLE.Uint16(body[at+2:]))
			at += 8
			for v := 0; v < visuals && at+24 <= len(body); v++ {
				if uixLE.Uint32(body[at:]) == sc.visual && depth == sc.depth && body[at+4] == 4 &&
					uixLE.Uint32(body[at+8:]) == 0xff0000 && uixLE.Uint32(body[at+12:]) == 0xff00 && uixLE.Uint32(body[at+16:]) == 0xff {
					trueColour = true
				}
				at += 24
			}
		}
		if s == screenIndex || (s == screens-1 && c.screen.root == 0) {
			if !trueColour || bpp[sc.depth] != 32 {
				return errors.New("the display has no 32-bit true-colour visual")
			}
			c.screen = sc
		}
	}
	if c.screen.root == 0 {
		return errors.New("no screen")
	}
	return nil
}

func (c *uixConn) read() {
	r := bufio.NewReaderSize(c.conn, 1<<16)
	for {
		head := make([]byte, 32)
		if _, err := io.ReadFull(r, head); err != nil {
			close(c.dead)
			return
		}
		switch head[0] {
		case 0:
			select {
			case c.replies <- uixReply{seq: uixLE.Uint16(head[2:]), data: head, failed: true}:
			default:
			}
		case 1:
			full := make([]byte, 32+int(uixLE.Uint32(head[4:]))*4)
			copy(full, head)
			if _, err := io.ReadFull(r, full[32:]); err != nil {
				close(c.dead)
				return
			}
			select {
			case c.replies <- uixReply{seq: uixLE.Uint16(head[2:]), data: full}:
			case <-time.After(5 * time.Second):
			}
		default:
			if head[0]&0x7f == 35 {
				if _, err := io.CopyN(io.Discard, r, int64(uixLE.Uint32(head[4:]))*4); err != nil {
					close(c.dead)
					return
				}
				continue
			}
			c.mu.Lock()
			c.queue = append(c.queue, head)
			c.mu.Unlock()
			select {
			case c.ready <- struct{}{}:
			default:
			}
		}
	}
}

func (c *uixConn) next() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.queue) == 0 {
		return nil
	}
	ev := c.queue[0]
	c.queue = c.queue[1:]
	return ev
}

func (c *uixConn) take(match func(ev []byte) bool) []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, ev := range c.queue {
		if match(ev) {
			c.queue = append(c.queue[:i:i], c.queue[i+1:]...)
			return ev
		}
	}
	return nil
}

func (c *uixConn) id() uint32 {
	c.idNext += c.idInc
	return c.idBase | c.idNext
}

type uixReq struct{ b []byte }

func uixRequest(op, data byte) *uixReq { return &uixReq{b: []byte{op, data, 0, 0}} }

func (q *uixReq) u8(v byte) *uixReq    { q.b = append(q.b, v); return q }
func (q *uixReq) u16(v int) *uixReq    { q.b = uixLE.AppendUint16(q.b, uint16(v)); return q }
func (q *uixReq) u32(v uint32) *uixReq { q.b = uixLE.AppendUint32(q.b, v); return q }

func (q *uixReq) raw(p []byte) *uixReq {
	q.b = append(q.b, p...)
	q.b = append(q.b, make([]byte, uixPad(len(p)))...)
	return q
}

func (c *uixConn) send(q *uixReq) uint16 {
	q.b = append(q.b, make([]byte, uixPad(len(q.b)))...)
	uixLE.PutUint16(q.b[2:], uint16(len(q.b)/4))
	c.seq++
	c.out.Write(q.b)
	return c.seq
}

func (c *uixConn) flush() { c.out.Flush() }

func (c *uixConn) call(q *uixReq) ([]byte, bool) {
	seq := c.send(q)
	c.flush()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case r := <-c.replies:
			if r.seq == seq {
				return r.data, !r.failed
			}
		case <-c.dead:
			return nil, false
		case <-deadline:
			return nil, false
		}
	}
}

func (c *uixConn) atom(name string) uint32 {
	reply, ok := c.call(uixRequest(16, 0).u16(len(name)).u16(0).raw([]byte(name)))
	if !ok {
		return 0
	}
	return uixLE.Uint32(reply[8:])
}

func (c *uixConn) property(win, prop, kind uint32, format byte, data []byte) {
	count := len(data)
	if format == 32 {
		count /= 4
	}
	c.send(uixRequest(18, 0).u32(win).u32(prop).u32(kind).u8(format).u8(0).u16(0).u32(uint32(count)).raw(data))
}

func (c *uixConn) getProperty(win, prop uint32, remove bool) []byte {
	del := byte(0)
	if remove {
		del = 1
	}
	reply, ok := c.call(uixRequest(20, del).u32(win).u32(prop).u32(0).u32(0).u32(1 << 22))
	if !ok || len(reply) < 32 {
		return nil
	}
	format := int(reply[1])
	count := int(uixLE.Uint32(reply[16:]))
	size := count * max(format/8, 1)
	if 32+size > len(reply) {
		return nil
	}
	return reply[32 : 32+size]
}

const (
	uixEventMask = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x8000 | 0x20000 | 0x200000 | 0x400000

	uixAtomAtom     = 4
	uixAtomCardinal = 6
	uixAtomString   = 31
	uixAtomWmName   = 39
	uixAtomWmHints  = 35
	uixAtomWmClass  = 67
	uixAtomResource = 23
)

type uixWindow struct {
	n       *uiNative
	c       *uixConn
	fonts   *uixFonts
	win, gc uint32
	w, h    int
	scale   float64
	frame   []uint32
	sent    []uint32
	wire    []byte
	canvas  *uiCanvas
	dirty   bool
	moved   bool
	exposed [4]int

	focused  bool
	shape    string
	cursors  map[string]uint32
	keymap   []uint32
	per      int
	level3   uint16
	numLock  uint16
	dead     rune
	stamp    uint32
	clip     string
	owned    bool
	atoms    map[string]uint32
	woke     chan struct{}
	themed   chan bool
	styledAt time.Time
	gone     sync.Once

	inbox    chan func()
	ime      *uixIME
	a11y     *uixA11y
	a11yAt   string
	origin   [2]int
	originOK bool
	title    string
	told     time.Time
	tell     <-chan time.Time

	beat     *time.Ticker
	beats    <-chan time.Time
	grabbed  bool
	lastX    float64
	lastY    float64
	lifting  bool
	lifted   byte
	liftedAt uint32
	liftedAs string
	padFiles [4]*uixPadFile
	padBeat  int
}

func (w *uixWindow) show(v UiView) {
	if w.n.publish(v) {
		w.poke()
	}
}

func (w *uixWindow) poke() {
	select {
	case w.woke <- struct{}{}:
	default:
	}
}

func (w *uixWindow) last() UiView { return w.n.latest() }

func (w *uixWindow) open(title string, addr SyslinkAddress) bool {
	if uiStageReady != nil && !uiStageReady() {
		return false
	}
	w.n.addr = addr
	fonts := uixSystemFonts()
	if fonts == nil {
		return false
	}
	c, err := uixDial()
	if err != nil {
		return false
	}
	w.c, w.fonts = c, fonts
	if !w.create(title) {
		c.conn.Close()
		return false
	}
	Hold()
	go w.run()
	return true
}

func (w *uixWindow) create(title string) bool {
	c := w.c
	w.atoms = map[string]uint32{}
	for _, name := range []string{"WM_PROTOCOLS", "WM_DELETE_WINDOW", "_NET_WM_NAME", "UTF8_STRING", "_NET_WM_PID",
		"_NET_WM_ICON", "CLIPBOARD", "TARGETS", "TEXT", "HIVE_CLIPBOARD", "_NET_WM_WINDOW_TYPE", "_NET_WM_WINDOW_TYPE_NORMAL"} {
		w.atoms[name] = c.atom(name)
		if w.atoms[name] == 0 {
			return false
		}
	}
	w.scale = w.dpiScale()
	w.n.dev = w
	w.n.theme(uixDark())
	w.styledAt = time.Now()
	w.loadKeymap()
	w.w = min(int(math.Round(1100*w.scale)), max(c.screen.width-40, 320))
	w.h = min(int(math.Round(780*w.scale)), max(c.screen.height-80, 240))
	w.win = c.id()
	c.send(uixRequest(1, c.screen.depth).u32(w.win).u32(c.screen.root).u16(0).u16(0).u16(w.w).u16(w.h).u16(0).u16(1).
		u32(c.screen.visual).u32(0x2 | 0x8 | 0x10 | 0x800).u32(uiPack(w.n.pal.bg) & 0xffffff).u32(0).u32(1).u32(uixEventMask))
	w.gc = c.id()
	c.send(uixRequest(55, 0).u32(w.gc).u32(w.win).u32(0x10000).u32(0))
	w.cursors = map[string]uint32{}
	font := c.id()
	c.send(uixRequest(45, 0).u32(font).u16(6).u16(0).raw([]byte("cursor")))
	for shape, glyph := range map[string]int{"arrow": 68, "text": 152, "hand": 60, "resize": 116, "cols": 108} {
		id := c.id()
		c.send(uixRequest(94, 0).u32(id).u32(font).u32(font).u16(glyph).u16(glyph + 1).
			u16(0).u16(0).u16(0).u16(0xffff).u16(0xffff).u16(0xffff))
		w.cursors[shape] = id
	}
	blank, ink, none := c.id(), c.id(), c.id()
	c.send(uixRequest(53, 1).u32(blank).u32(w.win).u16(1).u16(1))
	c.send(uixRequest(55, 0).u32(ink).u32(blank).u32(0x4).u32(0))
	c.send(uixRequest(70, 0).u32(blank).u32(ink).u16(0).u16(0).u16(1).u16(1))
	c.send(uixRequest(93, 0).u32(none).u32(blank).u32(blank).u16(0).u16(0).u16(0).u16(0).u16(0).u16(0).u16(0).u16(0))
	w.cursors["none"] = none
	w.shape = "arrow"
	w.setCursor("arrow")
	w.retitle(title)
	app := uiAppName()
	c.property(w.win, uixAtomWmClass, uixAtomString, 8, []byte(app+"\x00"+app+"\x00"))
	c.property(w.win, w.atoms["_NET_WM_PID"], uixAtomCardinal, 32, uixLE.AppendUint32(nil, uint32(os.Getpid())))
	c.property(w.win, w.atoms["WM_PROTOCOLS"], uixAtomAtom, 32, uixLE.AppendUint32(nil, w.atoms["WM_DELETE_WINDOW"]))
	c.property(w.win, w.atoms["_NET_WM_WINDOW_TYPE"], uixAtomAtom, 32, uixLE.AppendUint32(nil, w.atoms["_NET_WM_WINDOW_TYPE_NORMAL"]))
	hints := uixLE.AppendUint32(nil, 1)
	hints = uixLE.AppendUint32(hints, 1)
	c.property(w.win, uixAtomWmHints, uixAtomWmHints, 32, append(hints, make([]byte, 28)...))
	c.property(w.win, w.atoms["_NET_WM_ICON"], uixAtomCardinal, 32, uixIcon())
	w.n.wake = w.poke
	w.n.adopt()
	if first := uiTitleOf(w.n.latest()); first != "" && first != w.title {
		w.retitle(first)
	}
	c.send(uixRequest(8, 0).u32(w.win))
	c.flush()
	if at := c.atom("AT_SPI_BUS"); at != 0 {
		w.a11yAt = string(c.getProperty(c.screen.root, at, false))
	}
	go uixConnectIME(w)
	go uixConnectA11y(w, w.a11yAt)
	return true
}

func (w *uixWindow) post(f func()) {
	select {
	case w.inbox <- f:
	case <-w.c.dead:
	}
}

func (w *uixWindow) do(f func()) bool {
	done := make(chan struct{})
	select {
	case w.inbox <- func() { f(); close(done) }:
	case <-time.After(2 * time.Second):
		return false
	}
	select {
	case <-done:
		return true
	case <-time.After(2 * time.Second):
		return false
	}
}

func (w *uixWindow) originOnRoot() (int, int) {
	if !w.originOK {
		reply, ok := w.c.call(uixRequest(40, 0).u32(w.win).u32(w.c.screen.root).u16(0).u16(0))
		if ok && len(reply) >= 16 {
			w.origin = [2]int{int(int16(uixLE.Uint16(reply[12:]))), int(int16(uixLE.Uint16(reply[14:])))}
			w.originOK = true
		}
	}
	return w.origin[0], w.origin[1]
}

func (w *uixWindow) sync() {
	n := w.n
	if ime := w.ime; ime != nil {
		typing := w.focused && n.typing()
		ime.focus(typing)
		if x, y, ok := n.caretSpot(); typing && ok {
			ox, oy := w.originOnRoot()
			tall := int32(20 * w.scale)
			if b := n.boxes[n.focus]; b != nil {
				tall = int32(b.lineH * w.scale)
			}
			ime.place(int32(x+ox), int32(y+oy), tall)
		}
	}
	if w.a11y != nil && w.tell == nil {
		if wait := 100*time.Millisecond - time.Since(w.told); wait > 0 {
			w.tell = time.After(wait)
		} else {
			w.told = time.Now()
			w.a11y.notice()
		}
	}
}

func (w *uixWindow) retitle(title string) {
	w.title = title
	latin := make([]byte, 0, len(title))
	for _, r := range title {
		if r > 0xff {
			r = '?'
		}
		latin = append(latin, byte(r))
	}
	w.c.property(w.win, uixAtomWmName, uixAtomString, 8, latin)
	w.c.property(w.win, w.atoms["_NET_WM_NAME"], w.atoms["UTF8_STRING"], 8, []byte(title))
}

func (w *uixWindow) dpiScale() float64 {
	scale := 1.0
	for _, line := range strings.Split(string(w.c.getProperty(w.c.screen.root, uixAtomResource, false)), "\n") {
		if name, value, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(name) == "Xft.dpi" {
			if dpi, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err == nil && dpi >= 48 && dpi <= 480 {
				scale = dpi / 96
			}
		}
	}
	if g, err := strconv.Atoi(os.Getenv("GDK_SCALE")); err == nil && g >= 1 && g <= 4 {
		scale *= float64(g)
	}
	return scale
}

func uixDark() bool {
	if theme := strings.ToLower(os.Getenv("GTK_THEME")); theme != "" {
		return strings.Contains(theme, "dark")
	}
	if dark, known := uixPortalDark(); known {
		return dark
	}
	run := func(name string, args ...string) string {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, name, args...).Output()
		if err != nil {
			return ""
		}
		return strings.ToLower(strings.TrimSpace(string(out)))
	}
	ask := func(key string) string {
		if _, err := exec.LookPath("gsettings"); err == nil {
			return run("gsettings", "get", "org.gnome.desktop.interface", key)
		}
		if _, err := exec.LookPath("dconf"); err == nil {
			return run("dconf", "read", "/org/gnome/desktop/interface/"+key)
		}
		return ""
	}
	switch ask("color-scheme") {
	case "'prefer-dark'":
		return true
	case "'prefer-light'":
		return false
	}
	return strings.Contains(ask("gtk-theme"), "dark")
}

func uixPortalDark() (bool, bool) {
	address := os.Getenv("DBUS_SESSION_BUS_ADDRESS")
	if address == "" {
		return false, false
	}
	bus, err := uixBusDial(address, nil)
	if err != nil {
		return false, false
	}
	defer bus.close()
	const dest, path, iface = "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings"
	reply, err := bus.callWithin(time.Second, dest, path, iface, "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme")
	if err != nil {
		reply, err = bus.callWithin(time.Second, dest, path, iface, "Read", "ss", "org.freedesktop.appearance", "color-scheme")
	}
	if err != nil || len(reply) == 0 {
		return false, false
	}
	v := reply[0]
	for {
		inner, ok := v.(uixVariant)
		if !ok {
			break
		}
		v = inner.v
	}
	switch uixNumber(v) {
	case 1:
		return true, true
	case 2:
		return false, true
	}
	return false, false
}

func uixIcon() []byte {
	var out []byte
	add := func(side int, at func(x, y int) uint32) {
		out = uixLE.AppendUint32(out, uint32(side))
		out = uixLE.AppendUint32(out, uint32(side))
		for y := 0; y < side; y++ {
			for x := 0; x < side; x++ {
				out = uixLE.AppendUint32(out, at(x, y))
			}
		}
	}
	if len(uiWindowIcon) > 0 {
		if img, err := png.Decode(bytes.NewReader(uiWindowIcon)); err == nil {
			for _, side := range []int{128, 48, 32, 16} {
				add(side, uixSample(img, side))
			}
			return out
		}
	}
	corners := [][2]float64{{12, 1.5}, {21, 6.75}, {21, 17.25}, {12, 22.5}, {3, 17.25}, {3, 6.75}}
	inside := func(x, y float64) bool {
		for i := range corners {
			a, b := corners[i], corners[(i+1)%len(corners)]
			if (b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0]) < 0 {
				return false
			}
		}
		return true
	}
	for _, side := range []int{64, 32, 16} {
		scale := 24 / float64(side)
		add(side, func(x, y int) uint32 {
			hits := 0
			for sy := 0; sy < 4; sy++ {
				for sx := 0; sx < 4; sx++ {
					if inside((float64(x)+(float64(sx)+0.5)/4)*scale, (float64(y)+(float64(sy)+0.5)/4)*scale) {
						hits++
					}
				}
			}
			return uint32(hits*255/16)<<24 | 0xf0b429
		})
	}
	return out
}

func uixSample(img image.Image, side int) func(x, y int) uint32 {
	b := img.Bounds()
	return func(x, y int) uint32 {
		x0, x1 := b.Min.X+x*b.Dx()/side, b.Min.X+max((x+1)*b.Dx()/side, x*b.Dx()/side+1)
		y0, y1 := b.Min.Y+y*b.Dy()/side, b.Min.Y+max((y+1)*b.Dy()/side, y*b.Dy()/side+1)
		var r, g, bl, a, count uint64
		for sy := y0; sy < y1; sy++ {
			for sx := x0; sx < x1; sx++ {
				pr, pg, pb, pa := img.At(sx, sy).RGBA()
				r, g, bl, a, count = r+uint64(pr), g+uint64(pg), bl+uint64(pb), a+uint64(pa), count+1
			}
		}
		if a == 0 {
			return 0
		}
		un := func(v uint64) uint32 { return uint32(min(v*255/a, 255)) }
		return uint32(a/count>>8)<<24 | un(r)<<16 | un(g)<<8 | un(bl)
	}
}

func (w *uixWindow) run() {
	blink := time.NewTicker(530 * time.Millisecond)
	defer blink.Stop()
	var frame <-chan time.Time
	w.dirty = true
	for {
		select {
		case <-w.c.ready:
			for ev := w.c.next(); ev != nil; ev = w.c.next() {
				if !w.handle(ev) {
					return
				}
			}
			w.letUp()
		case <-w.woke:
			w.n.adopt()
			if title := uiTitleOf(w.n.latest()); title != "" && title != w.title {
				w.retitle(title)
				w.c.flush()
			}
			if w.n.staged() {
				w.dirty = true
			}
		case <-w.beats:
			if w.n.stage != nil {
				w.n.stage.tick()
			}
		case f := <-w.inbox:
			f()
		case <-w.tell:
			w.tell = nil
		case dark := <-w.themed:
			w.n.theme(dark)
			w.dirty = true
		case <-blink.C:
			if w.n.typing() {
				w.n.blink = w.focused && !w.n.blink
				w.dirty = true
			}
		case <-frame:
			frame = nil
			w.moved = true
		case <-w.c.dead:
			w.closed()
			return
		}
		if w.dirty || w.moved {
			var area uiClip
			if !w.dirty {
				area = w.n.moving()
			}
			w.dirty, w.moved = false, false
			w.paint(area)
			if due := w.n.frameDue(); due > 0 {
				frame = time.After(due)
			}
		}
		if w.exposed[2] > 0 {
			w.put(w.sent, w.exposed[0], w.exposed[1], w.exposed[2], w.exposed[3])
			w.exposed = [4]int{}
		}
		w.sync()
		w.c.flush()
	}
}

func (w *uixWindow) handle(ev []byte) bool {
	n := w.n
	switch ev[0] & 0x7f {
	case 2, 3:
		w.stamp = uixLE.Uint32(ev[4:])
		if n.stage != nil && w.sceneKeyed(ev[1], uixLE.Uint16(ev[28:]), ev[0]&0x7f == 3) {
			break
		}
		w.keyEvent(ev[1], uixLE.Uint16(ev[28:]), ev[0]&0x7f == 3)
	case 4, 5:
		w.stamp = uixLE.Uint32(ev[4:])
		x, y := float64(int16(uixLE.Uint16(ev[24:]))), float64(int16(uixLE.Uint16(ev[26:])))
		state := uixLE.Uint16(ev[28:])
		if button := int(ev[1]); n.stage != nil && button <= 3 {
			if ev[0]&0x7f == 4 && n.stage.press(button, x/w.scale, y/w.scale) {
				break
			}
			if ev[0]&0x7f == 5 && n.stage.lift(button) {
				break
			}
		}
		switch button := ev[1]; {
		case button == 1 && ev[0]&0x7f == 4:
			n.ctrl = state&4 != 0
			w.dirty = n.down(x, y) || w.dirty
		case button == 2 && ev[0]&0x7f == 4:
			w.dirty = n.middle(x, y) || w.dirty
		case button == 1:
			w.dirty = n.up(x, y) || w.dirty
		case button == 3 && ev[0]&0x7f == 4:
			w.dirty = n.menu(x, y) || w.dirty
		case button >= 4 && button <= 7 && ev[0]&0x7f == 4:
			lines := 1.0
			if button == 5 || button == 7 {
				lines = -1
			}
			w.dirty = n.wheel(x, y, lines, button >= 6 || state&1 != 0) || w.dirty
		}
	case 6, 7:
		x, y := float64(int16(uixLE.Uint16(ev[24:]))), float64(int16(uixLE.Uint16(ev[26:])))
		dx, dy := x-w.lastX, y-w.lastY
		w.lastX, w.lastY = x, y
		if w.grabbed {
			// The server queues what the mouse did before a warp lands, so a move is
			// measured from the event before it, and the warp's own landing is no move.
			if x == float64(w.w/2) && y == float64(w.h/2) {
				break
			}
			if (dx != 0 || dy != 0) && n.stage != nil {
				n.stage.looked(dx/w.scale, dy/w.scale)
			}
			w.recentre()
			break
		}
		if n.stage != nil {
			n.stage.drag(x/w.scale, y/w.scale)
		}
		n.ctrl = uixLE.Uint16(ev[28:])&4 != 0
		w.dirty = n.move(x, y) || w.dirty
		w.setCursor(n.cursor(x, y))
	case 8:
		w.dirty = n.leave() || w.dirty
	case 9:
		if ev[1] != 5 && ev[1] != 7 {
			w.focused = true
			n.blink = true
			w.dirty = true
			if time.Since(w.styledAt) > 2*time.Second {
				w.styledAt = time.Now()
				go func() {
					dark := uixDark()
					select {
					case w.themed <- dark:
					default:
					}
				}()
			}
		}
	case 10:
		if ev[1] != 2 && ev[1] != 5 && ev[1] != 7 {
			w.letUp()
			if n.stage != nil {
				n.stage.blur()
			}
			w.focused = false
			n.blink = false
			n.unfocused()
			w.dirty = true
		}
	case 12:
		x, y := int(uixLE.Uint16(ev[8:])), int(uixLE.Uint16(ev[10:]))
		ew, eh := int(uixLE.Uint16(ev[12:])), int(uixLE.Uint16(ev[14:]))
		if w.sent == nil || len(w.sent) != w.w*w.h {
			w.dirty = true
		} else if w.exposed[2] == 0 {
			w.exposed = [4]int{x, y, ew, eh}
		} else {
			x0, y0 := min(x, w.exposed[0]), min(y, w.exposed[1])
			x1, y1 := max(x+ew, w.exposed[0]+w.exposed[2]), max(y+eh, w.exposed[1]+w.exposed[3])
			w.exposed = [4]int{x0, y0, x1 - x0, y1 - y0}
		}
	case 22:
		if uixLE.Uint32(ev[8:]) == w.win {
			nw, nh := int(uixLE.Uint16(ev[20:])), int(uixLE.Uint16(ev[22:]))
			w.originOK = false
			if nw != w.w || nh != w.h {
				w.w, w.h = nw, nh
				w.dirty = true
			}
		}
	case 29:
		if uixLE.Uint32(ev[12:]) == w.atoms["CLIPBOARD"] {
			w.owned = false
		}
	case 30:
		w.answer(ev)
	case 33:
		if uixLE.Uint32(ev[8:]) == w.atoms["WM_PROTOCOLS"] && uixLE.Uint32(ev[12:]) == w.atoms["WM_DELETE_WINDOW"] {
			w.closed()
			return false
		}
	case 34:
		if ev[4] != 2 {
			w.loadKeymap()
		}
	}
	return true
}

func (w *uixWindow) setCursor(shape string) {
	if shape == w.shape && w.shape != "" {
		return
	}
	id, ok := w.cursors[shape]
	if !ok {
		id = w.cursors["arrow"]
	}
	w.shape = shape
	w.c.send(uixRequest(2, 0).u32(w.win).u32(0x4000).u32(id))
}

func (w *uixWindow) paint(area uiClip) {
	if w.w <= 0 || w.h <= 0 {
		return
	}
	if len(w.frame) != w.w*w.h {
		w.frame = make([]uint32, w.w*w.h)
		w.sent = nil
	}
	w.n.resize(float64(w.w)/w.scale, float64(w.h)/w.scale, w.scale)
	if w.sent == nil {
		area = uiClip{}
	}
	w.canvas = &uiCanvas{pix: w.frame, w: w.w, h: w.h, flush: func() {}, dirty: area}
	w.n.paint(w.canvas)
	w.canvas = nil
	if w.sent == nil {
		w.sent = make([]uint32, len(w.frame))
		copy(w.sent, w.frame)
		w.put(w.sent, 0, 0, w.w, w.h)
		return
	}
	span := uiClip{0, 0, w.w, w.h}
	if !area.empty() {
		span = span.and(area)
	}
	x0, y0, x1, y1 := w.w, w.h, -1, -1
	for y := span.y0; y < span.y1; y++ {
		now, was := w.frame[y*w.w+span.x0:y*w.w+span.x1], w.sent[y*w.w+span.x0:y*w.w+span.x1]
		first := -1
		for x := range now {
			if now[x] != was[x] {
				first = x
				break
			}
		}
		if first < 0 {
			continue
		}
		last := first
		for x := len(now) - 1; x > first; x-- {
			if now[x] != was[x] {
				last = x
				break
			}
		}
		copy(was[first:last+1], now[first:last+1])
		x0, x1 = min(x0, span.x0+first), max(x1, span.x0+last)
		y0, y1 = min(y0, y), max(y1, y)
	}
	if x1 >= 0 {
		w.put(w.sent, x0, y0, x1-x0+1, y1-y0+1)
	}
}

func (w *uixWindow) put(pix []uint32, x, y, rw, rh int) {
	x, y = max(x, 0), max(y, 0)
	rw, rh = min(rw, w.w-x), min(rh, w.h-y)
	if rw <= 0 || rh <= 0 || len(pix) != w.w*w.h {
		return
	}
	rows := max(1, (w.c.maxLen-24)/(rw*4))
	for top := y; top < y+rh; top += rows {
		count := min(rows, y+rh-top)
		need := rw * count * 4
		if cap(w.wire) < need {
			w.wire = make([]byte, need)
		}
		data := w.wire[:need]
		at := 0
		for row := top; row < top+count; row++ {
			for _, p := range pix[row*w.w+x : row*w.w+x+rw] {
				if w.c.msbPix {
					binary.BigEndian.PutUint32(data[at:], p)
				} else {
					uixLE.PutUint32(data[at:], p)
				}
				at += 4
			}
		}
		w.c.send(uixRequest(72, 2).u32(w.win).u32(w.gc).u16(rw).u16(count).u16(x).u16(top).u8(0).u8(w.c.screen.depth).u16(0).raw(data))
	}
}

func (w *uixWindow) loadKeymap() {
	c := w.c
	count := int(c.maxCode) - int(c.minCode) + 1
	reply, ok := c.call(uixRequest(101, 0).u8(c.minCode).u8(byte(count)).u16(0))
	if !ok {
		return
	}
	w.per = int(reply[1])
	w.keymap = make([]uint32, (len(reply)-32)/4)
	for i := range w.keymap {
		w.keymap[i] = uixLE.Uint32(reply[32+4*i:])
	}
	w.level3, w.numLock = 0x80, 0x10
	if mods, ok := c.call(uixRequest(119, 0)); ok && w.per > 0 {
		per := int(mods[1])
		for m := 0; m < 8; m++ {
			for k := 0; k < per && 32+m*per+k < len(mods); k++ {
				code := int(mods[32+m*per+k])
				at := (code - int(c.minCode)) * w.per
				if code == 0 || at < 0 || at >= len(w.keymap) {
					continue
				}
				switch w.keymap[at] {
				case 0xfe03, 0xff7e:
					w.level3 = 1 << m
				case 0xff7f:
					w.numLock = 1 << m
				}
			}
		}
	}
}

func uixCase(sym uint32) (uint32, uint32) {
	switch {
	case sym >= 'a' && sym <= 'z', sym >= 0xe0 && sym <= 0xfe && sym != 0xf7:
		return sym, sym - 0x20
	case sym >= 'A' && sym <= 'Z', sym >= 0xc0 && sym <= 0xde && sym != 0xd7:
		return sym + 0x20, sym
	case sym >= 0x01000100 && sym <= 0x0110ffff:
		r := rune(sym - 0x01000000)
		return uint32(unicode.ToLower(r)) + 0x01000000, uint32(unicode.ToUpper(r)) + 0x01000000
	}
	return sym, sym
}

func (w *uixWindow) keysym(code byte, state uint16) uint32 {
	at := (int(code) - int(w.c.minCode)) * w.per
	if w.per == 0 || at < 0 || at+w.per > len(w.keymap) {
		return 0
	}
	syms := w.keymap[at : at+w.per]
	col := 0
	if state&w.level3 != 0 && len(syms) > 4 && syms[4] != 0 {
		col = 4
	}
	lower, upper := syms[col], uint32(0)
	if col+1 < len(syms) {
		upper = syms[col+1]
	}
	if upper == 0 {
		lower, upper = uixCase(lower)
	}
	shift := state&1 != 0
	keypad := upper >= 0xff80 && upper <= 0xffbd
	if keypad && state&w.numLock != 0 {
		shift = !shift
	} else if l, u := uixCase(lower); state&2 != 0 && l != u && u == upper {
		shift = !shift
	}
	if shift {
		return upper
	}
	return lower
}

var uixKeys = map[uint32]uiKey{
	0xff08: uiKeyBack, 0xff09: uiKeyTab, 0xfe20: uiKeyTab, 0xff0d: uiKeyEnter, 0xff8d: uiKeyEnter,
	0xff1b: uiKeyEscape, 0xffff: uiKeyDelete, 0xff9f: uiKeyDelete,
	0xff50: uiKeyHome, 0xff95: uiKeyHome, 0xff57: uiKeyEnd, 0xff9c: uiKeyEnd,
	0xff51: uiKeyLeft, 0xff96: uiKeyLeft, 0xff53: uiKeyRight, 0xff98: uiKeyRight,
	0xff52: uiKeyUp, 0xff97: uiKeyUp, 0xff54: uiKeyDown, 0xff99: uiKeyDown,
	0xff55: uiKeyPageUp, 0xff9a: uiKeyPageUp, 0xff56: uiKeyPageDown, 0xff9b: uiKeyPageDown,
}

const uixGrave = rune(96)

var uixDeadKeys = map[uint32]rune{0xfe50: uixGrave, 0xfe51: '´', 0xfe52: '^', 0xfe53: '~', 0xfe57: '¨', 0xfe5b: '¸'}

var uixComposed = map[rune][2]string{
	uixGrave: {"aeiouAEIOU", "àèìòùÀÈÌÒÙ"},
	'´':      {"aeiouyAEIOUYcC", "áéíóúýÁÉÍÓÚÝçÇ"},
	'^':      {"aeiouAEIOU", "âêîôûÂÊÎÔÛ"},
	'~':      {"aonAON", "ãõñÃÕÑ"},
	'¨':      {"aeiouyAEIOUY", "äëïöüÿÄËÏÖÜŸ"},
	'¸':      {"cC", "çÇ"},
}

var uixSpacing = map[rune]rune{uixGrave: uixGrave, '´': '\'', '^': '^', '~': '~', '¨': '"', '¸': '¸'}

func uixCompose(accent, base rune) (rune, bool) {
	pair := uixComposed[accent]
	from, to := []rune(pair[0]), []rune(pair[1])
	for i, r := range from {
		if r == base {
			return to[i], true
		}
	}
	return 0, false
}

func uixRune(sym uint32) rune {
	switch {
	case sym >= 0x20 && sym <= 0x7e, sym >= 0xa0 && sym <= 0xff:
		return rune(sym)
	case sym >= 0x01000000 && sym <= 0x0110ffff:
		return rune(sym - 0x01000000)
	case sym >= 0xffb0 && sym <= 0xffb9:
		return rune('0' + sym - 0xffb0)
	case sym == 0x20ac:
		return '€'
	}
	switch sym {
	case 0xff80:
		return ' '
	case 0xffaa:
		return '*'
	case 0xffab:
		return '+'
	case 0xffac:
		return ','
	case 0xffad:
		return '-'
	case 0xffae:
		return '.'
	case 0xffaf:
		return '/'
	case 0xffbd:
		return '='
	case 0x13bc:
		return 'Œ'
	case 0x13bd:
		return 'œ'
	case 0x0ad0:
		return '‘'
	case 0x0ad1:
		return '’'
	case 0x0ad2:
		return '“'
	case 0x0ad3:
		return '”'
	case 0x0aa9:
		return '—'
	case 0x0aaa:
		return '–'
	case 0x0ae6:
		return '•'
	case 0x0aae:
		return '…'
	}
	return 0
}

func (w *uixWindow) keyEvent(code byte, state uint16, release bool) {
	sym := w.keysym(code, state)
	if sym == 0xffe3 || sym == 0xffe4 {
		w.dirty = w.n.setCtrl(!release) || w.dirty
		return
	}
	if ime := w.ime; ime != nil && ime.focused && w.n.typing() {
		if ime.key(sym, code, state, release, w.stamp) {
			return
		}
		if !release {
			w.pressed(sym, state, true)
		}
		return
	}
	if !release {
		w.pressed(sym, state, false)
	}
}

var uixNamed = map[uint32]string{
	0xff08: "Backspace", 0xff09: "Tab", 0xfe20: "Tab", 0xff0d: "Enter", 0xff8d: "Enter",
	0xff1b: "Escape", 0xffff: "Delete", 0xff9f: "Delete", 0xff63: "Insert", 0x20: "Space",
	0xff50: "Home", 0xff95: "Home", 0xff57: "End", 0xff9c: "End",
	0xff51: "ArrowLeft", 0xff96: "ArrowLeft", 0xff53: "ArrowRight", 0xff98: "ArrowRight",
	0xff52: "ArrowUp", 0xff97: "ArrowUp", 0xff54: "ArrowDown", 0xff99: "ArrowDown",
	0xff55: "PageUp", 0xff9a: "PageUp", 0xff56: "PageDown", 0xff9b: "PageDown",
}

func (w *uixWindow) named(sym uint32, shift, ctrl, alt bool) string {
	if name, ok := uixNamed[sym]; ok {
		return uiCombo(name, ctrl, shift, alt)
	}
	if sym >= 0xffbe && sym <= 0xffc9 {
		return uiCombo("F"+strconv.Itoa(int(sym-0xffbd)), ctrl, shift, alt)
	}
	r := uixRune(sym)
	if r == 0 {
		return ""
	}
	if !ctrl && !alt {
		return string(r)
	}
	return uiCombo(strings.ToUpper(string(r)), ctrl, shift, alt)
}

func (w *uixWindow) pressed(sym uint32, state uint16, composed bool) {
	n := w.n
	shift, ctrl, alt := state&1 != 0, state&4 != 0, state&8 != 0
	if _, dead := uixDeadKeys[sym]; !dead && w.dead == 0 && n.claim(w.named(sym, shift, ctrl, alt)) {
		w.dirty = true
		return
	}
	k, special := uixKeys[sym]
	if ctrl && !alt {
		switch l, _ := uixCase(sym); l {
		case 'a':
			k, special = uiKeyAll, true
		case 'c':
			k, special = uiKeyCopy, true
		case 'v':
			k, special = uiKeyPaste, true
		case 'x':
			k, special = uiKeyCut, true
		case 'y':
			k, special = uiKeyRedo, true
		case 'z':
			k, special = uiKeyUndo, true
			if shift {
				k = uiKeyRedo
			}
		}
	}
	switch {
	case sym == 0xff63 && shift:
		k, special = uiKeyPaste, true
	case sym == 0xff63 && ctrl:
		k, special = uiKeyCopy, true
	case sym == 0xffff && shift && !ctrl:
		k, special = uiKeyCut, true
	case sym == 0xff67, sym == 0xffc7 && shift:
		k, special = uiKeyMenu, true
	}
	if special {
		w.dead = 0
		if n.key(k, shift, ctrl) {
			w.dirty = true
		}
		return
	}
	if ctrl || alt {
		return
	}
	if accent, ok := uixDeadKeys[sym]; ok && !composed {
		if w.dead != 0 {
			w.typed(w.dead)
			if w.dead == accent {
				w.dead = 0
				return
			}
		}
		w.dead = accent
		return
	}
	r := uixRune(sym)
	if r == 0 {
		return
	}
	if w.dead != 0 {
		accent := w.dead
		w.dead = 0
		if composed, ok := uixCompose(accent, r); ok {
			w.typed(composed)
			return
		}
		if r == ' ' {
			w.typed(uixSpacing[accent])
			return
		}
		w.typed(accent)
	}
	w.typed(r)
}

func (w *uixWindow) typed(r rune) {
	if w.n.typed(r) {
		w.dirty = true
	}
}

func (w *uixWindow) setClipboard(s string) {
	w.clip = s
	w.c.send(uixRequest(22, 0).u32(w.win).u32(w.atoms["CLIPBOARD"]).u32(w.stamp))
	reply, ok := w.c.call(uixRequest(23, 0).u32(w.atoms["CLIPBOARD"]))
	w.owned = ok && uixLE.Uint32(reply[8:]) == w.win
}

func (w *uixWindow) clipboard() string {
	if w.owned {
		return w.clip
	}
	c := w.c
	target := w.atoms["UTF8_STRING"]
	for attempt := 0; attempt < 2; attempt++ {
		c.send(uixRequest(24, 0).u32(w.win).u32(w.atoms["CLIPBOARD"]).u32(target).u32(w.atoms["HIVE_CLIPBOARD"]).u32(w.stamp))
		c.flush()
		deadline := time.Now().Add(time.Second)
		var answer []byte
		for answer == nil && time.Now().Before(deadline) {
			answer = c.take(func(ev []byte) bool { return ev[0]&0x7f == 31 && uixLE.Uint32(ev[8:]) == w.win })
			if answer == nil {
				select {
				case <-c.ready:
				case <-c.dead:
					return ""
				case <-time.After(20 * time.Millisecond):
				}
			}
		}
		select {
		case c.ready <- struct{}{}:
		default:
		}
		if answer == nil {
			return ""
		}
		if uixLE.Uint32(answer[20:]) != 0 {
			data := c.getProperty(w.win, w.atoms["HIVE_CLIPBOARD"], true)
			if target == uixAtomString {
				runes := make([]rune, len(data))
				for i, b := range data {
					runes[i] = rune(b)
				}
				return string(runes)
			}
			return string(data)
		}
		target = uixAtomString
	}
	return ""
}

func (w *uixWindow) answer(ev []byte) {
	c := w.c
	stamp, requestor := uixLE.Uint32(ev[4:]), uixLE.Uint32(ev[12:])
	selection, target, prop := uixLE.Uint32(ev[16:]), uixLE.Uint32(ev[20:]), uixLE.Uint32(ev[24:])
	if prop == 0 {
		prop = target
	}
	switch {
	case !w.owned || selection != w.atoms["CLIPBOARD"]:
		prop = 0
	case target == w.atoms["TARGETS"]:
		var list []byte
		for _, a := range []uint32{w.atoms["TARGETS"], w.atoms["UTF8_STRING"], uixAtomString, w.atoms["TEXT"]} {
			list = uixLE.AppendUint32(list, a)
		}
		c.property(requestor, prop, uixAtomAtom, 32, list)
	case target == w.atoms["UTF8_STRING"] || target == w.atoms["TEXT"]:
		c.property(requestor, prop, w.atoms["UTF8_STRING"], 8, []byte(w.clip))
	case target == uixAtomString:
		latin := make([]byte, 0, len(w.clip))
		for _, r := range w.clip {
			if r > 0xff {
				r = '?'
			}
			latin = append(latin, byte(r))
		}
		c.property(requestor, prop, uixAtomString, 8, latin)
	default:
		prop = 0
	}
	notice := make([]byte, 32)
	notice[0] = 31
	uixLE.PutUint32(notice[4:], stamp)
	uixLE.PutUint32(notice[8:], requestor)
	uixLE.PutUint32(notice[12:], selection)
	uixLE.PutUint32(notice[16:], target)
	uixLE.PutUint32(notice[20:], prop)
	c.send(uixRequest(25, 0).u32(requestor).u32(0).raw(notice))
}

func (w *uixWindow) openLink(href string) {
	exec.Command("xdg-open", href).Start()
}

func (w *uixWindow) datePattern() string {
	locale := ""
	for _, name := range []string{"LC_ALL", "LC_TIME", "LANG"} {
		if v := os.Getenv(name); v != "" {
			locale = v
			break
		}
	}
	lang, region, _ := strings.Cut(strings.SplitN(locale, ".", 2)[0], "_")
	switch {
	case lang == "" || lang == "C" || lang == "POSIX":
		return "MM/dd/yyyy"
	case lang == "en" && (region == "US" || region == "PH" || region == ""):
		return "MM/dd/yyyy"
	case lang == "en" && region == "CA", lang == "sv", lang == "lt", lang == "fr" && region == "CA":
		return "yyyy-MM-dd"
	case lang == "zh" || lang == "ja":
		return "yyyy/MM/dd"
	case lang == "ko":
		return "yyyy. MM. dd."
	case lang == "hu":
		return "yyyy. MM. dd."
	case lang == "de" || lang == "ru" || lang == "pl" || lang == "cs" || lang == "fi" || lang == "nb" ||
		lang == "tr" || lang == "uk" || lang == "da" || lang == "ro" || lang == "sk":
		return "dd.MM.yyyy"
	case lang == "nl":
		return "dd-MM-yyyy"
	}
	return "dd/MM/yyyy"
}

func (w *uixWindow) measure(f uiFont, s string) float64 { return w.fonts.measure(f, s) }
func (w *uixWindow) tall(f uiFont) float64              { return w.fonts.tall(f) }
func (w *uixWindow) average(f uiFont) float64           { return w.fonts.average(f) }

func (w *uixWindow) text(f uiFont, x, y int, s string, c uiRGBA, clip uiClip) {
	if w.canvas != nil && s != "" && !clip.empty() {
		w.fonts.draw(w.canvas, f, f.px*w.scale, x, y, s, c, clip)
	}
}

var uixSceneKeys = map[uint32]string{
	0xff08: "backspace", 0xff09: "tab", 0xfe20: "tab", 0xff0d: "enter", 0xff8d: "enter", 0xff1b: "escape",
	0xffff: "delete", 0xff9f: "delete", 0xff63: "insert", 0x20: "space", 0xff50: "home", 0xff95: "home",
	0xff57: "end", 0xff9c: "end", 0xff51: "left", 0xff96: "left", 0xff53: "right", 0xff98: "right",
	0xff52: "up", 0xff97: "up", 0xff54: "down", 0xff99: "down", 0xff55: "pageup", 0xff9a: "pageup",
	0xff56: "pagedown", 0xff9b: "pagedown", 0xffe1: "shift", 0xffe2: "shift", 0xffe3: "ctrl", 0xffe4: "ctrl",
	0xffe9: "alt", 0xffea: "alt", 0xffeb: "meta", 0xffec: "meta", 0xffe5: "capslock", 0xff13: "pause",
	0xff7f: "numlock", 0xff14: "scrolllock", 0xff61: "printscreen", 0xff67: "contextmenu",
	0xffaa: "*", 0xffab: "+", 0xffad: "-", 0xffae: ".", 0xffaf: "/",
}

func (w *uixWindow) sceneKey(code byte, state uint16) string {
	sym := w.keysym(code, state&^1)
	if name, ok := uixSceneKeys[sym]; ok {
		return name
	}
	switch {
	case sym >= 0xffbe && sym <= 0xffd5:
		return "f" + strconv.Itoa(int(sym-0xffbd))
	case sym >= 0xffb0 && sym <= 0xffb9:
		return string(rune('0' + sym - 0xffb0))
	}
	if r := uixRune(sym); r > 0x20 {
		return strings.ToLower(string(r))
	}
	return ""
}

func (w *uixWindow) letUp() {
	if w.lifting {
		w.lifting = false
		if w.n.stage != nil {
			w.n.stage.key(w.liftedAs, false)
		}
	}
}

func (w *uixWindow) sceneKeyed(code byte, state uint16, release bool) bool {
	name := w.sceneKey(code, state)
	if release {
		w.letUp()
		w.lifting, w.lifted, w.liftedAt, w.liftedAs = true, code, w.stamp, name
		return false
	}
	if w.lifting && w.lifted == code && w.liftedAt == w.stamp {
		w.lifting = false
	} else {
		w.letUp()
	}
	return w.n.stage.key(name, true)
}

func (w *uixWindow) ticking(on bool) {
	if on == (w.beat != nil) {
		return
	}
	if !on {
		w.beat.Stop()
		w.beat, w.beats = nil, nil
		return
	}
	w.beat = time.NewTicker(time.Second / 60)
	w.beats = w.beat.C
}

func (w *uixWindow) recentre() {
	w.c.send(uixRequest(41, 0).u32(0).u32(w.win).u16(0).u16(0).u16(0).u16(0).u16(w.w / 2).u16(w.h / 2))
}

func (w *uixWindow) holding(on bool) {
	if on == w.grabbed {
		return
	}
	if !on {
		w.grabbed = false
		w.c.send(uixRequest(27, 0).u32(0))
		w.shape = ""
		return
	}
	reply, ok := w.c.call(uixRequest(26, 1).u32(w.win).u16(0x204C).u8(1).u8(1).u32(w.win).u32(w.cursors["none"]).u32(0))
	if !ok || len(reply) < 2 || reply[1] != 0 {
		return
	}
	w.grabbed = true
	w.recentre()
}

func (w *uixWindow) blot(f uiFont, s string) (int, int, []uint8) {
	wide := int(math.Ceil(w.fonts.measure(f, s) * w.scale))
	tall := int(math.Ceil(w.fonts.tall(f) * w.scale))
	if wide < 1 || tall < 1 {
		return 0, 0, nil
	}
	cv := &uiCanvas{pix: make([]uint32, wide*tall), w: wide, h: tall, flush: func() {}}
	for i := range cv.pix {
		cv.pix[i] = 0xff000000
	}
	w.fonts.draw(cv, f, f.px*w.scale, 0, 0, s, uiWhite, uiClip{0, 0, wide, tall})
	cover := make([]uint8, wide*tall)
	for i, p := range cv.pix {
		cover[i] = uint8(p >> 8)
	}
	return wide, tall, cover
}

type uixPadFile struct {
	fd      int
	axes    [16]float64
	buttons [32]float64
	axisN   int
	buttonN int
}

var uixPadLooseButtons = []string{"a", "b", "x", "y", "lb", "rb", "back", "start", "guide", "lstick", "rstick"}
var uixPadLooseAxes = []string{"leftX", "leftY", "lt", "rightX", "rightY", "rt", "dpadX", "dpadY"}
var uixPadButtons = []string{"a", "b", "x", "y", "lb", "rb", "lt", "rt", "back", "start", "lstick", "rstick",
	"up", "down", "left", "right", "guide"}
var uixPadAxes = []string{"leftX", "leftY", "rightX", "rightY"}

func uixPadName(names []string, at int, rest string) string {
	if at < len(names) {
		return names[at]
	}
	return rest + strconv.Itoa(at)
}

func (w *uixWindow) pads() map[int]uiGamepad {
	out := map[int]uiGamepad{}
	w.padBeat++
	for i := range w.padFiles {
		p := w.padFiles[i]
		if p == nil {
			if w.padBeat%60 != i*15 {
				continue
			}
			fd, err := syscall.Open("/dev/input/js"+strconv.Itoa(i), syscall.O_RDONLY|syscall.O_NONBLOCK, 0)
			if err != nil {
				continue
			}
			p = &uixPadFile{fd: fd}
			w.padFiles[i] = p
		}
		var ev [8]byte
		gone := false
		for {
			got, err := syscall.Read(p.fd, ev[:])
			if got == 8 {
				value, kind, at := float64(int16(uixLE.Uint16(ev[4:]))), ev[6]&^0x80, int(ev[7])
				switch {
				case kind == 1 && at < len(p.buttons):
					p.buttons[at] = value
					p.buttonN = max(p.buttonN, at+1)
				case kind == 2 && at < len(p.axes):
					p.axes[at] = math.Max(-1, value/32767)
					p.axisN = max(p.axisN, at+1)
				}
				continue
			}
			gone = err != nil && err != syscall.EAGAIN
			break
		}
		if gone {
			syscall.Close(p.fd)
			w.padFiles[i] = nil
			continue
		}
		wide := p.axisN >= 6 && p.buttonN <= 12
		c := map[string]float64{}
		for at := 0; at < p.buttonN; at++ {
			if wide {
				c[uixPadName(uixPadLooseButtons, at, "b")] = p.buttons[at]
			} else {
				c[uixPadName(uixPadButtons, at, "b")] = p.buttons[at]
			}
		}
		for at := 0; at < p.axisN; at++ {
			v := p.axes[at]
			name := uixPadName(uixPadAxes, at, "axis")
			if wide {
				name = uixPadName(uixPadLooseAxes, at, "axis")
			}
			switch name {
			case "lt", "rt":
				if v != 0 {
					v = uiClamp((v+1)/2, 0, 1)
				}
				c[name] = v
			case "dpadX":
				c["left"], c["right"] = 0, 0
				if v < -0.5 {
					c["left"] = 1
				}
				if v > 0.5 {
					c["right"] = 1
				}
			case "dpadY":
				c["up"], c["down"] = 0, 0
				if v < -0.5 {
					c["up"] = 1
				}
				if v > 0.5 {
					c["down"] = 1
				}
			default:
				c[name] = v
			}
		}
		out[i] = uiGamepad{controls: c}
	}
	return out
}

func (w *uixWindow) closed() {
	w.gone.Do(func() {
		if w.n.stage != nil {
			w.n.stage.close()
		}
		if w.ime != nil {
			w.ime.bus.close()
		}
		if w.a11y != nil {
			w.a11y.bus.close()
		}
		select {
		case <-w.c.dead:
		default:
			w.c.send(uixRequest(4, 0).u32(w.win))
			w.c.flush()
		}
		w.c.conn.Close()
		SyslinkKill(w.n.addr)
		if Release() == 0 {
			fmt.Fprintln(os.Stderr, "hive: the window was closed")
			os.Exit(0)
		}
	})
}
