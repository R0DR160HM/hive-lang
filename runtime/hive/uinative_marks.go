// A canvas's marks, drawn: every shape becomes rings of points in its own units, carried
// through the symbols around it to pixels, then filled, outlined or stroked.
package hive

import (
	"math"
)

// x' = a·x + c·y + e, y' = b·x + d·y + f.
type uiAffine struct{ a, b, c, d, e, f float64 }

func (m uiAffine) at(x, y float64) (float64, float64) {
	return m.a*x + m.c*y + m.e, m.b*x + m.d*y + m.f
}

func (m uiAffine) then(n uiAffine) uiAffine {
	return uiAffine{
		a: m.a*n.a + m.c*n.b, b: m.b*n.a + m.d*n.b,
		c: m.a*n.c + m.c*n.d, d: m.b*n.c + m.d*n.d,
		e: m.a*n.e + m.c*n.f + m.e, f: m.b*n.e + m.d*n.f + m.f,
	}
}

func (m uiAffine) size() float64 { return math.Sqrt(math.Abs(m.a*m.d - m.b*m.c)) }

func (m uiAffine) turned() bool { return math.Abs(m.b) > 1e-9 || math.Abs(m.c) > 1e-9 }

func (m uiAffine) inverse() uiAffine {
	det := m.a*m.d - m.b*m.c
	if det == 0 {
		return uiAffine{}
	}
	return uiAffine{a: m.d / det, b: -m.b / det, c: -m.c / det, d: m.a / det,
		e: (m.c*m.f - m.d*m.e) / det, f: (m.b*m.e - m.a*m.f) / det}
}

func (m uiAffine) points(pts []float64) []float64 {
	out := make([]float64, len(pts)&^1)
	for i := 0; i+1 < len(pts); i += 2 {
		out[i], out[i+1] = m.at(pts[i], pts[i+1])
	}
	return out
}

type uiInk struct {
	box    uiClip
	under  uiRGBA
	colour uiRGBA
}

func (n *uiNative) paintMarks(cv *uiCanvas, marks []UiMark, m uiAffine, ink uiInk) {
	for _, mk := range marks {
		n.paintMark(cv, mk, m, ink)
	}
}

// Steps enough that a curve of this radius in pixels reads as round.
func uiSteps(radius float64) int {
	if radius <= 0 {
		return 8
	}
	steps := int(math.Ceil(math.Pi / math.Acos(math.Max(-1, 1-0.12/math.Max(radius, 0.12)))))
	return min(max(steps, 8), 720)
}

func uiArcPoints(x, y, r, from, to float64, steps int) []float64 {
	out := make([]float64, 0, (steps+1)*2)
	for i := 0; i <= steps; i++ {
		at := from + (to-from)*float64(i)/float64(steps)
		px, py := uiOnCircle(x, y, r, at)
		out = append(out, px, py)
	}
	return out
}

func uiEllipsePoints(x, y, rx, ry float64, steps int) []float64 {
	out := make([]float64, 0, steps*2)
	for i := 0; i < steps; i++ {
		at := 2 * math.Pi * float64(i) / float64(steps)
		out = append(out, x+rx*math.Cos(at), y+ry*math.Sin(at))
	}
	return out
}

func uiBezierPoints(n []float64, size float64) []float64 {
	out := []float64{n[0], n[1]}
	for i := 2; i+5 < len(n); i += 6 {
		x0, y0 := out[len(out)-2], out[len(out)-1]
		c1x, c1y, c2x, c2y, x1, y1 := n[i], n[i+1], n[i+2], n[i+3], n[i+4], n[i+5]
		dd := math.Max(math.Hypot(x0-2*c1x+c2x, y0-2*c1y+c2y), math.Hypot(c1x-2*c2x+x1, c1y-2*c2y+y1)) * size
		steps := max(2, min(256, int(math.Sqrt(dd)*3)))
		for k := 1; k <= steps; k++ {
			t := float64(k) / float64(steps)
			u := 1 - t
			out = append(out, u*u*u*x0+3*u*u*t*c1x+3*u*t*t*c2x+t*t*t*x1, u*u*u*y0+3*u*u*t*c1y+3*u*t*t*c2y+t*t*t*y1)
		}
	}
	return out
}

