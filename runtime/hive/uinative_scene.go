// A scene in a window the program draws: the engine it starts beside itself, the
// frames and the box it is sent, the picture read back, and what the player did.
// A paint waits for the picture a turn asked for, so that what is over the world
// and the world come from the same turn.
//
// What `hive.audio` wants played is played here too. The window listens to the
// same feed a page would, fetches each stream itself, and hands the engine its
// bytes; one that runs out is started again after a moment, as a page does.

//go:build windows || (linux && !android)

package hive

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/draw"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

func init() {
	uiStageMake = func(n *uiNative) uiStaging {
		s := &uiStage{n: n, held: map[string]bool{}, whole: true, tally: os.Getenv("HIVE_FOLDS") != ""}
		s.radio.watch()
		return s
	}
	uiStageReady = uiEngineProbe
}

type uiTuned struct {
	from string
	loud float64
}

type uiPlayed struct {
	uiTuned
	stop context.CancelFunc
}

type uiRadio struct {
	mu      sync.Mutex
	engine  *uiEngine
	wanted  map[string]uiTuned
	playing map[string]*uiPlayed
}

type uiRadioSaid struct {
	head  http.Header
	held  []byte
	radio *uiRadio
}

func (w *uiRadioSaid) Header() http.Header { return w.head }

func (w *uiRadioSaid) WriteHeader(int) {}

func (w *uiRadioSaid) Write(b []byte) (int, error) {
	w.held = append(w.held, b...)
	return len(b), nil
}

func (w *uiRadioSaid) Flush() {
	said := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(w.held)), "data:"))
	w.held = w.held[:0]
	var streams map[string]map[string]any
	if json.Unmarshal([]byte(said), &streams) != nil {
		return
	}
	wanted := map[string]uiTuned{}
	for name, stream := range streams {
		from, _ := stream["url"].(string)
		loud, _ := stream["volume"].(float64)
		wanted[name] = uiTuned{from, loud}
	}
	w.radio.mu.Lock()
	w.radio.wanted = wanted
	w.radio.settle()
	w.radio.mu.Unlock()
}

func (r *uiRadio) watch() {
	serve, ok := hivePageRoutes["/_hive/audio"].(func(http.ResponseWriter, *http.Request))
	if !ok {
		return
	}
	req, err := http.NewRequest("GET", "/_hive/audio", nil)
	if err != nil {
		return
	}
	go serve(&uiRadioSaid{head: http.Header{}, radio: r}, req)
}

func (r *uiRadio) onto(e *uiEngine) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for name, p := range r.playing {
		p.stop()
		delete(r.playing, name)
	}
	r.engine = e
	r.settle()
}

func (r *uiRadio) settle() {
	if r.engine == nil {
		return
	}
	if r.playing == nil {
		r.playing = map[string]*uiPlayed{}
	}
	for name, p := range r.playing {
		if want, ok := r.wanted[name]; !ok || want.from != p.from {
			p.stop()
			r.engine.stream(0, name, nil)
			delete(r.playing, name)
		}
	}
	for name, want := range r.wanted {
		p := r.playing[name]
		if p == nil {
			r.start(name, want)
		} else if p.loud != want.loud {
			p.loud = want.loud
			r.engine.stream(3, name, []byte{uiRadioLoud(want.loud)})
		}
	}
}

func (r *uiRadio) start(name string, want uiTuned) {
	ctx, stop := context.WithCancel(context.Background())
	r.playing[name] = &uiPlayed{want, stop}
	e := r.engine
	e.stream(1, name, []byte{uiRadioLoud(want.loud)})
	go func() {
		uiRadioFetch(ctx, want.from, func(part []byte) {
			if ctx.Err() == nil {
				e.stream(2, name, part)
			}
		})
		if ctx.Err() == nil {
			e.stream(2, name, nil)
		}
	}()
}

