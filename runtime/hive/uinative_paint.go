// Every pixel that is not text.
package hive

import (
	"math"
	"strconv"
	"strings"
	"time"
)

var uiShade = uiRGBA{0, 0, 0, 115}

func (n *uiNative) paint(cv *uiCanvas) {
	n.layout()
	all := uiClip{0, 0, cv.w, cv.h}
	if !cv.dirty.empty() {
		all = all.and(cv.dirty)
	}
	cv.fill(0, 0, cv.w, cv.h, n.pal.bg, all)
	n.spins = n.spins[:0]
	n.anims, n.animDue = n.anims[:0], 0
	if n.root == nil {
		return
	}
	n.paintBox(cv, n.root, all, n.pal.bg)
	n.scrollbars(cv, n.root, all)
	for _, l := range n.layers {
		n.paintLayer(cv, l, all)
	}
	n.paintPopup(cv, all)
	n.paintTip(cv, all)
}

func (n *uiNative) paintBox(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.rectOf(b)
	box := uiClip{int(x0), int(y0), int(x1), int(y1)}
	visible := clip.and(box)
	if b.scroll != "" && visible.empty() {
		return
	}
	if !b.container && clip.and(uiClip{box.x0 - 4, box.y0 - 4, box.x1 + 4, box.y1 + 4}).empty() {
		return
	}
	if b.opacity < 1 {
		area := cv.bounds(visible)
		saved := cv.grab(area)
		defer cv.fade(saved, area, b.opacity)
	}
	framed := b.kind == "button" || b.kind == "input" || b.kind == "textarea" || b.kind == "select"
	if b.hoverTone != "" && b.path == n.lit && !b.disabled && !framed && !visible.empty() {
		lit := n.runColour(b.hoverTone, n.pal.surface)
		corner := b.corner
		if b.radius >= 0 {
			corner = b.radius
		}
		if corner > 0 {
			cv.round(x0, y0, x1, y1, corner*n.scale, lit, clip)
		} else {
			cv.fill(box.x0, box.y0, box.x1, box.y1, lit, clip)
		}
		under = uiMix(under, lit, 1)
	} else if b.fill.a > 0 && !visible.empty() && !framed {
		if b.corner > 0 {
			cv.round(x0, y0, x1, y1, b.corner*n.scale, b.fill, clip)
		} else {
			cv.fill(box.x0, box.y0, box.x1, box.y1, b.fill, clip)
		}
		under = uiMix(under, b.fill, 1)
	}
	switch b.kind {
	case "text", "link", "icon":
		n.paintLines(cv, b, clip, under, b.colour, x0, y0)
	case "button":
		n.paintButton(cv, b, clip, under)
	case "input":
		switch b.input {
		case "Range":
			n.paintRange(cv, b, clip, under)
		case "Date":
			n.paintDate(cv, b, clip, under)
		default:
			n.paintInput(cv, b, clip, under)
		}
	case "textarea":
		n.paintTextarea(cv, b, clip, under)
	case "select":
		n.paintSelect(cv, b, clip, under)
	case "checkbox":
		n.paintCheckbox(cv, b, clip, under)
	case "table":
		n.paintTable(cv, b, clip, under)
	case "spinner":
		n.paintSpinner(cv, b, clip)
	case "image":
		n.paintImage(cv, b, clip, under)
	case "canvas":
		n.paintCanvas(cv, b, clip, under)
	case "scene":
		if n.stage != nil && b == n.sceneBox {
			n.stage.paint(cv, b, clip)
		} else {
			cv.fill(box.x0, box.y0, box.x1, box.y1, uiHexRGB(0x0b0d10), clip)
		}
	}
	inner := clip
	if b.scroll != "" {
		inner = visible
	}
	for _, k := range b.kids {
		n.paintBox(cv, k, inner, under)
	}
	if b.scroll != "" && b != n.root {
		n.scrollbars(cv, b, clip)
	}
}

func (n *uiNative) hairline() float64 { return math.Max(1, math.Floor(n.scale)) }

func (n *uiNative) lift(b *uiBox) float64 { return (b.lineH - n.dev.tall(b.font)) / 2 * n.scale }

func (n *uiNative) say(f uiFont, x, y float64, s string, c uiRGBA, clip uiClip) {
	n.dev.text(f, int(math.Round(x)), int(math.Round(y)), s, c, clip)
}

