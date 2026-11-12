// Selecting text, the menu a right click opens, undoing a field, and grabbing a
// scroll bar or a textarea's corner.
package hive

import (
	"math"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type uiMark struct {
	path string
	cell int
	at   int
}

type uiRun struct {
	box    *uiBox
	cell   int
	text   []rune
	lines  []string
	starts []int
}

type uiSelection struct{ anchor, focus uiMark }

func uiRunKey(path string, cell int) string { return path + "#" + strconv.Itoa(cell) }

func uiLineStarts(text []rune, lines []string) []int {
	starts := make([]int, len(lines))
	at := 0
	for i, l := range lines {
		starts[i] = at
		at += utf8.RuneCountInString(l)
		if at < len(text) && text[at] == '\n' {
			at++
		}
	}
	return starts
}

func (n *uiNative) collectRuns() {
	n.runs = n.runs[:0]
	var walk func(b *uiBox)
	walk = func(b *uiBox) {
		switch b.kind {
		case "text", "link":
			text := []rune(b.v.Text)
			n.runs = append(n.runs, uiRun{box: b, cell: -1, text: text, lines: b.lines, starts: uiLineStarts(text, b.lines)})
		case "table":
			g := b.grid
			for r, cells := range g.cells {
				for c := range cells[:g.count[r]] {
					text := []rune(cells[c])
					lines := g.wrapped[r][c]
					n.runs = append(n.runs, uiRun{box: b, cell: r<<16 | c, text: text, lines: lines, starts: uiLineStarts(text, lines)})
				}
			}
		}
		for _, k := range b.kids {
			walk(k)
		}
	}
	if n.root != nil {
		walk(n.root)
	}
	for _, l := range n.layers {
		walk(l.panel)
	}
	n.runIndex = make(map[string]int, len(n.runs))
	for i, r := range n.runs {
		n.runIndex[uiRunKey(r.box.path, r.cell)] = i
	}
	if s := n.sel; s != nil {
		if _, ok := n.order2(s.anchor); !ok {
			n.sel = nil
		} else if _, ok := n.order2(s.focus); !ok {
			n.sel = nil
		}
	}
}

func (n *uiNative) runOrigin(r *uiRun) (float64, float64, float64, uiFont) {
	b := r.box
	if r.cell < 0 {
		return b.x + b.padX + b.border, b.y + b.margin + b.padY + b.border, b.lineH, b.font
	}
	g := b.grid
	row, col := r.cell>>16, r.cell&0xffff
	x := b.x + b.padX + b.border + 10
	for c := 0; c < col; c++ {
		x += g.cols[c]
	}
	y := b.y + b.padY + b.border + 8
	for rr := 0; rr < row; rr++ {
		y += g.heights[rr]
	}
	if row == 0 {
		y += g.stuck
	}
	return x, y, b.lineH, b.cellFont(row)
}

func (n *uiNative) runRect(r *uiRun) (float64, float64, float64, float64) {
	x, y, lineH, _ := n.runOrigin(r)
	if r.cell < 0 {
		return r.box.x, y, r.box.w, float64(len(r.lines)) * lineH
	}
	g := r.box.grid
	return x - 10, y - 8, g.cols[r.cell&0xffff], g.heights[r.cell>>16]
}

func (n *uiNative) runOffset(r *uiRun, x, y float64) int {
	if len(r.lines) == 0 {
		return 0
	}
	ox, oy, lineH, f := n.runOrigin(r)
	i := max(0, min(len(r.lines)-1, int(math.Floor((y-oy)/lineH))))
	line := []rune(r.lines[i])
	best, bestGap := 0, math.Inf(1)
	for k := 0; k <= len(line); k++ {
		gap := math.Abs(n.measure(f, string(line[:k])) - (x - ox))
		if gap < bestGap {
			best, bestGap = k, gap
		}
	}
	return r.starts[i] + best
}

func (n *uiNative) cellAt(b *uiBox, x, y float64) int {
	g := b.grid
	col, at := -1, b.x+b.padX+b.border
	for c, w := range g.cols {
		if x >= at && x < at+w {
			col = c
		}
		at += w
	}
	top := b.y + b.padY + b.border
	if col < 0 || len(g.cells) == 0 {
		return -1
	}
	if head := top + g.stuck; y >= head && y < head+g.heights[0] {
		return col
	}
	at = top + g.heights[0]
	for r := 1; r < len(g.cells); r++ {
		if y >= at && y < at+g.heights[r] {
			if col < g.count[r] {
				return r<<16 | col
			}
			return -1
		}
		at += g.heights[r]
	}
	return -1
}

func (n *uiNative) textAt(x, y float64) (uiMark, bool) {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		b := chain[i]
		cell := -1
		switch b.kind {
		case "text", "link":
		case "table":
			if cell = n.cellAt(b, x, y); cell < 0 {
				return uiMark{}, false
			}
		default:
			continue
		}
		at, ok := n.runIndex[uiRunKey(b.path, cell)]
		if !ok {
			return uiMark{}, false
		}
		return uiMark{b.path, cell, n.runOffset(&n.runs[at], x, y)}, true
	}
	return uiMark{}, false
}