// The rings a mark is made of in its own units, whether they enclose anything, and its box.
func uiRings(mk UiMark, size float64) ([][]float64, bool, [4]float64) {
	n := mk.Nums
	switch mk.Kind {
	case "dot":
		if len(n) < 3 || n[2] <= 0 {
			return nil, false, [4]float64{}
		}
		return [][]float64{uiEllipsePoints(n[0], n[1], n[2], n[2], uiSteps(n[2]*size))}, true,
			[4]float64{n[0] - n[2], n[1] - n[2], n[0] + n[2], n[1] + n[2]}
	case "oval":
		if len(n) < 4 || n[2] <= 0 || n[3] <= 0 {
			return nil, false, [4]float64{}
		}
		return [][]float64{uiEllipsePoints(n[0], n[1], n[2]/2, n[3]/2, uiSteps(math.Max(n[2], n[3])/2*size))}, true,
			[4]float64{n[0] - n[2]/2, n[1] - n[3]/2, n[0] + n[2]/2, n[1] + n[3]/2}
	case "bar":
		if len(n) < 4 {
			return nil, false, [4]float64{}
		}
		l, t, r, d := n[0]-n[2]/2, n[1]-n[3]/2, n[0]+n[2]/2, n[1]+n[3]/2
		return [][]float64{{l, t, r, t, r, d, l, d}}, true, [4]float64{l, t, r, d}
	case "patch":
		if len(n) < 6 {
			return nil, false, [4]float64{}
		}
		return [][]float64{n[:len(n)&^1]}, true, uiBoxOf(n)
	case "path":
		if len(n) < 4 {
			return nil, false, [4]float64{}
		}
		return [][]float64{n[:len(n)&^1]}, false, uiBoxOf(n)
	case "curve":
		if len(n) < 8 {
			return nil, false, [4]float64{}
		}
		return [][]float64{uiBezierPoints(n, size)}, false, uiBoxOf(n)
	case "arc", "wedge":
		if len(n) < 5 || n[2] <= 0 {
			return nil, false, [4]float64{}
		}
		x, y, r := n[0], n[1], n[2]
		box := [4]float64{x - r, y - r, x + r, y + r}
		sweep, whole := uiSweep(n[3], n[4])
		steps := max(2, int(math.Ceil(float64(uiSteps(r*size))*math.Min(math.Abs(sweep), 2*math.Pi)/(2*math.Pi))))
		if whole {
			ring := uiEllipsePoints(x, y, r, r, uiSteps(r*size))
			if mk.Kind == "arc" {
				return [][]float64{append(ring, ring[0], ring[1])}, false, box
			}
			return [][]float64{ring}, true, box
		}
		pts := uiArcPoints(x, y, r, n[3], n[4], steps)
		if mk.Kind == "arc" {
			return [][]float64{pts}, false, box
		}
		return [][]float64{append([]float64{x, y}, pts...)}, true, box
	case "cutout":
		var rings [][]float64
		var box [4]float64
		for i, part := range mk.Marks {
			if part.Kind == "cutout" || part.Kind == "path" || part.Kind == "curve" || part.Kind == "arc" {
				continue
			}
			got, closed, b := uiRings(part, size)
			if !closed || len(got) == 0 {
				continue
			}
			ring := got[0]
			if i == 0 {
				box = b
			} else {
				box = uiJoinBox(box, b)
				if len(rings) > 0 && (uiArea(ring) > 0) == (uiArea(rings[0]) > 0) {
					ring = uiReversed(ring)
				}
			}
			rings = append(rings, ring)
		}
		return rings, len(rings) > 0, box
	}
	return nil, false, [4]float64{}
}

func uiArea(pts []float64) float64 {
	sum := 0.0
	count := len(pts) / 2
	for i := 0; i < count; i++ {
		j := (i + 1) % count
		sum += pts[2*i]*pts[2*j+1] - pts[2*j]*pts[2*i+1]
	}
	return sum / 2
}

