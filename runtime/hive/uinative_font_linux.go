// The system's own fonts, read and rasterized in Go.

//go:build linux && !android

package hive

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

func uixU16(d []byte, at int) int {
	if at < 0 || at+2 > len(d) {
		return 0
	}
	return int(binary.BigEndian.Uint16(d[at:]))
}

func uixI16(d []byte, at int) int { return int(int16(uint16(uixU16(d, at)))) }

func uixU32(d []byte, at int) int {
	if at < 0 || at+4 > len(d) {
		return 0
	}
	return int(binary.BigEndian.Uint32(d[at:]))
}

type uixFace struct {
	path      string
	index     int
	data      []byte
	family    string
	weight    int
	italic    bool
	upm       float64
	asc, desc float64
	ascTag    string
	descTag   string
	avg       float64
	glyf      int
	glyfEnd   int
	loca      int
	longLoca  bool
	cff       *uixCFF
	hmtx      int
	numH      int
	numGlyphs int
	cmapKind  int
	cmapAt    int
	kernPairs map[uint32]int16
	gpos      []int
	pairs     map[uint32]float64
	axes      []uixAxis
	gvar      int
	hvar      int
	mvar      int
	coords    []float64
	base      *uixFace
	instances map[[2]int]*uixFace
	advances  map[uint16]float64
	scalars   map[int][]float64
}

func uixDirectory(d []byte, base int) map[string][2]int {
	count := uixU16(d, base+4)
	tables := map[string][2]int{}
	for i := 0; i < count; i++ {
		at := base + 12 + 16*i
		if at+16 > len(d) {
			break
		}
		off, size := uixU32(d, at+8), uixU32(d, at+12)
		tables[string(d[at:at+4])] = [2]int{off, size}
	}
	return tables
}

func uixNames(name []byte) (string, string) {
	count, strings0 := uixU16(name, 2), uixU16(name, 4)
	found := map[int]string{}
	rank := map[int]int{}
	for i := 0; i < count; i++ {
		at := 6 + 12*i
		platform, encoding, lang, id := uixU16(name, at), uixU16(name, at+2), uixU16(name, at+4), uixU16(name, at+6)
		size, off := uixU16(name, at+8), uixU16(name, at+10)
		if id != 1 && id != 2 && id != 16 && id != 17 {
			continue
		}
		start := strings0 + off
		if start+size > len(name) {
			continue
		}
		raw := name[start : start+size]
		var text string
		score := 0
		switch {
		case platform == 3 && (encoding == 1 || encoding == 10):
			units := make([]uint16, len(raw)/2)
			for k := range units {
				units[k] = binary.BigEndian.Uint16(raw[2*k:])
			}
			text = string(utf16.Decode(units))
			score = 2
			if lang == 0x409 {
				score = 3
			}
		case platform == 1 && encoding == 0:
			text = string(raw)
			score = 1
		default:
			continue
		}
		if score > rank[id] {
			rank[id], found[id] = score, text
		}
	}
	family, style := found[16], found[17]
	if family == "" {
		family = found[1]
	}
	if style == "" {
		style = found[2]
	}
	return family, style
}

func uixTable(data []byte, tables map[string][2]int, tag string) int {
	t, ok := tables[tag]
	if !ok || t[1] == 0 || t[0] < 0 || t[0]+t[1] > len(data) {
		return 0
	}
	return t[0]
}