func (n *uiNative) paintLines(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA, colour uiRGBA, x0, y0 float64) {
	colour = uiMix(under, colour, 1)
	top := y0 + (b.padY+b.border)*n.scale
	left := x0 + (b.padX+b.border)*n.scale
	lift := n.lift(b)
	underline := b.kind == "link" && b.path == n.hover && b.hoverTone == "" && n.lit == ""
	if n.lit == b.path {
		underline = false
	}
	for i, line := range b.lines {
		n.paintChosen(cv, b, -1, i, line, left, top+float64(i)*b.lineH*n.scale, b.font, b.lineH, clip)
		y := top + float64(i)*b.lineH*n.scale + lift
		n.say(b.font, left, y, line, colour, clip)
		if underline && line != "" {
			at := math.Round(y + n.dev.tall(b.font)*n.scale*0.86)
			cv.fill(int(math.Round(left)), int(at), int(math.Round(left+n.measure(b.font, line)*n.scale)), int(at+n.hairline()), colour, clip)
		}
	}
	if b.kind == "link" && b.path == n.focus && n.keyboard {
		x0, y0, x1, y1 := n.rectOf(b)
		line := n.hairline()
		cv.ring(x0-2*line, y0-2*line, x1+2*line, y1+2*line, 4*n.scale, 2*line, n.pal.accent, clip)
	}
}

func (n *uiNative) paintButton(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.rectOf(b)
	fill, edge, ink := n.pal.surface, n.pal.line, b.colour
	coloured := b.fill.a > 0
	if coloured {
		fill = uiMix(under, b.fill, 1)
	}
	tone, _ := b.attr("tone")
	switch tone.Word {
	case "Good":
		if !coloured {
			fill = n.pal.accent
		}
		edge, ink = n.pal.accent, uiWhite
	case "Danger":
		edge, ink = n.pal.danger, n.pal.danger
	}
	if c, ok := uiParseColour(tone.Word); ok {
		ink = c
	}
	width, own := n.edgeOf(b, coloured)
	if b.edgeTone != "" {
		edge = own
	}
	hovered := b.path == n.hover && !b.disabled
	switch {
	case hovered && b.hoverTone != "":
		fill = n.runColour(b.hoverTone, fill)
	case hovered && coloured:
		fill = uiMix(fill, n.pal.fg, 0.12)
	case hovered && tone.Word != "Good":
		edge, ink = n.pal.accent, n.pal.accent
	}
	if b.disabled {
		fill, edge, ink = uiMix(under, fill, 0.5), uiMix(under, edge, 0.5), uiMix(uiMix(under, fill, 0.5), ink, 0.5)
	}
	line := n.hairline()
	radius := (y1 - y0) / 2
	if b.radius >= 0 {
		radius = math.Min(b.radius*n.scale, radius)
	}
	if b.path == n.focus && n.keyboard && !b.noRing {
		cv.ring(x0-2*line, y0-2*line, x1+2*line, y1+2*line, radius+2*line, 2*line, n.pal.accent, clip)
	}
	if width > 0 {
		cv.round(x0, y0, x1, y1, radius, edge, clip)
		cv.round(x0+width, y0+width, x1-width, y1-width, math.Max(radius-width, 0), fill, clip)
	} else {
		cv.round(x0, y0, x1, y1, radius, fill, clip)
	}
	block := float64(len(b.lines)) * b.lineH * n.scale
	top := (y0+y1)/2 - block/2
	lift := n.lift(b)
	ink = uiMix(fill, ink, 1)
	inner := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
	for i, text := range b.lines {
		w := n.measure(b.font, text) * n.scale
		n.say(b.font, (x0+x1)/2-w/2, top+float64(i)*b.lineH*n.scale+lift, text, ink, inner)
	}
}

func (n *uiNative) paintFrame(cv *uiCanvas, b *uiBox, clip uiClip, ringed bool) (float64, float64, float64, float64) {
	x0, y0, x1, y1 := n.rectOf(b)
	line := n.hairline()
	radius := 8 * n.scale
	if b.radius >= 0 {
		radius = b.radius * n.scale
	}
	inside := n.pal.bg
	if b.fill.a > 0 {
		inside = uiMix(n.pal.bg, b.fill, 1)
	}
	edge, colour := n.edgeOf(b, b.fill.a > 0)
	switch {
	case ringed && !b.noRing:
		cv.round(x0-2*line, y0-2*line, x1+2*line, y1+2*line, radius+2*line, n.pal.accent, clip)
		cv.round(x0, y0, x1, y1, radius, inside, clip)
	case edge > 0:
		cv.round(x0, y0, x1, y1, radius, colour, clip)
		cv.round(x0+edge, y0+edge, x1-edge, y1-edge, math.Max(radius-edge, 0), inside, clip)
	default:
		cv.round(x0, y0, x1, y1, radius, inside, clip)
	}
	return x0, y0, x1, y1
}

func (n *uiNative) edgeOf(b *uiBox, coloured bool) (float64, uiRGBA) {
	colour := n.pal.line
	if b.edgeTone != "" {
		colour = n.runColour(b.edgeTone, colour)
	}
	switch {
	case b.edge >= 0:
		return math.Round(b.edge * n.scale), colour
	case coloured && b.edgeTone == "":
		return 0, colour
	}
	return n.hairline(), colour
}

func (n *uiNative) ink(b *uiBox) uiRGBA {
	ink := uiMix(n.pal.bg, b.colour, 1)
	if b.disabled {
		ink = uiMix(n.pal.bg, ink, 0.5)
	}
	return ink
}

