// The fields past text: a date, a time or both in segments, a slider and a number between
// limits, a colour with a picker of its own, and a file chosen from the desktop.
package hive

import (
	"math"
	"strconv"
	"strings"
	"time"
)

func uiStamp(kind string) bool { return kind == "Date" || kind == "Time" || kind == "DateTime" }

// The segments a stamped field shows, in the order the desktop writes a date.
func (n *uiNative) stampOrder(b *uiBox) []byte {
	order, _ := n.dateOrder()
	switch b.input {
	case "Time":
		return []byte{'h', 'm'}
	case "DateTime":
		return append(order[:], 'h', 'm')
	}
	return order[:]
}

// What is written after segment i of order.
func (n *uiNative) stampSep(order []byte, i int) string {
	if i >= len(order)-1 {
		return ""
	}
	switch {
	case order[i] == 'h':
		return ":"
	case order[i+1] == 'h':
		return " "
	}
	_, sep := n.dateOrder()
	return sep
}

func (n *uiNative) stampSample(b *uiBox) string {
	order := n.stampOrder(b)
	var out strings.Builder
	for i, p := range order {
		if p == 'y' {
			out.WriteString("0000")
		} else {
			out.WriteString("00")
		}
		out.WriteString(n.stampSep(order, i))
	}
	return out.String()
}

func uiStampSlots(kind string) []int {
	switch kind {
	case "Time":
		return []int{3, 4}
	case "DateTime":
		return []int{0, 1, 2, 3, 4}
	}
	return []int{0, 1, 2}
}

func (d *uiDate) setStamp(value string) {
	d.parts = [5]int{}
	d.typed = ""
	date, clock := value, ""
	switch d.kind {
	case "Time":
		date, clock = "", value
	case "DateTime":
		date, clock, _ = strings.Cut(value, "T")
	}
	if date != "" {
		if t, err := time.Parse("2006-01-02", date); err == nil {
			d.parts[0], d.parts[1], d.parts[2] = t.Year(), int(t.Month()), t.Day()
		}
	}
	if clock != "" {
		h, m, ok := uiClockOf(clock)
		if ok && (d.kind == "Time" || d.parts[0] != 0) {
			d.parts[3], d.parts[4] = h+1, m+1
		}
	}
	d.sent = d.value()
}

func uiClockOf(s string) (int, int, bool) {
	parts := strings.Split(s, ":")
	if len(parts) < 2 || len(parts) > 3 || len(parts[0]) != 2 || len(parts[1]) != 2 {
		return 0, 0, false
	}
	h, err1 := strconv.Atoi(parts[0])
	m, err2 := strconv.Atoi(parts[1])
	if err1 != nil || err2 != nil || h < 0 || h > 23 || m < 0 || m > 59 {
		return 0, 0, false
	}
	return h, m, true
}

func (d *uiDate) dayValue() string {
	y, m, day := d.parts[0], d.parts[1], d.parts[2]
	if y == 0 || m == 0 || day == 0 {
		return ""
	}
	if t := time.Date(y, time.Month(m), day, 0, 0, 0, 0, time.UTC); t.Day() != day {
		return ""
	}
	return uiPad(y, 4) + "-" + uiPad(m, 2) + "-" + uiPad(day, 2)
}

func (d *uiDate) clockValue() string {
	if d.parts[3] == 0 || d.parts[4] == 0 {
		return ""
	}
	return uiPad(d.parts[3]-1, 2) + ":" + uiPad(d.parts[4]-1, 2)
}

// --- a slider and a number between limits --------------------------------

func uiSnap(v, low, high, step float64) float64 {
	if step > 0 {
		v = low + math.Round((v-low)/step)*step
		if v > high {
			v -= step
		}
	}
	return uiClamp(v, low, math.Max(low, high))
}

func uiNumberText(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 32)
}

