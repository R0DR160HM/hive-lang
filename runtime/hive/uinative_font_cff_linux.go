// CFF and CFF2 outlines, which OpenType fonts like Noto Sans CJK and Cantarell carry.

//go:build linux && !android

package hive

import (
	"errors"
	"math"
)

type uixIndex struct {
	count, offSize, offsets, data int
}

func uixReadIndex(d []byte, at int, wide bool) (uixIndex, int, bool) {
	var ix uixIndex
	head := 2
	if wide {
		ix.count, head = uixU32(d, at), 4
	} else {
		ix.count = uixU16(d, at)
	}
	if ix.count == 0 {
		return ix, at + head, at+head <= len(d)
	}
	ix.offSize = uixByte(d, at+head)
	if ix.offSize < 1 || ix.offSize > 4 || ix.count > 1<<24 {
		return ix, 0, false
	}
	ix.offsets = at + head + 1
	ix.data = ix.offsets + (ix.count+1)*ix.offSize - 1
	last := ix.offsetIn(d, ix.count)
	if ix.data+last > len(d) || ix.data < 0 {
		return ix, 0, false
	}
	return ix, ix.data + last, true
}

func (ix uixIndex) offsetIn(d []byte, i int) int {
	v := 0
	for k := 0; k < ix.offSize; k++ {
		v = v<<8 | uixByte(d, ix.offsets+i*ix.offSize+k)
	}
	return v
}

func (ix uixIndex) item(d []byte, i int) []byte {
	if i < 0 || i >= ix.count {
		return nil
	}
	a, b := ix.offsetIn(d, i), ix.offsetIn(d, i+1)
	if a < 1 || b < a || ix.data+b > len(d) {
		return nil
	}
	return d[ix.data+a : ix.data+b]
}

type uixCFF struct {
	two      bool
	glyphs   uixIndex
	global   uixIndex
	fds      []uixPrivate
	fdSelect int
	charset  int
	store    int
	scale    float64
	sids     map[int]uint16
}

type uixPrivate struct {
	subrs   uixIndex
	vsindex int
	scale   float64
}

func uixBias(count int) int {
	switch {
	case count < 1240:
		return 107
	case count < 33900:
		return 1131
	}
	return 32768
}

func uixDict(d []byte) map[int][]float64 {
	out := map[int][]float64{}
	var args []float64
	for i := 0; i < len(d); {
		b := int(d[i])
		switch {
		case b <= 24:
			op := b
			i++
			if b == 12 {
				op = 1200 + uixByte(d, i)
				i++
			}
			if op == 23 {
				args = args[:0]
				continue
			}
			out[op] = append([]float64(nil), args...)
			args = args[:0]
		case b == 28:
			args = append(args, float64(uixI16(d, i+1)))
			i += 3
		case b == 29:
			args = append(args, float64(int32(uint32(uixU32(d, i+1)))))
			i += 5
		case b == 30:
			v, next := uixReal(d, i+1)
			args = append(args, v)
			i = next
		case b >= 32 && b <= 246:
			args = append(args, float64(b-139))
			i++
		case b >= 247 && b <= 250:
			args = append(args, float64((b-247)*256+uixByte(d, i+1)+108))
			i += 2
		case b >= 251 && b <= 254:
			args = append(args, float64(-(b-251)*256-uixByte(d, i+1)-108))
			i += 2
		default:
			i++
		}
		if len(args) > 513 {
			return out
		}
	}
	return out
}

func uixReal(d []byte, at int) (float64, int) {
	var text []byte
	for ; at < len(d); at++ {
		for _, nib := range [2]byte{d[at] >> 4, d[at] & 15} {
			switch {
			case nib <= 9:
				text = append(text, '0'+nib)
			case nib == 0xa:
				text = append(text, '.')
			case nib == 0xb:
				text = append(text, 'e')
			case nib == 0xc:
				text = append(text, 'e', '-')
			case nib == 0xe:
				text = append(text, '-')
			case nib == 0xf:
				v := 0.0
				if len(text) > 0 {
					v = uixParseFloat(string(text))
				}
				return v, at + 1
			}
		}
	}
	return 0, at
}