func (n *uiNative) paintInput(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	focused := b.path == n.focus
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, focused)
	f := n.fields[b.path]
	if f == nil {
		return
	}
	left := x0 + (b.padX+b.border)*n.scale
	right := x1 - (b.padX+b.border)*n.scale
	top := y0 + (b.padY+b.border)*n.scale
	lift := n.lift(b)
	switch n.extra(b, f) {
	case "clear":
		right -= 16 * n.scale
		mark := uiFont{px: b.font.px * 0.8, weight: b.font.weight, icon: true}
		tone := n.pal.muted
		if b.path == n.hover && n.hoverPart == 1 {
			tone = b.colour
		}
		w := n.measure(mark, "✕") * n.scale
		n.say(mark, right+16*n.scale-w, top+(b.lineH-n.dev.tall(mark))/2*n.scale, "✕", uiMix(n.pal.bg, tone, 1), clip)
	case "spin":
		right -= 15 * n.scale
		n.paintSpin(cv, b, right, y0, x1, y1, clip)
	}
	box := clip.and(uiClip{int(math.Floor(left)), int(y0), int(math.Ceil(right)), int(y1)})
	shown := n.shown(b, f)
	room := (right - left) / n.scale
	caretAt := n.measure(b.font, string(shown[:f.caret]))
	if caretAt-f.shift > room {
		f.shift = caretAt - room
	}
	if caretAt < f.shift {
		f.shift = caretAt
	}
	if full := n.measure(b.font, string(shown)); full-f.shift < room {
		f.shift = math.Max(0, full-room)
	}
	baseX := left - f.shift*n.scale
	if focused && f.caret != f.anchor {
		from, to := min(f.caret, f.anchor), max(f.caret, f.anchor)
		sx := baseX + n.measure(b.font, string(shown[:from]))*n.scale
		ex := baseX + n.measure(b.font, string(shown[:to]))*n.scale
		cv.fill(int(math.Round(sx)), int(math.Round(top)), int(math.Round(ex)), int(math.Round(top+b.lineH*n.scale)), n.selection(), box)
	}
	if len(shown) == 0 {
		if p, ok := b.attr("placeholder"); ok {
			n.say(b.font, left, top+lift, p.Word, uiMix(n.pal.bg, uiPlaceholder, 1), box)
		}
	} else {
		n.say(b.font, baseX, top+lift, string(shown), n.ink(b), box)
	}
	if focused && n.blink {
		n.caret(cv, b, baseX+caretAt*n.scale, top+lift, box)
	}
}

func (n *uiNative) selection() uiRGBA {
	return uiRGBA{n.pal.accent.r, n.pal.accent.g, n.pal.accent.b, 110}
}

func (n *uiNative) caret(cv *uiCanvas, b *uiBox, x, y float64, clip uiClip) {
	cx := math.Round(x)
	tall := n.dev.tall(b.font) * n.scale
	cv.fill(int(cx), int(math.Round(y)), int(cx+n.hairline()), int(math.Round(y+tall)), b.colour, clip)
}

func (n *uiNative) paintSpin(cv *uiCanvas, b *uiBox, x0, y0, x1, y1 float64, clip uiClip) {
	line := n.hairline()
	top := y0 + (b.border+2)*n.scale
	bottom := y1 - (b.border+2)*n.scale
	mid := (top + bottom) / 2
	right := x1 - (b.border+b.padX-4)*n.scale
	for i, half := range [2][2]float64{{top, mid}, {mid, bottom}} {
		shade := n.pal.line
		if b.path == n.hover && n.hoverPart == i+1 {
			shade = uiMix(n.pal.line, n.pal.muted, 0.5)
		}
		cv.fill(int(x0), int(half[0]), int(right), int(half[1]-line), uiMix(n.pal.bg, shade, 0.6), clip)
		cx, cy := (x0+right)/2, (half[0]+half[1])/2
		d := 3 * n.scale
		pts := []float64{cx - d, cy + d/2, cx + d, cy + d/2, cx, cy - d/2}
		if i == 1 {
			pts = []float64{cx - d, cy - d/2, cx + d, cy - d/2, cx, cy + d/2}
		}
		n.fillPolys(cv, [][]float64{pts}, n.ink(b), clip)
	}
}

func (n *uiNative) shown(b *uiBox, f *uiEntry) []rune {
	if b.input == "Password" {
		return []rune(strings.Repeat("•", len(f.text)))
	}
	return f.text
}

