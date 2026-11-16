// Pictures and canvases.
package hive

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/draw"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type uiPicture struct {
	mu     sync.Mutex
	done   bool
	used   bool
	pix    []uint8
	w, h   int
	frames []uiFrame
	vector uiVector
	start  time.Time
	sized  []uint8
	sw, sh int
	shown  int
}

type uiFrame struct {
	pix   []uint8
	delay time.Duration
}

type uiVector interface {
	size() (float64, float64)
	render(w, h int) []uint8
}

func (n *uiNative) picture(src string) *uiPicture {
	p, ok := n.pics[src]
	if !ok {
		p = &uiPicture{}
		n.pics[src] = p
		go n.fetch(p, src)
	}
	p.used = true
	return p
}

func (n *uiNative) forget() {
	for src, p := range n.pics {
		if !p.used {
			delete(n.pics, src)
		}
		p.used = false
	}
}

func (n *uiNative) fetch(p *uiPicture, src string) {
	var decoded image.Image
	body, ok := uiPictureBytes(src)
	if ok {
		if frames, w, h, moving := uiDecodeFrames(body); moving {
			p.mu.Lock()
			p.done, p.frames, p.pix, p.w, p.h, p.start = true, frames, frames[0].pix, w, h, time.Now()
			p.mu.Unlock()
			n.fetched()
			return
		}
		if v, drawn := uiParseSVG(body); drawn {
			w, h := v.size()
			p.mu.Lock()
			p.done, p.vector, p.w, p.h = true, v, int(math.Round(w)), int(math.Round(h))
			p.mu.Unlock()
			n.fetched()
			return
		}
		decoded, _, _ = image.Decode(bytes.NewReader(body))
	}
	var rgba *image.RGBA
	if decoded != nil {
		b := decoded.Bounds()
		rgba = image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
		draw.Draw(rgba, rgba.Bounds(), decoded, b.Min, draw.Src)
	}
	p.mu.Lock()
	p.done = true
	if rgba != nil {
		p.pix, p.w, p.h = rgba.Pix, rgba.Rect.Dx(), rgba.Rect.Dy()
	}
	p.mu.Unlock()
	n.fetched()
}

func (n *uiNative) fetched() {
	n.redo.Store(true)
	if n.wake != nil {
		n.wake()
	}
}

func uiPictureBytes(src string) ([]byte, bool) {
	lower := strings.ToLower(src)
	switch {
	case strings.HasPrefix(lower, "data:"):
		comma := strings.IndexByte(src, ',')
		if comma < 0 {
			return nil, false
		}
		head, body := src[5:comma], src[comma+1:]
		if strings.HasSuffix(strings.ToLower(head), ";base64") {
			out, err := base64.StdEncoding.DecodeString(strings.TrimRight(body, "="))
			if err != nil {
				out, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(body, "="))
			}
			return out, err == nil
		}
		out, err := url.PathUnescape(body)
		return []byte(out), err == nil
	case strings.HasPrefix(src, "/_hive/asset/"):
		name := strings.TrimPrefix(src, "/_hive/asset/")
		if uiAssets == nil || name == "" || strings.Contains(name, "..") {
			return nil, false
		}
		out, err := uiAssets.ReadFile("assets/" + name)
		return out, err == nil
	case src == "/_hive/icon":
		return uiWindowIcon, len(uiWindowIcon) > 0
	case strings.HasPrefix(lower, "http://"), strings.HasPrefix(lower, "https://"):
		client := http.Client{Timeout: 20 * time.Second}
		res, err := client.Get(src)
		if err != nil {
			return nil, false
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return nil, false
		}
		out, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
		return out, err == nil
	}
	return nil, false
}

func (p *uiPicture) natural() (float64, float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return float64(p.w), float64(p.h)
}

func (p *uiPicture) failed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.done && p.pix == nil && p.vector == nil
}

func (b *uiBox) alt() string {
	if len(b.v.Options) > 0 {
		return b.v.Options[0]
	}
	return ""
}

func (p *uiPicture) at(w, h int) []uint8 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if w <= 0 || h <= 0 || p.pix == nil && p.vector == nil {
		return nil
	}
	frame, _ := p.frameNow()
	if p.sized == nil || p.sw != w || p.sh != h || p.shown != frame {
		switch {
		case p.vector != nil:
			p.sized = p.vector.render(w, h)
		case len(p.frames) > 1:
			p.sized = uiResample(p.frames[frame].pix, p.w, p.h, w, h)
		default:
			p.sized = uiResample(p.pix, p.w, p.h, w, h)
		}
		p.sw, p.sh, p.shown = w, h, frame
	}
	return p.sized
}