func uixParseFloat(s string) float64 {
	mant, exp := s, 0
	for i := 0; i < len(s); i++ {
		if s[i] == 'e' {
			mant = s[:i]
			sign := 1
			j := i + 1
			if j < len(s) && s[j] == '-' {
				sign, j = -1, j+1
			}
			for ; j < len(s); j++ {
				exp = exp*10 + int(s[j]-'0')
			}
			exp *= sign
			break
		}
	}
	v, frac, neg := 0.0, 0.0, false
	scale := 1.0
	for i := 0; i < len(mant); i++ {
		switch c := mant[i]; {
		case c == '-':
			neg = true
		case c == '.':
			frac = 1
		case c >= '0' && c <= '9':
			if frac > 0 {
				scale /= 10
				v += float64(c-'0') * scale
			} else {
				v = v*10 + float64(c-'0')
			}
		}
	}
	if neg {
		v = -v
	}
	return v * math.Pow(10, float64(exp))
}

func uixMatrix(dict map[int][]float64) (float64, bool) {
	if m, ok := dict[1207]; ok && len(m) == 6 && m[0] != 0 {
		return m[0], true
	}
	return 0, false
}

func (f *uixFace) readCFF(at int, two bool) error {
	d := f.data
	c := &uixCFF{two: two, scale: 1}
	var top map[int][]float64
	next := 0
	if two {
		size := uixByte(d, at+2)
		length := uixU16(d, at+3)
		if at+size+length > len(d) {
			return errors.New("bad CFF2")
		}
		top = uixDict(d[at+size : at+size+length])
		var ok bool
		if c.global, _, ok = uixReadIndex(d, at+size+length, true); !ok {
			return errors.New("bad CFF2 subrs")
		}
	} else {
		ok := false
		if _, next, ok = uixReadIndex(d, at+uixByte(d, at+2), false); !ok {
			return errors.New("bad CFF names")
		}
		var tops uixIndex
		if tops, next, ok = uixReadIndex(d, next, false); !ok || tops.count < 1 {
			return errors.New("bad CFF top")
		}
		top = uixDict(tops.item(d, 0))
		if _, next, ok = uixReadIndex(d, next, false); !ok {
			return errors.New("bad CFF strings")
		}
		if c.global, _, ok = uixReadIndex(d, next, false); !ok {
			return errors.New("bad CFF subrs")
		}
	}
	glyphs, ok := top[17]
	if !ok || len(glyphs) < 1 {
		return errors.New("no charstrings")
	}
	if c.glyphs, _, ok = uixReadIndex(d, at+int(glyphs[0]), two); !ok || c.glyphs.count == 0 {
		return errors.New("bad charstrings")
	}
	topScale, hasTop := uixMatrix(top)
	if !hasTop && !two {
		topScale = 0.001
	}
	private := func(dict map[int][]float64, fdScale float64) uixPrivate {
		p := uixPrivate{scale: fdScale}
		if pv, ok := dict[18]; ok && len(pv) >= 2 {
			start, size := at+int(pv[1]), int(pv[0])
			if start >= 0 && size >= 0 && start+size <= len(d) {
				pd := uixDict(d[start : start+size])
				if s, ok := pd[19]; ok && len(s) >= 1 {
					p.subrs, _, _ = uixReadIndex(d, start+int(s[0]), two)
				}
				if v, ok := pd[22]; ok && len(v) >= 1 {
					p.vsindex = int(v[0])
				}
			}
		}
		return p
	}
	if fa, ok := top[1236]; ok && len(fa) >= 1 {
		fdArray, _, ok := uixReadIndex(d, at+int(fa[0]), two)
		if !ok {
			return errors.New("bad FDArray")
		}
		for i := 0; i < fdArray.count && i < 256; i++ {
			dict := uixDict(fdArray.item(d, i))
			s := topScale
			if m, ok := uixMatrix(dict); ok {
				if hasTop {
					s *= m
				} else {
					s = m
				}
			}
			c.fds = append(c.fds, private(dict, s))
		}
		if fs, ok := top[1237]; ok && len(fs) >= 1 {
			c.fdSelect = at + int(fs[0])
		}
	} else {
		c.fds = []uixPrivate{private(top, topScale)}
	}
	if len(c.fds) == 0 {
		return errors.New("no private")
	}
	if cs, ok := top[15]; ok && len(cs) >= 1 && cs[0] > 2 {
		c.charset = at + int(cs[0])
	}
	if vs, ok := top[24]; ok && len(vs) >= 1 && two {
		c.store = at + int(vs[0]) + 2
	}
	f.cff = c
	return nil
}

