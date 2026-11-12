// WebP's lossless pictures.
package hive

type uiWpBits struct {
	data []byte
	pos  int
	acc  uint64
	n    uint
	bad  bool
}

func (b *uiWpBits) read(n uint) uint32 {
	for b.n < n {
		if b.pos >= len(b.data) {
			b.bad = true
			return 0
		}
		b.acc |= uint64(b.data[b.pos]) << b.n
		b.pos++
		b.n += 8
	}
	v := uint32(b.acc & (1<<n - 1))
	b.acc >>= n
	b.n -= n
	return v
}

type uiWpCode struct {
	count  [16]uint16
	symbol []uint16
	single int
}

func uiWpBuild(lengths []uint8) (*uiWpCode, bool) {
	c := &uiWpCode{single: -1}
	used := 0
	last := 0
	for s, l := range lengths {
		if l > 15 {
			return nil, false
		}
		if l > 0 {
			c.count[l]++
			used++
			last = s
		}
	}
	if used == 0 {
		return nil, false
	}
	if used == 1 {
		c.single = last
		return c, true
	}
	left := 1
	for l := 1; l < 16; l++ {
		left = left<<1 - int(c.count[l])
		if left < 0 {
			return nil, false
		}
	}
	var offs [16]uint16
	for l := 1; l < 15; l++ {
		offs[l+1] = offs[l] + c.count[l]
	}
	c.symbol = make([]uint16, used)
	for s, l := range lengths {
		if l > 0 {
			c.symbol[offs[l]] = uint16(s)
			offs[l]++
		}
	}
	return c, true
}

func (c *uiWpCode) decode(b *uiWpBits) int {
	if c.single >= 0 {
		return c.single
	}
	code, first, index := 0, 0, 0
	for l := 1; l < 16; l++ {
		code |= int(b.read(1))
		count := int(c.count[l])
		if code-count < first {
			return int(c.symbol[index+code-first])
		}
		index += count
		first = (first + count) << 1
		code <<= 1
	}
	b.bad = true
	return 0
}

