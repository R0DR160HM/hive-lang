// WebP's lossy pictures, decoded as libwebp decodes them.
package hive

import "errors"

var uiWpBroken = errors.New("webp: broken")

type uiWpBool struct {
	data  []byte
	pos   int
	value uint32
	rng   uint32
	count int
}

func (d *uiWpBool) init(data []byte) {
	d.data, d.pos, d.rng, d.count = data, 0, 255, 0
	d.value = uint32(d.next())<<8 | uint32(d.next())
}

func (d *uiWpBool) next() byte {
	if d.pos >= len(d.data) {
		d.pos++
		return 0
	}
	b := d.data[d.pos]
	d.pos++
	return b
}

func (d *uiWpBool) bit(prob uint8) int {
	split := 1 + (((d.rng - 1) * uint32(prob)) >> 8)
	big := split << 8
	bit := 0
	if d.value >= big {
		bit = 1
		d.rng -= split
		d.value -= big
	} else {
		d.rng = split
	}
	for d.rng < 128 {
		d.value <<= 1
		d.rng <<= 1
		d.count++
		if d.count == 8 {
			d.count = 0
			d.value |= uint32(d.next())
		}
	}
	return bit
}

func (d *uiWpBool) literal(n int) int {
	v := 0
	for i := 0; i < n; i++ {
		v = v<<1 | d.bit(128)
	}
	return v
}

func (d *uiWpBool) signed(n int) int {
	v := d.literal(n)
	if d.bit(128) == 1 {
		return -v
	}
	return v
}

func (d *uiWpBool) maybe(n int) int {
	if d.bit(128) == 1 {
		return d.signed(n)
	}
	return 0
}

func (d *uiWpBool) tree(t []int8, probs []uint8, start int) int {
	i := start
	for {
		i = int(t[i+d.bit(probs[i>>1])])
		if i <= 0 {
			return -i
		}
	}
}

var uiWpBmodeTree = []int8{0, 2, -1, 4, -2, 6, 8, 12, -3, 10, -5, -6, -4, 14, -7, 16, -8, -9}
var uiWpCoeffTree = []int8{-11, 2, 0, 4, -1, 6, 8, 12, -2, 10, -3, -4, 14, 16, -5, -6, 18, 20, -7, -8, -9, -10}
var uiWpBands = [17]int{0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0}
var uiWpZigzag = [16]int{0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15}
var uiWpCat = [6][]uint8{
	{159},
	{165, 145},
	{173, 148, 140},
	{176, 155, 140, 135},
	{180, 157, 141, 134, 130},
	{254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129},
}
var uiWpCatBase = [6]int{5, 7, 11, 19, 35, 67}

type uiWpFilter struct {
	limit, inner, hev int
	insides           bool
}

type uiWpMB struct {
	i4x4    bool
	ymode   int
	uvmode  int
	modes   [16]int
	segment int
	skip    bool
}

type uiWpVP8 struct {
	w, h, mbw, mbh int
	y, u, v        []uint8
	ys, uvs        int

	segmentOn, segmentMap, absolute bool
	segQ, segLF                     [4]int
	segProb                         [3]uint8
	simple                          bool
	level, sharpness                int
	lfDeltaOn                       bool
	refDelta, modeDelta             [4]int
	probs                           [4][8][3][11]uint8
	skipProb                        int
	dq                              [4][3][2]int
	filters                         [4][2]uiWpFilter
	mbs                             []uiWpMB
	info                            []uiWpFilter
}

func uiWpClip(v, most int) int {
	if v < 0 {
		return 0
	}
	if v > most {
		return most
	}
	return v
}