func (n *uiNative) nearestMark(x, y float64) (uiMark, bool) {
	if m, ok := n.textAt(x, y); ok {
		return m, true
	}
	best, bestGap := -1, math.Inf(1)
	for i := range n.runs {
		rx, ry, rw, rh := n.runRect(&n.runs[i])
		dy := math.Max(0, math.Max(ry-y, y-(ry+rh)))
		dx := math.Max(0, math.Max(rx-x, x-(rx+rw)))
		if gap := dy*10000 + dx; gap < bestGap {
			best, bestGap = i, gap
		}
	}
	if best < 0 {
		return uiMark{}, false
	}
	r := &n.runs[best]
	return uiMark{r.box.path, r.cell, n.runOffset(r, x, y)}, true
}

func (n *uiNative) order2(m uiMark) (int, bool) {
	i, ok := n.runIndex[uiRunKey(m.path, m.cell)]
	return i, ok
}

func (n *uiNative) selRange() (int, int, int, int, bool) {
	s := n.sel
	if s == nil {
		return 0, 0, 0, 0, false
	}
	ai, ok1 := n.order2(s.anchor)
	fi, ok2 := n.order2(s.focus)
	if !ok1 || !ok2 {
		return 0, 0, 0, 0, false
	}
	a, b := s.anchor.at, s.focus.at
	if fi < ai || fi == ai && b < a {
		ai, fi, a, b = fi, ai, b, a
	}
	if ai == fi && a == b {
		return 0, 0, 0, 0, false
	}
	return ai, a, fi, b, true
}

func (n *uiNative) selectedIn(path string, cell int) (int, int, bool, bool) {
	i, ok := n.runIndex[uiRunKey(path, cell)]
	if !ok {
		return 0, 0, false, false
	}
	ai, a, fi, b, ok := n.selRange()
	if !ok || i < ai || i > fi {
		return 0, 0, false, false
	}
	from, to := 0, len(n.runs[i].text)
	if i == ai {
		from = a
	}
	if i == fi {
		to = b
	}
	return from, to, i < fi, true
}

func (n *uiNative) selectedText() string {
	ai, a, fi, b, ok := n.selRange()
	if !ok {
		return ""
	}
	var out strings.Builder
	for i := ai; i <= fi; i++ {
		r := &n.runs[i]
		from, to := 0, len(r.text)
		if i == ai {
			from = a
		}
		if i == fi {
			to = b
		}
		if i > ai {
			prev := &n.runs[i-1]
			if prev.box == r.box && prev.cell >= 0 && prev.cell>>16 == r.cell>>16 {
				out.WriteByte('\t')
			} else {
				out.WriteByte('\n')
			}
		}
		out.WriteString(string(r.text[from:to]))
	}
	return out.String()
}

