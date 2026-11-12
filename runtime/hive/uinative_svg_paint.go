// What an SVG draws: paths, strokes, gradients, clips and groups.
package hive

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

type uiSvgStyle struct {
	fill, stroke     uiSvgPaint
	fillOp, strokeOp float64
	opacity          float64
	evenOdd, clipOdd bool
	width            string
	cap, join        string
	miter            float64
	dash, dashOffset string
	color            uiSvgColor
	visible, display bool
	stopColor        uiSvgColor
	stopOp           float64
	clip             string
	transform        string
}

func uiSvgInitial() uiSvgStyle {
	return uiSvgStyle{fill: uiSvgPaint{color: uiSvgColor{0, 0, 0, 1}}, stroke: uiSvgPaint{none: true},
		fillOp: 1, strokeOp: 1, opacity: 1, width: "1", cap: "butt", join: "miter", miter: 4, dash: "none",
		dashOffset: "0", color: uiSvgColor{0, 0, 0, 1}, visible: true, display: true, stopColor: uiSvgColor{0, 0, 0, 1}, stopOp: 1}
}

type uiSvgRender struct {
	doc   *uiSvgDoc
	w, h  int
	vp    [][2]float64
	using map[*uiSvgNode]bool
	deep  int
	ras   uiRaster
	cover []uint8
}

func uiSvgUnit(s string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "%")), 64)
	if err != nil {
		return math.NaN()
	}
	if strings.HasSuffix(strings.TrimSpace(s), "%") {
		v /= 100
	}
	return v
}

func (r *uiSvgRender) style(n *uiSvgNode, parent uiSvgStyle) uiSvgStyle {
	st := parent
	st.opacity, st.clip, st.display, st.transform = 1, "", true, ""
	st.stopColor, st.stopOp = uiSvgColor{0, 0, 0, 1}, 1
	if c, ok := n.decl["color"]; ok && c != "inherit" {
		if v, ok := uiSvgParseColor(c, parent.color); ok {
			st.color = v
		}
	}
	for k, v := range n.decl {
		if v == "inherit" {
			continue
		}
		switch k {
		case "fill", "stroke":
			p, ok := uiSvgParsePaint(v, st.color)
			if !ok {
				continue
			}
			if k == "fill" {
				st.fill = p
			} else {
				st.stroke = p
			}
		case "fill-opacity", "stroke-opacity", "opacity", "stop-opacity":
			f := uiSvgUnit(v)
			if math.IsNaN(f) {
				continue
			}
			f = uiClamp(f, 0, 1)
			switch k {
			case "fill-opacity":
				st.fillOp = f
			case "stroke-opacity":
				st.strokeOp = f
			case "opacity":
				st.opacity = f
			default:
				st.stopOp = f
			}
		case "fill-rule":
			st.evenOdd = v == "evenodd"
		case "clip-rule":
			st.clipOdd = v == "evenodd"
		case "stroke-width":
			st.width = v
		case "stroke-linecap":
			st.cap = v
		case "stroke-linejoin":
			st.join = v
		case "stroke-miterlimit":
			if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 1 {
				st.miter = f
			}
		case "stroke-dasharray":
			st.dash = v
		case "stroke-dashoffset":
			st.dashOffset = v
		case "display":
			st.display = v != "none"
		case "visibility":
			st.visible = v == "visible"
		case "stop-color":
			if c, ok := uiSvgParseColor(v, st.color); ok {
				st.stopColor = c
			}
		case "clip-path":
			st.clip = v
		case "transform":
			st.transform = v
		}
	}
	return st
}

func (r *uiSvgRender) viewport() [2]float64 { return r.vp[len(r.vp)-1] }

func (r *uiSvgRender) length(n *uiSvgNode, key string, axis int) float64 {
	vp := r.viewport()
	of := math.Sqrt((vp[0]*vp[0] + vp[1]*vp[1]) / 2)
	if axis < 2 {
		of = vp[axis]
	}
	v, _ := uiSvgLength(n.attrs[key], of)
	return v
}

func (r *uiSvgRender) lengthOr(n *uiSvgNode, key string, axis int, def string) float64 {
	if _, ok := n.attrs[key]; !ok {
		vp := r.viewport()
		of := math.Sqrt((vp[0]*vp[0] + vp[1]*vp[1]) / 2)
		if axis < 2 {
			of = vp[axis]
		}
		v, _ := uiSvgLength(def, of)
		return v
	}
	return r.length(n, key, axis)
}

func (r *uiSvgRender) own(n *uiSvgNode, ctm uiSvgM, st uiSvgStyle) uiSvgM {
	t := n.attrs["transform"]
	if st.transform != "" {
		t = st.transform
	}
	if t == "" {
		return ctm
	}
	return ctm.mul(uiSvgTransform(t))
}

func (r *uiSvgRender) children(n *uiSvgNode, ctm uiSvgM, st uiSvgStyle, dst []uint8, depth int) {
	for _, k := range n.kids {
		r.node(k, ctm, st, dst, depth+1)
		if n.tag == "switch" {
			return
		}
	}
}

