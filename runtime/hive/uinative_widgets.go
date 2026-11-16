// Widgets made of their own items — a radio group, tabs, a list of choices, a tree — and
// what any box may be dressed in: a border, a shadow, a gradient, a change that eases.
package hive

import (
	"math"
	"strconv"
	"time"
)

type uiShading struct {
	from, to uiRGBA
	angle    float64
}

type uiItem struct {
	native *uiNative
	owner  *uiBox
	index  int
	value  string
	on     bool
}

type uiEaseState struct {
	fill, colour             uiRGBA
	opacity, shadow          float64
	width, height            float64
	gradientFrom, gradientTo uiRGBA
}

type uiEasing struct {
	from, to, now uiEaseState
	start         time.Time
	seen          bool
}

func (n *uiNative) fillOf(tone string) uiRGBA {
	if c, ok := uiParseColour(tone); ok {
		return c
	}
	switch tone {
	case "Muted":
		return n.pal.surface
	case "Good":
		return n.pal.good
	case "Warn":
		return n.pal.warn
	case "Danger":
		return n.pal.danger
	}
	return n.pal.bg
}

func uiFramedKind(kind string) bool {
	return kind == "button" || kind == "input" || kind == "textarea" || kind == "select"
}

func (n *uiNative) adopted(b *uiBox) {
	if !uiFramedKind(b.kind) && b.edge > 0 {
		b.border = b.edge
	}
	if s, ok := b.attr("scrollTo"); ok && len(s.Nums) == 3 {
		serial := int(s.Nums[2])
		if seen, ok := n.scrollAsked[b.path]; !ok || seen != serial {
			n.scrollAsked[b.path] = serial
			n.scrolls[b.path] = [2]float64{s.Nums[0], s.Nums[1]}
		}
	}
	if b.ease > 0 {
		n.eased(b)
	}
}

func (n *uiNative) item(owner *uiBox, kind string, index int, value string, on bool) *uiBox {
	n.seq++
	b := &uiBox{kind: kind, v: &UiView{Kind: kind, Text: value}, path: owner.path + "/" + kind[:1] + strconv.Itoa(index),
		seq: n.seq, width: -1, height: -1, opacity: 1, edge: -1, radius: -1, loW: -1, hiW: -1, loH: -1, hiH: -1,
		across: "Stretch", down: "Stretch", span: 1, font: owner.font, colour: owner.colour, lineH: owner.lineH,
		disabled: owner.disabled, item: &uiItem{native: n, owner: owner, index: index, value: value, on: on}}
	owner.kids = append(owner.kids, b)
	return b
}

func (n *uiNative) expand(b *uiBox) {
	v := b.v
	_, spaced := b.attr("gap")
	_, padded := b.attr("pad")
	switch b.kind {
	case "radio":
		b.container, b.row = true, b.wrap
		if !spaced {
			b.gap = 6
			if b.wrap {
				b.gap = 16
			}
		}
		for i, opt := range v.Options {
			n.item(b, "radioItem", i, opt, opt == v.Text)
		}
	case "tabs":
		b.container, b.row, b.scroll = true, true, "Horizontal"
		if !spaced {
			b.gap = 4
		}
		for i, label := range v.Options {
			n.item(b, "tab", i, label, label == v.Text)
		}
	case "choices":
		b.container, b.scroll = true, "Both"
		if !padded {
			b.padX, b.padY = 4, 4
		}
		if b.edge < 0 {
			b.border = 1
		}
		b.corner = 8
		if b.radius >= 0 {
			b.corner = b.radius
		}
		for i, opt := range v.Options {
			n.item(b, "choice", i, opt, uiPicked(v, opt))
		}
	case "branch":
		b.container = true
		head := n.item(b, "branchHead", 0, v.Text, b.selected)
		head.container, head.row, head.align = true, true, "Center"
		head.gap, head.padX, head.padY, head.corner = 4, 4, 2, 6
		n.item(head, "twisty", 0, "", v.Flag)
		label := n.item(head, "label", 1, v.Text, false)
		label.grow = 1
		if !v.Flag || len(v.Children) == 0 {
			return
		}
		under := n.item(b, "branchKids", 1, "", false)
		under.container, under.row = true, true
		indent := n.item(under, "indent", 0, "", false)
		indent.width = 16
		column := n.item(under, "column", 1, "", false)
		column.container, column.grow = true, 1
		for i := range v.Children {
			k := n.build(&v.Children[i], b.path+"/"+strconv.Itoa(i), column)
			switch {
			case k == nil:
			case k.kind == "overlay":
				n.layers = append(n.layers, n.layer(k))
			default:
				column.kids = append(column.kids, k)
			}
		}
	}
}