func (c *uixCFF) fd(d []byte, g int) int {
	if c.fdSelect == 0 || len(c.fds) == 1 {
		return 0
	}
	at := c.fdSelect
	switch uixByte(d, at) {
	case 0:
		return uixByte(d, at+1+g)
	case 3:
		ranges := uixU16(d, at+1)
		for i := 0; i < ranges; i++ {
			r := at + 3 + 3*i
			if g >= uixU16(d, r) && g < uixU16(d, r+3) {
				return uixByte(d, r+2)
			}
		}
	case 4:
		ranges := uixU32(d, at+1)
		for i := 0; i < ranges && i < 1<<16; i++ {
			r := at + 5 + 6*i
			if g >= uixU32(d, r) && g < uixU32(d, r+6) {
				return uixU16(d, r+4)
			}
		}
	}
	return 0
}

func (c *uixCFF) standard(d []byte, code int) (int, bool) {
	sid := 0
	switch {
	case code >= 32 && code <= 126:
		sid = code - 31
	case code >= 161 && code <= 255:
		sid = int(uixStandardHigh[code-161])
	}
	if sid == 0 {
		return 0, false
	}
	if c.sids == nil {
		c.sids = map[int]uint16{}
		g := 1
		at := c.charset
		if at == 0 {
			for g = 1; g < c.glyphs.count && g < 229; g++ {
				c.sids[g] = uint16(g)
			}
		} else {
			switch uixByte(d, at) {
			case 0:
				for ; g < c.glyphs.count; g++ {
					c.sids[uixU16(d, at+1+2*(g-1))] = uint16(g)
				}
			case 1, 2:
				wide := uixByte(d, at) == 2
				p := at + 1
				for g < c.glyphs.count && p < len(d) {
					first := uixU16(d, p)
					left := uixByte(d, p+2)
					p += 3
					if wide {
						left = uixU16(d, p-1)
						p++
					}
					for k := 0; k <= left && g < c.glyphs.count; k++ {
						c.sids[first+k] = uint16(g)
						g++
					}
				}
			}
		}
	}
	g, ok := c.sids[sid]
	return int(g), ok
}

var uixStandardHigh = [95]uint8{
	96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 0,
	111, 112, 113, 114, 0, 115, 116, 117, 118, 119, 120, 121, 122, 0, 123, 0,
	124, 125, 126, 127, 128, 129, 130, 131, 0, 132, 133, 0, 134, 135, 136, 137,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	138, 0, 139, 0, 0, 0, 0, 140, 141, 142, 143, 0, 0, 0, 0, 0,
	144, 0, 0, 0, 145, 0, 0, 146, 147, 148, 149, 0, 0, 0, 0,
}

type uixType2 struct {
	f      *uixFace
	c      *uixCFF
	d      []byte
	pen    *uixPen
	stack  []float64
	x, y   float64
	dx, dy float64
	scale  float64
	stems  int
	sized  bool
	open   bool
	local  uixIndex
	depth  int
	vs     int
	store  []float64
	trans  [32]float64
	seed   uint32
}

func (f *uixFace) cffPath(g uint16, pen *uixPen) {
	c := f.cff
	fd := c.fd(f.data, int(g))
	if fd >= len(c.fds) {
		fd = 0
	}
	p := c.fds[fd]
	t := &uixType2{f: f, c: c, d: f.data, pen: pen, local: p.subrs, vs: p.vsindex, scale: p.scale * f.upm, seed: 1}
	if t.scale == 0 || math.Abs(t.scale-1) < 1e-9 {
		t.scale = 1
	}
	t.stack = make([]float64, 0, 64)
	t.glyph(int(g), 0, 0)
}

