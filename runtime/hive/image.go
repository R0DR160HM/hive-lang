// The Go for hive.image: a picture read from the bytes of a file, and the same
// picture at another size. WebP is read by the decoder a window that draws
// itself uses, which registers itself with the image package.
package hive

import (
	"bytes"
	"errors"
	"image"
	"image/draw"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"strconv"
)

// ImagePicture is what the program reads as hive.image.Picture: Pixels holds
// four bytes a pixel — red, green, blue and alpha, unmultiplied — row by row
// from the top left.
type ImagePicture struct {
	Width  int
	Height int
	Pixels []uint8
}

type ImageImageError struct {
	Message string
}

func (e ImageImageError) Error() string { return "hive: image: " + e.Message }

// More than this is refused before it is decoded: a file of a few kilobytes can
// claim a size that would take every byte of memory there is.
const imageMostPixels = 100_000_000

func ImageDecode(data string) Result[ImagePicture, ImageImageError] {
	fail := func(message string) Result[ImagePicture, ImageImageError] {
		return Err[ImagePicture, ImageImageError](ImageImageError{Message: message})
	}
	size, _, err := image.DecodeConfig(bytes.NewReader([]byte(data)))
	if errors.Is(err, image.ErrFormat) {
		return fail("not a PNG, JPEG, GIF or WebP picture")
	}
	if err != nil {
		return fail(err.Error())
	}
	if size.Width*size.Height > imageMostPixels {
		return fail("a picture of " + strconv.Itoa(size.Width) + "×" + strconv.Itoa(size.Height) + " is more than 100 million pixels")
	}
	decoded, _, err := image.Decode(bytes.NewReader([]byte(data)))
	if err != nil {
		return fail(err.Error())
	}
	b := decoded.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(out, out.Bounds(), decoded, b.Min, draw.Src)
	return Ok[ImagePicture, ImageImageError](ImagePicture{Width: b.Dx(), Height: b.Dy(), Pixels: out.Pix})
}

// ImageScale is the picture at exactly width by height. Each new pixel is the
// average of the ones it covers, weighted by how opaque each is, so a shrunk
// picture keeps its colours and an edge against transparency does not darken;
// a grown one repeats them.
func ImageScale(p ImagePicture, width int, height int) ImagePicture {
	if width <= 0 || height <= 0 || p.Width <= 0 || p.Height <= 0 {
		return ImagePicture{Pixels: []uint8{}}
	}
	at := func(x, y, channel int) int {
		i := (y*p.Width+x)*4 + channel
		if i < len(p.Pixels) {
			return int(p.Pixels[i])
		}
		return 0
	}
	out := make([]uint8, width*height*4)
	for y := 0; y < height; y++ {
		y0, y1 := y*p.Height/height, (y+1)*p.Height/height
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < width; x++ {
			x0, x1 := x*p.Width/width, (x+1)*p.Width/width
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, b, a, n int
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					alpha := at(sx, sy, 3)
					r += at(sx, sy, 0) * alpha
					g += at(sx, sy, 1) * alpha
					b += at(sx, sy, 2) * alpha
					a += alpha
					n++
				}
			}
			i := (y*width + x) * 4
			if a > 0 {
				out[i], out[i+1], out[i+2] = uint8(r/a), uint8(g/a), uint8(b/a)
			}
			out[i+3] = uint8(a / n)
		}
	}
	return ImagePicture{Width: width, Height: height, Pixels: out}
}
