// The layouts past a row and a column: a row that wraps, a grid, a stack, and a
// paragraph of words in several fonts; and the limits any box may set on its size.
package hive

import (
	"math"
	"strings"
	"unicode/utf8"
)

type uiLaid struct {
	lines   [][]int
	heights []float64
	cols    []float64
	cells   [][2]int
	rows    int
	frags   []uiFrag
}

// One piece of a paragraph on one line: words of a text or a link, or a whole widget.
type uiFrag struct {
	kid     int
	text    string
	from    int
	x, y, w float64
	line    int
	lineTop float64
	hard    bool
}

func uiLimit(v, lo, hi float64) float64 {
	if hi >= 0 && v > hi {
		v = hi
	}
	if lo >= 0 && v < lo {
		v = lo
	}
	return v
}

func (b *uiBox) innerW() float64 { return math.Max(b.w-2*b.padX-2*b.border, 0) }
func (b *uiBox) innerH() float64 { return math.Max(b.h-2*b.padY-2*b.border, 0) }

func (b *uiBox) lineGapOf() float64 {
	if b.kind == "radio" && b.wrap {
		if _, spaced := b.attr("gap"); !spaced {
			return 6
		}
	}
	return b.gap
}

// --- a row that wraps ------------------------------------------------------

func (n *uiNative) wrapW(b *uiBox, inner float64) {
	b.layout = &uiLaid{}
	var line []int
	used := 0.0
	hyp := func(k *uiBox) float64 {
		basis := k.maxW
		switch {
		case k.width >= 0:
			basis = k.width
		case k.full:
			basis = inner
		}
		return uiLimit(math.Min(math.Max(basis, n.leastW(k, inner)), math.Max(inner, n.leastW(k, inner))), k.loW, k.hiW)
	}
	for i, k := range b.kids {
		size := hyp(k)
		if len(line) > 0 && used+b.gap+size > inner+0.01 {
			b.layout.lines = append(b.layout.lines, line)
			line, used = nil, 0
		}
		if len(line) > 0 {
			used += b.gap
		}
		line = append(line, i)
		used += size
	}
	if len(line) > 0 {
		b.layout.lines = append(b.layout.lines, line)
	}
	for _, line := range b.layout.lines {
		items := make([]uiFlex, len(line))
		for j, i := range line {
			k := b.kids[i]
			it := uiFlex{basis: hyp(k), max: math.Inf(1), shrink: 1, min: n.leastW(k, inner)}
			if k.grow > 0 || k.kind == "spacer" {
				it.grow = math.Max(k.grow, 1)
				it.basis = 0
			}
			uiFlexLimits(&it, k)
			items[j] = it
		}
		uiResolveFlex(items, inner-b.gap*float64(len(line)-1))
		for j, i := range line {
			n.sizeW(b.kids[i], items[j].size)
		}
	}
}

func uiFlexLimits(it *uiFlex, k *uiBox) {
	if k.hiW >= 0 {
		it.max = math.Min(it.max, k.hiW)
	}
	if k.loW >= 0 {
		it.min = math.Max(it.min, k.loW)
	}
	if it.max < it.min {
		it.max = it.min
	}
}

func (n *uiNative) wrapNatural(b *uiBox) float64 {
	total := 0.0
	b.layout.heights = b.layout.heights[:0]
	for li, line := range b.layout.lines {
		tall := 0.0
		for _, i := range line {
			k := b.kids[i]
			h := k.natH
			if k.height >= 0 {
				h = k.height
			}
			tall = math.Max(tall, h)
		}
		b.layout.heights = append(b.layout.heights, tall)
		total += tall
		if li > 0 {
			total += b.lineGapOf()
		}
	}
	return total
}

func (n *uiNative) wrapH(b *uiBox) {
	for li, line := range b.layout.lines {
		for _, i := range line {
			k := b.kids[i]
			kh := k.natH
			switch {
			case k.height >= 0:
				kh = k.height
			case uiStretches(b.align):
				kh = b.layout.heights[li]
			}
			n.sizeH(k, kh)
		}
	}
}

func (n *uiNative) wrapPlace(b *uiBox, x, y float64) {
	inner := b.innerW()
	at := y + b.padY + b.border
	for li, line := range b.layout.lines {
		used := b.gap * float64(len(line)-1)
		for _, i := range line {
			used += b.kids[i].w
		}
		start, extra := uiJustify(b.justify, inner-used, len(line))
		left := x + b.padX + b.border + start
		for _, i := range line {
			k := b.kids[i]
			n.place(k, left, at+uiCross(b.align, b.layout.heights[li], k.h))
			left += k.w + b.gap + extra
		}
		at += b.layout.heights[li] + b.lineGapOf()
	}
}

