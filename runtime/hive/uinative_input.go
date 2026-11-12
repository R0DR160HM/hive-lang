// The pointer and the keyboard, and what each widget does with them.
package hive

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const uiTipDelay = 500 * time.Millisecond

type uiPopup struct {
	path       string
	kind       string
	lit        int
	top        int
	month      time.Time
	day        time.Time
	x, y, w, h float64
	rowH       float64
	pressed    bool
}

type uiSpan struct{ from, to int }

type uiDate struct {
	parts      [3]int // year, month, day; nought where none is set
	at         int
	typed      string
	typingSlot int
	sent       string
}

func (d *uiDate) set(value string) {
	d.parts = [3]int{}
	d.typed = ""
	if t, err := time.Parse("2006-01-02", value); err == nil {
		d.parts = [3]int{t.Year(), int(t.Month()), t.Day()}
	}
	d.sent = d.value()
}

func (d *uiDate) value() string {
	y, m, day := d.parts[0], d.parts[1], d.parts[2]
	if y == 0 || m == 0 || day == 0 {
		return ""
	}
	if t := time.Date(y, time.Month(m), day, 0, 0, 0, 0, time.UTC); t.Day() != day {
		return ""
	}
	return uiPad(y, 4) + "-" + uiPad(m, 2) + "-" + uiPad(day, 2)
}

func (d *uiDate) partial() bool {
	set := 0
	for _, p := range d.parts {
		if p != 0 {
			set++
		}
	}
	return set > 0 && set < 3 || d.typed != ""
}

func uiPad(v, width int) string {
	s := strconv.Itoa(v)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func uiDateSlot(part byte) int {
	switch part {
	case 'y':
		return 0
	case 'M':
		return 1
	}
	return 2
}

func (d *uiDate) show(part byte) (string, bool) {
	slot := uiDateSlot(part)
	width := 2
	if slot == 0 {
		width = 4
	}
	if d.typed != "" && slot == d.typingSlot {
		if slot == 0 {
			return d.typed, false
		}
		v, _ := strconv.Atoi(d.typed)
		return uiPad(v, 2), false
	}
	if v := d.parts[slot]; v != 0 {
		return uiPad(v, width), false
	}
	switch part {
	case 'y':
		return "yyyy", true
	case 'M':
		return "mm", true
	}
	return "dd", true
}

func (n *uiNative) dateOrder() ([3]byte, string) {
	if n.dateSep != "" {
		return n.dateShape, n.dateSep
	}
	pattern := "MM/dd/yyyy"
	if n.dev != nil {
		pattern = n.dev.datePattern()
	}
	var order []byte
	sep := ""
	for i := 0; i < len(pattern); i++ {
		c := pattern[i]
		switch c {
		case 'd', 'D':
			c = 'd'
		case 'M', 'm':
			c = 'M'
		case 'y', 'Y':
			c = 'y'
		default:
			if len(order) == 1 && sep == "" {
				sep = string(c)
			}
			continue
		}
		if len(order) == 0 || order[len(order)-1] != c {
			order = append(order, c)
		}
	}
	shape := [3]byte{'M', 'd', 'y'}
	if len(order) == 3 && order[0] != order[1] && order[1] != order[2] && order[0] != order[2] {
		copy(shape[:], order)
	}
	if sep == "" {
		sep = "/"
	}
	n.dateShape, n.dateSep = shape, sep
	return shape, sep
}

func (n *uiNative) dateSample() string {
	order, sep := n.dateOrder()
	parts := make([]string, 3)
	for i, p := range order {
		parts[i] = "00"
		if p == 'y' {
			parts[i] = "0000"
		}
	}
	return strings.Join(parts, sep)
}

func (n *uiNative) under(x, y float64) []*uiBox {
	for i := len(n.layers) - 1; i >= 0; i-- {
		l := n.layers[i]
		if chain := uiWalk(l.panel, x, y); len(chain) > 0 {
			return chain
		}
		if !l.pinned {
			return []*uiBox{l.backdrop}
		}
	}
	if n.root == nil {
		return nil
	}
	return uiWalk(n.root, x, y)
}

func uiWalk(from *uiBox, x, y float64) []*uiBox {
	var chain []*uiBox
	var walk func(b *uiBox) bool
	walk = func(b *uiBox) bool {
		if b.kind == "inset" {
			return false
		}
		inside := x >= b.x && x < b.x+b.w && y >= b.y+b.margin && y < b.y+b.h-b.margin
		if b.scroll != "" && !inside {
			return false
		}
		chain = append(chain, b)
		for i := len(b.kids) - 1; i >= 0; i-- {
			if walk(b.kids[i]) {
				return true
			}
		}
		if inside {
			return true
		}
		chain = chain[:len(chain)-1]
		return false
	}
	walk(from)
	return chain
}

func (b *uiBox) answers() bool {
	switch b.kind {
	case "input", "textarea", "select", "checkbox", "backdrop":
		return true
	case "table":
		return b.grid.sortable || b.grid.pickable
	}
	return b.focusable() || b.clickable()
}

func (n *uiNative) target(x, y float64) *uiBox {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		if chain[i].answers() {
			return chain[i]
		}
	}
	return nil
}

func (n *uiNative) part(b *uiBox, x, y float64) int {
	switch b.kind {
	case "table":
		return n.tablePart(b, x, y)
	case "input":
		right := b.x + b.w - b.padX - b.border
		switch b.input {
		case "Search":
			if n.extra(b, n.fields[b.path]) == "clear" && x >= right-16 {
				return 1
			}
		case "Number":
			if n.extra(b, n.fields[b.path]) == "spin" && x >= right-15 {
				if y < b.y+b.h/2 {
					return 1
				}
				return 2
			}
		case "Date":
			if x >= right-18 {
				return 3
			}
			return n.dateSegment(b, x)
		}
	}
	return 0
}

func (n *uiNative) tablePart(b *uiBox, x, y float64) int {
	g := b.grid
	if len(g.cells) == 0 {
		return -1
	}
	left := b.x + b.padX + b.border
	top := b.y + b.padY + b.border
	column := -1
	at := left
	for c, w := range g.cols {
		if x >= at && x < at+w {
			column = c
		}
		at += w
	}
	head := top + g.stuck
	if y >= head && y < head+g.heights[0] {
		if column < 0 {
			return -1
		}
		return -2 - column
	}
	at = top + g.heights[0]
	for r := 1; r < len(g.cells); r++ {
		if y >= at && y < at+g.heights[r] {
			return r - 1
		}
		at += g.heights[r]
	}
	return -1
}

func (n *uiNative) extra(b *uiBox, f *uiEntry) string {
	if f == nil || b.disabled {
		return ""
	}
	engaged := b.path == n.focus || b.path == n.hover
	switch {
	case b.input == "Search" && len(f.text) > 0 && engaged:
		return "clear"
	case b.input == "Number" && engaged:
		return "spin"
	}
	return ""
}

func (n *uiNative) dateSegment(b *uiBox, x float64) int {
	d := n.dates[b.path]
	if d == nil {
		return 0
	}
	order, sep := n.dateOrder()
	at := b.x + b.padX + b.border
	best := 0
	for i, part := range order {
		text, _ := d.show(part)
		w := n.measure(b.font, text)
		if x >= at-2 {
			best = i
		}
		at += w + n.measure(b.font, sep)
	}
	return best
}

func (n *uiNative) hinted(x, y float64) string {
	if n.popup != nil && n.inPopup(x, y) {
		return ""
	}
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		if h, ok := chain[i].attr("hint"); ok && h.Word != "" {
			return chain[i].path
		}
	}
	return ""
}

