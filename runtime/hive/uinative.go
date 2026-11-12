// The tree laid out as the stylesheet lays it out, and what the widgets remember.
package hive

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"
)

type uiRGBA struct{ r, g, b, a uint8 }

func uiHexRGB(v uint32) uiRGBA { return uiRGBA{uint8(v >> 16), uint8(v >> 8), uint8(v), 255} }

type uiPalette struct{ bg, fg, muted, line, accent, good, warn, danger, surface uiRGBA }

var uiLightPalette = uiPalette{
	bg: uiHexRGB(0xffffff), fg: uiHexRGB(0x16181c), muted: uiHexRGB(0x5b6470), line: uiHexRGB(0xe3e6ea),
	accent: uiHexRGB(0x1d9bf0), good: uiHexRGB(0x00a870), warn: uiHexRGB(0xc47d00), danger: uiHexRGB(0xd7263d),
	surface: uiHexRGB(0xf7f9fa),
}

var uiDarkPalette = uiPalette{
	bg: uiHexRGB(0x15181c), fg: uiHexRGB(0xe7e9ea), muted: uiHexRGB(0x8b98a5), line: uiHexRGB(0x2f3336),
	accent: uiHexRGB(0x1d9bf0), good: uiHexRGB(0x00ba7c), warn: uiHexRGB(0xffd400), danger: uiHexRGB(0xf4212e),
	surface: uiHexRGB(0x1c2026),
}

var uiWhite = uiRGBA{255, 255, 255, 255}
var uiPlaceholder = uiHexRGB(0x757575)

func (p *uiPalette) role(word string) (uiRGBA, bool) {
	switch word {
	case "Muted":
		return p.muted, true
	case "Good":
		return p.good, true
	case "Warn":
		return p.warn, true
	case "Danger":
		return p.danger, true
	}
	return uiRGBA{}, false
}

func uiParseColour(s string) (uiRGBA, bool) {
	if strings.HasPrefix(s, "#") {
		digits := s[1:]
		if len(digits) == 3 || len(digits) == 4 {
			var b strings.Builder
			for i := 0; i < len(digits); i++ {
				b.WriteByte(digits[i])
				b.WriteByte(digits[i])
			}
			digits = b.String()
		}
		if len(digits) == 6 {
			digits += "ff"
		}
		v, err := strconv.ParseUint(digits, 16, 32)
		if err != nil || len(digits) != 8 {
			return uiRGBA{}, false
		}
		return uiRGBA{uint8(v >> 24), uint8(v >> 16), uint8(v >> 8), uint8(v)}, true
	}
	if strings.HasPrefix(s, "rgba(") && strings.HasSuffix(s, ")") {
		parts := strings.Split(s[5:len(s)-1], ",")
		if len(parts) != 4 {
			return uiRGBA{}, false
		}
		var ch [3]uint8
		for i := 0; i < 3; i++ {
			n, err := strconv.Atoi(strings.TrimSpace(parts[i]))
			if err != nil {
				return uiRGBA{}, false
			}
			ch[i] = uint8(uiChannel(n))
		}
		alpha, err := strconv.ParseFloat(strings.TrimSpace(parts[3]), 64)
		if err != nil {
			return uiRGBA{}, false
		}
		return uiRGBA{ch[0], ch[1], ch[2], uint8(math.Round(uiClamp(alpha, 0, 1) * 255))}, true
	}
	return uiRGBA{}, false
}

func uiMix(under uiRGBA, over uiRGBA, amount float64) uiRGBA {
	a := amount * float64(over.a) / 255
	mix := func(u, o uint8) uint8 { return uint8(math.Round(float64(u)*(1-a) + float64(o)*a)) }
	return uiRGBA{mix(under.r, over.r), mix(under.g, over.g), mix(under.b, over.b), 255}
}

func uiClamp(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

type uiFont struct {
	px     float64
	weight int
	icon   bool
	mono   bool
}

type uiClip struct{ x0, y0, x1, y1 int }

func (c uiClip) and(o uiClip) uiClip {
	return uiClip{max(c.x0, o.x0), max(c.y0, o.y0), min(c.x1, o.x1), min(c.y1, o.y1)}
}

func (c uiClip) empty() bool { return c.x0 >= c.x1 || c.y0 >= c.y1 }

type uiDevice interface {
	measure(f uiFont, s string) float64
	tall(f uiFont) float64
	average(f uiFont) float64
	text(f uiFont, x, y int, s string, c uiRGBA, clip uiClip)
	clipboard() string
	setClipboard(s string)
	openLink(href string)
	datePattern() string
}

type uiCanvas struct {
	pix   []uint32
	w, h  int
	flush func()
	dirty uiClip
}

func uiPack(c uiRGBA) uint32 { return uint32(c.r)<<16 | uint32(c.g)<<8 | uint32(c.b) | 0xff000000 }

func uiBlendPixel(dst uint32, c uiRGBA, cover float64) uint32 {
	a := cover * float64(c.a) / 255
	if a >= 1 {
		return uiPack(c)
	}
	mix := func(d uint32, o uint8) uint32 { return uint32(math.Round(float64(d)*(1-a) + float64(o)*a)) }
	r := mix(dst>>16&0xff, c.r)
	g := mix(dst>>8&0xff, c.g)
	b := mix(dst&0xff, c.b)
	return r<<16 | g<<8 | b | 0xff000000
}

func (cv *uiCanvas) bounds(clip uiClip) uiClip {
	return clip.and(uiClip{0, 0, cv.w, cv.h})
}

func (cv *uiCanvas) fill(x0, y0, x1, y1 int, c uiRGBA, clip uiClip) {
	r := cv.bounds(clip).and(uiClip{x0, y0, x1, y1})
	if r.empty() || c.a == 0 {
		return
	}
	cv.flush()
	solid := uiPack(c)
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w+r.x0 : y*cv.w+r.x1]
		if c.a == 255 {
			for x := range row {
				row[x] = solid
			}
			continue
		}
		a, under := uint32(c.a), 255-uint32(c.a)
		cr, cg, cb := uint32(c.r)*a+127, uint32(c.g)*a+127, uint32(c.b)*a+127
		for x, d := range row {
			r, g, b := (d>>16&0xff)*under+cr, (d>>8&0xff)*under+cg, (d&0xff)*under+cb
			row[x] = (r+1+r>>8)>>8<<16 | (g+1+g>>8)>>8<<8 | (b+1+b>>8)>>8 | 0xff000000
		}
	}
}

func (c uiClip) or(o uiClip) uiClip {
	if c.empty() {
		return o
	}
	if o.empty() {
		return c
	}
	return uiClip{min(c.x0, o.x0), min(c.y0, o.y0), max(c.x1, o.x1), max(c.y1, o.y1)}
}