func (r *uiSvgRender) node(n *uiSvgNode, ctm uiSvgM, parent uiSvgStyle, dst []uint8, depth int) {
	if depth > 64 {
		return
	}
	switch n.tag {
	case "g", "a", "switch", "svg", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
	default:
		return
	}
	st := r.style(n, parent)
	if !st.display {
		return
	}
	m := r.own(n, ctm, st)
	target := dst
	var layer []uint8
	clip := r.clipMask(st.clip, n, m)
	if st.opacity <= 0 {
		return
	}
	if (st.opacity < 1 || clip != nil) && r.deep < 8 {
		layer = make([]uint8, len(dst))
		target = layer
		r.deep++
		defer func() { r.deep-- }()
	}
	switch n.tag {
	case "g", "a", "switch":
		r.children(n, m, st, target, depth)
	case "svg":
		r.inner(n, n, m, st, target, depth, r.length(n, "x", 0), r.length(n, "y", 1),
			r.lengthOr(n, "width", 0, "100%"), r.lengthOr(n, "height", 1, "100%"))
	case "use":
		r.use(n, m, st, target, depth)
	default:
		r.shape(n, m, st, target)
	}
	if layer != nil {
		r.merge(dst, layer, st.opacity, clip)
	}
}

func (r *uiSvgRender) inner(n, content *uiSvgNode, ctm uiSvgM, st uiSvgStyle, dst []uint8, depth int, x, y, w, h float64) {
	if w <= 0 || h <= 0 {
		return
	}
	m := ctm.mul(uiSvgM{1, 0, 0, 1, x, y})
	size := [2]float64{w, h}
	if box := uiSvgViewBox(content.attrs["viewBox"]); box != nil {
		m = ctm.mul(uiSvgFit(box, content.attrs["preserveAspectRatio"], x, y, w, h))
		size = [2]float64{box[2], box[3]}
	}
	layer := make([]uint8, len(dst))
	r.vp = append(r.vp, size)
	r.children(content, m, st, layer, depth)
	r.vp = r.vp[:len(r.vp)-1]
	if strings.Contains(content.decl["overflow"]+content.attrs["overflow"], "visible") {
		r.merge(dst, layer, 1, nil)
		return
	}
	mask := r.cover[:0]
	r.fillMask(&mask, [][]float64{r.box(ctm, x, y, w, h)}, false)
	r.merge(dst, layer, 1, mask)
}

func (r *uiSvgRender) box(m uiSvgM, x, y, w, h float64) []float64 {
	var out []float64
	for _, p := range [4][2]float64{{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}} {
		a, b := m.apply(p[0], p[1])
		out = append(out, a, b)
	}
	return out
}

func (r *uiSvgRender) use(n *uiSvgNode, ctm uiSvgM, st uiSvgStyle, dst []uint8, depth int) {
	ref := strings.TrimPrefix(strings.TrimSpace(n.attrs["href"]), "#")
	target := r.doc.ids[ref]
	if target == nil || r.using[target] || target == n {
		return
	}
	for a := n.parent; a != nil; a = a.parent {
		if a == target {
			return
		}
	}
	if r.using == nil {
		r.using = map[*uiSvgNode]bool{}
	}
	r.using[target] = true
	defer delete(r.using, target)
	x, y := r.length(n, "x", 0), r.length(n, "y", 1)
	switch target.tag {
	case "symbol", "svg":
		ts := r.style(target, st)
		if !ts.display {
			return
		}
		w := r.lengthOr(n, "width", 0, "100%")
		h := r.lengthOr(n, "height", 1, "100%")
		if _, ok := n.attrs["width"]; !ok && target.tag == "svg" {
			w = r.lengthOr(target, "width", 0, "100%")
		}
		if _, ok := n.attrs["height"]; !ok && target.tag == "svg" {
			h = r.lengthOr(target, "height", 1, "100%")
		}
		r.inner(target, target, ctm, ts, dst, depth+1, x, y, w, h)
	default:
		r.node(target, ctm.mul(uiSvgM{1, 0, 0, 1, x, y}), st, dst, depth+1)
	}
}

type uiSvgSub struct {
	pts    []float64
	closed bool
}

type uiSvgPath struct {
	subs []uiSvgSub
	tol  float64
}

func (p *uiSvgPath) moveTo(x, y float64) {
	p.subs = append(p.subs, uiSvgSub{pts: []float64{x, y}})
}

func (p *uiSvgPath) cur() (float64, float64) {
	s := &p.subs[len(p.subs)-1]
	return s.pts[len(s.pts)-2], s.pts[len(s.pts)-1]
}

func (p *uiSvgPath) lineTo(x, y float64) {
	s := &p.subs[len(p.subs)-1]
	s.pts = append(s.pts, x, y)
}

func (p *uiSvgPath) cubicTo(c1x, c1y, c2x, c2y, x, y float64) {
	x0, y0 := p.cur()
	dd := math.Max(math.Hypot(x0-2*c1x+c2x, y0-2*c1y+c2y), math.Hypot(c1x-2*c2x+x, c1y-2*c2y+y))
	n := int(math.Ceil(math.Sqrt(dd * 0.75 / p.tol)))
	n = min(max(n, 1), 500)
	for i := 1; i <= n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		p.lineTo(u*u*u*x0+3*u*u*t*c1x+3*u*t*t*c2x+t*t*t*x, u*u*u*y0+3*u*u*t*c1y+3*u*t*t*c2y+t*t*t*y)
	}
}

func (p *uiSvgPath) close() {
	s := &p.subs[len(p.subs)-1]
	s.closed = true
}