func (n *uiNative) selectAllText() bool {
	if len(n.runs) == 0 {
		return false
	}
	first, last := &n.runs[0], &n.runs[len(n.runs)-1]
	n.sel = &uiSelection{uiMark{first.box.path, first.cell, 0}, uiMark{last.box.path, last.cell, len(last.text)}}
	return true
}

func uiWordAt(text []rune, at int) (int, int) {
	word := func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }
	if at >= len(text) {
		at = len(text) - 1
	}
	if at < 0 {
		return 0, 0
	}
	if !word(text[at]) {
		return at, at + 1
	}
	from, to := at, at
	for from > 0 && word(text[from-1]) {
		from--
	}
	for to < len(text) && word(text[to]) {
		to++
	}
	return from, to
}

func uiParagraphAt(text []rune, at int) (int, int) {
	from, to := min(at, len(text)), min(at, len(text))
	for from > 0 && text[from-1] != '\n' {
		from--
	}
	for to < len(text) && text[to] != '\n' {
		to++
	}
	return from, to
}

func (n *uiNative) countClick(x, y float64) int {
	now := time.Now()
	if now.Sub(n.lastPress) < 500*time.Millisecond && math.Abs(x-n.pressAt[0]) < 4 && math.Abs(y-n.pressAt[1]) < 4 {
		n.clicks++
	} else {
		n.clicks = 1
	}
	n.lastPress, n.pressAt = now, [2]float64{x, y}
	return n.clicks
}

func (n *uiNative) startSelection(x, y float64, clicks int) bool {
	m, ok := n.textAt(x, y)
	if !ok {
		return false
	}
	n.sel = &uiSelection{m, m}
	n.selecting = true
	if clicks >= 2 {
		r := &n.runs[n.runIndex[uiRunKey(m.path, m.cell)]]
		from, to := uiWordAt(r.text, m.at)
		if clicks >= 3 {
			from, to = uiParagraphAt(r.text, m.at)
		}
		n.sel.anchor.at, n.sel.focus.at = from, to
		n.selecting = false
	}
	return true
}

func (n *uiNative) extendSelection(x, y float64) bool {
	if m, ok := n.nearestMark(x, y); ok && n.sel != nil {
		n.sel.focus = m
		return true
	}
	return false
}

func (n *uiNative) clickField(b *uiBox, f *uiEntry, clicks int) {
	if clicks < 2 || len(f.text) == 0 {
		return
	}
	from, to := uiWordAt(f.text, f.caret)
	if clicks >= 3 {
		from, to = 0, len(f.text)
		if b.kind == "textarea" {
			from, to = uiParagraphAt(f.text, f.caret)
		}
	}
	f.anchor, f.caret = from, to
	n.dragging = false
}

type uiEntryState struct {
	text          []rune
	caret, anchor int
}

func (f *uiEntry) snapshot() uiEntryState {
	return uiEntryState{append([]rune(nil), f.text...), f.caret, f.anchor}
}

func (f *uiEntry) remember(from, to int, insert string) {
	typing := from == to && utf8.RuneCountInString(insert) == 1 && insert != " " && insert != "\n"
	if !(typing && f.lastTyped && time.Since(f.lastAt) < time.Second && from == f.caret) {
		f.past = append(f.past, f.snapshot())
		if len(f.past) > 200 {
			f.past = f.past[1:]
		}
	}
	f.future = nil
	f.lastTyped, f.lastAt = typing, time.Now()
}

func (n *uiNative) undo(b *uiBox, f *uiEntry, back bool) bool {
	if ro, ok := b.attr("readOnly"); ok && ro.Flag {
		return false
	}
	from, to := &f.past, &f.future
	if !back {
		from, to = to, from
	}
	if len(*from) == 0 {
		return false
	}
	*to = append(*to, f.snapshot())
	s := (*from)[len(*from)-1]
	*from = (*from)[:len(*from)-1]
	was := f.text
	f.text, f.caret, f.anchor = s.text, s.caret, s.anchor
	f.changed()
	f.lastTyped = false
	if a, zw, zn := uiDiff(was, f.text); a < zw || a < zn {
		n.post(b.v.Attrs, "edit", strconv.Itoa(a)+","+strconv.Itoa(zw)+","+string(f.text[a:zn]), 0)
	}
	value := n.numeric(b, f)
	f.sent = append(f.sent, value)
	n.post(b.v.Attrs, "input", value, 0)
	return true
}