func (r *uiRadio) again(e *uiEngine, name string) {
	r.mu.Lock()
	was := r.playing[name]
	r.mu.Unlock()
	if was == nil {
		return
	}
	time.AfterFunc(2*time.Second, func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.engine != e || r.playing[name] != was {
			return
		}
		was.stop()
		delete(r.playing, name)
		r.settle()
	})
}

func uiRadioLoud(v float64) byte {
	return byte(math.Round(math.Max(0, math.Min(1, v)) * 255))
}

func uiRadioFetch(ctx context.Context, from string, feed func([]byte)) {
	if strings.HasPrefix(from, "/_hive/asset/") {
		path, err := url.PathUnescape(strings.TrimPrefix(from, "/_hive/asset/"))
		if err != nil {
			return
		}
		if body, ok := uiEngineRead(path); ok && len(body) > 0 {
			feed(body)
		}
		return
	}
	req, err := http.NewRequestWithContext(ctx, "GET", from, nil)
	if err != nil {
		return
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return
	}
	part := make([]byte, 16384)
	for {
		n, err := res.Body.Read(part)
		if n > 0 {
			feed(append([]byte(nil), part[:n]...))
		}
		if err != nil {
			return
		}
	}
}

type uiPlaying interface {
	ticking(on bool)
	holding(on bool)
	blot(f uiFont, s string) (int, int, []uint8)
	pads() map[int]uiGamepad
}

type uiFinger struct {
	name                  string
	left, top, wide, tall float64
	x, y                  float64
}

type uiStage struct {
	n        *uiNative
	radio    uiRadio
	engine   *uiEngine
	starting bool
	failures int

	rect  [4]int
	drawn [2]int
	spots [][4]int
	sized [2]int

	scene string
	cuts  []int32
	looks string
	seq   uint32
	whole bool

	pix        []byte
	wide, tall int
	owed       bool
	wanted     bool
	since      time.Time
	serial     uint32

	arrived atomic.Bool
	stale   atomic.Bool
	lost    atomic.Bool
	died    atomic.Bool
	begun   atomic.Pointer[uiEngine]
	mu      sync.Mutex
	asked   [][2]string

	attrs    []UiAttr
	want     string
	grab     bool
	cross    bool
	shown    bool
	grabbing bool
	held     map[string]bool
	lookX    float64
	lookY    float64
	last     time.Time

	gaps      [240]float64
	gapAt     int
	gapsIn    int
	beat      time.Time
	rateSaid  int
	rateAsked time.Time

	draws      atomic.Int64
	drawMicros atomic.Int64
	work       time.Duration
	told       time.Time
	tally      bool

	padWas    map[int]map[string]float64
	finger    *uiFinger
	touches   map[string]bool
	touchTold map[string]float64
}

func (s *uiStage) wants(event byte) bool {
	for i := 0; i < len(s.want); i++ {
		if s.want[i] == event {
			return true
		}
	}
	return false
}

func (s *uiStage) post(kind, value string, index int) { s.n.post(s.attrs, kind, value, index) }

func (s *uiStage) nudge() {
	if s.n.wake != nil {
		s.n.wake()
	}
}

func (s *uiStage) play() uiPlaying {
	p, _ := s.n.dev.(uiPlaying)
	return p
}

func (s *uiStage) start() {
	if s.starting || s.failures > 2 {
		return
	}
	s.starting = true
	go func() {
		e := uiEngineSpare.Swap(nil)
		if e == nil {
			e, _ = uiEngineStart(uiEnginePath())
		}
		if e != nil {
			e.painted = func(_ uint32, _, _ int, micros int) {
				s.drawMicros.Add(int64(micros))
				s.draws.Add(1)
				s.arrived.Store(true)
				s.nudge()
			}
			e.stale = func() { s.stale.Store(true); s.nudge() }
			e.spent = func(name string) { s.radio.again(e, name) }
			e.resync = func() { s.lost.Store(true); s.nudge() }
			e.died = func() { s.died.Store(true); s.nudge() }
			e.picture = uiStagePicture
			e.label = func(words, colour string) {
				s.mu.Lock()
				s.asked = append(s.asked, [2]string{words, colour})
				s.mu.Unlock()
				s.nudge()
			}
			e.heed()
		}
		s.begun.Store(e)
		if e == nil {
			s.died.Store(true)
		}
		s.nudge()
	}()
}