func (p *uiSvgPath) arcTo(rx, ry, phi float64, large, sweep bool, x, y float64) {
	x0, y0 := p.cur()
	if x0 == x && y0 == y {
		return
	}
	rx, ry = math.Abs(rx), math.Abs(ry)
	if rx == 0 || ry == 0 {
		p.lineTo(x, y)
		return
	}
	phi *= math.Pi / 180
	cs, sn := math.Cos(phi), math.Sin(phi)
	dx, dy := (x0-x)/2, (y0-y)/2
	x1 := cs*dx + sn*dy
	y1 := -sn*dx + cs*dy
	if l := x1*x1/(rx*rx) + y1*y1/(ry*ry); l > 1 {
		rx, ry = rx*math.Sqrt(l), ry*math.Sqrt(l)
	}
	num := rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1
	den := rx*rx*y1*y1 + ry*ry*x1*x1
	f := math.Sqrt(math.Max(0, num/den))
	if large == sweep {
		f = -f
	}
	cx1, cy1 := f*rx*y1/ry, -f*ry*x1/rx
	cx := cs*cx1 - sn*cy1 + (x0+x)/2
	cy := sn*cx1 + cs*cy1 + (y0+y)/2
	angle := func(ux, uy, vx, vy float64) float64 {
		a := math.Atan2(ux*vy-uy*vx, ux*vx+uy*vy)
		return a
	}
	t1 := angle(1, 0, (x1-cx1)/rx, (y1-cy1)/ry)
	dt := angle((x1-cx1)/rx, (y1-cy1)/ry, (-x1-cx1)/rx, (-y1-cy1)/ry)
	if !sweep && dt > 0 {
		dt -= 2 * math.Pi
	} else if sweep && dt < 0 {
		dt += 2 * math.Pi
	}
	segs := int(math.Ceil(math.Abs(dt) / (math.Pi / 2)))
	step := dt / float64(max(segs, 1))
	k := 4.0 / 3 * math.Tan(step/4)
	at := func(t float64) (float64, float64, float64, float64) {
		ex, ey := rx*math.Cos(t), ry*math.Sin(t)
		tx, ty := -rx*math.Sin(t), ry*math.Cos(t)
		return cs*ex - sn*ey + cx, sn*ex + cs*ey + cy, cs*tx - sn*ty, sn*tx + cs*ty
	}
	for i := 0; i < segs; i++ {
		a, b := t1+float64(i)*step, t1+float64(i+1)*step
		ax, ay, adx, ady := at(a)
		bx, by, bdx, bdy := at(b)
		if i == segs-1 {
			bx, by = x, y
		}
		p.cubicTo(ax+k*adx, ay+k*ady, bx-k*bdx, by-k*bdy, bx, by)
	}
}

type uiSvgScanner struct {
	s  string
	at int
}

func (p *uiSvgScanner) skip() {
	for p.at < len(p.s) && (p.s[p.at] == ' ' || p.s[p.at] == ',' || p.s[p.at] == '\t' || p.s[p.at] == '\n' || p.s[p.at] == '\r') {
		p.at++
	}
}

func (p *uiSvgScanner) number() (float64, bool) {
	p.skip()
	start := p.at
	i := p.at
	if i < len(p.s) && (p.s[i] == '+' || p.s[i] == '-') {
		i++
	}
	digits := false
	for i < len(p.s) && p.s[i] >= '0' && p.s[i] <= '9' {
		i++
		digits = true
	}
	if i < len(p.s) && p.s[i] == '.' {
		i++
		for i < len(p.s) && p.s[i] >= '0' && p.s[i] <= '9' {
			i++
			digits = true
		}
	}
	if !digits {
		return 0, false
	}
	if i < len(p.s) && (p.s[i] == 'e' || p.s[i] == 'E') {
		j := i + 1
		if j < len(p.s) && (p.s[j] == '+' || p.s[j] == '-') {
			j++
		}
		if j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' {
			for j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' {
				j++
			}
			i = j
		}
	}
	v, err := strconv.ParseFloat(p.s[start:i], 64)
	if err != nil || math.IsInf(v, 0) {
		return 0, false
	}
	p.at = i
	return v, true
}

func (p *uiSvgScanner) flag() (bool, bool) {
	p.skip()
	if p.at < len(p.s) && (p.s[p.at] == '0' || p.s[p.at] == '1') {
		p.at++
		return p.s[p.at-1] == '1', true
	}
	return false, false
}