func uixParse(data []byte, index int, path string) (face *uixFace, err error) {
	defer func() {
		if recover() != nil {
			face, err = nil, errors.New("unreadable font")
		}
	}()
	base := 0
	if len(data) >= 12 && string(data[:4]) == "ttcf" {
		if index >= uixU32(data, 8) {
			return nil, errors.New("no such face")
		}
		base = uixU32(data, 12+4*index)
	}
	tables := uixDirectory(data, base)
	for _, tag := range []string{"head", "hhea", "maxp", "hmtx", "cmap"} {
		if uixTable(data, tables, tag) == 0 {
			return nil, errors.New("not an outline font")
		}
	}
	f := &uixFace{path: path, index: index, data: data, weight: 400, ascTag: "hasc", descTag: "hdsc",
		scalars: map[int][]float64{}, advances: map[uint16]float64{}}
	head, hhea := tables["head"][0], tables["hhea"][0]
	f.upm = float64(uixU16(data, head+18))
	if f.upm < 16 || f.upm > 16384 {
		return nil, errors.New("bad units per em")
	}
	f.asc, f.desc = float64(uixI16(data, hhea+4)), float64(uixI16(data, hhea+6))
	f.numH = uixU16(data, hhea+34)
	f.numGlyphs = uixU16(data, tables["maxp"][0]+4)
	f.hmtx = tables["hmtx"][0]
	if f.numH == 0 || f.hmtx+4*f.numH > len(data) {
		return nil, errors.New("bad metrics")
	}
	glyf, loca := uixTable(data, tables, "glyf"), uixTable(data, tables, "loca")
	switch {
	case glyf != 0 && loca != 0:
		f.longLoca = uixI16(data, head+50) != 0
		f.loca, f.glyf, f.glyfEnd = loca, glyf, glyf+tables["glyf"][1]
	case uixTable(data, tables, "CFF2") != 0:
		if err := f.readCFF(tables["CFF2"][0], true); err != nil {
			return nil, err
		}
	case uixTable(data, tables, "CFF ") != 0:
		if err := f.readCFF(tables["CFF "][0], false); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("no outlines")
	}
	if os2 := uixTable(data, tables, "OS/2"); os2 != 0 && tables["OS/2"][1] >= 78 {
		f.avg = float64(uixI16(data, os2+2))
		f.weight = uixU16(data, os2+4)
		selection := uixU16(data, os2+62)
		f.italic = selection&1 != 0
		if selection&0x80 != 0 || (f.asc == 0 && f.desc == 0) {
			f.asc, f.desc = float64(uixI16(data, os2+68)), float64(uixI16(data, os2+70))
			f.ascTag, f.descTag = "tasc", "tdsc"
		}
		if f.asc == 0 && f.desc == 0 {
			f.asc, f.desc = float64(uixU16(data, os2+74)), -float64(uixU16(data, os2+76))
			f.ascTag, f.descTag = "hcla", "hcld"
		}
	}
	if f.asc <= f.desc {
		f.asc, f.desc = f.upm*0.9, -f.upm*0.25
	}
	if name := uixTable(data, tables, "name"); name != 0 {
		family, style := uixNames(data[name : name+tables["name"][1]])
		f.family = family
		lower := strings.ToLower(style)
		f.italic = f.italic || strings.Contains(lower, "italic") || strings.Contains(lower, "oblique")
	}
	f.chooseCmap(tables["cmap"][0])
	if f.cmapKind == 0 {
		return nil, errors.New("no Unicode character map")
	}
	if fvar := uixTable(data, tables, "fvar"); fvar != 0 {
		f.readAxes(fvar, uixTable(data, tables, "avar"))
		if f.glyf != 0 {
			f.gvar = uixTable(data, tables, "gvar")
		}
		f.hvar = uixTable(data, tables, "HVAR")
		f.mvar = uixTable(data, tables, "MVAR")
	}
	if f.avg <= 0 {
		f.avg = f.advance(f.glyph('x'))
	}
	if gpos := uixTable(data, tables, "GPOS"); gpos != 0 {
		f.gpos = f.kernLookups(gpos)
	}
	if kern := uixTable(data, tables, "kern"); kern != 0 && len(f.gpos) == 0 {
		f.readKern(kern)
	}
	f.pairs = map[uint32]float64{}
	return f, nil
}

func (f *uixFace) chooseCmap(at int) {
	d := f.data
	best := 0
	for i := 0; i < uixU16(d, at+2); i++ {
		rec := at + 4 + 8*i
		platform, encoding := uixU16(d, rec), uixU16(d, rec+2)
		sub := at + uixU32(d, rec+4)
		format := uixU16(d, sub)
		score := 0
		switch {
		case format == 12 && (platform == 0 || (platform == 3 && encoding == 10)):
			score = 4
		case format == 4 && platform == 3 && encoding == 1:
			score = 3
		case format == 4 && platform == 0:
			score = 2
		case format == 4 && platform == 3 && encoding == 0:
			score = 1
		}
		if score > best {
			best, f.cmapKind, f.cmapAt = score, format, sub
		}
	}
}