func (t *uixType2) glyph(g int, dx, dy float64) {
	code := t.c.glyphs.item(t.d, g)
	if code == nil {
		return
	}
	t.x, t.y, t.dx, t.dy = 0, 0, dx, dy
	t.stack, t.stems, t.sized, t.open = t.stack[:0], 0, t.c.two, false
	defer func() {
		recover()
		t.closePath()
	}()
	t.run(code)
}

func (t *uixType2) point(x, y float64) (float64, float64) {
	return (x + t.dx) * t.scale, (y + t.dy) * t.scale
}

func (t *uixType2) moveTo(dx, dy float64) {
	t.closePath()
	t.x += dx
	t.y += dy
	x, y := t.point(t.x, t.y)
	t.pen.move(x, y)
	t.open = true
}

func (t *uixType2) lineTo(dx, dy float64) {
	t.x += dx
	t.y += dy
	x, y := t.point(t.x, t.y)
	t.pen.line(x, y)
}

func (t *uixType2) curveTo(dx1, dy1, dx2, dy2, dx3, dy3 float64) {
	ax, ay := t.x+dx1, t.y+dy1
	bx, by := ax+dx2, ay+dy2
	t.x, t.y = bx+dx3, by+dy3
	x1, y1 := t.point(ax, ay)
	x2, y2 := t.point(bx, by)
	x3, y3 := t.point(t.x, t.y)
	t.pen.cubic(x1, y1, x2, y2, x3, y3)
}

func (t *uixType2) closePath() {
	if t.open {
		t.pen.close()
		t.open = false
	}
}

func (t *uixType2) width(even bool) {
	if !t.sized {
		t.sized = true
		odd := len(t.stack)%2 == 1
		if odd == even && len(t.stack) > 0 {
			t.stack = t.stack[1:]
		}
	}
}

func (t *uixType2) blend() {
	if len(t.stack) < 1 {
		return
	}
	n := int(t.stack[len(t.stack)-1])
	t.stack = t.stack[:len(t.stack)-1]
	if t.store == nil {
		t.store = t.f.cffScalars(t.vs)
	}
	k := len(t.store)
	if n < 0 || n*(k+1) > len(t.stack) {
		t.stack = t.stack[:0]
		return
	}
	base := len(t.stack) - n*(k+1)
	for i := 0; i < n; i++ {
		v := t.stack[base+i]
		for j := 0; j < k; j++ {
			v += t.stack[base+n+i*k+j] * t.store[j]
		}
		t.stack[base+i] = v
	}
	t.stack = t.stack[:base+n]
}

func (f *uixFace) cffScalars(vs int) []float64 {
	if f.cff.store == 0 || !f.varied() {
		return f.cffZero(vs)
	}
	if s, ok := f.scalars[vs]; ok {
		return s
	}
	s := f.storeScalars(f.cff.store, vs)
	f.scalars[vs] = s
	return s
}

func (f *uixFace) cffZero(vs int) []float64 {
	if f.cff.store == 0 {
		return nil
	}
	d := f.data
	store := f.cff.store
	if uixU16(d, store) != 1 || vs >= uixU16(d, store+6) {
		return nil
	}
	data := store + uixU32(d, store+8+4*vs)
	return make([]float64, uixU16(d, data+4))
}