func (p *uiPicture) moving() time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, left := p.frameNow()
	return left
}

type uiTap struct {
	at int
	w  float32
}

func uiTaps(from, to int) [][]uiTap {
	scale := float64(from) / float64(to)
	reach := math.Max(1, scale)
	out := make([][]uiTap, to)
	for d := range out {
		centre := (float64(d)+0.5)*scale - 0.5
		lo := int(math.Ceil(centre - reach))
		hi := int(math.Floor(centre + reach))
		var taps []uiTap
		sum := float32(0)
		for i := lo; i <= hi; i++ {
			w := float32(1 - math.Abs(float64(i)-centre)/reach)
			if w <= 0 {
				continue
			}
			taps = append(taps, uiTap{min(max(i, 0), from-1), w})
			sum += w
		}
		if sum == 0 {
			taps = []uiTap{{min(max(int(math.Round(centre)), 0), from-1), 1}}
			sum = 1
		}
		for i := range taps {
			taps[i].w /= sum
		}
		out[d] = taps
	}
	return out
}

func uiResample(src []uint8, sw, sh, dw, dh int) []uint8 {
	across, down := uiTaps(sw, dw), uiTaps(sh, dh)
	mid := make([]float32, sh*dw*4)
	for y := 0; y < sh; y++ {
		row := src[y*sw*4 : (y+1)*sw*4]
		for x, taps := range across {
			var c [4]float32
			for _, t := range taps {
				p := row[t.at*4 : t.at*4+4]
				c[0] += float32(p[0]) * t.w
				c[1] += float32(p[1]) * t.w
				c[2] += float32(p[2]) * t.w
				c[3] += float32(p[3]) * t.w
			}
			copy(mid[(y*dw+x)*4:], c[:])
		}
	}
	out := make([]uint8, dh*dw*4)
	for y, taps := range down {
		for x := 0; x < dw; x++ {
			var c [4]float32
			for _, t := range taps {
				p := mid[(t.at*dw+x)*4:]
				c[0] += p[0] * t.w
				c[1] += p[1] * t.w
				c[2] += p[2] * t.w
				c[3] += p[3] * t.w
			}
			o := out[(y*dw+x)*4:]
			for i := range 4 {
				o[i] = uint8(uiClamp(float64(c[i])+0.5, 0, 255))
			}
		}
	}
	return out
}

func (n *uiNative) paintImage(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.rectOf(b)
	if b.pic.failed() {
		s := n.scale
		box := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
		cy := (y0 + y1) / 2
		muted := uiMix(under, n.pal.muted, 1)
		cv.ring(x0+2*s, cy-7*s, x0+14*s, cy+7*s, 1.5*s, n.hairline(), muted, box)
		n.fillPolys(cv, [][]float64{{x0 + 4*s, cy + 5*s, x0 + 8*s, cy, x0 + 12*s, cy + 5*s}}, muted, box)
		n.say(b.font, x0+16*s, cy-b.lineH*s/2+n.lift(b), b.alt(), uiMix(under, b.colour, 1), box)
		return
	}
	w, h := int(x1-x0), int(y1-y0)
	if left := b.pic.moving(); left > 0 {
		if area := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)}); !area.empty() {
			n.anims = append(n.anims, area)
			if n.animDue == 0 || left < n.animDue {
				n.animDue = left
			}
		}
	}
	pix := b.pic.at(w, h)
	if pix == nil {
		return
	}
	cv.blit(pix, w, h, int(x0), int(y0), clip)
}

// Pixels whose colour is already multiplied by their alpha, laid over what is there.
func (cv *uiCanvas) blit(pix []uint8, w, h, left, top int, clip uiClip) {
	r := cv.bounds(clip).and(uiClip{left, top, left + w, top + h})
	if r.empty() || len(pix) < w*h*4 {
		return
	}
	cv.flush()
	for y := r.y0; y < r.y1; y++ {
		row := cv.pix[y*cv.w : (y+1)*cv.w]
		src := pix[(y-top)*w*4:]
		for x := r.x0; x < r.x1; x++ {
			p := src[(x-left)*4 : (x-left)*4+4]
			if p[3] == 0 {
				continue
			}
			keep := uint32(255 - p[3])
			d := row[x]
			rr := uint32(p[0]) + (d>>16&0xff)*keep/255
			gg := uint32(p[1]) + (d>>8&0xff)*keep/255
			bb := uint32(p[2]) + (d&0xff)*keep/255
			row[x] = min(rr, 255)<<16 | min(gg, 255)<<8 | min(bb, 255) | 0xff000000
		}
	}
}