func (cv *uiCanvas) round(x0, y0, x1, y1, radius float64, c uiRGBA, clip uiClip) {
	if x1 <= x0 || y1 <= y0 || c.a == 0 {
		return
	}
	radius = math.Min(radius, math.Min(x1-x0, y1-y0)/2)
	r := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)), int(math.Ceil(y1))})
	if r.empty() {
		return
	}
	cv.flush()
	cx, cy := (x0+x1)/2, (y0+y1)/2
	hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
	band0, band1 := uiBand(cx, hx, r.x0, r.x1)
	solid := uiPack(c)
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		qy := math.Abs(float64(y)+0.5-cy) - hy
		at := func(x int) float64 {
			qx := math.Abs(float64(x)+0.5-cx) - hx
			outside := math.Hypot(math.Max(qx, 0), math.Max(qy, 0))
			inside := math.Min(math.Max(qx, qy), 0)
			return uiClamp(0.5-(outside+inside-radius), 0, 1)
		}
		for x := r.x0; x < band0; x++ {
			if cover := at(x); cover > 0 {
				row[x] = uiBlendPixel(row[x], c, cover)
			}
		}
		if band0 < band1 {
			cover := uiClamp(0.5-(qy-radius), 0, 1)
			switch {
			case cover >= 1 && c.a == 255:
				for x := band0; x < band1; x++ {
					row[x] = solid
				}
			case cover > 0:
				for x := band0; x < band1; x++ {
					row[x] = uiBlendPixel(row[x], c, cover)
				}
			}
		}
		for x := max(band1, r.x0); x < r.x1; x++ {
			if cover := at(x); cover > 0 {
				row[x] = uiBlendPixel(row[x], c, cover)
			}
		}
	}
}

func uiBand(cx, hx float64, from, to int) (int, int) {
	lo := int(math.Ceil(cx - hx + 0.5))
	hi := int(math.Floor(cx + hx - 0.5))
	lo, hi = max(lo, from), min(hi, to)
	if hi < lo {
		return from, from
	}
	return lo, hi
}

func (cv *uiCanvas) ring(x0, y0, x1, y1, radius, width float64, c uiRGBA, clip uiClip) {
	if x1 <= x0 || y1 <= y0 || c.a == 0 {
		return
	}
	radius = math.Min(radius, math.Min(x1-x0, y1-y0)/2)
	r := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)), int(math.Ceil(y1))})
	if r.empty() {
		return
	}
	cv.flush()
	cx, cy := (x0+x1)/2, (y0+y1)/2
	hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
	band0, band1 := uiBand(cx, hx, r.x0, r.x1)
	if width > radius+0.5 {
		band0, band1 = r.x1, r.x1
	}
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		qy := math.Abs(float64(y)+0.5-cy) - hy
		at := func(x int) float64 {
			qx := math.Abs(float64(x)+0.5-cx) - hx
			d := math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
			return uiClamp(0.5-d, 0, 1) - uiClamp(0.5-(d+width), 0, 1)
		}
		for x := r.x0; x < band0; x++ {
			if cover := at(x); cover > 0 {
				row[x] = uiBlendPixel(row[x], c, cover)
			}
		}
		if band0 < band1 {
			d := qy - radius
			if cover := uiClamp(0.5-d, 0, 1) - uiClamp(0.5-(d+width), 0, 1); cover > 0 {
				for x := band0; x < band1; x++ {
					row[x] = uiBlendPixel(row[x], c, cover)
				}
			}
		}
		for x := max(band1, r.x0); x < r.x1; x++ {
			if cover := at(x); cover > 0 {
				row[x] = uiBlendPixel(row[x], c, cover)
			}
		}
	}
}

func (cv *uiCanvas) grab(r uiClip) []uint32 {
	if r.empty() {
		return nil
	}
	cv.flush()
	out := make([]uint32, 0, (r.x1-r.x0)*(r.y1-r.y0))
	for y := r.y0; y < r.y1; y++ {
		out = append(out, cv.pix[y*cv.w+r.x0:y*cv.w+r.x1]...)
	}
	return out
}

func (cv *uiCanvas) fade(saved []uint32, r uiClip, keep float64) {
	if saved == nil {
		return
	}
	cv.flush()
	w := r.x1 - r.x0
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w+r.x0 : y*cv.w+r.x1]
		was := saved[(y-r.y0)*w : (y-r.y0+1)*w]
		for x, now := range row {
			if now != was[x] {
				row[x] = uiBlendPixel(was[x], uiRGBA{uint8(now >> 16), uint8(now >> 8), uint8(now), 255}, keep)
			}
		}
	}
}

type uiRaster struct {
	w, h int
	acc  []float32
}

func (r *uiRaster) reset(w, h int) {
	r.w, r.h = max(w, 0), max(h, 0)
	n := (r.w + 2) * r.h
	if cap(r.acc) < n {
		r.acc = make([]float32, n)
	}
	r.acc = r.acc[:n]
	clear(r.acc)
}

func (r *uiRaster) line(x0, y0, x1, y1 float64) {
	if y0 == y1 || math.IsNaN(x0+y0+x1+y1) {
		return
	}
	w := float64(r.w)
	for _, edge := range [2]float64{0, w} {
		if (x0 < edge) != (x1 < edge) && x0 != edge && x1 != edge {
			t := (edge - x0) / (x1 - x0)
			ym := y0 + (y1-y0)*t
			r.line(x0, y0, edge, ym)
			r.line(edge, ym, x1, y1)
			return
		}
	}
	r.edge(uiClamp(x0, 0, w), y0, uiClamp(x1, 0, w), y1)
}

func (r *uiRaster) edge(x0, y0, x1, y1 float64) {
	dir := float32(1)
	if y0 > y1 {
		dir = -1
		x0, y0, x1, y1 = x1, y1, x0, y0
	}
	dxdy := (x1 - x0) / (y1 - y0)
	stride := r.w + 2
	for y := max(0, int(math.Floor(y0))); y < min(r.h, int(math.Ceil(y1))); y++ {
		top := math.Max(float64(y), y0)
		bottom := math.Min(float64(y+1), y1)
		if bottom <= top {
			continue
		}
		xa := uiClamp(x0+(top-y0)*dxdy, 0, float64(r.w))
		xb := uiClamp(x0+(bottom-y0)*dxdy, 0, float64(r.w))
		d := float32(bottom-top) * dir
		row := r.acc[y*stride : (y+1)*stride]
		lo, hi := math.Min(xa, xb), math.Max(xa, xb)
		lf := math.Floor(lo)
		li := int(lf)
		hc := math.Ceil(hi)
		hiI := int(hc)
		if hiI <= li+1 {
			mid := float32((xa+xb)/2 - lf)
			row[li] += d - d*mid
			row[li+1] += d * mid
			continue
		}
		s := 1 / (hi - lo)
		f0 := lo - lf
		a0 := 0.5 * s * (1 - f0) * (1 - f0)
		f1 := hi - hc + 1
		am := 0.5 * s * f1 * f1
		row[li] += d * float32(a0)
		if hiI == li+2 {
			row[li+1] += d * float32(1-a0-am)
		} else {
			a1 := s * (1.5 - f0)
			row[li+1] += d * float32(a1-a0)
			for x := li + 2; x < hiI-1; x++ {
				row[x] += d * float32(s)
			}
			a2 := a1 + float64(hiI-li-3)*s
			row[hiI-1] += d * float32(1-a2-am)
		}
		row[hiI] += d * float32(am)
	}
}

func (r *uiRaster) quad(x0, y0, cx, cy, x1, y1 float64) {
	dd := math.Hypot(x0-2*cx+x1, y0-2*cy+y1)
	n := max(1, int(math.Sqrt(dd)*1.5))
	px, py := x0, y0
	for i := 1; i <= n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		qx := u*u*x0 + 2*u*t*cx + t*t*x1
		qy := u*u*y0 + 2*u*t*cy + t*t*y1
		r.line(px, py, qx, qy)
		px, py = qx, qy
	}
}