func (f *uixFace) glyph(r rune) uint16 {
	d, at := f.data, f.cmapAt
	c := int(r)
	switch f.cmapKind {
	case 12:
		lo, hi := 0, uixU32(d, at+12)-1
		for lo <= hi {
			mid := (lo + hi) / 2
			g := at + 16 + 12*mid
			start, end := uixU32(d, g), uixU32(d, g+4)
			switch {
			case c < start:
				hi = mid - 1
			case c > end:
				lo = mid + 1
			default:
				id := uixU32(d, g+8) + c - start
				if id >= f.numGlyphs {
					return 0
				}
				return uint16(id)
			}
		}
	case 4:
		if c > 0xffff {
			return 0
		}
		segs := uixU16(d, at+6) / 2
		ends := at + 14
		starts := ends + 2*segs + 2
		deltas := starts + 2*segs
		ranges := deltas + 2*segs
		lo, hi := 0, segs-1
		for lo < hi {
			mid := (lo + hi) / 2
			if uixU16(d, ends+2*mid) < c {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if segs == 0 || uixU16(d, ends+2*lo) < c || uixU16(d, starts+2*lo) > c {
			return 0
		}
		delta, offset := uixU16(d, deltas+2*lo), uixU16(d, ranges+2*lo)
		id := 0
		if offset == 0 {
			id = (c + delta) & 0xffff
		} else if g := uixU16(d, ranges+2*lo+offset+2*(c-uixU16(d, starts+2*lo))); g != 0 {
			id = (g + delta) & 0xffff
		}
		if id >= f.numGlyphs {
			return 0
		}
		return uint16(id)
	}
	return 0
}

func (f *uixFace) advance(g uint16) float64 {
	i := min(int(g), f.numH-1)
	return f.varAdvance(g, float64(uixU16(f.data, f.hmtx+4*i)))
}

func (f *uixFace) glyphRange(g uint16) (int, int) {
	if f.glyf == 0 || int(g) >= f.numGlyphs {
		return 0, 0
	}
	var start, end int
	if f.longLoca {
		start, end = uixU32(f.data, f.loca+4*int(g)), uixU32(f.data, f.loca+4*int(g)+4)
	} else {
		start, end = 2*uixU16(f.data, f.loca+2*int(g)), 2*uixU16(f.data, f.loca+2*int(g)+2)
	}
	start, end = f.glyf+start, f.glyf+end
	if end <= start || end > f.glyfEnd {
		return 0, 0
	}
	return start, end
}

func (f *uixFace) readKern(at int) {
	d := f.data
	if uixU16(d, at) != 0 {
		return
	}
	f.kernPairs = map[uint32]int16{}
	sub := at + 4
	for t := 0; t < uixU16(d, at+2); t++ {
		size, coverage := uixU16(d, sub+2), uixU16(d, sub+4)
		if coverage>>8 == 0 && coverage&1 != 0 && coverage&6 == 0 {
			for i := 0; i < uixU16(d, sub+6) && i < 1<<16; i++ {
				p := sub + 14 + 6*i
				f.kernPairs[uint32(uixU16(d, p))<<16|uint32(uixU16(d, p+2))] = int16(uixI16(d, p+4))
			}
		}
		if size == 0 {
			break
		}
		sub += size
	}
}

func (f *uixFace) kernLookups(at int) []int {
	d := f.data
	features, lookups := at+uixU16(d, at+6), at+uixU16(d, at+8)
	var subtables []int
	seen := map[int]bool{}
	for i := 0; i < uixU16(d, features); i++ {
		rec := features + 2 + 6*i
		if string(d[min(rec, len(d)):min(rec+4, len(d))]) != "kern" {
			continue
		}
		feature := features + uixU16(d, rec+4)
		for k := 0; k < uixU16(d, feature+2); k++ {
			index := uixU16(d, feature+4+2*k)
			if seen[index] {
				continue
			}
			seen[index] = true
			lookup := lookups + uixU16(d, lookups+2+2*index)
			kind := uixU16(d, lookup)
			for s := 0; s < uixU16(d, lookup+4); s++ {
				sub := lookup + uixU16(d, lookup+6+2*s)
				if kind == 9 && uixU16(d, sub+2) == 2 {
					subtables = append(subtables, sub+uixU32(d, sub+4))
				} else if kind == 2 {
					subtables = append(subtables, sub)
				}
			}
		}
	}
	return subtables
}

func uixCoverage(d []byte, at int, g int) int {
	switch uixU16(d, at) {
	case 1:
		lo, hi := 0, uixU16(d, at+2)-1
		for lo <= hi {
			mid := (lo + hi) / 2
			v := uixU16(d, at+4+2*mid)
			switch {
			case v < g:
				lo = mid + 1
			case v > g:
				hi = mid - 1
			default:
				return mid
			}
		}
	case 2:
		lo, hi := 0, uixU16(d, at+2)-1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := at + 4 + 6*mid
			switch {
			case uixU16(d, r+2) < g:
				lo = mid + 1
			case uixU16(d, r) > g:
				hi = mid - 1
			default:
				return uixU16(d, r+4) + g - uixU16(d, r)
			}
		}
	}
	return -1
}

func uixClass(d []byte, at int, g int) int {
	switch uixU16(d, at) {
	case 1:
		start := uixU16(d, at+2)
		if g >= start && g < start+uixU16(d, at+4) {
			return uixU16(d, at+6+2*(g-start))
		}
	case 2:
		lo, hi := 0, uixU16(d, at+2)-1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := at + 4 + 6*mid
			switch {
			case uixU16(d, r+2) < g:
				lo = mid + 1
			case uixU16(d, r) > g:
				hi = mid - 1
			default:
				return uixU16(d, r+4)
			}
		}
	}
	return 0
}

func uixBits(v int) int {
	n := 0
	for ; v != 0; v &= v - 1 {
		n++
	}
	return n
}

func (f *uixFace) kern(left, right uint16) float64 {
	key := uint32(left)<<16 | uint32(right)
	if f.kernPairs != nil {
		return float64(f.kernPairs[key])
	}
	if len(f.gpos) == 0 {
		return 0
	}
	if v, ok := f.pairs[key]; ok {
		return v
	}
	v := f.gposKern(int(left), int(right))
	if len(f.pairs) > 1<<14 {
		clear(f.pairs)
	}
	f.pairs[key] = v
	return v
}

func (f *uixFace) gposKern(left, right int) float64 {
	d := f.data
	for _, sub := range f.gpos {
		covered := uixCoverage(d, sub+uixU16(d, sub+2), left)
		if covered < 0 {
			continue
		}
		vf1, vf2 := uixU16(d, sub+4), uixU16(d, sub+6)
		size1, size2 := 2*uixBits(vf1&0xff), 2*uixBits(vf2&0xff)
		advance := func(rec int) float64 {
			if vf1&4 == 0 {
				return 0
			}
			return float64(uixI16(d, rec+2*uixBits(vf1&3)))
		}
		switch uixU16(d, sub) {
		case 1:
			if covered >= uixU16(d, sub+8) {
				continue
			}
			set := sub + uixU16(d, sub+10+2*covered)
			stride := 2 + size1 + size2
			lo, hi := 0, uixU16(d, set)-1
			for lo <= hi {
				mid := (lo + hi) / 2
				rec := set + 2 + stride*mid
				switch second := uixU16(d, rec); {
				case second < right:
					lo = mid + 1
				case second > right:
					hi = mid - 1
				default:
					return advance(rec + 2)
				}
			}
		case 2:
			c1 := uixClass(d, sub+uixU16(d, sub+8), left)
			c2 := uixClass(d, sub+uixU16(d, sub+10), right)
			count1, count2 := uixU16(d, sub+12), uixU16(d, sub+14)
			if c1 >= count1 || c2 >= count2 {
				continue
			}
			return advance(sub + 16 + (c1*count2+c2)*(size1+size2))
		}
	}
	return 0
}