func (n *uiNative) paintIcon(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, _, _ := n.rectOf(b)
	side := int(math.Round(b.font.px * n.scale))
	left := int(math.Round(x0 + (b.padX+b.border)*n.scale))
	top := int(math.Round(y0 + (b.padY+b.border+(b.lineH-b.font.px)/2)*n.scale))
	colour := uiMix(under, b.colour, 1)
	if b.disabled {
		colour = uiMix(under, colour, 0.5)
	}
	if pix := n.iconPixels(b.v.Text, colour, side); pix != nil {
		cv.blit(pix, side, side, left, top, clip)
	}
}

func (n *uiNative) iconPixels(name string, c uiRGBA, side int) []uint8 {
	if side <= 0 {
		return nil
	}
	hex := "#" + strconv.FormatUint(uint64(uiPack(c)&0xffffff)|1<<24, 16)[1:]
	key := name + "|" + hex + "|" + strconv.Itoa(side)
	if pix, ok := n.icons[key]; ok {
		return pix
	}
	if len(n.icons) > 512 {
		n.icons = map[string][]uint8{}
	}
	shape, ok := uiIconShapes[name]
	if !ok {
		shape = `<rect x="3" y="3" width="18" height="18" rx="2"/>`
	}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="` + hex +
		`" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` + shape + `</svg>`
	var pix []uint8
	if v, drawn := uiParseSVG([]byte(svg)); drawn {
		pix = v.render(side, side)
	}
	n.icons[key] = pix
	return pix
}

func (n *uiNative) fillPolys(cv *uiCanvas, polys [][]float64, c uiRGBA, clip uiClip) {
	if c.a == 0 || len(polys) == 0 {
		return
	}
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
	cv.blend(n.cover, r.w, r.h, area.x0, area.y0, c, clip)
}

func uiCircle(cx, cy, radius float64) []float64 {
	if radius <= 0 {
		return nil
	}
	steps := int(math.Ceil(math.Pi / math.Acos(math.Max(-1, 1-0.12/math.Max(radius, 0.12)))))
	steps = min(max(steps, 8), 720)
	out := make([]float64, 0, steps*2)
	for i := 0; i < steps; i++ {
		t := -2 * math.Pi * float64(i) / float64(steps)
		out = append(out, cx+radius*math.Cos(t), cy+radius*math.Sin(t))
	}
	return out
}

func uiStroke(pts []float64, half float64) [][]float64 {
	var polys [][]float64
	count := len(pts) / 2
	if half <= 0 || count == 0 {
		return nil
	}
	for i := 0; i+1 < count; i++ {
		ax, ay, bx, by := pts[2*i], pts[2*i+1], pts[2*i+2], pts[2*i+3]
		length := math.Hypot(bx-ax, by-ay)
		if length == 0 {
			continue
		}
		nx, ny := -(by-ay)/length*half, (bx-ax)/length*half
		polys = append(polys, []float64{ax + nx, ay + ny, bx + nx, by + ny, bx - nx, by - ny, ax - nx, ay - ny})
	}
	for i := 0; i < count; i++ {
		polys = append(polys, uiCircle(pts[2*i], pts[2*i+1], half))
	}
	return polys
}

func (n *uiNative) markColour(attrs []UiAttr, current uiRGBA) uiRGBA {
	paint, ok := uiFind(attrs, "paint")
	if !ok {
		return current
	}
	if c, ok := uiParseColour(paint.Word); ok {
		return c
	}
	if c, ok := n.pal.role(paint.Word); ok {
		return c
	}
	return current
}

func (n *uiNative) paintCanvas(cv *uiCanvas, b *uiBox, clip uiClip, under uiRGBA) {
	x0, y0, x1, y1 := n.rectOf(b)
	box := clip.and(uiClip{int(x0), int(y0), int(x1), int(y1)})
	if box.empty() {
		return
	}
	region := uiNumbers(b.v.Attrs, "region", []float64{0, 0, 100, 100})
	if region[2] <= 0 || region[3] <= 0 {
		region = []float64{0, 0, 100, 100}
	}
	s := math.Min((x1-x0)/region[2], (y1-y0)/region[3])
	ox := x0 + ((x1-x0)-region[2]*s)/2 - region[0]*s
	oy := y0 + ((y1-y0)-region[3]*s)/2 - region[1]*s
	n.paintMarks(cv, b.v.Marks, uiAffine{a: s, d: s, e: ox, f: oy}, uiInk{box: box, under: under, colour: b.colour})
}