func uiSvgParsePath(d string, tol float64) *uiSvgPath {
	p := &uiSvgPath{tol: tol}
	sc := &uiSvgScanner{s: d}
	var cmd byte
	var sx, sy, cx, cy, lastX, lastY float64
	var last byte
	for {
		sc.skip()
		if sc.at >= len(sc.s) {
			break
		}
		c := sc.s[sc.at]
		if strings.IndexByte("MmLlHhVvCcSsQqTtAaZz", c) >= 0 {
			cmd = c
			sc.at++
		} else if cmd == 0 {
			break
		}
		if len(p.subs) == 0 && cmd != 'M' && cmd != 'm' {
			break
		}
		rel := cmd >= 'a'
		ox, oy := 0.0, 0.0
		if rel {
			ox, oy = cx, cy
		}
		nums := func(n int) ([]float64, bool) {
			out := make([]float64, n)
			for i := range out {
				v, ok := sc.number()
				if !ok {
					return nil, false
				}
				out[i] = v
			}
			return out, true
		}
		upper := cmd &^ 0x20
		ok := true
		switch upper {
		case 'Z':
			p.close()
			cx, cy = sx, sy
			cmd = 0
			p.moveTo(cx, cy)
			last = 'Z'
			continue
		case 'M':
			var v []float64
			if v, ok = nums(2); ok {
				cx, cy = ox+v[0], oy+v[1]
				sx, sy = cx, cy
				p.dropLone()
				p.moveTo(cx, cy)
				if cmd == 'm' {
					cmd = 'l'
				} else {
					cmd = 'L'
				}
			}
		case 'L':
			var v []float64
			if v, ok = nums(2); ok {
				cx, cy = ox+v[0], oy+v[1]
				p.lineTo(cx, cy)
			}
		case 'H':
			var v []float64
			if v, ok = nums(1); ok {
				cx = ox + v[0]
				p.lineTo(cx, cy)
			}
		case 'V':
			var v []float64
			if v, ok = nums(1); ok {
				cy = oy + v[0]
				p.lineTo(cx, cy)
			}
		case 'C', 'S':
			n := 6
			if upper == 'S' {
				n = 4
			}
			var v []float64
			if v, ok = nums(n); ok {
				c1x, c1y := cx, cy
				if upper == 'S' {
					if last == 'C' || last == 'S' {
						c1x, c1y = 2*cx-lastX, 2*cy-lastY
					}
					v = append([]float64{0, 0}, v...)
				} else {
					c1x, c1y = ox+v[0], oy+v[1]
				}
				c2x, c2y := ox+v[2], oy+v[3]
				x, y := ox+v[4], oy+v[5]
				p.cubicTo(c1x, c1y, c2x, c2y, x, y)
				lastX, lastY, cx, cy = c2x, c2y, x, y
			}
		case 'Q', 'T':
			n := 4
			if upper == 'T' {
				n = 2
			}
			var v []float64
			if v, ok = nums(n); ok {
				qx, qy := cx, cy
				if upper == 'T' {
					if last == 'Q' || last == 'T' {
						qx, qy = 2*cx-lastX, 2*cy-lastY
					}
					v = append([]float64{0, 0}, v...)
				} else {
					qx, qy = ox+v[0], oy+v[1]
				}
				x, y := ox+v[2], oy+v[3]
				p.cubicTo(cx+2.0/3*(qx-cx), cy+2.0/3*(qy-cy), x+2.0/3*(qx-x), y+2.0/3*(qy-y), x, y)
				lastX, lastY, cx, cy = qx, qy, x, y
			}
		case 'A':
			v, okN := nums(3)
			large, ok1 := sc.flag()
			sweep, ok2 := sc.flag()
			end, ok3 := nums(2)
			ok = okN && ok1 && ok2 && ok3
			if ok {
				x, y := ox+end[0], oy+end[1]
				p.arcTo(v[0], v[1], v[2], large, sweep, x, y)
				cx, cy = x, y
			}
		}
		if !ok {
			break
		}
		last = upper
	}
	p.dropLone()
	return p
}

func (p *uiSvgPath) dropLone() {
	if k := len(p.subs) - 1; k >= 0 && len(p.subs[k].pts) == 2 && !p.subs[k].closed {
		p.subs = p.subs[:k]
	}
}

func (r *uiSvgRender) geometry(n *uiSvgNode, tol float64) *uiSvgPath {
	p := &uiSvgPath{tol: tol}
	num := func(key string, axis int) float64 { return r.length(n, key, axis) }
	switch n.tag {
	case "path":
		return uiSvgParsePath(n.attrs["d"], tol)
	case "rect":
		x, y, w, h := num("x", 0), num("y", 1), num("width", 0), num("height", 1)
		if w <= 0 || h <= 0 {
			return p
		}
		_, hasRx := n.attrs["rx"]
		_, hasRy := n.attrs["ry"]
		rx, ry := math.Max(num("rx", 0), 0), math.Max(num("ry", 1), 0)
		if hasRx && !hasRy {
			ry = rx
		} else if hasRy && !hasRx {
			rx = ry
		}
		rx, ry = math.Min(rx, w/2), math.Min(ry, h/2)
		if rx == 0 || ry == 0 {
			p.moveTo(x, y)
			p.lineTo(x+w, y)
			p.lineTo(x+w, y+h)
			p.lineTo(x, y+h)
			p.close()
			return p
		}
		p.moveTo(x+rx, y)
		p.lineTo(x+w-rx, y)
		p.arcTo(rx, ry, 0, false, true, x+w, y+ry)
		p.lineTo(x+w, y+h-ry)
		p.arcTo(rx, ry, 0, false, true, x+w-rx, y+h)
		p.lineTo(x+rx, y+h)
		p.arcTo(rx, ry, 0, false, true, x, y+h-ry)
		p.lineTo(x, y+ry)
		p.arcTo(rx, ry, 0, false, true, x+rx, y)
		p.close()
	case "circle", "ellipse":
		cx, cy := num("cx", 0), num("cy", 1)
		rx, ry := num("r", 2), num("r", 2)
		if n.tag == "ellipse" {
			rx, ry = num("rx", 0), num("ry", 1)
			_, hasRx := n.attrs["rx"]
			_, hasRy := n.attrs["ry"]
			if !hasRx {
				rx = ry
			} else if !hasRy {
				ry = rx
			}
		}
		if rx <= 0 || ry <= 0 {
			return p
		}
		p.moveTo(cx+rx, cy)
		p.arcTo(rx, ry, 0, false, true, cx, cy+ry)
		p.arcTo(rx, ry, 0, false, true, cx-rx, cy)
		p.arcTo(rx, ry, 0, false, true, cx, cy-ry)
		p.arcTo(rx, ry, 0, false, true, cx+rx, cy)
		p.close()
	case "line":
		p.moveTo(num("x1", 0), num("y1", 1))
		p.lineTo(num("x2", 0), num("y2", 1))
	case "polyline", "polygon":
		v := uiSvgNumbers(n.attrs["points"])
		if len(v) < 2 {
			return p
		}
		p.moveTo(v[0], v[1])
		for i := 2; i+1 < len(v); i += 2 {
			p.lineTo(v[i], v[i+1])
		}
		if n.tag == "polygon" {
			p.close()
		}
	}
	return p
}

func (p *uiSvgPath) bounds() (float64, float64, float64, float64, bool) {
	x0, y0, x1, y1 := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, s := range p.subs {
		for i := 0; i+1 < len(s.pts); i += 2 {
			x0, x1 = math.Min(x0, s.pts[i]), math.Max(x1, s.pts[i])
			y0, y1 = math.Min(y0, s.pts[i+1]), math.Max(y1, s.pts[i+1])
		}
	}
	return x0, y0, x1, y1, x0 <= x1
}