// --- a grid ------------------------------------------------------------------

func uiShares(b *uiBox) []float64 {
	if a, ok := b.attr("columns"); ok && len(a.Nums) > 0 {
		return a.Nums
	}
	return []float64{1}
}

func (n *uiNative) gridCells(b *uiBox) {
	cols := len(uiShares(b))
	b.layout = &uiLaid{cells: make([][2]int, len(b.kids))}
	r, c := 0, 0
	for i, k := range b.kids {
		span := min(k.span, cols)
		if c > 0 && c+span > cols {
			r, c = r+1, 0
		}
		b.layout.cells[i] = [2]int{r, c}
		c += span
		if c >= cols {
			r, c = r+1, 0
		}
	}
	b.layout.rows = r
	if c > 0 {
		b.layout.rows = r + 1
	}
}

// Each auto column's least and greatest width, from what lies in it alone; a wider span
// shares what it needs more of between the auto columns it crosses.
func (n *uiNative) gridSpans(b *uiBox) ([]float64, []float64) {
	shares := uiShares(b)
	least, most := make([]float64, len(shares)), make([]float64, len(shares))
	for pass := 1; pass <= 2; pass++ {
		for i, k := range b.kids {
			span := min(k.span, len(shares))
			if (pass == 1) != (span == 1) {
				continue
			}
			c := b.layout.cells[i][1]
			var autos []int
			haveLeast, haveMost := b.gap*float64(span-1), b.gap*float64(span-1)
			flexible := false
			for j := c; j < c+span; j++ {
				if shares[j] == 0 {
					autos = append(autos, j)
				} else {
					flexible = true
				}
				haveLeast += least[j]
				haveMost += most[j]
			}
			if len(autos) == 0 || flexible && span > 1 {
				continue
			}
			if need := k.minW - haveLeast; need > 0 {
				for _, j := range autos {
					least[j] += need / float64(len(autos))
				}
			}
			if need := k.maxW - haveMost; need > 0 {
				for _, j := range autos {
					most[j] += need / float64(len(autos))
				}
			}
		}
	}
	for j := range shares {
		most[j] = math.Max(most[j], least[j])
	}
	return least, most
}

func (n *uiNative) gridIntrinsic(b *uiBox, edge float64) {
	n.gridCells(b)
	shares := uiShares(b)
	least, most := n.gridSpans(b)
	gaps := b.gap * float64(len(shares)-1)
	sumMin, sumMax := gaps, gaps
	for j, share := range shares {
		if share == 0 {
			sumMin += least[j]
			sumMax += most[j]
			continue
		}
		widest := 0.0
		for i, k := range b.kids {
			if b.layout.cells[i][1] == j && min(k.span, len(shares)) == 1 {
				widest = math.Max(widest, k.maxW)
			}
		}
		sumMax += widest
	}
	b.minW, b.maxW = sumMin+edge, sumMax+edge
}

// Auto columns grow from their least toward their greatest, equally, before any share is
// handed out; what is left goes to the shares; with no shares, the auto columns take it.
func (n *uiNative) gridW(b *uiBox, inner float64) {
	shares := uiShares(b)
	least, most := n.gridSpans(b)
	space := inner - b.gap*float64(len(shares)-1)
	cols := make([]float64, len(shares))
	var autos []int
	totalShare := 0.0
	for j, share := range shares {
		if share == 0 {
			autos = append(autos, j)
			cols[j] = least[j]
			space -= least[j]
		} else {
			totalShare += share
		}
	}
	for space > 0.01 {
		var open []int
		for _, j := range autos {
			if cols[j] < most[j]-0.01 {
				open = append(open, j)
			}
		}
		if len(open) == 0 {
			break
		}
		each := space / float64(len(open))
		for _, j := range open {
			give := math.Min(each, most[j]-cols[j])
			cols[j] += give
			space -= give
		}
	}
	if space > 0 {
		if totalShare > 0 {
			for j, share := range shares {
				if share > 0 {
					cols[j] = space * share / totalShare
				}
			}
		} else if len(autos) > 0 {
			for _, j := range autos {
				cols[j] += space / float64(len(autos))
			}
		}
	}
	b.layout.cols = cols
	for i, k := range b.kids {
		cell := n.gridSpan(b, i)
		kw := cell
		switch {
		case k.width >= 0:
			kw = math.Min(k.width, cell)
		case b.justify != "" && b.justify != "Between":
			kw = math.Min(k.maxW, math.Max(k.minW, cell))
		}
		n.sizeW(k, kw)
	}
}