// Whether an item shows as chosen: what the program said, or what was just done and not yet answered.
func (n *uiNative) itemOn(b *uiBox) bool {
	it := b.item
	if it == nil {
		return false
	}
	switch b.kind {
	case "radioItem", "tab":
		if v, ok := n.pending[it.owner.path]; ok {
			return v == it.value
		}
	case "choice":
		if v, ok := n.pending[b.path]; ok {
			return v != ""
		}
	}
	return it.on
}

func (n *uiNative) itemFocusable(b *uiBox) bool {
	if b.disabled {
		return false
	}
	switch b.kind {
	case "tab", "choice":
		return true
	case "radioItem":
		if n.itemOn(b) {
			return true
		}
		for _, k := range b.item.owner.kids {
			if n.itemOn(k) {
				return false
			}
		}
		return b.item.index == 0
	case "branchHead":
		_, on := b.item.owner.attr("on")
		return on
	}
	return false
}

func (n *uiNative) itemClickable(b *uiBox) bool {
	if b.disabled || b.item == nil {
		return false
	}
	switch b.kind {
	case "radioItem", "tab", "choice":
		return true
	case "branchHead":
		_, on := b.item.owner.attr("on")
		return on
	case "twisty":
		owner := b.item.owner.item.owner
		_, toggles := owner.attr("onToggle")
		return toggles && len(owner.v.Children) > 0
	}
	return false
}

func (n *uiNative) activateItem(b *uiBox) {
	it := b.item
	switch b.kind {
	case "radioItem", "tab":
		if n.itemOn(b) && b.kind == "radioItem" {
			return
		}
		n.pending[it.owner.path] = it.value
		n.post(it.owner.v.Attrs, "choose", it.value, 0)
	case "choice":
		flag := ""
		if !n.itemOn(b) {
			flag = "1"
		}
		n.pending[b.path] = flag
		n.post(it.owner.v.Attrs, "choose", it.value, 0)
	case "branchHead":
		n.post(it.owner.v.Attrs, "click", "", 0)
	case "twisty":
		owner := it.owner.item.owner
		flag := ""
		if !owner.v.Flag {
			flag = "1"
		}
		n.post(owner.v.Attrs, "toggle", flag, 0)
	}
}

// Arrows move the choice along a radio group or a tab strip, and open or close a branch.
func (n *uiNative) itemKey(b *uiBox, k uiKey) bool {
	switch b.kind {
	case "radioItem", "tab":
		step := 0
		switch k {
		case uiKeyLeft, uiKeyUp:
			step = -1
		case uiKeyRight, uiKeyDown:
			step = 1
		}
		if step == 0 {
			return false
		}
		kids := b.item.owner.kids
		at := (b.item.index + step + len(kids)) % len(kids)
		next := kids[at]
		n.focus, n.keyboard = next.path, true
		if b.kind == "radioItem" {
			n.activateItem(next)
		}
		return true
	case "branchHead":
		owner := b.item.owner
		if (k == uiKeyRight && !owner.v.Flag || k == uiKeyLeft && owner.v.Flag) && len(owner.v.Children) > 0 {
			for _, t := range b.kids {
				if t.kind == "twisty" && n.itemClickable(t) {
					n.activateItem(t)
					return true
				}
			}
		}
	}
	return false
}

func (n *uiNative) itemIntrinsic(b *uiBox, edge float64) bool {
	switch b.kind {
	case "radioItem":
		b.maxW = 26 + n.measure(b.font, b.v.Text) + edge
		b.minW = 26 + n.longestWord(b.font, b.v.Text) + edge
	case "tab":
		b.maxW = 24 + n.measure(b.font, b.v.Text) + edge
		b.minW = b.maxW
	case "choice":
		b.maxW = 38 + n.measure(b.font, b.v.Text) + edge
		b.minW = 38 + n.longestWord(b.font, b.v.Text) + edge
	case "label":
		b.maxW, b.minW = n.measure(b.font, b.v.Text)+edge, edge
	case "twisty":
		b.maxW, b.minW = 16, 16
	case "progress":
		b.maxW, b.minW = 0, 0
	case "indent":
		b.maxW, b.minW = 16, 16
	default:
		return false
	}
	return true
}