func uiStagePicture(path string) (int, int, []byte) {
	body, ok := uiEngineRead(path)
	if !ok {
		return 0, 0, nil
	}
	decoded, _, err := image.Decode(bytes.NewReader(body))
	if err != nil {
		return 0, 0, nil
	}
	b := decoded.Bounds()
	plain := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(plain, plain.Bounds(), decoded, b.Min, draw.Src)
	return b.Dx(), b.Dy(), plain.Pix
}

func (s *uiStage) tallied(began time.Time) {
	if !s.tally {
		return
	}
	s.work += time.Since(began)
	if time.Since(s.told) < time.Second {
		return
	}
	draws, micros := s.draws.Swap(0), s.drawMicros.Swap(0)
	if draws > 0 {
		os.Stderr.WriteString("hive: scene " + strconv.FormatInt(draws, 10) + "/s | engine " +
			strconv.FormatFloat(float64(micros)/float64(draws)/1000, 'f', 1, 64) + "ms | window " +
			strconv.FormatFloat(float64(s.work)/float64(time.Millisecond)/float64(draws), 'f', 1, 64) + "ms\n")
	}
	s.work, s.told = 0, time.Now()
}

func (s *uiStage) settle() {
	defer s.tallied(time.Now())
	n := s.n
	b := n.sceneBox
	s.shown = true
	s.attrs = b.v.Attrs
	s.want = uiSceneWants(b.v.Attrs)
	grab, _ := uiFind(b.v.Attrs, "grab")
	cross, _ := uiFind(b.v.Attrs, "crosshair")
	s.grab, s.cross = grab.Flag, cross.Flag
	if s.grabbing && !s.grab {
		s.letGo()
	}
	x0, y0, x1, y1 := n.rectOf(b)
	rect := [4]int{int(x0), int(y0), int(x1), int(y1)}
	drawn := [2]int{max(int(math.Round(b.w)), 1), max(int(math.Round(b.h)), 1)}
	moved := rect[2]-rect[0] != s.rect[2]-s.rect[0] || rect[3]-rect[1] != s.rect[3]-s.rect[1] || drawn != s.drawn
	s.rect, s.drawn = rect, drawn
	if s.wants('s') && drawn != s.sized && rect[2] > rect[0] && rect[3] > rect[1] {
		s.sized = drawn
		s.post("size", strconv.Itoa(drawn[0])+","+strconv.Itoa(drawn[1]), 0)
	}
	spots := make([][4]int, len(n.insetBoxes))
	looks := make([]string, len(n.insetBoxes))
	for i, in := range n.insetBoxes {
		ix0, iy0, ix1, iy1 := n.rectOf(in)
		spots[i] = [4]int{int(ix0) - rect[0], int(iy0) - rect[1], int(ix1 - ix0), int(iy1 - iy0)}
		looks[i] = in.v.Text
	}
	if p := s.play(); p != nil {
		p.ticking(s.want != "")
	}
	if s.engine == nil {
		s.start()
		return
	}
	wide, tall := rect[2]-rect[0], rect[3]-rect[1]
	if wide < 1 || tall < 1 {
		return
	}
	if moved || s.whole {
		if !s.engine.size(wide, tall, drawn[0], drawn[1]) {
			return
		}
		s.wanted = true
	}
	same := len(spots) == len(s.spots)
	for i := 0; same && i < len(spots); i++ {
		same = spots[i] == s.spots[i]
	}
	if !same || s.whole {
		s.spots = spots
		s.engine.insets(spots)
		s.wanted = true
	}
	world := uiSceneLooks(looks)
	if s.whole || b.v.Text != s.scene || world != s.looks {
		prev := s.seq
		s.seq++
		if s.whole {
			s.engine.frame(uiSceneFrame(b.v.Text, b.v.Cuts, world, "", nil, s.seq, 0))
		} else {
			s.engine.frame(uiSceneFrame(b.v.Text, b.v.Cuts, world, s.scene, s.cuts, s.seq, prev))
		}
		s.scene, s.cuts, s.looks, s.whole = b.v.Text, b.v.Cuts, world, false
		s.wanted = true
	}
	s.ask()
}