func (r *uiRaster) cubic(x0, y0, c1x, c1y, c2x, c2y, x1, y1 float64) {
	dd := math.Max(math.Hypot(x0-2*c1x+c2x, y0-2*c1y+c2y), math.Hypot(c1x-2*c2x+x1, c1y-2*c2y+y1))
	n := max(1, int(math.Sqrt(dd)*2))
	px, py := x0, y0
	for i := 1; i <= n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		qx := u*u*u*x0 + 3*u*u*t*c1x + 3*u*t*t*c2x + t*t*t*x1
		qy := u*u*u*y0 + 3*u*u*t*c1y + 3*u*t*t*c2y + t*t*t*y1
		r.line(px, py, qx, qy)
		px, py = qx, qy
	}
}

func (r *uiRaster) polygon(pts []float64) {
	n := len(pts) / 2
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		r.line(pts[2*i], pts[2*i+1], pts[2*j], pts[2*j+1])
	}
}

func (r *uiRaster) mask(into []uint8) []uint8 {
	n := r.w * r.h
	if cap(into) < n {
		into = make([]uint8, n)
	}
	into = into[:n]
	stride := r.w + 2
	for y := 0; y < r.h; y++ {
		sum := float32(0)
		row := r.acc[y*stride : y*stride+r.w]
		out := into[y*r.w : (y+1)*r.w]
		for x, v := range row {
			sum += v
			a := sum
			if a < 0 {
				a = -a
			}
			if a > 1 {
				a = 1
			}
			out[x] = uint8(a*255 + 0.5)
		}
	}
	return into
}

func (cv *uiCanvas) blend(mask []uint8, mw, mh, x, y int, c uiRGBA, clip uiClip) {
	r := cv.bounds(clip).and(uiClip{x, y, x + mw, y + mh})
	if r.empty() || c.a == 0 {
		return
	}
	cv.flush()
	for py := r.y0; py < r.y1; py++ {
		row := cv.pix[py*cv.w : (py+1)*cv.w]
		cover := mask[(py-y)*mw : (py-y+1)*mw]
		for px := r.x0; px < r.x1; px++ {
			if m := cover[px-x]; m != 0 {
				row[px] = uiBlendPixel(row[px], c, float64(m)/255)
			}
		}
	}
}

type uiBox struct {
	kind       string
	v          *UiView
	path       string
	seq        int
	kids       []*uiBox
	font       uiFont
	colour     uiRGBA
	fill       uiRGBA
	lineH      float64
	container  bool
	row        bool
	padX       float64
	padY       float64
	border     float64
	gap        float64
	width      float64 // -1 where the view gave none, as for height
	height     float64
	grow       float64
	align      string
	justify    string
	scroll     string
	margin     float64
	inset      float64
	corner     float64
	disabled   bool
	opacity    float64
	full       bool
	floor      float64
	input      string
	minW, maxW float64
	natH, minH float64
	x, y, w, h float64
	extentW    float64
	extentH    float64
	lines      []string
	grid       *uiGrid
	pic        *uiPicture
	code       bool
	edge       float64
	edgeTone   string
	radius     float64
	noRing     bool
	hoverTone  string
}

type uiGrid struct {
	cells    [][]string
	count    []int
	minC     []float64
	maxC     []float64
	cols     []float64
	heights  []float64
	wrapped  [][][]string
	sortable bool
	pickable bool
	stuck    float64
}

type uiLayer struct {
	panel    *uiBox
	backdrop *uiBox
	pinned   bool
	anchor   string
	dismiss  []UiAttr
	align    string
	justify  string
}

func (b *uiBox) attr(kind string) (UiAttr, bool) { return uiFind(b.v.Attrs, kind) }

func (b *uiBox) focusable() bool {
	switch b.kind {
	case "button", "input", "link", "textarea", "select", "checkbox":
		return !b.disabled
	}
	return false
}

func (b *uiBox) clickable() bool {
	if b.disabled {
		return false
	}
	switch b.kind {
	case "link", "checkbox":
		return true
	}
	_, on := b.attr("on")
	return on
}

func (b *uiBox) editable() bool {
	return !b.disabled && (b.kind == "textarea" || b.kind == "input" && b.input != "Range" && b.input != "Date")
}

type uiEntry struct {
	text   []rune
	caret  int
	anchor int
	sent   []string
	shift  float64
	top    float64
	goal   float64
	seen   int

	past, future []uiEntryState
	lastTyped    bool
	lastAt       time.Time

	caretSet, told, view, fit string

	str     string
	strOK   bool
	lines   []uiSpan
	linesOK bool
}

func (f *uiEntry) changed() {
	f.strOK, f.linesOK = false, false
}

func (f *uiEntry) value() string {
	if !f.strOK {
		f.str, f.strOK = string(f.text), true
	}
	return f.str
}

type uiMeasured struct {
	font uiFont
	text string
}

type uiNative struct {
	mu     sync.Mutex
	next   *UiView
	queued bool
	last   UiView
	addr   SyslinkAddress

	dev     uiDevice
	scale   float64
	vw, vh  float64
	pal     uiPalette
	stale   bool
	root    *uiBox
	layers  []*uiLayer
	seq     int
	boxes   map[string]*uiBox
	order   []*uiBox
	fields  map[string]*uiEntry
	dates   map[string]*uiDate
	scrolls map[string][2]float64
	sized   map[uiMeasured]float64
	pending map[string]string
	pics    map[string]*uiPicture
	popup   *uiPopup

	hover     string
	hoverPart int
	press     string
	pressPart int
	focus     string
	keyboard  bool
	blink     bool
	dragging  bool
	sliding   string
	pointer   [2]float64
	tip       string
	quiet     string
	tipSince  time.Time
	tipAt     [2]float64
	spins     []uiClip
	anims     []uiClip
	animDue   time.Duration
	tipDrawn  bool
	epoch     time.Time
	dateShape [3]byte
	dateSep   string
	redo      atomic.Bool

	runs      []uiRun
	runIndex  map[string]int
	sel       *uiSelection
	selecting bool
	clicks    int
	lastPress time.Time
	pressAt   [2]float64
	spot      [2]float64
	drag      *uiDrag
	ctrl      bool
	hovered   string
	lit       string
	probed    string
	asked     map[string]int
	clips     map[string]int
	performed map[string]int
	menuItems []uiMenuItem
	grab      *uiGrab
	grown     map[string]float64

	stamp       uint64
	accessRoot  *uiAccess
	accessStamp uint64
	accessIds   map[int32]*uiAccess
	accessBuilt uint64

	raster uiRaster
	cover  []uint8

	wake func()

	stage      uiStaging
	sceneBox   *uiBox
	insetBoxes []*uiBox
	owed       atomic.Bool
}

type uiStaging interface {
	settle()
	idle()
	pump() bool
	paint(cv *uiCanvas, b *uiBox, clip uiClip)
	hidden(x, y float64) bool
	key(name string, down bool) bool
	press(button int, x, y float64) bool
	lift(button int) bool
	drag(x, y float64)
	looked(dx, dy float64)
	blur()
	tick()
	close()
}

var uiStageMake func(n *uiNative) uiStaging
var uiStageReady func() bool

type uiGamepad struct {
	named    bool
	controls map[string]float64
}

