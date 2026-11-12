// Variable fonts, set at the weight and the optical size asked for.

//go:build linux && !android

package hive

import (
	"math"
)

type uixAxis struct {
	tag            string
	min, def, max  float64
	mapFrom, mapTo []float64
}

func uixF2(d []byte, at int) float64 { return float64(uixI16(d, at)) / 16384 }

func uixFixed(d []byte, at int) float64 { return float64(int32(uint32(uixU32(d, at)))) / 65536 }

func uixByte(d []byte, at int) int {
	if at < 0 || at >= len(d) {
		return 0
	}
	return int(d[at])
}

func (f *uixFace) readAxes(fvar, avar int) {
	d := f.data
	at := fvar + uixU16(d, fvar+4)
	count, size := uixU16(d, fvar+8), uixU16(d, fvar+10)
	if size < 20 || count > 64 {
		return
	}
	for i := 0; i < count; i++ {
		rec := at + i*size
		if rec+20 > len(d) {
			return
		}
		a := uixAxis{tag: string(d[rec : rec+4]), min: uixFixed(d, rec+4), def: uixFixed(d, rec+8), max: uixFixed(d, rec+12)}
		if a.min > a.def || a.def > a.max {
			return
		}
		f.axes = append(f.axes, a)
	}
	if avar == 0 || uixU16(d, avar+6) != len(f.axes) {
		return
	}
	at = avar + 8
	for i := range f.axes {
		pairs := uixU16(d, at)
		at += 2
		for k := 0; k < pairs; k++ {
			f.axes[i].mapFrom = append(f.axes[i].mapFrom, uixF2(d, at))
			f.axes[i].mapTo = append(f.axes[i].mapTo, uixF2(d, at+2))
			at += 4
		}
	}
}

func (f *uixFace) axis(tag string) (uixAxis, bool) {
	for _, a := range f.axes {
		if a.tag == tag {
			return a, true
		}
	}
	return uixAxis{}, false
}

func (a uixAxis) normalize(v float64) float64 {
	v = uiClamp(v, a.min, a.max)
	n := 0.0
	switch {
	case v < a.def && a.def > a.min:
		n = (v - a.def) / (a.def - a.min)
	case v > a.def && a.max > a.def:
		n = (v - a.def) / (a.max - a.def)
	}
	if len(a.mapFrom) >= 2 {
		for i := 1; i < len(a.mapFrom); i++ {
			if n <= a.mapFrom[i] {
				lo, hi := a.mapFrom[i-1], a.mapFrom[i]
				if hi > lo {
					n = a.mapTo[i-1] + (n-lo)*(a.mapTo[i]-a.mapTo[i-1])/(hi-lo)
				} else {
					n = a.mapTo[i]
				}
				break
			}
		}
	}
	return math.Round(n*16384) / 16384
}

func (f *uixFace) instance(weight, opsz float64) *uixFace {
	base := f
	if f.base != nil {
		base = f.base
	}
	if len(base.axes) == 0 {
		return base
	}
	if a, ok := base.axis("wght"); !ok {
		weight = 0
	} else if weight > 0 {
		weight = uiClamp(weight, a.min, a.max)
	}
	if a, ok := base.axis("opsz"); !ok {
		opsz = 0
	} else if opsz > 0 {
		opsz = uiClamp(opsz, a.min, a.max)
	}
	key := [2]int{int(math.Round(weight)), int(math.Round(opsz * 2))}
	if inst, ok := base.instances[key]; ok {
		return inst
	}
	inst := *base
	inst.base = base
	inst.instances = nil
	inst.advances = map[uint16]float64{}
	inst.scalars = map[int][]float64{}
	inst.coords = make([]float64, len(base.axes))
	for i, a := range base.axes {
		switch {
		case a.tag == "wght" && weight > 0:
			inst.coords[i] = a.normalize(weight)
			inst.weight = int(math.Round(uiClamp(weight, a.min, a.max)))
		case a.tag == "opsz" && opsz > 0:
			inst.coords[i] = a.normalize(opsz)
		default:
			inst.coords[i] = a.normalize(a.def)
		}
	}
	if base.mvar != 0 {
		inst.applyMetrics()
	}
	if base.instances == nil || len(base.instances) > 64 {
		base.instances = map[[2]int]*uixFace{}
	}
	base.instances[key] = &inst
	return &inst
}