func (n *uiNative) gridSpan(b *uiBox, i int) float64 {
	c := b.layout.cells[i][1]
	span := min(b.kids[i].span, len(b.layout.cols))
	w := b.gap * float64(span-1)
	for j := c; j < c+span && j < len(b.layout.cols); j++ {
		w += b.layout.cols[j]
	}
	return w
}

func (n *uiNative) gridNatural(b *uiBox) float64 {
	b.layout.heights = make([]float64, b.layout.rows)
	for i, k := range b.kids {
		h := k.natH
		if k.height >= 0 {
			h = k.height
		}
		r := b.layout.cells[i][0]
		b.layout.heights[r] = math.Max(b.layout.heights[r], h)
	}
	total := b.gap * float64(max(b.layout.rows-1, 0))
	for _, h := range b.layout.heights {
		total += h
	}
	return total
}

func (n *uiNative) gridH(b *uiBox) {
	used := b.gap * float64(max(b.layout.rows-1, 0))
	for _, h := range b.layout.heights {
		used += h
	}
	if extra := b.innerH() - used; extra > 0.01 && b.layout.rows > 0 {
		for r := range b.layout.heights {
			b.layout.heights[r] += extra / float64(b.layout.rows)
		}
	}
	for i, k := range b.kids {
		row := b.layout.heights[b.layout.cells[i][0]]
		kh := row
		switch {
		case k.height >= 0:
			kh = k.height
		case !uiStretches(b.align):
			kh = math.Min(k.natH, row)
		}
		n.sizeH(k, kh)
	}
}

func (n *uiNative) gridPlace(b *uiBox, x, y float64) {
	left := x + b.padX + b.border
	top := y + b.padY + b.border
	colAt := make([]float64, len(b.layout.cols))
	at := left
	for j, w := range b.layout.cols {
		colAt[j] = at
		at += w + b.gap
	}
	rowAt := make([]float64, len(b.layout.heights))
	at = top
	for r, h := range b.layout.heights {
		rowAt[r] = at
		at += h + b.gap
	}
	for i, k := range b.kids {
		r, c := b.layout.cells[i][0], b.layout.cells[i][1]
		across, down := b.justify, b.align
		if k.across != "Stretch" {
			across = k.across
		}
		if k.down != "Stretch" {
			down = k.down
		}
		n.place(k, colAt[c]+uiCross(across, n.gridSpan(b, i), k.w), rowAt[r]+uiCross(down, b.layout.heights[r], k.h))
	}
}

// --- a stack -------------------------------------------------------------------

func (n *uiNative) stackW(b *uiBox, inner float64) {
	for _, k := range b.kids {
		kw := inner
		switch {
		case k.width >= 0:
			kw = math.Min(k.width, inner)
		case k.across != "Stretch":
			kw = math.Min(k.maxW, math.Max(k.minW, inner))
		}
		n.sizeW(k, kw)
	}
}

func (n *uiNative) stackH(b *uiBox) {
	inner := b.innerH()
	for _, k := range b.kids {
		kh := inner
		switch {
		case k.height >= 0:
			kh = k.height
		case k.down != "Stretch":
			kh = math.Min(k.natH, inner)
		}
		n.sizeH(k, kh)
	}
}

func (n *uiNative) stackPlace(b *uiBox, x, y float64) {
	for _, k := range b.kids {
		n.place(k, x+b.padX+b.border+uiCross(k.across, b.innerW(), k.w), y+b.padY+b.border+uiCross(k.down, b.innerH(), k.h))
	}
}

// --- a paragraph ---------------------------------------------------------------

func uiWorded(kind string) bool { return kind == "text" || kind == "link" }

// Every piece a paragraph can break between: a word and the spaces after it, a hard
// break, or a whole widget.
type uiWordPiece struct {
	kid  int
	text string
	from int
	hard bool
}

func (n *uiNative) pieces(b *uiBox) []uiWordPiece {
	var out []uiWordPiece
	for i, k := range b.kids {
		if !uiWorded(k.kind) {
			out = append(out, uiWordPiece{kid: i})
			continue
		}
		at := 0
		for p, para := range strings.Split(k.v.Text, "\n") {
			if p > 0 {
				out = append(out, uiWordPiece{kid: i, hard: true, from: at})
				at++
			}
			for _, word := range uiWords(para) {
				if word != "" {
					out = append(out, uiWordPiece{kid: i, text: word, from: at})
				}
				at += utf8.RuneCountInString(word)
			}
		}
	}
	return out
}