func (t *uixType2) run(code []byte) bool {
	t.depth++
	defer func() { t.depth-- }()
	if t.depth > 16 {
		return false
	}
	s := func(i int) float64 {
		if i < len(t.stack) {
			return t.stack[i]
		}
		return 0
	}
	for i := 0; i < len(code); {
		b := int(code[i])
		i++
		if b >= 32 || b == 28 {
			var v float64
			switch {
			case b == 28:
				v = float64(uixI16(code, i))
				i += 2
			case b <= 246:
				v = float64(b - 139)
			case b <= 250:
				v = float64((b-247)*256 + uixByte(code, i) + 108)
				i++
			case b <= 254:
				v = float64(-(b-251)*256 - uixByte(code, i) - 108)
				i++
			default:
				v = float64(int32(uint32(uixU32(code, i)))) / 65536
				i += 4
			}
			if len(t.stack) >= 513 {
				return false
			}
			t.stack = append(t.stack, v)
			continue
		}
		n := len(t.stack)
		switch b {
		case 1, 3, 18, 23:
			t.width(true)
			t.stems += len(t.stack) / 2
		case 19, 20:
			t.width(true)
			t.stems += len(t.stack) / 2
			i += (t.stems + 7) / 8
		case 21:
			t.width(true)
			t.moveTo(s(0), s(1))
		case 22:
			t.width(false)
			t.moveTo(s(0), 0)
		case 4:
			t.width(false)
			t.moveTo(0, s(0))
		case 5:
			for k := 0; k+1 < n; k += 2 {
				t.lineTo(s(k), s(k+1))
			}
		case 6, 7:
			across := b == 6
			for k := 0; k < n; k++ {
				if across {
					t.lineTo(s(k), 0)
				} else {
					t.lineTo(0, s(k))
				}
				across = !across
			}
		case 8:
			for k := 0; k+5 < n; k += 6 {
				t.curveTo(s(k), s(k+1), s(k+2), s(k+3), s(k+4), s(k+5))
			}
		case 24:
			k := 0
			for ; k+5 < n-2; k += 6 {
				t.curveTo(s(k), s(k+1), s(k+2), s(k+3), s(k+4), s(k+5))
			}
			t.lineTo(s(k), s(k+1))
		case 25:
			k := 0
			for ; k+1 < n-6; k += 2 {
				t.lineTo(s(k), s(k+1))
			}
			t.curveTo(s(k), s(k+1), s(k+2), s(k+3), s(k+4), s(k+5))
		case 26:
			k, dx1 := 0, 0.0
			if n%2 == 1 {
				dx1, k = s(0), 1
			}
			for ; k+3 < n; k += 4 {
				t.curveTo(dx1, s(k), s(k+1), s(k+2), 0, s(k+3))
				dx1 = 0
			}
		case 27:
			k, dy1 := 0, 0.0
			if n%2 == 1 {
				dy1, k = s(0), 1
			}
			for ; k+3 < n; k += 4 {
				t.curveTo(s(k), dy1, s(k+1), s(k+2), s(k+3), 0)
				dy1 = 0
			}
		case 30, 31:
			across := b == 31
			for k := 0; k+3 < n; k += 4 {
				last := 0.0
				if n-k == 5 {
					last = s(k + 4)
				}
				if across {
					t.curveTo(s(k), 0, s(k+1), s(k+2), last, s(k+3))
				} else {
					t.curveTo(0, s(k), s(k+1), s(k+2), s(k+3), last)
				}
				across = !across
			}
		case 10, 29:
			if n == 0 {
				return false
			}
			index := int(t.stack[n-1])
			t.stack = t.stack[:n-1]
			subrs := t.local
			if b == 29 {
				subrs = t.c.global
			}
			sub := subrs.item(t.d, index+uixBias(subrs.count))
			if sub == nil || !t.run(sub) {
				return false
			}
			continue
		case 11:
			return true
		case 14:
			if t.c.two {
				return false
			}
			t.width(true)
			if len(t.stack) >= 4 {
				t.seac(s(len(t.stack)-4), s(len(t.stack)-3), int(s(len(t.stack)-2)), int(s(len(t.stack)-1)))
			}
			t.closePath()
			return false
		case 15:
			if n > 0 {
				t.vs = int(t.stack[n-1])
				t.store = nil
			}
		case 16:
			t.blend()
			continue
		case 12:
			op := uixByte(code, i)
			i++
			if !t.escape(op) {
				return false
			}
			if op < 34 || op > 37 {
				continue
			}
		default:
		}
		t.stack = t.stack[:0]
	}
	return true
}

func (t *uixType2) seac(adx, ady float64, base, accent int) {
	bg, ok1 := t.c.standard(t.d, base)
	ag, ok2 := t.c.standard(t.d, accent)
	if !ok1 || !ok2 || t.depth > 2 {
		return
	}
	t.closePath()
	stack := t.stack
	t.stack = make([]float64, 0, 64)
	x, y, dx, dy := t.x, t.y, t.dx, t.dy
	t.glyphInner(bg, 0, 0)
	t.glyphInner(ag, adx, ady)
	t.stack, t.x, t.y, t.dx, t.dy = stack[:0], x, y, dx, dy
}