type uiMenuItem struct {
	label string
	keys  string
	on    bool
	do    func()
}

const uiMenuRow, uiMenuGap = 28.0, 9.0

var uiMenuFont = uiFont{px: 13, weight: 400}

func (n *uiNative) menu(x, y float64) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	n.popup, n.tip = nil, ""
	n.spot = [2]float64{x, y}
	if hb := n.heard(x, y, "onMenu"); hb != nil {
		n.post(hb.v.Attrs, "menu", "", 0)
		return true
	}
	b := n.target(x, y)
	var items []uiMenuItem
	switch {
	case b != nil && b.editable():
		f := n.fields[b.path]
		n.focus, n.keyboard = b.path, false
		at := n.pointAt(b, f, x, y)
		if at < min(f.caret, f.anchor) || at > max(f.caret, f.anchor) {
			f.caret, f.anchor = at, at
		}
		items = n.fieldMenu(b, f)
	case b != nil && b.kind == "link" && len(b.v.Options) > 0 && strings.Contains(uiHref(b.v.Options[0]), ":"):
		href := uiHref(b.v.Options[0])
		items = []uiMenuItem{
			{label: "Open link", on: true, do: func() { n.dev.openLink(href) }},
			{label: "Copy link address", on: true, do: func() { n.dev.setClipboard(href) }},
		}
		if n.selectedText() != "" {
			items = append(items, uiMenuItem{}, uiMenuItem{label: "Copy", keys: "Ctrl+C", on: true, do: n.copySelection})
		}
	case n.selectedText() != "":
		items = []uiMenuItem{
			{label: "Copy", keys: "Ctrl+C", on: true, do: n.copySelection},
			{label: "Select all", keys: "Ctrl+A", on: true, do: func() { n.selectAllText() }},
		}
	}
	if len(items) > 0 {
		n.openMenu(items, x, y)
	}
	return true
}

func (n *uiNative) fieldMenu(b *uiBox, f *uiEntry) []uiMenuItem {
	chosen := f.caret != f.anchor
	hidden := b.input == "Password"
	act := func(k uiKey) func() { return func() { n.fieldKey(b, k, false, false) } }
	return []uiMenuItem{
		{label: "Undo", keys: "Ctrl+Z", on: len(f.past) > 0, do: func() { n.undo(b, f, true) }},
		{label: "Redo", keys: "Ctrl+Y", on: len(f.future) > 0, do: func() { n.undo(b, f, false) }},
		{},
		{label: "Cut", keys: "Ctrl+X", on: chosen && !hidden, do: act(uiKeyCut)},
		{label: "Copy", keys: "Ctrl+C", on: chosen && !hidden, do: act(uiKeyCopy)},
		{label: "Paste", keys: "Ctrl+V", on: true, do: act(uiKeyPaste)},
		{label: "Delete", on: chosen, do: act(uiKeyDelete)},
		{},
		{label: "Select all", keys: "Ctrl+A", on: len(f.text) > 0, do: act(uiKeyAll)},
	}
}

func (n *uiNative) menuKey() bool {
	if b, ok := n.boxes[n.focus]; ok && b.editable() {
		x, y, _ := n.caretSpot()
		n.menu(float64(x), float64(y)+b.lineH*n.scale)
		n.keyboard = true
		return true
	}
	if n.selectedText() != "" {
		n.openMenu([]uiMenuItem{
			{label: "Copy", keys: "Ctrl+C", on: true, do: n.copySelection},
			{label: "Select all", keys: "Ctrl+A", on: true, do: func() { n.selectAllText() }},
		}, n.pointer[0], n.pointer[1])
		return true
	}
	return false
}