// A range with nothing on it stands in the middle, as a browser's does.
func (n *uiNative) rangeValue(b *uiBox) float64 {
	low, high, step := uiLimits(b.v.Attrs)
	text := b.v.Text
	if v, ok := n.pending[b.path]; ok {
		text = v
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
	if err != nil {
		v = low + (high-low)/2
	}
	return uiSnap(v, low, high, step)
}

func (n *uiNative) rangeFraction(b *uiBox) float64 {
	low, high, _ := uiLimits(b.v.Attrs)
	if high <= low {
		return 0
	}
	return (n.rangeValue(b) - low) / (high - low)
}

func (n *uiNative) setRange(b *uiBox, v float64) bool {
	low, high, step := uiLimits(b.v.Attrs)
	v = uiSnap(v, low, high, step)
	if v == n.rangeValue(b) {
		return false
	}
	text := uiNumberText(v)
	n.pending[b.path] = text
	n.post(b.v.Attrs, "input", text, 0)
	return true
}

func (n *uiNative) slide(b *uiBox, x float64) bool {
	from := b.x + b.inset + b.padX + 8
	to := b.x + b.w - b.inset - b.padX - 8
	if to <= from {
		return false
	}
	low, high, _ := uiLimits(b.v.Attrs)
	n.setRange(b, low+uiClamp((x-from)/(to-from), 0, 1)*(high-low))
	return true
}

func (n *uiNative) rangeKey(b *uiBox, k uiKey) bool {
	low, high, step := uiLimits(b.v.Attrs)
	if step <= 0 {
		step = (high - low) / 100
	}
	big := math.Max(step, (high-low)/10)
	v := n.rangeValue(b)
	switch k {
	case uiKeyLeft, uiKeyDown:
		v -= step
	case uiKeyRight, uiKeyUp:
		v += step
	case uiKeyPageUp:
		v += big
	case uiKeyPageDown:
		v -= big
	case uiKeyHome:
		v = low
	case uiKeyEnd:
		v = high
	default:
		return false
	}
	n.setRange(b, uiClamp(v, low, high))
	return true
}

func (n *uiNative) stepNumber(b *uiBox, by int) {
	f := n.fields[b.path]
	if f == nil {
		return
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(string(f.text)), 64)
	if err != nil {
		v = 0
	}
	if _, ok := b.attr("limits"); ok {
		low, high, step := uiLimits(b.v.Attrs)
		if step <= 0 {
			step = 1
		}
		at := (v - low) / step
		switch {
		case math.Abs(at-math.Round(at)) > 1e-9 && by > 0:
			at = math.Ceil(at)
		case math.Abs(at-math.Round(at)) > 1e-9:
			at = math.Floor(at)
		default:
			at = math.Round(at) + float64(by)
		}
		v = uiClamp(low+at*step, low, high)
	} else {
		v += float64(by)
	}
	n.edit(b, f, 0, len(f.text), strconv.FormatFloat(v, 'f', -1, 64))
}

// --- a colour ------------------------------------------------------------------

func (n *uiNative) colourValue(b *uiBox) string {
	text := b.v.Text
	if v, ok := n.pending[b.path]; ok {
		text = v
	}
	if c, ok := uiParseColour(strings.TrimSpace(text)); ok && len(strings.TrimSpace(text)) == 7 {
		return uiHexOf(c)
	}
	return "#000000"
}

func uiHexOf(c uiRGBA) string {
	return "#" + strconv.FormatUint(uint64(uiPack(c)&0xffffff)|1<<24, 16)[1:]
}

func uiHSV(c uiRGBA) [3]float64 {
	r, g, b := float64(c.r)/255, float64(c.g)/255, float64(c.b)/255
	hi, lo := math.Max(r, math.Max(g, b)), math.Min(r, math.Min(g, b))
	h, d := 0.0, hi-lo
	switch {
	case d == 0:
	case hi == r:
		h = math.Mod((g-b)/d+6, 6)
	case hi == g:
		h = (b-r)/d + 2
	default:
		h = (r-g)/d + 4
	}
	s := 0.0
	if hi > 0 {
		s = d / hi
	}
	return [3]float64{h / 6, s, hi}
}

func uiFromHSV(hsv [3]float64) uiRGBA {
	h, s, v := math.Mod(hsv[0], 1)*6, hsv[1], hsv[2]
	c := v * s
	x := c * (1 - math.Abs(math.Mod(h, 2)-1))
	var r, g, b float64
	switch int(h) {
	case 0:
		r, g = c, x
	case 1:
		r, g = x, c
	case 2:
		g, b = c, x
	case 3:
		g, b = x, c
	case 4:
		r, b = x, c
	default:
		r, b = c, x
	}
	m := v - c
	ch := func(f float64) uint8 { return uint8(math.Round(uiClamp(f+m, 0, 1) * 255)) }
	return uiRGBA{ch(r), ch(g), ch(b), 255}
}

const (
	uiPickPad   = 10.0
	uiPickWide  = 200.0
	uiPickTall  = 150.0
	uiPickHueAt = uiPickPad + uiPickTall + 8
	uiPickHue   = 14.0
)

func (n *uiNative) openColour(b *uiBox) {
	c, _ := uiParseColour(n.colourValue(b))
	n.popup = &uiPopup{path: b.path, kind: "colour", hsv: uiHSV(c)}
	n.placePopup()
}

func (n *uiNative) colourPress(x, y float64) {
	p := n.popup
	ly := y - p.y
	switch {
	case ly >= uiPickHueAt-4 && ly < uiPickHueAt+uiPickHue+4:
		p.area = 2
	case ly < uiPickHueAt-4:
		p.area = 1
	default:
		p.area = 0
	}
	n.colourDrag(x, y)
}

func (n *uiNative) colourDrag(x, y float64) {
	p := n.popup
	b := n.boxes[p.path]
	if b == nil || p.area == 0 {
		return
	}
	lx := uiClamp((x-p.x-uiPickPad)/uiPickWide, 0, 1)
	switch p.area {
	case 1:
		p.hsv[1] = lx
		p.hsv[2] = 1 - uiClamp((y-p.y-uiPickPad)/uiPickTall, 0, 1)
	case 2:
		p.hsv[0] = math.Min(lx, 0.9999)
	}
	n.colourChosen(b, uiHexOf(uiFromHSV(p.hsv)))
}

func (n *uiNative) colourChosen(b *uiBox, hex string) {
	if hex == n.colourValue(b) {
		return
	}
	n.pending[b.path] = hex
	n.post(b.v.Attrs, "input", hex, 0)
}

func (n *uiNative) colourKey(b *uiBox, k uiKey) bool {
	if k == uiKeyEnter || k == uiKeySpace {
		n.openColour(b)
		return true
	}
	return false
}

func (n *uiNative) paintColour(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, b.path == n.focus && n.keyboard)
	s := n.scale
	c, _ := uiParseColour(n.colourValue(b))
	inset := (b.border + 6) * s
	if b.disabled {
		c = uiMix(under, c, 0.5)
	}
	cv.round(x0+inset, y0+inset, x1-inset, y1-inset, 4*s, c, clip)
}