func (n *uiNative) cursor(x, y float64) string {
	n.layout()
	x, y = x/n.scale, y/n.scale
	if n.stage != nil && n.stage.hidden(x, y) {
		return "none"
	}
	if n.popup != nil && n.inPopup(x, y) {
		return "arrow"
	}
	if shape := n.grabCursor(x, y); shape != "" {
		return shape
	}
	if d := n.heard(x, y, "onDrag"); d != nil {
		if t := n.target(x, y); t == nil || t == d || !t.focusable() {
			if d.w >= d.h {
				return "resize"
			}
			return "cols"
		}
	}
	if n.ctrl {
		if b := n.heard(x, y, "onJump"); b != nil && b.code && n.codeAt(b, x, y) >= 0 {
			return "hand"
		}
	}
	b := n.target(x, y)
	if b == nil {
		if _, ok := n.textAt(x, y); ok {
			return "text"
		}
		return "arrow"
	}
	if b.disabled {
		return "arrow"
	}
	part := n.part(b, x, y)
	switch b.kind {
	case "input":
		switch {
		case b.input == "Range":
			return "hand"
		case b.input == "Date", part != 0:
			return "arrow"
		}
		return "text"
	case "textarea":
		return "text"
	case "table":
		if part >= 0 && b.grid.pickable || part <= -2 && b.grid.sortable {
			return "hand"
		}
		return "arrow"
	case "select", "backdrop":
		return "arrow"
	}
	if b.clickable() || b.kind == "button" {
		return "hand"
	}
	return "arrow"
}

func (n *uiNative) move(x, y float64) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	n.pointer = [2]float64{x, y}
	if d := n.drag; d != nil {
		dx, dy := int(math.Round(x-d.x)), int(math.Round(y-d.y))
		if dx != d.dx || dy != d.dy {
			d.dx, d.dy = dx, dy
			n.post(d.attrs, "drag", strconv.Itoa(dx)+","+strconv.Itoa(dy)+",0", 0)
		}
		return false
	}
	changed := false
	lit := ""
	if b := n.litUnder(x, y); b != nil {
		lit = b.path
	}
	if lit != n.lit {
		n.lit = lit
		changed = true
	}
	n.probe(x, y)
	if b := n.heard(x, y, "onHover"); b != nil && b.code {
		said := b.path + "#" + strconv.Itoa(n.codeAt(b, x, y))
		if said != n.hovered {
			n.unhover(b.path)
			n.hovered = said
			n.post(b.v.Attrs, "hover", strconv.Itoa(n.codeAt(b, x, y)), 0)
		}
	} else {
		n.unhover("")
	}
	if n.grab != nil {
		return n.dragGrab(x, y) || changed
	}
	if n.selecting {
		return n.extendSelection(x, y) || changed
	}
	if n.dragging {
		if b, ok := n.boxes[n.focus]; ok && b.editable() {
			f := n.fields[b.path]
			f.caret = n.pointAt(b, f, x, y)
			f.goal = -1
			return true
		}
	}
	if b, ok := n.boxes[n.sliding]; ok {
		return n.slide(b, x)
	}
	if tip := n.hinted(x, y); tip != n.tip && tip != n.quiet {
		changed = changed || n.tipDrawn
		n.tip, n.tipSince, n.tipAt, n.tipDrawn = tip, time.Now(), [2]float64{x, y}, false
	}
	if n.quiet != "" && n.hinted(x, y) != n.quiet {
		n.quiet = ""
	}
	hover, part := "", 0
	if n.popup != nil && n.inPopup(x, y) {
		hover, part = n.popup.path+"/popup", n.popupPart(x, y)
		if (n.popup.kind == "select" || n.popup.kind == "menu") && part >= 0 && part != n.popup.lit {
			n.popup.lit = part
			changed = true
		}
	} else if b := n.target(x, y); b != nil {
		hover, part = b.path, n.part(b, x, y)
	}
	if hover != n.hover || part != n.hoverPart {
		n.hover, n.hoverPart = hover, part
		changed = true
	}
	return changed
}

type uiDrag struct {
	attrs  []UiAttr
	x, y   float64
	dx, dy int
}

func uiFocusable(b *uiBox) *uiBox {
	if b.focusable() {
		return b
	}
	for _, k := range b.kids {
		if t := uiFocusable(k); t != nil {
			return t
		}
	}
	return nil
}

func (n *uiNative) heard(x, y float64, kind string) *uiBox {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		if _, ok := chain[i].attr(kind); ok && !chain[i].disabled {
			return chain[i]
		}
	}
	return nil
}

func (n *uiNative) codeAt(b *uiBox, x, y float64) int {
	f := n.fields[b.path]
	if f == nil || !b.code {
		return -1
	}
	spans := n.flow(b, f)
	line := int(math.Floor((y - (b.y + b.padY + b.border) + f.top) / b.lineH))
	if line < 0 || line >= len(spans) {
		return -1
	}
	col := (x - (b.x + b.border + b.padX + n.gutterOf(b, len(spans))) + f.shift) / n.cellW(b)
	if col < 0 {
		return -1
	}
	tab, c := n.tabOf(b), 0
	for i := spans[line].from; i < spans[line].to; i++ {
		next := c + 1
		if f.text[i] == '\t' {
			next = (c/tab + 1) * tab
		}
		if col < float64(next) {
			return i
		}
		c = next
	}
	return -1
}

func (n *uiNative) middle(x, y float64) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	if b := n.heard(x, y, "onMiddle"); b != nil {
		n.post(b.v.Attrs, "middle", "", 0)
		return true
	}
	return false
}

func (n *uiNative) litUnder(x, y float64) *uiBox {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		if chain[i].hoverTone != "" && !chain[i].disabled {
			return chain[i]
		}
	}
	return nil
}

func (n *uiNative) probe(x, y float64) {
	at, path := -1, ""
	var box *uiBox
	if b := n.heard(x, y, "onProbe"); b != nil && b.code {
		box, path = b, b.path
		if n.ctrl {
			at = n.codeAt(b, x, y)
		}
	}
	said := path + "#" + strconv.Itoa(at)
	if said == n.probed {
		return
	}
	was, _, _ := strings.Cut(n.probed, "#")
	if was != "" && was != path {
		if b, ok := n.boxes[was]; ok {
			n.post(b.v.Attrs, "probe", "-1", 0)
		}
	}
	if box != nil && (at >= 0 || strings.HasPrefix(n.probed, path+"#") && !strings.HasSuffix(n.probed, "#-1")) {
		n.post(box.v.Attrs, "probe", strconv.Itoa(at), 0)
	}
	n.probed = said
}

func (n *uiNative) setCtrl(held bool) bool {
	if n.ctrl == held {
		return false
	}
	n.touched()
	n.layout()
	n.ctrl = held
	n.probe(n.pointer[0], n.pointer[1])
	return true
}

func (n *uiNative) unhover(keep string) {
	path, _, _ := strings.Cut(n.hovered, "#")
	if n.hovered == "" || path == keep {
		return
	}
	n.hovered = ""
	if b, ok := n.boxes[path]; ok {
		n.post(b.v.Attrs, "hover", "-1", 0)
	}
}

func (n *uiNative) leave() bool {
	n.touched()
	n.unhover("")
	n.lit = ""
	n.probe(-1, -1)
	changed := n.hover != "" || n.tip != ""
	n.hover, n.hoverPart = "", 0
	n.tip = ""
	return changed
}

func (n *uiNative) down(x, y float64) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	n.quiet, n.tip = n.tip, ""
	if p := n.popup; p != nil {
		if n.inPopup(x, y) {
			p.pressed = true
			return true
		}
		n.popup = nil
		return true
	}
	n.spot = [2]float64{x, y}
	for _, l := range n.layers {
		p := l.panel
		if l.dismiss != nil && !(x >= p.x && x < p.x+p.w && y >= p.y && y < p.y+p.h) {
			n.post(l.dismiss, "click", "", 0)
		}
	}
	if n.startGrab(x, y) {
		return true
	}
	clicks := n.countClick(x, y)
	if clicks == 2 {
		if b := n.heard(x, y, "onDouble"); b != nil {
			n.post(b.v.Attrs, "double", "", 0)
		}
	}
	if d := n.heard(x, y, "onDrag"); d != nil {
		if t := n.target(x, y); t == nil || t == d || !t.focusable() {
			n.drag = &uiDrag{attrs: d.v.Attrs, x: x, y: y}
			return true
		}
	}
	if n.ctrl {
		if b := n.heard(x, y, "onJump"); b != nil && b.code {
			if at := n.codeAt(b, x, y); at >= 0 {
				n.post(b.v.Attrs, "jump", strconv.Itoa(at), 0)
			}
		}
	}
	n.sel = nil
	b := n.target(x, y)
	n.press, n.pressPart = "", 0
	n.keyboard = false
	if b == nil {
		n.focus = ""
		n.startSelection(x, y, clicks)
		return true
	}
	n.press, n.pressPart = b.path, n.part(b, x, y)
	if b.focusable() {
		n.focus = b.path
	} else {
		n.focus = ""
	}
	if b.disabled {
		return true
	}
	switch {
	case b.kind == "input" && b.input == "Range":
		n.sliding = b.path
		n.slide(b, x)
	case b.kind == "input" && b.input == "Date":
		if d := n.dates[b.path]; d != nil && n.pressPart < 3 {
			d.at, d.typed = n.pressPart, ""
		}
	case b.kind == "input" && b.input == "Number" && n.pressPart > 0:
		n.stepNumber(b, 3-2*n.pressPart)
	case b.kind == "select":
		if p := n.popup; p == nil {
			n.open(b)
		}
	case b.editable() && n.pressPart == 0:
		f := n.fields[b.path]
		f.caret = n.pointAt(b, f, x, y)
		f.anchor = f.caret
		f.goal = -1
		n.dragging = true
		n.blink = true
		n.clickField(b, f, clicks)
	case !b.focusable() && b.kind != "input" && b.kind != "textarea":
		n.startSelection(x, y, clicks)
	}
	return true
}