func (n *uiNative) staged() bool {
	if uiStageMake == nil {
		return true
	}
	n.layout()
	if n.stage == nil {
		return true
	}
	return n.stage.pump()
}

func uiNewNative() *uiNative {
	return &uiNative{
		scale:     1,
		pal:       uiLightPalette,
		fields:    map[string]*uiEntry{},
		dates:     map[string]*uiDate{},
		scrolls:   map[string][2]float64{},
		sized:     map[uiMeasured]float64{},
		pending:   map[string]string{},
		pics:      map[string]*uiPicture{},
		grown:     map[string]float64{},
		asked:     map[string]int{},
		clips:     map[string]int{},
		performed: map[string]int{},
		blink:     true,
		epoch:     time.Now(),
	}
}

func (n *uiNative) publish(v UiView) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.next = &v
	n.last = v
	n.owed.Store(false)
	wake := !n.queued
	n.queued = true
	return wake
}

func uiTitleOf(v UiView) string {
	if a, ok := uiFind(v.Attrs, "title"); ok {
		return a.Word
	}
	return ""
}

func (n *uiNative) latest() UiView {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.last
}

func (n *uiNative) touched() { n.stamp++ }

func (n *uiNative) adopt() {
	n.touched()
	n.mu.Lock()
	next := n.next
	n.next = nil
	n.queued = false
	n.mu.Unlock()
	if next != nil {
		n.stale = true
		n.last = *next
		clear(n.pending)
	}
	if n.redo.Swap(false) {
		n.stale = true
	}
}

func (n *uiNative) resize(w, h, scale float64) {
	if w != n.vw || h != n.vh || scale != n.scale {
		if scale != n.scale {
			n.sized = map[uiMeasured]float64{}
		}
		n.vw, n.vh, n.scale = w, h, scale
		n.stale = true
	}
}

func (n *uiNative) theme(dark bool) {
	p := uiLightPalette
	if dark {
		p = uiDarkPalette
	}
	if p != n.pal {
		n.pal = p
		n.stale = true
	}
}

func (n *uiNative) measure(f uiFont, s string) float64 {
	if s == "" {
		return 0
	}
	key := uiMeasured{f, s}
	if w, ok := n.sized[key]; ok {
		return w
	}
	if len(n.sized) > 20000 {
		n.sized = map[uiMeasured]float64{}
	}
	w := n.dev.measure(f, s)
	n.sized[key] = w
	return w
}

var uiHeadingSize = [7]float64{1, 2, 1.5, 1.17, 1, 0.83, 0.67}
var uiHeadingMargin = [7]float64{0, 0.67, 0.83, 1, 1.33, 1.67, 2.33}

func (n *uiNative) build(v *UiView, path string, parent *uiBox) *uiBox {
	if v.Kind == "none" {
		return nil
	}
	code := v.Kind == "code"
	if code {
		c := *v
		c.Kind = "textarea"
		v = &c
	}
	n.seq++
	b := &uiBox{kind: v.Kind, v: v, path: path, seq: n.seq, width: -1, height: -1, opacity: 1, edge: -1, radius: -1}
	if parent == nil {
		b.font = uiFont{px: 14, weight: 400}
		b.colour = n.pal.fg
	} else {
		b.font = parent.font
		b.colour = parent.colour
	}
	formed := v.Kind == "button" || v.Kind == "input" || v.Kind == "textarea" || v.Kind == "select"
	var tone, background string
	_, padded := uiFind(v.Attrs, "pad")
	for _, a := range v.Attrs {
		switch a.Kind {
		case "gap":
			b.gap = float64(a.Num)
		case "pad":
			b.padX, b.padY = float64(a.Num), float64(a.Num)
		case "width":
			b.width = float64(max(a.Num, 0))
		case "height":
			b.height = float64(max(a.Num, 0))
		case "grow":
			b.grow = float64(max(a.Num, 0))
		case "align":
			b.align = a.Word
		case "justify":
			b.justify = a.Word
		case "scroll":
			b.scroll = a.Word
		case "tone":
			tone = a.Word
		case "background":
			background = a.Word
		case "disabled":
			b.disabled = b.disabled || a.Flag
		case "busy":
			b.disabled = b.disabled || a.Flag
			if a.Flag && v.Kind != "button" {
				b.opacity = 0.6
			}
		case "kind":
			b.input = a.Word
		case "border":
			b.edge = float64(max(a.Num, 0))
		case "borderTone":
			b.edgeTone = a.Word
		case "radius":
			b.radius = float64(max(a.Num, 0))
		case "ring":
			b.noRing = !a.Flag
		case "hover":
			b.hoverTone = a.Word
		}
	}
	level := 0
	if h, ok := uiFind(v.Attrs, "heading"); ok && v.Kind == "text" && h.Num >= 1 && h.Num <= 6 {
		level = h.Num
		b.font.px *= uiHeadingSize[level]
		b.font.weight = 700
	}
	if s, ok := uiFind(v.Attrs, "size"); ok && !formed {
		switch s.Word {
		case "Title":
			b.font.px, b.font.weight = 20, 700
		case "Subtitle":
			b.font.px, b.font.weight = 16, 600
		case "Caption":
			b.font.px = 12
		}
	}
	b.margin = uiHeadingMargin[level] * b.font.px
	if c, ok := uiParseColour(background); ok {
		b.fill = c
	} else {
		switch background {
		case "Normal":
			b.fill = n.pal.bg
		case "Muted":
			b.fill = n.pal.surface
		case "Good":
			b.fill, b.colour = n.pal.good, uiWhite
		case "Warn":
			b.fill, b.colour = n.pal.warn, uiHexRGB(0x15181c)
		case "Danger":
			b.fill, b.colour = n.pal.danger, uiWhite
		}
	}
	if c, ok := uiParseColour(tone); ok {
		b.colour = c
	} else if c, ok := n.pal.role(tone); ok {
		b.colour = c
	}
	if code {
		b.code = true
		b.font.mono = true
		if _, sized := uiFind(v.Attrs, "size"); !sized {
			b.font.px = 13
		}
		if size, ok := uiFind(v.Attrs, "fontSize"); ok && size.Num >= 6 && size.Num <= 72 {
			b.font.px = float64(size.Num)
		}
	}
	b.lineH = b.font.px * 1.5
	switch v.Kind {
	case "row", "column", "overlay", "inset":
		b.container = true
		b.row = v.Kind == "row"
		if v.Kind == "inset" {
			n.insetBoxes = append(n.insetBoxes, b)
		}
	case "scene":
		if n.sceneBox == nil {
			n.sceneBox = b
		}
	case "button":
		if !padded {
			b.padX, b.padY = 14, 6
		}
		b.border = 1
	case "input":
		if b.input == "Range" {
			b.inset = 2
			if b.width >= 0 {
				b.width += 4
			}
			if b.height >= 0 {
				b.height += 4
			}
			break
		}
		fallthrough
	case "textarea", "select":
		if !padded {
			b.padX, b.padY = 10, 8
		}
		b.border = 1
		if v.Kind == "textarea" {
			b.full = b.width < 0
			b.floor = 64
			if tall, ok := n.grown[path]; ok {
				b.height = tall
			}
		}
	case "table":
		b.full = b.width < 0
		b.grid = n.grid(b)
	case "canvas":
		b.full = b.width < 0
	case "image":
		b.pic = n.picture(v.Text)
	case "icon":
		b.font.icon = true
	case "link":
		if _, own := uiParseColour(tone); !own {
			b.colour = n.pal.accent
		}
	}
	if parent == nil {
		b.container = true
		b.row = false
	}
	for i := range v.Children {
		k := n.build(&v.Children[i], path+"/"+strconv.Itoa(i), b)
		switch {
		case k == nil:
		case k.kind == "overlay":
			n.layers = append(n.layers, n.layer(k))
		default:
			b.kids = append(b.kids, k)
		}
	}
	return b
}