func (n *uiNative) paintRange(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.rectOf(b)
	x0 += b.padX * n.scale
	x1 -= b.padX * n.scale
	cy := (y0 + y1) / 2
	knob := 8 * n.scale
	track := 2 * n.scale
	value := n.rangeValue(b)
	from, to := x0+knob, x1-knob
	at := from + (to-from)*float64(value)/100
	rest, lit := n.pal.line, n.pal.accent
	if b.path == n.hover || b.path == n.sliding {
		lit = uiMix(lit, n.pal.fg, 0.15)
	}
	if b.disabled {
		rest, lit = uiMix(under, rest, 0.5), uiMix(under, lit, 0.5)
	}
	cv.round(x0, cy-track, x1, cy+track, track, rest, clip)
	cv.round(x0, cy-track, at, cy+track, track, lit, clip)
	if b.path == n.focus && n.keyboard {
		line := n.hairline()
		cv.ring(at-knob-2*line, cy-knob-2*line, at+knob+2*line, cy+knob+2*line, knob+2*line, 2*line, n.pal.accent, clip)
	}
	cv.round(at-knob, cy-knob, at+knob, cy+knob, knob, lit, clip)
}

func (n *uiNative) paintDate(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	focused := b.path == n.focus
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, focused)
	d := n.dates[b.path]
	if d == nil {
		return
	}
	left := x0 + (b.padX+b.border)*n.scale
	right := x1 - (b.padX+b.border)*n.scale
	top := (y0+y1)/2 - b.lineH*n.scale/2
	lift := n.lift(b)
	box := clip.and(uiClip{int(left) - 2, int(y0), int(right), int(y1)})
	order, sep := n.dateOrder()
	x := left
	for i, part := range order {
		text, empty := d.show(part)
		w := n.measure(b.font, text) * n.scale
		colour := n.ink(b)
		if empty {
			colour = uiMix(n.pal.bg, uiPlaceholder, 1)
		}
		if focused && d.at == i {
			cv.fill(int(math.Round(x-1)), int(math.Round(top)), int(math.Round(x+w+1)), int(math.Round(top+b.lineH*n.scale)), n.pal.accent, box)
			colour = uiWhite
		}
		n.say(b.font, x, top+lift, text, colour, box)
		x += w
		if i < len(order)-1 {
			n.say(b.font, x, top+lift, sep, n.ink(b), box)
			x += n.measure(b.font, sep) * n.scale
		}
	}
	n.paintCalendarMark(cv, b, right-14*n.scale, (y0+y1)/2, clip)
}

func (n *uiNative) paintCalendarMark(cv *uiCanvas, b *uiBox, x, cy float64, clip uiClip) {
	s := n.scale
	ink := n.ink(b)
	if b.path == n.hover && n.hoverPart == 3 {
		ink = n.pal.accent
	}
	line := n.hairline()
	l, t, r, d := x, cy-6*s, x+13*s, cy+6*s
	cv.ring(l, t, r, d, 1.5*s, line, ink, clip)
	cv.fill(int(l), int(t), int(r), int(t+3*s), ink, clip)
	for row := 0; row < 2; row++ {
		for col := 0; col < 3; col++ {
			cx := l + (2.5+float64(col)*3.2)*s
			cy := t + (5+float64(row)*3)*s
			cv.fill(int(math.Round(cx)), int(math.Round(cy)), int(math.Round(cx+2*s)), int(math.Round(cy+2*s)), ink, clip)
		}
	}
}

func (n *uiNative) paintTextarea(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	if b.code {
		n.paintCode(cv, b, clip, under)
		return
	}
	focused := b.path == n.focus
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, focused)
	f := n.fields[b.path]
	if f == nil {
		return
	}
	if f.caret != f.seen {
		n.reveal(b, f)
		f.seen = f.caret
	}
	line := n.hairline()
	box := clip.and(uiClip{int(x0 + line), int(y0 + line), int(x1 - line), int(y1 - line)})
	left := x0 + (b.padX+b.border)*n.scale
	top := y0 + (b.padY+b.border)*n.scale - f.top*n.scale
	lift := n.lift(b)
	spans := n.flow(b, f)
	from, to := min(f.caret, f.anchor), max(f.caret, f.anchor)
	for i, sp := range spans {
		y := top + float64(i)*b.lineH*n.scale
		if y > float64(box.y1) || y+b.lineH*n.scale < float64(box.y0) {
			continue
		}
		if focused && from != to && from <= sp.to && to >= sp.from {
			a, z := max(from, sp.from), min(to, sp.to)
			sx := left + n.measure(b.font, string(f.text[sp.from:a]))*n.scale
			ex := left + n.measure(b.font, string(f.text[sp.from:z]))*n.scale
			if to > sp.to {
				ex += 4 * n.scale
			}
			cv.fill(int(math.Round(sx)), int(math.Round(y)), int(math.Round(ex)), int(math.Round(y+b.lineH*n.scale)), n.selection(), box)
		}
		n.say(b.font, left, y+lift, strings.TrimRight(string(f.text[sp.from:sp.to]), "\n"), n.ink(b), box)
	}
	if len(f.text) == 0 {
		if p, ok := b.attr("placeholder"); ok {
			for i, text := range n.wrap(b.font, p.Word, n.flowWidth(b), true) {
				n.say(b.font, left, top+float64(i)*b.lineH*n.scale+lift, text, uiMix(n.pal.bg, uiPlaceholder, 1), box)
			}
		}
	}
	if focused && n.blink {
		i, x := n.caretLine(b, f, spans)
		n.caret(cv, b, left+x*n.scale, top+float64(i)*b.lineH*n.scale+lift, box)
	}
	grip := uiMix(n.pal.bg, n.pal.muted, 0.8)
	gx, gy := x1-4*n.scale, y1-4*n.scale
	for _, d := range []float64{3, 7} {
		n.fillPolys(cv, uiStroke([]float64{gx - d*n.scale, gy, gx, gy - d*n.scale}, 0.5*n.scale), grip, clip)
	}
	inner := b.h - 2*b.border
	extent := float64(len(spans))*b.lineH + 2*b.padY
	if extent > inner+0.5 {
		track := y1 - y0 - 2*line
		size := math.Max(track*inner/extent, 24*n.scale)
		at := y0 + line + (track-size)*f.top/(extent-inner)
		width := 6 * n.scale
		cv.round(x1-width-3*n.scale, at, x1-3*n.scale, at+size, width/2, uiMix(n.pal.bg, n.pal.muted, 0.6), clip)
	}
}