func (n *uiNative) itemNatural(b *uiBox, edgeX, edgeY float64) (float64, bool) {
	switch b.kind {
	case "radioItem":
		b.lines = n.wrap(b.font, b.v.Text, math.Max(b.w-edgeX-26, 0), false)
		return math.Max(13, float64(len(b.lines))*b.lineH) + edgeY, true
	case "tab":
		return b.lineH + 18 + edgeY, true
	case "choice":
		b.lines = n.wrap(b.font, b.v.Text, math.Max(b.w-edgeX-38, 0), false)
		return float64(len(b.lines))*b.lineH + 12 + edgeY, true
	case "label":
		b.lines = []string{n.ellipsized(b.font, b.v.Text, math.Max(b.w-edgeX, 0))}
		return b.lineH + edgeY, true
	case "twisty":
		return 16, true
	case "progress":
		return 6, true
	case "indent":
		return 0, true
	}
	return 0, false
}

// The longest start of s that fits in width once an ellipsis follows it, or s where it fits whole.
func (n *uiNative) ellipsized(f uiFont, s string, width float64) string {
	if n.measure(f, s) <= width+0.01 {
		return s
	}
	runes := []rune(s)
	for cut := len(runes) - 1; cut > 0; cut-- {
		try := string(runes[:cut]) + "…"
		if n.measure(f, try) <= width+0.01 {
			return try
		}
	}
	return "…"
}