type uixPen struct {
	ops            []byte
	pts            []float64
	lx, ly, hx, hy float64
}

func (p *uixPen) reset() {
	p.ops, p.pts = p.ops[:0], p.pts[:0]
	p.lx, p.ly, p.hx, p.hy = math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
}

func (p *uixPen) add(op byte, xy ...float64) {
	p.ops = append(p.ops, op)
	for i := 0; i+1 < len(xy); i += 2 {
		x, y := xy[i], xy[i+1]
		if math.IsNaN(x) || math.IsNaN(y) || math.IsInf(x, 0) || math.IsInf(y, 0) {
			x, y = 0, 0
		}
		p.pts = append(p.pts, x, y)
		p.lx, p.hx = math.Min(p.lx, x), math.Max(p.hx, x)
		p.ly, p.hy = math.Min(p.ly, y), math.Max(p.hy, y)
	}
}

func (p *uixPen) move(x, y float64)                  { p.add('M', x, y) }
func (p *uixPen) line(x, y float64)                  { p.add('L', x, y) }
func (p *uixPen) quad(cx, cy, x, y float64)          { p.add('Q', cx, cy, x, y) }
func (p *uixPen) cubic(ax, ay, bx, by, x, y float64) { p.add('C', ax, ay, bx, by, x, y) }
func (p *uixPen) close()                             { p.add('Z') }

func (p *uixPen) empty() bool { return len(p.ops) == 0 || p.lx > p.hx }

func (p *uixPen) replay(r *uiRaster, sx, dx, sy, dy float64) {
	at := 0
	var ox, oy, cx, cy float64
	open := false
	pt := func() (float64, float64) {
		x, y := p.pts[at]*sx+dx, p.pts[at+1]*sy+dy
		at += 2
		return x, y
	}
	for _, op := range p.ops {
		switch op {
		case 'M':
			if open {
				r.line(cx, cy, ox, oy)
			}
			ox, oy = pt()
			cx, cy, open = ox, oy, true
		case 'L':
			x, y := pt()
			r.line(cx, cy, x, y)
			cx, cy = x, y
		case 'Q':
			qx, qy := pt()
			x, y := pt()
			r.quad(cx, cy, qx, qy, x, y)
			cx, cy = x, y
		case 'C':
			ax, ay := pt()
			bx, by := pt()
			x, y := pt()
			r.cubic(cx, cy, ax, ay, bx, by, x, y)
			cx, cy = x, y
		case 'Z':
			if open {
				r.line(cx, cy, ox, oy)
				cx, cy, open = ox, oy, false
			}
		}
	}
	if open {
		r.line(cx, cy, ox, oy)
	}
}

type uixAffine struct{ xx, xy, yx, yy, dx, dy float64 }

func (m uixAffine) at(x, y float64) (float64, float64) {
	return m.xx*x + m.yx*y + m.dx, m.xy*x + m.yy*y + m.dy
}

func (f *uixFace) trace(g uint16, pen *uixPen) {
	if f.cff != nil {
		f.cffPath(g, pen)
		return
	}
	f.outline(pen, g, uixAffine{xx: 1, yy: 1}, 0)
}

func (f *uixFace) outline(pen *uixPen, g uint16, m uixAffine, depth int) {
	start, end := f.glyphRange(g)
	if end-start < 10 || depth > 8 {
		return
	}
	d := f.data[start:end]
	contours := uixI16(d, 0)
	if contours < 0 {
		f.composite(pen, g, d, m, depth)
		return
	}
	if contours == 0 {
		return
	}
	ends := make([]int, contours)
	for i := range ends {
		ends[i] = uixU16(d, 10+2*i)
	}
	count := ends[contours-1] + 1
	at := 10 + 2*contours
	at += 2 + uixU16(d, at)
	flags := make([]byte, count)
	for i := 0; i < count && at < len(d); {
		flag := d[at]
		at++
		flags[i] = flag
		i++
		if flag&8 != 0 && at < len(d) {
			repeat := int(d[at])
			at++
			for k := 0; k < repeat && i < count; k++ {
				flags[i] = flag
				i++
			}
		}
	}
	xs, ys := make([]float64, count), make([]float64, count)
	for axis, short, same := 0, byte(2), byte(16); axis < 2; axis, short, same = axis+1, 4, 32 {
		v := 0
		for i := 0; i < count; i++ {
			flag := flags[i]
			switch {
			case flag&short != 0:
				step := uixByte(d, at)
				at++
				if flag&same != 0 {
					v += step
				} else {
					v -= step
				}
			case flag&same == 0:
				v += uixI16(d, at)
				at += 2
			}
			if axis == 0 {
				xs[i] = float64(v)
			} else {
				ys[i] = float64(v)
			}
		}
	}
	if f.gvar != 0 && f.varied() {
		if dx, dy := f.gvarDeltas(g, count+4, xs, ys, ends); dx != nil {
			for i := 0; i < count; i++ {
				xs[i] += dx[i]
				ys[i] += dy[i]
			}
		}
	}
	first := 0
	for _, last := range ends {
		if last < first || last >= count {
			return
		}
		f.contour(pen, xs[first:last+1], ys[first:last+1], flags[first:last+1], m)
		first = last + 1
	}
}