func (r *uiSvgRender) shape(n *uiSvgNode, m uiSvgM, st uiSvgStyle, dst []uint8) {
	if !st.visible {
		return
	}
	scale := math.Max(m.scale(), 1e-6)
	path := r.geometry(n, 0.2/scale)
	bx0, by0, bx1, by1, ok := path.bounds()
	if !ok {
		return
	}
	bbox := [4]float64{bx0, by0, bx1 - bx0, by1 - by0}
	if !st.fill.none && n.tag != "line" {
		var polys [][]float64
		for _, s := range path.subs {
			if len(s.pts) >= 6 {
				polys = append(polys, uiSvgMap(m, s.pts))
			}
		}
		r.paint(dst, polys, st.evenOdd, st.fill, st.fillOp, m, bbox)
	}
	if !st.stroke.none {
		vp := r.viewport()
		width, _ := uiSvgLength(st.width, math.Sqrt((vp[0]*vp[0]+vp[1]*vp[1])/2))
		if width <= 0 {
			return
		}
		outline := uiSvgStroke(path, width/2, st, r.dashes(st))
		for i := range outline {
			outline[i] = uiSvgMap(m, outline[i])
		}
		r.paint(dst, outline, false, st.stroke, st.strokeOp, m, bbox)
	}
}

func uiSvgMap(m uiSvgM, pts []float64) []float64 {
	out := make([]float64, len(pts))
	for i := 0; i+1 < len(pts); i += 2 {
		out[i], out[i+1] = m.apply(pts[i], pts[i+1])
	}
	return out
}

func (r *uiSvgRender) dashes(st uiSvgStyle) []float64 {
	if st.dash == "none" || st.dash == "" {
		return nil
	}
	vp := r.viewport()
	of := math.Sqrt((vp[0]*vp[0] + vp[1]*vp[1]) / 2)
	var out []float64
	sum := 0.0
	for _, f := range strings.FieldsFunc(st.dash, func(c rune) bool { return c == ',' || c == ' ' }) {
		v, ok := uiSvgLength(f, of)
		if !ok || v < 0 {
			return nil
		}
		out = append(out, v)
		sum += v
	}
	if sum <= 0 {
		return nil
	}
	if len(out)%2 == 1 {
		out = append(out, out...)
	}
	off, _ := uiSvgLength(st.dashOffset, of)
	return append([]float64{off}, out...)
}

func uiSvgArea(p []float64) float64 {
	a := 0.0
	n := len(p) / 2
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		a += p[2*i]*p[2*j+1] - p[2*j]*p[2*i+1]
	}
	return a
}

func uiSvgWound(p []float64) []float64 {
	if uiSvgArea(p) >= 0 {
		return p
	}
	n := len(p) / 2
	out := make([]float64, len(p))
	for i := 0; i < n; i++ {
		out[2*i], out[2*i+1] = p[2*(n-1-i)], p[2*(n-1-i)+1]
	}
	return out
}

func uiSvgDisc(x, y, r float64) []float64 {
	n := min(max(int(math.Ceil(r*2.5)), 12), 128)
	out := make([]float64, 0, 2*n)
	for i := 0; i < n; i++ {
		t := 2 * math.Pi * float64(i) / float64(n)
		out = append(out, x+r*math.Cos(t), y+r*math.Sin(t))
	}
	return out
}

func uiSvgDedupe(pts []float64) []float64 {
	out := pts[:0:0]
	for i := 0; i+1 < len(pts); i += 2 {
		if len(out) >= 2 && out[len(out)-2] == pts[i] && out[len(out)-1] == pts[i+1] {
			continue
		}
		out = append(out, pts[i], pts[i+1])
	}
	return out
}

func uiSvgDash(pts []float64, closed bool, dash []float64) [][]float64 {
	if closed && len(pts) >= 4 {
		pts = append(append([]float64(nil), pts...), pts[0], pts[1])
	}
	pattern := dash[1:]
	total := 0.0
	for _, v := range pattern {
		total += v
	}
	off := math.Mod(dash[0], total)
	if off < 0 {
		off += total
	}
	idx := 0
	for off >= pattern[idx] {
		off -= pattern[idx]
		idx = (idx + 1) % len(pattern)
	}
	left := pattern[idx] - off
	on := idx%2 == 0
	var pieces [][]float64
	var cur []float64
	if on {
		cur = []float64{pts[0], pts[1]}
	}
	for i := 0; i+3 < len(pts); i += 2 {
		ax, ay, bx, by := pts[i], pts[i+1], pts[i+2], pts[i+3]
		seg := math.Hypot(bx-ax, by-ay)
		at := 0.0
		for seg-at > left {
			at += left
			x, y := ax+(bx-ax)*at/seg, ay+(by-ay)*at/seg
			if on {
				cur = append(cur, x, y)
				pieces = append(pieces, cur)
				cur = nil
			} else {
				cur = []float64{x, y}
			}
			on = !on
			idx = (idx + 1) % len(pattern)
			left = pattern[idx]
			if len(pieces) > 100000 {
				return pieces
			}
		}
		left -= seg - at
		if on {
			cur = append(cur, bx, by)
		}
	}
	if on && len(cur) >= 2 {
		pieces = append(pieces, cur)
	}
	return pieces
}