func (n *uiNative) paintPicker(cv *uiCanvas, all uiClip) {
	p := n.popup
	s := n.scale
	left, top := (p.x+uiPickPad)*s, (p.y+uiPickPad)*s
	wide, tall := uiPickWide*s, uiPickTall*s
	area := cv.bounds(all).and(uiClip{int(left), int(top), int(left + wide), int(top + tall)})
	if !area.empty() {
		cv.flush()
		for y := area.y0; y < area.y1; y++ {
			row := cv.pix[y*cv.w : (y+1)*cv.w]
			v := 1 - uiClamp((float64(y)+0.5-top)/tall, 0, 1)
			for x := area.x0; x < area.x1; x++ {
				sat := uiClamp((float64(x)+0.5-left)/wide, 0, 1)
				row[x] = uiPack(uiFromHSV([3]float64{p.hsv[0], sat, v}))
			}
		}
	}
	hueTop := (p.y + uiPickHueAt) * s
	strip := cv.bounds(all).and(uiClip{int(left), int(hueTop), int(left + wide), int(hueTop + uiPickHue*s)})
	if !strip.empty() {
		cv.flush()
		for y := strip.y0; y < strip.y1; y++ {
			row := cv.pix[y*cv.w : (y+1)*cv.w]
			for x := strip.x0; x < strip.x1; x++ {
				row[x] = uiPack(uiFromHSV([3]float64{uiClamp((float64(x)+0.5-left)/wide, 0, 0.9999), 1, 1}))
			}
		}
	}
	line := n.hairline()
	mx, my := left+p.hsv[1]*wide, top+(1-p.hsv[2])*tall
	r := 6 * s
	cv.ring(mx-r-line, my-r-line, mx+r+line, my+r+line, r+line, line, uiRGBA{0, 0, 0, 120}, all)
	cv.ring(mx-r, my-r, mx+r, my+r, r, 2*line, uiWhite, all)
	hx := left + p.hsv[0]*wide
	cv.round(hx-2*s, hueTop-2*s, hx+2*s, hueTop+(uiPickHue+2)*s, 2*s, uiWhite, all)
	cv.ring(hx-2*s, hueTop-2*s, hx+2*s, hueTop+(uiPickHue+2)*s, 2*s, line, uiRGBA{0, 0, 0, 120}, all)
}

// --- a file ----------------------------------------------------------------------

// A desktop that can be asked for a file answers through done, on the window's own thread.
type uiFileChooser interface {
	chooseFile(done func(path string))
}

const uiNoFile = "No file chosen"
const uiChooseFile = "Choose file"

func (n *uiNative) fileLabel(b *uiBox) string {
	if v, ok := n.pending[b.path]; ok && v != "" {
		return v
	}
	return uiNoFile
}

func (n *uiNative) chooseFile(b *uiBox) {
	chooser, ok := n.dev.(uiFileChooser)
	if !ok {
		return
	}
	path, attrs := b.path, b.v.Attrs
	chooser.chooseFile(func(file string) {
		if file == "" {
			return
		}
		n.pending[path] = uiBaseName(file)
		n.redo.Store(true)
		if n.wake != nil {
			n.wake()
		}
		go n.sendFiles(attrs, []string{file})
	})
}

func uiBaseName(path string) string {
	cut := strings.LastIndexAny(path, `/\`)
	return path[cut+1:]
}

func (n *uiNative) paintFile(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, b.path == n.focus && n.keyboard)
	s := n.scale
	left := x0 + (b.padX+b.border)*s
	top := y0 + (b.padY+b.border)*s
	lift := n.lift(b)
	button := (n.measure(b.font, uiChooseFile) + 20) * s
	fill := n.pal.surface
	if b.path == n.hover && !b.disabled {
		fill = uiMix(fill, n.pal.fg, 0.08)
	}
	cv.round(left-4*s, top, left-4*s+button, top+b.lineH*s, 6*s, fill, clip)
	box := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
	n.say(b.font, left+6*s, top+lift, uiChooseFile, n.ink(b), box)
	label := n.ellipsized(b.font, n.fileLabel(b), math.Max((x1-left-button-8*s)/s-(b.padX+b.border), 0))
	tone := n.ink(b)
	if _, chosen := n.pending[b.path]; !chosen {
		tone = uiMix(n.pal.bg, n.pal.muted, 1)
	}
	n.say(b.font, left-4*s+button+8*s, top+lift, label, tone, box)
}