func (f *uixFace) contour(pen *uixPen, xs, ys []float64, flags []byte, m uixAffine) {
	n := len(xs)
	if n < 2 {
		return
	}
	on := func(i int) bool { return flags[i]&1 != 0 }
	var sx, sy float64
	begin := 0
	switch {
	case on(0):
		sx, sy, begin = xs[0], ys[0], 1
	case on(n - 1):
		sx, sy = xs[n-1], ys[n-1]
		n--
	default:
		sx, sy = (xs[0]+xs[n-1])/2, (ys[0]+ys[n-1])/2
	}
	ox, oy := m.at(sx, sy)
	pen.move(ox, oy)
	pending := false
	var qx, qy float64
	for i := begin; i < n; i++ {
		px, py := m.at(xs[i], ys[i])
		if on(i) {
			if pending {
				pen.quad(qx, qy, px, py)
			} else {
				pen.line(px, py)
			}
			pending = false
			continue
		}
		if pending {
			pen.quad(qx, qy, (qx+px)/2, (qy+py)/2)
		}
		qx, qy, pending = px, py, true
	}
	if pending {
		pen.quad(qx, qy, ox, oy)
	}
	pen.close()
}

type uixPart struct {
	flags, child int
	e, g         float64
	a, b, c, d   float64
}

func (f *uixFace) composite(pen *uixPen, g uint16, d []byte, m uixAffine, depth int) {
	f2 := func(at int) float64 { return float64(uixI16(d, at)) / 16384 }
	var parts []uixPart
	for at := 10; at+4 <= len(d); {
		p := uixPart{flags: uixU16(d, at), child: uixU16(d, at+2), a: 1, d: 1}
		at += 4
		if p.flags&1 != 0 {
			p.e, p.g = float64(uixI16(d, at)), float64(uixI16(d, at+2))
			at += 4
		} else {
			p.e, p.g = float64(int8(uixByte(d, at))), float64(int8(uixByte(d, at+1)))
			at += 2
		}
		if p.flags&2 == 0 {
			p.e, p.g = 0, 0
		}
		switch {
		case p.flags&8 != 0:
			p.a = f2(at)
			p.d = p.a
			at += 2
		case p.flags&0x40 != 0:
			p.a, p.d = f2(at), f2(at+2)
			at += 4
		case p.flags&0x80 != 0:
			p.a, p.b, p.c, p.d = f2(at), f2(at+2), f2(at+4), f2(at+6)
			at += 8
		}
		parts = append(parts, p)
		if p.flags&0x20 == 0 {
			break
		}
	}
	if f.gvar != 0 && f.varied() {
		if dx, dy := f.gvarDeltas(g, len(parts)+4, nil, nil, nil); dx != nil {
			for i := range parts {
				if parts[i].flags&2 != 0 {
					parts[i].e += dx[i]
					parts[i].g += dy[i]
				}
			}
		}
	}
	for _, p := range parts {
		f.outline(pen, uint16(p.child), uixAffine{
			xx: m.xx*p.a + m.yx*p.b, yx: m.xx*p.c + m.yx*p.d, dx: m.xx*p.e + m.yx*p.g + m.dx,
			xy: m.xy*p.a + m.yy*p.b, yy: m.xy*p.c + m.yy*p.d, dy: m.xy*p.e + m.yy*p.g + m.dy,
		}, depth+1)
	}
}

type uixGlyphKey struct {
	face *uixFace
	size int32
	g    uint16
	sub  uint8
	bold bool
}

type uixGlyph struct {
	mask       []uint8
	w, h, x, y int
}

type uixEntry struct {
	path   string
	index  int
	family string
	weight int
	italic bool
	size   int64
}

type uixFonts struct {
	mu        sync.Mutex
	mono      *uixFace
	monoAsked bool
	regular   *uixFace
	semibold  *uixFace
	bold      *uixFace
	fc        bool
	asked     int
	pending   []uixEntry
	loaded    []*uixFace
	files     map[string]*uixFace
	byRune    map[rune]*uixFace
	glyphs    map[uixGlyphKey]*uixGlyph
	raster    uiRaster
	pen       uixPen
}

var (
	uixFontsOnce  sync.Once
	uixFontsFound *uixFonts
	uixGamma      [256]uint8
)

func uixSystemFonts() *uixFonts {
	uixFontsOnce.Do(func() {
		for i := range uixGamma {
			uixGamma[i] = uint8(math.Round(math.Pow(float64(i)/255, 0.8) * 255))
		}
		fonts := &uixFonts{files: map[string]*uixFace{}, byRune: map[rune]*uixFace{}, glyphs: map[uixGlyphKey]*uixGlyph{}}
		if _, err := exec.LookPath("fc-match"); err == nil {
			fonts.fc = true
			fonts.fromFontconfig()
		}
		if fonts.regular == nil {
			fonts.fc = false
			fonts.fromScan()
		}
		if fonts.regular != nil {
			uixFontsFound = fonts
		}
	})
	return uixFontsFound
}

func (fs *uixFonts) load(path string, index int) *uixFace {
	key := path + "#" + strconv.Itoa(index)
	if f, ok := fs.files[key]; ok {
		return f
	}
	var face *uixFace
	if data, err := os.ReadFile(path); err == nil {
		face, _ = uixParse(data, index, path)
	}
	fs.files[key] = face
	return face
}