func (n *uiNative) layer(p *uiBox) *uiLayer {
	a, aligned := p.attr("align")
	j, justified := p.attr("justify")
	an, anchored := p.attr("anchor")
	l := &uiLayer{panel: p, pinned: aligned || justified || anchored, align: "Center", justify: "Center"}
	if anchored {
		l.anchor = an.Word
		if d, ok := p.attr("onDismiss"); ok {
			l.dismiss = []UiAttr{{Kind: "on", heard: d.heard}}
		}
	}
	shade := &UiView{Kind: "backdrop"}
	if d, ok := p.attr("onDismiss"); ok && !l.pinned {
		shade.Attrs = []UiAttr{{Kind: "on", heard: d.heard}}
	}
	l.backdrop = &uiBox{kind: "backdrop", v: shade, path: p.path + "/backdrop", seq: p.seq, opacity: 1}
	background, _ := p.attr("background")
	if _, colour := uiParseColour(background.Word); !colour {
		p.fill = uiRGBA{}
		if !l.pinned {
			p.fill = n.pal.bg
		}
	}
	p.scroll = "Both"
	if anchored {
		p.row = false
		if p.fill == (uiRGBA{}) {
			p.fill = n.pal.bg
		}
		p.border = math.Max(p.border, 1)
		p.corner = 8
		return l
	}
	if l.pinned {
		p.row = true
		if aligned {
			l.align = a.Word
		}
		if justified {
			l.justify = j.Word
		}
		return l
	}
	p.row = false
	p.corner = 16
	p.align, p.justify = "Stretch", ""
	if len(p.kids) == 1 && uiInline(p.kids[0].kind) {
		p.align = "Start"
	}
	return l
}

func uiInline(kind string) bool {
	switch kind {
	case "text", "icon", "link", "button", "input", "textarea", "select", "checkbox":
		return true
	}
	return false
}

func (n *uiNative) grid(b *uiBox) *uiGrid {
	g := &uiGrid{}
	wide := 0
	for _, r := range b.v.Rows {
		wide = max(wide, len(r))
	}
	for _, r := range b.v.Rows {
		cells := make([]string, wide)
		for i, c := range r {
			cells[i] = strings.Join(strings.Fields(c), " ")
		}
		g.cells = append(g.cells, cells)
		g.count = append(g.count, len(r))
	}
	_, g.sortable = b.attr("onSort")
	_, g.pickable = b.attr("onPick")
	return g
}

func (b *uiBox) cellFont(row int) uiFont {
	if row == 0 {
		return uiFont{px: b.font.px, weight: 600}
	}
	return b.font
}

func (n *uiNative) glyphs(b *uiBox) string {
	if b.kind == "icon" {
		return uiIconGlyph(b.v.Text)
	}
	if b.kind == "input" {
		return ""
	}
	return b.v.Text
}

func (n *uiNative) letter(f uiFont, s string) float64 {
	least := 0.0
	for _, r := range s {
		if !unicode.IsSpace(r) {
			least = math.Max(least, n.measure(f, string(r)))
		}
	}
	return least
}

func (n *uiNative) longestWord(f uiFont, s string) float64 {
	least := 0.0
	for _, word := range strings.Fields(s) {
		least = math.Max(least, n.measure(f, word))
	}
	return least
}

const uiArrowRoom = 20

const uiDateRoom = 46

func (n *uiNative) intrinsic(b *uiBox) {
	for _, k := range b.kids {
		n.intrinsic(k)
	}
	edge := 2*b.padX + 2*b.border
	switch b.kind {
	case "text", "link", "icon":
		widest := 0.0
		for _, line := range strings.Split(n.glyphs(b), "\n") {
			widest = math.Max(widest, n.measure(b.font, line))
		}
		b.maxW, b.minW = widest+edge, n.letter(b.font, n.glyphs(b))+edge
	case "button":
		b.maxW = n.measure(b.font, b.v.Text) + edge
		b.minW = n.longestWord(b.font, b.v.Text) + edge
	case "input":
		switch b.input {
		case "Range":
			b.maxW = 129 + 2*b.inset + edge
		case "Date":
			b.maxW = n.measure(b.font, n.dateSample()) + uiDateRoom + edge
		default:
			b.maxW = 20*n.dev.average(b.font) + edge
		}
		b.minW = b.maxW
	case "textarea":
		b.maxW = 20*n.dev.average(b.font) + edge
		b.minW = edge
	case "select":
		widest := 0.0
		for _, o := range b.v.Options {
			widest = math.Max(widest, n.measure(b.font, o))
		}
		b.maxW = widest + uiArrowRoom + edge
		b.minW = edge
	case "checkbox":
		b.maxW = 26 + n.measure(b.font, b.v.Text) + edge
		b.minW = 26 + n.longestWord(b.font, b.v.Text) + edge
	case "spinner":
		b.maxW, b.minW = 18, 4
	case "table":
		g := b.grid
		wide := 0
		if len(g.cells) > 0 {
			wide = len(g.cells[0])
		}
		g.minC, g.maxC = make([]float64, wide), make([]float64, wide)
		for r, cells := range g.cells {
			f := b.cellFont(r)
			for c, text := range cells[:g.count[r]] {
				g.maxC[c] = math.Max(g.maxC[c], n.measure(f, text)+20)
				g.minC[c] = math.Max(g.minC[c], n.letter(f, text)+20)
			}
		}
		sumMin, sumMax := 0.0, 0.0
		for c := range g.minC {
			sumMin += g.minC[c]
			sumMax += g.maxC[c]
		}
		b.maxW, b.minW = sumMax+edge, sumMin+edge
	case "image":
		w, _ := n.pictureSize(b, -1)
		b.maxW, b.minW = w, w
	case "canvas":
		b.maxW, b.minW = 300, 0
	default:
		if !b.container {
			b.maxW, b.minW = edge, edge
			break
		}
		gaps := b.gap * float64(max(len(b.kids)-1, 0))
		sumMax, sumMin, topMax, topMin := 0.0, 0.0, 0.0, 0.0
		for _, k := range b.kids {
			sumMax += k.maxW
			sumMin += k.minW
			topMax = math.Max(topMax, k.maxW)
			topMin = math.Max(topMin, k.minW)
		}
		if b.row {
			b.maxW, b.minW = sumMax+gaps+edge, sumMin+gaps+edge
		} else {
			b.maxW, b.minW = topMax+edge, topMin+edge
		}
	}
	if b.width >= 0 {
		b.maxW, b.minW = b.width, b.width
	}
}

func (n *uiNative) pictureSize(b *uiBox, w float64) (float64, float64) {
	if b.pic.failed() && b.alt() != "" {
		if w < 0 {
			w = 16 + n.measure(b.font, b.alt())
			if b.width >= 0 {
				w = b.width
			}
		}
		if b.height >= 0 {
			return w, b.height
		}
		return w, b.lineH
	}
	pw, ph := b.pic.natural()
	if w < 0 {
		switch {
		case b.width >= 0:
			w = b.width
		case b.height >= 0 && ph > 0:
			w = b.height * pw / ph
		default:
			w = pw
		}
	}
	h := 0.0
	switch {
	case b.height >= 0:
		h = b.height
	case pw > 0:
		h = w * ph / pw
	}
	return w, h
}

