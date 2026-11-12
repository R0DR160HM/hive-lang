// WebP, read in Go: the container, its alpha, and the frames of a moving one.
package hive

import (
	"image"
	"image/color"
	"io"
	"time"
)

func init() {
	image.RegisterFormat("webp", "RIFF????WEBP", uiWebPDecode, uiWebPConfig)
}

type uiWpChunk struct {
	id   string
	data []byte
}

func uiWpU24(b []byte) int { return int(b[0]) | int(b[1])<<8 | int(b[2])<<16 }

func uiWpChunks(b []byte) []uiWpChunk {
	var out []uiWpChunk
	for len(b) >= 8 {
		size := int(uint32(b[4]) | uint32(b[5])<<8 | uint32(b[6])<<16 | uint32(b[7])<<24)
		if size < 0 || size > len(b)-8 {
			size = len(b) - 8
		}
		out = append(out, uiWpChunk{string(b[:4]), b[8 : 8+size]})
		b = b[min(8+size+size&1, len(b)):]
	}
	return out
}

func uiWpFile(body []byte) ([]uiWpChunk, bool) {
	if len(body) < 12 || string(body[:4]) != "RIFF" || string(body[8:12]) != "WEBP" {
		return nil, false
	}
	end := int(uint32(body[4])|uint32(body[5])<<8|uint32(body[6])<<16|uint32(body[7])<<24) + 8
	if end < 12 || end > len(body) {
		end = len(body)
	}
	return uiWpChunks(body[12:end]), true
}

func uiWpFind(chunks []uiWpChunk, id string) []byte {
	for _, c := range chunks {
		if c.id == id {
			return c.data
		}
	}
	return nil
}

func uiWpStill(chunks []uiWpChunk) (*image.NRGBA, error) {
	if data := uiWpFind(chunks, "VP8L"); data != nil {
		pix, w, h, ok := uiVP8LDecode(data, true, 0, 0)
		if !ok {
			return nil, uiWpBroken
		}
		img := image.NewNRGBA(image.Rect(0, 0, w, h))
		for i, p := range pix {
			img.Pix[i*4], img.Pix[i*4+1], img.Pix[i*4+2], img.Pix[i*4+3] = uint8(p>>16), uint8(p>>8), uint8(p), uint8(p>>24)
		}
		return img, nil
	}
	data := uiWpFind(chunks, "VP8 ")
	if data == nil {
		return nil, uiWpBroken
	}
	d, err := uiVP8Decode(data)
	if err != nil {
		return nil, err
	}
	img := image.NewNRGBA(image.Rect(0, 0, d.w, d.h))
	d.rgba(img.Pix, img.Stride)
	if a := uiWpFind(chunks, "ALPH"); len(a) > 0 {
		alpha, ok := uiWpAlpha(a, d.w, d.h)
		if !ok {
			return nil, uiWpBroken
		}
		for i, v := range alpha {
			img.Pix[i*4+3] = v
		}
	}
	return img, nil
}

func uiWpAlpha(data []byte, w, h int) ([]uint8, bool) {
	head := data[0]
	body := data[1:]
	alpha := make([]uint8, w*h)
	switch head & 3 {
	case 0:
		if len(body) < w*h {
			return nil, false
		}
		copy(alpha, body)
	case 1:
		pix, _, _, ok := uiVP8LDecode(body, false, w, h)
		if !ok {
			return nil, false
		}
		for i, p := range pix {
			alpha[i] = uint8(p >> 8)
		}
	default:
		return nil, false
	}
	method := head >> 2 & 3
	for y := 0; y < h && method != 0; y++ {
		row := alpha[y*w : (y+1)*w]
		if y == 0 || method == 1 {
			pred := uint8(0)
			if y > 0 {
				pred = alpha[(y-1)*w]
			}
			for x := range row {
				row[x] += pred
				pred = row[x]
			}
			continue
		}
		prev := alpha[(y-1)*w : y*w]
		if method == 2 {
			for x := range row {
				row[x] += prev[x]
			}
			continue
		}
		left, topLeft := prev[0], prev[0]
		for x := range row {
			top := prev[x]
			left = row[x] + uint8(uiWpClip(int(left)+int(top)-int(topLeft), 255))
			topLeft = top
			row[x] = left
		}
	}
	return alpha, true
}

func uiWebPDecode(r io.Reader) (image.Image, error) {
	body, err := io.ReadAll(io.LimitReader(r, 64<<20))
	if err != nil {
		return nil, err
	}
	chunks, ok := uiWpFile(body)
	if !ok {
		return nil, uiWpBroken
	}
	if x := uiWpFind(chunks, "VP8X"); len(x) >= 10 && x[0]&2 != 0 {
		frames, w, h, ok := uiWpCompose(chunks, 1)
		if !ok {
			return nil, uiWpBroken
		}
		img := image.NewRGBA(image.Rect(0, 0, w, h))
		copy(img.Pix, frames[0].pix)
		return img, nil
	}
	return uiWpStill(chunks)
}