func uiVP8Decode(data []byte) (*uiWpVP8, error) {
	if len(data) < 10 {
		return nil, uiWpBroken
	}
	tag := int(data[0]) | int(data[1])<<8 | int(data[2])<<16
	if tag&1 != 0 || data[3] != 0x9d || data[4] != 0x01 || data[5] != 0x2a {
		return nil, uiWpBroken
	}
	first := tag >> 5
	d := &uiWpVP8{w: int(data[6]) | int(data[7]&0x3f)<<8, h: int(data[8]) | int(data[9]&0x3f)<<8}
	if d.w == 0 || d.h == 0 || 10+first > len(data) {
		return nil, uiWpBroken
	}
	var br uiWpBool
	br.init(data[10 : 10+first])
	d.header(&br)
	rest := data[10+first:]
	count := 1 << br.literal(2)
	d.quant(&br)
	br.literal(1)
	for i := 0; i < 4; i++ {
		for j := 0; j < 8; j++ {
			for k := 0; k < 3; k++ {
				for l := 0; l < 11; l++ {
					at := ((i*8+j)*3+k)*11 + l
					if br.bit(uiWpCoeffUpdate[at]) == 1 {
						d.probs[i][j][k][l] = uint8(br.literal(8))
					}
				}
			}
		}
	}
	d.skipProb = -1
	if br.literal(1) == 1 {
		d.skipProb = br.literal(8)
	}
	parts := make([]uiWpBool, count)
	sizes := rest
	if len(sizes) < 3*(count-1) {
		return nil, uiWpBroken
	}
	at := 3 * (count - 1)
	for i := 0; i < count; i++ {
		size := len(rest) - at
		if i < count-1 {
			size = int(sizes[3*i]) | int(sizes[3*i+1])<<8 | int(sizes[3*i+2])<<16
		}
		end := min(at+size, len(rest))
		if at > len(rest) {
			at = len(rest)
		}
		parts[i].init(rest[at:end])
		at = end
	}
	d.mbw, d.mbh = (d.w+15)/16, (d.h+15)/16
	d.ys, d.uvs = d.mbw*16, d.mbw*8
	d.y = make([]uint8, d.ys*d.mbh*16)
	d.u = make([]uint8, d.uvs*d.mbh*8)
	d.v = make([]uint8, d.uvs*d.mbh*8)
	d.mbs = make([]uiWpMB, d.mbw)
	d.info = make([]uiWpFilter, d.mbw*d.mbh)
	d.strengths()
	d.frame(&br, parts)
	d.filter()
	return d, nil
}

func (d *uiWpVP8) header(br *uiWpBool) {
	br.literal(2)
	d.segmentOn = br.literal(1) == 1
	if d.segmentOn {
		d.segmentMap = br.literal(1) == 1
		if br.literal(1) == 1 {
			d.absolute = br.literal(1) == 1
			for i := range d.segQ {
				d.segQ[i] = br.maybe(7)
			}
			for i := range d.segLF {
				d.segLF[i] = br.maybe(6)
			}
		}
		if d.segmentMap {
			for i := range d.segProb {
				d.segProb[i] = 255
				if br.literal(1) == 1 {
					d.segProb[i] = uint8(br.literal(8))
				}
			}
		}
	}
	d.simple = br.literal(1) == 1
	d.level = br.literal(6)
	d.sharpness = br.literal(3)
	d.lfDeltaOn = br.literal(1) == 1
	if d.lfDeltaOn && br.literal(1) == 1 {
		for i := range d.refDelta {
			if br.literal(1) == 1 {
				d.refDelta[i] = br.signed(6)
			}
		}
		for i := range d.modeDelta {
			if br.literal(1) == 1 {
				d.modeDelta[i] = br.signed(6)
			}
		}
	}
	for i := range d.probs {
		for j := range d.probs[i] {
			for k := range d.probs[i][j] {
				for l := range d.probs[i][j][k] {
					d.probs[i][j][k][l] = uiWpCoeffDefault[((i*8+j)*3+k)*11+l]
				}
			}
		}
	}
}

func (d *uiWpVP8) quant(br *uiWpBool) {
	base := br.literal(7)
	ydc, y2dc, y2ac, uvdc, uvac := br.maybe(4), br.maybe(4), br.maybe(4), br.maybe(4), br.maybe(4)
	for s := 0; s < 4; s++ {
		q := base
		if d.segmentOn {
			q = d.segQ[s]
			if !d.absolute {
				q += base
			}
		}
		d.dq[s][0] = [2]int{int(uiWpDcQ[uiWpClip(q+ydc, 127)]), int(uiWpAcQ[uiWpClip(q, 127)])}
		ac2 := int(uiWpAcQ[uiWpClip(q+y2ac, 127)]) * 101581 >> 16
		d.dq[s][1] = [2]int{int(uiWpDcQ[uiWpClip(q+y2dc, 127)]) * 2, max(ac2, 8)}
		d.dq[s][2] = [2]int{int(uiWpDcQ[uiWpClip(q+uvdc, 117)]), int(uiWpAcQ[uiWpClip(q+uvac, 127)])}
	}
}