func (n *uiNative) leastW(b *uiBox, room float64) float64 {
	edge := 2*b.padX + 2*b.border
	switch {
	case b.scroll != "", b.kind == "input" && b.input != "Range", b.kind == "textarea", b.kind == "select":
		return edge
	case b.kind == "canvas":
		return 0
	case b.kind == "image":
		return math.Min(b.minW, room)
	}
	return b.minW
}

type uiFlex struct {
	basis, min, max, grow, shrink float64
	size                          float64
	frozen                        bool
}

func uiResolveFlex(items []uiFlex, space float64) {
	sum := 0.0
	for i := range items {
		sum += uiClamp(items[i].basis, items[i].min, items[i].max)
	}
	growing := sum < space
	for i := range items {
		it := &items[i]
		hyp := uiClamp(it.basis, it.min, it.max)
		it.size = hyp
		factor := it.shrink
		if growing {
			factor = it.grow
		}
		it.frozen = factor == 0 || (growing && it.basis > hyp) || (!growing && it.basis < hyp)
	}
	initial := math.NaN()
	for round := 0; round < len(items)+1; round++ {
		free := space
		factors, scaled := 0.0, 0.0
		open := 0
		for _, it := range items {
			if it.frozen {
				free -= it.size
				continue
			}
			free -= it.basis
			open++
			if growing {
				factors += it.grow
			} else {
				factors += it.shrink
				scaled += it.shrink * it.basis
			}
		}
		if open == 0 {
			return
		}
		if math.IsNaN(initial) {
			initial = free
		}
		if factors < 1 && math.Abs(initial*factors) < math.Abs(free) {
			free = initial * factors
		}
		violation := 0.0
		for i := range items {
			it := &items[i]
			if it.frozen {
				continue
			}
			target := it.basis
			if growing && factors > 0 {
				target += free * it.grow / factors
			} else if !growing && scaled > 0 {
				target += free * it.shrink * it.basis / scaled
			}
			clamped := uiClamp(target, it.min, it.max)
			violation += clamped - target
			it.size = clamped
		}
		for i := range items {
			it := &items[i]
			if it.frozen {
				continue
			}
			switch {
			case violation == 0:
				it.frozen = true
			case violation > 0 && it.size <= it.min:
				it.frozen = true
			case violation < 0 && it.size >= it.max:
				it.frozen = true
			}
		}
	}
}

func uiStretches(align string) bool { return align == "" || align == "Stretch" }

func (n *uiNative) sizeW(b *uiBox, w float64) {
	if b.kind == "table" {
		w = math.Max(w, b.minW)
	}
	b.w = w
	if !b.container {
		return
	}
	inner := math.Max(w-2*b.padX, 0)
	if b.row {
		items := make([]uiFlex, len(b.kids))
		for i, k := range b.kids {
			it := uiFlex{max: math.Inf(1), shrink: 1}
			switch {
			case k.grow > 0:
				it.grow = k.grow
			case k.kind == "spacer":
				it.grow = 1
			case k.width >= 0:
				it.basis, it.shrink = k.width, 0
			case k.full:
				it.basis = inner
			default:
				it.basis = k.maxW
			}
			it.min = n.leastW(k, inner)
			if b.scroll == "Horizontal" && it.grow == 0 {
				it.shrink = 0
				it.min = math.Max(it.min, it.basis)
			}
			if k.width >= 0 && (k.container || k.kind == "image") {
				if b.scroll != "Horizontal" {
					it.min = math.Min(it.min, inner)
				}
				it.max = math.Max(inner, it.min)
			}
			items[i] = it
		}
		uiResolveFlex(items, inner-b.gap*float64(max(len(b.kids)-1, 0)))
		for i, k := range b.kids {
			n.sizeW(k, items[i].size)
		}
		return
	}
	for _, k := range b.kids {
		var kw float64
		switch {
		case k.width >= 0:
			kw = k.width
			if k.container || k.kind == "image" {
				kw = math.Min(kw, inner)
			}
		case k.full:
			kw = inner
		case k.kind == "spinner":
			kw = k.maxW
		case uiStretches(b.align):
			kw = inner
		default:
			kw = math.Min(k.maxW, math.Max(k.minW, inner))
		}
		n.sizeW(k, kw)
	}
}

func (n *uiNative) wrap(f uiFont, s string, width float64, anywhere bool) []string {
	var lines []string
	for _, para := range strings.Split(s, "\n") {
		if n.measure(f, para) <= width+0.01 {
			lines = append(lines, para)
			continue
		}
		line := ""
		for _, word := range uiWords(para) {
			try := line + word
			if line == "" || n.measure(f, strings.TrimRight(try, " ")) <= width+0.01 {
				line = try
			} else {
				lines = append(lines, line)
				line = word
			}
			for anywhere && n.measure(f, strings.TrimRight(line, " ")) > width+0.01 && utf8.RuneCountInString(line) > 1 {
				cut := n.fits(f, line, width)
				lines = append(lines, line[:cut])
				line = line[cut:]
			}
		}
		lines = append(lines, line)
	}
	return lines
}

func uiWords(s string) []string {
	var out []string
	start := 0
	for i := 1; i < len(s); i++ {
		if s[i-1] == ' ' && s[i] != ' ' {
			out = append(out, s[start:i])
			start = i
		}
	}
	return append(out, s[start:])
}

func (n *uiNative) fits(f uiFont, s string, width float64) int {
	cut := 0
	for i := range s {
		if i > 0 && n.measure(f, s[:i]) > width+0.01 {
			break
		}
		cut = i
	}
	if cut == 0 {
		_, size := utf8.DecodeRuneInString(s)
		return size
	}
	return cut
}

func uiColumnItem(k *uiBox) uiFlex {
	it := uiFlex{max: math.Inf(1), shrink: 1, min: k.minH}
	switch {
	case k.grow > 0:
		it.grow = k.grow
	case k.kind == "spacer":
		it.grow = 1
	case k.height >= 0:
		it.basis = k.height
		if k.width >= 0 {
			it.shrink = 0
		}
	default:
		it.basis = k.natH
	}
	return it
}

func uiShare(least, most []float64, width float64) []float64 {
	out := make([]float64, len(least))
	sumMin, sumMax := 0.0, 0.0
	for i := range least {
		sumMin += least[i]
		sumMax += most[i]
	}
	for i := range out {
		switch {
		case width >= sumMax && sumMax > 0:
			out[i] = most[i] + (width-sumMax)*most[i]/sumMax
		case width >= sumMax:
			out[i] = width / float64(len(out))
		case width > sumMin:
			out[i] = least[i] + (most[i]-least[i])*(width-sumMin)/(sumMax-sumMin)
		default:
			out[i] = least[i]
		}
	}
	return out
}

