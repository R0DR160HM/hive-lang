package hive

import (
	"bytes"
	"embed"
	"encoding/base64"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Eight by four: the left half opaque red, the right half half-transparent blue.
const (
	webpLossless = "UklGRiAAAABXRUJQVlA4TBMAAAAvB8AAEA8Q+z//D/yPCoWP6H8AAA=="
	webpLossy    = "UklGRoAAAABXRUJQVlA4WAoAAAAQAAAABwAAAwAAQUxQSAwAAAABD/DA/4iIUPiI/gdWUDggTgAAADADAJ0BKggABAAAwBIlqAJ0ugH4AUYD8AK7/3AAEYHcrMAA/v2ev/5zIbf/u2RJgpE/66J+2yJMFIn/9aOf/jUsoSOVzf41LKEjl94AAA=="
)

func halves() *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, 8, 4))
	for y := 0; y < 4; y++ {
		for x := 0; x < 8; x++ {
			if x < 4 {
				img.SetNRGBA(x, y, color.NRGBA{255, 0, 0, 255})
			} else {
				img.SetNRGBA(x, y, color.NRGBA{0, 0, 255, 128})
			}
		}
	}
	return img
}

func pixelOf(p ImagePicture, x, y int) [4]int {
	i := (y*p.Width + x) * 4
	return [4]int{int(p.Pixels[i]), int(p.Pixels[i+1]), int(p.Pixels[i+2]), int(p.Pixels[i+3])}
}

func near(got [4]int, want [4]int, slack int) bool {
	for i := range got {
		if got[i] < want[i]-slack || got[i] > want[i]+slack {
			return false
		}
	}
	return true
}

// Every format reads into the same four bytes a pixel, unmultiplied, whatever
// the file kept them as.
func TestEveryFormatReadsIntoTheSamePixels(t *testing.T) {
	var asPng, asJpeg, asGif bytes.Buffer
	png.Encode(&asPng, halves())
	jpeg.Encode(&asJpeg, halves(), &jpeg.Options{Quality: 100})
	gif.Encode(&asGif, halves(), nil)
	lossless, _ := base64.StdEncoding.DecodeString(webpLossless)
	lossy, _ := base64.StdEncoding.DecodeString(webpLossy)
	for _, c := range []struct {
		name        string
		data        []byte
		right       [4]int
		slack       int
		alphaIsKept bool
	}{
		{"png", asPng.Bytes(), [4]int{0, 0, 255, 128}, 0, true},
		{"webp lossless", lossless, [4]int{0, 0, 255, 128}, 0, true},
		{"webp lossy", lossy, [4]int{0, 0, 255, 128}, 24, true},
		{"jpeg", asJpeg.Bytes(), [4]int{0, 0, 255, 255}, 24, false},
		{"gif", asGif.Bytes(), [4]int{0, 0, 255, 255}, 24, false},
	} {
		got := ImageDecode(string(c.data))
		p, ok := okOf(got)
		if !ok {
			t.Errorf("%s: %+v", c.name, got)
			continue
		}
		if p.Width != 8 || p.Height != 4 || len(p.Pixels) != 8*4*4 {
			t.Errorf("%s: %d by %d, %d bytes", c.name, p.Width, p.Height, len(p.Pixels))
			continue
		}
		if left := pixelOf(p, 1, 1); !near(left, [4]int{255, 0, 0, 255}, c.slack) {
			t.Errorf("%s: the left half is %v", c.name, left)
		}
		if right := pixelOf(p, 6, 2); c.alphaIsKept && !near(right, c.right, c.slack) {
			t.Errorf("%s: the right half is %v", c.name, right)
		}
	}
}

func TestWhatIsNoPictureSaysSo(t *testing.T) {
	if why, ok := errOf(ImageDecode("not a picture at all")); !ok || why.Message != "not a PNG, JPEG, GIF or WebP picture" {
		t.Errorf("read %+v", why)
	}
	var asPng bytes.Buffer
	png.Encode(&asPng, halves())
	if why, ok := errOf(ImageDecode(asPng.String()[:40])); !ok || why.Message == "" {
		t.Errorf("a cut-off file read as %+v", why)
	}
}

// A file a few bytes long can claim any size; one past the limit is refused
// before anything is allocated for it.
func TestAPictureTooBigIsRefusedUnread(t *testing.T) {
	var asPng bytes.Buffer
	png.Encode(&asPng, halves())
	claim := []byte(asPng.String())
	copy(claim[16:24], []byte{0, 0, 0x4e, 0x20, 0, 0, 0x4e, 0x20}) // 20000 by 20000
	binary.BigEndian.PutUint32(claim[29:33], crc32.ChecksumIEEE(claim[12:29]))
	if why, ok := errOf(ImageDecode(string(claim))); !ok || !strings.Contains(why.Message, "100 million pixels") {
		t.Errorf("read %+v", why)
	}
}

// Shrinking averages what each new pixel covers, weighted by how opaque each
// is; growing repeats. A size of nothing is a picture of nothing.
func TestScalingAveragesAndRepeats(t *testing.T) {
	var asPng bytes.Buffer
	png.Encode(&asPng, halves())
	p, _ := okOf(ImageDecode(asPng.String()))

	half := ImageScale(p, 2, 1)
	if got := pixelOf(half, 0, 0); got != [4]int{255, 0, 0, 255} {
		t.Errorf("the left of two is %v", got)
	}
	if got := pixelOf(half, 1, 0); got != [4]int{0, 0, 255, 128} {
		t.Errorf("the right of two is %v", got)
	}
	one := ImageScale(p, 1, 1)
	if got := pixelOf(one, 0, 0); !near(got, [4]int{170, 0, 85, 191}, 1) {
		t.Errorf("one pixel is %v", got)
	}
	big := ImageScale(p, 16, 8)
	if big.Width != 16 || big.Height != 8 || pixelOf(big, 15, 7) != [4]int{0, 0, 255, 128} {
		t.Errorf("doubled: %d by %d, corner %v", big.Width, big.Height, pixelOf(big, 15, 7))
	}
	if none := ImageScale(p, 0, 3); none.Width != 0 || len(none.Pixels) != 0 {
		t.Errorf("nothing is %+v", none)
	}
}

func TestWhereTheProgramIs(t *testing.T) {
	here, _ := os.Getwd()
	if got, _ := okOf(FileWorkingDirectory()); got != filepath.ToSlash(here) || strings.Contains(got, "\\") {
		t.Errorf("the working directory is %q", got)
	}
	me, _ := os.Executable()
	if got, _ := okOf(FileExecutable()); got != filepath.ToSlash(me) {
		t.Errorf("the executable is %q", got)
	}
	if got, ok := okOf(FileHome()); !ok || !filepath.IsAbs(filepath.FromSlash(got)) {
		t.Errorf("home is %q", got)
	}
	if !FileIsDir(".") || FileIsDir(me) || FileIsDir("no such thing") {
		t.Error("isDir is wrong about a folder, a file or nothing")
	}
}

func TestAnAssetIsReadFromWhatTheBuildEmbedded(t *testing.T) {
	was := programAssets
	defer func() { programAssets = was }()

	programAssets = nil
	if why, ok := errOf(FileAsset("logo.png")); !ok || why.Reason != "NotFound" || why.Path != "logo.png" {
		t.Errorf("with no assets: %+v", why)
	}
	var empty embed.FS
	assetsAre(empty)
	for _, path := range []string{"logo.png", "../go.mod", "./logo.png"} {
		if why, ok := errOf(FileAsset(path)); !ok || why.Reason != "NotFound" {
			t.Errorf("%q: %+v", path, why)
		}
	}
}