func (d *uiWpVP8) strengths() {
	for s := 0; s < 4; s++ {
		base := d.level
		if d.segmentOn {
			base = d.segLF[s]
			if !d.absolute {
				base += d.level
			}
		}
		for i4 := 0; i4 < 2; i4++ {
			level := base
			if d.lfDeltaOn {
				level += d.refDelta[0]
				if i4 == 1 {
					level += d.modeDelta[0]
				}
			}
			level = uiWpClip(level, 63)
			f := &d.filters[s][i4]
			if level > 0 {
				inner := level
				if d.sharpness > 0 {
					if d.sharpness > 4 {
						inner >>= 2
					} else {
						inner >>= 1
					}
					inner = min(inner, 9-d.sharpness)
				}
				inner = max(inner, 1)
				f.inner, f.limit = inner, 2*level+inner
				f.hev = 0
				if level >= 40 {
					f.hev = 2
				} else if level >= 15 {
					f.hev = 1
				}
			}
			f.insides = i4 == 1
		}
	}
}

type uiWpNz struct {
	y, u, v [4]bool
	dc      bool
}

func (d *uiWpVP8) frame(br *uiWpBool, parts []uiWpBool) {
	top := make([]uiWpNz, d.mbw)
	above := make([]int, d.mbw*4)
	var coeffs [25][16]int
	for mby := 0; mby < d.mbh; mby++ {
		var left uiWpNz
		var leftModes [4]int
		tokens := &parts[mby%len(parts)]
		for mbx := 0; mbx < d.mbw; mbx++ {
			mb := &d.mbs[mbx]
			d.modes(br, mb, above[mbx*4:mbx*4+4], &leftModes)
			coeffs = [25][16]int{}
			nonzero := false
			if mb.skip {
				left.y, left.u, left.v = [4]bool{}, [4]bool{}, [4]bool{}
				top[mbx].y, top[mbx].u, top[mbx].v = [4]bool{}, [4]bool{}, [4]bool{}
				if !mb.i4x4 {
					left.dc, top[mbx].dc = false, false
				}
			} else {
				nonzero = d.residuals(tokens, mb, &top[mbx], &left, &coeffs)
			}
			if d.level > 0 {
				f := d.filters[mb.segment][b2i(mb.i4x4)]
				f.insides = f.insides || nonzero
				d.info[mby*d.mbw+mbx] = f
			}
			d.reconstruct(mbx, mby, mb, &coeffs)
		}
	}
}

func (d *uiWpVP8) modes(br *uiWpBool, mb *uiWpMB, above []int, left *[4]int) {
	mb.segment = 0
	if d.segmentMap {
		if br.bit(d.segProb[0]) == 0 {
			mb.segment = br.bit(d.segProb[1])
		} else {
			mb.segment = 2 + br.bit(d.segProb[2])
		}
	}
	mb.skip = d.skipProb >= 0 && br.bit(uint8(d.skipProb)) == 1
	mb.i4x4 = br.bit(145) == 0
	if !mb.i4x4 {
		if br.bit(156) == 1 {
			mb.ymode = 3 - 2*br.bit(128)
		} else {
			mb.ymode = 2 * br.bit(163)
		}
		for i := 0; i < 4; i++ {
			above[i], left[i] = mb.ymode, mb.ymode
		}
	} else {
		for y := 0; y < 4; y++ {
			l := left[y]
			for x := 0; x < 4; x++ {
				at := (above[x]*10 + l) * 9
				l = br.tree(uiWpBmodeTree, uiWpBmodeProb[at:at+9], 0)
				above[x] = l
				mb.modes[y*4+x] = l
			}
			left[y] = l
		}
	}
	switch {
	case br.bit(142) == 0:
		mb.uvmode = 0
	case br.bit(114) == 0:
		mb.uvmode = 2
	case br.bit(183) == 1:
		mb.uvmode = 1
	default:
		mb.uvmode = 3
	}
}