var uiWpLengthOrder = [19]int{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

func uiWpReadCode(b *uiWpBits, size int) (*uiWpCode, bool) {
	lengths := make([]uint8, size)
	if b.read(1) == 1 {
		two := b.read(1) == 1
		width := uint(1)
		if b.read(1) == 1 {
			width = 8
		}
		s0 := int(b.read(width))
		if s0 >= size {
			return nil, false
		}
		lengths[s0] = 1
		if two {
			s1 := int(b.read(8))
			if s1 >= size {
				return nil, false
			}
			lengths[s1] = 1
		}
		return uiWpBuild(lengths)
	}
	var meta [19]uint8
	for i, n := 0, int(b.read(4))+4; i < n; i++ {
		meta[uiWpLengthOrder[i]] = uint8(b.read(3))
	}
	lc, ok := uiWpBuild(meta[:])
	if !ok {
		return nil, false
	}
	most := size
	if b.read(1) == 1 {
		most = 2 + int(b.read(2+2*uint(b.read(3))))
		if most > size {
			return nil, false
		}
	}
	prev := uint8(8)
	for s := 0; s < size && most > 0 && !b.bad; most-- {
		l := lc.decode(b)
		if l < 16 {
			lengths[s] = uint8(l)
			s++
			if l != 0 {
				prev = uint8(l)
			}
			continue
		}
		repeat, value := 0, uint8(0)
		switch l {
		case 16:
			repeat, value = 3+int(b.read(2)), prev
		case 17:
			repeat = 3 + int(b.read(3))
		default:
			repeat = 11 + int(b.read(7))
		}
		if s+repeat > size {
			return nil, false
		}
		for ; repeat > 0; repeat-- {
			lengths[s] = value
			s++
		}
	}
	if b.bad {
		return nil, false
	}
	return uiWpBuild(lengths)
}

type uiWpGroup [5]*uiWpCode

type uiWpTransform struct {
	kind  int
	bits  uint
	w     int
	data  []uint32
	count int
}

func uiWpDiv(v int, bits uint) int { return (v + 1<<bits - 1) >> bits }

func uiVP8LDecode(data []byte, headed bool, w, h int) ([]uint32, int, int, bool) {
	b := &uiWpBits{data: data}
	if headed {
		if len(data) < 5 || data[0] != 0x2f {
			return nil, 0, 0, false
		}
		b.pos = 1
		w, h = int(b.read(14))+1, int(b.read(14))+1
		b.read(1)
		if b.read(3) != 0 {
			return nil, 0, 0, false
		}
	}
	if w <= 0 || h <= 0 || w > 16384 || h > 16384 {
		return nil, 0, 0, false
	}
	var transforms []uiWpTransform
	seen := 0
	xs := w
	for b.read(1) == 1 {
		t := uiWpTransform{kind: int(b.read(2)), w: xs}
		if seen&(1<<t.kind) != 0 || b.bad {
			return nil, 0, 0, false
		}
		seen |= 1 << t.kind
		switch t.kind {
		case 0, 1:
			t.bits = uint(b.read(3)) + 2
			img, ok := uiWpImage(b, uiWpDiv(xs, t.bits), uiWpDiv(h, t.bits), false)
			if !ok {
				return nil, 0, 0, false
			}
			t.data = img
		case 3:
			t.count = int(b.read(8)) + 1
			img, ok := uiWpImage(b, t.count, 1, false)
			if !ok {
				return nil, 0, 0, false
			}
			for i := 1; i < len(img); i++ {
				img[i] = uiWpAddPixels(img[i], img[i-1])
			}
			t.data = img
			switch {
			case t.count <= 2:
				t.bits = 3
			case t.count <= 4:
				t.bits = 2
			case t.count <= 16:
				t.bits = 1
			}
			xs = uiWpDiv(xs, t.bits)
		}
		transforms = append(transforms, t)
	}
	pix, ok := uiWpImage(b, xs, h, true)
	if !ok {
		return nil, 0, 0, false
	}
	for i := len(transforms) - 1; i >= 0; i-- {
		pix = transforms[i].undo(pix, h)
	}
	return pix, w, h, true
}

func uiWpAddPixels(a, b uint32) uint32 {
	return (a&0xff00ff00+b&0xff00ff00)&0xff00ff00 | (a&0x00ff00ff+b&0x00ff00ff)&0x00ff00ff
}

func uiWpImage(b *uiWpBits, w, h int, level0 bool) ([]uint32, bool) {
	cacheBits := uint(0)
	if b.read(1) == 1 {
		cacheBits = uint(b.read(4))
		if cacheBits < 1 || cacheBits > 11 {
			return nil, false
		}
	}
	metaBits := uint(0)
	var meta []uint32
	groups := 1
	if level0 && b.read(1) == 1 {
		metaBits = uint(b.read(3)) + 2
		img, ok := uiWpImage(b, uiWpDiv(w, metaBits), uiWpDiv(h, metaBits), false)
		if !ok {
			return nil, false
		}
		meta = img
		for i := range meta {
			meta[i] = (meta[i] >> 8) & 0xffff
			groups = max(groups, int(meta[i])+1)
		}
	}
	if b.bad || groups > w*h+1 {
		return nil, false
	}
	cacheSize := 0
	if cacheBits > 0 {
		cacheSize = 1 << cacheBits
	}
	sizes := [5]int{256 + 24 + cacheSize, 256, 256, 256, 40}
	all := make([]uiWpGroup, groups)
	for g := range all {
		for i, size := range sizes {
			c, ok := uiWpReadCode(b, size)
			if !ok {
				return nil, false
			}
			all[g][i] = c
		}
	}
	out := make([]uint32, w*h)
	var cache []uint32
	if cacheSize > 0 {
		cache = make([]uint32, cacheSize)
	}
	cached := 0
	insert := func(to int) {
		for ; cached < to; cached++ {
			cache[(0x1e35a7bd*out[cached])>>(32-cacheBits)] = out[cached]
		}
	}
	metaW := 0
	if meta != nil {
		metaW = uiWpDiv(w, metaBits)
	}
	for at := 0; at < len(out); {
		if b.bad {
			return nil, false
		}
		g := &all[0]
		if meta != nil {
			x, y := at%w, at/w
			g = &all[meta[(y>>metaBits)*metaW+(x>>metaBits)]]
		}
		s := g[0].decode(b)
		switch {
		case s < 256:
			r := g[1].decode(b)
			bl := g[2].decode(b)
			a := g[3].decode(b)
			out[at] = uint32(a)<<24 | uint32(r)<<16 | uint32(s)<<8 | uint32(bl)
			at++
		case s < 256+24:
			length := uiWpPrefixValue(b, s-256)
			dcode := uiWpPrefixValue(b, g[4].decode(b))
			dist := dcode - 120
			if dcode <= 120 {
				xy := uiWpDistances[dcode-1]
				dist = int(xy[0]) + int(xy[1])*w
			}
			dist = max(dist, 1)
			if dist > at || length > len(out)-at {
				return nil, false
			}
			for i := 0; i < length; i++ {
				out[at+i] = out[at+i-dist]
			}
			at += length
		case cache != nil && s < 256+24+cacheSize:
			insert(at)
			out[at] = cache[s-280]
			at++
		default:
			return nil, false
		}
		if cache != nil {
			insert(at)
		}
	}
	return out, !b.bad
}

func uiWpPrefixValue(b *uiWpBits, prefix int) int {
	if prefix < 4 {
		return prefix + 1
	}
	extra := uint(prefix-2) >> 1
	offset := (2 + prefix&1) << extra
	return offset + int(b.read(extra)) + 1
}

var uiWpDistances = [120][2]int8{
	{0, 1}, {1, 0}, {1, 1}, {-1, 1}, {0, 2}, {2, 0}, {1, 2}, {-1, 2}, {2, 1}, {-2, 1}, {2, 2}, {-2, 2}, {0, 3}, {3, 0},
	{1, 3}, {-1, 3}, {3, 1}, {-3, 1}, {2, 3}, {-2, 3}, {3, 2}, {-3, 2}, {0, 4}, {4, 0}, {1, 4}, {-1, 4}, {4, 1}, {-4, 1},
	{3, 3}, {-3, 3}, {2, 4}, {-2, 4}, {4, 2}, {-4, 2}, {0, 5}, {3, 4}, {-3, 4}, {4, 3}, {-4, 3}, {5, 0}, {1, 5}, {-1, 5},
	{5, 1}, {-5, 1}, {2, 5}, {-2, 5}, {5, 2}, {-5, 2}, {4, 4}, {-4, 4}, {3, 5}, {-3, 5}, {5, 3}, {-5, 3}, {0, 6}, {6, 0},
	{1, 6}, {-1, 6}, {6, 1}, {-6, 1}, {2, 6}, {-2, 6}, {6, 2}, {-6, 2}, {4, 5}, {-4, 5}, {5, 4}, {-5, 4}, {3, 6}, {-3, 6},
	{6, 3}, {-6, 3}, {0, 7}, {7, 0}, {1, 7}, {-1, 7}, {5, 5}, {-5, 5}, {7, 1}, {-7, 1}, {4, 6}, {-4, 6}, {6, 4}, {-6, 4},
	{2, 7}, {-2, 7}, {7, 2}, {-7, 2}, {3, 7}, {-3, 7}, {7, 3}, {-7, 3}, {5, 6}, {-5, 6}, {6, 5}, {-6, 5}, {8, 0}, {4, 7},
	{-4, 7}, {7, 4}, {-7, 4}, {8, 1}, {8, 2}, {6, 6}, {-6, 6}, {8, 3}, {5, 7}, {-5, 7}, {7, 5}, {-7, 5}, {8, 4}, {6, 7},
	{-6, 7}, {7, 6}, {-7, 6}, {8, 5}, {7, 7}, {-7, 7}, {8, 6}, {8, 7},
}

func (t *uiWpTransform) undo(pix []uint32, h int) []uint32 {
	w := t.w
	switch t.kind {
	case 0:
		tw := uiWpDiv(w, t.bits)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				i := y*w + x
				var p uint32
				switch {
				case y == 0 && x == 0:
					p = 0xff000000
				case y == 0:
					p = pix[i-1]
				case x == 0:
					p = pix[i-w]
				default:
					mode := (t.data[(y>>t.bits)*tw+(x>>t.bits)] >> 8) & 0xf
					p = uiWpPredict(mode, pix[i-1], pix[i-w], pix[i-w+1], pix[i-w-1])
				}
				pix[i] = uiWpAddPixels(pix[i], p)
			}
		}
	case 1:
		tw := uiWpDiv(w, t.bits)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				e := t.data[(y>>t.bits)*tw+(x>>t.bits)]
				g2r, g2b, r2b := int8(e), int8(e>>8), int8(e>>16)
				p := pix[y*w+x]
				green := int8(p >> 8)
				red := int(p>>16&0xff) + int(uiWpDelta(g2r, green))
				blue := int(p&0xff) + int(uiWpDelta(g2b, green)) + int(uiWpDelta(r2b, int8(red)))
				pix[y*w+x] = p&0xff00ff00 | uint32(red&0xff)<<16 | uint32(blue&0xff)
			}
		}
	case 2:
		for i, p := range pix {
			g := p >> 8 & 0xff
			pix[i] = p&0xff00ff00 | ((p>>16+g)&0xff)<<16 | (p+g)&0xff
		}
	case 3:
		per := 1 << t.bits
		bitsPer := uint(8 >> t.bits)
		mask := uint32(1<<bitsPer - 1)
		pw := uiWpDiv(w, t.bits)
		out := make([]uint32, w*h)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				idx := (pix[y*pw+(x>>t.bits)] >> 8) & 0xff
				if t.bits > 0 {
					idx = (idx >> (uint(x&(per-1)) * bitsPer)) & mask
				}
				if int(idx) < len(t.data) {
					out[y*w+x] = t.data[idx]
				}
			}
		}
		return out
	}
	return pix
}