func (f *uixFace) varied() bool {
	for _, c := range f.coords {
		if c != 0 {
			return true
		}
	}
	return false
}

func (f *uixFace) regionScalar(d []byte, region int, axes int) float64 {
	scalar := 1.0
	for i := 0; i < axes; i++ {
		start, peak, end := uixF2(d, region+6*i), uixF2(d, region+6*i+2), uixF2(d, region+6*i+4)
		if peak == 0 || start > peak || peak > end || start < 0 && end > 0 {
			continue
		}
		v := 0.0
		if i < len(f.coords) {
			v = f.coords[i]
		}
		switch {
		case v == peak:
		case v <= start || v >= end:
			return 0
		case v < peak:
			scalar *= (v - start) / (peak - start)
		default:
			scalar *= (end - v) / (end - peak)
		}
	}
	return scalar
}

func (f *uixFace) storeScalars(store, outer int) []float64 {
	d := f.data
	if uixU16(d, store) != 1 || outer >= uixU16(d, store+6) {
		return nil
	}
	regions := store + uixU32(d, store+2)
	axes, regionCount := uixU16(d, regions), uixU16(d, regions+2)
	data := store + uixU32(d, store+8+4*outer)
	count := uixU16(d, data+4)
	out := make([]float64, count)
	for i := range out {
		r := uixU16(d, data+6+2*i)
		if r < regionCount {
			out[i] = f.regionScalar(d, regions+4+r*axes*6, axes)
		}
	}
	return out
}

func (f *uixFace) storeDelta(store, outer, inner int) float64 {
	d := f.data
	if store == 0 || uixU16(d, store) != 1 || outer >= uixU16(d, store+6) {
		return 0
	}
	data := store + uixU32(d, store+8+4*outer)
	items, words, count := uixU16(d, data), uixU16(d, data+2), uixU16(d, data+4)
	if inner >= items {
		return 0
	}
	long := words&0x8000 != 0
	words &= 0x7fff
	wide, narrow := 2, 1
	if long {
		wide, narrow = 4, 2
	}
	rowSize := words*wide + (count-words)*narrow
	row := data + 6 + 2*count + inner*rowSize
	key := store*65536 + outer
	scalars, ok := f.scalars[key]
	if !ok {
		scalars = f.storeScalars(store, outer)
		f.scalars[key] = scalars
	}
	total := 0.0
	at := row
	for i := 0; i < count && i < len(scalars); i++ {
		var v int
		switch {
		case i < words && long:
			v = int(int32(uint32(uixU32(d, at))))
			at += 4
		case i < words || long:
			v = uixI16(d, at)
			at += 2
		default:
			v = int(int8(uixByte(d, at)))
			at++
		}
		total += float64(v) * scalars[i]
	}
	return total
}

func uixDeltaSet(d []byte, mapAt int, g int) (int, int) {
	if mapAt == 0 {
		return 0, g
	}
	format, entry := uixByte(d, mapAt), uixByte(d, mapAt+1)
	count, at := uixU16(d, mapAt+2), mapAt+4
	if format == 1 {
		count, at = uixU32(d, mapAt+2), mapAt+6
	}
	if count == 0 {
		return 0, g
	}
	g = min(g, count-1)
	size := (entry>>4)&3 + 1
	bits := entry&15 + 1
	v := 0
	for k := 0; k < size; k++ {
		v = v<<8 | uixByte(d, at+g*size+k)
	}
	return v >> bits, v & (1<<bits - 1)
}

func (f *uixFace) applyMetrics() {
	d := f.data
	size, count := uixU16(d, f.mvar+6), uixU16(d, f.mvar+8)
	store := f.mvar + uixU16(d, f.mvar+10)
	if uixU16(d, f.mvar+10) == 0 || size < 8 {
		return
	}
	for i := 0; i < count; i++ {
		rec := f.mvar + 12 + i*size
		if rec+8 > len(d) {
			return
		}
		delta := f.storeDelta(store, uixU16(d, rec+4), uixU16(d, rec+6))
		switch string(d[rec : rec+4]) {
		case f.ascTag:
			f.asc += delta
		case f.descTag:
			if f.descTag == "hcld" {
				f.desc -= delta
			} else {
				f.desc += delta
			}
		}
	}
}