func (n *uiNative) paintCheckbox(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, _, y1 := n.rectOf(b)
	s := n.scale
	left := x0 + b.padX*s
	top := y0 + b.padY*s
	tall := (y1 - y0) - 2*b.padY*s
	bx := math.Round(left + 4*s)
	by := math.Round(top + (tall-13*s)/2)
	side := math.Round(13 * s)
	on := n.checked(b)
	hover := b.path == n.hover && !b.disabled
	line := n.hairline()
	edge, fill := n.pal.muted, n.pal.bg
	if hover {
		edge = n.pal.fg
	}
	if on {
		edge, fill = n.pal.accent, n.pal.accent
		if hover {
			edge = uiMix(n.pal.accent, n.pal.fg, 0.2)
			fill = edge
		}
	}
	if b.disabled {
		edge, fill = uiMix(under, edge, 0.5), uiMix(under, fill, 0.5)
	}
	if b.path == n.focus && n.keyboard {
		cv.ring(bx-3*line, by-3*line, bx+side+3*line, by+side+3*line, 4*s, 2*line, n.pal.accent, clip)
	}
	cv.round(bx, by, bx+side, by+side, 2*s, edge, clip)
	if !on {
		cv.round(bx+line, by+line, bx+side-line, by+side-line, 2*s-line, fill, clip)
	} else {
		tick := []float64{bx + 3*s, by + 6.8*s, bx + 5.4*s, by + 9.2*s, bx + 10*s, by + 3.8*s}
		n.fillPolys(cv, uiStroke(tick, 0.9*s), uiWhite, clip)
	}
	ink := uiMix(under, b.colour, 1)
	if b.disabled {
		ink = uiMix(under, ink, 0.5)
	}
	block := float64(len(b.lines)) * b.lineH * s
	start := top + (tall-block)/2
	for i, text := range b.lines {
		n.say(b.font, left+26*s, start+float64(i)*b.lineH*s+n.lift(b), text, ink, clip)
	}
}

func (n *uiNative) paintSelect(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, b.path == n.focus && n.keyboard)
	left := x0 + (b.padX+b.border)*n.scale
	right := x1 - (b.padX+b.border)*n.scale
	top := (y0+y1)/2 - b.lineH*n.scale/2
	box := clip.and(uiClip{int(left), int(y0), int(right - uiArrowRoom*n.scale), int(y1)})
	n.say(b.font, left, top+n.lift(b), n.chosen(b), n.ink(b), box)
	cx, cy := right-6*n.scale, (y0+y1)/2
	d := 3.5 * n.scale
	n.fillPolys(cv, uiStroke([]float64{cx - d, cy - d/2, cx, cy + d/2, cx + d, cy - d/2}, 0.75*n.scale), n.ink(b), clip)
}

func (n *uiNative) paintTable(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	g := b.grid
	if len(g.cells) == 0 {
		return
	}
	s := n.scale
	x0, y0, x1, y1 := n.rectOf(b)
	box := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
	left := x0 + (b.padX+b.border)*s
	top := y0 + (b.padY+b.border)*s
	total := 0.0
	for _, h := range g.heights {
		total += h
	}
	head := top
	if float64(clip.y0) > top {
		head = math.Min(float64(clip.y0), top+(total-g.heights[0])*s)
	}
	g.stuck = (head - top) / s
	ink := uiMix(under, b.colour, 1)
	at := top + g.heights[0]*s
	for r := 1; r < len(g.cells); r++ {
		h := g.heights[r] * s
		if at < float64(box.y1) && at+h > float64(box.y0) {
			if g.pickable && b.path == n.hover && n.hoverPart == r-1 {
				cv.fill(int(math.Round(left)), int(math.Round(at)), int(math.Round(x1)), int(math.Round(at+h)), n.pal.surface, box)
			}
			n.paintRow(cv, b, r, left, at, ink, box)
		}
		at += h
	}
	cv.fill(int(math.Round(left)), int(math.Round(head)), int(math.Round(x1)), int(math.Round(head+g.heights[0]*s)), n.pal.bg, box)
	n.paintRow(cv, b, 0, left, head, uiMix(n.pal.bg, b.colour, 1), box)
}