func (n *uiNative) natural(b *uiBox) {
	for _, k := range b.kids {
		n.natural(k)
	}
	edgeX := 2*b.padX + 2*b.border
	edgeY := 2*b.padY + 2*b.border
	content := 0.0
	switch b.kind {
	case "text", "link", "icon":
		b.lines = n.wrap(b.font, n.glyphs(b), math.Max(b.w-edgeX, 0), true)
		content = float64(len(b.lines))*b.lineH + edgeY + 2*b.margin
	case "button":
		b.lines = n.wrap(b.font, b.v.Text, math.Max(b.w-edgeX, 0), false)
		content = float64(len(b.lines))*b.lineH + edgeY
	case "input", "select":
		content = b.lineH + edgeY
		switch b.input {
		case "Range":
			content = 16 + 2*b.inset + edgeY
		case "Date":
			content += 2
		}
	case "textarea":
		content = 2*b.lineH + edgeY
	case "checkbox":
		b.lines = n.wrap(b.font, b.v.Text, math.Max(b.w-edgeX-26, 0), false)
		content = math.Max(19, float64(len(b.lines))*b.lineH) + edgeY
	case "spinner":
		content = 18
	case "table":
		content = n.tableRows(b) + edgeY
	case "image":
		_, content = n.pictureSize(b, b.w)
	case "canvas":
		region := uiNumbers(b.v.Attrs, "region", []float64{0, 0, 100, 100})
		if region[2] <= 0 || region[3] <= 0 {
			region = []float64{0, 0, 100, 100}
		}
		content = b.w * region[3] / region[2]
	default:
		if !b.container {
			content = edgeY
			break
		}
		gaps := b.gap * float64(max(len(b.kids)-1, 0))
		if b.row {
			for _, k := range b.kids {
				tall := k.natH
				if k.height >= 0 {
					tall = k.height
				}
				content = math.Max(content, tall)
			}
			content += edgeY
		} else {
			for _, k := range b.kids {
				it := uiColumnItem(k)
				content += uiClamp(it.basis, it.min, it.max)
			}
			content += gaps + edgeY
		}
	}
	b.natH = content
	b.minH = content
	if b.height >= 0 {
		b.natH = b.height
		b.minH = math.Min(b.height, content)
	}
	if b.floor > 0 {
		b.natH = math.Max(b.natH, b.floor)
		b.minH = math.Max(b.minH, b.floor)
	}
	if b.scroll != "" {
		b.minH = edgeY
	}
}

func (n *uiNative) tableRows(b *uiBox) float64 {
	g := b.grid
	g.cols = uiShare(g.minC, g.maxC, math.Max(b.w-2*b.padX-2*b.border, 0))
	g.heights = g.heights[:0]
	g.wrapped = g.wrapped[:0]
	total := 0.0
	for r, cells := range g.cells {
		f := b.cellFont(r)
		lines := 1
		wrapped := make([][]string, len(cells))
		for c, text := range cells[:g.count[r]] {
			wrapped[c] = n.wrap(f, text, math.Max(g.cols[c]-20, 0), true)
			lines = max(lines, len(wrapped[c]))
		}
		tall := float64(lines)*b.lineH + 17
		g.heights = append(g.heights, tall)
		g.wrapped = append(g.wrapped, wrapped)
		total += tall
	}
	return total
}

func (n *uiNative) sizeH(b *uiBox, h float64) {
	b.h = h
	if !b.container {
		return
	}
	inner := math.Max(h-2*b.padY, 0)
	if !b.row {
		items := make([]uiFlex, len(b.kids))
		for i, k := range b.kids {
			items[i] = uiColumnItem(k)
		}
		uiResolveFlex(items, inner-b.gap*float64(max(len(b.kids)-1, 0)))
		for i, k := range b.kids {
			n.sizeH(k, items[i].size)
		}
		return
	}
	for _, k := range b.kids {
		kh := k.natH
		switch {
		case k.height >= 0:
			kh = k.height
		case k.kind == "spinner":
		case uiStretches(b.align):
			kh = inner
		}
		n.sizeH(k, kh)
	}
}

func uiJustify(justify string, free float64, count int) (float64, float64) {
	switch justify {
	case "Center":
		return free / 2, 0
	case "End":
		return free, 0
	case "Between":
		if count > 1 && free > 0 {
			return 0, free / float64(count-1)
		}
	}
	return 0, 0
}

func uiCross(align string, room float64, size float64) float64 {
	switch align {
	case "Center":
		return (room - size) / 2
	case "End":
		return room - size
	}
	return 0
}

func (n *uiNative) place(b *uiBox, x, y float64) {
	b.x, b.y = x, y
	if !b.container {
		return
	}
	innerW := math.Max(b.w-2*b.padX, 0)
	innerH := math.Max(b.h-2*b.padY, 0)
	used := b.gap * float64(max(len(b.kids)-1, 0))
	for _, k := range b.kids {
		if b.row {
			used += k.w
		} else {
			used += k.h
		}
	}
	if b.row {
		start, extra := uiJustify(b.justify, innerW-used, len(b.kids))
		at := x + b.padX + start
		for _, k := range b.kids {
			n.place(k, at, y+b.padY+uiCross(b.align, innerH, k.h))
			at += k.w + b.gap + extra
		}
	} else {
		start, extra := uiJustify(b.justify, innerH-used, len(b.kids))
		at := y + b.padY + start
		for _, k := range b.kids {
			n.place(k, x+b.padX+uiCross(b.align, innerW, k.w), at)
			at += k.h + b.gap + extra
		}
	}
	if b.scroll != "" {
		n.scrolled(b, b.padX, b.padY)
	}
}

func uiReach(b *uiBox, right, bottom *float64) {
	*right = math.Max(*right, b.x+b.w)
	*bottom = math.Max(*bottom, b.y+b.h)
	if b.scroll != "" {
		return
	}
	for _, k := range b.kids {
		uiReach(k, right, bottom)
	}
}

func uiShift(b *uiBox, dx, dy float64) {
	b.x += dx
	b.y += dy
	for _, k := range b.kids {
		uiShift(k, dx, dy)
	}
}

func (n *uiNative) scrolled(b *uiBox, endX, endY float64) {
	right, bottom := b.x, b.y
	for _, k := range b.kids {
		uiReach(k, &right, &bottom)
	}
	b.extentW = right - b.x + endX
	b.extentH = bottom - b.y + endY
	if b.extentW <= b.w+0.5 {
		b.extentW = b.w
	}
	if b.extentH <= b.h+0.5 {
		b.extentH = b.h
	}
	at := n.scrolls[b.path]
	at[0] = uiClamp(at[0], 0, b.extentW-b.w)
	at[1] = uiClamp(at[1], 0, b.extentH-b.h)
	if b.scroll == "Vertical" {
		at[0] = 0
	}
	if b.scroll == "Horizontal" {
		at[1] = 0
	}
	n.scrolls[b.path] = at
	for _, k := range b.kids {
		uiShift(k, -at[0], -at[1])
	}
}