func (n *uiNative) pieceW(b *uiBox, p uiWordPiece, trimmed bool) float64 {
	k := b.kids[p.kid]
	if !uiWorded(k.kind) {
		return k.w
	}
	text := p.text
	if trimmed {
		text = strings.TrimRight(text, " ")
	}
	return n.measure(k.font, text)
}

func (n *uiNative) paragraphIntrinsic(b *uiBox, edge float64) {
	widest, line, least := 0.0, 0.0, 0.0
	for _, p := range n.pieces(b) {
		if p.hard {
			widest, line = math.Max(widest, line), 0
			continue
		}
		k := b.kids[p.kid]
		if !uiWorded(k.kind) {
			line += k.maxW
			least = math.Max(least, k.minW)
			continue
		}
		line += n.measure(k.font, p.text)
		least = math.Max(least, n.measure(k.font, strings.TrimRight(p.text, " ")))
	}
	b.maxW = math.Max(widest, line) + edge
	b.minW = least + edge
}

func (n *uiNative) paragraphW(b *uiBox, inner float64) {
	for _, k := range b.kids {
		if uiWorded(k.kind) {
			k.w = inner
			continue
		}
		kw := math.Min(k.maxW, math.Max(k.minW, inner))
		if k.width >= 0 {
			kw = math.Min(k.width, inner)
		}
		n.sizeW(k, kw)
	}
}

// Lines filled word by word, each set on a shared baseline; a widget stands on it by its middle.
func (n *uiNative) paragraphNatural(b *uiBox) float64 {
	inner := b.innerW()
	laid := &uiLaid{}
	b.layout = laid
	var line []uiFrag
	used := 0.0
	flush := func(hard bool) {
		laid.frags = append(laid.frags, n.settleLine(b, line, len(laid.heights), inner)...)
		line, used = nil, 0
		if hard && len(laid.frags) > 0 {
			laid.frags[len(laid.frags)-1].hard = true
		}
	}
	for _, p := range n.pieces(b) {
		if p.hard {
			if len(line) == 0 {
				line = append(line, uiFrag{kid: p.kid, from: p.from})
			}
			flush(true)
			continue
		}
		w := n.pieceW(b, p, false)
		if len(line) > 0 && used+n.pieceW(b, p, true) > inner+0.01 {
			flush(false)
		}
		line = append(line, uiFrag{kid: p.kid, text: p.text, from: p.from, x: used, w: w})
		used += w
	}
	if len(line) > 0 {
		flush(false)
	}
	n.paragraphJustify(b)
	total := 0.0
	for _, h := range laid.heights {
		total += h
	}
	return total
}

func (n *uiNative) fragHeights(b *uiBox, f uiFrag) (float64, float64, bool) {
	k := b.kids[f.kid]
	if uiWorded(k.kind) {
		above := (k.lineH-n.dev.tall(k.font))/2 + 0.8*n.dev.tall(k.font)
		return above, k.lineH - above, false
	}
	tall := k.natH
	if k.height >= 0 {
		tall = k.height
	}
	if k.kind == "icon" {
		return 0, 0, true
	}
	mid := 0.3 * b.font.px
	return tall/2 + mid, tall/2 - mid, false
}

func (n *uiNative) settleLine(b *uiBox, line []uiFrag, index int, inner float64) []uiFrag {
	above := 0.8*n.dev.tall(b.font) + (b.lineH-n.dev.tall(b.font))/2
	below := b.lineH - above
	for _, f := range line {
		if f.text == "" && uiWorded(b.kids[f.kid].kind) {
			continue
		}
		a, z, _ := n.fragHeights(b, f)
		above, below = math.Max(above, a), math.Max(below, z)
	}
	tall := above + below
	for _, f := range line {
		if k := b.kids[f.kid]; k.kind == "icon" {
			tall = math.Max(tall, k.natH)
		}
	}
	top := 0.0
	for _, h := range b.layout.heights {
		top += h
	}
	b.layout.heights = append(b.layout.heights, tall)
	width := 0.0
	if len(line) > 0 {
		last := line[len(line)-1]
		width = last.x + n.pieceW(b, uiWordPiece{kid: last.kid, text: last.text}, true)
		if !uiWorded(b.kids[last.kid].kind) {
			width = last.x + last.w
		}
	}
	shift := 0.0
	switch b.justify {
	case "Center":
		shift = (inner - width) / 2
	case "End":
		shift = inner - width
	}
	for i := range line {
		f := &line[i]
		a, _, atTop := n.fragHeights(b, *f)
		if f.text == "" && uiWorded(b.kids[f.kid].kind) {
			a = above
		}
		f.x += shift
		f.line, f.lineTop, f.y = index, top, top+above-a
		if atTop {
			f.y = top
		}
	}
	return line
}