func uiWpDelta(t, c int8) int8 { return int8((int(t) * int(c)) >> 5) }

func uiWpAvg(a, b uint32) uint32 {
	return (((a ^ b) & 0xfefefefe) >> 1) + (a & b)
}

func uiWpPredict(mode uint32, l, t, tr, tl uint32) uint32 {
	switch mode {
	case 1:
		return l
	case 2:
		return t
	case 3:
		return tr
	case 4:
		return tl
	case 5:
		return uiWpAvg(uiWpAvg(l, tr), t)
	case 6:
		return uiWpAvg(l, tl)
	case 7:
		return uiWpAvg(l, t)
	case 8:
		return uiWpAvg(tl, t)
	case 9:
		return uiWpAvg(t, tr)
	case 10:
		return uiWpAvg(uiWpAvg(l, tl), uiWpAvg(t, tr))
	case 11:
		pl, pt := 0, 0
		for s := uint(0); s < 32; s += 8 {
			a, b, c := int(l>>s&0xff), int(t>>s&0xff), int(tl>>s&0xff)
			pl += uiWpAbs(b - c)
			pt += uiWpAbs(a - c)
		}
		if pl < pt {
			return l
		}
		return t
	case 12, 13:
		var out uint32
		for s := uint(0); s < 32; s += 8 {
			a, b, c := int(l>>s&0xff), int(t>>s&0xff), int(tl>>s&0xff)
			v := a + b - c
			if mode == 13 {
				avg := (a + b) / 2
				v = avg + (avg-c)/2
			}
			out |= uint32(uiWpClip(v, 255)) << s
		}
		return out
	}
	return 0xff000000
}