func (s *uiStage) ask() {
	if !s.wanted || s.owed || s.engine == nil {
		return
	}
	s.wanted, s.owed, s.since = false, true, time.Now()
	s.serial++
	s.engine.draw(s.serial)
}

func (s *uiStage) idle() {
	if !s.shown {
		return
	}
	s.shown = false
	s.release()
	s.letGo()
	if p := s.play(); p != nil {
		p.ticking(false)
	}
	if s.engine != nil {
		empty := UiScene(nil, nil)
		s.seq++
		s.engine.frame(uiSceneFrame(empty.Text, empty.Cuts, uiSceneLooks(nil), "", nil, s.seq, 0))
	}
	s.scene, s.cuts, s.looks, s.whole = "", nil, "", true
	s.rect, s.drawn, s.sized, s.spots = [4]int{}, [2]int{}, [2]int{}, nil
}

func (s *uiStage) pump() bool {
	defer s.tallied(time.Now())
	if e := s.begun.Swap(nil); e != nil {
		s.engine, s.starting, s.whole = e, false, true
		s.owed, s.wanted = false, false
		s.radio.onto(e)
		if s.shown && s.n.sceneBox != nil {
			s.settle()
		}
	}
	if s.died.Swap(false) {
		if s.engine != nil {
			s.engine.close()
		}
		s.engine, s.starting, s.owed = nil, false, false
		s.radio.onto(nil)
		s.failures++
		if s.shown {
			s.start()
		}
	}
	if s.engine == nil {
		return true
	}
	s.mu.Lock()
	asked := s.asked
	s.asked = nil
	s.mu.Unlock()
	for _, a := range asked {
		wide, tall, rgba := s.lettered(a[0], a[1])
		s.engine.labelled(a[0], a[1], wide, tall, rgba)
	}
	if s.lost.Swap(false) {
		s.whole = true
		if s.shown && s.n.sceneBox != nil {
			s.settle()
		}
	}
	if s.stale.Swap(false) {
		s.wanted = true
	}
	fresh := false
	if s.arrived.Swap(false) {
		if got := s.engine.pixels(); len(got) > 0 {
			wide, tall := s.rect[2]-s.rect[0], s.rect[3]-s.rect[1]
			if len(got) == wide*tall*4 {
				if len(s.pix) != len(got) {
					s.pix = make([]byte, len(got))
				}
				copy(s.pix, got)
				s.wide, s.tall = wide, tall
			}
		}
		s.owed = false
		fresh = true
	}
	s.ask()
	return fresh || !s.owed || time.Since(s.since) > 120*time.Millisecond
}