func (n *uiNative) up(x, y float64) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	n.dragging = false
	if d := n.drag; d != nil {
		n.drag = nil
		n.post(d.attrs, "drag", strconv.Itoa(d.dx)+","+strconv.Itoa(d.dy)+",1", 0)
		return true
	}
	if n.grab != nil {
		n.grab = nil
		return true
	}
	if n.selecting {
		n.selecting = false
		if n.selectedText() != "" {
			n.press = ""
			return true
		}
		n.sel = nil
	}
	if n.sliding != "" {
		n.sliding = ""
		return true
	}
	if p := n.popup; p != nil && p.pressed {
		p.pressed = false
		if n.inPopup(x, y) {
			n.popupClick(n.popupPart(x, y))
		}
		return true
	}
	pressed, part := n.press, n.pressPart
	n.press = ""
	b := n.target(x, y)
	if b == nil || b.path != pressed || n.part(b, x, y) != part {
		return true
	}
	n.activate(b, part)
	return true
}

func (n *uiNative) activate(b *uiBox, part int) {
	if b.disabled {
		return
	}
	switch b.kind {
	case "link":
		if _, ok := b.attr("on"); ok {
			n.post(b.v.Attrs, "click", "", 0)
		} else if len(b.v.Options) > 0 {
			if href := uiHref(b.v.Options[0]); strings.Contains(href, ":") {
				n.dev.openLink(href)
			}
		}
		return
	case "checkbox":
		n.toggle(b)
		return
	case "table":
		if a, ok := b.attr("onPick"); ok && part >= 0 {
			n.post([]UiAttr{a}, "click", "", part)
		}
		if a, ok := b.attr("onSort"); ok && part <= -2 {
			n.post([]UiAttr{a}, "click", "", -2-part)
		}
		return
	case "input":
		switch {
		case b.input == "Search" && part == 1:
			n.clearField(b)
		case b.input == "Date" && part == 3:
			n.open(b)
		}
		return
	}
	if b.clickable() {
		n.post(b.v.Attrs, "click", "", 0)
	}
}

func (n *uiNative) checked(b *uiBox) bool {
	if v, ok := n.pending[b.path]; ok {
		return v != ""
	}
	return b.v.Flag
}

func (n *uiNative) toggle(b *uiBox) {
	flag := ""
	if !n.checked(b) {
		flag = "1"
	}
	n.pending[b.path] = flag
	n.post(b.v.Attrs, "toggle", flag, 0)
}

func (n *uiNative) chosen(b *uiBox) string {
	if v, ok := n.pending[b.path]; ok {
		return v
	}
	for _, o := range b.v.Options {
		if o == b.v.Text {
			return o
		}
	}
	if len(b.v.Options) > 0 {
		return b.v.Options[0]
	}
	return ""
}

func (n *uiNative) choose(b *uiBox, i int) {
	if i < 0 || i >= len(b.v.Options) {
		return
	}
	if o := b.v.Options[i]; o != n.chosen(b) {
		n.pending[b.path] = o
		n.post(b.v.Attrs, "choose", o, 0)
	}
}

func (n *uiNative) chosenIndex(b *uiBox) int {
	c := n.chosen(b)
	for i, o := range b.v.Options {
		if o == c {
			return i
		}
	}
	return 0
}