func uiReversed(pts []float64) []float64 {
	out := make([]float64, len(pts))
	count := len(pts) / 2
	for i := 0; i < count; i++ {
		out[2*i], out[2*i+1] = pts[2*(count-1-i)], pts[2*(count-1-i)+1]
	}
	return out
}

// A polyline cut into its dashes, the pattern carried on from one piece to the next as SVG carries it.
func uiDashed(pts []float64, on, off float64) [][]float64 {
	if on <= 0 && off <= 0 || on <= 0 {
		return [][]float64{pts}
	}
	var out [][]float64
	var piece []float64
	drawing, left := true, on
	for i := 0; i+3 < len(pts); i += 2 {
		ax, ay, bx, by := pts[i], pts[i+1], pts[i+2], pts[i+3]
		length := math.Hypot(bx-ax, by-ay)
		done := 0.0
		for done < length {
			step := math.Min(left, length-done)
			t0, t1 := done/length, (done+step)/length
			if drawing {
				if len(piece) == 0 {
					piece = append(piece, ax+(bx-ax)*t0, ay+(by-ay)*t0)
				}
				piece = append(piece, ax+(bx-ax)*t1, ay+(by-ay)*t1)
			}
			done += step
			left -= step
			if left <= 1e-9 {
				if drawing && len(piece) >= 4 {
					out = append(out, piece)
				}
				piece = nil
				drawing = !drawing
				left = on
				if !drawing {
					left = off
				}
			}
		}
	}
	if drawing && len(piece) >= 4 {
		out = append(out, piece)
	}
	return out
}

func (n *uiNative) strokeRings(cv *uiCanvas, rings [][]float64, closed bool, width float64, dash []float64, c uiRGBA, clip uiClip) {
	var polys [][]float64
	for _, ring := range rings {
		line := ring
		if closed && len(ring) >= 4 {
			line = append(append([]float64{}, ring...), ring[0], ring[1])
		}
		pieces := [][]float64{line}
		if len(dash) == 2 {
			pieces = uiDashed(line, dash[0], dash[1])
		}
		for _, p := range pieces {
			polys = append(polys, uiStroke(p, width/2)...)
		}
	}
	n.fillPolys(cv, polys, c, clip)
}

func (n *uiNative) paintMark(cv *uiCanvas, mk UiMark, m uiAffine, ink uiInk) {
	opacity := uiOpacity(mk.Attrs)
	if opacity <= 0 {
		return
	}
	if mk.Kind == "symbol" {
		n.paintSymbol(cv, mk, m, ink, opacity)
		return
	}
	if opacity < 1 {
		saved := cv.grab(cv.bounds(ink.box))
		defer cv.fade(saved, cv.bounds(ink.box), opacity)
	}
	switch mk.Kind {
	case "words":
		n.paintWords(cv, mk, m, ink)
		return
	case "picture":
		n.paintPictureMark(cv, mk, m, ink)
		return
	}
	size := m.size()
	rings, closed, box := uiRings(mk, size)
	if len(rings) == 0 {
		return
	}
	pixel := make([][]float64, len(rings))
	for i, r := range rings {
		pixel[i] = m.points(r)
	}
	_, painted := uiFind(mk.Attrs, "paint")
	edge, edged := uiFind(mk.Attrs, "edge")
	paint := n.markColour(mk.Attrs, ink.colour)
	width := uiThick(mk.Attrs) * size
	var dash []float64
	if d, ok := uiFind(mk.Attrs, "dash"); ok && len(d.Nums) == 2 && d.Nums[0]+d.Nums[1] > 0 {
		dash = []float64{d.Nums[0] * size, d.Nums[1] * size}
	}
	g, shaded := uiFind(mk.Attrs, "gradient")
	if !closed {
		n.strokeRings(cv, pixel, false, width, dash, paint, ink.box)
		return
	}
	if shaded {
		n.shadePolys(cv, pixel, g, box, m, ink.box)
	} else if painted || !edged {
		n.fillPolys(cv, pixel, paint, ink.box)
	}
	if edged {
		line := n.markColour([]UiAttr{{Kind: "paint", Word: edge.Word}}, ink.colour)
		n.strokeRings(cv, pixel, true, width, dash, line, ink.box)
	}
}

