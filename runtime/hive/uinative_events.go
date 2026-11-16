// What any widget may hear besides a click: the pointer arriving, pressing, moving and
// letting go over it, the focus coming and going, the wheel, a scroll, its own size,
// something carried onto it, and files dropped onto it.
package hive

import (
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type uiCarry struct {
	path    string
	word    string
	x, y    float64
	at      [2]float64
	started bool
}

// The innermost widget under a point that hears an event, disabled or not, as the page finds one.
func (n *uiNative) hearer(x, y float64, kind string) *uiBox {
	chain := n.under(x, y)
	for i := len(chain) - 1; i >= 0; i-- {
		if _, ok := chain[i].attr(kind); ok {
			return chain[i]
		}
	}
	return nil
}

// Where a point is on a widget: in a canvas's own units, and elsewhere in pixels from its corner.
func (n *uiNative) localOf(b *uiBox, x, y float64) string {
	top, tall := b.y+b.margin, b.h-2*b.margin
	if b.kind == "canvas" {
		region := uiNumbers(b.v.Attrs, "region", []float64{0, 0, 100, 100})
		if region[2] <= 0 || region[3] <= 0 {
			region = []float64{0, 0, 100, 100}
		}
		s := math.Min(b.w/region[2], tall/region[3])
		if !(s > 0) {
			return "0,0"
		}
		ox := b.x + (b.w-region[2]*s)/2 - region[0]*s
		oy := top + (tall-region[3]*s)/2 - region[1]*s
		return uiNumber((x-ox)/s) + "," + uiNumber((y-oy)/s)
	}
	return uiNumber(x-b.x) + "," + uiNumber(y-top)
}

func (n *uiNative) crossed(x, y float64, inside bool) {
	var chain []*uiBox
	if inside {
		for _, b := range n.under(x, y) {
			_, enters := b.attr("onEnter")
			_, leaves := b.attr("onLeave")
			if enters || leaves {
				chain = append(chain, b)
			}
		}
	}
	over := map[string]bool{}
	for _, b := range chain {
		over[b.path] = true
	}
	kept := n.entered[:0]
	var left []string
	for _, path := range n.entered {
		if over[path] {
			kept = append(kept, path)
		} else {
			left = append(left, path)
		}
	}
	for i := len(left) - 1; i >= 0; i-- {
		if b, ok := n.boxes[left[i]]; ok {
			n.post(b.v.Attrs, "leave", "", 0)
		}
	}
	was := map[string]bool{}
	for _, path := range kept {
		was[path] = true
	}
	n.entered = kept
	for i := len(chain) - 1; i >= 0; i-- {
		if b := chain[i]; !was[b.path] {
			n.post(b.v.Attrs, "enter", "", 0)
		}
	}
	n.entered = n.entered[:0]
	for _, b := range chain {
		n.entered = append(n.entered, b.path)
	}
}

func uiAncestry(path string) []string {
	if path == "" {
		return nil
	}
	parts := strings.Split(path, "/")
	out := make([]string, len(parts))
	for i := range parts {
		out[i] = strings.Join(parts[:i+1], "/")
	}
	return out
}

func uiWithin(path, ancestor string) bool {
	return path == ancestor || strings.HasPrefix(path, ancestor+"/")
}

func (n *uiNative) focusMoved() {
	if n.focus == n.focusSaid {
		return
	}
	was, now := n.focusSaid, n.focus
	n.focusSaid = now
	if was != "" {
		chain := uiAncestry(was)
		for i := len(chain) - 1; i >= 0; i-- {
			if now != "" && uiWithin(now, chain[i]) {
				continue
			}
			if b, ok := n.boxes[chain[i]]; ok {
				if _, heard := b.attr("onBlur"); heard {
					n.post(b.v.Attrs, "blur", "", 0)
				}
			}
		}
	}
	if now != "" {
		chain := uiAncestry(now)
		for i := len(chain) - 1; i >= 0; i-- {
			if was != "" && uiWithin(was, chain[i]) {
				continue
			}
			if b, ok := n.boxes[chain[i]]; ok {
				if _, heard := b.attr("onFocus"); heard {
					n.post(b.v.Attrs, "focus", "", 0)
				}
			}
		}
	}
}

func (n *uiNative) pressed(x, y float64) {
	if n.popup != nil && n.inPopup(x, y) {
		return
	}
	if b := n.hearer(x, y, "onPress"); b != nil {
		n.post(b.v.Attrs, "press", n.localOf(b, x, y), 0)
	}
	n.releasing, n.pointing, n.pressing = "", "", true
	if b := n.hearer(x, y, "onRelease"); b != nil {
		n.releasing = b.path
	}
	if b := n.hearer(x, y, "onPoint"); b != nil {
		n.pointing = b.path
	}
	n.carrying = nil
	if b := n.hearer(x, y, "carry"); b != nil {
		if t := n.target(x, y); t == nil || !t.editable() {
			word, _ := b.attr("carry")
			n.carrying = &uiCarry{path: b.path, word: word.Word, x: x, y: y, at: [2]float64{x, y}}
		}
	}
}

// Whether moving the pointer carried something, which leaves nothing else to do with the move.
func (n *uiNative) pointed(x, y float64) bool {
	if n.popup != nil && n.inPopup(x, y) {
		return false
	}
	n.crossed(x, y, true)
	path := n.pointing
	if !n.pressing || path == "" {
		path = ""
		if b := n.hearer(x, y, "onPoint"); b != nil {
			path = b.path
		}
	}
	if b, ok := n.boxes[path]; ok {
		if said := path + "@" + n.localOf(b, x, y); said != n.pointSaid {
			n.pointSaid = said
			_, value, _ := strings.Cut(said, "@")
			n.post(b.v.Attrs, "point", value, 0)
		}
	}
	c := n.carrying
	if c == nil {
		return false
	}
	if !c.started && math.Hypot(x-c.x, y-c.y) > 4 {
		c.started = true
		n.sel, n.selecting, n.dragging = nil, false, false
	}
	c.at = [2]float64{x, y}
	return c.started
}

// Whether letting go put down something carried, which is then all the release did.
func (n *uiNative) released(x, y float64) bool {
	n.pressing = false
	if b, ok := n.boxes[n.releasing]; ok {
		n.post(b.v.Attrs, "release", n.localOf(b, x, y), 0)
	}
	n.releasing, n.pointing = "", ""
	c := n.carrying
	n.carrying = nil
	if c == nil || !c.started {
		return false
	}
	if to := n.hearer(x, y, "onDrop"); to != nil {
		n.post(to.v.Attrs, "drop", c.word, 0)
	}
	n.press = ""
	return true
}

func (n *uiNative) paintCarried(cv *uiCanvas, all uiClip) {
	c := n.carrying
	if c == nil || !c.started {
		return
	}
	b, ok := n.boxes[c.path]
	if !ok {
		return
	}
	dx, dy := c.at[0]-c.x, c.at[1]-c.y
	uiShift(b, dx, dy)
	was := b.opacity
	b.opacity = was * 0.6
	n.paintBox(cv, b, all, n.pal.bg)
	b.opacity = was
	uiShift(b, -dx, -dy)
}

func (n *uiNative) wheeled(x, y, lines float64, sideways bool) bool {
	b := n.hearer(x, y, "onWheel")
	if b == nil {
		return false
	}
	dx, dy := 0.0, -lines*100
	if sideways {
		dx, dy = dy, 0
	}
	n.post(b.v.Attrs, "wheel", uiNumber(dx)+","+uiNumber(dy), 0)
	return true
}

// After a layout: a scroll that moved, and a size that changed, are told to whoever hears them.
func (n *uiNative) reported() {
	paths := make([]string, 0, len(n.boxes))
	for path := range n.boxes {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	seen := map[string]bool{}
	for _, path := range paths {
		b := n.boxes[path]
		if _, ok := b.attr("onScroll"); ok && b.scroll != "" {
			seen["s"+path] = true
			at := n.scrolls[path]
			said := strconv.Itoa(int(math.Round(at[0]))) + "," + strconv.Itoa(int(math.Round(at[1])))
			if was, known := n.said["s"+path]; !known || was != said {
				n.said["s"+path] = said
				if known {
					n.post(b.v.Attrs, "scroll", said, 0)
				}
			}
		}
		if _, ok := b.attr("onSize"); ok && b.kind != "scene" {
			seen["z"+path] = true
			said := strconv.Itoa(int(math.Round(b.w))) + "," + strconv.Itoa(int(math.Round(b.h-2*b.margin)))
			if n.said["z"+path] != said {
				n.said["z"+path] = said
				n.post(b.v.Attrs, "size", said, 0)
			}
		}
	}
	for key := range n.said {
		if !seen[key] {
			delete(n.said, key)
		}
	}
	kept := n.entered[:0]
	for _, path := range n.entered {
		if _, ok := n.boxes[path]; ok {
			kept = append(kept, path)
		}
	}
	n.entered = kept
}

// Files the desktop dropped on the window, read off the window's thread and told to the widget under them.
func (n *uiNative) filesDropped(x, y float64, paths []string) bool {
	n.layout()
	b := n.hearer(x/n.scale, y/n.scale, "onFile")
	if b == nil {
		return false
	}
	attrs := b.v.Attrs
	go n.sendFiles(attrs, paths)
	return true
}

func (n *uiNative) sendFiles(attrs []UiAttr, paths []string) {
	for _, path := range paths {
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		n.post(attrs, "file", uiFileValue(filepath.Base(path), body), 0)
	}
}