func uixFcMatch(pattern string, sorted bool) [][4]string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	args := []string{"-f", "%{file}\t%{index}\t%{family}\t%{weight}\t%{slant}\n", pattern}
	if sorted {
		args = append([]string{"-s"}, args...)
	}
	out, err := exec.CommandContext(ctx, "fc-match", args...).Output()
	if err != nil {
		return nil
	}
	var found [][4]string
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) != 5 || parts[0] == "" {
			continue
		}
		family, _, _ := strings.Cut(parts[2], ",")
		found = append(found, [4]string{parts[0], parts[1], family, parts[3] + "/" + parts[4]})
		if len(found) >= 12 {
			break
		}
	}
	return found
}

func uixDesktopFamily() string {
	if _, err := exec.LookPath("gsettings"); err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "gsettings", "get", "org.gnome.desktop.interface", "font-name").Output()
	if err != nil {
		return ""
	}
	name := strings.Trim(strings.TrimSpace(string(out)), "'\"")
	if i := strings.LastIndexByte(name, ' '); i > 0 {
		if _, err := strconv.ParseFloat(name[i+1:], 64); err == nil {
			name = name[:i]
		}
	}
	return strings.TrimSpace(name)
}

func (fs *uixFonts) fromFontconfig() {
	pick := func(pattern string, family string, lo, hi, least, most int, tries int) (*uixFace, string) {
		for i, m := range uixFcMatch(pattern, true) {
			if i >= tries {
				break
			}
			weight, slant, _ := strings.Cut(m[3], "/")
			w, _ := strconv.Atoi(weight)
			s, _ := strconv.Atoi(slant)
			if s != 0 || w < lo || w > hi || (family != "" && !strings.EqualFold(m[2], family)) {
				continue
			}
			index, _ := strconv.Atoi(m[1])
			if face := fs.load(m[0], index&0xffff); face != nil && face.weight >= least && face.weight <= most {
				return face, m[2]
			}
		}
		return nil, ""
	}
	var regular *uixFace
	family := ""
	if desktop := uixDesktopFamily(); desktop != "" {
		regular, family = pick(desktop, desktop, 0, 150, 0, 549, 3)
	}
	if regular == nil {
		regular, family = pick("sans-serif", "", 0, 150, 0, 549, 12)
	}
	if regular == nil {
		return
	}
	fs.regular = regular
	if _, ok := regular.axis("wght"); ok {
		return
	}
	fs.bold, _ = pick(family+":bold", family, 190, 250, 650, 1000, 3)
	fs.semibold, _ = pick(family+":semibold", family, 160, 189, 550, 649, 3)
}

var uixPreferred = []string{"noto sans", "dejavu sans", "liberation sans", "ubuntu", "cantarell", "open sans",
	"roboto", "arimo", "segoe ui", "arial", "freesans"}

func uixRank(family string) int {
	lower := strings.ToLower(family)
	for i, p := range uixPreferred {
		if lower == p {
			return i
		}
	}
	return len(uixPreferred)
}

func uixDescribe(path string) []uixEntry {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil
	}
	read := func(at, size int) []byte {
		if at < 0 || size <= 0 || size > 1<<20 || int64(at+size) > info.Size() {
			return nil
		}
		b := make([]byte, size)
		if _, err := file.ReadAt(b, int64(at)); err != nil {
			return nil
		}
		return b
	}
	head := read(0, 12)
	if head == nil {
		return nil
	}
	bases := []int{0}
	if string(head[:4]) == "ttcf" {
		count := min(uixU32(head, 8), 64)
		offsets := read(12, 4*count)
		bases = bases[:0]
		for i := 0; i < count; i++ {
			bases = append(bases, uixU32(offsets, 4*i))
		}
	}
	var entries []uixEntry
	for index, base := range bases {
		top := read(base, 12)
		if top == nil {
			continue
		}
		count := uixU16(top, 4)
		dir := read(base+12, 16*count)
		tables := map[string][2]int{}
		for i := 0; i < count && dir != nil; i++ {
			tables[string(dir[16*i:16*i+4])] = [2]int{uixU32(dir, 16*i+8), uixU32(dir, 16*i+12)}
		}
		_, glyf := tables["glyf"]
		_, cff := tables["CFF "]
		_, cff2 := tables["CFF2"]
		if !glyf && !cff && !cff2 {
			continue
		}
		e := uixEntry{path: path, index: index, weight: 400, size: info.Size()}
		if t, ok := tables["name"]; ok {
			family, style := uixNames(read(t[0], t[1]))
			e.family = family
			lower := strings.ToLower(style)
			e.italic = strings.Contains(lower, "italic") || strings.Contains(lower, "oblique")
		}
		if t, ok := tables["OS/2"]; ok {
			if os2 := read(t[0], min(t[1], 96)); len(os2) >= 64 {
				e.weight = uixU16(os2, 4)
				e.italic = e.italic || uixU16(os2, 62)&1 != 0
			}
		}
		if e.family != "" {
			entries = append(entries, e)
		}
	}
	return entries
}