func (n *uiNative) paintItem(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) bool {
	s := n.scale
	x0, y0, x1, y1 := n.rectOf(b)
	line := n.hairline()
	hovered := b.path == n.hover && !b.disabled
	ringed := b.path == n.focus && n.keyboard
	ink := uiMix(under, b.colour, 1)
	if b.disabled {
		ink = uiMix(under, ink, 0.5)
	}
	lift := n.lift(b)
	switch b.kind {
	case "radioItem":
		on := n.itemOn(b)
		cx := math.Round(x0+(b.padX+4)*s) + 6.5*s
		cy := math.Round((y0+y1)/2-6.5*s) + 6.5*s
		r := 6.5 * s
		if ringed {
			cv.ring(cx-r-3*line, cy-r-3*line, cx+r+3*line, cy+r+3*line, r+3*line, 2*line, n.pal.accent, clip)
		}
		edge, fill := n.pal.muted, n.pal.bg
		if hovered {
			edge = n.pal.fg
		}
		if on {
			edge = n.pal.accent
		}
		if b.disabled {
			edge, fill = uiMix(under, edge, 0.5), uiMix(under, fill, 0.5)
		}
		cv.round(cx-r, cy-r, cx+r, cy+r, r, edge, clip)
		inner := r - line
		if on {
			inner = r - 2*s
		}
		cv.round(cx-inner, cy-inner, cx+inner, cy+inner, inner, fill, clip)
		if on {
			dot := 3.5 * s
			cv.round(cx-dot, cy-dot, cx+dot, cy+dot, dot, edge, clip)
		}
		block := float64(len(b.lines)) * b.lineH * s
		top := (y0+y1)/2 - block/2
		for i, text := range b.lines {
			n.say(b.font, x0+(b.padX+26)*s, top+float64(i)*b.lineH*s+lift, text, ink, clip)
		}
	case "tab":
		on := n.itemOn(b)
		colour := n.pal.muted
		switch {
		case on:
			colour = n.pal.accent
		case hovered:
			colour = b.colour
		}
		colour = uiMix(under, colour, 1)
		if b.disabled {
			colour = uiMix(under, colour, 0.5)
		}
		if on {
			cv.fill(int(x0), int(math.Round(y1-2*s)), int(x1), int(y1), colour, clip)
		}
		if ringed {
			cv.ring(x0, y0, x1, y1, 4*s, 2*line, n.pal.accent, clip)
		}
		n.say(b.font, x0+12*s, y0+8*s+lift, b.v.Text, colour, clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)}))
	case "choice":
		on := n.itemOn(b)
		switch {
		case on:
			cv.round(x0, y0, x1, y1, 6*s, uiMix(under, uiRGBA{n.pal.accent.r, n.pal.accent.g, n.pal.accent.b, 36}, 1), clip)
		case hovered:
			cv.round(x0, y0, x1, y1, 6*s, n.pal.surface, clip)
		}
		if ringed {
			cv.ring(x0, y0, x1, y1, 6*s, 2*line, n.pal.accent, clip)
		}
		if on {
			side := int(math.Round(b.font.px * s))
			tick := uiMix(under, n.pal.accent, 1)
			if b.disabled {
				tick = uiMix(under, tick, 0.5)
			}
			if pix := n.iconPixels("Check", tick, side); pix != nil {
				cv.blit(pix, side, side, int(math.Round(x0+8*s)), int(math.Round((y0+y1)/2-float64(side)/2)), clip)
			}
		}
		block := float64(len(b.lines)) * b.lineH * s
		top := (y0+y1)/2 - block/2
		for i, text := range b.lines {
			n.say(b.font, x0+30*s, top+float64(i)*b.lineH*s+lift, text, ink, clip)
		}
	case "branchHead":
		owner := b.item.owner
		switch {
		case owner.selected:
			cv.round(x0, y0, x1, y1, 6*s, uiMix(under, uiRGBA{n.pal.accent.r, n.pal.accent.g, n.pal.accent.b, 36}, 1), clip)
		case hovered && n.itemClickable(b):
			cv.round(x0, y0, x1, y1, 6*s, n.pal.surface, clip)
		}
		if ringed {
			cv.ring(x0, y0, x1, y1, 6*s, 2*line, n.pal.accent, clip)
		}
		return false
	case "twisty":
		owner := b.item.owner.item.owner
		if len(owner.v.Children) == 0 {
			return true
		}
		name := "ChevronRight"
		if owner.v.Flag {
			name = "ChevronDown"
		}
		side := int(math.Round(14 * s))
		if pix := n.iconPixels(name, uiMix(under, n.pal.muted, 1), side); pix != nil {
			cv.blit(pix, side, side, int(math.Round((x0+x1)/2-float64(side)/2)), int(math.Round((y0+y1)/2-float64(side)/2)), clip)
		}
	case "label":
		if len(b.lines) > 0 {
			n.say(b.font, x0+(b.padX+b.border)*s, y0+(b.padY+b.border)*s+lift, b.lines[0], ink,
				clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)}))
		}
	case "progress":
		r := 3 * s
		cv.round(x0, y0, x1, y1, r, n.pal.line, clip)
		if done := uiDone(b.v); done > 0 {
			cv.round(x0, y0, x0+(x1-x0)*done, y1, r, n.pal.accent, clip)
		}
	default:
		return false
	}
	return true
}

// A box's own shadow, as `0 n/2 n rgba(0,0,0,.25)` draws one: a blur whose spread is half the elevation.
func (n *uiNative) boxShadow(cv *uiCanvas, b *uiBox, corner float64, clip uiClip) {
	x0, y0, x1, y1 := n.rectOf(b)
	s := n.scale
	lift := b.shadow / 2 * s
	sigma := math.Max(b.shadow/2*s, 0.5)
	radius := corner * s
	reach := 3 * sigma
	area := cv.bounds(clip).and(uiClip{int(x0 - reach), int(y0 + lift - reach), int(x1 + reach), int(y1 + lift + reach)})
	if area.empty() {
		return
	}
	cv.flush()
	cx, cy := (x0+x1)/2, (y0+y1)/2+lift
	radius = math.Min(radius, math.Min(x1-x0, y1-y0)/2)
	hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
	k := 1 / (sigma * math.Sqrt2)
	for y := area.y0; y < area.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		qy := math.Abs(float64(y)+0.5-cy) - hy
		for x := area.x0; x < area.x1; x++ {
			qx := math.Abs(float64(x)+0.5-cx) - hx
			d := math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
			if a := 0.25 * 0.5 * math.Erfc(d*k); a > 0.002 {
				row[x] = uiBlendPixel(row[x], uiRGBA{0, 0, 0, 255}, a)
			}
		}
	}
}

