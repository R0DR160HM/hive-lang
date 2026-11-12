// Pictures that move.
package hive

import (
	"bytes"
	"image"
	"image/draw"
	"image/gif"
	"time"
)

const uiFramesBudget = 192 << 20

func uiDecodeFrames(body []byte) ([]uiFrame, int, int, bool) {
	if bytes.HasPrefix(body, []byte("GIF8")) {
		return uiGifFrames(body)
	}
	if len(body) > 12 && string(body[0:4]) == "RIFF" && string(body[8:12]) == "WEBP" {
		return uiWebPFrames(body)
	}
	return nil, 0, 0, false
}

func uiGifFrames(body []byte) ([]uiFrame, int, int, bool) {
	all, err := gif.DecodeAll(bytes.NewReader(body))
	if err != nil || len(all.Image) < 2 {
		return nil, 0, 0, false
	}
	w, h := all.Config.Width, all.Config.Height
	if w <= 0 || h <= 0 || w*h*4*len(all.Image) > uiFramesBudget {
		return nil, 0, 0, false
	}
	canvas := image.NewRGBA(image.Rect(0, 0, w, h))
	frames := make([]uiFrame, 0, len(all.Image))
	for i, img := range all.Image {
		var before []uint8
		disposal := byte(0)
		if i < len(all.Disposal) {
			disposal = all.Disposal[i]
		}
		if disposal == gif.DisposalPrevious {
			before = append([]uint8(nil), canvas.Pix...)
		}
		draw.Draw(canvas, img.Bounds(), img, img.Bounds().Min, draw.Over)
		delay := 100 * time.Millisecond
		if i < len(all.Delay) && all.Delay[i] > 1 {
			delay = time.Duration(all.Delay[i]) * 10 * time.Millisecond
		}
		frames = append(frames, uiFrame{pix: append([]uint8(nil), canvas.Pix...), delay: delay})
		switch disposal {
		case gif.DisposalBackground:
			draw.Draw(canvas, img.Bounds(), image.Transparent, image.Point{}, draw.Src)
		case gif.DisposalPrevious:
			copy(canvas.Pix, before)
		}
	}
	return frames, w, h, true
}

func (p *uiPicture) frameNow() (int, time.Duration) {
	if len(p.frames) < 2 {
		return 0, 0
	}
	total := time.Duration(0)
	for _, f := range p.frames {
		total += f.delay
	}
	at := time.Since(p.start) % total
	for i, f := range p.frames {
		if at < f.delay {
			return i, f.delay - at
		}
		at -= f.delay
	}
	return 0, p.frames[0].delay
}