func (n *uiNative) paintRow(cv *uiCanvas, b *uiBox, r int, left, top float64, ink uiRGBA, clip uiClip) {
	g := b.grid
	s := n.scale
	f := b.cellFont(r)
	lift := (b.lineH - n.dev.tall(f)) / 2 * s
	x := left
	for c, width := range g.cols {
		if c >= g.count[r] {
			break
		}
		cell := clip.and(uiClip{int(math.Round(x)), int(top), int(math.Round(x + width*s)), int(top + g.heights[r]*s)})
		for i, text := range g.wrapped[r][c] {
			n.paintChosen(cv, b, r<<16|c, i, text, x+10*s, top+8*s+float64(i)*b.lineH*s, f, b.lineH, cell)
			n.say(f, x+10*s, top+8*s+float64(i)*b.lineH*s+lift, text, ink, cell)
		}
		bottom := math.Round(top + (g.heights[r]-1)*s)
		cv.fill(int(math.Round(x)), int(bottom), int(math.Round(x+width*s)), int(bottom+n.hairline()), n.pal.line, clip)
		x += width * s
	}
}

func (n *uiNative) paintSpinner(cv *uiCanvas, b *uiBox, clip uiClip) {
	x0, y0, x1, y1 := n.rectOf(b)
	area := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
	if area.empty() {
		return
	}
	n.spins = append(n.spins, area)
	cx, cy := (x0+x1)/2, (y0+y1)/2
	outer := math.Min(x1-x0, y1-y0) / 2
	inner := outer - 2*n.scale
	ring := uiCircle(cx, cy, outer)
	hole := uiCircle(cx, cy, inner)
	for i, j := 0, len(hole)-2; i < j; i, j = i+2, j-2 {
		hole[i], hole[j] = hole[j], hole[i]
		hole[i+1], hole[j+1] = hole[j+1], hole[i+1]
	}
	n.fillPolys(cv, [][]float64{ring, hole}, n.pal.line, clip)
	turn := float64(time.Since(n.epoch)%(700*time.Millisecond)) / float64(700*time.Millisecond)
	mid := -math.Pi/2 + 2*math.Pi*turn
	var arc []float64
	for i := 0; i <= 24; i++ {
		t := mid - math.Pi/4 + math.Pi/2*float64(i)/24
		arc = append(arc, cx+outer*math.Cos(t), cy+outer*math.Sin(t))
	}
	for i := 24; i >= 0; i-- {
		t := mid - math.Pi/4 + math.Pi/2*float64(i)/24
		arc = append(arc, cx+inner*math.Cos(t), cy+inner*math.Sin(t))
	}
	n.fillPolys(cv, [][]float64{arc}, n.pal.accent, clip)
}

func (n *uiNative) paintLayer(cv *uiCanvas, l *uiLayer, all uiClip) {
	p := l.panel
	under := n.pal.bg
	if !l.pinned {
		cv.fill(0, 0, cv.w, cv.h, uiShade, all)
		n.shadow(cv, p, all)
	}
	if l.anchor != "" {
		x0, y0, x1, y1 := n.rectOf(p)
		line := n.hairline()
		cv.round(x0-line, y0-line, x1+line, y1+line, p.corner*n.scale+line, n.pal.line, all)
	}
	n.paintBox(cv, p, all, under)
}

func (n *uiNative) shadow(cv *uiCanvas, p *uiBox, clip uiClip) {
	x0, y0, x1, y1 := n.rectOf(p)
	s := n.scale
	y0 += 12 * s
	y1 += 12 * s
	sigma := 20 * s
	radius := 16 * s
	reach := 2.5 * sigma
	area := cv.bounds(clip).and(uiClip{int(x0 - reach), int(y0 - reach), int(x1 + reach), int(y1 + reach)})
	if area.empty() {
		return
	}
	cv.flush()
	cx, cy := (x0+x1)/2, (y0+y1)/2
	hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
	k := 1 / (sigma * math.Sqrt2)
	for y := area.y0; y < area.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		qy := math.Abs(float64(y)+0.5-cy) - hy
		for x := area.x0; x < area.x1; x++ {
			qx := math.Abs(float64(x)+0.5-cx) - hx
			d := math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
			a := 0.3 * 0.5 * math.Erfc(d*k)
			if a > 0.002 {
				row[x] = uiBlendPixel(row[x], uiRGBA{0, 0, 0, 255}, a)
			}
		}
	}
}