func uiWebPConfig(r io.Reader) (image.Config, error) {
	head := make([]byte, 64)
	n, _ := io.ReadFull(r, head)
	chunks, ok := uiWpFile(head[:n])
	if ok && len(chunks) > 0 {
		c := chunks[0]
		switch {
		case c.id == "VP8X" && len(c.data) >= 10:
			return image.Config{ColorModel: color.NRGBAModel, Width: uiWpU24(c.data[4:]) + 1, Height: uiWpU24(c.data[7:]) + 1}, nil
		case c.id == "VP8L" && len(c.data) >= 5 && c.data[0] == 0x2f:
			b := &uiWpBits{data: c.data, pos: 1}
			w := int(b.read(14)) + 1
			return image.Config{ColorModel: color.NRGBAModel, Width: w, Height: int(b.read(14)) + 1}, nil
		case c.id == "VP8 " && len(c.data) >= 10:
			return image.Config{ColorModel: color.NRGBAModel, Width: int(c.data[6]) | int(c.data[7]&0x3f)<<8,
				Height: int(c.data[8]) | int(c.data[9]&0x3f)<<8}, nil
		}
	}
	return image.Config{}, uiWpBroken
}

func uiWebPFrames(body []byte) ([]uiFrame, int, int, bool) {
	chunks, ok := uiWpFile(body)
	if !ok {
		return nil, 0, 0, false
	}
	if x := uiWpFind(chunks, "VP8X"); len(x) < 10 || x[0]&2 == 0 {
		return nil, 0, 0, false
	}
	return uiWpCompose(chunks, -1)
}

func uiWpCompose(chunks []uiWpChunk, limit int) ([]uiFrame, int, int, bool) {
	x := uiWpFind(chunks, "VP8X")
	w, h := uiWpU24(x[4:])+1, uiWpU24(x[7:])+1
	var anmf [][]byte
	for _, c := range chunks {
		if c.id == "ANMF" && len(c.data) >= 16 {
			anmf = append(anmf, c.data)
		}
	}
	if limit < 0 && len(anmf) < 2 || len(anmf) == 0 || w > 16384 || h > 16384 {
		return nil, 0, 0, false
	}
	if limit > 0 {
		anmf = anmf[:min(limit, len(anmf))]
	}
	if w*h*4*len(anmf) > uiFramesBudget {
		return nil, 0, 0, false
	}
	canvas := make([]uint8, w*h*4)
	var frames []uiFrame
	var dispose [4]int
	for _, f := range anmf {
		for y := dispose[1]; y < dispose[3]; y++ {
			clear(canvas[(y*w+dispose[0])*4 : (y*w+dispose[2])*4])
		}
		dispose = [4]int{}
		fx, fy := 2*uiWpU24(f[0:]), 2*uiWpU24(f[3:])
		ms := uiWpU24(f[12:])
		flags := f[15]
		img, err := uiWpStill(uiWpChunks(f[16:]))
		if err != nil {
			return nil, 0, 0, false
		}
		fw, fh := img.Rect.Dx(), img.Rect.Dy()
		x0, y0, x1, y1 := min(fx, w), min(fy, h), min(fx+fw, w), min(fy+fh, h)
		for y := y0; y < y1; y++ {
			for x := x0; x < x1; x++ {
				s := img.Pix[(y-fy)*img.Stride+(x-fx)*4:]
				d := canvas[(y*w+x)*4:]
				a := uint32(s[3])
				r, g, b := uint32(s[0])*a/255, uint32(s[1])*a/255, uint32(s[2])*a/255
				if flags&2 != 0 || a == 255 {
					d[0], d[1], d[2], d[3] = uint8(r), uint8(g), uint8(b), uint8(a)
					continue
				}
				keep := 255 - a
				d[0] = uint8(r + (uint32(d[0])*keep+127)/255)
				d[1] = uint8(g + (uint32(d[1])*keep+127)/255)
				d[2] = uint8(b + (uint32(d[2])*keep+127)/255)
				d[3] = uint8(a + (uint32(d[3])*keep+127)/255)
			}
		}
		if flags&1 != 0 {
			dispose = [4]int{x0, y0, x1, y1}
		}
		delay := time.Duration(ms) * time.Millisecond
		if ms <= 10 {
			delay = 100 * time.Millisecond
		}
		frames = append(frames, uiFrame{pix: append([]uint8(nil), canvas...), delay: delay})
	}
	return frames, w, h, true
}