func (n *uiNative) copySelection() {
	if text := n.selectedText(); text != "" {
		n.dev.setClipboard(text)
	}
}

func (n *uiNative) openMenu(items []uiMenuItem, x, y float64) {
	n.menuItems = items
	n.popup = &uiPopup{path: "menu", kind: "menu", lit: -1, x: x, y: y}
	n.placeMenu()
}

func (n *uiNative) placeMenu() {
	p := n.popup
	wide, tall := 0.0, 8.0
	for _, it := range n.menuItems {
		if it.label == "" {
			tall += uiMenuGap
			continue
		}
		tall += uiMenuRow
		wide = math.Max(wide, n.measure(uiMenuFont, it.label)+n.measure(uiMenuFont, it.keys)+64)
	}
	p.w, p.h = math.Max(wide, 180), tall
	if p.x+p.w > n.vw {
		p.x = math.Max(0, p.x-p.w)
	}
	if p.y+p.h > n.vh {
		p.y = math.Max(0, n.vh-p.h)
	}
}

func (n *uiNative) menuPart(y float64) int {
	at := n.popup.y + 4
	for i, it := range n.menuItems {
		tall := uiMenuRow
		if it.label == "" {
			tall = uiMenuGap
		}
		if y >= at && y < at+tall {
			if it.label == "" || !it.on {
				return -1
			}
			return i
		}
		at += tall
	}
	return -1
}

func (n *uiNative) menuKeyed(k uiKey) bool {
	p := n.popup
	step := 0
	switch k {
	case uiKeyUp:
		step = -1
	case uiKeyDown:
		step = 1
	case uiKeyEnter:
		n.runMenu(p.lit)
		return true
	default:
		return false
	}
	count := len(n.menuItems)
	for tries, i := 0, p.lit; tries < count; tries++ {
		i = (i + step + count) % count
		if it := n.menuItems[i]; it.label != "" && it.on {
			p.lit = i
			break
		}
	}
	return true
}

func (n *uiNative) runMenu(i int) {
	n.popup = nil
	if i >= 0 && i < len(n.menuItems) && n.menuItems[i].on && n.menuItems[i].do != nil {
		n.menuItems[i].do()
	}
	n.menuItems = nil
}

func (n *uiNative) paintMenu(cv *uiCanvas, all uiClip) {
	p := n.popup
	s := n.scale
	at := p.y + 4
	for i, it := range n.menuItems {
		if it.label == "" {
			y := math.Round((at + uiMenuGap/2) * s)
			cv.fill(int((p.x+8)*s), int(y), int((p.x+p.w-8)*s), int(y+n.hairline()), n.pal.line, all)
			at += uiMenuGap
			continue
		}
		ink, faint := uiMix(n.pal.bg, n.pal.fg, 1), uiMix(n.pal.bg, n.pal.muted, 1)
		if !it.on {
			ink = uiMix(n.pal.bg, n.pal.fg, 0.4)
			faint = ink
		}
		if i == p.lit {
			cv.round((p.x+4)*s, at*s, (p.x+p.w-4)*s, (at+uiMenuRow)*s, 4*s, n.pal.accent, all)
			ink, faint = uiWhite, uiWhite
		}
		lift := (uiMenuRow - n.dev.tall(uiMenuFont)) / 2 * s
		n.say(uiMenuFont, (p.x+16)*s, at*s+lift, it.label, ink, all)
		if it.keys != "" {
			w := n.measure(uiMenuFont, it.keys) * s
			n.say(uiMenuFont, (p.x+p.w-16)*s-w, at*s+lift, it.keys, faint, all)
		}
		at += uiMenuRow
	}
}

type uiGrab struct {
	path string
	kind string
	at   float64
	was  float64
	per  float64
}

const uiBarReach = 12.0

func uiThumb(start, track, view, extent, scrolled float64) (float64, float64) {
	size := math.Min(track, math.Max(track*view/extent, 24))
	return start + (track-size)*scrolled/(extent-view), size
}