func uiSvgStroke(path *uiSvgPath, hw float64, st uiSvgStyle, dash []float64) [][]float64 {
	var out [][]float64
	add := func(p []float64) { out = append(out, uiSvgWound(p)) }
	for _, s := range path.subs {
		pts := uiSvgDedupe(s.pts)
		closed := s.closed
		if closed && len(pts) >= 4 && pts[0] == pts[len(pts)-2] && pts[1] == pts[len(pts)-1] {
			pts = pts[:len(pts)-2]
		}
		pieces := [][]float64{pts}
		if dash != nil && len(pts) >= 4 {
			pieces = uiSvgDash(pts, closed, dash)
			closed = false
		}
		for _, piece := range pieces {
			piece = uiSvgDedupe(piece)
			n := len(piece) / 2
			if n == 1 {
				x, y := piece[0], piece[1]
				switch st.cap {
				case "round":
					add(uiSvgDisc(x, y, hw))
				case "square":
					add([]float64{x - hw, y - hw, x + hw, y - hw, x + hw, y + hw, x - hw, y + hw})
				}
				continue
			}
			segs := n - 1
			if closed && n > 2 {
				segs = n
			}
			dir := func(i int) (float64, float64) {
				j := (i + 1) % n
				dx, dy := piece[2*j]-piece[2*i], piece[2*j+1]-piece[2*i+1]
				l := math.Hypot(dx, dy)
				return dx / l, dy / l
			}
			for i := 0; i < segs; i++ {
				j := (i + 1) % n
				dx, dy := dir(i)
				nx, ny := -dy*hw, dx*hw
				ax, ay, bx, by := piece[2*i], piece[2*i+1], piece[2*j], piece[2*j+1]
				add([]float64{ax + nx, ay + ny, bx + nx, by + ny, bx - nx, by - ny, ax - nx, ay - ny})
			}
			joins := func(i int) {
				p := (i - 1 + n) % n
				ix, iy := dir(p)
				ox, oy := dir(i)
				vx, vy := piece[2*i], piece[2*i+1]
				cross := ix*oy - iy*ox
				if math.Abs(cross) < 1e-9 && ix*ox+iy*oy > 0 {
					return
				}
				side := 1.0
				if cross > 0 {
					side = -1
				}
				ax, ay := vx-iy*hw*side, vy+ix*hw*side
				bx, by := vx-oy*hw*side, vy+ox*hw*side
				switch st.join {
				case "round":
					add(uiSvgDisc(vx, vy, hw))
				case "bevel":
					add([]float64{vx, vy, ax, ay, bx, by})
				default:
					cosT := -(ix*ox + iy*oy)
					sinHalf := math.Sqrt(math.Max(0, (1-cosT)/2))
					if sinHalf > 1e-9 && 1/sinHalf <= st.miter {
						mx, my := (ax+bx)/2-vx, (ay+by)/2-vy
						ml := math.Hypot(mx, my)
						reach := hw / sinHalf
						if ml > 1e-12 {
							px, py := vx+mx/ml*reach, vy+my/ml*reach
							add([]float64{vx, vy, ax, ay, px, py, bx, by})
							break
						}
					}
					add([]float64{vx, vy, ax, ay, bx, by})
				}
			}
			if closed && n > 2 {
				for i := 0; i < n; i++ {
					joins(i)
				}
				continue
			}
			for i := 1; i < n-1; i++ {
				joins(i)
			}
			for _, end := range [2]int{0, n - 1} {
				x, y := piece[2*end], piece[2*end+1]
				dx, dy := dir(min(end, n-2))
				if end == 0 {
					dx, dy = -dx, -dy
				}
				switch st.cap {
				case "round":
					add(uiSvgDisc(x, y, hw))
				case "square":
					nx, ny := -dy*hw, dx*hw
					fx, fy := x+dx*hw, y+dy*hw
					add([]float64{x + nx, y + ny, fx + nx, fy + ny, fx - nx, fy - ny, x - nx, y - ny})
				}
			}
		}
	}
	return out
}

func (r *uiRaster) maskEvenOdd(into []uint8) []uint8 {
	n := r.w * r.h
	if cap(into) < n {
		into = make([]uint8, n)
	}
	into = into[:n]
	stride := r.w + 2
	for y := 0; y < r.h; y++ {
		sum := float32(0)
		row := r.acc[y*stride : y*stride+r.w]
		out := into[y*r.w : (y+1)*r.w]
		for x, v := range row {
			sum += v
			a := sum
			if a < 0 {
				a = -a
			}
			a -= 2 * float32(math.Floor(float64(a/2)))
			if a > 1 {
				a = 2 - a
			}
			out[x] = uint8(a*255 + 0.5)
		}
	}
	return into
}

func (r *uiSvgRender) fillMask(into *[]uint8, polys [][]float64, evenOdd bool) {
	r.ras.reset(r.w, r.h)
	for _, p := range polys {
		r.ras.polygon(p)
	}
	if evenOdd {
		*into = r.ras.maskEvenOdd(*into)
	} else {
		*into = r.ras.mask(*into)
	}
}

type uiSvgStop struct {
	at    float64
	color [4]float64
}

type uiSvgGradient struct {
	radial     bool
	x1, y1     float64
	x2, y2     float64
	cx, cy, rr float64
	fx, fy, fr float64
	spread     string
	stops      []uiSvgStop
	inverse    uiSvgM
}