func (t *uixType2) glyphInner(g int, dx, dy float64) {
	code := t.c.glyphs.item(t.d, g)
	if code == nil {
		return
	}
	t.x, t.y, t.dx, t.dy = 0, 0, dx, dy
	t.stack, t.stems, t.sized, t.open = t.stack[:0], 0, false, false
	t.run(code)
	t.closePath()
}

func (t *uixType2) escape(op int) bool {
	st := t.stack
	n := len(st)
	s := func(i int) float64 {
		if i >= 0 && i < n {
			return st[i]
		}
		return 0
	}
	pop := func(k int) bool {
		if n < k {
			return false
		}
		t.stack = st[:n-k]
		return true
	}
	push := func(v float64) { t.stack = append(t.stack, v) }
	switch op {
	case 34:
		t.curveTo(s(0), 0, s(1), s(2), s(3), 0)
		t.curveTo(s(4), 0, s(5), -s(2), s(6), 0)
	case 35:
		t.curveTo(s(0), s(1), s(2), s(3), s(4), s(5))
		t.curveTo(s(6), s(7), s(8), s(9), s(10), s(11))
	case 36:
		t.curveTo(s(0), s(1), s(2), s(3), s(4), 0)
		t.curveTo(s(5), 0, s(6), s(7), s(8), -(s(1) + s(3) + s(7)))
	case 37:
		sx := s(0) + s(2) + s(4) + s(6) + s(8)
		sy := s(1) + s(3) + s(5) + s(7) + s(9)
		lx, ly := s(10), s(10)
		if math.Abs(sx) > math.Abs(sy) {
			ly = -sy
		} else {
			lx = -sx
		}
		t.curveTo(s(0), s(1), s(2), s(3), s(4), s(5))
		t.curveTo(s(6), s(7), s(8), s(9), lx, ly)
	case 3, 4, 10, 11, 12, 15, 24:
		if !pop(2) {
			return false
		}
		a, b := s(n-2), s(n-1)
		v := 0.0
		switch op {
		case 3:
			if a != 0 && b != 0 {
				v = 1
			}
		case 4:
			if a != 0 || b != 0 {
				v = 1
			}
		case 10:
			v = a + b
		case 11:
			v = a - b
		case 12:
			if b != 0 {
				v = a / b
			}
		case 15:
			if a == b {
				v = 1
			}
		case 24:
			v = a * b
		}
		push(v)
	case 5, 9, 14, 26:
		if !pop(1) {
			return false
		}
		a := s(n - 1)
		switch op {
		case 5:
			if a == 0 {
				push(1)
			} else {
				push(0)
			}
		case 9:
			push(math.Abs(a))
		case 14:
			push(-a)
		case 26:
			push(math.Sqrt(math.Abs(a)))
		}
	case 18:
		pop(1)
	case 20:
		if !pop(2) {
			return false
		}
		if i := int(s(n - 1)); i >= 0 && i < len(t.trans) {
			t.trans[i] = s(n - 2)
		}
	case 21:
		if !pop(1) {
			return false
		}
		v := 0.0
		if i := int(s(n - 1)); i >= 0 && i < len(t.trans) {
			v = t.trans[i]
		}
		push(v)
	case 22:
		if !pop(4) {
			return false
		}
		if s(n-2) <= s(n-1) {
			push(s(n - 4))
		} else {
			push(s(n - 3))
		}
	case 23:
		t.seed = t.seed*1103515245 + 12345
		push(float64(t.seed>>8&0xffff+1) / 65537)
	case 27:
		if n < 1 {
			return false
		}
		push(s(n - 1))
	case 28:
		if n < 2 {
			return false
		}
		st[n-1], st[n-2] = st[n-2], st[n-1]
	case 29:
		if !pop(1) {
			return false
		}
		i := int(s(n - 1))
		if i < 0 {
			i = 0
		}
		push(s(n - 2 - i))
	case 30:
		if !pop(2) {
			return false
		}
		count, shift := int(s(n-2)), int(s(n-1))
		if count <= 0 || count > n-2 {
			return true
		}
		part := t.stack[n-2-count:]
		shift = ((shift % count) + count) % count
		rolled := append(append([]float64(nil), part[count-shift:]...), part[:count-shift]...)
		copy(part, rolled)
	}
	return true
}