func (n *uiNative) layout() {
	if !n.stale || n.dev == nil {
		return
	}
	n.stale = false
	n.touched()
	view := n.last
	n.seq = 0
	n.layers = n.layers[:0]
	n.sceneBox, n.insetBoxes = nil, n.insetBoxes[:0]
	root := n.build(&UiView{Kind: "column", Children: []UiView{view}}, "r", nil)
	n.forget()
	n.intrinsic(root)
	n.sizeW(root, n.vw)
	n.natural(root)
	n.sizeH(root, math.Max(n.vh, root.natH))
	n.place(root, 0, 0)
	root.scroll = "Both"
	root.h = n.vh
	n.scrolled(root, 0, 0)
	n.root = root
	for _, l := range n.layers {
		n.arrange(l)
	}
	n.boxes = map[string]*uiBox{}
	n.order = n.order[:0]
	n.index(root)
	for _, l := range n.layers {
		n.boxes[l.backdrop.path] = l.backdrop
		n.index(l.panel)
	}
	sort.SliceStable(n.order, func(i, j int) bool { return n.order[i].seq < n.order[j].seq })
	n.reconcile()
	n.collectRuns()
	for path := range n.grown {
		if b, ok := n.boxes[path]; !ok || b.kind != "textarea" {
			delete(n.grown, path)
		}
	}
	switch {
	case uiStageMake == nil:
	case n.sceneBox != nil:
		if n.stage == nil {
			n.stage = uiStageMake(n)
		}
		n.stage.settle()
	case n.stage != nil:
		n.stage.idle()
	}
}

func (n *uiNative) arrange(l *uiLayer) {
	p := l.panel
	n.intrinsic(p)
	room := math.Max(n.vw-24, 0)
	w := math.Min(p.maxW, room)
	if p.grow > 0 {
		w = room
	}
	n.sizeW(p, w)
	n.natural(p)
	h := p.natH
	if !l.pinned {
		h = math.Min(h, 0.85*n.vh)
	} else if l.align == "Stretch" {
		h = math.Max(n.vh-24, 0)
	}
	n.sizeH(p, h)
	x, y := (n.vw-w)/2, (n.vh-h)/2
	if l.anchor != "" {
		x, y = n.spot[0], n.spot[1]
		above := y
		if l.anchor == "Caret" {
			if cx, cy, ok := n.caretSpot(); ok {
				b := n.boxes[n.focus]
				x, above = float64(cx)/n.scale, float64(cy)/n.scale
				y = above + b.lineH
			}
		}
		x = math.Max(4, math.Min(x, n.vw-w-4))
		if y+h > n.vh-4 {
			y = math.Min(above-h, n.vh-h-4)
		}
		n.place(p, x, math.Max(4, y))
		l.backdrop.w, l.backdrop.h = n.vw, n.vh
		return
	}
	if l.pinned {
		switch l.justify {
		case "Start", "Between":
			x = 12
		case "End":
			x = n.vw - 12 - w
		}
		switch l.align {
		case "Start", "Stretch":
			y = 12
		case "End":
			y = n.vh - 12 - h
		}
	}
	n.place(p, x, y)
	l.backdrop.w, l.backdrop.h = n.vw, n.vh
}

func (n *uiNative) index(b *uiBox) {
	n.boxes[b.path] = b
	if b.focusable() {
		n.order = append(n.order, b)
	}
	for _, k := range b.kids {
		n.index(k)
	}
}

func (n *uiNative) reconcile() {
	for path, f := range n.fields {
		b, ok := n.boxes[path]
		if !ok || !b.editable() {
			delete(n.fields, path)
			continue
		}
		value := b.v.Text
		switch {
		case path != n.focus:
			n.settle(b, f, value)
		case f.value() == value || n.numeric(b, f) == value:
			f.sent = nil
		default:
			caught := -1
			for i, s := range f.sent {
				if s == value {
					caught = i
				}
			}
			if caught >= 0 {
				f.sent = f.sent[caught+1:]
			} else {
				n.settle(b, f, value)
			}
		}
	}
	for path, b := range n.boxes {
		if !b.editable() {
			continue
		}
		if _, ok := n.fields[path]; !ok {
			f := &uiEntry{goal: -1, seen: -1}
			f.set(b.v.Text)
			n.fields[path] = f
		}
	}
	for path, b := range n.boxes {
		f := n.fields[path]
		c, ok := b.attr("caret")
		if !b.code || f == nil || !ok || len(c.Nums) != 3 {
			continue
		}
		want := strconv.Itoa(int(c.Nums[0])) + "," + strconv.Itoa(int(c.Nums[1])) + "," + strconv.Itoa(int(c.Nums[2]))
		if want == f.caretSet {
			continue
		}
		f.caretSet = want
		f.anchor = max(0, min(int(c.Nums[0]), len(f.text)))
		f.caret = max(0, min(int(c.Nums[1]), len(f.text)))
		f.told = strconv.Itoa(f.anchor) + "," + strconv.Itoa(f.caret)
		f.goal, f.seen = -1, -1
	}
	for path, b := range n.boxes {
		if c, ok := b.attr("clip"); ok {
			if seen, ok := n.clips[path]; ok && seen != c.Num {
				n.dev.setClipboard(c.Word)
			}
			n.clips[path] = c.Num
		}
		p, ok := b.attr("perform")
		if !ok {
			continue
		}
		seen, known := n.performed[path]
		n.performed[path] = p.Num
		f := n.fields[path]
		if !known || seen == p.Num || f == nil {
			continue
		}
		n.focus, n.keyboard, n.blink = path, false, true
		switch p.Word {
		case "selectAll":
			f.anchor, f.caret = 0, len(f.text)
		case "undo":
			n.undo(b, f, true)
		case "redo":
			n.undo(b, f, false)
		case "cut":
			n.fieldKey(b, uiKeyCut, false, false)
		case "copy":
			n.fieldKey(b, uiKeyCopy, false, false)
		case "paste":
			n.fieldKey(b, uiKeyPaste, false, false)
		}
	}
	for path, b := range n.boxes {
		a, ok := b.attr("focus")
		if !ok {
			continue
		}
		if seen, ok := n.asked[path]; ok && seen == a.Num {
			continue
		}
		n.asked[path] = a.Num
		if t := uiFocusable(b); t != nil {
			n.focus, n.keyboard, n.blink = t.path, false, true
		}
	}
	for path, d := range n.dates {
		if b, ok := n.boxes[path]; !ok || b.kind != "input" || b.input != "Date" {
			delete(n.dates, path)
		} else if path != n.focus || d.value() != b.v.Text && !d.partial() {
			d.set(b.v.Text)
		}
	}
	for path, b := range n.boxes {
		if b.kind == "input" && b.input == "Date" && n.dates[path] == nil {
			d := &uiDate{}
			d.set(b.v.Text)
			n.dates[path] = d
		}
	}
	if b, ok := n.boxes[n.focus]; !ok || !b.focusable() {
		n.focus = ""
	}
	if _, ok := n.boxes[n.hover]; !ok {
		n.hover = ""
	}
	if _, ok := n.boxes[n.press]; !ok {
		n.press = ""
	}
	if n.popup != nil && n.popup.kind != "menu" {
		if b, ok := n.boxes[n.popup.path]; !ok || b.disabled {
			n.popup = nil
		}
	}
}

func (f *uiEntry) set(value string) {
	f.text = []rune(value)
	f.str, f.strOK, f.linesOK = value, true, false
	f.caret = len(f.text)
	f.anchor = f.caret
	f.sent = nil
	f.goal = -1
}

func (n *uiNative) dp(v float64) int { return int(math.Round(v * n.scale)) }

func (n *uiNative) rectOf(b *uiBox) (float64, float64, float64, float64) {
	s := n.scale
	return math.Round((b.x + b.inset) * s), math.Round((b.y + b.margin + b.inset) * s),
		math.Round((b.x + b.w - b.inset) * s), math.Round((b.y + b.h - b.margin - b.inset) * s)
}