func (s *uiStage) lettered(words, colour string) (int, int, []byte) {
	p := s.play()
	if p == nil {
		return 0, 0, nil
	}
	const pad, plate = 16, 84
	tw, th, cover := p.blot(uiFont{px: 52 / s.n.scale, weight: 700}, words)
	wide := tw + 2*pad
	ink, ok := uiParseColour(colour)
	if !ok {
		ink = uiWhite
	}
	out := make([]byte, wide*plate*4)
	top := (plate-th)/2 + 2
	for y := 0; y < plate; y++ {
		for x := 0; x < wide; x++ {
			a := 0.0
			if tx, ty := x-pad, y-top; tx >= 0 && tx < tw && ty >= 0 && ty < th {
				a = float64(cover[ty*tw+tx]) / 255 * float64(ink.a) / 255
			}
			under := 0.5 * (1 - a)
			all := a + under
			at := (y*wide + x) * 4
			out[at] = uint8(math.Round((float64(ink.r)*a + 10*under) / all))
			out[at+1] = uint8(math.Round((float64(ink.g)*a + 12*under) / all))
			out[at+2] = uint8(math.Round((float64(ink.b)*a + 16*under) / all))
			out[at+3] = uint8(math.Round(all * 255))
		}
	}
	return wide, plate, out
}

var uiStageDark = uiHexRGB(0x0b0d10)

func (s *uiStage) paint(cv *uiCanvas, b *uiBox, clip uiClip) {
	defer s.tallied(time.Now())
	x0, y0, x1, y1 := s.n.rectOf(b)
	box := uiClip{int(x0), int(y0), int(x1), int(y1)}
	r := cv.bounds(clip).and(box)
	if r.empty() {
		return
	}
	cv.fill(box.x0, box.y0, box.x1, box.y1, uiStageDark, clip)
	if len(s.pix) >= s.wide*s.tall*4 && s.wide > 0 {
		cv.flush()
		src := unsafe.Slice((*uint32)(unsafe.Pointer(&s.pix[0])), s.wide*s.tall)
		for y := r.y0; y < r.y1 && y-box.y0 < s.tall; y++ {
			from := (y-box.y0)*s.wide + r.x0 - box.x0
			run := min(r.x1-r.x0, s.wide-(r.x0-box.x0))
			if run > 0 {
				copy(cv.pix[y*cv.w+r.x0:y*cv.w+r.x0+run], src[from:from+run])
			}
		}
	}
	if s.cross {
		mark := uiRGBA{255, 255, 255, 204}
		cx, cy := (x0+x1)/2, (y0+y1)/2
		k := s.n.scale
		cv.fill(int(cx-k), int(cy-7*k), int(cx+k), int(cy+8*k), mark, clip)
		cv.fill(int(cx-7*k), int(cy-k), int(cx-k), int(cy+k), mark, clip)
		cv.fill(int(cx+k), int(cy-k), int(cx+8*k), int(cy+k), mark, clip)
	}
}

func (s *uiStage) over(x, y float64) bool {
	chain := s.n.under(x, y)
	return len(chain) > 0 && chain[len(chain)-1] == s.n.sceneBox
}

func (s *uiStage) hidden(x, y float64) bool {
	return s.grabbing || s.cross && s.over(x, y)
}

func (s *uiStage) down(k string) {
	if s.held[k] {
		return
	}
	s.held[k] = true
	if s.wants('k') {
		s.post("keydown", k, 0)
	}
}

func (s *uiStage) up(k string) {
	if !s.held[k] {
		return
	}
	delete(s.held, k)
	if s.wants('u') {
		s.post("keyup", k, 0)
	}
}

func (s *uiStage) release() {
	for k := range s.held {
		if s.wants('u') {
			s.post("keyup", k, 0)
		}
	}
	clear(s.held)
	s.finger = nil
}

func (s *uiStage) letGo() {
	if !s.grabbing {
		return
	}
	s.grabbing = false
	if p := s.play(); p != nil {
		p.holding(false)
	}
	s.release()
	if s.wants('g') {
		s.post("grab", "", 0)
	}
}

func uiStageSwallows(k string) bool {
	switch k {
	case "space", "tab", "up", "down", "left", "right":
		return true
	}
	return false
}