func (n *uiNative) scrollbars(cv *uiCanvas, b *uiBox, clip uiClip) {
	x0, y0, x1, y1 := n.rectOf(b)
	thumb := uiMix(n.pal.bg, n.pal.muted, 0.6)
	width := 6 * n.scale
	at := n.scrolls[b.path]
	if b.extentH > b.h+0.5 {
		track := y1 - y0
		size := math.Max(track*b.h/b.extentH, 24*n.scale)
		top := y0 + (track-size)*at[1]/(b.extentH-b.h)
		cv.round(x1-width-2*n.scale, top, x1-2*n.scale, top+size, width/2, thumb, clip)
	}
	if b.extentW > b.w+0.5 {
		track := x1 - x0
		size := math.Max(track*b.w/b.extentW, 24*n.scale)
		left := x0 + (track-size)*at[0]/(b.extentW-b.w)
		cv.round(left, y1-width-2*n.scale, left+size, y1-2*n.scale, width/2, thumb, clip)
	}
}

func (n *uiNative) paintPopup(cv *uiCanvas, all uiClip) {
	p := n.popup
	if p == nil {
		return
	}
	b := n.boxes[p.path]
	if b == nil && p.kind != "menu" {
		return
	}
	n.placePopup()
	s := n.scale
	x0, y0, x1, y1 := p.x*s, p.y*s, (p.x+p.w)*s, (p.y+p.h)*s
	if p.kind == "menu" {
		n.paintFrameOf(cv, x0, y0, x1, y1, all)
		n.paintMenu(cv, all)
		return
	}
	line := n.hairline()
	for i := 1; i <= 3; i++ {
		d := float64(i) * s
		cv.round(x0-d, y0-d+2*s, x1+d, y1+d+2*s, 6*s+d, uiRGBA{0, 0, 0, 14}, all)
	}
	cv.round(x0, y0, x1, y1, 6*s, n.pal.line, all)
	cv.round(x0+line, y0+line, x1-line, y1-line, 6*s-line, n.pal.bg, all)
	if p.kind == "calendar" {
		n.paintCalendar(cv, b, all)
		return
	}
	box := all.and(uiClip{int(x0 + line), int(y0 + line), int(x1 - line), int(y1 - line)})
	f := b.font
	lift := n.lift(b)
	shown := n.popupRows(b)
	for i := p.top; i < min(len(b.v.Options), p.top+shown); i++ {
		y := y0 + (4+float64(i-p.top)*p.rowH)*s
		ink := uiMix(n.pal.bg, b.colour, 1)
		if i == p.lit {
			cv.fill(int(x0+line), int(math.Round(y)), int(x1-line), int(math.Round(y+p.rowH*s)), n.pal.accent, box)
			ink = uiWhite
		}
		n.say(f, x0+10*s, y+(p.rowH-b.lineH)/2*s+lift, b.v.Options[i], ink, box)
	}
	if len(b.v.Options) > shown {
		track := y1 - y0 - 8*s
		size := math.Max(track*float64(shown)/float64(len(b.v.Options)), 24*s)
		at := y0 + 4*s + (track-size)*float64(p.top)/float64(len(b.v.Options)-shown)
		cv.round(x1-9*s, at, x1-3*s, at+size, 3*s, uiMix(n.pal.bg, n.pal.muted, 0.6), all)
	}
}

func (n *uiNative) paintFrameOf(cv *uiCanvas, x0, y0, x1, y1 float64, all uiClip) {
	s := n.scale
	line := n.hairline()
	for i := 1; i <= 3; i++ {
		d := float64(i) * s
		cv.round(x0-d, y0-d+2*s, x1+d, y1+d+2*s, 6*s+d, uiRGBA{0, 0, 0, 14}, all)
	}
	cv.round(x0, y0, x1, y1, 6*s, n.pal.line, all)
	cv.round(x0+line, y0+line, x1-line, y1-line, 6*s-line, n.pal.bg, all)
}

func (n *uiNative) paintChosen(cv *uiCanvas, b *uiBox, cell, i int, line string, left, top float64, f uiFont, lineH float64, clip uiClip) {
	from, to, more, ok := n.selectedIn(b.path, cell)
	if !ok {
		return
	}
	run := &n.runs[n.runIndex[uiRunKey(b.path, cell)]]
	if i >= len(run.starts) {
		return
	}
	runes := []rune(line)
	a, e := max(from-run.starts[i], 0), min(to-run.starts[i], len(runes))
	if a > len(runes) || e < 0 || a > e {
		return
	}
	x0 := left + n.measure(f, string(runes[:a]))*n.scale
	x1 := left + n.measure(f, string(runes[:e]))*n.scale
	if e == len(runes) && (more || to > run.starts[i]+len(runes)) {
		x1 += 4 * n.scale
	}
	if x1 > x0 {
		cv.fill(int(math.Round(x0)), int(math.Round(top)), int(math.Round(x1)), int(math.Round(top+lineH*n.scale)), n.selection(), clip)
	}
}