func (r *uiSvgRender) gradient(ref string, m uiSvgM, bbox [4]float64) (*uiSvgGradient, bool) {
	n := r.doc.ids[ref]
	if n == nil || n.tag != "linearGradient" && n.tag != "radialGradient" {
		return nil, false
	}
	attrs := map[string]string{}
	var stops []*uiSvgNode
	seen := map[*uiSvgNode]bool{}
	for at := n; at != nil && !seen[at]; {
		seen[at] = true
		for k, v := range at.attrs {
			if _, has := attrs[k]; !has {
				attrs[k] = v
			}
		}
		if stops == nil {
			for _, k := range at.kids {
				if k.tag == "stop" {
					stops = append(stops, k)
				}
			}
			if len(stops) == 0 {
				stops = nil
			}
		}
		next := r.doc.ids[strings.TrimPrefix(strings.TrimSpace(at.attrs["href"]), "#")]
		if next == nil || next.tag != "linearGradient" && next.tag != "radialGradient" {
			break
		}
		at = next
	}
	g := &uiSvgGradient{radial: n.tag == "radialGradient", spread: attrs["spreadMethod"]}
	userSpace := attrs["gradientUnits"] == "userSpaceOnUse"
	vp := r.viewport()
	get := func(key, def string, axis int) float64 {
		s, ok := attrs[key]
		if !ok {
			s = def
		}
		if !userSpace {
			v := uiSvgUnit(s)
			if math.IsNaN(v) {
				v = uiSvgUnit(def)
			}
			return v
		}
		of := math.Sqrt((vp[0]*vp[0] + vp[1]*vp[1]) / 2)
		if axis < 2 {
			of = vp[axis]
		}
		v, ok2 := uiSvgLength(s, of)
		if !ok2 {
			v, _ = uiSvgLength(def, of)
		}
		return v
	}
	if g.radial {
		g.cx, g.cy, g.rr = get("cx", "50%", 0), get("cy", "50%", 1), get("r", "50%", 2)
		g.fx, g.fy, g.fr = get("fx", attrs["cx"], 0), get("fy", attrs["cy"], 1), get("fr", "0%", 2)
		if _, ok := attrs["fx"]; !ok {
			g.fx = g.cx
		}
		if _, ok := attrs["fy"]; !ok {
			g.fy = g.cy
		}
	} else {
		g.x1, g.y1, g.x2, g.y2 = get("x1", "0%", 0), get("y1", "0%", 1), get("x2", "100%", 0), get("y2", "0%", 1)
	}
	space := m
	if !userSpace {
		if bbox[2] <= 0 || bbox[3] <= 0 {
			return nil, false
		}
		space = space.mul(uiSvgM{bbox[2], 0, 0, bbox[3], bbox[0], bbox[1]})
	}
	if t := attrs["gradientTransform"]; t != "" {
		space = space.mul(uiSvgTransform(t))
	}
	inv, ok := space.invert()
	if !ok {
		return nil, false
	}
	g.inverse = inv
	prev := 0.0
	for _, s := range stops {
		st := r.style(s, uiSvgInitial())
		at := uiSvgUnit(s.attrs["offset"])
		if math.IsNaN(at) {
			at = 0
		}
		at = math.Max(uiClamp(at, 0, 1), prev)
		prev = at
		c := st.stopColor
		c[3] *= st.stopOp
		g.stops = append(g.stops, uiSvgStop{at, [4]float64{c[0], c[1], c[2], c[3]}})
	}
	return g, true
}

func (g *uiSvgGradient) at(x, y float64) [4]float64 {
	c := g.straight(x, y)
	return [4]float64{c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]}
}

func (g *uiSvgGradient) straight(x, y float64) [4]float64 {
	if len(g.stops) == 0 {
		return [4]float64{}
	}
	if len(g.stops) == 1 {
		return g.stops[0].color
	}
	ux, uy := g.inverse.apply(x, y)
	var t float64
	if g.radial {
		cdx, cdy := g.cx-g.fx, g.cy-g.fy
		pdx, pdy := ux-g.fx, uy-g.fy
		dr := g.rr - g.fr
		a := cdx*cdx + cdy*cdy - dr*dr
		b := pdx*cdx + pdy*cdy + g.fr*dr
		c := pdx*pdx + pdy*pdy - g.fr*g.fr
		if math.Abs(a) < 1e-12 {
			t = c / (2 * b)
		} else {
			disc := b*b - a*c
			if disc < 0 {
				return [4]float64{}
			}
			t = (b + math.Sqrt(disc)) / a
			if a < 0 {
				t = (b - math.Sqrt(disc)) / a
			}
		}
	} else {
		dx, dy := g.x2-g.x1, g.y2-g.y1
		l := dx*dx + dy*dy
		if l == 0 {
			return g.stops[len(g.stops)-1].color
		}
		t = ((ux-g.x1)*dx + (uy-g.y1)*dy) / l
	}
	switch g.spread {
	case "reflect":
		t = math.Mod(math.Abs(t), 2)
		if t > 1 {
			t = 2 - t
		}
	case "repeat":
		t -= math.Floor(t)
	default:
		t = uiClamp(t, 0, 1)
	}
	i := sort.Search(len(g.stops), func(i int) bool { return g.stops[i].at >= t })
	switch {
	case i == 0:
		return g.stops[0].color
	case i == len(g.stops):
		return g.stops[len(g.stops)-1].color
	}
	a, b := g.stops[i-1], g.stops[i]
	f := 0.0
	if b.at > a.at {
		f = (t - a.at) / (b.at - a.at)
	}
	var out [4]float64
	for k := range out {
		out[k] = a.color[k] + (b.color[k]-a.color[k])*f
	}
	return out
}