func (n *uiNative) textareaExtent(b *uiBox, f *uiEntry) (float64, float64) {
	return float64(len(n.flow(b, f)))*b.lineH + 2*b.padY, b.h - 2*b.border
}

func (n *uiNative) startGrab(x, y float64) bool {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		b := chain[i]
		if b.kind == "textarea" && !b.disabled {
			if x >= b.x+b.w-14 && y >= b.y+b.h-14 {
				n.grab = &uiGrab{path: b.path, kind: "grip", at: y, was: b.h}
				return true
			}
			f := n.fields[b.path]
			extent, room := n.textareaExtent(b, f)
			if f != nil && extent > room+0.5 && x >= b.x+b.w-uiBarReach {
				top, size := uiThumb(b.y+b.border, room, room, extent, f.top)
				if y < top || y >= top+size {
					f.top = uiClamp(f.top+math.Copysign(room*0.875, y-top), 0, extent-room)
					f.seen = f.caret
					return true
				}
				n.grab = &uiGrab{path: b.path, kind: "area", at: y, was: f.top, per: (extent - room) / math.Max(room-size, 1)}
				return true
			}
		}
		if b.scroll == "" {
			continue
		}
		scrolled := n.scrolls[b.path]
		if b.extentH > b.h+0.5 && x >= b.x+b.w-uiBarReach {
			top, size := uiThumb(b.y, b.h, b.h, b.extentH, scrolled[1])
			if y < top || y >= top+size {
				scrolled[1] = uiClamp(scrolled[1]+math.Copysign(b.h*0.875, y-top), 0, b.extentH-b.h)
				n.scrolls[b.path], n.stale = scrolled, true
				return true
			}
			n.grab = &uiGrab{path: b.path, kind: "down", at: y, was: scrolled[1], per: (b.extentH - b.h) / math.Max(b.h-size, 1)}
			return true
		}
		if b.extentW > b.w+0.5 && y >= b.y+b.h-uiBarReach {
			left, size := uiThumb(b.x, b.w, b.w, b.extentW, scrolled[0])
			if x < left || x >= left+size {
				scrolled[0] = uiClamp(scrolled[0]+math.Copysign(b.w*0.875, x-left), 0, b.extentW-b.w)
				n.scrolls[b.path], n.stale = scrolled, true
				return true
			}
			n.grab = &uiGrab{path: b.path, kind: "across", at: x, was: scrolled[0], per: (b.extentW - b.w) / math.Max(b.w-size, 1)}
			return true
		}
	}
	return false
}

func (n *uiNative) dragGrab(x, y float64) bool {
	g := n.grab
	switch g.kind {
	case "grip":
		n.grown[g.path] = math.Max(64, g.was+y-g.at)
		n.stale = true
	case "area":
		if b, f := n.boxes[g.path], n.fields[g.path]; b != nil && f != nil {
			extent, room := n.textareaExtent(b, f)
			f.top = uiClamp(g.was+(y-g.at)*g.per, 0, math.Max(0, extent-room))
			f.seen = f.caret
		}
	case "down", "across":
		b := n.boxes[g.path]
		if b == nil {
			return false
		}
		scrolled := n.scrolls[g.path]
		if g.kind == "down" {
			scrolled[1] = uiClamp(g.was+(y-g.at)*g.per, 0, math.Max(0, b.extentH-b.h))
		} else {
			scrolled[0] = uiClamp(g.was+(x-g.at)*g.per, 0, math.Max(0, b.extentW-b.w))
		}
		n.scrolls[g.path], n.stale = scrolled, true
	}
	return true
}

func (n *uiNative) grabCursor(x, y float64) string {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		b := chain[i]
		if b.kind == "textarea" && !b.disabled && x >= b.x+b.w-14 && y >= b.y+b.h-14 {
			return "resize"
		}
		if b.scroll != "" && (b.extentH > b.h+0.5 && x >= b.x+b.w-uiBarReach || b.extentW > b.w+0.5 && y >= b.y+b.h-uiBarReach) {
			return "arrow"
		}
	}
	return ""
}