func (s *uiStage) key(name string, down bool) bool {
	if !s.shown || name == "" {
		return false
	}
	if !down {
		s.up(name)
		return false
	}
	if s.grabbing && name == "escape" {
		s.letGo()
		return true
	}
	if s.n.typing() {
		return false
	}
	if b, ok := s.n.boxes[s.n.focus]; ok && b.kind == "input" && b.input == "Range" {
		switch name {
		case "up", "down", "left", "right", "pageup", "pagedown", "home", "end":
			return false
		}
	}
	s.down(name)
	return s.grabbing && uiStageSwallows(name)
}

func (s *uiStage) press(button int, x, y float64) bool {
	if !s.shown {
		return false
	}
	n := s.n
	chain := n.under(x, y)
	if button == 1 {
		for i := len(chain) - 1; i >= 0; i-- {
			if t, ok := chain[i].attr("touch"); ok && t.Word != "" {
				b := chain[i]
				if s.touches == nil {
					s.touches, s.touchTold = map[string]bool{}, map[string]float64{}
				}
				s.touches[t.Word] = true
				s.finger = &uiFinger{name: t.Word, left: b.x, top: b.y, wide: b.w, tall: b.h}
				s.drag(x, y)
				return true
			}
		}
	}
	onScene := len(chain) > 0 && chain[len(chain)-1] == n.sceneBox
	if s.grab && !s.grabbing {
		for i := len(chain) - 1; i >= 0; i-- {
			if chain[i] != n.sceneBox && chain[i].answers() {
				return false
			}
		}
		if p := s.play(); p != nil {
			s.grabbing = true
			p.holding(true)
			if s.wants('g') {
				s.post("grab", "1", 0)
			}
			return true
		}
	}
	if s.grabbing || onScene {
		s.down("mouse" + strconv.Itoa(button))
	}
	return s.grabbing
}

func (s *uiStage) lift(button int) bool {
	if button == 1 && s.finger != nil {
		s.finger = nil
		return true
	}
	s.up("mouse" + strconv.Itoa(button))
	return s.grabbing
}

func (s *uiStage) drag(x, y float64) {
	f := s.finger
	if f == nil {
		return
	}
	fx := (x - f.left - f.wide/2) / math.Max(1, f.wide/2)
	fy := (y - f.top - f.tall/2) / math.Max(1, f.tall/2)
	if far := math.Hypot(fx, fy); far > 1 {
		fx, fy = fx/far, fy/far
	}
	f.x, f.y = fx, fy
}

func (s *uiStage) looked(dx, dy float64) {
	s.lookX += dx
	s.lookY += dy
}

func (s *uiStage) blur() {
	s.release()
	s.letGo()
}

func uiStageRound(v float64) string {
	return strconv.FormatFloat(math.Round(v*100)/100, 'f', -1, 64)
}

func (s *uiStage) tick() {
	if !s.shown {
		return
	}
	now := time.Now()
	s.paced(now)
	if s.lookX != 0 || s.lookY != 0 {
		if s.wants('l') {
			s.post("look", uiStageRound(s.lookX)+","+uiStageRound(s.lookY), 0)
		}
		s.lookX, s.lookY = 0, 0
	}
	if s.wants('p') {
		s.padded()
		s.touched()
	}
	if !s.wants('f') || s.last.IsZero() {
		s.last = now
		return
	}
	ms := int(math.Round(float64(now.Sub(s.last)) / float64(time.Millisecond)))
	if ms <= 0 || s.n.owed.Load() {
		return
	}
	s.last = now
	s.n.owed.Store(true)
	s.post("frame", "", min(100, ms))
}

func (s *uiStage) paced(now time.Time) {
	if !s.beat.IsZero() {
		ms := float64(now.Sub(s.beat)) / float64(time.Millisecond)
		if ms > 0.5 && ms < 200 {
			s.gaps[s.gapAt] = ms
			s.gapAt = (s.gapAt + 1) % len(s.gaps)
			if s.gapsIn < len(s.gaps) {
				s.gapsIn++
			}
		}
	}
	s.beat = now
	if !s.wants('r') || s.gapsIn < 30 || now.Sub(s.rateAsked) < time.Second {
		return
	}
	s.rateAsked = now
	sorted := append([]float64(nil), s.gaps[:s.gapsIn]...)
	sort.Float64s(sorted)
	hz := int(math.Round(1000 / sorted[s.gapsIn/10]))
	hz = max(20, min(480, hz))
	if hz != s.rateSaid {
		s.rateSaid = hz
		s.post("rate", "", hz)
	}
}