func (fs *uixFonts) fromScan() {
	home, _ := os.UserHomeDir()
	dirs := []string{"/usr/share/fonts", "/usr/local/share/fonts"}
	if data := os.Getenv("XDG_DATA_HOME"); data != "" {
		dirs = append(dirs, filepath.Join(data, "fonts"))
	}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, ".local/share/fonts"), filepath.Join(home, ".fonts"))
	}
	var entries []uixEntry
	visited := map[string]bool{}
	files := 0
	for _, dir := range dirs {
		filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
			if err != nil || files > 5000 {
				return nil
			}
			if d.IsDir() {
				return nil
			}
			switch strings.ToLower(filepath.Ext(path)) {
			case ".ttf", ".ttc", ".otf", ".otc":
			default:
				return nil
			}
			if real, err := filepath.EvalSymlinks(path); err == nil {
				if visited[real] {
					return nil
				}
				visited[real] = true
			}
			files++
			entries = append(entries, uixDescribe(path)...)
			return nil
		})
	}
	upright := entries[:0]
	for _, e := range entries {
		if !e.italic {
			upright = append(upright, e)
		}
	}
	sort.SliceStable(upright, func(i, j int) bool {
		a, b := upright[i], upright[j]
		if ra, rb := uixRank(a.family), uixRank(b.family); ra != rb {
			return ra < rb
		}
		if a.family != b.family {
			return a.family < b.family
		}
		return math.Abs(float64(a.weight-400)) < math.Abs(float64(b.weight-400))
	})
	near := func(family string, want, lo, hi int) *uixFace {
		best, gap := -1, 1<<30
		for i, e := range upright {
			if e.family == family && e.weight >= lo && e.weight <= hi {
				if d := int(math.Abs(float64(e.weight - want))); d < gap {
					best, gap = i, d
				}
			}
		}
		if best < 0 {
			return nil
		}
		return fs.load(upright[best].path, upright[best].index)
	}
	for _, e := range upright {
		if e.weight > 500 {
			continue
		}
		if face := fs.load(e.path, e.index); face != nil {
			fs.regular = face
			if _, ok := face.axis("wght"); !ok {
				fs.bold = near(e.family, 700, 650, 1000)
				fs.semibold = near(e.family, 600, 550, 649)
			}
			break
		}
	}
	if fs.regular == nil {
		return
	}
	chosen := map[string]bool{fs.regular.family: true}
	for _, e := range upright {
		if !chosen[e.family] {
			chosen[e.family] = true
			fs.pending = append(fs.pending, e)
		}
	}
	rest := fs.pending
	sort.SliceStable(rest, func(i, j int) bool {
		ra, rb := uixRank(rest[i].family), uixRank(rest[j].family)
		sa := strings.Contains(strings.ToLower(rest[i].family), "symbol")
		sb := strings.Contains(strings.ToLower(rest[j].family), "symbol")
		switch {
		case ra != rb:
			return ra < rb
		case sa != sb:
			return sa
		}
		return rest[i].size < rest[j].size
	})
}

func uixStyled(face *uixFace, weight int, px float64) (*uixFace, bool) {
	if len(face.axes) > 0 {
		_, heavy := face.axis("wght")
		w := 0.0
		if heavy {
			w = float64(weight)
		}
		face = face.instance(w, px)
		if heavy {
			return face, false
		}
	}
	return face, weight >= 600 && face.weight < 600
}

func (fs *uixFonts) monoFace() *uixFace {
	if fs.monoAsked {
		return fs.mono
	}
	fs.monoAsked = true
	if fs.fc {
		for _, m := range uixFcMatch("monospace", false) {
			index, _ := strconv.Atoi(m[1])
			if face := fs.load(m[0], index&0xffff); face != nil {
				fs.mono = face
				return face
			}
		}
	}
	for _, path := range []string{
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf", "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf", "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
	} {
		if face := fs.load(path, 0); face != nil {
			fs.mono = face
			return face
		}
	}
	return nil
}

func (fs *uixFonts) face(f uiFont) (*uixFace, bool) {
	if f.mono {
		if face := fs.monoFace(); face != nil {
			return uixStyled(face, f.weight, f.px)
		}
	}
	face := fs.regular
	switch {
	case f.weight >= 600 && f.weight < 700 && fs.semibold != nil:
		face = fs.semibold
	case f.weight >= 600 && fs.bold != nil:
		face = fs.bold
	}
	return uixStyled(face, f.weight, f.px)
}

func (fs *uixFonts) find(r rune, primary *uixFace, heavy bool) *uixFace {
	if primary.glyph(r) != 0 {
		return primary
	}
	key := r
	if heavy {
		key |= 1 << 30
	}
	if face, ok := fs.byRune[key]; ok {
		if face == nil {
			return primary
		}
		return face
	}
	var found *uixFace
	if heavy {
		for _, face := range fs.loaded {
			if face.weight >= 600 && face.glyph(r) != 0 {
				found = face
				break
			}
		}
		if found == nil && fs.fc && fs.asked < 256 {
			fs.asked++
			found = fs.fromCharset(r, "sans-serif:bold:charset=", 600)
		}
		if found == nil {
			found = fs.find(r, primary, false)
			if found == primary {
				found = nil
			}
		}
	} else {
		for _, face := range append([]*uixFace{fs.regular, fs.bold, fs.semibold}, fs.loaded...) {
			if face != nil && face.glyph(r) != 0 {
				found = face
				break
			}
		}
		if found == nil && fs.fc && fs.asked < 256 {
			fs.asked++
			found = fs.fromCharset(r, "sans-serif:charset=", 0)
		}
		for found == nil && len(fs.pending) > 0 && len(fs.loaded) < 48 {
			e := fs.pending[0]
			fs.pending = fs.pending[1:]
			if face := fs.load(e.path, e.index); face != nil {
				fs.loaded = append(fs.loaded, face)
				if face.glyph(r) != 0 {
					found = face
				}
			}
		}
	}
	if len(fs.byRune) > 4096 {
		fs.byRune = map[rune]*uixFace{}
	}
	fs.byRune[key] = found
	if found == nil {
		return primary
	}
	return found
}