// A linear gradient as CSS lays one: through the box's middle at the angle, as long as the box is across it.
func (cv *uiCanvas) shade(x0, y0, x1, y1, radius float64, g *uiShading, clip uiClip) {
	r := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)), int(math.Ceil(y1))})
	if r.empty() {
		return
	}
	cv.flush()
	dx, dy := math.Cos(g.angle), math.Sin(g.angle)
	span := math.Abs((x1-x0)*dx) + math.Abs((y1-y0)*dy)
	if span <= 0 {
		span = 1
	}
	cx, cy := (x0+x1)/2, (y0+y1)/2
	radius = math.Min(radius, math.Min(x1-x0, y1-y0)/2)
	hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		py := float64(y) + 0.5
		qy := math.Abs(py-cy) - hy
		for x := r.x0; x < r.x1; x++ {
			px := float64(x) + 0.5
			cover := 1.0
			if radius > 0 {
				qx := math.Abs(px-cx) - hx
				d := math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
				cover = uiClamp(0.5-d, 0, 1)
			}
			if cover <= 0 {
				continue
			}
			t := uiClamp(((px-cx)*dx+(py-cy)*dy)/span+0.5, 0, 1)
			row[x] = uiBlendPixel(row[x], uiLerpColour(g.from, g.to, t), cover)
		}
	}
}

func uiLerpColour(a, b uiRGBA, t float64) uiRGBA {
	mix := func(p, q uint8) uint8 { return uint8(math.Round(float64(p) + (float64(q)-float64(p))*t)) }
	return uiRGBA{mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b), mix(a.a, b.a)}
}

// CSS's `ease`, cubic-bezier(0.25, 0.1, 0.25, 1), solved for x by bisection.
func uiEase(p float64) float64 {
	if p <= 0 {
		return 0
	}
	if p >= 1 {
		return 1
	}
	curve := func(a, b, t float64) float64 { return 3*a*t*(1-t)*(1-t) + 3*b*t*t*(1-t) + t*t*t }
	lo, hi := 0.0, 1.0
	for i := 0; i < 40; i++ {
		mid := (lo + hi) / 2
		if curve(0.25, 0.25, mid) < p {
			lo = mid
		} else {
			hi = mid
		}
	}
	return curve(0.1, 1, (lo+hi)/2)
}

func (n *uiNative) eased(b *uiBox) {
	want := uiEaseState{fill: b.fill, colour: b.colour, opacity: b.opacity, shadow: b.shadow, width: b.width, height: b.height}
	if b.gradient != nil {
		want.gradientFrom, want.gradientTo = b.gradient.from, b.gradient.to
	}
	e := n.easing[b.path]
	if e == nil {
		n.easing[b.path] = &uiEasing{from: want, to: want, now: want, seen: true}
		return
	}
	e.seen = true
	if e.to != want {
		e.from, e.to, e.start = e.now, want, time.Now()
	}
	p := 1.0
	if !e.start.IsZero() {
		p = float64(time.Since(e.start)) / float64(time.Duration(b.ease)*time.Millisecond)
	}
	t := uiEase(p)
	if p < 1 {
		n.easingLive = true
	}
	lerp := func(a, z float64) float64 { return a + (z-a)*t }
	sized := func(a, z float64) float64 {
		if a < 0 || z < 0 {
			return z
		}
		return lerp(a, z)
	}
	e.now = uiEaseState{
		fill: uiLerpColour(e.from.fill, e.to.fill, t), colour: uiLerpColour(e.from.colour, e.to.colour, t),
		opacity: lerp(e.from.opacity, e.to.opacity), shadow: lerp(e.from.shadow, e.to.shadow),
		width: sized(e.from.width, e.to.width), height: sized(e.from.height, e.to.height),
		gradientFrom: uiLerpColour(e.from.gradientFrom, e.to.gradientFrom, t),
		gradientTo:   uiLerpColour(e.from.gradientTo, e.to.gradientTo, t),
	}
	b.fill, b.colour, b.opacity, b.shadow = e.now.fill, e.now.colour, e.now.opacity, e.now.shadow
	b.width, b.height = e.now.width, e.now.height
	if b.gradient != nil {
		b.gradient.from, b.gradient.to = e.now.gradientFrom, e.now.gradientTo
	}
}

func (n *uiNative) forgetEasing() {
	for path, e := range n.easing {
		if !e.seen {
			delete(n.easing, path)
			continue
		}
		e.seen = false
	}
}