func (s *uiStage) padded() {
	p := s.play()
	if p == nil {
		return
	}
	now := p.pads()
	if s.padWas == nil {
		s.padWas = map[int]map[string]float64{}
	}
	for i, was := range s.padWas {
		if _, here := now[i]; here {
			continue
		}
		for control, at := range was {
			if at != 0 {
				s.post("pad", control+"|0", i)
			}
		}
		delete(s.padWas, i)
		s.post("pad", "here|0", i)
	}
	for i, pad := range now {
		was, known := s.padWas[i]
		if !known {
			was = map[string]float64{}
			s.padWas[i] = was
			if pad.named {
				s.post("pad", "here|1", i)
			} else {
				s.post("pad", "here|2", i)
			}
		}
		for control, at := range pad.controls {
			switch control {
			case "leftX", "leftY", "rightX", "rightY":
				if at > -0.08 && at < 0.08 {
					at = 0
				}
			}
			if math.Abs(at-was[control]) < 0.02 {
				continue
			}
			was[control] = at
			s.post("pad", control+"|"+uiStageRound(at), i)
		}
	}
}

func (s *uiStage) touched() {
	if len(s.touches) == 0 {
		return
	}
	now := map[string]float64{}
	for name := range s.touches {
		now[name], now[name+"X"], now[name+"Y"] = 0, 0, 0
	}
	if f := s.finger; f != nil {
		now[f.name], now[f.name+"X"], now[f.name+"Y"] = 1, f.x, f.y
	}
	for control, at := range now {
		told := s.touchTold[control]
		if at == told || at != 0 && math.Abs(at-told) < 0.02 {
			continue
		}
		s.touchTold[control] = at
		s.post("pad", control+"|"+uiStageRound(at), -1)
	}
}

func (s *uiStage) close() {
	s.radio.onto(nil)
	if s.engine != nil {
		s.engine.close()
		s.engine = nil
	}
}

var (
	uiEngineData  []byte
	uiEngineSum   string
	uiEngineOnce  sync.Once
	uiEngineWorks bool
	uiEngineSpare atomic.Pointer[uiEngine]
)

func uiEnginePath() string {
	if path := os.Getenv("HIVE_SCENE_ENGINE"); path != "" {
		return path
	}
	return uiEngineUnpacked()
}

func uiEngineUnpacked() string {
	if len(uiEngineData) == 0 {
		return ""
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	dir = filepath.Join(dir, "hive", "scene-"+uiEngineSum[:16])
	path := filepath.Join(dir, "hive-scene")
	if runtime.GOOS == "windows" {
		path += ".exe"
	}
	if held, err := os.ReadFile(path); err == nil {
		sum := sha256.Sum256(held)
		if hex.EncodeToString(sum[:]) == uiEngineSum {
			return path
		}
	}
	if os.MkdirAll(dir, 0o755) != nil {
		return ""
	}
	fresh := path + "." + strconv.Itoa(os.Getpid())
	if os.WriteFile(fresh, uiEngineData, 0o755) != nil {
		return ""
	}
	if os.Rename(fresh, path) != nil {
		os.Remove(fresh)
		if _, err := os.Stat(path); err != nil {
			return ""
		}
	}
	return path
}

func uiEngineProbe() bool {
	uiEngineOnce.Do(func() {
		if e, err := uiEngineStart(uiEnginePath()); err == nil {
			uiEngineSpare.Store(e)
			uiEngineWorks = true
		}
	})
	return uiEngineWorks
}