func (f *uixFace) varAdvance(g uint16, base float64) float64 {
	if !f.varied() {
		return base
	}
	if v, ok := f.advances[g]; ok {
		return v
	}
	v := base
	switch {
	case f.hvar != 0:
		d := f.data
		outer, inner := uixDeltaSet(d, uixOffset(d, f.hvar, 8), int(g))
		v += f.storeDelta(f.hvar+uixU32(d, f.hvar+4), outer, inner)
	case f.gvar != 0 && f.glyf != 0:
		if n := f.pointCount(g); n >= 0 {
			dx, _ := f.gvarDeltas(g, n+4, nil, nil, nil)
			if dx != nil {
				v += dx[n+1] - dx[n]
			}
		}
	}
	v = math.Round(v)
	if len(f.advances) > 1<<14 {
		f.advances = map[uint16]float64{}
	}
	f.advances[g] = v
	return v
}

func uixOffset(d []byte, table, at int) int {
	if o := uixU32(d, table+at); o != 0 {
		return table + o
	}
	return 0
}

func (f *uixFace) pointCount(g uint16) int {
	start, end := f.glyphRange(g)
	if end-start < 10 {
		return 0
	}
	d := f.data[start:end]
	contours := uixI16(d, 0)
	if contours >= 0 {
		if contours == 0 {
			return 0
		}
		return uixU16(d, 10+2*(contours-1)) + 1
	}
	n := 0
	for at := 10; at+4 <= len(d); n++ {
		flags := uixU16(d, at)
		at += 4
		if flags&1 != 0 {
			at += 4
		} else {
			at += 2
		}
		switch {
		case flags&8 != 0:
			at += 2
		case flags&0x40 != 0:
			at += 4
		case flags&0x80 != 0:
			at += 8
		}
		if flags&0x20 == 0 {
			return n + 1
		}
	}
	return n
}

func (f *uixFace) tupleScalar(peak, start, end []float64) float64 {
	scalar := 1.0
	for i, p := range peak {
		if p == 0 {
			continue
		}
		v := 0.0
		if i < len(f.coords) {
			v = f.coords[i]
		}
		if v == p {
			continue
		}
		if start != nil {
			s, e := start[i], end[i]
			if s > p || p > e || s < 0 && e > 0 {
				continue
			}
			if v < s || v > e {
				return 0
			}
			if v < p {
				scalar *= (v - s) / (p - s)
			} else {
				scalar *= (e - v) / (e - p)
			}
			continue
		}
		if v == 0 || v < math.Min(0, p) || v > math.Max(0, p) {
			return 0
		}
		scalar *= v / p
	}
	return scalar
}

func uixPackedPoints(d []byte, at, n int) ([]int, int) {
	count := uixByte(d, at)
	at++
	if count == 0 {
		return nil, at
	}
	if count&0x80 != 0 {
		count = (count&0x7f)<<8 | uixByte(d, at)
		at++
	}
	points := make([]int, 0, count)
	v := 0
	for len(points) < count && at < len(d) {
		control := uixByte(d, at)
		at++
		run := control&0x7f + 1
		for k := 0; k < run && len(points) < count; k++ {
			if control&0x80 != 0 {
				v += uixU16(d, at)
				at += 2
			} else {
				v += uixByte(d, at)
				at++
			}
			points = append(points, v)
		}
	}
	return points, at
}

func uixPackedDeltas(d []byte, at, count int) ([]float64, int) {
	out := make([]float64, count)
	for i := 0; i < count && at < len(d); {
		control := uixByte(d, at)
		at++
		run := control&0x3f + 1
		for k := 0; k < run && i < count; k, i = k+1, i+1 {
			switch {
			case control&0x80 != 0:
			case control&0x40 != 0:
				out[i] = float64(uixI16(d, at))
				at += 2
			default:
				out[i] = float64(int8(uixByte(d, at)))
				at++
			}
		}
	}
	return out, at
}