var uiMonths = [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
var uiWeekdays = [7]string{"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"}

func (n *uiNative) paintCalendar(cv *uiCanvas, b *uiBox, all uiClip) {
	p := n.popup
	s := n.scale
	f := uiFont{px: 13, weight: 400}
	bold := uiFont{px: 13, weight: 600}
	lift := func(font uiFont, room float64) float64 { return (room - n.dev.tall(font)) / 2 * s }
	ink := uiMix(n.pal.bg, n.pal.fg, 1)
	muted := uiMix(n.pal.bg, n.pal.muted, 1)
	x, y := p.x*s, p.y*s
	title := uiMonths[p.month.Month()-1] + " " + strconv.Itoa(p.month.Year())
	n.say(bold, x+12*s, y+8*s+lift(bold, 24), title, ink, all)
	for i, arrow := range []string{"‹", "›"} {
		ax := x + (p.w-56+float64(i)*28)*s
		if n.hover == p.path+"/popup" && n.hoverPart == -2-i {
			cv.round(ax, y+8*s, ax+24*s, y+32*s, 4*s, n.pal.surface, all)
		}
		big := uiFont{px: 18, weight: 400}
		w := n.measure(big, arrow) * s
		n.say(big, ax+12*s-w/2, y+8*s+lift(big, 24), arrow, ink, all)
	}
	for i, day := range uiWeekdays {
		w := n.measure(f, day) * s
		n.say(f, x+(8+float64(i)*32+16)*s-w/2, y+40*s+lift(f, 20), day, muted, all)
	}
	first := time.Date(p.month.Year(), p.month.Month(), 1, 0, 0, 0, 0, time.Local)
	start := first.AddDate(0, 0, -int(first.Weekday()))
	d := n.dates[p.path]
	chosen := ""
	if d != nil {
		chosen = d.value()
	}
	today := time.Now().Format("2006-01-02")
	for cell := 0; cell < 42; cell++ {
		day := start.AddDate(0, 0, cell)
		cx := x + (8+float64(cell%7)*32)*s
		cy := y + (64+float64(cell/7)*28)*s
		stamp := day.Format("2006-01-02")
		tone := ink
		if day.Month() != p.month.Month() {
			tone = muted
		}
		switch {
		case stamp == chosen:
			cv.round(cx+2*s, cy, cx+30*s, cy+26*s, 4*s, n.pal.accent, all)
			tone = uiWhite
		case cell == p.lit:
			cv.round(cx+2*s, cy, cx+30*s, cy+26*s, 4*s, n.pal.surface, all)
		}
		if stamp == today && stamp != chosen {
			cv.ring(cx+2*s, cy, cx+30*s, cy+26*s, 4*s, n.hairline(), n.pal.accent, all)
		}
		label := strconv.Itoa(day.Day())
		w := n.measure(f, label) * s
		n.say(f, cx+16*s-w/2, cy+lift(f, 26), label, tone, all)
	}
}

func (n *uiNative) paintTip(cv *uiCanvas, all uiClip) {
	if n.tip == "" || time.Since(n.tipSince) < uiTipDelay {
		return
	}
	b := n.boxes[n.tip]
	if b == nil {
		return
	}
	hint, _ := b.attr("hint")
	if hint.Word == "" {
		return
	}
	s := n.scale
	f := uiFont{px: 12, weight: 400}
	lineH := 16.0
	lines := n.wrap(f, hint.Word, math.Min(400, n.vw-24), false)
	wide := 0.0
	for _, l := range lines {
		wide = math.Max(wide, n.measure(f, l))
	}
	w, h := wide+16, float64(len(lines))*lineH+8
	x := math.Min(n.tipAt[0], n.vw-w-4)
	y := n.tipAt[1] + 20
	if y+h > n.vh-4 {
		y = n.tipAt[1] - h - 8
	}
	x, y = math.Max(x, 4), math.Max(y, 4)
	x0, y0, x1, y1 := x*s, y*s, (x+w)*s, (y+h)*s
	line := n.hairline()
	if !n.tipDrawn {
		n.tipDrawn = true
		n.touched()
	}
	cv.round(x0-line, y0-line+s, x1+line, y1+line+s, 4*s+line, uiRGBA{0, 0, 0, 30}, all)
	cv.round(x0, y0, x1, y1, 4*s, n.pal.line, all)
	cv.round(x0+line, y0+line, x1-line, y1-line, 4*s-line, n.pal.surface, all)
	lift := (lineH - n.dev.tall(f)) / 2 * s
	for i, text := range lines {
		n.say(f, x0+8*s, y0+(4+float64(i)*lineH)*s+lift, text, uiMix(n.pal.surface, n.pal.fg, 1), all)
	}
}