func (r *uiSvgRender) paint(dst []uint8, polys [][]float64, evenOdd bool, paint uiSvgPaint, opacity float64, m uiSvgM, bbox [4]float64) {
	if len(polys) == 0 || opacity <= 0 {
		return
	}
	var g *uiSvgGradient
	solid := paint.color
	if paint.ref != "" {
		var ok bool
		g, ok = r.gradient(paint.ref, m, bbox)
		if !ok {
			if paint.back == nil || paint.back.none || paint.back.ref != "" {
				return
			}
			solid = paint.back.color
		}
	}
	x0, y0, x1, y1 := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, p := range polys {
		for i := 0; i+1 < len(p); i += 2 {
			x0, x1 = math.Min(x0, p[i]), math.Max(x1, p[i])
			y0, y1 = math.Min(y0, p[i+1]), math.Max(y1, p[i+1])
		}
	}
	if math.IsNaN(x0 + y0 + x1 + y1) {
		return
	}
	ax0, ay0 := max(int(math.Floor(x0)), 0), max(int(math.Floor(y0)), 0)
	ax1, ay1 := min(int(math.Ceil(x1))+1, r.w), min(int(math.Ceil(y1))+1, r.h)
	if ax0 >= ax1 || ay0 >= ay1 {
		return
	}
	bw, bh := ax1-ax0, ay1-ay0
	r.ras.reset(bw, bh)
	ox, oy := float64(ax0), float64(ay0)
	for _, p := range polys {
		count := len(p) / 2
		for i := 0; i < count; i++ {
			j := (i + 1) % count
			r.ras.line(p[2*i]-ox, p[2*i+1]-oy, p[2*j]-ox, p[2*j+1]-oy)
		}
	}
	if evenOdd {
		r.cover = r.ras.maskEvenOdd(r.cover)
	} else {
		r.cover = r.ras.mask(r.cover)
	}
	pre := [4]float64{solid[0] * solid[3], solid[1] * solid[3], solid[2] * solid[3], solid[3]}
	for y := 0; y < bh; y++ {
		for x := 0; x < bw; x++ {
			c := r.cover[y*bw+x]
			if c == 0 {
				continue
			}
			col := pre
			if g != nil {
				col = g.at(float64(ax0+x)+0.5, float64(ay0+y)+0.5)
			}
			k := float64(c) / 255 * opacity
			d := dst[((ay0+y)*r.w+ax0+x)*4:]
			sa := col[3] * k
			keep := 1 - sa
			for ch := 0; ch < 3; ch++ {
				d[ch] = uint8(uiClamp(col[ch]*k*255+float64(d[ch])*keep+0.5, 0, 255))
			}
			d[3] = uint8(uiClamp(sa*255+float64(d[3])*keep+0.5, 0, 255))
		}
	}
}

func (r *uiSvgRender) merge(dst, layer []uint8, opacity float64, mask []uint8) {
	for i := 0; i < len(dst); i += 4 {
		if layer[i+3] == 0 && layer[i] == 0 && layer[i+1] == 0 && layer[i+2] == 0 {
			continue
		}
		k := opacity
		if mask != nil {
			k *= float64(mask[i/4]) / 255
		}
		if k <= 0 {
			continue
		}
		keep := 1 - float64(layer[i+3])/255*k
		for ch := 0; ch < 4; ch++ {
			dst[i+ch] = uint8(uiClamp(float64(layer[i+ch])*k+float64(dst[i+ch])*keep+0.5, 0, 255))
		}
	}
}

func (r *uiSvgRender) clipMask(ref string, n *uiSvgNode, m uiSvgM) []uint8 {
	ref = strings.TrimSpace(ref)
	if !strings.HasPrefix(ref, "url(") {
		return nil
	}
	close := strings.IndexByte(ref, ')')
	if close < 0 {
		return nil
	}
	c := r.doc.ids[strings.TrimPrefix(strings.Trim(strings.TrimSpace(ref[4:close]), "'\""), "#")]
	if c == nil || c.tag != "clipPath" {
		return nil
	}
	space := m
	if t := c.attrs["transform"]; t != "" {
		space = space.mul(uiSvgTransform(t))
	}
	if c.attrs["clipPathUnits"] == "objectBoundingBox" {
		p := r.geometry(n, 0.01)
		x0, y0, x1, y1, ok := p.bounds()
		if !ok || x1 <= x0 || y1 <= y0 {
			return make([]uint8, r.w*r.h)
		}
		space = space.mul(uiSvgM{x1 - x0, 0, 0, y1 - y0, x0, y0})
	}
	cst := r.style(c, uiSvgInitial())
	var union []uint8
	var walk func(k *uiSvgNode, sm uiSvgM, st uiSvgStyle, depth int)
	walk = func(k *uiSvgNode, sm uiSvgM, st uiSvgStyle, depth int) {
		if depth > 16 {
			return
		}
		ks := r.style(k, st)
		if !ks.display || !ks.visible && k.tag != "use" {
			return
		}
		km := r.own(k, sm, ks)
		switch k.tag {
		case "use":
			t := r.doc.ids[strings.TrimPrefix(strings.TrimSpace(k.attrs["href"]), "#")]
			if t != nil && t != k && t.tag != "use" {
				walk(t, km.mul(uiSvgM{1, 0, 0, 1, r.length(k, "x", 0), r.length(k, "y", 1)}), ks, depth+1)
			}
		case "path", "rect", "circle", "ellipse", "polyline", "polygon":
			p := r.geometry(k, 0.2/math.Max(km.scale(), 1e-6))
			var polys [][]float64
			for _, s := range p.subs {
				if len(s.pts) >= 6 {
					polys = append(polys, uiSvgMap(km, s.pts))
				}
			}
			var one []uint8
			r.fillMask(&one, polys, ks.clipOdd)
			if union == nil {
				union = one
				return
			}
			for i, v := range one {
				union[i] = max(union[i], v)
			}
		}
	}
	for _, k := range c.kids {
		walk(k, space, cst, 0)
	}
	if union == nil {
		return make([]uint8, r.w*r.h)
	}
	return union
}