func (d *uiWpVP8) residuals(br *uiWpBool, mb *uiWpMB, top, left *uiWpNz, out *[25][16]int) bool {
	dq := &d.dq[mb.segment]
	firstY, yType := 0, 3
	any := false
	if !mb.i4x4 {
		var dc [16]int
		ctx := b2i(top.dc) + b2i(left.dc)
		nz := d.coeffs(br, 1, ctx, dq[1], 0, &dc)
		top.dc, left.dc = nz > 0, nz > 0
		var w [16]int
		uiWpWHT(&dc, &w)
		for i := 0; i < 16; i++ {
			out[i][0] = w[i]
		}
		firstY, yType = 1, 0
	}
	for y := 0; y < 4; y++ {
		l := left.y[y]
		for x := 0; x < 4; x++ {
			b := &out[y*4+x]
			nz := d.coeffs(br, yType, b2i(l)+b2i(top.y[x]), dq[0], firstY, b)
			l = nz > firstY
			top.y[x] = l
			if nz > 1 || b[0] != 0 {
				any = true
			}
		}
		left.y[y] = l
	}
	for ch := 0; ch < 2; ch++ {
		t, lf := &top.u, &left.u
		if ch == 1 {
			t, lf = &top.v, &left.v
		}
		for y := 0; y < 2; y++ {
			l := lf[y]
			for x := 0; x < 2; x++ {
				b := &out[16+ch*4+y*2+x]
				nz := d.coeffs(br, 2, b2i(l)+b2i(t[x]), dq[2], 0, b)
				l = nz > 0
				t[x] = l
				if nz > 1 || b[0] != 0 {
					any = true
				}
			}
			lf[y] = l
		}
	}
	return any
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (d *uiWpVP8) coeffs(br *uiWpBool, kind, ctx int, dq [2]int, n int, out *[16]int) int {
	zero := false
	for ; n < 16; n++ {
		p := d.probs[kind][uiWpBands[n]][ctx][:]
		start := 0
		if zero {
			start = 2
		}
		token := br.tree(uiWpCoeffTree, p, start)
		if token == 11 {
			return n
		}
		if token == 0 {
			zero, ctx = true, 0
			continue
		}
		zero = false
		v := token
		if token >= 5 {
			cat := token - 5
			extra := 0
			for _, pr := range uiWpCat[cat] {
				extra = extra<<1 | br.bit(pr)
			}
			v = uiWpCatBase[cat] + extra
		}
		ctx = 2
		if v == 1 {
			ctx = 1
		}
		if br.bit(128) == 1 {
			v = -v
		}
		f := dq[1]
		if n == 0 {
			f = dq[0]
		}
		out[uiWpZigzag[n]] = v * f
	}
	return 16
}

func uiWpWHT(in *[16]int, out *[16]int) {
	var t [16]int
	for i := 0; i < 4; i++ {
		a0 := in[i] + in[12+i]
		a1 := in[4+i] + in[8+i]
		a2 := in[4+i] - in[8+i]
		a3 := in[i] - in[12+i]
		t[i], t[8+i], t[4+i], t[12+i] = a0+a1, a0-a1, a3+a2, a3-a2
	}
	for i := 0; i < 4; i++ {
		dc := t[i*4] + 3
		a0 := dc + t[i*4+3]
		a1 := t[i*4+1] + t[i*4+2]
		a2 := t[i*4+1] - t[i*4+2]
		a3 := dc - t[i*4+3]
		out[i*4], out[i*4+1], out[i*4+2], out[i*4+3] = (a0+a1)>>3, (a3+a2)>>3, (a0-a1)>>3, (a3-a2)>>3
	}
}

func uiWpMul1(a int) int { return (a*20091)>>16 + a }
func uiWpMul2(a int) int { return (a * 35468) >> 16 }

func uiWpClip8(v int) uint8 {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return uint8(v)
}

func uiWpIDCT(in *[16]int, dst []uint8, at, stride int) {
	var c [16]int
	for i := 0; i < 4; i++ {
		a := in[i] + in[8+i]
		b := in[i] - in[8+i]
		cc := uiWpMul2(in[4+i]) - uiWpMul1(in[12+i])
		dd := uiWpMul1(in[4+i]) + uiWpMul2(in[12+i])
		c[i*4], c[i*4+1], c[i*4+2], c[i*4+3] = a+dd, b+cc, b-cc, a-dd
	}
	for i := 0; i < 4; i++ {
		dc := c[i] + 4
		a := dc + c[8+i]
		b := dc - c[8+i]
		cc := uiWpMul2(c[4+i]) - uiWpMul1(c[12+i])
		dd := uiWpMul1(c[4+i]) + uiWpMul2(c[12+i])
		row := dst[at+i*stride:]
		row[0] = uiWpClip8(int(row[0]) + (a+dd)>>3)
		row[1] = uiWpClip8(int(row[1]) + (b+cc)>>3)
		row[2] = uiWpClip8(int(row[2]) + (b-cc)>>3)
		row[3] = uiWpClip8(int(row[3]) + (a-dd)>>3)
	}
}

func uiWpAvg3(a, b, c uint8) uint8 { return uint8((int(a) + 2*int(b) + int(c) + 2) >> 2) }
func uiWpAvg2(a, b uint8) uint8    { return uint8((int(a) + int(b) + 1) >> 1) }

const uiWpBPS = 21

func (d *uiWpVP8) reconstruct(mbx, mby int, mb *uiWpMB, coeffs *[25][16]int) {
	var ws [17 * uiWpBPS]uint8
	x0, y0 := mbx*16, mby*16
	switch {
	case mby == 0:
		for i := 0; i < uiWpBPS; i++ {
			ws[i] = 127
		}
	default:
		copy(ws[1:17], d.y[(y0-1)*d.ys+x0:])
		if mbx == 0 {
			ws[0] = 129
		} else {
			ws[0] = d.y[(y0-1)*d.ys+x0-1]
		}
		if mbx == d.mbw-1 {
			for i := 17; i < 21; i++ {
				ws[i] = d.y[(y0-1)*d.ys+x0+15]
			}
		} else {
			copy(ws[17:21], d.y[(y0-1)*d.ys+x0+16:])
		}
	}
	for r := 1; r <= 16; r++ {
		if mbx == 0 {
			ws[r*uiWpBPS] = 129
		} else {
			ws[r*uiWpBPS] = d.y[(y0+r-1)*d.ys+x0-1]
		}
	}
	if mb.i4x4 {
		for _, r := range []int{4, 8, 12} {
			copy(ws[r*uiWpBPS+17:r*uiWpBPS+21], ws[17:21])
		}
		for n := 0; n < 16; n++ {
			at := (1+(n/4)*4)*uiWpBPS + 1 + (n%4)*4
			uiWpPredict4(ws[:], at, mb.modes[n])
			uiWpIDCT(&coeffs[n], ws[:], at, uiWpBPS)
		}
	} else {
		uiWpPredictBlock(ws[:], uiWpBPS+1, uiWpBPS, 16, uiWpEdgeMode(mb.ymode, mbx, mby))
		for n := 0; n < 16; n++ {
			uiWpIDCT(&coeffs[n], ws[:], (1+(n/4)*4)*uiWpBPS+1+(n%4)*4, uiWpBPS)
		}
	}
	for r := 0; r < 16; r++ {
		copy(d.y[(y0+r)*d.ys+x0:(y0+r)*d.ys+x0+16], ws[(r+1)*uiWpBPS+1:])
	}
	for ch, plane := range [2][]uint8{d.u, d.v} {
		var cs [9 * 9]uint8
		cx, cy := mbx*8, mby*8
		if mby == 0 {
			for i := 0; i < 9; i++ {
				cs[i] = 127
			}
		} else {
			copy(cs[1:9], plane[(cy-1)*d.uvs+cx:])
			if mbx == 0 {
				cs[0] = 129
			} else {
				cs[0] = plane[(cy-1)*d.uvs+cx-1]
			}
		}
		for r := 1; r <= 8; r++ {
			if mbx == 0 {
				cs[r*9] = 129
			} else {
				cs[r*9] = plane[(cy+r-1)*d.uvs+cx-1]
			}
		}
		uiWpPredictBlock(cs[:], 10, 9, 8, uiWpEdgeMode(mb.uvmode, mbx, mby))
		for n := 0; n < 4; n++ {
			uiWpIDCT(&coeffs[16+ch*4+n], cs[:], (1+(n/2)*4)*9+1+(n%2)*4, 9)
		}
		for r := 0; r < 8; r++ {
			copy(plane[(cy+r)*d.uvs+cx:(cy+r)*d.uvs+cx+8], cs[(r+1)*9+1:])
		}
	}
}

func uiWpEdgeMode(mode, mbx, mby int) int {
	if mode != 0 {
		return mode
	}
	switch {
	case mbx == 0 && mby == 0:
		return 6
	case mbx == 0:
		return 5
	case mby == 0:
		return 4
	}
	return 0
}

func uiWpPredictBlock(ws []uint8, at, stride, size, mode int) {
	topRow := ws[at-stride : at-stride+size]
	leftAt := func(r int) uint8 { return ws[at+r*stride-1] }
	shift := 3
	if size == 16 {
		shift = 4
	}
	fill := func(v uint8) {
		for r := 0; r < size; r++ {
			for c := 0; c < size; c++ {
				ws[at+r*stride+c] = v
			}
		}
	}
	switch mode {
	case 0, 4, 5:
		sum := 0
		n := shift
		if mode != 5 {
			for r := 0; r < size; r++ {
				sum += int(leftAt(r))
			}
		}
		if mode != 4 {
			for _, v := range topRow {
				sum += int(v)
			}
		}
		if mode == 0 {
			n++
		}
		fill(uint8((sum + 1<<(n-1)) >> n))
	case 6:
		fill(128)
	case 1:
		tl := int(ws[at-stride-1])
		for r := 0; r < size; r++ {
			l := int(leftAt(r))
			for c := 0; c < size; c++ {
				ws[at+r*stride+c] = uiWpClip8(l + int(topRow[c]) - tl)
			}
		}
	case 2:
		for r := 0; r < size; r++ {
			copy(ws[at+r*stride:at+r*stride+size], topRow)
		}
	case 3:
		for r := 0; r < size; r++ {
			v := leftAt(r)
			for c := 0; c < size; c++ {
				ws[at+r*stride+c] = v
			}
		}
	}
}

func uiWpPredict4(ws []uint8, at, mode int) {
	s := uiWpBPS
	A := func(i int) uint8 { return ws[at-s+i] }
	L := func(i int) uint8 {
		if i < 0 {
			return ws[at-s-1]
		}
		return ws[at+i*s-1]
	}
	P := ws[at-s-1]
	set := func(r, c int, v uint8) { ws[at+r*s+c] = v }
	E := [9]uint8{L(3), L(2), L(1), L(0), P, A(0), A(1), A(2), A(3)}
	e3 := func(i int) uint8 { return uiWpAvg3(E[i-1], E[i], E[i+1]) }
	e2 := func(i int) uint8 { return uiWpAvg2(E[i], E[i+1]) }
	a3 := func(i int) uint8 { return uiWpAvg3(A(i-1), A(i), A(i+1)) }
	a2 := func(i int) uint8 { return uiWpAvg2(A(i), A(i+1)) }
	l3 := func(i int) uint8 { return uiWpAvg3(L(i-1), L(i), L(i+1)) }
	l2 := func(i int) uint8 { return uiWpAvg2(L(i), L(i+1)) }
	switch mode {
	case 0:
		v := 4
		for i := 0; i < 4; i++ {
			v += int(A(i)) + int(L(i))
		}
		for r := 0; r < 4; r++ {
			for c := 0; c < 4; c++ {
				set(r, c, uint8(v>>3))
			}
		}
	case 1:
		for r := 0; r < 4; r++ {
			for c := 0; c < 4; c++ {
				set(r, c, uiWpClip8(int(L(r))+int(A(c))-int(P)))
			}
		}
	case 2:
		for c := 0; c < 4; c++ {
			v := a3(c)
			for r := 0; r < 4; r++ {
				set(r, c, v)
			}
		}
	case 3:
		for r := 0; r < 4; r++ {
			v := uiWpAvg3(L(2), L(3), L(3))
			if r < 3 {
				v = l3(r)
			}
			for c := 0; c < 4; c++ {
				set(r, c, v)
			}
		}
	case 4:
		for r := 0; r < 4; r++ {
			for c := 0; c < 4; c++ {
				if r+c == 6 {
					set(r, c, uiWpAvg3(A(6), A(7), A(7)))
				} else {
					set(r, c, a3(r+c+1))
				}
			}
		}
	case 5:
		for r := 0; r < 4; r++ {
			for c := 0; c < 4; c++ {
				set(r, c, e3(4-r+c))
			}
		}
	case 6:
		set(3, 0, e3(2))
		set(2, 0, e3(3))
		set(3, 1, e3(4))
		set(1, 0, e3(4))
		set(2, 1, e2(4))
		set(0, 0, e2(4))
		set(3, 2, e3(5))
		set(1, 1, e3(5))
		set(2, 2, e2(5))
		set(0, 1, e2(5))
		set(3, 3, e3(6))
		set(1, 2, e3(6))
		set(2, 3, e2(6))
		set(0, 2, e2(6))
		set(1, 3, e3(7))
		set(0, 3, e2(7))
	case 7:
		set(0, 0, a2(0))
		set(1, 0, a3(1))
		set(2, 0, a2(1))
		set(0, 1, a2(1))
		set(1, 1, a3(2))
		set(3, 0, a3(2))
		set(2, 1, a2(2))
		set(0, 2, a2(2))
		set(3, 1, a3(3))
		set(1, 2, a3(3))
		set(2, 2, a2(3))
		set(0, 3, a2(3))
		set(3, 2, a3(4))
		set(1, 3, a3(4))
		set(2, 3, a3(5))
		set(3, 3, a3(6))
	case 8:
		set(3, 0, e2(0))
		set(3, 1, e3(1))
		set(2, 0, e2(1))
		set(3, 2, e2(1))
		set(2, 1, e3(2))
		set(3, 3, e3(2))
		set(2, 2, e2(2))
		set(1, 0, e2(2))
		set(2, 3, e3(3))
		set(1, 1, e3(3))
		set(1, 2, e2(3))
		set(0, 0, e2(3))
		set(1, 3, e3(4))
		set(0, 1, e3(4))
		set(0, 2, e3(5))
		set(0, 3, e3(6))
	case 9:
		set(0, 0, l2(0))
		set(0, 1, l3(1))
		set(0, 2, l2(1))
		set(1, 0, l2(1))
		set(0, 3, l3(2))
		set(1, 1, l3(2))
		set(1, 2, l2(2))
		set(2, 0, l2(2))
		v := uiWpAvg3(L(2), L(3), L(3))
		set(1, 3, v)
		set(2, 1, v)
		for _, rc := range [][2]int{{2, 2}, {2, 3}, {3, 0}, {3, 1}, {3, 2}, {3, 3}} {
			set(rc[0], rc[1], L(3))
		}
	}
}

func uiWpAbs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func uiWpSclip1(v int) int { return max(-128, min(127, v)) }
func uiWpSclip2(v int) int { return max(-16, min(15, v)) }

type uiWpEdge struct {
	p    []uint8
	at   int
	step int
}

func (e uiWpEdge) px(i int) int { return int(e.p[e.at+i*e.step]) }
func (e uiWpEdge) put(i, v int) { e.p[e.at+i*e.step] = uiWpClip8(v) }

func (e uiWpEdge) needs(t int) bool {
	return 4*uiWpAbs(e.px(-1)-e.px(0))+uiWpAbs(e.px(-2)-e.px(1)) <= t
}

func (e uiWpEdge) needs2(t, it int) bool {
	if !e.needs(t) {
		return false
	}
	p3, p2, p1, p0 := e.px(-4), e.px(-3), e.px(-2), e.px(-1)
	q0, q1, q2, q3 := e.px(0), e.px(1), e.px(2), e.px(3)
	return uiWpAbs(p3-p2) <= it && uiWpAbs(p2-p1) <= it && uiWpAbs(p1-p0) <= it &&
		uiWpAbs(q3-q2) <= it && uiWpAbs(q2-q1) <= it && uiWpAbs(q1-q0) <= it
}

func (e uiWpEdge) hev(t int) bool {
	return uiWpAbs(e.px(-2)-e.px(-1)) > t || uiWpAbs(e.px(1)-e.px(0)) > t
}

func (e uiWpEdge) filter2() {
	p1, p0, q0, q1 := e.px(-2), e.px(-1), e.px(0), e.px(1)
	a := 3*(q0-p0) + uiWpSclip1(p1-q1)
	a1 := uiWpSclip2((a + 4) >> 3)
	a2 := uiWpSclip2((a + 3) >> 3)
	e.put(-1, p0+a2)
	e.put(0, q0-a1)
}

func (e uiWpEdge) filter4() {
	p1, p0, q0, q1 := e.px(-2), e.px(-1), e.px(0), e.px(1)
	a := 3 * (q0 - p0)
	a1 := uiWpSclip2((a + 4) >> 3)
	a2 := uiWpSclip2((a + 3) >> 3)
	a3 := (a1 + 1) >> 1
	e.put(-2, p1+a3)
	e.put(-1, p0+a2)
	e.put(0, q0-a1)
	e.put(1, q1-a3)
}

func (e uiWpEdge) filter6() {
	p2, p1, p0 := e.px(-3), e.px(-2), e.px(-1)
	q0, q1, q2 := e.px(0), e.px(1), e.px(2)
	a := uiWpSclip1(3*(q0-p0) + uiWpSclip1(p1-q1))
	a1 := (27*a + 63) >> 7
	a2 := (18*a + 63) >> 7
	a3 := (9*a + 63) >> 7
	e.put(-3, p2+a3)
	e.put(-2, p1+a2)
	e.put(-1, p0+a1)
	e.put(0, q0-a1)
	e.put(1, q1-a2)
	e.put(2, q2-a3)
}

func uiWpLoop(p []uint8, at, step, along, count, t, it, hev int, macro, simple bool) {
	t2 := 2*t + 1
	for i := 0; i < count; i++ {
		e := uiWpEdge{p, at + i*along, step}
		if simple {
			if e.needs(t2) {
				e.filter2()
			}
			continue
		}
		if !e.needs2(t2, it) {
			continue
		}
		switch {
		case e.hev(hev):
			e.filter2()
		case macro:
			e.filter6()
		default:
			e.filter4()
		}
	}
}

func (d *uiWpVP8) filter() {
	if d.level == 0 {
		return
	}
	for mby := 0; mby < d.mbh; mby++ {
		for mbx := 0; mbx < d.mbw; mbx++ {
			f := d.info[mby*d.mbw+mbx]
			if f.limit == 0 {
				continue
			}
			ya := mby*16*d.ys + mbx*16
			ua := mby*8*d.uvs + mbx*8
			edge, in := f.limit+4, f.limit
			if mbx > 0 {
				uiWpLoop(d.y, ya, 1, d.ys, 16, edge, f.inner, f.hev, true, d.simple)
				if !d.simple {
					uiWpLoop(d.u, ua, 1, d.uvs, 8, edge, f.inner, f.hev, true, false)
					uiWpLoop(d.v, ua, 1, d.uvs, 8, edge, f.inner, f.hev, true, false)
				}
			}
			if f.insides {
				for k := 4; k < 16; k += 4 {
					uiWpLoop(d.y, ya+k, 1, d.ys, 16, in, f.inner, f.hev, false, d.simple)
				}
				if !d.simple {
					uiWpLoop(d.u, ua+4, 1, d.uvs, 8, in, f.inner, f.hev, false, false)
					uiWpLoop(d.v, ua+4, 1, d.uvs, 8, in, f.inner, f.hev, false, false)
				}
			}
			if mby > 0 {
				uiWpLoop(d.y, ya, d.ys, 1, 16, edge, f.inner, f.hev, true, d.simple)
				if !d.simple {
					uiWpLoop(d.u, ua, d.uvs, 1, 8, edge, f.inner, f.hev, true, false)
					uiWpLoop(d.v, ua, d.uvs, 1, 8, edge, f.inner, f.hev, true, false)
				}
			}
			if f.insides {
				for k := 4; k < 16; k += 4 {
					uiWpLoop(d.y, ya+k*d.ys, d.ys, 1, 16, in, f.inner, f.hev, false, d.simple)
				}
				if !d.simple {
					uiWpLoop(d.u, ua+4*d.uvs, d.uvs, 1, 8, in, f.inner, f.hev, false, false)
					uiWpLoop(d.v, ua+4*d.uvs, d.uvs, 1, 8, in, f.inner, f.hev, false, false)
				}
			}
		}
	}
}

func uiWpYuv(y, u, v int) (uint8, uint8, uint8) {
	hi := func(v, c int) int { return (v * c) >> 8 }
	clip := func(v int) uint8 {
		if v&^16383 == 0 {
			return uint8(v >> 6)
		}
		if v < 0 {
			return 0
		}
		return 255
	}
	yy := hi(y, 19077)
	return clip(yy + hi(v, 26149) - 14234), clip(yy - hi(u, 6419) - hi(v, 13320) + 8708), clip(yy + hi(u, 33050) - 17685)
}

func (d *uiWpVP8) row(dst []uint8, yRow, topUV, curUV int, near bool) {
	w := d.w
	yp := d.y[yRow*d.ys:]
	tu, tv := d.u[topUV*d.uvs:], d.v[topUV*d.uvs:]
	cu, cv := d.u[curUV*d.uvs:], d.v[curUV*d.uvs:]
	put := func(x, u, v int) {
		dst[x*4], dst[x*4+1], dst[x*4+2] = uiWpYuv(int(yp[x]), u, v)
		dst[x*4+3] = 255
	}
	edge := func(tl, l int) int {
		if near {
			return (3*tl + l + 2) >> 2
		}
		return (3*l + tl + 2) >> 2
	}
	tlU, tlV, lU, lV := int(tu[0]), int(tv[0]), int(cu[0]), int(cv[0])
	put(0, edge(tlU, lU), edge(tlV, lV))
	for x := 1; x <= (w-1)>>1; x++ {
		tU, tV, U, V := int(tu[x]), int(tv[x]), int(cu[x]), int(cv[x])
		avgU, avgV := tlU+tU+lU+U+8, tlV+tV+lV+V+8
		d12U, d12V := (avgU+2*(tU+lU))>>3, (avgV+2*(tV+lV))>>3
		d03U, d03V := (avgU+2*(tlU+U))>>3, (avgV+2*(tlV+V))>>3
		if near {
			put(2*x-1, (d12U+tlU)>>1, (d12V+tlV)>>1)
			put(2*x, (d03U+tU)>>1, (d03V+tV)>>1)
		} else {
			put(2*x-1, (d03U+lU)>>1, (d03V+lV)>>1)
			put(2*x, (d12U+U)>>1, (d12V+V)>>1)
		}
		tlU, tlV, lU, lV = tU, tV, U, V
	}
	if w&1 == 0 {
		put(w-1, edge(tlU, lU), edge(tlV, lV))
	}
}

func (d *uiWpVP8) rgba(out []uint8, stride int) {
	d.row(out, 0, 0, 0, true)
	for y := 1; y < d.h; y += 2 {
		k := (y + 1) / 2
		if y+1 >= d.h {
			d.row(out[y*stride:], y, k-1, k-1, true)
			break
		}
		d.row(out[y*stride:], y, k-1, k, true)
		d.row(out[(y+1)*stride:], y+1, k-1, k, false)
	}
}