func (n *uiNative) rangeValue(b *uiBox) int {
	text := b.v.Text
	if v, ok := n.pending[b.path]; ok {
		text = v
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
	if err != nil {
		return 50
	}
	return int(uiClamp(math.Round(v), 0, 100))
}

func (n *uiNative) setRange(b *uiBox, v int) bool {
	v = max(0, min(100, v))
	if v == n.rangeValue(b) {
		return false
	}
	n.pending[b.path] = strconv.Itoa(v)
	n.post(b.v.Attrs, "input", strconv.Itoa(v), 0)
	return true
}

func (n *uiNative) slide(b *uiBox, x float64) bool {
	from := b.x + b.inset + b.padX + 8
	to := b.x + b.w - b.inset - b.padX - 8
	if to <= from {
		return false
	}
	n.setRange(b, int(math.Round((x-from)/(to-from)*100)))
	return true
}

func (n *uiNative) open(b *uiBox) {
	p := &uiPopup{path: b.path, kind: "select", rowH: b.lineH}
	if b.kind == "input" {
		p.kind = "calendar"
		p.day = time.Now()
		if t, err := time.Parse("2006-01-02", n.dates[b.path].value()); err == nil {
			p.day = t
		}
		p.month = time.Date(p.day.Year(), p.day.Month(), 1, 0, 0, 0, 0, time.Local)
	} else {
		p.lit = n.chosenIndex(b)
	}
	n.popup = p
	n.placePopup()
	if p.kind == "select" {
		rows := n.popupRows(b)
		p.top = max(0, min(p.lit-rows/2, len(b.v.Options)-rows))
	}
}

func (n *uiNative) popupRows(b *uiBox) int { return min(len(b.v.Options), 20) }

func (n *uiNative) placePopup() {
	p := n.popup
	if p.kind == "menu" {
		n.placeMenu()
		return
	}
	b := n.boxes[p.path]
	if b == nil {
		return
	}
	if p.kind == "calendar" {
		p.w, p.h = 240, 240
		first := time.Date(p.month.Year(), p.month.Month(), 1, 0, 0, 0, 0, time.Local)
		start := first.AddDate(0, 0, -int(first.Weekday()))
		p.lit = int(math.Round(p.day.Sub(start).Hours() / 24))
	} else {
		widest := 0.0
		for _, o := range b.v.Options {
			widest = math.Max(widest, n.measure(b.font, o))
		}
		p.w = math.Max(b.w, widest+20+uiArrowRoom)
		p.h = float64(n.popupRows(b))*p.rowH + 8
	}
	p.x = math.Max(0, math.Min(b.x, n.vw-p.w))
	p.y = b.y + b.h + 2
	if p.y+p.h > n.vh && b.y-p.h-2 >= 0 {
		p.y = b.y - p.h - 2
	}
}

func (n *uiNative) inPopup(x, y float64) bool {
	p := n.popup
	return x >= p.x && x < p.x+p.w && y >= p.y && y < p.y+p.h
}

func (n *uiNative) popupPart(x, y float64) int {
	p := n.popup
	if p.kind == "menu" {
		return n.menuPart(y)
	}
	x, y = x-p.x, y-p.y
	if p.kind == "select" {
		i := p.top + int(math.Floor((y-4)/p.rowH))
		if y < 4 || i >= p.top+n.popupRows(n.boxes[p.path]) {
			return -1
		}
		return i
	}
	if y >= 8 && y < 32 {
		switch {
		case x >= p.w-56 && x < p.w-32:
			return -2
		case x >= p.w-28 && x < p.w-4:
			return -3
		}
		return -1
	}
	col, row := int(math.Floor((x-8)/32)), int(math.Floor((y-64)/28))
	if x < 8 || y < 64 || col > 6 || row > 5 {
		return -1
	}
	return row*7 + col
}

func (n *uiNative) popupClick(part int) {
	p := n.popup
	if p.kind == "menu" {
		if part >= 0 {
			n.runMenu(part)
		}
		return
	}
	b := n.boxes[p.path]
	if b == nil {
		n.popup = nil
		return
	}
	if p.kind == "select" {
		if part >= 0 {
			n.choose(b, part)
			n.popup = nil
		}
		return
	}
	switch {
	case part == -2:
		n.turnMonth(-1)
	case part == -3:
		n.turnMonth(1)
	case part >= 0:
		first := time.Date(p.month.Year(), p.month.Month(), 1, 0, 0, 0, 0, time.Local)
		n.pickDay(b, first.AddDate(0, 0, part-int(first.Weekday())))
	}
}

func (n *uiNative) turnMonth(by int) {
	p := n.popup
	p.month = p.month.AddDate(0, by, 0)
	p.day = p.day.AddDate(0, by, 0)
}

func (n *uiNative) pickDay(b *uiBox, day time.Time) {
	if d := n.dates[b.path]; d != nil {
		d.parts = [3]int{day.Year(), int(day.Month()), day.Day()}
		d.typed = ""
		n.dateChanged(b, d)
	}
	n.popup = nil
}

func (n *uiNative) popupKey(k uiKey) bool {
	p := n.popup
	if p.kind == "menu" {
		if k == uiKeyEscape || k == uiKeyTab || k == uiKeyMenu {
			n.popup = nil
			return true
		}
		return n.menuKeyed(k)
	}
	b := n.boxes[p.path]
	if b == nil {
		n.popup = nil
		return false
	}
	if k == uiKeyEscape || k == uiKeyTab {
		n.popup = nil
		return k == uiKeyEscape
	}
	if p.kind == "calendar" {
		step := map[uiKey]int{uiKeyLeft: -1, uiKeyRight: 1, uiKeyUp: -7, uiKeyDown: 7}
		switch {
		case step[k] != 0:
			p.day = p.day.AddDate(0, 0, step[k])
			p.month = time.Date(p.day.Year(), p.day.Month(), 1, 0, 0, 0, 0, time.Local)
		case k == uiKeyPageUp:
			n.turnMonth(-1)
		case k == uiKeyPageDown:
			n.turnMonth(1)
		case k == uiKeyEnter:
			n.pickDay(b, p.day)
		default:
			return false
		}
		return true
	}
	rows := n.popupRows(b)
	last := len(b.v.Options) - 1
	switch k {
	case uiKeyUp:
		p.lit = max(0, p.lit-1)
	case uiKeyDown:
		p.lit = min(last, p.lit+1)
	case uiKeyPageUp:
		p.lit = max(0, p.lit-(rows-1))
	case uiKeyPageDown:
		p.lit = min(last, p.lit+rows-1)
	case uiKeyHome:
		p.lit = 0
	case uiKeyEnd:
		p.lit = last
	case uiKeyEnter:
		n.choose(b, p.lit)
		n.popup = nil
		return true
	default:
		return false
	}
	p.top = max(0, min(p.top, p.lit))
	if p.lit >= p.top+rows {
		p.top = p.lit - rows + 1
	}
	return true
}

func (n *uiNative) caretAt(b *uiBox, f *uiEntry, x float64) int {
	shown := n.shown(b, f)
	local := x - (b.x + b.padX + b.border) + f.shift
	best, bestGap := 0, math.Inf(1)
	for i := 0; i <= len(shown); i++ {
		gap := math.Abs(n.measure(b.font, string(shown[:i])) - local)
		if gap < bestGap {
			best, bestGap = i, gap
		}
	}
	return best
}

func (n *uiNative) pointAt(b *uiBox, f *uiEntry, x, y float64) int {
	if b.kind != "textarea" {
		return n.caretAt(b, f, x)
	}
	spans := n.flow(b, f)
	line := int(math.Floor((y - (b.y + b.padY + b.border) + f.top) / b.lineH))
	line = max(0, min(line, len(spans)-1))
	left := b.x + b.padX + b.border
	if b.code {
		left += n.gutterOf(b, len(spans)) - f.shift
	}
	return n.column(b, f, spans, line, x-left)
}

func (n *uiNative) column(b *uiBox, f *uiEntry, spans []uiSpan, line int, x float64) int {
	sp := spans[line]
	end := sp.to
	if line+1 < len(spans) && spans[line+1].from == sp.to && end > sp.from {
		end--
	}
	best, bestGap := sp.from, math.Inf(1)
	for i := sp.from; i <= end; i++ {
		gap := math.Abs(n.runeX(b, f, sp.from, i) - x)
		if gap < bestGap {
			best, bestGap = i, gap
		}
	}
	return best
}

func (n *uiNative) flowWidth(b *uiBox) float64 {
	return math.Max(b.w-2*b.padX-2*b.border, 1)
}

func (n *uiNative) flow(b *uiBox, f *uiEntry) []uiSpan {
	if b.code {
		if !f.linesOK {
			f.lines, f.linesOK = uiLinesOf(f.text), true
		}
		return f.lines
	}
	width := n.flowWidth(b)
	text := f.text
	var spans []uiSpan
	start := 0
	for i := 0; i <= len(text); i++ {
		if i < len(text) && text[i] != '\n' {
			continue
		}
		from := start
		for {
			used, cut, lastBreak := 0.0, i, -1
			for j := from; j < i; j++ {
				w := n.measure(b.font, string(text[j]))
				if text[j] != ' ' && used+w > width+0.01 && j > from {
					cut = j
					break
				}
				used += w
				if text[j] == ' ' && (j+1 >= i || text[j+1] != ' ') {
					lastBreak = j + 1
				}
			}
			if cut == i {
				spans = append(spans, uiSpan{from, i})
				break
			}
			if lastBreak > from && lastBreak <= cut {
				cut = lastBreak
			}
			spans = append(spans, uiSpan{from, cut})
			from = cut
		}
		start = i + 1
	}
	return spans
}

func (n *uiNative) caretLine(b *uiBox, f *uiEntry, spans []uiSpan) (int, float64) {
	for i, sp := range spans {
		if f.caret < sp.from || f.caret > sp.to {
			continue
		}
		if f.caret == sp.to && i+1 < len(spans) && spans[i+1].from == sp.to {
			continue
		}
		return i, n.runeX(b, f, sp.from, f.caret)
	}
	last := len(spans) - 1
	return last, n.runeX(b, f, spans[last].from, spans[last].to)
}

func (n *uiNative) reveal(b *uiBox, f *uiEntry) {
	spans := n.flow(b, f)
	room := b.h - 2*b.padY - 2*b.border
	line, _ := n.caretLine(b, f, spans)
	top := float64(line) * b.lineH
	if top < f.top {
		f.top = top
	}
	if top+b.lineH > f.top+room {
		f.top = top + b.lineH - room
	}
	f.top = uiClamp(f.top, 0, math.Max(0, float64(len(spans))*b.lineH-room))
	if b.code {
		_, x := n.caretLine(b, f, spans)
		wide := b.w - 2*b.padX - 2*b.border - n.gutterOf(b, len(spans))
		cell := n.cellW(b)
		if x < f.shift {
			f.shift = math.Max(0, x-4*cell)
		} else if x > f.shift+wide-cell {
			f.shift = x - wide + 4*cell
		}
	}
}

func uiLinesOf(text []rune) []uiSpan {
	spans := make([]uiSpan, 0, 64)
	start := 0
	for i, r := range text {
		if r == '\n' {
			spans = append(spans, uiSpan{start, i})
			start = i + 1
		}
	}
	return append(spans, uiSpan{start, len(text)})
}

func (n *uiNative) runeX(b *uiBox, f *uiEntry, from, to int) float64 {
	if !b.code {
		return n.measure(b.font, string(f.text[from:to]))
	}
	return float64(uiColumns(f.text[from:to], 0, n.tabOf(b))) * n.cellW(b)
}

func uiColumns(text []rune, col, tab int) int {
	for _, r := range text {
		if r == '\t' {
			col = (col/tab + 1) * tab
		} else {
			col++
		}
	}
	return col
}

func (n *uiNative) tabOf(b *uiBox) int {
	if t, ok := b.attr("tabSize"); ok && t.Num > 0 {
		return t.Num
	}
	return 4
}

func (n *uiNative) cellW(b *uiBox) float64 { return n.measure(b.font, "M") }

func (n *uiNative) gutterOf(b *uiBox, lines int) float64 {
	if a, ok := b.attr("numbers"); !b.code || !ok || !a.Flag {
		return 0
	}
	return float64(max(len(strconv.Itoa(max(lines, 1))), 2)+2) * n.cellW(b)
}

func (n *uiNative) settle(b *uiBox, f *uiEntry, value string) {
	if !b.code {
		f.set(value)
		return
	}
	if f.value() == value {
		f.sent = nil
		return
	}
	caret, anchor := f.caret, f.anchor
	f.set(value)
	f.caret, f.anchor = min(caret, len(f.text)), min(anchor, len(f.text))
	f.seen = f.caret
}

func uiDiff(was, now []rune) (int, int, int) {
	a, top := 0, min(len(was), len(now))
	for a < top && was[a] == now[a] {
		a++
	}
	zw, zn := len(was), len(now)
	for zw > a && zn > a && was[zw-1] == now[zn-1] {
		zw--
		zn--
	}
	return a, zw, zn
}

func (n *uiNative) runColour(tone string, fallback uiRGBA) uiRGBA {
	if c, ok := uiParseColour(tone); ok {
		return c
	}
	if c, ok := n.pal.role(tone); ok {
		return c
	}
	return fallback
}

type uiPiece struct{ from, to, run int }

func (n *uiNative) piecesOf(b *uiBox, spans []uiSpan, first, last int) (inks, shades, waves [][]uiPiece) {
	count := max(0, last-first+1)
	inks, shades, waves = make([][]uiPiece, count), make([][]uiPiece, count), make([][]uiPiece, count)
	for i, m := range b.v.Marks {
		if len(m.Nums) != 2 || m.Kind == "marker" {
			continue
		}
		from, to := int(m.Nums[0]), int(m.Nums[1])
		if to <= from {
			continue
		}
		k := sort.Search(len(spans), func(j int) bool { return spans[j].to >= from })
		for k = max(k, first); k <= last && k < len(spans) && spans[k].from <= to; k++ {
			p := uiPiece{max(from, spans[k].from), min(to, spans[k].to), i}
			if p.to <= p.from && m.Kind != "squiggle" {
				continue
			}
			switch m.Kind {
			case "ink":
				inks[k-first] = append(inks[k-first], p)
			case "shade":
				shades[k-first] = append(shades[k-first], p)
			case "squiggle", "underline":
				waves[k-first] = append(waves[k-first], p)
			}
		}
	}
	return
}

func (n *uiNative) paintCode(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	focused := b.path == n.focus
	x0, y0, x1, y1 := n.paintFrame(cv, b, clip, focused)
	inside := n.pal.bg
	if b.fill.a > 0 {
		inside = uiMix(n.pal.bg, b.fill, 1)
	}
	f := n.fields[b.path]
	if f == nil {
		return
	}
	if f.caret != f.seen {
		n.reveal(b, f)
		f.seen = f.caret
	}
	s := n.scale
	line := n.hairline()
	box := clip.and(uiClip{int(x0 + line), int(y0 + line), int(x1 - line), int(y1 - line)})
	spans := n.flow(b, f)
	room := b.h - 2*b.padY - 2*b.border
	f.top = uiClamp(f.top, 0, math.Max(0, float64(len(spans))*b.lineH-room))
	gutter := n.gutterOf(b, len(spans)) * s
	cell := n.cellW(b)
	lh := b.lineH * s
	edge := x0 + b.border*s
	text := box.and(uiClip{int(math.Round(edge + gutter)), box.y0, box.x1, box.y1})
	numbers := box.and(uiClip{box.x0, box.y0, int(math.Round(edge + gutter)), box.y1})
	left := edge + gutter + (b.padX-f.shift)*s
	top := y0 + (b.padY+b.border)*s - f.top*s
	lift := n.lift(b)
	first := max(0, int(f.top/b.lineH)-1)
	last := min(len(spans)-1, int((f.top+b.h)/b.lineH)+1)
	inks, shades, waves := n.piecesOf(b, spans, first, last)
	marked := map[int]uiRGBA{}
	banded := map[int]uiRGBA{}
	type uiNoted struct {
		text   string
		colour uiRGBA
	}
	noted := map[int]uiNoted{}
	for _, m := range b.v.Marks {
		if len(m.Nums) != 2 {
			continue
		}
		switch m.Kind {
		case "marker":
			marked[int(m.Nums[0])] = n.runColour(m.Text, n.pal.accent)
		case "band":
			banded[int(m.Nums[0])] = n.runColour(m.Text, n.selection())
		case "note":
			noted[int(m.Nums[0])] = uiNoted{uiNoteText(m), n.runColour(m.Text, n.pal.muted)}
		}
	}
	if gutter > 0 {
		cv.fill(numbers.x0, numbers.y0, numbers.x1, numbers.y1, uiMix(inside, n.ink(b), 0.04), numbers)
	}
	at, _ := n.caretLine(b, f, spans)
	from, to := min(f.caret, f.anchor), max(f.caret, f.anchor)
	xOf := func(sp uiSpan, i int) float64 { return left + n.runeX(b, f, sp.from, i)*s }
	for i := first; i <= last; i++ {
		sp := spans[i]
		y := top + float64(i)*lh
		if y > float64(box.y1) || y+lh < float64(box.y0) {
			continue
		}
		yi, yz := int(math.Round(y)), int(math.Round(y+lh))
		if c, ok := banded[i]; ok {
			cv.fill(text.x0, yi, text.x1, yz, c, text)
		}
		if focused && from == to && i == at {
			cv.fill(text.x0, yi, text.x1, yz, uiRGBA{n.pal.fg.r, n.pal.fg.g, n.pal.fg.b, 14}, text)
		}
		for _, p := range shades[i-first] {
			c := n.runColour(b.v.Marks[p.run].Text, n.selection())
			cv.fill(int(math.Round(xOf(sp, p.from))), yi, int(math.Round(xOf(sp, p.to))), yz, c, text)
		}
		if focused && from != to && from <= sp.to && to >= sp.from {
			sx, ex := xOf(sp, max(from, sp.from)), xOf(sp, min(to, sp.to))
			if to > sp.to {
				ex += cell / 2 * s
			}
			cv.fill(int(math.Round(sx)), yi, int(math.Round(ex)), yz, n.selection(), text)
		}
		n.paintCodeLine(b, f, sp, inks[i-first], left, y+lift, text)
		if note, ok := noted[i]; ok && note.text != "" {
			cols := uiColumns(f.text[sp.from:sp.to], 0, n.tabOf(b))
			n.say(b.font, left+float64(cols+3)*cell*s, y+lift, note.text, uiMix(inside, note.colour, 1), text)
		}
		for _, p := range waves[i-first] {
			c := n.runColour(b.v.Marks[p.run].Text, n.pal.danger)
			sx, ex := xOf(sp, p.from), xOf(sp, p.to)
			if ex <= sx {
				ex = sx + cell*s
			}
			base := y + lh - 3*s
			if b.v.Marks[p.run].Kind == "underline" {
				c = n.runColour(b.v.Marks[p.run].Text, n.ink(b))
				cv.fill(int(math.Round(sx)), int(math.Round(base)), int(math.Round(ex)), int(math.Round(base+line)), c, text)
				continue
			}
			for x, k := sx, 0; x < ex; x, k = x+2*s, k+1 {
				yy := base
				if k%2 == 0 {
					yy -= s
				}
				cv.fill(int(math.Round(x)), int(math.Round(yy)), int(math.Round(math.Min(x+2*s, ex))), int(math.Round(yy+line)), c, text)
			}
		}
		if gutter > 0 {
			number := strconv.Itoa(i + 1)
			ink := uiMix(n.pal.bg, n.pal.muted, 0.8)
			if i == at {
				ink = n.ink(b)
			}
			n.say(b.font, edge+gutter-(cell+n.measure(b.font, number))*s, y+lift, number, ink, numbers)
			if c, ok := marked[i]; ok {
				cv.fill(int(math.Round(edge)), yi, int(math.Round(edge+3*s)), yz, c, numbers)
			}
		}
	}
	if focused && n.blink {
		i, x := n.caretLine(b, f, spans)
		n.caret(cv, b, left+x*s, top+float64(i)*lh+lift, text)
	}
	inner := b.h - 2*b.border
	extent := float64(len(spans))*b.lineH + 2*b.padY
	if extent > inner+0.5 {
		track := y1 - y0 - 2*line
		size := math.Max(track*inner/extent, 24*s)
		thumb := y0 + line + (track-size)*f.top/(extent-inner)
		width := 6 * s
		cv.round(x1-width-3*s, thumb, x1-3*s, thumb+size, width/2, uiMix(n.pal.bg, n.pal.muted, 0.6), clip)
	}
	n.codeTell(b, f, spans)
}

func (n *uiNative) paintCodeLine(b *uiBox, f *uiEntry, sp uiSpan, inks []uiPiece, left, y float64, clip uiClip) {
	if sp.to <= sp.from {
		return
	}
	owner := make([]int, sp.to-sp.from)
	for i := range owner {
		owner[i] = -1
	}
	for _, p := range inks {
		for j := p.from; j < p.to; j++ {
			owner[j-sp.from] = p.run
		}
	}
	tab, cell, s := n.tabOf(b), n.cellW(b), n.scale
	base := n.ink(b)
	col := 0
	var piece []rune
	for a := sp.from; a < sp.to; {
		z := a
		for z < sp.to && owner[z-sp.from] == owner[a-sp.from] {
			z++
		}
		start := col
		piece = piece[:0]
		for _, r := range f.text[a:z] {
			if r == '\t' {
				next := (col/tab + 1) * tab
				for ; col < next; col++ {
					piece = append(piece, ' ')
				}
				continue
			}
			piece = append(piece, r)
			col++
		}
		x := left + float64(start)*cell*s
		if x < float64(clip.x1) && left+float64(col)*cell*s > float64(clip.x0) {
			ink := base
			if run := owner[a-sp.from]; run >= 0 {
				ink = uiMix(n.pal.bg, n.runColour(b.v.Marks[run].Text, base), 1)
			}
			n.say(b.font, x, y, string(piece), ink, clip)
		}
		a = z
	}
}

func (n *uiNative) codeTell(b *uiBox, f *uiEntry, spans []uiSpan) {
	if _, ok := b.attr("onCaret"); ok {
		said := strconv.Itoa(f.anchor) + "," + strconv.Itoa(f.caret)
		if said != f.told {
			f.told = said
			n.post(b.v.Attrs, "caret", said, 0)
		}
	}
	if _, ok := b.attr("onView"); ok {
		room := b.h - 2*b.padY - 2*b.border
		first := min(len(spans)-1, max(0, int(f.top/b.lineH)))
		last := min(len(spans)-1, max(first, int((f.top+room)/b.lineH)-1))
		view := strconv.Itoa(first) + "," + strconv.Itoa(last)
		if view != f.view {
			f.view = view
			n.post(b.v.Attrs, "view", view, 0)
		}
	}
	if _, ok := b.attr("onFit"); ok {
		wide := b.w - 2*b.padX - 2*b.border - n.gutterOf(b, len(spans))
		room := b.h - 2*b.padY - 2*b.border
		fit := strconv.Itoa(max(1, int(wide/n.cellW(b)))) + "," + strconv.Itoa(max(1, int(room/b.lineH)))
		if fit != f.fit {
			f.fit = fit
			n.post(b.v.Attrs, "fit", fit, 0)
		}
	}
}

func (n *uiNative) wheel(x, y float64, lines float64, sideways bool) bool {
	n.touched()
	n.layout()
	x, y = x/n.scale, y/n.scale
	if p := n.popup; p != nil {
		if n.inPopup(x, y) && p.kind == "select" {
			b := n.boxes[p.path]
			top := max(0, min(p.top-int(lines*3), len(b.v.Options)-n.popupRows(b)))
			moved := top != p.top
			p.top = top
			return moved
		}
		n.popup = nil
	}
	if n.tip != "" {
		n.quiet, n.tip = n.tip, ""
	}
	chain := n.under(x, y)
	step := lines * 100
	for i := len(chain) - 1; i >= 0; i-- {
		b := chain[i]
		if b.kind == "textarea" && b.code && sideways {
			f := n.fields[b.path]
			if f == nil {
				continue
			}
			widest := 0
			for _, sp := range n.flow(b, f) {
				widest = max(widest, uiColumns(f.text[sp.from:sp.to], 0, n.tabOf(b)))
			}
			room := b.w - 2*b.padX - 2*b.border - n.gutterOf(b, 1)
			most := math.Max(0, float64(widest+2)*n.cellW(b)-room)
			moved := uiClamp(f.shift-step, 0, most)
			if moved != f.shift {
				f.shift = moved
				return true
			}
			continue
		}
		if b.kind == "textarea" && !sideways {
			f := n.fields[b.path]
			if f == nil {
				continue
			}
			room := b.h - 2*b.padY - 2*b.border
			most := math.Max(0, float64(len(n.flow(b, f)))*b.lineH-room)
			moved := uiClamp(f.top-step, 0, most)
			if moved != f.top {
				f.top = moved
				return true
			}
			continue
		}
		if b.scroll == "" {
			continue
		}
		at := n.scrolls[b.path]
		axis, room := 1, b.extentH-b.h
		if sideways || b.scroll == "Horizontal" {
			axis, room = 0, b.extentW-b.w
		}
		if room <= 0 {
			continue
		}
		moved := uiClamp(at[axis]-step, 0, room)
		if moved == at[axis] {
			continue
		}
		at[axis] = moved
		n.scrolls[b.path] = at
		n.stale = true
		return true
	}
	return false
}

type uiKey int

const (
	uiKeyNone uiKey = iota
	uiKeyBack
	uiKeyDelete
	uiKeyLeft
	uiKeyRight
	uiKeyHome
	uiKeyEnd
	uiKeyEnter
	uiKeyTab
	uiKeySpace
	uiKeyAll
	uiKeyCopy
	uiKeyCut
	uiKeyPaste
	uiKeyUp
	uiKeyDown
	uiKeyPageUp
	uiKeyPageDown
	uiKeyEscape
	uiKeyUndo
	uiKeyRedo
	uiKeyMenu
)

func (n *uiNative) claim(name string) bool {
	if name == "" {
		return false
	}
	n.touched()
	n.layout()
	at := n.focus
	if _, ok := n.boxes[at]; !ok {
		at = "r/0"
	}
	if name == "Ctrl+V" || name == "Shift+Insert" {
		for p := at; ; {
			if b, ok := n.boxes[p]; ok && b.v != nil {
				if _, heard := uiFind(b.v.Attrs, "onPaste"); heard {
					pasted := strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(n.dev.clipboard())
					n.post(b.v.Attrs, "paste", pasted, 0)
					return true
				}
			}
			cut := strings.LastIndexByte(p, '/')
			if cut < 0 {
				break
			}
			p = p[:cut]
		}
	}
	for {
		if b, ok := n.boxes[at]; ok && b.v != nil {
			if keys, ok := uiFind(b.v.Attrs, "keys"); ok && uiClaims(keys.Word, name) {
				if _, heard := uiFind(b.v.Attrs, "onKey"); heard {
					n.post(b.v.Attrs, "key", name, 0)
					return true
				}
			}
		}
		cut := strings.LastIndexByte(at, '/')
		if cut < 0 {
			return false
		}
		at = at[:cut]
	}
}

func uiClaims(keys, name string) bool {
	for _, k := range strings.Fields(keys) {
		if k == name || k == "Any" {
			return true
		}
	}
	return false
}

func uiCombo(key string, ctrl, shift, alt bool) string {
	if key == "" {
		return ""
	}
	if alt {
		key = "Alt+" + key
	}
	if shift {
		key = "Shift+" + key
	}
	if ctrl {
		key = "Ctrl+" + key
	}
	return key
}

func (n *uiNative) key(k uiKey, shift, word bool) bool {
	n.touched()
	n.layout()
	if n.popup != nil && n.popupKey(k) {
		return true
	}
	if k == uiKeyMenu {
		return n.menuKey()
	}
	b, ok := n.boxes[n.focus]
	if !ok || !b.editable() {
		switch k {
		case uiKeyCopy:
			if n.selectedText() != "" {
				n.copySelection()
				return true
			}
		case uiKeyAll:
			if !ok || b.kind != "select" {
				return n.selectAllText()
			}
		}
	}
	if k == uiKeyTab {
		if ok && b.code && !b.disabled && !shift {
			f := n.fields[b.path]
			n.edit(b, f, min(f.caret, f.anchor), max(f.caret, f.anchor), "\t")
			n.blink = true
			return true
		}
		if ok && b.kind == "input" && b.input == "Date" {
			if d := n.dates[b.path]; d != nil && (shift && d.at > 0 || !shift && d.at < 2) {
				if shift {
					d.at--
				} else {
					d.at++
				}
				d.typed = ""
				return true
			}
		}
		n.tab(shift)
		return true
	}
	if !ok {
		return false
	}
	if b.disabled {
		return false
	}
	switch b.kind {
	case "textarea":
		return n.areaKey(b, k, shift, word)
	case "select":
		return n.selectKey(b, k)
	case "checkbox":
		return false
	case "input":
		switch b.input {
		case "Range":
			return n.rangeKey(b, k)
		case "Date":
			return n.dateKey(b, k)
		case "Number":
			if k == uiKeyUp || k == uiKeyDown {
				n.stepNumber(b, map[uiKey]int{uiKeyUp: 1, uiKeyDown: -1}[k])
				return true
			}
		case "Search":
			if k == uiKeyEscape && len(n.fields[b.path].text) > 0 {
				n.clearField(b)
				return true
			}
		}
		return n.fieldKey(b, k, shift, word)
	}
	if k == uiKeyEnter || k == uiKeySpace {
		n.activate(b, 0)
		return true
	}
	return false
}

func (n *uiNative) fieldKey(b *uiBox, k uiKey, shift, word bool) bool {
	f := n.fields[b.path]
	n.blink = true
	from, to := min(f.caret, f.anchor), max(f.caret, f.anchor)
	switch k {
	case uiKeyEnter:
		if b.kind == "textarea" {
			broke := "\n"
			if b.code {
				start := from
				for start > 0 && f.text[start-1] != '\n' {
					start--
				}
				end := start
				for end < from && (f.text[end] == ' ' || f.text[end] == '\t') {
					end++
				}
				broke += string(f.text[start:end])
			}
			n.edit(b, f, from, to, broke)
			break
		}
		n.post(b.v.Attrs, "submit", n.numeric(b, f), 0)
	case uiKeyLeft, uiKeyRight, uiKeyHome, uiKeyEnd:
		switch k {
		case uiKeyLeft:
			if from != to && !shift {
				f.caret = from
			} else {
				f.caret = uiStep(f.text, f.caret, -1, word)
			}
		case uiKeyRight:
			if from != to && !shift {
				f.caret = to
			} else {
				f.caret = uiStep(f.text, f.caret, 1, word)
			}
		case uiKeyHome:
			f.caret = 0
		case uiKeyEnd:
			f.caret = len(f.text)
		}
		if !shift {
			f.anchor = f.caret
		}
		f.goal = -1
	case uiKeyAll:
		f.anchor, f.caret = 0, len(f.text)
	case uiKeyUndo, uiKeyRedo:
		n.undo(b, f, k == uiKeyUndo)
	case uiKeyCopy, uiKeyCut:
		if from != to && b.input != "Password" {
			n.dev.setClipboard(string(f.text[from:to]))
			if k == uiKeyCut {
				n.edit(b, f, from, to, "")
			}
		}
	case uiKeyPaste:
		pasted := strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(n.dev.clipboard())
		if b.kind != "textarea" {
			pasted = strings.ReplaceAll(pasted, "\n", " ")
		}
		if b.input == "Number" {
			pasted = strings.Map(func(r rune) rune {
				if uiNumberRune(r) {
					return r
				}
				return -1
			}, pasted)
		}
		n.edit(b, f, from, to, pasted)
	case uiKeyBack, uiKeyDelete:
		if from == to {
			if k == uiKeyBack {
				from = uiStep(f.text, f.caret, -1, word)
			} else {
				to = uiStep(f.text, f.caret, 1, word)
			}
		}
		if from != to {
			n.edit(b, f, from, to, "")
		}
	default:
		return false
	}
	return true
}

func (n *uiNative) areaKey(b *uiBox, k uiKey, shift, word bool) bool {
	f := n.fields[b.path]
	switch k {
	case uiKeyUp, uiKeyDown, uiKeyPageUp, uiKeyPageDown:
		spans := n.flow(b, f)
		line, x := n.caretLine(b, f, spans)
		if f.goal < 0 {
			f.goal = x
		}
		by := map[uiKey]int{uiKeyUp: -1, uiKeyDown: 1}[k]
		if by == 0 {
			page := max(1, int((b.h-2*b.padY)/b.lineH)-1)
			by = page
			if k == uiKeyPageUp {
				by = -page
			}
		}
		next := line + by
		switch {
		case next < 0:
			f.caret = 0
		case next >= len(spans):
			f.caret = len(f.text)
		default:
			f.caret = n.column(b, f, spans, next, f.goal)
		}
		if !shift {
			f.anchor = f.caret
		}
		n.blink = true
		return true
	case uiKeyHome, uiKeyEnd:
		if word {
			return n.fieldKey(b, k, shift, word)
		}
		spans := n.flow(b, f)
		line, _ := n.caretLine(b, f, spans)
		if k == uiKeyHome {
			f.caret = spans[line].from
		} else {
			f.caret = spans[line].to
			if line+1 < len(spans) && spans[line+1].from == spans[line].to && f.caret > spans[line].from {
				f.caret--
			}
		}
		if !shift {
			f.anchor = f.caret
		}
		f.goal = -1
		n.blink = true
		return true
	}
	return n.fieldKey(b, k, shift, word)
}

func (n *uiNative) selectKey(b *uiBox, k uiKey) bool {
	at, last := n.chosenIndex(b), len(b.v.Options)-1
	switch k {
	case uiKeyUp, uiKeyLeft:
		n.choose(b, max(0, at-1))
	case uiKeyDown, uiKeyRight:
		n.choose(b, min(last, at+1))
	case uiKeyHome, uiKeyPageUp:
		n.choose(b, 0)
	case uiKeyEnd, uiKeyPageDown:
		n.choose(b, last)
	case uiKeySpace:
		n.open(b)
	default:
		return false
	}
	return true
}

func (n *uiNative) rangeKey(b *uiBox, k uiKey) bool {
	v := n.rangeValue(b)
	switch k {
	case uiKeyLeft, uiKeyDown:
		v--
	case uiKeyRight, uiKeyUp:
		v++
	case uiKeyPageUp:
		v += 10
	case uiKeyPageDown:
		v -= 10
	case uiKeyHome:
		v = 0
	case uiKeyEnd:
		v = 100
	default:
		return false
	}
	n.setRange(b, v)
	return true
}

func (n *uiNative) dateKey(b *uiBox, k uiKey) bool {
	d := n.dates[b.path]
	if d == nil {
		return false
	}
	order, _ := n.dateOrder()
	slot := uiDateSlot(order[d.at])
	switch k {
	case uiKeyLeft:
		d.at, d.typed = max(0, d.at-1), ""
		return true
	case uiKeyRight:
		d.at, d.typed = min(2, d.at+1), ""
		return true
	case uiKeyUp, uiKeyDown:
		by := map[uiKey]int{uiKeyUp: 1, uiKeyDown: -1}[k]
		v := d.parts[slot]
		switch slot {
		case 0:
			if v == 0 {
				v = time.Now().Year()
			} else {
				v = max(1, min(275760, v+by))
			}
		case 1:
			v = uiWrap(v, by, 12)
		default:
			most := 31
			if d.parts[0] != 0 && d.parts[1] != 0 {
				most = time.Date(d.parts[0], time.Month(d.parts[1])+1, 0, 0, 0, 0, 0, time.UTC).Day()
			}
			v = uiWrap(v, by, most)
		}
		d.parts[slot], d.typed = v, ""
	case uiKeyBack, uiKeyDelete:
		d.parts[slot], d.typed = 0, ""
	case uiKeyEnter:
		n.post(b.v.Attrs, "submit", d.value(), 0)
		return true
	case uiKeySpace:
		n.open(b)
		return true
	default:
		return false
	}
	n.dateChanged(b, d)
	return true
}

func uiWrap(v, by, most int) int {
	if v == 0 {
		if by > 0 {
			return 1
		}
		return most
	}
	v += by
	if v > most {
		return 1
	}
	if v < 1 {
		return most
	}
	return v
}

func (n *uiNative) dateDigit(b *uiBox, d *uiDate, r rune) {
	order, _ := n.dateOrder()
	slot := uiDateSlot(order[d.at])
	if d.typingSlot != slot {
		d.typed = ""
	}
	d.typingSlot = slot
	d.typed += string(r)
	v, _ := strconv.Atoi(d.typed)
	done := false
	switch slot {
	case 0:
		d.parts[0] = v
		done = len(d.typed) >= 4
	case 1:
		done = len(d.typed) >= 2 || v > 1
		if v > 0 {
			d.parts[1] = min(v, 12)
		}
	case 2:
		done = len(d.typed) >= 2 || v > 3
		if v > 0 {
			d.parts[2] = min(v, 31)
		}
	}
	if done {
		d.typed = ""
		if d.at < 2 {
			d.at++
		}
	}
	n.dateChanged(b, d)
}

func (n *uiNative) dateChanged(b *uiBox, d *uiDate) {
	if v := d.value(); v != d.sent {
		d.sent = v
		n.post(b.v.Attrs, "input", v, 0)
	}
}

func (n *uiNative) typed(r rune) bool {
	n.touched()
	n.layout()
	if p := n.popup; p != nil && p.kind == "menu" {
		n.popup = nil
	}
	b, ok := n.boxes[n.focus]
	if !ok {
		return false
	}
	if p := n.popup; p != nil && p.path == b.path && r == ' ' {
		if p.kind == "select" {
			n.choose(b, p.lit)
			n.popup = nil
		}
		return true
	}
	if b.disabled {
		return false
	}
	switch {
	case b.kind == "select":
		if r == ' ' {
			n.open(b)
			return true
		}
		return n.jump(b, r)
	case b.kind == "checkbox":
		if r == ' ' {
			n.toggle(b)
			return true
		}
		return false
	case b.kind == "input" && b.input == "Date":
		d := n.dates[b.path]
		switch {
		case d == nil:
			return false
		case r >= '0' && r <= '9':
			n.dateDigit(b, d, r)
		case strings.ContainsRune("/-.", r):
			d.at, d.typed = min(2, d.at+1), ""
		default:
			return false
		}
		return true
	case b.kind == "input" && b.input == "Range":
		return false
	case b.editable():
		if r < 0x20 || r == 0x7f || b.input == "Number" && !uiNumberRune(r) {
			return false
		}
		f := n.fields[b.path]
		n.edit(b, f, min(f.caret, f.anchor), max(f.caret, f.anchor), string(r))
		n.blink = true
		return true
	}
	if r == ' ' {
		n.activate(b, 0)
		return true
	}
	return false
}

func (n *uiNative) jump(b *uiBox, r rune) bool {
	if !unicode.IsPrint(r) {
		return false
	}
	at := n.chosenIndex(b)
	count := len(b.v.Options)
	for i := 1; i <= count; i++ {
		o := b.v.Options[(at+i)%count]
		if first, _ := firstRune(o); unicode.ToLower(first) == unicode.ToLower(r) {
			n.choose(b, (at+i)%count)
			return true
		}
	}
	return false
}

func firstRune(s string) (rune, bool) {
	for _, r := range s {
		return r, true
	}
	return 0, false
}

func uiNumberRune(r rune) bool { return r >= '0' && r <= '9' || strings.ContainsRune(".-+eE", r) }

func (n *uiNative) numeric(b *uiBox, f *uiEntry) string {
	text := f.value()
	if b.input != "Number" || uiValidNumber(text) {
		return text
	}
	return ""
}

func uiValidNumber(s string) bool {
	i := 0
	if i < len(s) && s[i] == '-' {
		i++
	}
	digits := func() int {
		start := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		return i - start
	}
	whole := digits()
	if i < len(s) && s[i] == '.' {
		i++
		if digits() == 0 {
			return false
		}
	} else if whole == 0 {
		return false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
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
	text := strconv.FormatFloat(v+float64(by), 'f', -1, 64)
	n.edit(b, f, 0, len(f.text), text)
}

func (n *uiNative) clearField(b *uiBox) {
	if f := n.fields[b.path]; f != nil && len(f.text) > 0 {
		n.edit(b, f, 0, len(f.text), "")
	}
}

func (n *uiNative) edit(b *uiBox, f *uiEntry, from, to int, insert string) {
	if ro, ok := b.attr("readOnly"); ok && ro.Flag {
		return
	}
	f.remember(from, to, insert)
	added := []rune(insert)
	text := make([]rune, 0, len(f.text)-(to-from)+len(added))
	text = append(text, f.text[:from]...)
	text = append(text, added...)
	text = append(text, f.text[to:]...)
	f.text = text
	f.changed()
	f.caret = from + len(added)
	f.anchor = f.caret
	f.goal = -1
	value := n.numeric(b, f)
	f.sent = append(f.sent, value)
	n.post(b.v.Attrs, "edit", strconv.Itoa(from)+","+strconv.Itoa(to)+","+insert, 0)
	n.post(b.v.Attrs, "input", value, 0)
}

func uiStep(text []rune, at int, by int, word bool) int {
	if !word {
		return max(0, min(len(text), at+by))
	}
	if by < 0 {
		for at > 0 && unicode.IsSpace(text[at-1]) {
			at--
		}
		for at > 0 && !unicode.IsSpace(text[at-1]) {
			at--
		}
		return at
	}
	for at < len(text) && !unicode.IsSpace(text[at]) {
		at++
	}
	for at < len(text) && unicode.IsSpace(text[at]) {
		at++
	}
	return at
}

func (n *uiNative) tab(back bool) {
	n.popup = nil
	if len(n.order) == 0 {
		return
	}
	at := -1
	for i, b := range n.order {
		if b.path == n.focus {
			at = i
		}
	}
	switch {
	case at < 0 && back:
		at = len(n.order) - 1
	case at < 0:
		at = 0
	case back:
		at = (at - 1 + len(n.order)) % len(n.order)
	default:
		at = (at + 1) % len(n.order)
	}
	next := n.order[at]
	n.focus = next.path
	n.keyboard = true
	n.blink = true
	if f, ok := n.fields[next.path]; ok {
		if next.kind == "textarea" {
			f.anchor, f.caret = len(f.text), len(f.text)
		} else {
			f.anchor, f.caret = 0, len(f.text)
		}
	}
	if d, ok := n.dates[next.path]; ok {
		d.at, d.typed = 0, ""
		if back {
			d.at = 2
		}
	}
}

func (n *uiNative) caretSpot() (int, int, bool) {
	b, ok := n.boxes[n.focus]
	if !ok || !b.editable() {
		return 0, 0, false
	}
	f := n.fields[b.path]
	if b.kind == "textarea" {
		spans := n.flow(b, f)
		line, x := n.caretLine(b, f, spans)
		if b.code {
			x += n.gutterOf(b, len(spans)) - f.shift
		}
		return n.dp(b.x + b.padX + b.border + x), n.dp(b.y + b.padY + b.border + float64(line)*b.lineH - f.top), true
	}
	x := b.x + b.padX + b.border - f.shift + n.measure(b.font, string(n.shown(b, f)[:f.caret]))
	y := b.y + b.padY + b.border
	return n.dp(x), n.dp(y), true
}

func (n *uiNative) typing() bool {
	b, ok := n.boxes[n.focus]
	return ok && b.editable()
}

func (n *uiNative) frameDue() time.Duration {
	due := time.Duration(0)
	if len(n.spins) > 0 {
		due = 16 * time.Millisecond
	}
	if n.animDue > 0 && (due == 0 || n.animDue < due) {
		due = n.animDue
	}
	if n.tip != "" {
		if left := uiTipDelay - time.Since(n.tipSince); left > 0 && (due == 0 || left < due) {
			due = left
		}
	}
	return due
}

func (n *uiNative) moving() uiClip {
	if n.tip != "" && !n.tipDrawn && time.Since(n.tipSince) >= uiTipDelay-time.Millisecond {
		return uiClip{}
	}
	var area uiClip
	for _, s := range n.spins {
		area = area.or(s)
	}
	for _, a := range n.anims {
		area = area.or(a)
	}
	return area
}

func (n *uiNative) unfocused() bool {
	n.touched()
	n.popup = nil
	n.tip = ""
	n.dragging = false
	n.sliding = ""
	return true
}

func (n *uiNative) post(attrs []UiAttr, kind string, value string, index int) {
	msg, ok := uiMeaning(attrs, kind, value, index)
	if !ok {
		return
	}
	if uiDrawnAfter(kind) {
		syslinkPostDrawn(n.addr, msg)
	} else {
		SyslinkPost(n.addr, msg)
	}
}