func (f *uixFace) gvarDeltas(g uint16, n int, xs, ys []float64, ends []int) ([]float64, []float64) {
	d, gv := f.data, f.gvar
	axes, shared := uixU16(d, gv+4), uixU16(d, gv+6)
	sharedAt := gv + uixU32(d, gv+8)
	glyphs, flags := uixU16(d, gv+12), uixU16(d, gv+14)
	array := gv + uixU32(d, gv+16)
	if int(g) >= glyphs || axes != len(f.coords) {
		return nil, nil
	}
	var start, end int
	if flags&1 != 0 {
		start, end = uixU32(d, gv+20+4*int(g)), uixU32(d, gv+24+4*int(g))
	} else {
		start, end = 2*uixU16(d, gv+20+2*int(g)), 2*uixU16(d, gv+22+2*int(g))
	}
	if end <= start || array+end > len(d) {
		return nil, nil
	}
	gd := d[array+start : array+end]
	header := uixU16(gd, 0)
	count := header & 0x0fff
	data := uixU16(gd, 2)
	var common []int
	if header&0x8000 != 0 {
		common, data = uixPackedPoints(gd, data, n)
	}
	dx, dy := make([]float64, n), make([]float64, n)
	at := 4
	for t := 0; t < count; t++ {
		size, index := uixU16(gd, at), uixU16(gd, at+2)
		at += 4
		read := func() []float64 {
			v := make([]float64, axes)
			for i := range v {
				v[i] = uixF2(gd, at+2*i)
			}
			at += 2 * axes
			return v
		}
		var peak, lo, hi []float64
		if index&0x8000 != 0 {
			peak = read()
		} else {
			if index&0x0fff >= shared {
				data += size
				continue
			}
			peak = make([]float64, axes)
			for i := range peak {
				peak[i] = uixF2(d, sharedAt+(index&0x0fff)*axes*2+2*i)
			}
		}
		if index&0x4000 != 0 {
			lo, hi = read(), read()
		}
		chunk := data
		data += size
		scalar := f.tupleScalar(peak, lo, hi)
		if scalar == 0 {
			continue
		}
		points := common
		if index&0x2000 != 0 {
			points, chunk = uixPackedPoints(gd, chunk, n)
		}
		touched := n
		if points != nil {
			touched = len(points)
		}
		xd, next := uixPackedDeltas(gd, chunk, touched)
		yd, _ := uixPackedDeltas(gd, next, touched)
		if points == nil {
			for i := 0; i < n; i++ {
				dx[i] += scalar * xd[i]
				dy[i] += scalar * yd[i]
			}
			continue
		}
		tx, ty := make([]float64, n), make([]float64, n)
		mark := make([]bool, n)
		for i, p := range points {
			if p < n {
				tx[p], ty[p], mark[p] = xd[i], yd[i], true
			}
		}
		if ends != nil {
			uixInfer(tx, xs, mark, ends)
			uixInfer(ty, ys, mark, ends)
		}
		for i := 0; i < n; i++ {
			dx[i] += scalar * tx[i]
			dy[i] += scalar * ty[i]
		}
	}
	return dx, dy
}

func uixInfer(delta, orig []float64, touched []bool, ends []int) {
	first := 0
	for _, last := range ends {
		if last >= len(orig) || last < first {
			return
		}
		var marked []int
		for i := first; i <= last; i++ {
			if touched[i] {
				marked = append(marked, i)
			}
		}
		switch len(marked) {
		case 0:
		case 1:
			for i := first; i <= last; i++ {
				delta[i] = delta[marked[0]]
			}
		default:
			for k, a := range marked {
				b := marked[(k+1)%len(marked)]
				for i := a + 1; ; i++ {
					if i > last {
						i = first
					}
					if i == b {
						break
					}
					delta[i] = uixBetween(orig[i], orig[a], orig[b], delta[a], delta[b])
				}
			}
		}
		first = last + 1
	}
}

func uixBetween(p, c1, c2, d1, d2 float64) float64 {
	if c1 > c2 {
		c1, c2, d1, d2 = c2, c1, d2, d1
	}
	switch {
	case c1 == c2:
		if d1 == d2 {
			return d1
		}
		return 0
	case p <= c1:
		return d1
	case p >= c2:
		return d2
	}
	return d1 + (p-c1)*(d2-d1)/(c2-c1)
}