// A gradient over filled rings, its line laid in the mark's own units.
func (n *uiNative) shadePolys(cv *uiCanvas, polys [][]float64, g UiAttr, box [4]float64, m uiAffine, clip uiClip) {
	from, to, angle := uiGradientOf(g)
	a, z := n.markColour([]UiAttr{{Kind: "paint", Word: from}}, n.pal.fg), n.markColour([]UiAttr{{Kind: "paint", Word: to}}, n.pal.fg)
	dx, dy := math.Cos(angle), math.Sin(angle)
	w, h := box[2]-box[0], box[3]-box[1]
	span := math.Abs(w*dx) + math.Abs(h*dy)
	if span <= 0 {
		span = 1
	}
	cx, cy := (box[0]+box[2])/2, (box[1]+box[3])/2
	back := m.inverse()
	x0, y0, x1, y1 := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, p := range polys {
		for i := 0; i+1 < len(p); i += 2 {
			x0, x1 = math.Min(x0, p[i]), math.Max(x1, p[i])
			y0, y1 = math.Min(y0, p[i+1]), math.Max(y1, p[i+1])
		}
	}
	if math.IsInf(x0, 0) || math.IsNaN(x0+x1+y0+y1) {
		return
	}
	area := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)) + 1, int(math.Ceil(y1)) + 1})
	if area.empty() {
		return
	}
	r := &n.raster
	r.reset(area.x1-area.x0, area.y1-area.y0)
	ox, oy := float64(area.x0), float64(area.y0)
	for _, p := range polys {
		count := len(p) / 2
		for i := 0; i < count; i++ {
			j := (i + 1) % count
			r.line(p[2*i]-ox, p[2*i+1]-oy, p[2*j]-ox, p[2*j+1]-oy)
		}
	}
	n.cover = r.mask(n.cover)
	cv.flush()
	for py := area.y0; py < area.y1; py++ {
		row := cv.pix[py*cv.w : (py+1)*cv.w]
		cover := n.cover[(py-area.y0)*r.w : (py-area.y0+1)*r.w]
		for px := area.x0; px < area.x1; px++ {
			k := cover[px-area.x0]
			if k == 0 {
				continue
			}
			mx, my := back.at(float64(px)+0.5, float64(py)+0.5)
			t := uiClamp(((mx-cx)*dx+(my-cy)*dy)/span+0.5, 0, 1)
			row[px] = uiBlendPixel(row[px], uiLerpColour(a, z, t), float64(k)/255)
		}
	}
}

func (n *uiNative) paintSymbol(cv *uiCanvas, mk UiMark, m uiAffine, ink uiInk, opacity float64) {
	if len(mk.Nums) < 4 {
		return
	}
	x, y, angle, size := mk.Nums[0], mk.Nums[1], mk.Nums[2], mk.Nums[3]
	cos, sin := math.Cos(angle), math.Sin(angle)
	inner := m.then(uiAffine{a: cos * size, b: sin * size, c: -sin * size, d: cos * size, e: x, f: y})
	c, cropped := uiFind(mk.Attrs, "crop")
	cropped = cropped && len(c.Nums) == 4
	area := cv.bounds(ink.box)
	var saved []uint32
	if opacity < 1 || cropped {
		saved = cv.grab(area)
	}
	n.paintMarks(cv, mk.Marks, inner, ink)
	if saved == nil {
		return
	}
	var mask []uint8
	if cropped {
		l, t := c.Nums[0], c.Nums[1]
		rect := inner.points([]float64{l, t, l + c.Nums[2], t, l + c.Nums[2], t + c.Nums[3], l, t + c.Nums[3]})
		r := &n.raster
		r.reset(area.x1-area.x0, area.y1-area.y0)
		ox, oy := float64(area.x0), float64(area.y0)
		for i := 0; i < 4; i++ {
			j := (i + 1) % 4
			r.line(rect[2*i]-ox, rect[2*i+1]-oy, rect[2*j]-ox, rect[2*j+1]-oy)
		}
		mask = r.mask(nil)
	}
	cv.keep(saved, area, mask, opacity)
}