func (fs *uixFonts) fromCharset(r rune, pattern string, least int) *uixFace {
	for _, m := range uixFcMatch(pattern+strconv.FormatInt(int64(r), 16), false) {
		index, _ := strconv.Atoi(m[1])
		face := fs.load(m[0], index&0xffff)
		if face == nil || face.glyph(r) == 0 {
			return nil
		}
		if _, variable := face.axis("wght"); face.weight < least && !variable {
			return nil
		}
		for _, known := range fs.loaded {
			if known == face {
				return face
			}
		}
		fs.loaded = append(fs.loaded, face)
		return face
	}
	return nil
}

type uixPlaced struct {
	face *uixFace
	g    uint16
	bold bool
}

func (fs *uixFonts) layout(f uiFont, s string, each func(p uixPlaced, kern, advance float64)) {
	primary, bold := fs.face(f)
	var prev uixPlaced
	for _, r := range s {
		if r == '\t' {
			r = ' '
		}
		if r < 0x20 || r == 0x7f {
			continue
		}
		face, heavy := primary, bold
		if found := fs.find(r, primary, f.weight >= 600); found != primary {
			face, heavy = uixStyled(found, f.weight, f.px)
		}
		p := uixPlaced{face: face, g: face.glyph(r), bold: heavy}
		kern := 0.0
		if prev.face == face {
			kern = face.kern(prev.g, p.g) / face.upm
		}
		advance := face.advance(p.g) / face.upm
		if p.bold {
			advance += 1.0 / 24
		}
		each(p, kern, advance)
		prev = p
	}
}

func (fs *uixFonts) measure(f uiFont, s string) float64 {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	total := 0.0
	fs.layout(f, s, func(_ uixPlaced, kern, advance float64) { total += kern + advance })
	return total * f.px
}

func (fs *uixFonts) tall(f uiFont) float64 {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	primary, _ := fs.face(f)
	return (primary.asc - primary.desc) * f.px / primary.upm
}

func (fs *uixFonts) average(f uiFont) float64 {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	primary, _ := fs.face(f)
	return primary.avg * f.px / primary.upm
}

func (fs *uixFonts) draw(cv *uiCanvas, f uiFont, size float64, x, y int, s string, c uiRGBA, clip uiClip) {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	primary, _ := fs.face(f)
	base := int(math.Round(float64(y) + primary.asc*size/primary.upm))
	pen := float64(x)
	fs.layout(f, s, func(p uixPlaced, kern, advance float64) {
		pen += kern * size
		whole := math.Floor(pen)
		quarter := int(math.Round((pen - whole) * 4))
		if quarter == 4 {
			whole, quarter = whole+1, 0
		}
		if gl := fs.render(p, size, uint8(quarter)); gl.mask != nil {
			cv.blend(gl.mask, gl.w, gl.h, int(whole)+gl.x, base+gl.y, c, clip)
		}
		pen += advance * size
	})
}

func (fs *uixFonts) render(p uixPlaced, size float64, quarter uint8) (glyph *uixGlyph) {
	key := uixGlyphKey{face: p.face, size: int32(math.Round(size * 16)), g: p.g, sub: quarter, bold: p.bold}
	if gl, ok := fs.glyphs[key]; ok {
		return gl
	}
	if len(fs.glyphs) > 8192 {
		fs.glyphs = map[uixGlyphKey]*uixGlyph{}
	}
	glyph = &uixGlyph{}
	fs.glyphs[key] = glyph
	defer func() {
		if recover() != nil {
			glyph.mask = nil
		}
	}()
	face := p.face
	pen := &fs.pen
	pen.reset()
	face.trace(p.g, pen)
	if pen.empty() {
		return glyph
	}
	scale := size / face.upm
	shift := float64(quarter) / 4
	extra := 0.0
	if p.bold {
		extra = size / 24
	}
	x0 := int(math.Floor(pen.lx*scale+shift)) - 1
	x1 := int(math.Ceil(pen.hx*scale+shift+extra)) + 1
	y0 := int(math.Floor(-pen.hy*scale)) - 1
	y1 := int(math.Ceil(-pen.ly*scale)) + 1
	w, h := x1-x0, y1-y0
	if w <= 0 || h <= 0 || w*h > 1<<22 {
		return glyph
	}
	fs.raster.reset(w, h)
	pen.replay(&fs.raster, scale, shift-float64(x0), -scale, -float64(y0))
	if p.bold {
		for _, step := range []float64{0.5, 1} {
			pen.replay(&fs.raster, scale, shift-float64(x0)+extra*step, -scale, -float64(y0))
		}
	}
	mask := fs.raster.mask(nil)
	for i, v := range mask {
		mask[i] = uixGamma[v]
	}
	glyph.mask, glyph.w, glyph.h, glyph.x, glyph.y = mask, w, h, x0, y0
	return glyph
}