// A justified line spreads its slack between its words; the last of a paragraph does not.
func (n *uiNative) paragraphJustify(b *uiBox) {
	if b.justify != "Between" || b.layout == nil {
		return
	}
	inner := b.innerW()
	frags := b.layout.frags
	for start := 0; start < len(frags); {
		end := start
		for end+1 < len(frags) && frags[end+1].line == frags[start].line {
			end++
		}
		lastOfParagraph := end == len(frags)-1 || frags[end].hard
		if !lastOfParagraph && end > start {
			last := frags[end]
			width := last.x + n.pieceW(b, uiWordPiece{kid: last.kid, text: last.text}, true)
			if !uiWorded(b.kids[last.kid].kind) {
				width = last.x + last.w
			}
			extra := (inner - width) / float64(end-start)
			for i := start + 1; i <= end; i++ {
				frags[i].x += extra * float64(i-start)
			}
		}
		start = end + 1
	}
}

func (n *uiNative) paragraphPlace(b *uiBox, x, y float64) {
	left := x + b.padX + b.border
	top := y + b.padY + b.border
	boxes := make([][4]float64, len(b.kids))
	for i := range boxes {
		boxes[i] = [4]float64{math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)}
	}
	for _, f := range b.layout.frags {
		k := b.kids[f.kid]
		if !uiWorded(k.kind) {
			n.place(k, left+f.x, top+f.y)
			continue
		}
		bx := &boxes[f.kid]
		bx[0], bx[1] = math.Min(bx[0], left+f.x), math.Min(bx[1], top+f.y)
		bx[2], bx[3] = math.Max(bx[2], left+f.x+f.w), math.Max(bx[3], top+f.y+k.lineH)
	}
	for i, k := range b.kids {
		if !uiWorded(k.kind) {
			continue
		}
		bx := boxes[i]
		if math.IsInf(bx[0], 1) {
			k.x, k.y, k.w, k.h = left, top, 0, 0
			continue
		}
		k.x, k.y, k.w, k.h = bx[0], bx[1], bx[2]-bx[0], bx[3]-bx[1]
	}
}

func (n *uiNative) fragAt(b *uiBox, x, y float64) (int, bool) { return uiFragAt(b, x, y) }

func uiFragAt(b *uiBox, x, y float64) (int, bool) {
	if b.layout == nil {
		return 0, false
	}
	left := b.x + b.padX + b.border
	top := b.y + b.padY + b.border
	for i, f := range b.layout.frags {
		k := b.kids[f.kid]
		if !uiWorded(k.kind) || f.text == "" {
			continue
		}
		fy := top + f.y
		if x >= left+f.x && x < left+f.x+f.w && y >= fy && y < fy+k.lineH {
			return i, true
		}
	}
	return 0, false
}

// --- text ---------------------------------------------------------------------

func (n *uiNative) textLines(b *uiBox, width float64) []string {
	var lines []string
	if b.unwrapped {
		lines = strings.Split(n.glyphs(b), "\n")
	} else {
		lines = n.wrap(b.font, n.glyphs(b), width, true)
	}
	if b.clamp > 0 && len(lines) > b.clamp {
		lines = lines[:b.clamp]
		lines[b.clamp-1] = n.clipped(b.font, strings.TrimRight(lines[b.clamp-1], " "), width)
	}
	return lines
}

// A line cut short: as much of it as fits with an ellipsis after it.
func (n *uiNative) clipped(f uiFont, s string, width float64) string {
	runes := []rune(s)
	for cut := len(runes); cut > 0; cut-- {
		if try := string(runes[:cut]) + "…"; n.measure(f, try) <= width+0.01 {
			return try
		}
	}
	return "…"
}

// Where a line of a text starts and how much wider each of its spaces is drawn.
func (n *uiNative) lineShift(b *uiBox, i int, line string, inner float64) (float64, float64) {
	w := n.measure(b.font, strings.TrimRight(line, " "))
	switch b.justify {
	case "Center":
		return (inner - w) / 2, 0
	case "End":
		return inner - w, 0
	case "Between":
		last := i == len(b.lines)-1
		if !last {
			text := []rune(b.v.Text)
			starts := uiLineStarts(text, b.lines)
			next := starts[i+1]
			last = next > 0 && next-1 < len(text) && text[next-1] == '\n'
		}
		spaces := strings.Count(strings.TrimRight(line, " "), " ")
		if !last && spaces > 0 && inner > w {
			return 0, (inner - w) / float64(spaces)
		}
	}
	return 0, 0
}