// What was drawn over an area since it was saved, kept as far as a mask and an opacity say.
func (cv *uiCanvas) keep(saved []uint32, r uiClip, mask []uint8, opacity float64) {
	if saved == nil || r.empty() {
		return
	}
	cv.flush()
	w := r.x1 - r.x0
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w+r.x0 : y*cv.w+r.x1]
		was := saved[(y-r.y0)*w : (y-r.y0+1)*w]
		for x, now := range row {
			if now == was[x] {
				continue
			}
			k := opacity
			if mask != nil {
				k *= float64(mask[(y-r.y0)*w+x]) / 255
			}
			row[x] = uiBlendPixel(was[x], uiRGBA{uint8(now >> 16), uint8(now >> 8), uint8(now), 255}, k)
		}
	}
}

func (n *uiNative) paintWords(cv *uiCanvas, mk UiMark, m uiAffine, ink uiInk) {
	if len(mk.Nums) < 3 || mk.Nums[2] <= 0 || mk.Text == "" {
		return
	}
	height := mk.Nums[2]
	wide := UiMeasure(mk.Text, height)
	cx, cy := uiAnchored(mk.Attrs, mk.Nums[0], mk.Nums[1], wide, height)
	size := m.size()
	f := uiFont{px: math.Round(height*size/n.scale*8) / 8, weight: 400}
	if w, ok := uiFind(mk.Attrs, "weight"); ok {
		f.weight = w.Num
	}
	f.italic = uiFlagOf(mk.Attrs, "italic")
	if f.px < 1 || wide <= 0 {
		return
	}
	natural := n.measure(f, mk.Text)
	if natural > 0 {
		f.stretch = wide * size / n.scale / natural
	}
	colour := uiMix(ink.under, n.markColour(mk.Attrs, ink.colour), 1)
	px, py := m.at(cx, cy)
	if !m.turned() {
		width := n.measure(f, mk.Text) * n.scale
		tall := n.dev.tall(f) * n.scale
		n.dev.text(f, int(math.Round(px-width/2)), int(math.Round(py-tall/2)), mk.Text, colour, ink.box)
		return
	}
	blot, ok := n.dev.(interface {
		blot(f uiFont, s string) (int, int, []uint8)
	})
	if !ok {
		return
	}
	bw, bh, mask := blot.blot(f, mk.Text)
	if bw <= 0 || bh <= 0 {
		return
	}
	angle := math.Atan2(m.b, m.a)
	turn := uiAffine{a: math.Cos(angle), b: math.Sin(angle), c: -math.Sin(angle), d: math.Cos(angle), e: px, f: py}.
		then(uiAffine{a: 1, d: 1, e: -float64(bw) / 2, f: -float64(bh) / 2})
	cv.blendTurned(mask, bw, bh, turn, colour, ink.box)
}

// A mask laid down through a turn, each pixel sampled back from where it came.
func (cv *uiCanvas) blendTurned(mask []uint8, mw, mh int, m uiAffine, c uiRGBA, clip uiClip) {
	x0, y0, x1, y1 := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, corner := range [][2]float64{{0, 0}, {float64(mw), 0}, {0, float64(mh)}, {float64(mw), float64(mh)}} {
		x, y := m.at(corner[0], corner[1])
		x0, x1, y0, y1 = math.Min(x0, x), math.Max(x1, x), math.Min(y0, y), math.Max(y1, y)
	}
	area := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)), int(math.Ceil(y1))})
	if area.empty() {
		return
	}
	back := m.inverse()
	sample := func(x, y int) float64 {
		if x < 0 || y < 0 || x >= mw || y >= mh {
			return 0
		}
		return float64(mask[y*mw+x]) / 255
	}
	cv.flush()
	for py := area.y0; py < area.y1; py++ {
		row := cv.pix[py*cv.w : (py+1)*cv.w]
		for px := area.x0; px < area.x1; px++ {
			sx, sy := back.at(float64(px)+0.5, float64(py)+0.5)
			sx, sy = sx-0.5, sy-0.5
			ix, iy := int(math.Floor(sx)), int(math.Floor(sy))
			fx, fy := sx-float64(ix), sy-float64(iy)
			k := sample(ix, iy)*(1-fx)*(1-fy) + sample(ix+1, iy)*fx*(1-fy) + sample(ix, iy+1)*(1-fx)*fy + sample(ix+1, iy+1)*fx*fy
			if k > 0.002 {
				row[px] = uiBlendPixel(row[px], c, k)
			}
		}
	}
}

func (n *uiNative) paintPictureMark(cv *uiCanvas, mk UiMark, m uiAffine, ink uiInk) {
	if len(mk.Nums) < 4 || mk.Nums[2] <= 0 || mk.Nums[3] <= 0 {
		return
	}
	pic := n.picture(mk.Text)
	pw, ph := pic.natural()
	if pw <= 0 || ph <= 0 {
		return
	}
	x, y, w, h := mk.Nums[0]-mk.Nums[2]/2, mk.Nums[1]-mk.Nums[3]/2, mk.Nums[2], mk.Nums[3]
	dx, dy, dw, dh := x, y, w, h
	fit, _ := uiFind(mk.Attrs, "fit")
	if fit.Word == "Contain" || fit.Word == "Cover" {
		k := math.Min(w/pw, h/ph)
		if fit.Word == "Cover" {
			k = math.Max(w/pw, h/ph)
		}
		dw, dh = pw*k, ph*k
		dx, dy = x+(w-dw)/2, y+(h-dh)/2
	}
	size := m.size()
	sw, sh := max(1, int(math.Round(dw*size))), max(1, int(math.Round(dh*size)))
	if sw > 8192 || sh > 8192 {
		return
	}
	pix := pic.at(sw, sh)
	if pix == nil {
		return
	}
	clip := ink.box
	if fit.Word == "Cover" {
		corners := m.points([]float64{x, y, x + w, y + h})
		if !m.turned() {
			clip = clip.and(uiClip{int(math.Round(math.Min(corners[0], corners[2]))), int(math.Round(math.Min(corners[1], corners[3]))),
				int(math.Round(math.Max(corners[0], corners[2]))), int(math.Round(math.Max(corners[1], corners[3])))})
		}
	}
	if !m.turned() {
		left, top := m.at(dx, dy)
		cv.blit(pix, sw, sh, int(math.Round(left)), int(math.Round(top)), clip)
		return
	}
	place := m.then(uiAffine{a: dw / float64(sw), d: dh / float64(sh), e: dx, f: dy})
	cv.blitTurned(pix, sw, sh, place, clip)
}

func (cv *uiCanvas) blitTurned(pix []uint8, w, h int, m uiAffine, clip uiClip) {
	x0, y0, x1, y1 := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, corner := range [][2]float64{{0, 0}, {float64(w), 0}, {0, float64(h)}, {float64(w), float64(h)}} {
		x, y := m.at(corner[0], corner[1])
		x0, x1, y0, y1 = math.Min(x0, x), math.Max(x1, x), math.Min(y0, y), math.Max(y1, y)
	}
	area := cv.bounds(clip).and(uiClip{int(math.Floor(x0)), int(math.Floor(y0)), int(math.Ceil(x1)), int(math.Ceil(y1))})
	if area.empty() {
		return
	}
	back := m.inverse()
	cv.flush()
	for py := area.y0; py < area.y1; py++ {
		row := cv.pix[py*cv.w : (py+1)*cv.w]
		for px := area.x0; px < area.x1; px++ {
			sx, sy := back.at(float64(px)+0.5, float64(py)+0.5)
			ix, iy := int(math.Floor(sx)), int(math.Floor(sy))
			if ix < 0 || iy < 0 || ix >= w || iy >= h {
				continue
			}
			p := pix[(iy*w+ix)*4:]
			if p[3] == 0 {
				continue
			}
			keep := uint32(255 - p[3])
			d := row[px]
			rr := uint32(p[0]) + (d>>16&0xff)*keep/255
			gg := uint32(p[1]) + (d>>8&0xff)*keep/255
			bb := uint32(p[2]) + (d&0xff)*keep/255
			row[px] = min(rr, 255)<<16 | min(gg, 255)<<8 | min(bb, 255) | 0xff000000
		}
	}
}
