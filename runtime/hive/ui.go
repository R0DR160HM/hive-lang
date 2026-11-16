// The Go for `hive.ui`: a window is a `hive.syslink` service with a page in front
// of it, spawned exactly as `spawn` spawns one. What this module adds is the render
// after each turn and the socket that carries it.
// The user interface module (hive.ui).
//
// A view is a value: a tree of widgets built by the constructors below, with no
// handle to hold and nothing to mutate. What paints it is decided separately —
// UiHtml turns a tree into HTML for an ordinary web server, UiWindow serves the
// same tree to a window and folds the events back through the program's update.
//
// The tree is deliberately not HTML. Every widget is one of a closed set and
// every attribute a semantic token rather than a CSS value, which is what lets
// one view render as a desktop window, a served page, or somewhere with no DOM.
//
// ---------------------------------------------------------------------------
// The tree
// ---------------------------------------------------------------------------
package hive

import (
	"embed"
	"encoding/base64"
	"fmt"
	"hash/fnv"
	"hash/maphash"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// UiView is one node. Kind names the widget; which of the payload fields
// carries anything depends on it.
//
// Leaf payloads. A widget reads the one its kind gives meaning to.
type UiView struct {
	Kind     string
	Attrs    []UiAttr
	Children []UiView
	Text     string
	Rows     Table
	Options  []string
	Flag     bool
	Marks    []UiMark

	// A scene only: one more entry than there are shapes, so shape i's record
	// is Text[Cuts[i]:Cuts[i+1]]. It is what lets a frame carry a few slots.
	Cuts []int32
}

// UiAttr is one attribute. Layout and styling attributes carry a number, a
// string or an enum tag; the event attributes carry the message a widget hands
// back, either directly or as a function of what the user did.
//
// Several numbers at once: a position, a rotation, a heading. The scene's
// attributes, and the only ones carrying more than one — nothing in this
// file knows what they mean. hive/ui_scene.go builds and reads them back.
type UiAttr struct {
	Kind string
	Num  int

	// A placeholder, a hint, a track's path — or an enumeration's tag. Which it
	// is, is which attribute this is: `uiStr` and `uiEnum` build it and no
	// attribute is built by both, so two fields only ever held one string.
	Word string
	Flag bool
	Nums []float64

	// What an attribute carrying a message or a handler carries, held to one
	// side. Seven fields that only an event ever sets were seven fields every
	// attribute paid for: a scene's every `at`, `turn` and `paint` is one of
	// these, and none of them is an event. One pointer instead took the
	// attribute from a hundred and fifty-two bytes to ninety-six, and a world
	// of eight hundred shapes from four hundred and eighty-nine kilobytes a
	// frame to three hundred and thirty-five.
	heard *uiHeard
}

type uiHeard struct {
	Msg    any
	FnStr  func(string) any
	FnInt  func(int) any
	FnBool func(bool) any
	FnLook func(float64, float64) any
	FnPad  func(int, string, float64) any
	FnSize func(int, int) any
	FnEdit func(int, int, string) any
	FnDrag func(int, int, bool) any
	FnFile func(string, string) any
	FnHit  func(int, float64, float64, float64) any
	Picks  any
}

// What is under a point of a scene; set by the scene's own file, so a program without one carries none of it.
var uiScenePicker func(attrs []UiAttr, value string) (int, float64, float64, float64)

func uiNode(kind string, attrs []UiAttr, children []UiView) UiView {
	return UiView{Kind: kind, Attrs: attrs, Children: children}
}

// --- Layout -----------------------------------------------------------------
func UiRow(attrs []UiAttr, children []UiView) UiView {
	return uiNode("row", attrs, children)
}

func UiColumn(attrs []UiAttr, children []UiView) UiView {
	return uiNode("column", attrs, children)
}

func UiSpacer() UiView { return UiView{Kind: "spacer"} }

// An overlay is drawn above everything else rather than in the flow, which is
// why it is a widget of its own rather than a container with an attribute.
func UiOverlay(attrs []UiAttr, child UiView) UiView {
	return uiNode("overlay", attrs, []UiView{child})
}

// --- Content ----------------------------------------------------------------
func UiText(attrs []UiAttr, content string) UiView {
	return UiView{Kind: "text", Attrs: attrs, Text: content}
}

// alt is a parameter rather than an attribute because an attribute is
// optional by construction and a description of an image is not.
func UiImage(attrs []UiAttr, src string, alt string) UiView {
	return UiView{Kind: "image", Attrs: attrs, Text: src, Options: []string{alt}}
}

func UiIconOf(attrs []UiAttr, name UiIcon) UiView {
	return UiView{Kind: "icon", Attrs: attrs, Text: string(name)}
}

// A link is the one widget that acts without an event: an anchor needs no
// socket, no handler and no state, which lets a page rendered as text still be
// navigated. href is a parameter rather than an attribute because a link with
// nowhere to go is not worth making easy to write.
//
// --- The plane ----------------------------------------------------------------
func UiLink(attrs []UiAttr, href string, label string) UiView {
	return UiView{Kind: "link", Attrs: attrs, Text: label, Options: []string{href}}
}

// UiMark is one thing on a canvas: the same arrangement UiView and UiShape use,
// and for the same reason — a mark is a value with nothing behind it.
//
// A mark is deliberately not a UiView and not a UiShape. Three closed sets,
// three meanings, and keeping them apart is what makes a button on a canvas
// something the compiler refuses rather than something the renderer drops.
type UiMark struct {
	Kind  string
	Attrs []UiAttr
	Nums  []float64
	Text  string
	Marks []UiMark
}

// A filled circle: a car on a map, a point on a plot, a bulb on a dial.
func UiDot(attrs []UiAttr, x float64, y float64, radius float64) UiMark {
	return UiMark{Kind: "dot", Attrs: attrs, Nums: []float64{x, y, radius}}
}

// A rectangle, from its middle rather than from a corner — because everything
// else on a canvas is placed by where it is, and one thing placed by where its
// corner is would be the one that is always half a width out.
func UiBar(attrs []UiAttr, x float64, y float64, width float64, height float64) UiMark {
	return UiMark{Kind: "bar", Attrs: attrs, Nums: []float64{x, y, width, height}}
}

// A line through every place given, as x, y, x, y. Thick is how wide it is
// drawn, in the canvas's units.
func UiPath(attrs []UiAttr, points []float64) UiMark {
	return UiMark{Kind: "path", Attrs: attrs, Nums: points}
}

// The same places, filled: the area a road encloses, a sector of a dial, a
// country on a map.
func UiPatch(attrs []UiAttr, points []float64) UiMark {
	return UiMark{Kind: "patch", Attrs: attrs, Nums: points}
}

// Words centred on a place, as tall as it says — in the canvas's units like
// everything else, so words on a map grow with the map rather than staying the
// size of the page's type.
func UiWords(attrs []UiAttr, x float64, y float64, height float64, text string) UiMark {
	return UiMark{Kind: "words", Attrs: attrs, Nums: []float64{x, y, height}, Text: text}
}

// UiCanvas is the widget. Unlike a scene it keeps its payload in the document:
// a canvas draws a few hundred numbers where a world is a few thousand, and a
// picture arriving with its page needs no second channel and cannot lag it.
func UiCanvas(attrs []UiAttr, marks []UiMark) UiView {
	return UiView{Kind: "canvas", Attrs: attrs, Marks: marks}
}

func UiOval(attrs []UiAttr, x float64, y float64, width float64, height float64) UiMark {
	return UiMark{Kind: "oval", Attrs: attrs, Nums: []float64{x, y, width, height}}
}

func UiArc(attrs []UiAttr, x float64, y float64, radius float64, from float64, to float64) UiMark {
	return UiMark{Kind: "arc", Attrs: attrs, Nums: []float64{x, y, radius, from, to}}
}

func UiWedge(attrs []UiAttr, x float64, y float64, radius float64, from float64, to float64) UiMark {
	return UiMark{Kind: "wedge", Attrs: attrs, Nums: []float64{x, y, radius, from, to}}
}

func UiCurve(attrs []UiAttr, points []float64) UiMark {
	return UiMark{Kind: "curve", Attrs: attrs, Nums: points}
}

// The outer mark comes first, its holes after it.
func UiCutout(attrs []UiAttr, outer UiMark, holes []UiMark) UiMark {
	return UiMark{Kind: "cutout", Attrs: attrs, Marks: append([]UiMark{outer}, holes...)}
}

func UiSymbol(attrs []UiAttr, x float64, y float64, angle float64, size float64, marks []UiMark) UiMark {
	return UiMark{Kind: "symbol", Attrs: attrs, Nums: []float64{x, y, angle, size}, Marks: marks}
}

func UiPicture(attrs []UiAttr, src string, x float64, y float64, width float64, height float64) UiMark {
	return UiMark{Kind: "picture", Attrs: attrs, Text: src, Nums: []float64{x, y, width, height}}
}

func UiAttrEdge(v UiTone) UiAttr { return uiEnum("edge", string(v)) }

func UiAttrDash(on float64, off float64) UiAttr {
	return uiNums("dash", []float64{math.Max(uiFinite(on), 0), math.Max(uiFinite(off), 0)})
}

func UiAttrCrop(x float64, y float64, width float64, height float64) UiAttr {
	return uiNums("crop", []float64{uiFinite(x), uiFinite(y), math.Max(uiFinite(width), 0), math.Max(uiFinite(height), 0)})
}

func uiFinite(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return v
}

// How wide words are on a canvas, in the units their height is in. Every renderer sets them to this width,
// whatever face it has, so the answer is exact everywhere.
func UiMeasure(words string, height float64) float64 {
	total := 0.0
	for _, r := range words {
		total += float64(uiWordsAdvance(r))
	}
	return total / 1000 * uiFinite(height)
}

// Advances in thousandths of the height, from the metrics Arial and Liberation Sans share.
func uiWordsAdvance(r rune) int {
	switch {
	case r >= 0x20 && r <= 0x17F:
		return int(uiWordsWidth[r-0x20])
	case r < 0x20, r >= 0x300 && r <= 0x36F, r == 0x200B, r == 0x200C, r == 0x200D, r == 0xFEFF:
		return 0
	case r >= 0x1100 && r <= 0x115F, r >= 0x2E80 && r <= 0xA4CF, r >= 0xAC00 && r <= 0xD7A3,
		r >= 0xF900 && r <= 0xFAFF, r >= 0xFE30 && r <= 0xFE4F, r >= 0xFF00 && r <= 0xFF60,
		r >= 0xFFE0 && r <= 0xFFE6, r >= 0x1F300 && r <= 0x1FAFF, r >= 0x20000 && r <= 0x3FFFD:
		return 1000
	}
	return 556
}

var uiWordsWidth = [...]uint16{
	278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
	556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
	1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
	667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
	333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
	556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 552,
	400, 549, 333, 333, 333, 576, 537, 333, 333, 333, 365, 556, 834, 834, 834, 611,
	667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
	722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
	556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278,
	556, 556, 556, 556, 556, 556, 556, 549, 611, 556, 556, 556, 556, 500, 556, 500,
	667, 556, 667, 556, 667, 556, 722, 500, 722, 500, 722, 500, 722, 500, 722, 615,
	722, 556, 667, 556, 667, 556, 667, 556, 667, 556, 667, 556, 778, 556, 778, 556,
	778, 556, 778, 556, 722, 556, 722, 556, 278, 278, 278, 278, 278, 278, 278, 222,
	278, 278, 735, 444, 500, 222, 667, 500, 500, 556, 222, 556, 222, 556, 292, 556,
	334, 556, 222, 722, 556, 722, 556, 722, 556, 604, 723, 556, 778, 556, 778, 556,
	778, 556, 1000, 944, 722, 333, 722, 333, 722, 333, 667, 500, 667, 500, 667, 500,
	667, 500, 611, 278, 611, 375, 611, 278, 722, 556, 722, 556, 722, 556, 722, 556,
	722, 556, 722, 556, 944, 722, 667, 500, 667, 611, 500, 611, 500, 611, 500, 222,
}

// A code editor's runs are marks of its own: the same record, carried where a
// canvas carries its marks, so nothing that copies or compares a view needs to
// know there are two. Nums holds the offsets and Text the tone.
type UiRun = UiMark

func UiCode(attrs []UiAttr, text string, runs []UiRun) UiView {
	return UiView{Kind: "code", Attrs: attrs, Text: text, Marks: runs}
}

func uiRunOf(kind string, from int, to int, tone UiTone) UiRun {
	return UiMark{Kind: kind, Nums: []float64{float64(from), float64(to)}, Text: string(tone)}
}

func UiInk(from int, to int, tone UiTone) UiRun       { return uiRunOf("ink", from, to, tone) }
func UiShade(from int, to int, tone UiTone) UiRun     { return uiRunOf("shade", from, to, tone) }
func UiSquiggle(from int, to int, tone UiTone) UiRun  { return uiRunOf("squiggle", from, to, tone) }
func UiMarker(line int, tone UiTone) UiRun            { return uiRunOf("marker", line, line, tone) }
func UiUnderline(from int, to int, tone UiTone) UiRun { return uiRunOf("underline", from, to, tone) }
func UiBand(line int, tone UiTone) UiRun              { return uiRunOf("band", line, line, tone) }
func UiNote(line int, text string, tone UiTone) UiRun {
	r := uiRunOf("note", line, line, tone)
	r.Attrs = []UiAttr{uiStr("note", text)}
	return r
}

func uiNoteText(r UiRun) string {
	if a, ok := uiFind(r.Attrs, "note"); ok {
		return a.Word
	}
	return ""
}

// --- Input ------------------------------------------------------------------
//
// --- Data -------------------------------------------------------------------
func UiButton(attrs []UiAttr, label string) UiView {
	return UiView{Kind: "button", Attrs: attrs, Text: label}
}

func UiInput(attrs []UiAttr, value string) UiView {
	return UiView{Kind: "input", Attrs: attrs, Text: value}
}

func UiTextarea(attrs []UiAttr, value string) UiView {
	return UiView{Kind: "textarea", Attrs: attrs, Text: value}
}

func UiCheckbox(attrs []UiAttr, label string, checked bool) UiView {
	return UiView{Kind: "checkbox", Attrs: attrs, Text: label, Flag: checked}
}

func UiSelect(attrs []UiAttr, options []string, chosen string) UiView {
	return UiView{Kind: "select", Attrs: attrs, Options: options, Text: chosen}
}

// The table takes the headered Table every other part of the language hands
// back — a CSV read, a SQL result, a JSON document — so putting one
// on screen costs one call.
func UiTable(attrs []UiAttr, rows Table) UiView {
	return UiView{Kind: "table", Attrs: attrs, Rows: rows}
}

// --- Status -----------------------------------------------------------------
func UiSpinner(attrs []UiAttr) UiView { return UiView{Kind: "spinner", Attrs: attrs} }

// Nothing at all. It still occupies its slot among its siblings, which is what
// keeps a conditional branch from shifting everything after it.
//
// ---------------------------------------------------------------------------
// Attributes
// ---------------------------------------------------------------------------
func UiNone() UiView { return UiView{Kind: "none"} }

func UiGrid(attrs []UiAttr, views []UiView) UiView      { return uiNode("grid", attrs, views) }
func UiStack(attrs []UiAttr, views []UiView) UiView     { return uiNode("stack", attrs, views) }
func UiParagraph(attrs []UiAttr, views []UiView) UiView { return uiNode("paragraph", attrs, views) }
func UiTree(attrs []UiAttr, views []UiView) UiView      { return uiNode("tree", attrs, views) }

func UiBranch(attrs []UiAttr, label string, open bool, views []UiView) UiView {
	return UiView{Kind: "branch", Attrs: attrs, Text: label, Flag: open, Children: views}
}

func UiRadio(attrs []UiAttr, options []string, chosen string) UiView {
	return UiView{Kind: "radio", Attrs: attrs, Options: options, Text: chosen}
}

func UiTabs(attrs []UiAttr, labels []string, chosen string) UiView {
	return UiView{Kind: "tabs", Attrs: attrs, Options: labels, Text: chosen}
}

// The chosen set rides in Rows, the one field of a view that holds a list of lists.
func UiChoices(attrs []UiAttr, options []string, chosen []string) UiView {
	return UiView{Kind: "choices", Attrs: attrs, Options: options, Rows: Table{chosen}}
}

func uiPicked(v *UiView, option string) bool {
	if len(v.Rows) == 0 {
		return false
	}
	for _, c := range v.Rows[0] {
		if c == option {
			return true
		}
	}
	return false
}

func UiProgress(attrs []UiAttr, done float64) UiView {
	return UiView{Kind: "progress", Attrs: attrs, Text: strconv.FormatFloat(uiFraction(done), 'f', -1, 64)}
}

func uiFraction(v float64) float64 {
	if math.IsNaN(v) || v < 0 {
		return 0
	}
	return math.Min(v, 1)
}

func uiDone(v *UiView) float64 {
	done, err := strconv.ParseFloat(v.Text, 64)
	if err != nil {
		return 0
	}
	return uiFraction(done)
}

// The enumerations hive.ui owns. Each is a closed set the renderer can answer
// for in full, which is what a raw CSS value would take away. None is an atom,
// because the atom table belongs to the program rather than to a library.
type UiAlign string
type UiJustify string
type UiTextSize string
type UiTone string
type UiAxis string
type UiAnchor string
type UiInputKind string
type UiIcon string
type UiFit string

// What a solid in a scene is made of, as against what colour it is. It lives
// here with the other enumerations because a closed set of names is a name and
// nothing more; what it costs to draw is hive/ui_scene.go's business.
type UiSurface string

// And what a sound in a scene is the sound of, here for the same reason and
// with the same division: the name is the module's, the oscillators are the
// scene's.
type UiVoice string

// A UiTone is the one enumeration that is not only a closed set: past the five
// roles a stylesheet answers for, two variants carry a colour outright. The two
// are told apart by shape alone — no variant is spelt starting with # or rgba(.
//
// A role becomes a class and a colour becomes a declaration, so a renderer with
// no colours still answers for every role and has exactly one thing it cannot
// do.
func uiToneColour(e string) (string, bool) {
	if strings.HasPrefix(e, "#") || strings.HasPrefix(e, "rgba(") {
		return e, true
	}
	return "", false
}

// A colour written down rather than named, checked here rather than trusted
// because a tone is the only value in the module that reaches a stylesheet as
// text. Anything that is not # and then 3, 4, 6 or 8 hex digits is Normal.
func UiToneHex(hex string) UiTone {
	n := len(hex)
	if n != 4 && n != 5 && n != 7 && n != 9 {
		return UiTone("Normal")
	}
	if hex[0] != '#' {
		return UiTone("Normal")
	}
	for i := 1; i < n; i++ {
		c := hex[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return UiTone("Normal")
		}
	}
	return UiTone(hex)
}

// Four channels, each 0–255, clamped rather than refused: a colour is computed
// at least as often as it is written down, and arithmetic arriving at 260 meant
// the top of the range. Alpha is 0–255 too, and reaches CSS as a fraction.
func UiToneRGBA(red int, green int, blue int, alpha int) UiTone {
	return UiTone("rgba(" +
		strconv.Itoa(uiChannel(red)) + "," +
		strconv.Itoa(uiChannel(green)) + "," +
		strconv.Itoa(uiChannel(blue)) + "," +
		strconv.FormatFloat(float64(uiChannel(alpha))/255, 'f', 3, 64) + ")")
}

func uiChannel(n int) int {
	if n < 0 {
		return 0
	}
	if n > 255 {
		return 255
	}
	return n
}

func uiNum(kind string, n int) UiAttr     { return UiAttr{Kind: kind, Num: n} }
func uiStr(kind string, s string) UiAttr  { return UiAttr{Kind: kind, Word: s} }
func uiEnum(kind string, e string) UiAttr { return UiAttr{Kind: kind, Word: e} }

func UiAttrGap(n int) UiAttr    { return uiNum("gap", n) }
func UiAttrPad(n int) UiAttr    { return uiNum("pad", n) }
func UiAttrWidth(n int) UiAttr  { return uiNum("width", n) }
func UiAttrHeight(n int) UiAttr { return uiNum("height", n) }
func UiAttrGrow(n int) UiAttr   { return uiNum("grow", n) }

func UiAttrAlign(v UiAlign) UiAttr     { return uiEnum("align", string(v)) }
func UiAttrJustify(v UiJustify) UiAttr { return uiEnum("justify", string(v)) }
func UiAttrScroll(v UiAxis) UiAttr     { return uiEnum("scroll", string(v)) }
func UiAttrAnchor(v UiAnchor) UiAttr   { return uiEnum("anchor", string(v)) }
func UiAttrSize(v UiTextSize) UiAttr   { return uiEnum("size", string(v)) }
func UiAttrTone(v UiTone) UiAttr       { return uiEnum("tone", string(v)) }
func UiAttrBackground(v UiTone) UiAttr { return uiEnum("background", string(v)) }
func UiAttrKind(v UiInputKind) UiAttr  { return uiEnum("kind", string(v)) }

// Several numbers at once. A place, a heading, a corner of the plane: none of
// them is one number and none of them is worth a type.
func uiNums(kind string, values []float64) UiAttr {
	return UiAttr{Kind: kind, Nums: values}
}

// What colour a thing is, as against what colour the words on it are. Here
// rather than with the scene because both dimensions past this page use it, and
// a canvas must not drag a 3D library into a build to colour a line.
func UiAttrPaint(v UiTone) UiAttr { return uiEnum("paint", string(v)) }

// How thick a line is drawn, in the canvas's own units rather than in pixels:
// a map zoomed in has thicker roads, which is what zooming in means.
func UiAttrThick(n float64) UiAttr { return uiNums("thick", []float64{n}) }

// Which part of the plane a canvas shows: a corner, then how much of it. It is
// the whole of the coordinate system — everything on a canvas is said in these
// units and nothing anywhere is said in pixels.
func UiAttrRegion(x float64, y float64, width float64, height float64) UiAttr {
	return uiNums("region", []float64{x, y, width, height})
}

// The numbers one attribute carries, or what to do without it.
func uiNumbers(attrs []UiAttr, kind string, fallback []float64) []float64 {
	if a, ok := uiFind(attrs, kind); ok && len(a.Nums) == len(fallback) {
		return a.Nums
	}
	return fallback
}

func UiAttrHeading(n int) UiAttr        { return uiNum("heading", n) }
func UiAttrPlaceholder(s string) UiAttr { return uiStr("placeholder", s) }
func UiAttrHint(s string) UiAttr        { return uiStr("hint", s) }
func UiAttrTouch(s string) UiAttr       { return uiStr("touch", s) }
func UiAttrTitle(s string) UiAttr       { return uiStr("title", s) }
func UiAttrKeys(keys []string) UiAttr   { return uiStr("keys", strings.Join(keys, " ")) }
func UiAttrCaret(anchor int, head int, serial int) UiAttr {
	return UiAttr{Kind: "caret", Nums: []float64{float64(anchor), float64(head), float64(serial)}}
}
func UiAttrFocus(serial int) UiAttr             { return uiNum("focus", serial) }
func UiAttrClip(text string, serial int) UiAttr { return UiAttr{Kind: "clip", Word: text, Num: serial} }
func UiAttrPerform(command string, serial int) UiAttr {
	return UiAttr{Kind: "perform", Word: command, Num: serial}
}
func UiAttrNumbers(b bool) UiAttr      { return UiAttr{Kind: "numbers", Flag: b} }
func UiAttrReadOnly(b bool) UiAttr     { return UiAttr{Kind: "readOnly", Flag: b} }
func UiAttrTabSize(n int) UiAttr       { return UiAttr{Kind: "tabSize", Num: n} }
func UiAttrFontSize(n int) UiAttr      { return UiAttr{Kind: "fontSize", Num: n} }
func UiAttrBorder(n int) UiAttr        { return UiAttr{Kind: "border", Num: n} }
func UiAttrRadius(n int) UiAttr        { return UiAttr{Kind: "radius", Num: n} }
func UiAttrRing(on bool) UiAttr        { return UiAttr{Kind: "ring", Flag: on} }
func UiAttrBorderTone(v UiTone) UiAttr { return uiEnum("borderTone", string(v)) }
func UiAttrHover(v UiTone) UiAttr      { return uiEnum("hover", string(v)) }

func uiFramed(kind string) bool {
	switch kind {
	case "button", "input", "textarea", "select", "code":
		return true
	}
	return false
}

func UiAttrDisabled(b bool) UiAttr { return UiAttr{Kind: "disabled", Flag: b} }
func UiAttrBusy(b bool) UiAttr     { return UiAttr{Kind: "busy", Flag: b} }

// The event attributes. A plain one carries the message itself; the rest carry
// a function of what the user did, because the message depends on it.
func UiAttrOn(msg any) UiAttr              { return UiAttr{Kind: "on", heard: &uiHeard{Msg: msg}} }
func UiAttrOnMenu(msg any) UiAttr          { return UiAttr{Kind: "onMenu", heard: &uiHeard{Msg: msg}} }
func UiAttrOnMiddle(msg any) UiAttr        { return UiAttr{Kind: "onMiddle", heard: &uiHeard{Msg: msg}} }
func UiAttrOnDouble(msg any) UiAttr        { return UiAttr{Kind: "onDouble", heard: &uiHeard{Msg: msg}} }
func UiAttrOnHover(f func(int) any) UiAttr { return UiAttr{Kind: "onHover", heard: &uiHeard{FnInt: f}} }
func UiAttrOnJump(f func(int) any) UiAttr  { return UiAttr{Kind: "onJump", heard: &uiHeard{FnInt: f}} }
func UiAttrOnProbe(f func(int) any) UiAttr { return UiAttr{Kind: "onProbe", heard: &uiHeard{FnInt: f}} }
func UiAttrOnDrag(f func(int, int, bool) any) UiAttr {
	return UiAttr{Kind: "onDrag", heard: &uiHeard{FnDrag: f}}
}
func UiAttrOnDismiss(msg any) UiAttr { return UiAttr{Kind: "onDismiss", heard: &uiHeard{Msg: msg}} }

func UiAttrOnInput(f func(string) any) UiAttr {
	return UiAttr{Kind: "onInput", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnSubmit(f func(string) any) UiAttr {
	return UiAttr{Kind: "onSubmit", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnKey(f func(string) any) UiAttr { return UiAttr{Kind: "onKey", heard: &uiHeard{FnStr: f}} }
func UiAttrOnCaret(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onCaret", heard: &uiHeard{FnSize: f}}
}
func UiAttrOnView(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onView", heard: &uiHeard{FnSize: f}}
}
func UiAttrOnFit(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onFit", heard: &uiHeard{FnSize: f}}
}
func UiAttrOnPaste(f func(string) any) UiAttr {
	return UiAttr{Kind: "onPaste", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnEdit(f func(int, int, string) any) UiAttr {
	return UiAttr{Kind: "onEdit", heard: &uiHeard{FnEdit: f}}
}
func UiAttrOnChoose(f func(string) any) UiAttr {
	return UiAttr{Kind: "onChoose", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnToggle(f func(bool) any) UiAttr {
	return UiAttr{Kind: "onToggle", heard: &uiHeard{FnBool: f}}
}
func UiAttrOnPick(f func(int) any) UiAttr { return UiAttr{Kind: "onPick", heard: &uiHeard{FnInt: f}} }
func UiAttrOnSort(f func(int) any) UiAttr { return UiAttr{Kind: "onSort", heard: &uiHeard{FnInt: f}} }

func UiAttrOnEnter(msg any) UiAttr { return UiAttr{Kind: "onEnter", heard: &uiHeard{Msg: msg}} }
func UiAttrOnLeave(msg any) UiAttr { return UiAttr{Kind: "onLeave", heard: &uiHeard{Msg: msg}} }
func UiAttrOnFocus(msg any) UiAttr { return UiAttr{Kind: "onFocus", heard: &uiHeard{Msg: msg}} }
func UiAttrOnBlur(msg any) UiAttr  { return UiAttr{Kind: "onBlur", heard: &uiHeard{Msg: msg}} }

func UiAttrOnWheel(f func(float64, float64) any) UiAttr {
	return UiAttr{Kind: "onWheel", heard: &uiHeard{FnLook: f}}
}
func UiAttrOnPress(f func(float64, float64) any) UiAttr {
	return UiAttr{Kind: "onPress", heard: &uiHeard{FnLook: f}}
}
func UiAttrOnPoint(f func(float64, float64) any) UiAttr {
	return UiAttr{Kind: "onPoint", heard: &uiHeard{FnLook: f}}
}
func UiAttrOnRelease(f func(float64, float64) any) UiAttr {
	return UiAttr{Kind: "onRelease", heard: &uiHeard{FnLook: f}}
}
func UiAttrOnScroll(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onScroll", heard: &uiHeard{FnSize: f}}
}
func UiAttrOnSize(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onSize", heard: &uiHeard{FnSize: f}}
}
func UiAttrOnDrop(f func(string) any) UiAttr {
	return UiAttr{Kind: "onDrop", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnFile(f func(string, string) any) UiAttr {
	return UiAttr{Kind: "onFile", heard: &uiHeard{FnFile: f}}
}

func UiAttrWrap(on bool) UiAttr     { return UiAttr{Kind: "wrap", Flag: on} }
func UiAttrSpan(n int) UiAttr       { return uiNum("span", max(n, 1)) }
func UiAttrMinWidth(n int) UiAttr   { return uiNum("minWidth", max(n, 0)) }
func UiAttrMaxWidth(n int) UiAttr   { return uiNum("maxWidth", max(n, 0)) }
func UiAttrMinHeight(n int) UiAttr  { return uiNum("minHeight", max(n, 0)) }
func UiAttrMaxHeight(n int) UiAttr  { return uiNum("maxHeight", max(n, 0)) }
func UiAttrFit(v UiFit) UiAttr      { return uiEnum("fit", string(v)) }
func UiAttrItalic(on bool) UiAttr   { return UiAttr{Kind: "italic", Flag: on} }
func UiAttrMono(on bool) UiAttr     { return UiAttr{Kind: "mono", Flag: on} }
func UiAttrLines(n int) UiAttr      { return uiNum("lines", max(n, 1)) }
func UiAttrShadow(n int) UiAttr     { return uiNum("shadow", max(n, 0)) }
func UiAttrEase(ms int) UiAttr      { return uiNum("ease", max(ms, 0)) }
func UiAttrSelected(on bool) UiAttr { return UiAttr{Kind: "selected", Flag: on} }
func UiAttrCarry(s string) UiAttr   { return uiStr("carry", s) }

// CSS reads 1 to 1000 and a face has its weights in hundreds between, so a weight is held there.
func UiAttrWeight(n int) UiAttr { return uiNum("weight", min(max(n, 100), 900)) }

func UiAttrColumns(widths []int) UiAttr {
	shares := make([]float64, len(widths))
	for i, w := range widths {
		shares[i] = float64(max(w, 0))
	}
	return uiNums("columns", shares)
}

func UiAttrPlace(across UiAlign, down UiAlign) UiAttr {
	return UiAttr{Kind: "place", Word: string(across) + " " + string(down)}
}

func uiPlaced(attrs []UiAttr) (string, string) {
	if p, ok := uiFind(attrs, "place"); ok {
		across, down, _ := strings.Cut(p.Word, " ")
		return across, down
	}
	return "Stretch", "Stretch"
}

func UiAttrAspect(wide int, tall int) UiAttr {
	if wide <= 0 || tall <= 0 {
		return UiAttr{Kind: "aspect"}
	}
	return uiNums("aspect", []float64{float64(wide), float64(tall)})
}

func UiAttrOpacity(v float64) UiAttr { return uiNums("opacity", []float64{uiFraction(v)}) }

func uiOpacity(attrs []UiAttr) float64 {
	if a, ok := uiFind(attrs, "opacity"); ok && len(a.Nums) == 1 {
		return a.Nums[0]
	}
	return 1
}

func UiAttrGradient(from UiTone, to UiTone, angle float64) UiAttr {
	if math.IsNaN(angle) || math.IsInf(angle, 0) {
		angle = 0
	}
	return UiAttr{Kind: "gradient", Word: string(from) + "|" + string(to), Nums: []float64{angle}}
}

func uiGradientOf(a UiAttr) (string, string, float64) {
	from, to, _ := strings.Cut(a.Word, "|")
	angle := 0.0
	if len(a.Nums) == 1 {
		angle = a.Nums[0]
	}
	return from, to, angle
}

func UiAttrLimits(low float64, high float64, step float64) UiAttr {
	for _, v := range []*float64{&low, &high, &step} {
		if math.IsNaN(*v) || math.IsInf(*v, 0) {
			*v = 0
		}
	}
	if high < low {
		low, high = high, low
	}
	return uiNums("limits", []float64{low, high, math.Max(step, 0)})
}

func uiLimits(attrs []UiAttr) (float64, float64, float64) {
	if a, ok := uiFind(attrs, "limits"); ok && len(a.Nums) == 3 {
		return a.Nums[0], a.Nums[1], a.Nums[2]
	}
	return 0, 100, 1
}

func UiAttrScrollTo(x int, y int, serial int) UiAttr {
	return uiNums("scrollTo", []float64{float64(max(x, 0)), float64(max(y, 0)), float64(serial)})
}

// Finding one attribute among a node's. Attributes are few and a view is
// rebuilt every turn, so a scan beats anything with a map's allocation.
func uiFind(attrs []UiAttr, kind string) (UiAttr, bool) {
	for _, a := range attrs {
		if a.Kind == kind {
			return a, true
		}
	}
	return UiAttr{}, false
}

func uiHasEvent(attrs []UiAttr) bool {
	for _, a := range attrs {
		switch a.Kind {
		case "on", "onDismiss", "onInput", "onSubmit", "onChoose", "onToggle", "onPick", "onSort", "onKey",
			"onCaret", "onView", "onFit", "onEdit", "onPaste", "onProbe", "onMenu", "onMiddle", "onDouble", "onDrag", "onHover", "onJump",
			"onEnter", "onLeave", "onFocus", "onBlur", "onWheel", "onPress", "onPoint", "onRelease", "onScroll", "onDrop", "onFile":
			return true

			// A scene's own events, listed here rather than anywhere the scene
			// module can reach because this is what gives a node its id.
			//
			// onPad was missing from this list, which cost nothing only because
			// every scene that reads a pad also reads a frame — a scene listening
			// for a controller and nothing else got no id, so nothing it heard could
			// be delivered anywhere.
			//
			// ---------------------------------------------------------------------------
			// Rendering
			// ---------------------------------------------------------------------------
		case "onFrame", "onRate", "onKeyDown", "onKeyUp", "onLook", "onGrab", "onPad", "onSize", "onHit", "onOver",
			"onSnapshot":
			return true
		}
	}
	return false
}

// A render pass. handlers is filled in as the tree is walked when the render is
// a live one: each interactive node is given an id, and the message it carries
// is filed under it. A static render leaves it nil and emits no ids.
//
// What each scene in the tree wants drawn, in the order the scenes appear.
// The element carries only its index: a scene's contents travel on a frame
// of their own, so a world that moves sixty times a second does not re-send
// the document around it, and the canvas is never replaced.
//
// UiView.Cuts for each of those scenes, in the same order.
type uiRender struct {
	out      strings.Builder
	handlers map[string][]UiAttr
	next     int

	// One buffer every element's opening tag is built in, kept between them:
	// the tag is handed back as a string, but what it took to arrive at one
	// need not be a fresh allocation per node.
	scratch   []byte
	scenes    []string
	sceneCuts [][]int32

	// And where each inset is looking, kept apart for the same reason: a second
	// camera that moves is a document that would be re-sent every frame.
	insets []string
	paced  bool

	// Whether the next node opened sits directly in a grid or a stack, the only parents `place` and `span` speak to.
	placing bool
	// Whether the next node opened sits directly in a paragraph, where text is never a heading.
	inline bool
	// Numbers the document's own ids: a gradient's, a radio group's name.
	serial int
}

var uiEscaper = strings.NewReplacer(
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	"\"", "&quot;",
	"'", "&#39;",
)

func uiEscape(s string) string {
	return uiEscaper.Replace(s)
}

// The same, appended rather than returned. Text with nothing to escape —
// which is nearly all of it — is appended in one run rather than a byte at
// a time.
func uiEscapeTo(b *strings.Builder, s string) {
	at := 0
	for i := 0; i < len(s); i++ {
		var swap string
		switch s[i] {
		case '&':
			swap = "&amp;"
		case '<':
			swap = "&lt;"
		case '>':
			swap = "&gt;"
		case '"':
			swap = "&quot;"
		case '\'':
			swap = "&#39;"
		default:
			continue
		}
		b.WriteString(s[at:i])
		b.WriteString(swap)
		at = i + 1
	}
	b.WriteString(s[at:])
}

func uiEscapeInto(b []byte, s string) []byte {
	at := 0
	for i := 0; i < len(s); i++ {
		var swap string
		switch s[i] {
		case '&':
			swap = "&amp;"
		case '<':
			swap = "&lt;"
		case '>':
			swap = "&gt;"
		case '"':
			swap = "&quot;"
		case '\'':
			swap = "&#39;"
		default:
			continue
		}
		b = append(b, s[at:i]...)
		b = append(b, swap...)
		at = i + 1
	}
	return append(b, s[at:]...)
}

// The style a node's attributes come to. Every one maps to a fixed declaration:
// nothing here takes a CSS value from the program, which is what keeps a view
// portable to a renderer that has no CSS at all.
//
// A flex item will not shrink below its content unless it says so,
// and one that cannot shrink never scrolls — it stretches the page
// instead. This is the line that makes scroll mean anything.
//
// The two tones that carry a colour. The value reaching this point has
// been through UiToneHex or UiToneRGBA, so it is a colour and not
// whatever the program had in the string.
func uiStyle(b []byte, kind string, attrs []UiAttr, placed bool) []byte {
	switch kind {
	case "row":
		b = append(b, "display:flex;flex-direction:row;"...)
	case "column", "inset":
		b = append(b, "display:flex;flex-direction:column;"...)
	case "spacer":
		b = append(b, "flex:1 1 auto;"...)
	case "grid":
		b = append(b, "display:grid;grid-template-columns:"...)
		b = uiTracks(b, attrs)
		b = append(b, ";"...)
	}
	worded := kind == "text" || kind == "paragraph"
	for _, a := range attrs {
		switch a.Kind {
		case "gap":
			b = append(b, "gap:"...)
			b = uiInt(b, a.Num)
			b = append(b, "px;"...)
		case "pad":
			b = append(b, "padding:"...)
			b = uiInt(b, a.Num)
			b = append(b, "px;"...)
		case "width":
			b = append(b, "width:"...)
			b = uiInt(b, a.Num)
			b = append(b, "px;"...)
			if kind == "row" || kind == "column" {
				b = append(b, "max-width:100%;"...)
			}
		case "height":
			b = append(b, "height:"...)
			b = uiInt(b, a.Num)
			b = append(b, "px;"...)
		case "align":
			b = append(b, "align-items:"...)
			b = append(b, uiFlexPos(a.Word)...)
			b = append(b, ";"...)
		case "justify":
			switch {
			case worded:
				b = append(b, "text-align:"...)
				b = append(b, uiTextAlign(a.Word)...)
			case kind == "grid":
				b = append(b, "justify-items:"...)
				b = append(b, uiSelfPos(a.Word)...)
			default:
				b = append(b, "justify-content:"...)
				b = append(b, uiFlexPos(a.Word)...)
			}
			b = append(b, ";"...)
		case "wrap":
			switch {
			case kind == "row" && a.Flag:
				b = append(b, "flex-wrap:wrap;align-content:flex-start;"...)
			case worded && !a.Flag:
				b = append(b, "white-space:pre;"...)
			}
		case "span":
			if placed {
				b = append(b, "grid-column:span "...)
				b = uiInt(b, a.Num)
				b = append(b, ";"...)
			}
		case "place":
			if placed {
				across, down := uiPlaced(attrs)
				b = append(b, "justify-self:"...)
				b = append(b, uiSelfPos(across)...)
				b = append(b, ";align-self:"...)
				b = append(b, uiSelfPos(down)...)
				b = append(b, ";"...)
			}
		case "aspect":
			if len(a.Nums) == 2 {
				b = append(b, "aspect-ratio:"...)
				b = uiInt(b, int(a.Nums[0]))
				b = append(b, "/"...)
				b = uiInt(b, int(a.Nums[1]))
				b = append(b, ";"...)
			}
		case "fit":
			b = append(b, "object-fit:"...)
			b = uiLower(b, a.Word)
			b = append(b, ";"...)
		case "weight":
			b = append(b, "font-weight:"...)
			b = uiInt(b, a.Num)
			b = append(b, ";"...)
		case "italic":
			if a.Flag {
				b = append(b, "font-style:italic;"...)
			} else {
				b = append(b, "font-style:normal;"...)
			}
		case "mono":
			if a.Flag {
				b = append(b, "font-family:"...)
				b = append(b, uiMonoFaces...)
				b = append(b, ";"...)
			}
		case "lines":
			if worded {
				b = append(b, "display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:"...)
				b = uiInt(b, a.Num)
				b = append(b, ";line-clamp:"...)
				b = uiInt(b, a.Num)
				b = append(b, ";overflow:hidden;"...)
			}
		case "opacity":
			if len(a.Nums) == 1 && a.Nums[0] < 1 {
				b = append(b, "opacity:"...)
				b = append(b, uiNumber(a.Nums[0])...)
				b = append(b, ";"...)
			}
		case "shadow":
			if a.Num > 0 {
				b = append(b, "box-shadow:0 "...)
				b = append(b, uiNumber(float64(a.Num)/2)...)
				b = append(b, "px "...)
				b = uiInt(b, a.Num)
				b = append(b, "px rgba(0,0,0,.25);"...)
			}
		case "ease":
			if a.Num > 0 {
				b = append(b, "transition:"...)
				for i, p := range uiEased {
					if i > 0 {
						b = append(b, ","...)
					}
					b = append(b, p...)
					b = append(b, " "...)
					b = uiInt(b, a.Num)
					b = append(b, "ms ease"...)
				}
				b = append(b, ";"...)
			}
		case "scroll":
			switch a.Word {
			case "Horizontal":
				b = append(b, "overflow-x:auto;"...)
			case "Vertical":
				b = append(b, "overflow-y:auto;"...)
			default:
				b = append(b, "overflow:auto;"...)
			}
			b = append(b, "min-height:0;min-width:0;"...)
		case "tone":
			if c, colour := uiToneColour(a.Word); colour {
				b = append(b, "color:"...)
				b = append(b, c...)
				b = append(b, ";"...)
			}
		case "background":
			if c, colour := uiToneColour(a.Word); colour {
				b = append(b, "background:"...)
				b = append(b, c...)
				b = append(b, ";"...)
			}
		case "border":
			if a.Num <= 0 {
				b = append(b, "border:0;"...)
			} else {
				b = append(b, "border-width:"...)
				b = uiInt(b, a.Num)
				b = append(b, "px;border-style:solid;"...)
			}
		case "borderTone":
			if css := uiRunColour(a.Word); css != "" {
				b = append(b, "border-color:"...)
				b = append(b, css...)
				b = append(b, ";"...)
			}
		case "radius":
			b = append(b, "border-radius:"...)
			b = uiInt(b, max(a.Num, 0))
			b = append(b, "px;"...)
		case "hover":
			if css := uiRunColour(a.Word); css != "" {
				b = append(b, "--hv:"...)
				b = append(b, css...)
				b = append(b, ";"...)
			}
		}
	}
	if uiFramed(kind) {
		_, coloured := uiFind(attrs, "background")
		_, shaded := uiFind(attrs, "gradient")
		_, edged := uiFind(attrs, "border")
		_, toned := uiFind(attrs, "borderTone")
		if (coloured || shaded) && !edged && !toned {
			b = append(b, "border-color:transparent;"...)
		}
	}
	if g, ok := uiFind(attrs, "gradient"); ok {
		from, to, angle := uiGradientOf(g)
		b = append(b, "background:linear-gradient("...)
		b = append(b, uiNumber(90+angle*180/math.Pi)...)
		b = append(b, "deg,"...)
		b = append(b, uiFillColour(from)...)
		b = append(b, ","...)
		b = append(b, uiFillColour(to)...)
		b = append(b, ");"...)
	}
	for _, edge := range [4][2]string{{"minWidth", "min-width:"}, {"maxWidth", "max-width:"},
		{"minHeight", "min-height:"}, {"maxHeight", "max-height:"}} {
		if a, ok := uiFind(attrs, edge[0]); ok {
			b = append(b, edge[1]...)
			b = uiInt(b, a.Num)
			b = append(b, "px;"...)
		}
	}

	// flex is written once, after everything else: grow and width are two
	// answers to the same question, and a box that emitted both would have the
	// later one quietly win.
	if grow, ok := uiFind(attrs, "grow"); ok {
		b = append(b, "flex:"...)
		b = uiInt(b, grow.Num)
		b = append(b, " 1 0;"...)
	} else if _, ok := uiFind(attrs, "width"); ok {
		b = append(b, "flex:0 0 auto;"...)
	}
	return b
}

var uiEased = [...]string{"background-color", "color", "opacity", "width", "height", "box-shadow", "border-color"}

const uiMonoFaces = `ui-monospace,'Cascadia Mono','Cascadia Code',Consolas,'Liberation Mono','DejaVu Sans Mono',monospace`

func uiTracks(b []byte, attrs []UiAttr) []byte {
	a, ok := uiFind(attrs, "columns")
	if !ok || len(a.Nums) == 0 {
		return append(b, "minmax(0,1fr)"...)
	}
	for i, share := range a.Nums {
		if i > 0 {
			b = append(b, ' ')
		}
		if share == 0 {
			b = append(b, "auto"...)
			continue
		}
		b = append(b, "minmax(0,"...)
		b = uiInt(b, int(share))
		b = append(b, "fr)"...)
	}
	return b
}

func uiTextAlign(v string) string {
	switch v {
	case "Center":
		return "center"
	case "End":
		return "end"
	case "Between":
		return "justify"
	}
	return "start"
}

func uiSelfPos(v string) string {
	switch v {
	case "Start":
		return "start"
	case "Center":
		return "center"
	case "End":
		return "end"
	}
	return "stretch"
}

// A role behind something is the page's or a state's fill, as `background` paints it.
func uiFillColour(tone string) string {
	if c, ok := uiToneColour(tone); ok {
		return c
	}
	switch tone {
	case "Muted":
		return "var(--surface)"
	case "Good":
		return "var(--good)"
	case "Warn":
		return "var(--warn)"
	case "Danger":
		return "var(--danger)"
	}
	return "var(--bg)"
}

func uiFlexPos(v string) string {
	switch v {
	case "Start":
		return "flex-start"
	case "End":
		return "flex-end"
	case "Center":
		return "center"
	case "Between":
		return "space-between"
	case "Stretch":
		return "stretch"
	}
	return "flex-start"
}

// The classes a node carries: its widget name, plus a token for each attribute
// the stylesheet gives meaning to. A tone is a class rather than a colour so a
// theme — or a renderer with no colours — decides what it looks like.
//
// A tone naming a role is a class the stylesheet answers for. One
// carrying a colour has nothing to look up and becomes a declaration in
// uiStyle instead, so it gets no class here.
func uiClasses(b []byte, kind string, attrs []UiAttr) []byte {
	b = append(b, "h-"...)
	b = append(b, kind...)
	for _, a := range attrs {
		switch a.Kind {
		case "tone":
			if _, colour := uiToneColour(a.Word); !colour {
				b = append(b, " h-tone-"...)
				b = uiLower(b, a.Word)
			}
		case "background":
			if _, colour := uiToneColour(a.Word); !colour {
				b = append(b, " h-bg-"...)
				b = uiLower(b, a.Word)
			}
		case "size":
			b = append(b, " h-size-"...)
			b = uiLower(b, a.Word)
		case "busy":
			if a.Flag {
				b = append(b, " h-busy"...)
			}

			// A scene's aiming mark. It is a class rather than something drawn in the
			// world because it belongs to the viewport rather than to the world: it has
			// no position in it, and nothing in the scene can stand in front of it.
		case "crosshair":
			if a.Flag {
				b = append(b, " h-aiming"...)
			}
		case "ring":
			if !a.Flag {
				b = append(b, " h-noring"...)
			}
		case "hover":
			b = append(b, " h-hover"...)
		case "scroll":
			if a.Word == "Horizontal" {
				b = append(b, " h-scroll-x"...)
			}
		case "wrap":
			if a.Flag && kind == "radio" {
				b = append(b, " h-wrap"...)
			}
		}
	}
	return b
}

// An enumeration's name, lowered straight into the output. The names are
// ASCII words this compiler wrote, so this is the whole of what ToLower
// would do — without the string it allocates to do it.
func uiLower(b []byte, s string) []byte {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		b = append(b, c)
	}
	return b
}

func uiInt(b []byte, n int) []byte {
	return strconv.AppendInt(b, int64(n), 10)
}

// The common attribute string every element opens with.
//
// Where in the window it sits.
//
// An overlay that says nothing is a dialog: centred, over a dimmed page.
// One that says where it goes is a panel pinned to an edge — a HUD, a
// toast, a legend — so it is not dimmed, and it lets clicks through
// everywhere it is not.
//
// The stylesheet takes the rest of the dialog off it too, all one
// decision: a pinned panel is a shape the program chose, so a stripe
// down the side of the window is exactly that.
//
// Wrapped in its label so the words are clickable too, which is what
// anyone expects of a checkbox and is easy to leave out.
//
// The box a scene is drawn in, and nothing else: what to draw is in
// v.Text and goes into r.scenes rather than into the document. A static
// render has no socket to send frames down, so it leaves an empty box.
func (r *uiRender) code(v UiView) {
	r.out.WriteString("<div")
	r.common(v.Kind, v.Attrs)
	if size, ok := uiFind(v.Attrs, "fontSize"); ok && size.Num >= 6 && size.Num <= 72 {
		r.out.WriteString(" data-font=\"")
		r.out.WriteString(strconv.Itoa(size.Num))
		r.out.WriteString("\"")
	}
	if c, ok := uiFind(v.Attrs, "caret"); ok && len(c.Nums) == 3 {
		r.out.WriteString(" data-caret=\"")
		r.out.WriteString(strconv.Itoa(int(c.Nums[0])))
		r.out.WriteString(",")
		r.out.WriteString(strconv.Itoa(int(c.Nums[1])))
		r.out.WriteString(",")
		r.out.WriteString(strconv.Itoa(int(c.Nums[2])))
		r.out.WriteString("\"")
	}
	if _, ok := uiFind(v.Attrs, "onInput"); ok {
		r.out.WriteString(" data-whole")
	}
	tab := 4
	if t, ok := uiFind(v.Attrs, "tabSize"); ok && t.Num > 0 {
		tab = t.Num
	}
	r.out.WriteString(">")
	if n, ok := uiFind(v.Attrs, "numbers"); ok && n.Flag {
		r.out.WriteString("<pre class=\"h-gutter\" aria-hidden=\"true\">\n")
		r.gutter(v)
		r.out.WriteString("</pre>")
	}
	sized := " style=\"tab-size:" + strconv.Itoa(tab) + "\""
	r.out.WriteString("<div class=\"h-code-body\"><div class=\"h-curline\"></div><pre class=\"h-runs\" aria-hidden=\"true\"")
	r.out.WriteString(sized)
	r.out.WriteString(">\n")
	for _, m := range v.Marks {
		if m.Kind == "band" && len(m.Nums) == 2 {
			if css := uiRunColour(m.Text); css != "" {
				r.out.WriteString("<span class=\"h-band\" style=\"top:calc(8px + ")
				r.out.WriteString(strconv.Itoa(int(m.Nums[0])))
				r.out.WriteString(" * 1.5em);background:")
				r.out.WriteString(css)
				r.out.WriteString("\"></span>")
			}
		}
	}
	uiRunsTo(&r.out, v.Text, v.Marks)
	r.out.WriteString("\n</pre><textarea class=\"h-mono\" spellcheck=\"false\" wrap=\"off\" autocomplete=\"off\" autocapitalize=\"off\"")
	r.out.WriteString(sized)
	r.out.WriteString(r.disabled(v.Attrs))
	if ro, ok := uiFind(v.Attrs, "readOnly"); ok && ro.Flag {
		r.out.WriteString(" readonly")
	}
	r.out.WriteString(">\n")
	uiEscapeTo(&r.out, v.Text)
	r.out.WriteString("</textarea></div></div>")
}

func (r *uiRender) gutter(v UiView) {
	lines := strings.Count(v.Text, "\n") + 1
	marked := map[int]string{}
	for _, m := range v.Marks {
		if m.Kind == "marker" && len(m.Nums) == 2 {
			if css := uiRunColour(m.Text); css != "" {
				marked[int(m.Nums[0])] = css
			}
		}
	}
	for i := 0; i < lines; i++ {
		if css, ok := marked[i]; ok {
			r.out.WriteString("<span class=\"h-mk\" style=\"box-shadow:inset 3px 0 0 ")
			r.out.WriteString(css)
			r.out.WriteString("\">")
			r.out.WriteString(strconv.Itoa(i + 1))
			r.out.WriteString("</span>\n")
			continue
		}
		r.out.WriteString(strconv.Itoa(i + 1))
		r.out.WriteString("\n")
	}
}

func uiRunColour(tone string) string {
	if css, ok := uiToneColour(tone); ok {
		return css
	}
	switch tone {
	case "Muted":
		return "var(--muted)"
	case "Good":
		return "var(--good)"
	case "Warn":
		return "var(--warn)"
	case "Danger":
		return "var(--danger)"
	}
	return ""
}

func uiRunsTo(out *strings.Builder, text string, runs []UiRun) {
	type cut struct {
		at    int
		run   int
		start bool
		note  bool
	}
	var cuts []cut
	for i, m := range runs {
		if m.Kind == "note" || m.Kind == "marker" || m.Kind == "band" || len(m.Nums) != 2 || m.Nums[1] <= m.Nums[0] {
			continue
		}
		cuts = append(cuts, cut{int(m.Nums[0]), i, true, false})
		cuts = append(cuts, cut{int(m.Nums[1]), i, false, false})
	}
	var notes []int
	for i, m := range runs {
		if m.Kind == "note" && len(m.Nums) == 2 {
			notes = append(notes, i)
		}
	}
	if len(notes) > 0 {
		ends := []int{}
		line, at := 0, 0
		for _, r := range text {
			if r == '\n' {
				ends = append(ends, at)
				line++
			}
			at++
		}
		ends = append(ends, at)
		for _, i := range notes {
			if line := int(runs[i].Nums[0]); line >= 0 && line < len(ends) {
				cuts = append(cuts, cut{ends[line], i, false, true})
			}
		}
	}
	if len(cuts) == 0 {
		uiEscapeTo(out, text)
		return
	}
	sort.SliceStable(cuts, func(i, j int) bool { return cuts[i].at < cuts[j].at })
	live := map[int]bool{}
	chars := []rune(text)
	at := 0
	piece := func(to int) {
		to = max(0, min(to, len(chars)))
		if to <= at {
			return
		}
		ink, shade, wave, line := -1, -1, -1, -1
		for i := range live {
			switch runs[i].Kind {
			case "ink":
				ink = max(ink, i)
			case "shade":
				shade = max(shade, i)
			case "squiggle":
				wave = max(wave, i)
			case "underline":
				line = max(line, i)
			}
		}
		style := ""
		if ink >= 0 {
			if css := uiRunColour(runs[ink].Text); css != "" {
				style += "color:" + css + ";"
			}
		}
		if shade >= 0 {
			if css := uiRunColour(runs[shade].Text); css != "" {
				style += "background:" + css + ";"
			}
		}
		if wave >= 0 {
			css := uiRunColour(runs[wave].Text)
			if css == "" {
				css = "currentColor"
			}
			style += "text-decoration:underline wavy " + css + ";text-decoration-skip-ink:none;"
		} else if line >= 0 {
			css := uiRunColour(runs[line].Text)
			if css == "" {
				css = "currentColor"
			}
			style += "text-decoration:underline " + css + ";"
		}
		if style != "" {
			out.WriteString("<span style=\"")
			out.WriteString(style)
			out.WriteString("\">")
		}
		uiEscapeTo(out, string(chars[at:to]))
		if style != "" {
			out.WriteString("</span>")
		}
		at = to
	}
	for _, c := range cuts {
		piece(c.at)
		if c.note {
			css := uiRunColour(runs[c.run].Text)
			out.WriteString("<span class=\"h-note\" data-note=\"")
			uiEscapeTo(out, uiNoteText(runs[c.run]))
			out.WriteString("\"")
			if css != "" {
				out.WriteString(" style=\"color:")
				out.WriteString(css)
				out.WriteString("\"")
			}
			out.WriteString("></span>")
			continue
		}
		if c.start {
			live[c.run] = true
		} else {
			delete(live, c.run)
		}
	}
	piece(len(chars))
}

func (r *uiRender) common(kind string, attrs []UiAttr) {
	b := r.scratch[:0]
	b = append(b, " class=\""...)
	b = uiClasses(b, kind, attrs)
	b = append(b, '"')

	// The opening is written before there is anything to put in it and taken
	// back where nothing was: whether a node has any style at all is not a
	// question that can be answered without asking every attribute.
	was := len(b)
	b = append(b, " style=\""...)
	held := len(b)
	placed := r.placing
	r.placing = false
	b = uiStyle(b, kind, attrs, placed)
	if len(b) == held {
		b = b[:was]
	} else {
		b = append(b, '"')
	}
	if hint, ok := uiFind(attrs, "hint"); ok {
		b = append(b, " title=\""...)
		b = uiEscapeInto(b, hint.Word)
		b = append(b, '"')
	}
	if touch, ok := uiFind(attrs, "touch"); ok {
		b = append(b, " data-touch=\""...)
		b = uiEscapeInto(b, touch.Word)
		b = append(b, '"')
	}
	if title, ok := uiFind(attrs, "title"); ok {
		b = append(b, " data-title=\""...)
		b = uiEscapeInto(b, title.Word)
		b = append(b, '"')
	}
	if keys, ok := uiFind(attrs, "keys"); ok {
		b = append(b, " data-keys=\""...)
		b = uiEscapeInto(b, keys.Word)
		b = append(b, '"')
	}
	if f, ok := uiFind(attrs, "focus"); ok {
		b = append(b, " data-focus=\""...)
		b = strconv.AppendInt(b, int64(f.Num), 10)
		b = append(b, '"')
	}
	if c, ok := uiFind(attrs, "clip"); ok {
		b = append(b, " data-clip=\""...)
		b = strconv.AppendInt(b, int64(c.Num), 10)
		b = append(b, "\" data-clip-text=\""...)
		b = uiEscapeInto(b, c.Word)
		b = append(b, '"')
	}
	if p, ok := uiFind(attrs, "perform"); ok {
		b = append(b, " data-perform=\""...)
		b = uiEscapeInto(b, p.Word)
		b = append(b, ',')
		b = strconv.AppendInt(b, int64(p.Num), 10)
		b = append(b, '"')
	}
	if s, ok := uiFind(attrs, "scrollTo"); ok && len(s.Nums) == 3 {
		b = append(b, " data-scrollto=\""...)
		b = uiInt(b, int(s.Nums[0]))
		b = append(b, ',')
		b = uiInt(b, int(s.Nums[1]))
		b = append(b, ',')
		b = uiInt(b, int(s.Nums[2]))
		b = append(b, '"')
	}
	if c, ok := uiFind(attrs, "carry"); ok {
		b = append(b, " draggable=\"true\" data-carry=\""...)
		b = uiEscapeInto(b, c.Word)
		b = append(b, '"')
	}
	heard := len(b)
	for _, a := range attrs {
		switch a.Kind {
		case "onMenu", "onMiddle", "onDouble", "onDrag", "onHover", "onJump", "onPaste", "onProbe",
			"onEnter", "onLeave", "onFocus", "onBlur", "onWheel", "onPress", "onPoint", "onRelease",
			"onScroll", "onDrop", "onFile", "onSize":
			if len(b) == heard {
				b = append(b, " data-ev=\""...)
			} else {
				b = append(b, ' ')
			}
			b = append(b, strings.ToLower(a.Kind[2:])...)
		}
	}
	if len(b) > heard {
		b = append(b, '"')
	}
	if r.handlers != nil && uiHasEvent(attrs) {
		r.next++
		id := "h" + strconv.Itoa(r.next)
		r.handlers[id] = attrs
		if _, ok := uiFind(attrs, "onFrame"); ok {
			r.paced = true
		}
		b = append(b, " data-h=\""...)
		b = append(b, id...)
		b = append(b, '"')
	}
	r.scratch = b
	r.out.Write(b)
}

func (r *uiRender) view(v UiView) {
	inline := r.inline
	r.inline = false
	switch v.Kind {
	case "none":
		r.out.WriteString("<!--none-->")
	case "spacer":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString("></div>")
	case "row", "column":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(">")
		for _, c := range v.Children {
			r.view(c)
		}
		r.out.WriteString("</div>")
	case "overlay":
		pinned := ""
		if a, ok := uiFind(v.Attrs, "align"); ok {
			pinned += "align-items:" + uiFlexPos(a.Word) + ";"
		}
		if j, ok := uiFind(v.Attrs, "justify"); ok {
			pinned += "justify-content:" + uiFlexPos(j.Word) + ";"
		}
		shade := "h-backdrop"
		if pinned != "" {
			shade = "h-backdrop h-pinned"
			pinned += "padding:12px;"
		}
		open := "<div class=\"" + shade + "\""
		if pinned != "" {
			open += " style=\"" + pinned + "\""
		}
		if a, ok := uiFind(v.Attrs, "anchor"); ok {
			open = "<div class=\"h-backdrop h-pinned h-anchored\" data-anchor=\"" + a.Word + "\""
		}
		r.out.WriteString(open + r.backdrop(v.Attrs) + ">")
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(">")
		for _, c := range v.Children {
			r.view(c)
		}
		r.out.WriteString("</div></div>")
	case "text":
		tag := "span"
		if h, ok := uiFind(v.Attrs, "heading"); ok && h.Num >= 1 && h.Num <= 6 && !inline {
			tag = "h" + strconv.Itoa(h.Num)
		}
		r.out.WriteString("<")
		r.out.WriteString(tag)
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(">")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("</")
		r.out.WriteString(tag)
		r.out.WriteString(">")
	case "image":
		alt := ""
		if len(v.Options) > 0 {
			alt = v.Options[0]
		}
		r.out.WriteString("<img")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" src=\"")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("\" alt=\"")
		uiEscapeTo(&r.out, alt)
		r.out.WriteString("\">")
	case "icon":
		r.out.WriteString("<span")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" aria-hidden=\"true\">")
		r.out.WriteString(uiIconSvg(v.Text))
		r.out.WriteString("</span>")
	case "link":
		href := ""
		if len(v.Options) > 0 {
			href = v.Options[0]
		}
		r.out.WriteString("<a")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" href=\"")
		uiEscapeTo(&r.out, uiHref(href))
		r.out.WriteString("\">")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("</a>")
	case "button":
		r.out.WriteString("<button type=\"button\"")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(r.disabled(v.Attrs))
		r.out.WriteString(">")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("</button>")
	case "input":
		kind := "text"
		if k, ok := uiFind(v.Attrs, "kind"); ok {
			kind = uiInputType(k.Word)
		}
		r.out.WriteString("<input type=\"")
		r.out.WriteString(kind)
		r.out.WriteString("\"")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(r.disabled(v.Attrs))
		if kind != "file" {
			r.out.WriteString(" value=\"")
			uiEscapeTo(&r.out, v.Text)
			r.out.WriteString("\"")
		}
		if _, ok := uiFind(v.Attrs, "limits"); ok && (kind == "range" || kind == "number") {
			low, high, step := uiLimits(v.Attrs)
			r.out.WriteString(" min=\"" + uiNumber(low) + "\" max=\"" + uiNumber(high) + "\" step=\"")
			if step > 0 {
				r.out.WriteString(uiNumber(step))
			} else {
				r.out.WriteString("any")
			}
			r.out.WriteString("\"")
		}
		if p, ok := uiFind(v.Attrs, "placeholder"); ok {
			r.out.WriteString(" placeholder=\"")
			uiEscapeTo(&r.out, p.Word)
			r.out.WriteString("\"")
		}
		r.out.WriteString(">")
	case "code":
		r.code(v)
	case "textarea":
		r.out.WriteString("<textarea")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(r.disabled(v.Attrs))
		if p, ok := uiFind(v.Attrs, "placeholder"); ok {
			r.out.WriteString(" placeholder=\"")
			uiEscapeTo(&r.out, p.Word)
			r.out.WriteString("\"")
		}
		r.out.WriteString(">")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("</textarea>")
	case "checkbox":
		r.out.WriteString("<label")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString("><input type=\"checkbox\"")
		if v.Flag {
			r.out.WriteString(" checked")
		}
		r.out.WriteString(r.disabled(v.Attrs))
		r.out.WriteString("><span>")
		uiEscapeTo(&r.out, v.Text)
		r.out.WriteString("</span></label>")
	case "select":
		r.out.WriteString("<select")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(r.disabled(v.Attrs))
		r.out.WriteString(">")
		for _, opt := range v.Options {
			sel := ""
			if opt == v.Text {
				sel = " selected"
			}
			r.out.WriteString("<option value=\"")
			uiEscapeTo(&r.out, opt)
			r.out.WriteString("\"")
			r.out.WriteString(sel)
			r.out.WriteString(">")
			uiEscapeTo(&r.out, opt)
			r.out.WriteString("</option>")
		}
		r.out.WriteString("</select>")
	case "scene":
		at := len(r.scenes)
		r.scenes = append(r.scenes, v.Text)
		r.sceneCuts = append(r.sceneCuts, v.Cuts)
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		if r.handlers != nil {
			r.out.WriteString(" data-scene=\"")
			r.out.WriteString(strconv.Itoa(at))
			r.out.WriteString("\"")
		}
		r.out.WriteString("></div>")
	case "inset":

		// The box a second look at the world goes in. Like a scene it keeps its
		// camera out of the document (see uiRender.insets), and unlike a scene
		// it has children, laid over the picture rather than drawn into it.
		//
		// ---------------------------------------------------------------------------
		// A canvas
		// ---------------------------------------------------------------------------
		at := len(r.insets)
		r.insets = append(r.insets, v.Text)
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		if r.handlers != nil {
			r.out.WriteString(" data-inset=\"")
			r.out.WriteString(strconv.Itoa(at))
			r.out.WriteString("\"")
		}
		r.out.WriteString(">")
		for _, c := range v.Children {
			r.view(c)
		}
		r.out.WriteString("</div>")
	case "canvas":
		r.canvas(v)
	case "table":
		r.table(v)
	case "spinner":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" role=\"status\"></div>")
	case "grid", "stack":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(">")
		for _, c := range v.Children {
			r.placing = true
			r.view(c)
		}
		r.placing = false
		r.out.WriteString("</div>")
	case "paragraph":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(">")
		for _, c := range v.Children {
			r.inline = true
			r.view(c)
		}
		r.inline = false
		r.out.WriteString("</div>")
	case "progress":
		done := uiNumber(uiDone(&v))
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" role=\"progressbar\" aria-valuemin=\"0\" aria-valuemax=\"1\" aria-valuenow=\"" + done +
			"\"><div style=\"width:" + uiNumber(uiDone(&v)*100) + "%\"></div></div>")
	case "radio":
		r.serial++
		group := "hr" + strconv.Itoa(r.serial)
		off := r.disabled(v.Attrs)
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" role=\"radiogroup\">")
		for _, opt := range v.Options {
			r.out.WriteString("<label class=\"h-option\"><input type=\"radio\" name=\"" + group + "\" value=\"")
			uiEscapeTo(&r.out, opt)
			r.out.WriteString("\"")
			if opt == v.Text {
				r.out.WriteString(" checked")
			}
			r.out.WriteString(off + "><span>")
			uiEscapeTo(&r.out, opt)
			r.out.WriteString("</span></label>")
		}
		r.out.WriteString("</div>")
	case "choices", "tabs":
		role, item, class, many := "tablist", "tab", "tab", ""
		if v.Kind == "choices" {
			role, item, class, many = "listbox", "option", "choice", " aria-multiselectable=\"true\""
		}
		off := r.disabled(v.Attrs)
		choose, choosing := uiFind(v.Attrs, "onChoose")
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" role=\"" + role + "\"" + many + ">")
		for _, opt := range v.Options {
			on := opt == v.Text
			if v.Kind == "choices" {
				on = uiPicked(&v, opt)
			}
			r.out.WriteString("<button type=\"button\" class=\"h-" + class + "\" role=\"" + item + "\" aria-selected=\"" +
				strconv.FormatBool(on) + "\"" + off)
			if r.handlers != nil && choosing {
				r.next++
				id := "h" + strconv.Itoa(r.next)
				r.handlers[id] = []UiAttr{{Kind: "choice", heard: choose.heard, Word: opt}}
				r.out.WriteString(" data-h=\"" + id + "\"")
			}
			r.out.WriteString(">")
			if v.Kind == "choices" {
				r.out.WriteString("<span class=\"h-tick\">")
				if on {
					r.out.WriteString(uiIconSvg("Check"))
				}
				r.out.WriteString("</span>")
			}
			r.out.WriteString("<span>")
			uiEscapeTo(&r.out, opt)
			r.out.WriteString("</span></button>")
		}
		r.out.WriteString("</div>")
	case "tree":
		r.out.WriteString("<div")
		r.common(v.Kind, v.Attrs)
		r.out.WriteString(" role=\"tree\">")
		for _, c := range v.Children {
			r.view(c)
		}
		r.out.WriteString("</div>")
	case "branch":
		r.branch(v)
	default:
		r.out.WriteString("<!--unknown widget-->")
	}
}

// Two dimensions, in the program's own units.
//
// It renders to SVG, and that is the whole implementation — no drawing context,
// no frame to schedule, nothing to clear, because a canvas is a value like
// every other view. The same tree a window swaps in is what ui.page writes to a
// file, so a map drawn for a game is served by a web server unchanged.
//
// The units are the region's, not the page's: a canvas showing a kilometre of
// racetrack says so once, and everything on it is then written in metres. That
// is what preserveAspectRatio is for — the box may be any shape and what is
// drawn keeps its own.
func (r *uiRender) canvas(v UiView) {
	region := uiNumbers(v.Attrs, "region", []float64{0, 0, 100, 100})

	// A region with no extent would divide by nothing. Worth answering rather
	// than refusing: a canvas of a lap before the lap is rolled is a real
	// state for one frame, and an empty box is what it should look like.
	//
	// Round at both the ends and the joins, which is the difference between
	// a road and a row of splinters wherever one bends sharply.
	if region[2] <= 0 || region[3] <= 0 {
		region = []float64{0, 0, 100, 100}
	}
	r.out.WriteString("<svg")
	r.common(v.Kind, v.Attrs)
	r.out.WriteString(" viewBox=\"")
	r.out.WriteString(uiNumber(region[0]))
	r.out.WriteString(" ")
	r.out.WriteString(uiNumber(region[1]))
	r.out.WriteString(" ")
	r.out.WriteString(uiNumber(region[2]))
	r.out.WriteString(" ")
	r.out.WriteString(uiNumber(region[3]))
	r.out.WriteString("\" preserveAspectRatio=\"xMidYMid meet\"")
	r.out.WriteString(" xmlns=\"http://www.w3.org/2000/svg\">")
	for _, m := range v.Marks {
		r.mark(m)
	}
	r.out.WriteString("</svg>")
}

func (r *uiRender) mark(m UiMark) {
	switch m.Kind {
	case "symbol":
		r.symbol(m)
		return
	case "words":
		r.words(m)
		return
	case "picture":
		r.picture(m)
		return
	}
	shape, box, closed := uiMarkShape(m)
	if shape == "" {
		return
	}
	_, painted := uiFind(m.Attrs, "paint")
	edge, edged := uiFind(m.Attrs, "edge")
	fill := uiMarkColour(m.Attrs)
	if g, ok := uiFind(m.Attrs, "gradient"); ok {
		fill = "url(#" + r.gradient(g, box) + ")"
		painted = true
	}
	var b strings.Builder
	b.WriteString(shape)
	if closed {
		switch {
		case !painted && edged:
			b.WriteString(" fill=\"none\"")
		default:
			b.WriteString(" fill=\"" + fill + "\"")
		}
		if m.Kind == "cutout" {
			b.WriteString(" fill-rule=\"evenodd\"")
		}
		if edged {
			b.WriteString(" stroke=\"" + uiMarkColour([]UiAttr{{Kind: "paint", Word: edge.Word}}) + "\" stroke-width=\"" +
				uiNumber(uiThick(m.Attrs)) + "\"")
			uiDashTo(&b, m.Attrs)
		}
	} else {
		b.WriteString(" fill=\"none\" stroke=\"" + fill + "\" stroke-width=\"" + uiNumber(uiThick(m.Attrs)) +
			"\" stroke-linecap=\"round\" stroke-linejoin=\"round\"")
		uiDashTo(&b, m.Attrs)
	}
	if o := uiOpacity(m.Attrs); o < 1 {
		b.WriteString(" opacity=\"" + uiNumber(o) + "\"")
	}
	b.WriteString("/>")
	r.out.WriteString(b.String())
}

func uiDashTo(b *strings.Builder, attrs []UiAttr) {
	if d, ok := uiFind(attrs, "dash"); ok && len(d.Nums) == 2 && d.Nums[0]+d.Nums[1] > 0 {
		b.WriteString(" stroke-dasharray=\"" + uiNumber(d.Nums[0]) + " " + uiNumber(d.Nums[1]) + "\"")
	}
}

// The element a mark is drawn as, its box in the canvas's units, and whether it encloses anything to fill.
func uiMarkShape(m UiMark) (string, [4]float64, bool) {
	n := m.Nums
	switch m.Kind {
	case "dot":
		if len(n) < 3 {
			return "", [4]float64{}, false
		}
		return "<circle cx=\"" + uiNumber(n[0]) + "\" cy=\"" + uiNumber(n[1]) + "\" r=\"" + uiNumber(n[2]) + "\"",
			[4]float64{n[0] - n[2], n[1] - n[2], n[0] + n[2], n[1] + n[2]}, true
	case "bar":
		if len(n) < 4 {
			return "", [4]float64{}, false
		}
		return "<rect x=\"" + uiNumber(n[0]-n[2]/2) + "\" y=\"" + uiNumber(n[1]-n[3]/2) + "\" width=\"" + uiNumber(n[2]) +
			"\" height=\"" + uiNumber(n[3]) + "\"", [4]float64{n[0] - n[2]/2, n[1] - n[3]/2, n[0] + n[2]/2, n[1] + n[3]/2}, true
	case "oval":
		if len(n) < 4 {
			return "", [4]float64{}, false
		}
		return "<ellipse cx=\"" + uiNumber(n[0]) + "\" cy=\"" + uiNumber(n[1]) + "\" rx=\"" + uiNumber(n[2]/2) +
			"\" ry=\"" + uiNumber(n[3]/2) + "\"", [4]float64{n[0] - n[2]/2, n[1] - n[3]/2, n[0] + n[2]/2, n[1] + n[3]/2}, true
	case "path", "patch":
		points := uiPoints(n)
		if points == "" {
			return "", [4]float64{}, false
		}
		if m.Kind == "path" {
			return "<polyline points=\"" + points + "\"", uiBoxOf(n), false
		}
		return "<polygon points=\"" + points + "\"", uiBoxOf(n), true
	case "arc", "wedge", "curve", "cutout":
		d, box, ok := uiPathData(m)
		if !ok {
			return "", [4]float64{}, false
		}
		return "<path d=\"" + d + "\"", box, m.Kind != "arc" && m.Kind != "curve"
	}
	return "", [4]float64{}, false
}

func uiBoxOf(n []float64) [4]float64 {
	box := [4]float64{math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)}
	for i := 0; i+1 < len(n); i += 2 {
		box[0], box[1] = math.Min(box[0], n[i]), math.Min(box[1], n[i+1])
		box[2], box[3] = math.Max(box[2], n[i]), math.Max(box[3], n[i+1])
	}
	if math.IsInf(box[0], 0) {
		return [4]float64{}
	}
	return box
}

func uiJoinBox(a, b [4]float64) [4]float64 {
	return [4]float64{math.Min(a[0], b[0]), math.Min(a[1], b[1]), math.Max(a[2], b[2]), math.Max(a[3], b[3])}
}

// A turn of at least a whole circle is the whole circle.
func uiSweep(from, to float64) (float64, bool) {
	sweep := to - from
	if math.Abs(sweep) >= 2*math.Pi-1e-9 {
		return sweep, true
	}
	return sweep, false
}

func uiOnCircle(x, y, r, at float64) (float64, float64) {
	return x + r*math.Cos(at), y + r*math.Sin(at)
}

// SVG path data for the marks that are not one of its own shapes, and for a cutout's rings.
func uiPathData(m UiMark) (string, [4]float64, bool) {
	n := m.Nums
	var d strings.Builder
	pt := func(x, y float64) string { return uiNumber(x) + " " + uiNumber(y) }
	circle := func(x, y, rx, ry float64) {
		d.WriteString("M" + pt(x-rx, y) + "A" + uiNumber(rx) + " " + uiNumber(ry) + " 0 1 0 " + pt(x+rx, y) +
			"A" + uiNumber(rx) + " " + uiNumber(ry) + " 0 1 0 " + pt(x-rx, y) + "Z")
	}
	switch m.Kind {
	case "dot":
		if len(n) < 3 {
			return "", [4]float64{}, false
		}
		circle(n[0], n[1], n[2], n[2])
		return d.String(), [4]float64{n[0] - n[2], n[1] - n[2], n[0] + n[2], n[1] + n[2]}, true
	case "oval":
		if len(n) < 4 {
			return "", [4]float64{}, false
		}
		circle(n[0], n[1], n[2]/2, n[3]/2)
		return d.String(), [4]float64{n[0] - n[2]/2, n[1] - n[3]/2, n[0] + n[2]/2, n[1] + n[3]/2}, true
	case "bar":
		if len(n) < 4 {
			return "", [4]float64{}, false
		}
		x0, y0 := n[0]-n[2]/2, n[1]-n[3]/2
		d.WriteString("M" + pt(x0, y0) + "H" + uiNumber(x0+n[2]) + "V" + uiNumber(y0+n[3]) + "H" + uiNumber(x0) + "Z")
		return d.String(), [4]float64{x0, y0, x0 + n[2], y0 + n[3]}, true
	case "patch":
		if len(n) < 6 {
			return "", [4]float64{}, false
		}
		for i := 0; i+1 < len(n); i += 2 {
			if i == 0 {
				d.WriteString("M")
			} else {
				d.WriteString("L")
			}
			d.WriteString(pt(n[i], n[i+1]))
		}
		d.WriteString("Z")
		return d.String(), uiBoxOf(n), true
	case "arc", "wedge":
		if len(n) < 5 || n[2] <= 0 {
			return "", [4]float64{}, false
		}
		x, y, r := n[0], n[1], n[2]
		box := [4]float64{x - r, y - r, x + r, y + r}
		sweep, whole := uiSweep(n[3], n[4])
		if whole {
			circle(x, y, r, r)
			return d.String(), box, true
		}
		x0, y0 := uiOnCircle(x, y, r, n[3])
		x1, y1 := uiOnCircle(x, y, r, n[4])
		large, clockwise := "0", "1"
		if math.Abs(sweep) > math.Pi {
			large = "1"
		}
		if sweep < 0 {
			clockwise = "0"
		}
		if m.Kind == "wedge" {
			d.WriteString("M" + pt(x, y) + "L" + pt(x0, y0))
		} else {
			d.WriteString("M" + pt(x0, y0))
		}
		d.WriteString("A" + uiNumber(r) + " " + uiNumber(r) + " 0 " + large + " " + clockwise + " " + pt(x1, y1))
		if m.Kind == "wedge" {
			d.WriteString("Z")
		}
		return d.String(), box, true
	case "curve":
		if len(n) < 8 {
			return "", [4]float64{}, false
		}
		d.WriteString("M" + pt(n[0], n[1]))
		for i := 2; i+5 < len(n); i += 6 {
			d.WriteString("C" + pt(n[i], n[i+1]) + " " + pt(n[i+2], n[i+3]) + " " + pt(n[i+4], n[i+5]))
		}
		return d.String(), uiBoxOf(n), true
	case "cutout":
		var box [4]float64
		for i, ring := range m.Marks {
			part, b, ok := uiPathData(ring)
			if !ok || ring.Kind == "cutout" || ring.Kind == "arc" || ring.Kind == "curve" {
				continue
			}
			d.WriteString(part)
			if i == 0 {
				box = b
			} else {
				box = uiJoinBox(box, b)
			}
		}
		if d.Len() == 0 {
			return "", [4]float64{}, false
		}
		return d.String(), box, true
	}
	return "", [4]float64{}, false
}

// A gradient laid across a box in the canvas's units, as CSS lays one across a box: through its middle at the angle.
func (r *uiRender) gradient(g UiAttr, box [4]float64) string {
	from, to, angle := uiGradientOf(g)
	r.serial++
	id := "hg" + strconv.Itoa(r.serial)
	dx, dy := math.Cos(angle), math.Sin(angle)
	w, h := box[2]-box[0], box[3]-box[1]
	half := (math.Abs(w*dx) + math.Abs(h*dy)) / 2
	cx, cy := (box[0]+box[2])/2, (box[1]+box[3])/2
	r.out.WriteString("<defs><linearGradient id=\"" + id + "\" gradientUnits=\"userSpaceOnUse\" x1=\"" +
		uiNumber(cx-dx*half) + "\" y1=\"" + uiNumber(cy-dy*half) + "\" x2=\"" + uiNumber(cx+dx*half) + "\" y2=\"" +
		uiNumber(cy+dy*half) + "\"><stop offset=\"0\" stop-color=\"" + uiMarkColour([]UiAttr{{Kind: "paint", Word: from}}) +
		"\"/><stop offset=\"1\" stop-color=\"" + uiMarkColour([]UiAttr{{Kind: "paint", Word: to}}) + "\"/></linearGradient></defs>")
	return id
}

func (r *uiRender) symbol(m UiMark) {
	if len(m.Nums) < 4 {
		return
	}
	n := m.Nums
	r.out.WriteString("<g transform=\"translate(" + uiNumber(n[0]) + " " + uiNumber(n[1]) + ") rotate(" +
		uiNumber(n[2]*180/math.Pi) + ") scale(" + uiNumber(n[3]) + ")\"")
	if o := uiOpacity(m.Attrs); o < 1 {
		r.out.WriteString(" opacity=\"" + uiNumber(o) + "\"")
	}
	r.out.WriteString(">")
	cropped := false
	if c, ok := uiFind(m.Attrs, "crop"); ok && len(c.Nums) == 4 {
		r.serial++
		id := "hc" + strconv.Itoa(r.serial)
		r.out.WriteString("<clipPath id=\"" + id + "\"><rect x=\"" + uiNumber(c.Nums[0]) + "\" y=\"" + uiNumber(c.Nums[1]) +
			"\" width=\"" + uiNumber(c.Nums[2]) + "\" height=\"" + uiNumber(c.Nums[3]) + "\"/></clipPath><g clip-path=\"url(#" + id + ")\">")
		cropped = true
	}
	for _, k := range m.Marks {
		r.mark(k)
	}
	if cropped {
		r.out.WriteString("</g>")
	}
	r.out.WriteString("</g>")
}

// Words are set to exactly the width measure says, so a program that measured them knows where they end.
func (r *uiRender) words(m UiMark) {
	if len(m.Nums) < 3 {
		return
	}
	x, y, height := m.Nums[0], m.Nums[1], m.Nums[2]
	wide := UiMeasure(m.Text, height)
	cx, cy := uiAnchored(m.Attrs, x, y, wide, height)
	r.out.WriteString("<text x=\"" + uiNumber(cx) + "\" y=\"" + uiNumber(cy) + "\" font-size=\"" + uiNumber(height) +
		"\" fill=\"" + uiMarkColour(m.Attrs) + "\" text-anchor=\"middle\" dominant-baseline=\"central\"")
	if wide > 0 {
		r.out.WriteString(" textLength=\"" + uiNumber(wide) + "\" lengthAdjust=\"spacingAndGlyphs\"")
	}
	if w, ok := uiFind(m.Attrs, "weight"); ok {
		r.out.WriteString(" font-weight=\"" + strconv.Itoa(w.Num) + "\"")
	}
	if uiFlagOf(m.Attrs, "italic") {
		r.out.WriteString(" font-style=\"italic\"")
	}
	if o := uiOpacity(m.Attrs); o < 1 {
		r.out.WriteString(" opacity=\"" + uiNumber(o) + "\"")
	}
	r.out.WriteString(" font-family=\"system-ui,-apple-system,sans-serif\">" + uiEscape(m.Text) + "</text>")
}

// The middle of words placed by their start, middle or end across, and their top, middle or bottom down.
func uiAnchored(attrs []UiAttr, x, y, wide, height float64) (float64, float64) {
	if j, ok := uiFind(attrs, "justify"); ok {
		switch j.Word {
		case "Start":
			x += wide / 2
		case "End":
			x -= wide / 2
		}
	}
	if a, ok := uiFind(attrs, "align"); ok {
		switch a.Word {
		case "Start":
			y += height / 2
		case "End":
			y -= height / 2
		}
	}
	return x, y
}

func (r *uiRender) picture(m UiMark) {
	if len(m.Nums) < 4 {
		return
	}
	n := m.Nums
	fit := "none"
	if f, ok := uiFind(m.Attrs, "fit"); ok {
		switch f.Word {
		case "Contain":
			fit = "xMidYMid meet"
		case "Cover":
			fit = "xMidYMid slice"
		}
	}
	r.out.WriteString("<image href=\"")
	uiEscapeTo(&r.out, m.Text)
	r.out.WriteString("\" x=\"" + uiNumber(n[0]-n[2]/2) + "\" y=\"" + uiNumber(n[1]-n[3]/2) + "\" width=\"" + uiNumber(n[2]) +
		"\" height=\"" + uiNumber(n[3]) + "\" preserveAspectRatio=\"" + fit + "\"")
	if o := uiOpacity(m.Attrs); o < 1 {
		r.out.WriteString(" opacity=\"" + uiNumber(o) + "\"")
	}
	r.out.WriteString("/>")
}

// What a mark is painted. A tone naming a role becomes the colour that role is
// on the page, because SVG has no stylesheet to look one up in — and a canvas
// that said "danger" and drew nothing would be worse than one that said nothing.
func uiMarkColour(attrs []UiAttr) string {
	paint, ok := uiFind(attrs, "paint")
	if !ok {
		return "currentColor"
	}
	if colour, is := uiToneColour(paint.Word); is {
		return uiEscape(colour)
	}
	switch paint.Word {
	case "Muted":
		return "var(--muted)"
	case "Good":
		return "var(--good)"
	case "Warn":
		return "var(--warn)"
	case "Danger":
		return "var(--danger)"
	}
	return "currentColor"
}

func uiThick(attrs []UiAttr) float64 {
	thick := uiNumbers(attrs, "thick", []float64{1})
	if thick[0] <= 0 {
		return 1
	}
	return thick[0]
}

// x, y, x, y as SVG wants them. An odd number of them is a place with no second
// half, and it is dropped rather than guessed at.
func uiPoints(nums []float64) string {
	var b strings.Builder
	for i := 0; i+1 < len(nums); i += 2 {
		if i > 0 {
			b.WriteString(" ")
		}
		b.WriteString(uiNumber(nums[i]) + "," + uiNumber(nums[i+1]))
	}
	return b.String()
}

// A number as short as it can be written without losing anything that shows.
// A canvas redrawn sixty times a second is sixty documents a second, and a
// racetrack written to seventeen figures is most of one.
func uiNumber(n float64) string {
	if math.IsNaN(n) || math.IsInf(n, 0) {
		return "0"
	}
	return strconv.FormatFloat(n, 'f', -1, 32)
}

// Where a link may point. The only value in the module that becomes a URL, and
// a URL is executable in one well-known case — so what is allowed is a closed
// set: somewhere within this page, a relative path, or a web or mail address.
// Anything else, javascript: first among them, points at nothing.
func uiHref(raw string) string {
	if raw == "" {
		return "#"
	}
	switch raw[0] {
	case '/', '#', '?':
		return raw
	}
	lower := strings.ToLower(raw)
	if strings.HasPrefix(lower, "http://") ||
		strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "mailto:") {
		return raw
	}

	// No scheme at all is a relative path, which is what a served page mostly
	// wants. A colon before the first slash *is* a scheme, and it is not one of
	// the three above or it would have matched already.
	if i := strings.IndexByte(raw, ':'); i >= 0 {
		if j := strings.IndexByte(raw, '/'); j < 0 || i < j {
			return "#"
		}
	}
	return raw
}

// The backdrop carries the dismiss message rather than the panel, so a click
// outside closes and a click inside does not.
func (r *uiRender) backdrop(attrs []UiAttr) string {
	if r.handlers == nil {
		return ""
	}
	if d, ok := uiFind(attrs, "onDismiss"); ok {
		r.next++
		id := "h" + strconv.Itoa(r.next)
		r.handlers[id] = []UiAttr{{Kind: "on", heard: d.heard}}
		return " data-h=\"" + id + "\" data-backdrop=\"1\""
	}
	return ""
}

func (r *uiRender) disabled(attrs []UiAttr) string {
	if d, ok := uiFind(attrs, "disabled"); ok && d.Flag {
		return " disabled"
	}
	if b, ok := uiFind(attrs, "busy"); ok && b.Flag {
		return " disabled"
	}
	return ""
}

// A headered Table: the first row names the columns and the rest are data. The
// header cells carry the sort message when there is one, and each body row
// carries its own index, so a click says which row rather than which pixel.
func (r *uiRender) table(v UiView) {
	r.out.WriteString("<table")
	r.common(v.Kind, v.Attrs)
	r.out.WriteString(">")
	if len(v.Rows) == 0 {
		r.out.WriteString("</table>")
		return
	}
	sortAttr, sortable := uiFind(v.Attrs, "onSort")
	r.out.WriteString("<thead><tr>")
	for i, head := range v.Rows[0] {
		cell := "<th"
		if r.handlers != nil && sortable {
			r.next++
			id := "h" + strconv.Itoa(r.next)
			r.handlers[id] = []UiAttr{{Kind: "onSort", heard: sortAttr.heard, Num: i}}
			cell += " data-h=\"" + id + "\" data-index=\"" + strconv.Itoa(i) + "\" class=\"h-sortable\""
		}
		r.out.WriteString(cell + ">" + uiEscape(head) + "</th>")
	}
	r.out.WriteString("</tr></thead><tbody>")
	pickAttr, pickable := uiFind(v.Attrs, "onPick")
	for i, row := range v.Rows[1:] {
		line := "<tr"
		if r.handlers != nil && pickable {
			r.next++
			id := "h" + strconv.Itoa(r.next)
			r.handlers[id] = []UiAttr{{Kind: "onPick", heard: pickAttr.heard, Num: i}}
			line += " data-h=\"" + id + "\" data-index=\"" + strconv.Itoa(i) + "\" class=\"h-pickable\""
		}
		r.out.WriteString(line + ">")
		for _, cell := range row {
			r.out.WriteString("<td>" + uiEscape(cell) + "</td>")
		}
		r.out.WriteString("</tr>")
	}
	r.out.WriteString("</tbody></table>")
}

func uiInputType(v string) string {
	switch v {
	case "Number":
		return "number"
	case "Date":
		return "date"
	case "Password":
		return "password"
	case "Search":
		return "search"
	case "Range":
		return "range"
	case "Time":
		return "time"
	case "DateTime":
		return "datetime-local"
	case "Email":
		return "email"
	case "Tel":
		return "tel"
	case "Url":
		return "url"
	case "Color":
		return "color"
	case "File":
		return "file"
	}
	return "text"
}

// The handlers sit on the header row rather than on the branch, so a click in a child is never its parent's.
func (r *uiRender) branch(v UiView) {
	selected := uiFlagOf(v.Attrs, "selected")
	r.out.WriteString("<div class=\"h-branch\" role=\"treeitem\"")
	if len(v.Children) > 0 {
		r.out.WriteString(" aria-expanded=\"" + strconv.FormatBool(v.Flag) + "\"")
	}
	r.out.WriteString(" aria-selected=\"" + strconv.FormatBool(selected) + "\"><div")
	r.common("branch-head", v.Attrs)
	if _, ok := uiFind(v.Attrs, "on"); ok {
		r.out.WriteString(" tabindex=\"0\"")
	}
	r.out.WriteString("><span class=\"h-twisty\"")
	toggle, toggling := uiFind(v.Attrs, "onToggle")
	if len(v.Children) > 0 && r.handlers != nil && toggling {
		r.next++
		id := "h" + strconv.Itoa(r.next)
		r.handlers[id] = []UiAttr{{Kind: "onToggle", heard: toggle.heard}}
		next := ""
		if !v.Flag {
			next = "1"
		}
		r.out.WriteString(" data-h=\"" + id + "\" data-toggle=\"" + next + "\"")
	}
	r.out.WriteString(">")
	if len(v.Children) > 0 {
		if v.Flag {
			r.out.WriteString(uiIconSvg("ChevronDown"))
		} else {
			r.out.WriteString(uiIconSvg("ChevronRight"))
		}
	}
	r.out.WriteString("</span><span class=\"h-label\">")
	uiEscapeTo(&r.out, v.Text)
	r.out.WriteString("</span></div>")
	if v.Flag && len(v.Children) > 0 {
		r.out.WriteString("<div class=\"h-branch-kids\" role=\"group\">")
		for _, c := range v.Children {
			r.view(c)
		}
		r.out.WriteString("</div>")
	}
	r.out.WriteString("</div>")
}

func uiFlagOf(attrs []UiAttr, kind string) bool {
	a, ok := uiFind(attrs, kind)
	return ok && a.Flag
}

func uiIconSvg(name string) string {
	shape, ok := uiIconShapes[name]
	if !ok {
		shape = `<rect x="3" y="3" width="18" height="18" rx="2"/>`
	}
	return `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="2" ` +
		`stroke-linecap="round" stroke-linejoin="round">` + shape + `</svg>`
}

// UiHtml renders a view as a fragment of HTML, with no ids and nothing to talk
// back to. This is what a web server serves: hive.ui.html(view) inside an
// httpServe handler puts the same tree on a page.
func UiHtml(v UiView) string {
	r := &uiRender{}
	r.view(v)
	return r.out.String()
}

// UiPage wraps a fragment in a whole document, stylesheet included, so a server
// can answer a request with one call rather than assembling a page by hand.
//
// ---------------------------------------------------------------------------
// A window on this machine
// ---------------------------------------------------------------------------
func UiPage(title string, v UiView) string {
	return "<!doctype html>\n<html><head><meta charset=\"utf-8\">" +
		"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
		"<title>" + uiEscape(title) + "</title><style>" + uiCSS + "</style></head><body>" +
		"<div class=\"h-root\">" + UiHtml(v) + "</div></body></html>"
}

// The live document. The shell keeps a socket open, swaps in whatever HTML
// arrives, and posts back the id of whatever was interacted with.
//
// Text frames are the document ("H") and the answer to a reported frame ("A");
// a binary frame is the world. The split is what lets a scene be redrawn every
// frame while the document is only re-sent when it changed.
const uiShell = `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<link rel="icon" href="__ICON__">
<style>__CSS__</style></head>
<body><div class="h-root" id="root"></div>
<script>
var sock = new WebSocket("ws://" + location.host + "/_hive/socket?token=__TOKEN__");

` +
	// A Blob would only be readable through a promise; a world has to be read now.
	`sock.binaryType = "arraybuffer";
var root = document.getElementById("root");
var paintScene = null;
var attachScene = null;
var pendingScenes = [];
var sceneQueued = false;

` +
	// Whether the program still owes an answer for the last frame this window
	// reported. Read by tick in the scene module, and by nothing else.
	`var hiveOwed = false;

` +
	// Where a module that draws inside the window registers itself: the first is
	// handed each scene frame, the second is called whenever the document was
	// swapped so whatever it draws on can find its box again.
	`window.hiveSceneReady = function (paint, attach) {
  paintScene = paint;
  attachScene = attach;
  attach();
  flushScene();
};

` +
	// Everything waiting, drawn once, on the next animation frame — rather than
	// each frame the moment it lands, which is how a window a little behind gets
	// further behind, building pictures the next frame overwrites.
	`function flushScene() {
  sceneQueued = false;
  if (!paintScene || !pendingScenes.length) { return; }
  var waiting = pendingScenes;
  pendingScenes = [];
  for (var i = 0; i < waiting.length; i++) { paintScene(waiting[i]); }
}

` +
	// A frame carrying only what changed has to be drawn after the one it was
	// taken from, so it queues; one carrying the whole world empties the queue.
	// Bytes five to eight are the frame followed, nought meaning none.
	//
	// A binary frame is the world, and nothing else is binary.
	//
	// The answer, sent every turn of the fold whether or not anything changed
	// (see uiWindow.publish). It is what keeps one frame in flight instead of
	// sixty a second at a program that may be managing twenty.
	`function keepScene(frame) {
  if (frame.byteLength >= 9 && new DataView(frame).getUint32(5, true) === 0) {
    pendingScenes.length = 0;
  }
  pendingScenes.push(frame);
  if (paintScene && !sceneQueued) {
    sceneQueued = true;
    requestAnimationFrame(flushScene);
  }
}
sock.onmessage = function (e) {
  if (typeof e.data !== "string") { keepScene(e.data); return; }
  var head = e.data.charAt(0);
  if (head === "A") { hiveOwed = false; return; }

` +
	// The canvas is found again only when the page actually changed shape:
	// finding it means reading where its box landed, which forces a layout.
	`  if (head === "P") {
    if (uiApply(e.data.slice(1)) && attachScene) { attachScene(); }
    uiTitle();
    uiCodeSync();
    uiAnchorSync();
    uiAfter();
    return;
  }
  if (uiPatch(e.data.slice(1)) && attachScene) { attachScene(); }
  uiTitle();
  uiCodeSync();
  uiAnchorSync();
  uiAfter();
};

` +
	// The window's title is the outermost widget's `title`, where it gives one:
	// the document's own is what a browser puts on the window and the taskbar.
	`function uiTitle() {
  var top = root.firstElementChild;
  var title = top && top.getAttribute("data-title");
  if (title && document.title !== title) { document.title = title; }
}
sock.onclose = function () { document.body.classList.add("h-closed"); };
function send(id, kind, value, index) {
  if (sock.readyState !== 1) { return; }
  sock.send(JSON.stringify({ id: id, kind: kind, value: String(value), index: index | 0 }));
}

` +
	// How far anything under a node has been scrolled, and where to put it back
	// when that node is replaced. Keyed by the path of child indices, since data-h
	// belongs to elements carrying a message and a scrolled box may carry none.
	`function uiScrolled(node, at, into) {
  if (node.scrollTop || node.scrollLeft) {
    into.push([at, node.scrollTop, node.scrollLeft]);
  }
  for (var i = 0; i < node.children.length; i++) {
    uiScrolled(node.children[i], at + "." + i, into);
  }
  return into;
}
function uiPathFrom(from, at) {
  var node = from;
  var parts = at.split(".");
  for (var i = 1; i < parts.length && node; i++) {
    node = node.children[parts[i] | 0];
  }
  return node || null;
}

` +
	// --- the page, made to match the document -----------------------------------
	//
	// A program hands back a whole document every fold, and this walks it against
	// the page rather than assigning it to root.innerHTML: same tag, patch and
	// descend; different tag, swap; text that differs, write the text. What the
	// browser lays out again is then what actually moved, which on a racing HUD is
	// four numbers rather than eight hundred elements.
	//
	// Positional and not keyed, because a view rendered by the same code from a
	// model that changed a little is the same tree with different numbers in it.
	// Where that is wrong the tags disagree and the node is swapped.
	//
	// uiPatch answers with how many nodes were added, removed or swapped — nought
	// on nearly every frame, and what tells a scene its box may have moved.
	`var draft = document.createElement("div");
var moved = 0;

function uiPatch(html) {
  draft.innerHTML = html;
  moved = 0;
  uiPatchKids(root, draft);
  return moved;
}

` +
	// The same patcher, handed only the nodes that changed. Each edit names one by
	// the child indices that reach it and carries that node's HTML, so what the
	// browser parses is the four numbers that moved rather than the page holding
	// them. An edit naming nothing is the whole document, which is what a page
	// that has just arrived is sent.
	//
	// Edits never nest — the difference either descends into a node or hands it
	// over — so a path is still true by the time this walks it.
	`function uiApply(text) {
  var edits = JSON.parse(text);
  moved = 0;
  for (var i = 0; i < edits.length; i++) {
    var at = edits[i][0];
    if (at === "") {
      draft.innerHTML = edits[i][1];
      uiPatchKids(root, draft);
      continue;
    }
    var node = uiNodeAt(at);
    if (!node) { continue; }
    var fresh = uiParseIn(node.parentNode, edits[i][1]);
    if (fresh) { uiPatchNode(node.parentNode, node, fresh); }
  }
  return moved;
}

` +
	// Parsed inside its own parent: a div drops a lone tr or td down to its text,
	// and makes an svg mark an HTML element that draws nothing.
	`var cut = document.createRange();

function uiParseIn(parent, html) {
  cut.selectNodeContents(parent);
  return cut.createContextualFragment(html).firstChild;
}

function uiNodeAt(at) {
  var node = root, parts = at.split(".");
  for (var i = 0; i < parts.length && node; i++) {
    node = node.childNodes[parts[i] | 0];
  }
  return node || null;
}

function uiPatchKids(live, next) {
  var a = live.firstChild, b = next.firstChild;
  while (a && b) {

` +
	// Both read first: patching takes b out of next, and may take a out of live.
	`    var an = a.nextSibling, bn = b.nextSibling;
    uiPatchNode(live, a, b);
    a = an;
    b = bn;
  }
  while (a) {
    var gone = a.nextSibling;
    live.removeChild(a);
    moved++;
    a = gone;
  }
  while (b) {
    var after = b.nextSibling;
    live.appendChild(b);
    moved++;
    b = after;
  }
}

function uiPatchNode(parent, a, b) {
  if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName) {
    uiSwapNode(parent, a, b);
    return;
  }
  if (a.nodeType === 3) {
    if (a.nodeValue !== b.nodeValue) { a.nodeValue = b.nodeValue; }
    return;
  }
  if (a.nodeType !== 1) { return; }
  var name = a.nodeName;

` +
	// Read before the children are patched, because patching takes them out of
	// the document being read from: a select's options, and the text a textarea
	// holds its value in. Reading either afterwards finds it empty, and a
	// textarea a reader had just started typing into would be emptied with it.
	`  var pick = name === "SELECT" ? uiChosenIn(b) : null;
  var written = name === "TEXTAREA" ? b.textContent : null;
  uiPatchAttrs(a, b);
  uiPatchKids(a, b);
  uiDress(a, b, name, pick, written);
}

function uiPatchAttrs(a, b) {
  var want = b.attributes, have = a.attributes, i;
  for (i = 0; i < want.length; i++) {
    var one = want[i];
    if (a.getAttribute(one.name) !== one.value) { a.setAttribute(one.name, one.value); }
  }

` +
	// Backwards, because removing one shortens the list under the loop.
	`  for (i = have.length - 1; i >= 0; i--) {
    var was = have[i].name;
    if (!b.hasAttribute(was)) { a.removeAttribute(was); }
  }
}

` +
	// What an element shows that is not written in its attributes. Once a reader
	// has typed in a field its value is a property, so setting the attribute alone
	// would leave the page showing something the program never said.
	`function uiDress(a, b, name, pick, written) {
  if (name === "INPUT") {
    if (a.type === "checkbox" || a.type === "radio") {
      var on = b.hasAttribute("checked");
      if (a.checked !== on) { a.checked = on; }
      return;
    }
    if (a.type === "file") { return; }
    var want = b.getAttribute("value");
    if (want !== null && a.value !== want) { a.value = want; }
    return;
  }
  if (name === "TEXTAREA") {
    if (a.classList.contains("h-mono")) { uiCodeDress(a, written); return; }
    if (a.value !== written) { a.value = written; }
    return;
  }
  if (name === "SELECT" && pick !== null && a.value !== pick) { a.value = pick; }
}

function uiChosenIn(el) {
  var opts = el.getElementsByTagName("option");
  for (var i = 0; i < opts.length; i++) {
    if (opts[i].hasAttribute("selected")) { return opts[i].getAttribute("value"); }
  }
  return null;
}

` +
	// A node that has genuinely become a different node. What the reader had done
	// to the old one and the document does not say — where it was scrolled to, and
	// the cursor in it — is carried across.
	//
	// A link carrying a message means the message. Its href is the fallback for
	// a render with no socket behind it, and following it here would navigate
	// away from the very window the message was meant to update.
	`function uiSwapNode(parent, a, b) {
  var scrolled = a.nodeType === 1 ? uiScrolled(a, "", []) : [];
  var mark = null, start = null;
  var here = document.activeElement;
  if (here && a.nodeType === 1 && a.contains(here)) {
    mark = here.getAttribute ? here.getAttribute("data-h") : null;
    start = here.selectionStart;
  }
  parent.replaceChild(b, a);
  moved++;
  for (var s = 0; s < scrolled.length; s++) {
    var box = uiPathFrom(b, scrolled[s][0]);
    if (box) { box.scrollTop = scrolled[s][1]; box.scrollLeft = scrolled[s][2]; }
  }
  if (mark && b.nodeType === 1) {
    var again = b.querySelector('[data-h="' + mark + '"]');
    if (again && again.focus) {
      again.focus();
      if (start != null && again.setSelectionRange) {
        try { again.setSelectionRange(start, start); } catch (err) {}
      }
    }
  }
}
function holder(el) {
  while (el && el !== root) {
    if (el.getAttribute && el.getAttribute("data-h")) { return el; }
    el = el.parentNode;
  }
  return null;
}
function anchorUnder(el, stop) {
  while (el && el !== stop) {
    if (el.tagName === "A") { return true; }
    el = el.parentNode;
  }
  return false;
}
root.addEventListener("click", function (e) {
  var el = holder(e.target);
  if (!el) { return; }
  if (el.getAttribute("data-backdrop") && e.target !== el) { return; }
  if (el.tagName === "A") {
    e.preventDefault();
  } else if (anchorUnder(e.target, el)) {

` +
	// A plain link inside something that does carry a message: the link is the
	// more specific thing the click landed on, so it navigates and the
	// surrounding message goes unsent.
	`    return;
  }
  var idx = parseInt(el.getAttribute("data-index") || "0", 10);
  settled = true;
  uiClicked(el, idx);
});
function uiClicked(el, idx) {
  var turned = el.getAttribute("data-toggle");
  if (turned !== null) { send(el.getAttribute("data-h"), "toggle", turned, 0); }
  else { send(el.getAttribute("data-h"), "click", "", idx); }
}

` +
	// A click is a press and a release on the same node, and a repaint between the
	// two that swaps that node leaves the browser with two different elements and
	// no click at all. Invisible in a static window, total in one drawing a world.
	//
	// So the press is remembered by handle rather than by node, and the release
	// decides. The browser's own click still wins wherever it happens, being
	// dispatched before a task queued from the mouseup, so this only speaks up when
	// none arrived.
	`var pressedOn = "";
var settled = false;
root.addEventListener("mousedown", function (e) {
  var el = holder(e.target);
  pressedOn = el && el.tagName !== "A" ? el.getAttribute("data-h") : "";
});
root.addEventListener("mouseup", function (e) {
  var el = holder(e.target);
  var was = pressedOn;
  pressedOn = "";
  if (!el || el.tagName === "A" || el.disabled) { return; }
  var id = el.getAttribute("data-h");
  if (!id || id !== was) { return; }
  if (el.getAttribute("data-backdrop") && e.target !== el) { return; }
  if (anchorUnder(e.target, el)) { return; }
  var idx = parseInt(el.getAttribute("data-index") || "0", 10);
  settled = false;
  setTimeout(function () {
    if (settled) { return; }
    uiClicked(el, idx);
  }, 0);
});
root.addEventListener("input", function (e) {
  var el = holder(e.target);
  if (!el) { return; }
  var t = e.target;
  if (t.type === "radio" || t.type === "file") { return; }
  if (t.type === "checkbox") { send(el.getAttribute("data-h"), "toggle", t.checked ? "1" : "", 0); }
  else { send(el.getAttribute("data-h"), "input", t.value, 0); }
});
root.addEventListener("change", function (e) {
  var el = holder(e.target), t = e.target;
  if (!el) { return; }
  if (t.tagName === "SELECT" || t.type === "radio") { send(el.getAttribute("data-h"), "choose", t.value, 0); }
  else if (t.type === "file") { uiSendFiles(el, t.files); }
});

` +
	// A key a widget took with `keys`: the innermost one around the focus that
	// names it, or names Any, hears it, and the page does nothing else with it.
	// The name is what the key types when nothing but Shift is held, and the key
	// itself — modifiers first, Ctrl then Shift then Alt — when anything else is.
	`var uiPunct = {Backquote: "\x60", Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]",
  Backslash: "\\", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/", IntlBackslash: "\\"};
function uiKeyName(e) {
  var key = e.key;
  if (key === "Control" || key === "Shift" || key === "Alt" || key === "Meta" || key === "AltGraph") { return ""; }
  var held = e.ctrlKey || e.metaKey || e.altKey;
  if (key === " ") { key = "Space"; }
  else if (key === "Esc") { key = "Escape"; }
  else if (key === "Dead" || key === "Unidentified" || (key.length === 1 && held)) {
    var code = e.code || "";
    if (code.indexOf("Key") === 0) { key = code.slice(3); }
    else if (code.indexOf("Digit") === 0) { key = code.slice(5); }
    else if (uiPunct[code]) { key = uiPunct[code]; }
    else if (key.length === 1) { key = key.toUpperCase(); }
    else { return ""; }
  } else if (key.length === 1) { return key; }
  return (e.ctrlKey || e.metaKey ? "Ctrl+" : "") + (e.shiftKey ? "Shift+" : "") + (e.altKey ? "Alt+" : "") + key;
}
document.addEventListener("keydown", function (e) {
  if (e.isComposing) { return; }
  var name = uiKeyName(e);
  if (!name) { return; }
  if (uiClaim(e, name)) { return; }
  var ta = e.target;
  if (ta && ta.classList && ta.classList.contains("h-mono") && !ta.disabled) {
    if (name === "Tab") { e.preventDefault(); uiCodeType(ta, "\t"); }
    else if (name === "Enter") {
      e.preventDefault();
      var start = ta.value.lastIndexOf("\n", ta.selectionStart - 1) + 1;
      var indent = /^[\t ]*/.exec(ta.value.slice(start, ta.selectionStart))[0];
      uiCodeType(ta, "\n" + indent);
    }
  }
}, true);
document.addEventListener("paste", function (e) {
  var el = uiHearer(e.target, "paste");
  if (!el) { return; }
  e.preventDefault();
  send(el.getAttribute("data-h"), "paste", (e.clipboardData || window.clipboardData).getData("text"), 0);
}, true);
function uiClaim(e, name) {
  if ((name === "Ctrl+V" || name === "Shift+Insert") && uiHearer(e.target, "paste")) { return false; }
  var el = e.target && root.contains(e.target) ? e.target : root.firstElementChild;
  for (; el && el !== root; el = el.parentNode) {
    var keys = el.getAttribute && el.getAttribute("data-keys");
    if (!keys || !el.getAttribute("data-h")) { continue; }
    var list = keys.split(" ");
    if (list.indexOf(name) < 0 && list.indexOf("Any") < 0) { continue; }
    e.preventDefault();
    e.stopPropagation();
    send(el.getAttribute("data-h"), "key", name, 0);
    return true;
  }
  return false;
}

` +
	// A code editor. The textarea is what is typed into and the pre under it is
	// what is seen; an edit is told to the program as what it replaced, counted in
	// characters, and painted into the pre's own text at once so nothing waits on
	// the program to be seen. The program's next document repaints it properly.
	//
	// What has been typed is kept until the program has seen it, as a native field
	// keeps it: a document that answers an older edit does not take back a newer one.
	`var uiSurrogate = /[\uD800-\uDFFF]/;
function uiRunes(s, units) {
  if (!uiSurrogate.test(s)) { return units; }
  var n = 0;
  for (var i = 0; i < units; i++) { var c = s.charCodeAt(i); if (c < 0xDC00 || c > 0xDFFF) { n++; } }
  return n;
}
function uiUnits(s, runes) {
  if (!uiSurrogate.test(s)) { return Math.max(0, Math.min(runes, s.length)); }
  var i = 0, n = 0;
  while (i < s.length && n < runes) { var c = s.charCodeAt(i); i += c >= 0xD800 && c < 0xDC00 ? 2 : 1; n++; }
  return i;
}
function uiCodeState(ta) {
  if (!ta.__code) { ta.__code = { value: ta.value, sent: [], caret: null, told: null, view: null }; }
  return ta.__code;
}
function uiCodeType(ta, text) {
  if (!document.execCommand("insertText", false, text)) {
    ta.setRangeText(text, ta.selectionStart, ta.selectionEnd, "end");
    ta.dispatchEvent(new Event("input", { bubbles: true }));
  }
}
document.addEventListener("input", function (e) {
  var ta = e.target;
  if (!ta || !ta.classList || !ta.classList.contains("h-mono")) { return; }
  e.stopPropagation();
  var box = ta.closest(".h-code"), s = uiCodeState(ta);
  var was = s.value, now = ta.value, a = 0, top = Math.min(was.length, now.length);
  while (a < top && was.charCodeAt(a) === now.charCodeAt(a)) { a++; }
  var zw = was.length, zn = now.length;
  while (zw > a && zn > a && was.charCodeAt(zw - 1) === now.charCodeAt(zn - 1)) { zw--; zn--; }
  if (a > 0 && (was.charCodeAt(a - 1) & 0xFC00) === 0xD800) { a--; }
  if (zw < was.length && (was.charCodeAt(zw) & 0xFC00) === 0xDC00) { zw++; zn++; }
  s.value = now;
  s.sent.push(now);
  if (s.sent.length > 64) { s.sent.shift(); }
  uiCodePaint(box, a, zw, now.slice(a, zn));
  var id = box && box.getAttribute("data-h");
  if (!id) { return; }
  send(id, "edit", uiRunes(was, a) + "," + uiRunes(was, zw) + "," + now.slice(a, zn), 0);
  if (box.hasAttribute("data-whole")) { send(id, "input", now, 0); }
}, true);
function uiCodePaint(box, a, z, text) {
  var pre = box && box.querySelector(".h-runs");
  if (!pre) { return; }
  var walk = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT), node, at = 0, first = null;
  while ((node = walk.nextNode())) {
    var len = node.nodeValue.length, end = at + len;
    if (first === null && a <= end) {
      var v = node.nodeValue;
      node.nodeValue = v.slice(0, a - at) + text + v.slice(Math.min(z, end) - at);
      first = node;
      if (z <= end) { break; }
    } else if (first !== null) {
      node.nodeValue = node.nodeValue.slice(Math.min(z, end) - at);
      if (z <= end) { break; }
    }
    at = end;
  }
}
function uiCodeDress(ta, written) {
  var s = uiCodeState(ta);
  if (ta.value === written) { s.sent = []; s.value = written; return; }
  if (document.activeElement === ta) {
    var seen = s.sent.lastIndexOf(written);
    if (seen >= 0) { s.sent = s.sent.slice(seen + 1); return; }
  }
  var from = ta.selectionStart, to = ta.selectionEnd, top = ta.scrollTop, left = ta.scrollLeft;
  ta.value = written;
  s.value = written;
  s.sent = [];
  ta.setSelectionRange(Math.min(from, written.length), Math.min(to, written.length));
  ta.scrollTop = top;
  ta.scrollLeft = left;
}

` +
	// After every document: a selection the program set is put where it said, the
	// copy and the numbers follow the textarea's scroll, and the lines in view are
	// told where they changed.
	`function uiCodeSync() {
  var boxes = root.querySelectorAll(".h-code");
  for (var i = 0; i < boxes.length; i++) {
    var box = boxes[i], ta = box.querySelector(".h-mono");
    if (!ta) { continue; }
    var font = box.getAttribute("data-font");
    box.style.fontSize = font ? font + "px" : "";
    var s = uiCodeState(ta), want = box.getAttribute("data-caret");
    if (want !== null && want !== s.caret) {
      s.caret = want;
      var p = want.split(","), v = ta.value;
      s.told = p[0] + "," + p[1];
      var anchor = uiUnits(v, p[0] | 0), head = uiUnits(v, p[1] | 0);
      ta.setSelectionRange(Math.min(anchor, head), Math.max(anchor, head), head < anchor ? "backward" : "forward");
      uiCodeReveal(ta, head);
    }
    uiCodeScrolled(box, ta);
  }
  var clips = root.querySelectorAll("[data-clip]");
  for (var c = 0; c < clips.length; c++) {
    var holder = clips[c], serial = holder.getAttribute("data-clip");
    if (holder.__clip !== undefined && holder.__clip !== serial && navigator.clipboard) {
      navigator.clipboard.writeText(holder.getAttribute("data-clip-text")).catch(function () {});
    }
    holder.__clip = serial;
  }
  var asks = root.querySelectorAll("[data-perform]");
  for (var p = 0; p < asks.length; p++) {
    var field = asks[p], said = field.getAttribute("data-perform");
    var seen = field.__perform;
    field.__perform = said;
    if (seen === undefined || seen === said) { continue; }
    var command = said.slice(0, said.lastIndexOf(","));
    var area = field.matches("input,textarea") ? field : field.querySelector("textarea,input");
    if (!area) { continue; }
    area.focus();
    if (command === "selectAll") { area.select(); }
    else if (command === "paste") {
      if (navigator.clipboard && navigator.clipboard.readText) {
        navigator.clipboard.readText().then(function (text) { document.execCommand("insertText", false, text); }).catch(function () {});
      }
    } else { document.execCommand(command); }
  }
  var asked = root.querySelectorAll("[data-focus]");
  for (var k = 0; k < asked.length; k++) {
    var el = asked[k], want = el.getAttribute("data-focus");
    if (el.__focus === want) { continue; }
    el.__focus = want;
    var target = el.matches("input,textarea,select,button,a") ? el : el.querySelector("textarea,input,select,button,a");
    if (target && target.focus) { target.focus(); }
  }
}
function uiCodeLine(ta) {
  var lh = parseFloat(getComputedStyle(ta).lineHeight);
  return lh > 0 ? lh : 19.5;
}
var uiMeasure = null;
function uiCodeReveal(ta, head) {
  var v = ta.value, lh = uiCodeLine(ta), pad = 8;
  var start = v.lastIndexOf("\n", head - 1) + 1, line = 0;
  for (var i = 0; i < start; i++) { if (v.charCodeAt(i) === 10) { line++; } }
  var y = pad + line * lh;
  if (y < ta.scrollTop + pad) { ta.scrollTop = Math.max(0, y - pad); }
  else if (y + lh > ta.scrollTop + ta.clientHeight - pad) { ta.scrollTop = y + lh - ta.clientHeight + pad; }
  if (!uiMeasure) { uiMeasure = document.createElement("canvas").getContext("2d"); }
  uiMeasure.font = getComputedStyle(ta).font;
  var tab = parseInt(ta.style.tabSize, 10) || 4, cols = 0;
  for (var j = start; j < head; j++) { cols = v.charCodeAt(j) === 9 ? (Math.floor(cols / tab) + 1) * tab : cols + 1; }
  var x = 12 + cols * uiMeasure.measureText("M").width;
  if (x < ta.scrollLeft + 12) { ta.scrollLeft = Math.max(0, x - 40); }
  else if (x > ta.scrollLeft + ta.clientWidth - 12) { ta.scrollLeft = x - ta.clientWidth + 40; }
}
function uiCodeScrolled(box, ta) {
  var pre = box.querySelector(".h-runs"), gutter = box.querySelector(".h-gutter");
  var top = ta.scrollTop, left = ta.scrollLeft, lh = uiCodeLine(ta);
  if (pre) { pre.style.transform = "translate(" + -left + "px," + -top + "px)"; }
  if (gutter) { gutter.style.transform = "translateY(" + -top + "px)"; }
  var cur = box.querySelector(".h-curline");
  if (cur) {
    var v = ta.value, at = ta.selectionStart, line = 0;
    if (document.activeElement === ta && ta.selectionStart === ta.selectionEnd) {
      for (var i = 0; i < at; i++) { if (v.charCodeAt(i) === 10) { line++; } }
      cur.style.display = "block";
      cur.style.height = lh + "px";
      cur.style.transform = "translateY(" + (8 + line * lh - top) + "px)";
    } else {
      cur.style.display = "none";
    }
  }
  var id = box.getAttribute("data-h");
  if (!id) { return; }
  var lines = 1;
  for (var k = 0; k < ta.value.length; k++) { if (ta.value.charCodeAt(k) === 10) { lines++; } }
  var first = Math.max(0, Math.floor((top) / lh));
  var last = Math.min(lines - 1, Math.floor((top + ta.clientHeight - 16) / lh));
  var view = first + "," + Math.max(first, last), s = uiCodeState(ta);
  if (view !== s.view) { s.view = view; send(id, "view", view, 0); }
  var fit = Math.max(1, Math.floor((ta.clientWidth - 24) / uiCodeCell(ta))) + "," + Math.max(1, Math.floor((ta.clientHeight - 16) / lh));
  if (fit !== s.fit) { s.fit = fit; send(id, "fit", fit, 0); }
}
document.addEventListener("scroll", function (e) {
  var ta = e.target;
  if (ta && ta.classList && ta.classList.contains("h-mono")) { uiCodeScrolled(ta.closest(".h-code"), ta); }
}, true);
window.addEventListener("resize", function () { uiCodeSync(); uiAnchorSync(); });

` +
	// The pointer's own events: a right click, a middle click, a double click, a
	// drag. Each goes to the innermost element around the pointer that hears it.
	`function uiInWorld(el) {
  var world = el && el.closest && el.closest(".h-world");
  return world && window.uiWorldHost ? window.uiWorldHost() || el : el;
}
function uiHearer(el, ev) {
  for (el = uiInWorld(el); el && el !== root && el.getAttribute; el = el.parentNode) {
    var heard = el.getAttribute("data-ev");
    if (heard && el.getAttribute("data-h") && (" " + heard + " ").indexOf(" " + ev + " ") >= 0) { return el; }
  }
  return null;
}
var uiSpot = { x: 0, y: 0 }, uiDragging = null, uiDragOwed = false;
document.addEventListener("mousedown", function (e) {
  uiSpot = { x: e.clientX, y: e.clientY };
  var open = root.querySelectorAll(".h-anchored[data-h]");
  for (var i = 0; i < open.length; i++) {
    var panel = open[i].firstElementChild;
    if (panel && !panel.contains(e.target)) { send(open[i].getAttribute("data-h"), "click", "", 0); }
  }
  if (e.button === 1 && uiHearer(e.target, "middle")) { e.preventDefault(); }
  if (e.button !== 0) { return; }
  var ta = e.target;
  if ((e.ctrlKey || e.metaKey) && ta.classList && ta.classList.contains("h-mono")) {
    var box = uiHearer(ta, "jump"), at = box ? uiCodeAt(ta, e.clientX, e.clientY) : -1;
    if (at >= 0) { send(box.getAttribute("data-h"), "jump", at, 0); }
  }
  var drag = uiHearer(e.target, "drag");
  if (!drag || (e.target !== drag && e.target.closest("input,textarea,select,button,a"))) { return; }
  e.preventDefault();
  uiDragging = { id: drag.getAttribute("data-h"), x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
}, true);
document.addEventListener("mousemove", function (e) {
  if (uiDragging) {
    uiDragging.dx = Math.round(e.clientX - uiDragging.x);
    uiDragging.dy = Math.round(e.clientY - uiDragging.y);
    if (!uiDragOwed) {
      uiDragOwed = true;
      requestAnimationFrame(function () {
        uiDragOwed = false;
        if (uiDragging) { send(uiDragging.id, "drag", uiDragging.dx + "," + uiDragging.dy + ",0", 0); }
      });
    }
    return;
  }
  var ta = e.target;
  if (!ta.classList || !ta.classList.contains("h-mono")) { return; }
  var box = uiHearer(ta, "hover");
  if (!box) { return; }
  var at = uiCodeAt(ta, e.clientX, e.clientY), s = uiCodeState(ta);
  if (at !== s.hover) { s.hover = at; send(box.getAttribute("data-h"), "hover", at, 0); }
}, true);
var uiProbeAt = null;
function uiProbe(ta, x, y, ctrl) {
  var box = uiHearer(ta, "probe");
  if (!box) { return; }
  var at = ctrl ? uiCodeAt(ta, x, y) : -1, s = uiCodeState(ta);
  ta.closest(".h-code").classList.toggle("h-ctrl", ctrl && at >= 0);
  if (at !== s.probe && (s.probe !== undefined || at >= 0)) { s.probe = at; send(box.getAttribute("data-h"), "probe", at, 0); }
}
document.addEventListener("mousemove", function (e) {
  var ta = e.target;
  if (!ta.classList || !ta.classList.contains("h-mono")) { uiProbeAt = null; return; }
  uiProbeAt = { ta: ta, x: e.clientX, y: e.clientY };
  uiProbe(ta, e.clientX, e.clientY, e.ctrlKey || e.metaKey);
}, true);
["keydown", "keyup"].forEach(function (name) {
  document.addEventListener(name, function (e) {
    if ((e.key === "Control" || e.key === "Meta") && uiProbeAt) {
      uiProbe(uiProbeAt.ta, uiProbeAt.x, uiProbeAt.y, name === "keydown");
    }
  }, true);
});
document.addEventListener("mouseout", function (e) {
  var ta = e.target;
  if (ta && ta.classList && ta.classList.contains("h-mono")) {
    var s = uiCodeState(ta), owner = uiHearer(ta, "probe");
    if (owner && s.probe !== undefined && s.probe !== -1) { s.probe = -1; send(owner.getAttribute("data-h"), "probe", -1, 0); }
  }
  if (!ta.classList || !ta.classList.contains("h-mono")) { return; }
  var box = uiHearer(ta, "hover"), s = uiCodeState(ta);
  if (box && s.hover !== -1 && s.hover !== undefined) { s.hover = -1; send(box.getAttribute("data-h"), "hover", -1, 0); }
}, true);
document.addEventListener("mouseup", function () {
  if (!uiDragging) { return; }
  var d = uiDragging;
  uiDragging = null;
  send(d.id, "drag", d.dx + "," + d.dy + ",1", 0);
}, true);
document.addEventListener("contextmenu", function (e) {
  uiSpot = { x: e.clientX, y: e.clientY };
  var el = uiHearer(e.target, "menu");
  if (!el) { return; }
  e.preventDefault();
  send(el.getAttribute("data-h"), "menu", "", 0);
}, true);
document.addEventListener("auxclick", function (e) {
  var el = e.button === 1 && uiHearer(e.target, "middle");
  if (!el) { return; }
  e.preventDefault();
  send(el.getAttribute("data-h"), "middle", "", 0);
}, true);
document.addEventListener("dblclick", function (e) {
  var el = uiHearer(e.target, "double");
  if (el) { send(el.getAttribute("data-h"), "double", "", 0); }
}, true);

` +
	// The character of a code editor under a point, -1 where there is none: past
	// the end of its line, or below its last.
	`function uiCodeCell(ta) {
  if (!uiMeasure) { uiMeasure = document.createElement("canvas").getContext("2d"); }
  uiMeasure.font = getComputedStyle(ta).font;
  return uiMeasure.measureText("M").width || 8;
}
function uiCodeAt(ta, x, y) {
  var r = ta.getBoundingClientRect(), lh = uiCodeLine(ta), cw = uiCodeCell(ta), v = ta.value;
  var line = Math.floor((y - r.top - 8 + ta.scrollTop) / lh), col = (x - r.left - 12 + ta.scrollLeft) / cw;
  if (line < 0 || col < 0) { return -1; }
  var at = 0;
  for (var l = 0; l < line; l++) { at = v.indexOf("\n", at); if (at < 0) { return -1; } at++; }
  var tab = parseInt(ta.style.tabSize, 10) || 4, c = 0;
  for (var i = at; i < v.length && v.charCodeAt(i) !== 10; i++) {
    var next = v.charCodeAt(i) === 9 ? (Math.floor(c / tab) + 1) * tab : c + 1;
    if (col < next) { return uiRunes(v, i); }
    c = next;
  }
  return -1;
}

` +
	// An anchored overlay opens where the pointer was last pressed, or under the
	// caret of the code editor being typed in, and never past the window's edge:
	// what does not fit below goes above.
	`function uiAnchorSync() {
  var open = root.querySelectorAll(".h-anchored");
  for (var i = 0; i < open.length; i++) {
    var panel = open[i].firstElementChild;
    if (!panel) { continue; }
    var x = uiSpot.x, y = uiSpot.y, above = y;
    var ta = document.activeElement;
    if (open[i].getAttribute("data-anchor") === "Caret" && ta && ta.classList && ta.classList.contains("h-mono")) {
      var r = ta.getBoundingClientRect(), lh = uiCodeLine(ta), cw = uiCodeCell(ta), v = ta.value, at = ta.selectionEnd;
      var start = v.lastIndexOf("\n", at - 1) + 1, line = 0, tab = parseInt(ta.style.tabSize, 10) || 4, c = 0;
      for (var k = 0; k < start; k++) { if (v.charCodeAt(k) === 10) { line++; } }
      for (var j = start; j < at; j++) { c = v.charCodeAt(j) === 9 ? (Math.floor(c / tab) + 1) * tab : c + 1; }
      x = r.left + 12 + c * cw - ta.scrollLeft;
      above = r.top + 8 + line * lh - ta.scrollTop;
      y = above + lh;
    }
    var w = panel.offsetWidth, h = panel.offsetHeight;
    x = Math.max(4, Math.min(x, window.innerWidth - w - 4));
    if (y + h > window.innerHeight - 4) { y = Math.max(4, Math.min(above - h, window.innerHeight - h - 4)); }
    panel.style.left = x + "px";
    panel.style.top = Math.max(4, y) + "px";
  }
}
var uiCaretOwed = false;
document.addEventListener("selectionchange", function () {
  var ta = document.activeElement;
  if (!ta || !ta.classList || !ta.classList.contains("h-mono") || uiCaretOwed) { return; }
  uiCaretOwed = true;
  requestAnimationFrame(function () {
    uiCaretOwed = false;
    var box = ta.closest(".h-code");
    if (!box) { return; }
    uiCodeScrolled(box, ta);
    var v = ta.value, s = uiCodeState(ta), back = ta.selectionDirection === "backward";
    var anchor = uiRunes(v, back ? ta.selectionEnd : ta.selectionStart);
    var head = uiRunes(v, back ? ta.selectionStart : ta.selectionEnd);
    var said = anchor + "," + head, id = box.getAttribute("data-h");
    if (said !== s.told && id) { s.told = said; send(id, "caret", said, 0); }
    uiAnchorSync();
  });
});
root.addEventListener("keydown", function (e) {
  if (e.key !== "Enter" || e.shiftKey) { return; }
  var el = holder(e.target);
  if (!el || e.target.tagName === "TEXTAREA") { return; }
  send(el.getAttribute("data-h"), "submit", e.target.value, 0);
});
root.addEventListener("keydown", function (e) {
  var t = e.target;
  if (!t.classList || !t.classList.contains("h-branch-head")) { return; }
  if ((e.key === "Enter" || e.key === " ") && t.getAttribute("data-h")) {
    e.preventDefault();
    send(t.getAttribute("data-h"), "click", "", 0);
  } else if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
    var twisty = t.querySelector(".h-twisty[data-h]");
    if (twisty && (twisty.getAttribute("data-toggle") === "1") === (e.key === "ArrowRight")) {
      e.preventDefault();
      uiClicked(twisty, 0);
    }
  }
});
function uiHears(el, ev) {
  var heard = el.getAttribute && el.getAttribute("data-ev");
  return !!heard && !!el.getAttribute("data-h") && (" " + heard + " ").indexOf(" " + ev + " ") >= 0;
}

` +
	// A canvas answers in its own units, through the matrix the browser drew it with.
	`function uiLocal(el, e) {
  if (el.tagName === "svg" && el.getScreenCTM && el.getScreenCTM()) {
    var p = el.createSVGPoint();
    p.x = e.clientX;
    p.y = e.clientY;
    p = p.matrixTransform(el.getScreenCTM().inverse());
    return p.x + "," + p.y;
  }
  var r = el.getBoundingClientRect();
  return (e.clientX - r.left) + "," + (e.clientY - r.top);
}
var uiReleasing = null, uiPointing = null, uiPointAt = null, uiPointOwed = false;
document.addEventListener("pointerdown", function (e) {
  var el = uiHearer(e.target, "press");
  if (el) { send(el.getAttribute("data-h"), "press", uiLocal(el, e), 0); }
  uiReleasing = uiHearer(e.target, "release");
  uiPointing = uiHearer(e.target, "point");
}, true);
document.addEventListener("pointermove", function (e) {
  var el = e.buttons && uiPointing && root.contains(uiPointing) ? uiPointing : uiHearer(e.target, "point");
  if (!el) { return; }
  uiPointAt = [el, uiLocal(el, e)];
  if (uiPointOwed) { return; }
  uiPointOwed = true;
  requestAnimationFrame(function () {
    uiPointOwed = false;
    var at = uiPointAt;
    uiPointAt = null;
    if (at && root.contains(at[0])) { send(at[0].getAttribute("data-h"), "point", at[1], 0); }
  });
}, true);
document.addEventListener("pointerup", function (e) {
  var el = uiReleasing;
  uiReleasing = null;
  uiPointing = null;
  if (el && root.contains(el)) { send(el.getAttribute("data-h"), "release", uiLocal(el, e), 0); }
}, true);
document.addEventListener("pointercancel", function () { uiReleasing = null; uiPointing = null; }, true);
function uiCrossed(at, other, ev) {
  at = uiInWorld(at);
  other = uiInWorld(other);
  if (at === other) { return; }
  for (var el = at; el && el !== root && el.getAttribute; el = el.parentNode) {
    if (uiHears(el, ev) && !(other && el.contains(other))) { send(el.getAttribute("data-h"), ev, "", 0); }
  }
}
document.addEventListener("pointerover", function (e) { uiCrossed(e.target, e.relatedTarget, "enter"); }, true);
document.addEventListener("pointerout", function (e) { uiCrossed(e.target, e.relatedTarget, "leave"); }, true);

` +
	// The window itself losing the focus is not a widget losing it: the same element has it back on return.
	`var uiParked = null;
document.addEventListener("focusout", function (e) {
  var from = e.target, to = e.relatedTarget;
  if (to) { uiCrossed(from, to, "blur"); return; }
  setTimeout(function () {
    if (!document.hasFocus() && document.activeElement === from) { uiParked = from; return; }
    var now = document.activeElement;
    uiCrossed(from, now && now !== document.body ? now : null, "blur");
  }, 0);
}, true);
document.addEventListener("focusin", function (e) {
  if (uiParked && e.target === uiParked && !e.relatedTarget) { uiParked = null; return; }
  uiParked = null;
  uiCrossed(e.target, e.relatedTarget, "focus");
}, true);
var uiWheelOn = null, uiWheelX = 0, uiWheelY = 0;
function uiWheelSent() {
  if (uiWheelOn && root.contains(uiWheelOn) && (uiWheelX || uiWheelY)) {
    send(uiWheelOn.getAttribute("data-h"), "wheel", uiWheelX + "," + uiWheelY, 0);
  }
  uiWheelOn = null;
  uiWheelX = uiWheelY = 0;
}
document.addEventListener("wheel", function (e) {
  var el = uiHearer(e.target, "wheel");
  if (!el) { return; }
  e.preventDefault();
  if (uiWheelOn && uiWheelOn !== el) { uiWheelSent(); }
  var k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? window.innerHeight : 1;
  if (!uiWheelOn) { requestAnimationFrame(uiWheelSent); }
  uiWheelOn = el;
  uiWheelX += e.deltaX * k;
  uiWheelY += e.deltaY * k;
}, { capture: true, passive: false });
var uiScrolling = [];
document.addEventListener("scroll", function (e) {
  var el = e.target;
  if (!uiHears(el, "scroll") || uiScrolling.indexOf(el) >= 0) { return; }
  uiScrolling.push(el);
  if (uiScrolling.length > 1) { return; }
  requestAnimationFrame(function () {
    var all = uiScrolling;
    uiScrolling = [];
    for (var i = 0; i < all.length; i++) {
      if (root.contains(all[i])) {
        send(all[i].getAttribute("data-h"), "scroll", Math.round(all[i].scrollLeft) + "," + Math.round(all[i].scrollTop), 0);
      }
    }
  });
}, true);
var uiSizes = window.ResizeObserver ? new ResizeObserver(function (seen) {
  for (var i = 0; i < seen.length; i++) {
    var el = seen[i].target, r = el.getBoundingClientRect();
    var said = Math.round(r.width) + "," + Math.round(r.height);
    if (root.contains(el) && el.getAttribute("data-h") && el.__size !== said) {
      el.__size = said;
      send(el.getAttribute("data-h"), "size", said, 0);
    }
  }
}) : null;
function uiAfter() {
  var asked = root.querySelectorAll("[data-scrollto]");
  for (var i = 0; i < asked.length; i++) {
    var el = asked[i], want = el.getAttribute("data-scrollto");
    if (el.__scrollTo === want) { continue; }
    el.__scrollTo = want;
    var p = want.split(",");
    el.scrollTo(p[0] | 0, p[1] | 0);
  }
  var sized = root.querySelectorAll('[data-ev~="size"]');
  for (var k = 0; k < sized.length; k++) {
    if (uiSizes && !sized[k].__observed && !sized[k].classList.contains("h-scene")) {
      sized[k].__observed = true;
      uiSizes.observe(sized[k]);
    }
  }
}

` +
	// A file goes up in pieces small enough for any socket, the name ahead of the last.
	`function uiSendFiles(el, files) {
  Array.prototype.forEach.call(files, function (f) {
    var reader = new FileReader();
    reader.onload = function () {
      if (!root.contains(el) || !el.getAttribute("data-h")) { return; }
      var id = el.getAttribute("data-h"), data = String(reader.result), body = data.slice(data.indexOf(",") + 1);
      var step = 4194304, at = 0;
      for (; at + step < body.length; at += step) { send(id, "filepart", body.slice(at, at + step), 0); }
      send(id, "file", btoa(unescape(encodeURIComponent(f.name))) + "," + body.slice(at), 0);
    };
    reader.readAsDataURL(f);
  });
}
function uiCarries(dt, kind) { return !!dt && Array.prototype.indexOf.call(dt.types || [], kind) >= 0; }
document.addEventListener("dragstart", function (e) {
  var el = e.target && e.target.closest ? e.target.closest("[data-carry]") : null;
  if (!el || !root.contains(el)) { return; }
  e.dataTransfer.setData("application/x-hive", el.getAttribute("data-carry"));
  e.dataTransfer.effectAllowed = "move";
}, true);
document.addEventListener("dragover", function (e) {
  var dt = e.dataTransfer;
  if (uiCarries(dt, "Files")) {
    e.preventDefault();
    dt.dropEffect = uiHearer(e.target, "file") ? "copy" : "none";
  } else if (uiCarries(dt, "application/x-hive") && uiHearer(e.target, "drop")) {
    e.preventDefault();
    dt.dropEffect = "move";
  }
}, true);
document.addEventListener("drop", function (e) {
  var dt = e.dataTransfer;
  if (uiCarries(dt, "Files")) {
    e.preventDefault();
    var to = uiHearer(e.target, "file");
    if (to) { uiSendFiles(to, dt.files); }
    return;
  }
  var into = uiHearer(e.target, "drop");
  if (into && uiCarries(dt, "application/x-hive")) {
    e.preventDefault();
    send(into.getAttribute("data-h"), "drop", dt.getData("application/x-hive"), 0);
  }
}, true);
</script>
__EXTRA__
</body></html>`

// A program's own typeface, by the same convention its icon arrives on: ship
// `assets/font.woff2` and the window is set in it. Nothing declares it and
// nothing detects it — the rule is always written, and a program with no such
// file serves a 404, the face is unavailable, and the stack falls through to
// the system's own. A miss costs one request and changes nothing.
//
// A coarse pointer is a finger: controls grow to a thumb's width and a field's
// text reaches 16px, below which a phone zooms on focus and never zooms back.
// Nothing here moves a box.
const uiCSS = `*,*::before,*::after{box-sizing:border-box}
@font-face{font-family:hive-own;font-weight:100 900;font-display:swap;
src:url("/_hive/asset/font.woff2") format("woff2")}
body{margin:0;font:14px/1.5 hive-own,system-ui,-apple-system,"Segoe UI",sans-serif;
background:var(--bg);color:var(--fg);-webkit-text-size-adjust:100%}
:root{--bg:#fff;--fg:#16181c;--muted:#5b6470;--line:#e3e6ea;--accent:#1d9bf0;
--good:#00a870;--warn:#c47d00;--danger:#d7263d;--surface:#f7f9fa}
@media (prefers-color-scheme:dark){:root{--bg:#15181c;--fg:#e7e9ea;--muted:#8b98a5;
--line:#2f3336;--accent:#1d9bf0;--good:#00ba7c;--warn:#ffd400;--danger:#f4212e;
--surface:#1c2026}}
.h-root{display:flex;flex-direction:column;min-height:100vh;min-height:100dvh}
.h-text{white-space:pre-wrap;overflow-wrap:anywhere}
.h-size-title{font-size:20px;font-weight:700}
.h-size-subtitle{font-size:16px;font-weight:600}
.h-size-caption{font-size:12px}
.h-bg-normal{background:var(--bg)}
.h-bg-muted{background:var(--surface)}
.h-bg-good{background:var(--good);color:#fff}
.h-bg-warn{background:var(--warn);color:#15181c}
.h-bg-danger{background:var(--danger);color:#fff}
.h-tone-muted{color:var(--muted)}
.h-tone-good{color:var(--good)}
.h-tone-warn{color:var(--warn)}
.h-tone-danger{color:var(--danger)}
.h-link{color:var(--accent);text-decoration:none}
.h-link:hover{text-decoration:underline}
.h-button{font:inherit;border:1px solid var(--line);background:var(--surface);
color:inherit;border-radius:999px;padding:6px 14px;cursor:pointer;
touch-action:manipulation}
.h-button:hover:not(:disabled){border-color:var(--accent);color:var(--accent)}
.h-button:disabled{opacity:.5;cursor:default}
.h-button.h-tone-good{background:var(--accent);border-color:var(--accent);color:#fff}
.h-button.h-tone-danger{border-color:var(--danger);color:var(--danger)}
.h-input,.h-textarea,.h-select{font:inherit;color:inherit;background:var(--bg);
border:1px solid var(--line);border-radius:8px;padding:8px 10px;min-width:0}
.h-input:focus,.h-textarea:focus{outline:2px solid var(--accent);border-color:transparent}
.h-input[type=range]{padding:0;border:0;background:none;accent-color:var(--accent);cursor:pointer}
.h-input[type=color]{width:64px;height:39px;padding:6px;cursor:pointer}
.h-input[type=color]::-webkit-color-swatch-wrapper{padding:0}
.h-input[type=color]::-webkit-color-swatch{border:0;border-radius:4px}
.h-input[type=color]::-moz-color-swatch{border:0;border-radius:4px}
.h-input[type=file]{cursor:pointer}
.h-input[type=file]::file-selector-button{font:inherit;color:inherit;background:var(--surface);border:0;
border-radius:6px;padding:0 10px;margin:0 8px 0 -4px;cursor:pointer}
.h-textarea{resize:vertical;min-height:64px;width:100%}
.h-checkbox{display:inline-flex;align-items:center;gap:6px;cursor:pointer}
.h-noring:focus,.h-noring:focus-visible,.h-noring:focus-within{outline:none}
.h-code.h-noring:focus-within{border-color:var(--line)}
.h-button[style*="background"]:hover:not(:disabled){border-color:transparent;filter:brightness(1.15)}
.h-hover:hover:not(:disabled){background:var(--hv)!important;filter:none;text-decoration:none}
.h-link.h-hover:hover,.h-hover .h-link:hover{text-decoration:none}
.h-code.h-ctrl .h-mono{cursor:pointer}
.h-scroll-x>*{flex-shrink:0}
.h-code{display:flex;position:relative;min-height:64px;min-width:0;overflow:hidden;
border:1px solid var(--line);border-radius:8px;background:var(--bg);
font:13px/1.5 ui-monospace,"Cascadia Mono","Cascadia Code",Consolas,"Liberation Mono","DejaVu Sans Mono",monospace}
.h-code:focus-within{border-color:var(--accent)}
.h-gutter{margin:0;padding:8px 10px 8px 12px;font:inherit;text-align:right;color:var(--muted);
opacity:.75;user-select:none;white-space:pre;flex:none;will-change:transform}
.h-mk{display:inline-block;width:100%;margin-left:-12px;padding-left:12px}
.h-code-body{position:relative;flex:1;min-width:0;overflow:hidden}
.h-runs,.h-mono{margin:0;padding:8px 12px;font:inherit;white-space:pre;letter-spacing:0}
.h-runs{position:absolute;left:0;top:0;min-width:100%;pointer-events:none;color:inherit;will-change:transform}
.h-mono{position:absolute;inset:0;width:100%;height:100%;resize:none;border:0;outline:0;
background:transparent;color:inherit;-webkit-text-fill-color:transparent;overflow:auto;box-sizing:border-box}
.h-mono::selection{background:color-mix(in srgb,var(--accent) 35%,transparent);-webkit-text-fill-color:transparent}
.h-mono:disabled{cursor:default}
.h-band{position:absolute;left:0;right:0;height:1.5em;pointer-events:none;z-index:-1}
.h-runs{z-index:0;isolation:isolate}
.h-note::after{content:attr(data-note);padding-left:3ch;font-style:italic;opacity:.9}
.h-curline{position:absolute;left:0;right:0;top:0;display:none;pointer-events:none;
background:color-mix(in srgb,var(--fg) 6%,transparent)}
.h-table{border-collapse:collapse;width:100%}
.h-table th,.h-table td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);
overflow-wrap:anywhere}
.h-table thead th{position:sticky;top:0;background:var(--bg);font-weight:600}
.h-sortable,.h-pickable{cursor:pointer}
.h-pickable:hover{background:var(--surface)}
.h-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;
align-items:center;justify-content:center;z-index:10}
.h-pinned{background:none;pointer-events:none}
.h-pinned>.h-overlay{background:none;box-shadow:none;pointer-events:auto;
display:flex;max-height:none;border-radius:0}
[data-touch]{touch-action:none;user-select:none;-webkit-user-select:none}
.h-anchored>.h-overlay{position:fixed;left:0;top:0;display:block;max-height:70vh;overflow:auto;
background:var(--bg);border:1px solid var(--line);border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.25)}
.h-overlay{background:var(--bg);border-radius:16px;max-height:85vh;overflow:auto;
max-width:calc(100vw - 24px);box-shadow:0 12px 40px rgba(0,0,0,.3)}
.h-spinner{width:18px;height:18px;border:2px solid var(--line);
border-top-color:var(--accent);border-radius:50%;animation:h-spin .7s linear infinite}
@keyframes h-spin{to{transform:rotate(360deg)}}
.h-busy{opacity:.6}
.h-icon{display:inline-flex;align-items:center;justify-content:center;width:1em;height:1.5em;vertical-align:top;flex:none}
.h-icon>svg{display:block;width:1em;height:1em}
.h-grid,.h-stack,.h-paragraph,.h-tree{min-width:0}
.h-stack{display:grid;grid-template-columns:minmax(0,1fr)}
.h-stack>*{grid-area:1/1}
.h-paragraph{display:block;white-space:pre-wrap;overflow-wrap:anywhere}
.h-paragraph>:not(.h-text):not(.h-link):not(.h-icon){display:inline-flex;vertical-align:middle}
.h-radio{display:flex;flex-direction:column;gap:6px}
.h-radio.h-wrap{flex-direction:row;flex-wrap:wrap;column-gap:16px}
.h-option{display:inline-flex;align-items:center;gap:6px;cursor:pointer}
.h-option>input{margin:0 3px 0 4px;accent-color:var(--accent)}
.h-progress{display:block;width:100%;height:6px;border-radius:3px;background:var(--line);overflow:hidden}
.h-progress>div{height:100%;border-radius:3px;background:var(--accent)}
.h-choices{display:flex;flex-direction:column;padding:4px;border:1px solid var(--line);border-radius:8px;overflow:auto}
.h-choice,.h-tab{font:inherit;color:inherit;background:none;border:0;cursor:pointer;text-align:start}
.h-choice{display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:6px}
.h-choice:hover:not(:disabled){background:var(--surface)}
.h-choice[aria-selected=true]{background:color-mix(in srgb,var(--accent) 14%,transparent)}
.h-tick{display:inline-flex;width:1em;height:1em;flex:none;color:var(--accent)}
.h-tick>svg{width:1em;height:1em}
.h-tabs{display:flex;gap:4px;box-shadow:inset 0 -1px 0 var(--line);overflow-x:auto}
.h-tab{flex:none;color:var(--muted);padding:8px 12px;border-bottom:2px solid transparent;white-space:nowrap}
.h-tab:hover:not(:disabled){color:inherit}
.h-tab[aria-selected=true]{color:var(--accent);border-bottom-color:var(--accent)}
.h-choice:disabled,.h-tab:disabled{opacity:.5;cursor:default}
.h-tree,.h-branch,.h-branch-kids{display:flex;flex-direction:column}
.h-branch-kids{padding-left:16px}
.h-branch-head{display:flex;align-items:center;gap:4px;padding:2px 4px;border-radius:6px}
.h-branch-head[data-h]{cursor:pointer}
.h-branch-head[data-h]:hover{background:var(--surface)}
.h-branch[aria-selected=true]>.h-branch-head{background:color-mix(in srgb,var(--accent) 14%,transparent)}
.h-twisty{display:inline-flex;align-items:center;justify-content:center;width:16px;height:16px;flex:none;color:var(--muted)}
.h-twisty[data-h]{cursor:pointer}
.h-twisty>svg{width:14px;height:14px}
.h-label{white-space:pre;overflow:hidden;text-overflow:ellipsis}
.h-image{max-width:100%;height:auto;display:block}
.h-closed::after{content:"disconnected";position:fixed;bottom:12px;left:12px;
background:var(--danger);color:#fff;padding:4px 10px;border-radius:6px;font-size:12px}
.h-scene{position:relative;overflow:hidden;min-height:0;min-width:0;background:#0b0d10}
.h-inset{position:relative;overflow:hidden;min-height:0;min-width:0;
background:none;pointer-events:none}
.h-world{position:fixed;z-index:2;overflow:hidden}
.h-world>canvas{display:block;width:100%;height:100%}
.h-canvas{display:block;min-width:0;min-height:0}
.h-aiming{cursor:none}
.h-aiming::before,.h-aiming::after{content:"";position:absolute;left:50%;top:50%;
background:#fff;opacity:.8;pointer-events:none}
.h-aiming::before{width:2px;height:15px;margin:-7px 0 0 -1px}
.h-aiming::after{width:15px;height:2px;margin:-1px 0 0 -7px}
@media (pointer:coarse){.h-button,.h-select,.h-input:not([type=range]){min-height:44px}
.h-checkbox{min-height:44px}
.h-input,.h-textarea,.h-select{font-size:16px}}`

// One running window: the page it last rendered, the sockets watching it, and
// the handlers the current page's ids stand for.
//
// The world as it was last published: the payload, where each shape's record
// lies inside it, where the insets were looking, and which turn of the fold
// it came from. The last three are what a difference is made of.
//
// --- What actually changed in the document ----------------------------------
//
// A window drew the page and sent the whole of it whenever a byte moved:
// fourteen kilobytes down the socket, and a parse of every element in it, to
// change four numbers. The scene has never worked that way — it sends the
// difference — and this is the same for the document.
//
// The page's own patcher applies it, unchanged. An edit names a node and
// carries that node's HTML, so everything that patcher knows about a select's
// options, a textarea's value and where the reader is typing still holds: the
// only thing that changed is how much of the page it is handed.
//
// A node of the document as the page will hold it. Positions rather than text,
// because every comparison here is between two slices of two documents that are
// already in memory.
type uiDom struct {
	kind byte
	name string
	from int
	open int
	to   int
	kids int32
	head int32
	tail int32
	next int32
}

// The document, read back into the shape the page's parser will give it. It is
// this renderer's own output, so what it has to understand is only what that
// renderer writes: elements, text, comments, and the few tags that close
// themselves. Nothing here is a general HTML parser and nothing should make it
// one.
func uiScan(html string, into []uiDom) []uiDom {
	nodes := into[:0]
	if cap(nodes) < 16 {
		nodes = make([]uiDom, 0, len(html)/40+16)
	}
	nodes = append(nodes, uiDom{kind: 'r', from: 0, open: 0, to: len(html)})
	stack := make([]int32, 1, 32)
	i := 0
	for i < len(html) {
		top := stack[len(stack)-1]
		if html[i] != '<' {
			at := i
			for i < len(html) && html[i] != '<' {
				i++
			}
			nodes = append(nodes, uiDom{kind: 't', from: at, open: i, to: i})
			uiAdopt(nodes, top, int32(len(nodes)-1))
			continue
		}
		if strings.HasPrefix(html[i:], "<!--") {
			shut := strings.Index(html[i:], "-->")
			if shut < 0 {
				break
			}
			end := i + shut + 3
			nodes = append(nodes, uiDom{kind: 'c', from: i, open: end, to: end})
			uiAdopt(nodes, top, int32(len(nodes)-1))
			i = end
			continue
		}
		shut := strings.IndexByte(html[i:], '>')
		if shut < 0 {
			break
		}
		end := i + shut + 1
		if html[i+1] == '/' {
			if len(stack) > 1 {
				nodes[top].to = end
				stack = stack[:len(stack)-1]
			}
			i = end
			continue
		}
		name := uiTagName(html[i+1 : end-1])
		nodes = append(nodes, uiDom{kind: 'e', name: name, from: i, open: end, to: end})
		me := int32(len(nodes) - 1)
		uiAdopt(nodes, top, me)
		if html[end-2] != '/' && uiVoidTag(name) == false {
			stack = append(stack, me)
		}
		i = end
	}
	return nodes
}

// Children are a chain through the nodes rather than a slice apiece: a page of
// a few hundred elements was a few hundred little allocations, every fold, to
// hold what one more field on each node holds for nothing. Nought is "none",
// which costs nothing to say because nought is the root and the root is no
// one's child.
func uiAdopt(nodes []uiDom, parent int32, child int32) {
	if nodes[parent].tail == 0 {
		nodes[parent].head = child
	} else {
		nodes[nodes[parent].tail].next = child
	}
	nodes[parent].tail = child
	nodes[parent].kids++
}

func uiTagName(open string) string {
	for i := 0; i < len(open); i++ {
		c := open[i]
		if c == ' ' || c == '/' {
			return open[:i]
		}
	}
	return open
}

// The two this renderer writes that carry no closing tag. Every other tag it
// emits either closes itself with a slash — the canvas marks — or is closed.
func uiVoidTag(name string) bool {
	return name == "img" || name == "input"
}

type uiEdit struct {
	path string
	html string
}

// The difference between two documents, as edits the page can apply.
//
// Positional, exactly as the page's patcher is: a view rendered by the same
// code from a model that moved a little is the same tree with different
// numbers in it. Where that is wrong the tags disagree and the node is handed
// over whole.
//
// An edit is never emitted inside another: a node that differs is either
// descended into or handed over, never both. That is what keeps every path
// still true by the time the page walks it.
func uiDocEdits(was string, old []uiDom, now string, fresh []uiDom) []uiEdit {
	var edits []uiEdit
	uiDiffKids(was, old, 0, now, fresh, 0, "", &edits)
	return edits
}

func uiDiffKids(was string, old []uiDom, a int32, now string, fresh []uiDom,
	b int32, path string, edits *[]uiEdit) {
	if old[a].kids != fresh[b].kids {
		*edits = append(*edits, uiEdit{path: path, html: now[fresh[b].from:fresh[b].to]})
		return
	}
	x := old[a].head
	y := fresh[b].head
	for i := 0; x != 0 && y != 0; i, x, y = i+1, old[x].next, fresh[y].next {
		if was[old[x].from:old[x].to] == now[fresh[y].from:fresh[y].to] {
			continue
		}

		// Anything that is not an element on both sides — a text node, a comment, a
		// different tag — is answered by handing over the node holding it, because a
		// path names a node and the page patches nodes.
		if old[x].kind != 'e' || fresh[y].kind != 'e' || old[x].name != fresh[y].name {
			*edits = append(*edits, uiEdit{path: path, html: now[fresh[b].from:fresh[b].to]})
			return
		}
		here := strconv.Itoa(i)
		if path != "" {
			here = path + "." + here
		}
		if was[old[x].from:old[x].open] != now[fresh[y].from:fresh[y].open] {
			*edits = append(*edits, uiEdit{path: here, html: now[fresh[y].from:fresh[y].to]})
			continue
		}
		uiDiffKids(was, old, x, now, fresh, y, here, edits)
	}
}

// The edits as one frame. JSON because an edit carries a program's own text and
// there is no byte this renderer cannot emit; a length-prefixed format would
// have to agree with the page about what a length counts, and JSON does not.
func uiEditsFrame(edits []uiEdit) string {
	var b strings.Builder
	b.WriteString("P[")
	for i, e := range edits {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('[')
		uiQuoteInto(&b, e.path)
		b.WriteByte(',')
		uiQuoteInto(&b, e.html)
		b.WriteByte(']')
	}
	b.WriteByte(']')
	return b.String()
}

func uiQuoteInto(b *strings.Builder, s string) {
	b.WriteByte(uiQuoteMark)
	at := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != uiQuoteMark && c != uiBackslash && c >= 0x20 {
			continue
		}
		b.WriteString(s[at:i])
		at = i + 1
		b.WriteByte(uiBackslash)
		if c == uiQuoteMark || c == uiBackslash {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('u')
		b.WriteByte('0')
		b.WriteByte('0')
		b.WriteByte(uiHexDigit(c >> 4))
		b.WriteByte(uiHexDigit(c & 15))
	}
	b.WriteString(s[at:])
	b.WriteByte(uiQuoteMark)
}

// Spelled as their codes rather than as characters: this Go is written from
// inside a backtick string, and a lone backslash there is an escape rather
// than itself.
const uiQuoteMark = byte(34)
const uiBackslash = byte(92)

func uiHexDigit(n byte) byte {
	if n < 10 {
		return '0' + n
	}
	return 'a' + n - 10
}

type uiWindow struct {
	mu       sync.Mutex
	html     string
	dom      []uiDom
	spare    []uiDom
	scene    string
	cuts     []int32
	insets   string
	worldGen uint32
	docGen   uint32
	handlers map[string][]UiAttr
	paced    bool

	// Every watcher, and the world it is known to be holding. A page holding the
	// frame before this one can be sent the difference; anything else gets the
	// lot. `holding` says the same of the document.
	watchers map[NetWsConnection]uint32
	holding  map[NetWsConnection]uint32
	token    string
	addr     SyslinkAddress
	listener net.Listener
	shut     bool
	painter  uiPainter
}

// A window drawn by the program rather than by a page. hive/uinative.go fills
// uiNativePainter in, where the build found nothing only a page can draw.
type uiPainter interface {
	show(v UiView)
	open(title string, addr SyslinkAddress) bool
	last() UiView
}

var uiNativePainter func() uiPainter

// One watcher as publish found it, so the sending can happen off the lock.
//
// What actually changed. A window with no scene in it is exactly what it was
// before: one frame per turn, and nothing here costs it anything.
//
// Counts worlds that were sent, not folds that happened, so a page holding
// the last world anybody sent is not behind because time passed.
//
// The answer first, not last: the fold is over now, not after a document
// has gone down the socket and been laid out. Unconditional — tying it to
// H or S would deadlock the moment a fold left the page exactly as it was.
type uiWatcher struct {
	conn NetWsConnection
	near bool
	read bool
}

func uiPaced(v *UiView) bool {
	if _, ok := uiFind(v.Attrs, "onFrame"); ok {
		return true
	}
	for i := range v.Children {
		if uiPaced(&v.Children[i]) {
			return true
		}
	}
	return false
}

func (w *uiWindow) publish(v UiView) {
	w.mu.Lock()
	painter := w.painter
	w.mu.Unlock()
	if painter != nil {
		paced := uiPaced(&v)
		w.mu.Lock()
		w.paced = paced
		w.mu.Unlock()
		painter.show(v)
		return
	}
	r := &uiRender{handlers: map[string][]UiAttr{}}

	// Room for a document about the size of the last one. A builder not told how
	// big the answer will be doubles as it fills, and doubling copies everything
	// so far: a fold that changed four numbers was rebuilding the page four times
	// over on its way to writing it once.
	w.mu.Lock()
	room := len(w.html)
	spare := w.spare
	w.spare = nil
	w.mu.Unlock()
	if room > 0 {
		r.out.Grow(room + room/8)
	}
	r.view(v)
	scene, cuts := uiSceneWorld(r.scenes, r.sceneCuts)
	insets := uiSceneLooks(r.insets)
	w.mu.Lock()
	html := r.out.String()
	document := html != w.html
	world := scene != "" && (scene != w.scene || insets != w.insets)
	was, wasCuts := w.scene, w.cuts
	wasHtml, wasDom := w.html, w.dom
	w.html = html
	w.scene = scene
	w.cuts = cuts
	w.insets = insets
	w.handlers = r.handlers
	w.paced = r.paced
	if world {
		w.worldGen++
	}

	// The document is read back into nodes only when one is about to be sent, and
	// only while somebody is watching: a window nobody has open folds on without
	// paying for a difference nobody will read.
	if document {
		w.docGen++
		if len(w.watchers) > 0 {
			w.dom = uiScan(html, spare)
		} else {
			w.dom = nil
		}
	}
	seq := w.worldGen
	papers := w.docGen
	dom := w.dom
	watchers := make([]uiWatcher, 0, len(w.watchers))
	for c, held := range w.watchers {
		watchers = append(watchers, uiWatcher{
			conn: c,
			near: held == seq-1,
			read: w.holding[c] == papers-1,
		})
		if world {
			w.watchers[c] = seq
		}
		if document {
			w.holding[c] = papers
		}
	}
	w.mu.Unlock()
	var edit, whole []byte
	if world {
		edit = uiSceneFrame(scene, cuts, insets, was, wasCuts, seq, seq-1)
	}

	// The difference, worked out once however many pages are holding the document
	// it is against. A page holding anything else is sent the whole of it, which is
	// what a page that has just arrived or lost the thread always was.
	paper := ""
	if document && wasDom != nil && dom != nil {
		edits := uiDocEdits(wasHtml, wasDom, html, dom)
		if len(edits) > 0 {
			paper = uiEditsFrame(edits)
		}
	}
	for _, c := range watchers {
		NetWsSend(c.conn, "A")
		if document {
			if c.read && paper != "" {
				NetWsSend(c.conn, paper)
			} else {
				NetWsSend(c.conn, "H"+html)
			}
		}
		if !world {
			continue
		}

		// A page one frame behind is sent the difference; anything else — just
		// arrived, or asked to start again — the whole world, built once however
		// many are asking for it.
		if c.near {
			uiWsSend(c.conn, edit)
			continue
		}
		if whole == nil {
			whole = uiSceneFrame(scene, cuts, insets, "", nil, seq, 0)
		}
		uiWsSend(c.conn, whole)
	}

	// The document before this one, handed back now the difference against it has
	// been written. The next fold reads the page into it rather than into a fresh
	// one: two buffers, each holding still while the other is filled, so a window
	// at sixty folds a second stops leaving a page of nodes behind every time.
	// An unchanged document is still w.dom, so it must not become the spare.
	w.mu.Lock()
	if document {
		w.spare = wasDom
	} else {
		w.spare = spare
	}
	w.mu.Unlock()
}

// What the window draws, out of a tree that may hold no scene at all — which
// is what keeps the whole mechanism invisible to a window that never draws one.
func uiSceneWorld(scenes []string, cuts [][]int32) (string, []int32) {
	if len(scenes) == 0 {
		return "", nil
	}

	// A window draws one scene. A view holding several is a mistake worth saying
	// out loud once — the alternative is a second picture that is silently
	// blank.
	//
	// An inset is not one of those, and that is the distinction the widget rests
	// on: a second camera, not a second world, so any number of them cost a
	// second pass over shapes that are already there.
	if len(scenes) > 1 {
		uiSceneCrowd.Do(func() {
			fmt.Fprintln(os.Stderr, "hive: a window draws one scene, and this view has "+
				strconv.Itoa(len(scenes))+" — the first one is the one on screen")
		})
	}
	return scenes[0], cuts[0]
}

// Where every inset is looking: one camera after another behind a count. An
// inset holds no world of its own, so this is a few dozen bytes however big
// the scene in front of it is.
func uiSceneLooks(insets []string) string {
	many := len(insets)
	if many > 255 {
		many = 255
	}
	var b strings.Builder
	uiPackU8(&b, many)
	for i := 0; i < many; i++ {
		b.WriteString(insets[i])
	}
	return b.String()
}

// One frame of the world, carrying only the shapes whose record is not what the
// page already holds. A circuit is eighteen hundred shapes of which the
// scenery — three quarters of them — never moves.
//
// seq names this frame and prev the one it was taken from, because a difference
// means nothing against any other. A page that finds prev is not what it holds
// asks for the world again; prev nought means this frame is the whole of it.
//
// How much of what the page holds is worth comparing against. Nothing, when
// this frame is the whole world.
func uiSceneFrame(scene string, cuts []int32, insets string,
	was string, wasCuts []int32, seq, prev uint32) []byte {
	head := len(scene)
	if len(cuts) > 0 {
		head = int(cuts[0])
	}
	shapes := len(cuts) - 1
	if shapes < 0 {
		shapes = 0
	}
	held := 0
	if prev != 0 && len(wasCuts) > 0 {
		held = len(wasCuts) - 1
	}
	moves, changed := uiSceneDiff(scene, cuts, was, wasCuts, shapes, held)

	// Sized exactly and built as the bytes that are sent: a frame is the largest
	// thing a window makes sixty times a second, and a builder guessing short
	// and then copied out into bytes was three of them.
	size := 9 + head + len(insets) + 4 + len(moves)*4 + 4
	for _, at := range changed {
		size += 4 + int(cuts[at+1]-cuts[at])
	}
	out := make([]byte, 0, size)
	out = append(out, 'S')
	out = uiAppendU32(out, int(seq))
	out = uiAppendU32(out, int(prev))

	// The camera and the shape count, already written at the front of the
	// scene's own payload.
	out = append(out, scene[:head]...)
	out = append(out, insets...)
	out = uiAppendU32(out, len(moves)/3)
	for _, n := range moves {
		out = uiAppendU32(out, int(n))
	}
	out = uiAppendU32(out, len(changed))
	for _, at := range changed {
		out = uiAppendU32(out, int(at))
		out = append(out, scene[cuts[at]:cuts[at+1]]...)
	}
	return out
}

func uiAppendU32(out []byte, v int) []byte {
	return append(out, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

// What NetWsSend does, as a binary frame: a text frame has to carry valid
// UTF-8 and a float is not any.
var uiSceneSeed = maphash.MakeSeed()

func uiSceneDiff(scene string, cuts []int32, was string, wasCuts []int32, shapes, held int) ([]int32, []int32) {
	rec := func(i int) string { return scene[cuts[i]:cuts[i+1]] }
	old := func(i int) string { return was[wasCuts[i]:wasCuts[i+1]] }
	same := func(i int) bool { return i < held && i < shapes && rec(i) == old(i) }
	changed := make([]int32, 0, shapes)
	var moves []int32
	var index map[uint64]int32
	var taken []bool
	for i := 0; i < shapes; i++ {
		if same(i) {
			continue
		}
		if held > 0 {
			if index == nil {
				index = make(map[uint64]int32, held)
				for j := held - 1; j >= 0; j-- {
					index[maphash.String(uiSceneSeed, old(j))] = int32(j)
				}
				taken = make([]bool, held)
			}
			if at, ok := index[maphash.String(uiSceneSeed, rec(i))]; ok {
				src := int(at)
				n := 0
				for i+n < shapes && src+n < held && !taken[src+n] && !same(i+n) && !same(src+n) && rec(i+n) == old(src+n) {
					taken[src+n] = true
					n++
				}
				if n > 0 {
					moves = append(moves, int32(i), int32(src), int32(n))
					i += n - 1
					continue
				}
			}
		}
		changed = append(changed, int32(i))
	}
	return moves, changed
}

func uiWsSend(c NetWsConnection, payload []byte) {
	if c.ws == nil {
		return
	}
	_ = c.ws.writeFrame(wsBinary, payload)
}

// --- numbers, as bytes -----------------------------------------------------
//
// Little-endian, which is what every machine a browser runs on is, and what the
// DataView on the other side is asked for.
func uiPackU8(b *strings.Builder, v int) { b.WriteByte(byte(v)) }

func uiPackU16(b *strings.Builder, v int) {
	b.WriteByte(byte(v))
	b.WriteByte(byte(v >> 8))
}

func uiPackU32(b *strings.Builder, v int) {
	b.WriteByte(byte(v))
	b.WriteByte(byte(v >> 8))
	b.WriteByte(byte(v >> 16))
	b.WriteByte(byte(v >> 24))
}

// A non-finite number goes as 0. One reaching the page puts a mesh nowhere and
// keeps it there, since every matrix built from it is non-finite too.
func uiPackF32(b *strings.Builder, v float64) {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		v = 0
	}
	uiPackU32(b, int(math.Float32bits(float32(v))))
}

// A short string behind one byte of length: colours, surface names and voices,
// which are identifiers and never long.
func uiPackWord(b *strings.Builder, s string) {
	if len(s) > 255 {
		s = uiPackCut(s, 255)
	}
	b.WriteByte(byte(len(s)))
	b.WriteString(s)
}

// A long one behind two: the words on a label and the name of a sound, which
// are the only prose a scene carries.
func uiPackLong(b *strings.Builder, s string) {
	if len(s) > 65535 {
		s = uiPackCut(s, 65535)
	}
	uiPackU16(b, len(s))
	b.WriteString(s)
}

// Cut to a length in bytes without splitting a rune, because the page decodes
// UTF-8 and half a rune is not any. Back up while the byte the cut lands on is
// a continuation byte; callers only ask when the string is longer than that.
func uiPackCut(s string, most int) string {
	for most > 0 && s[most]&0xC0 == 0x80 {
		most--
	}
	return s[:most]
}

var uiSceneCrowd sync.Once

// Two numbers in one event's value ("12.5,-4"), which is how far the mouse
// moved. Anything that is not a pair of numbers is no movement at all.
func uiPair(text string) (float64, float64) {
	at := strings.IndexByte(text, ',')
	if at < 0 {
		return 0, 0
	}
	x, errX := strconv.ParseFloat(strings.TrimSpace(text[:at]), 64)
	y, errY := strconv.ParseFloat(strings.TrimSpace(text[at+1:]), 64)
	if errX != nil || errY != nil {
		return 0, 0
	}
	return x, y
}

// One control off a pad: its name, then where it is. A bar between them
// rather than a comma because a control's name is a word and a comma is what
// the mouse already uses; nothing else about the two is different.
func uiControl(text string) (string, float64) {
	at := strings.IndexByte(text, '|')
	if at < 0 {
		return "", 0
	}
	position, err := strconv.ParseFloat(strings.TrimSpace(text[at+1:]), 64)
	if err != nil {
		return "", 0
	}
	return text[:at], position
}

// The last window closing ends the program: nobody could see or stop what
// outlived it. The wait is what tells a closed window from a reloaded one.
func (w *uiWindow) linger() {
	if runtime.GOOS == "android" {
		return
	}
	time.Sleep(1500 * time.Millisecond)
	w.mu.Lock()
	gone := len(w.watchers) == 0 && !w.shut
	if gone {
		w.shut = true
	}
	addr, listener := w.addr, w.listener
	w.mu.Unlock()
	if !gone {
		return
	}
	SyslinkKill(addr)
	if listener != nil {
		listener.Close()
	}
	if Release() == 0 {
		fmt.Fprintln(os.Stderr, "hive: the window was closed")
		os.Exit(0)
	}
}

// The message an event on id means, if it means one. A stale id — an event
// from a page the program has already replaced — resolves to nothing, which is
// the right answer rather than a guess.
//
// A scene's events. A frame carries how long the last one took, a key
// carries its own name, a look carries how far the mouse moved, and a grab
// carries whether the window is holding the mouse now.
//
// How often the window is handed a frame to draw: the screen's own rate,
// not what this program is managing to do with it.
func (w *uiWindow) message(id string, kind string, value string, index int) (any, bool) {
	w.mu.Lock()
	attrs, ok := w.handlers[id]
	w.mu.Unlock()
	if !ok {
		return nil, false
	}
	return uiMeaning(attrs, kind, value, index)
}

func uiCut(value string) (int, int, string) {
	a, rest, _ := strings.Cut(value, ",")
	b, text, _ := strings.Cut(rest, ",")
	x, _ := strconv.Atoi(a)
	y, _ := strconv.Atoi(b)
	return x, y, text
}

func uiMeaning(attrs []UiAttr, kind string, value string, index int) (any, bool) {
	for _, a := range attrs {
		h := a.heard
		if h == nil {
			continue
		}
		switch {
		case kind == "click" && a.Kind == "on":
			return h.Msg, true
		case kind == "click" && a.Kind == "onPick" && h.FnInt != nil:
			return h.FnInt(index), true
		case kind == "click" && a.Kind == "onSort" && h.FnInt != nil:
			return h.FnInt(index), true
		case kind == "input" && a.Kind == "onInput" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "submit" && a.Kind == "onSubmit" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "key" && a.Kind == "onKey" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "paste" && a.Kind == "onPaste" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "caret" && a.Kind == "onCaret" && h.FnSize != nil:
			anchor, head, _ := uiCut(value)
			return h.FnSize(anchor, head), true
		case kind == "view" && a.Kind == "onView" && h.FnSize != nil:
			first, last, _ := uiCut(value)
			return h.FnSize(first, last), true
		case kind == "fit" && a.Kind == "onFit" && h.FnSize != nil:
			cols, rows, _ := uiCut(value)
			return h.FnSize(cols, rows), true
		case kind == "edit" && a.Kind == "onEdit" && h.FnEdit != nil:
			from, to, text := uiCut(value)
			return h.FnEdit(from, to, text), true
		case kind == "menu" && a.Kind == "onMenu", kind == "middle" && a.Kind == "onMiddle",
			kind == "double" && a.Kind == "onDouble":
			return h.Msg, true
		case kind == "drag" && a.Kind == "onDrag" && h.FnDrag != nil:
			x, y, done := uiCut(value)
			return h.FnDrag(x, y, done == "1"), true
		case kind == "hover" && a.Kind == "onHover" && h.FnInt != nil,
			kind == "jump" && a.Kind == "onJump" && h.FnInt != nil,
			kind == "probe" && a.Kind == "onProbe" && h.FnInt != nil:
			at, _ := strconv.Atoi(value)
			return h.FnInt(at), true
		case kind == "choose" && a.Kind == "onChoose" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "toggle" && a.Kind == "onToggle" && h.FnBool != nil:
			return h.FnBool(value != ""), true
		case kind == "frame" && a.Kind == "onFrame" && h.FnInt != nil:
			return h.FnInt(index), true
		case kind == "rate" && a.Kind == "onRate" && h.FnInt != nil:
			return h.FnInt(index), true
		case kind == "keydown" && a.Kind == "onKeyDown" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "keyup" && a.Kind == "onKeyUp" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "look" && a.Kind == "onLook" && h.FnLook != nil:
			dx, dy := uiPair(value)
			return h.FnLook(dx, dy), true
		case kind == "grab" && a.Kind == "onGrab" && h.FnBool != nil:
			return h.FnBool(value != ""), true

			// A pad names the control that moved and says where it now is; which
			// pad it was is the index, the same channel a list's row travels in.
		case kind == "pad" && a.Kind == "onPad" && h.FnPad != nil:
			control, position := uiControl(value)
			return h.FnPad(index, control, position), true
		case kind == "size" && a.Kind == "onSize" && h.FnSize != nil:
			wide, tall := uiPair(value)
			return h.FnSize(int(wide), int(tall)), true
		case kind == "enter" && a.Kind == "onEnter", kind == "leave" && a.Kind == "onLeave",
			kind == "focus" && a.Kind == "onFocus", kind == "blur" && a.Kind == "onBlur":
			return h.Msg, true
		case kind == "wheel" && a.Kind == "onWheel" && h.FnLook != nil,
			kind == "press" && a.Kind == "onPress" && h.FnLook != nil,
			kind == "point" && a.Kind == "onPoint" && h.FnLook != nil,
			kind == "release" && a.Kind == "onRelease" && h.FnLook != nil:
			x, y := uiPair(value)
			return h.FnLook(x, y), true
		case kind == "scroll" && a.Kind == "onScroll" && h.FnSize != nil:
			x, y := uiPair(value)
			return h.FnSize(int(x), int(y)), true
		case kind == "drop" && a.Kind == "onDrop" && h.FnStr != nil:
			return h.FnStr(value), true
		case kind == "file" && a.Kind == "onFile" && h.FnFile != nil:
			name, contents, ok := uiFileOf(value)
			if !ok {
				return nil, false
			}
			return h.FnFile(name, contents), true
		case kind == "click" && a.Kind == "choice" && h.FnStr != nil:
			return h.FnStr(a.Word), true
		case (kind == "hit" && a.Kind == "onHit" || kind == "over" && a.Kind == "onOver") && h.FnHit != nil:
			if uiScenePicker == nil {
				return nil, false
			}
			tag, x, y, z := uiScenePicker(attrs, value)
			return h.FnHit(tag, x, y, z), true
		case kind == "snapshot" && a.Kind == "onSnapshot" && h.FnStr != nil:
			shot, err := base64.StdEncoding.DecodeString(value)
			if err != nil {
				return nil, false
			}
			return h.FnStr(string(shot)), true
		}
	}
	return nil, false
}

// Called directly, as a test does, the handler is `update` and nothing more.
func UiWindow[S any, M any](title string, view func(S) UiView, update func(*S, M) M) func(*S, M) M {
	handler := func(state *S, msg M) M { return update(state, msg) }
	startsAs(funcKey(handler), uiStarter[S, M](title, view, false))
	return handler
}

func UiWindowAddressed[S any, M any](title string, view func(S) UiView, update func(*S, M, SyslinkAddress) M) func(*S, M, SyslinkAddress) M {
	handler := func(state *S, msg M, self SyslinkAddress) M { return update(state, msg, self) }
	startsAs(funcKey(handler), uiStarter[S, M](title, view, false))
	return handler
}

// The same window, always a page, wherever the program could have drawn it itself.
func UiWebview[S any, M any](title string, view func(S) UiView, update func(*S, M) M) func(*S, M) M {
	handler := func(state *S, msg M) M { return update(state, msg) }
	startsAs(funcKey(handler), uiStarter[S, M](title, view, true))
	return handler
}

func UiWebviewAddressed[S any, M any](title string, view func(S) UiView, update func(*S, M, SyslinkAddress) M) func(*S, M, SyslinkAddress) M {
	handler := func(state *S, msg M, self SyslinkAddress) M { return update(state, msg, self) }
	startsAs(funcKey(handler), uiStarter[S, M](title, view, true))
	return handler
}

// Rendering happens inside the turn, so a page never shows a mix of two states.
func uiStarter[S any, M any](title string, view func(S) UiView, page bool) syslinkStarter {
	return func(given any, first any) (any, func(SyslinkAddress)) {
		update := given.(func(*S, M, syslinkTurn) M)
		w := &uiWindow{
			watchers: map[NetWsConnection]uint32{},
			holding:  map[NetWsConnection]uint32{},
			token:    CryptoRandomHex(16),
		}
		if uiNativePainter != nil && !page && os.Getenv("HIVE_WINDOW") != "print" {
			w.painter = uiNativePainter()
			uiCrashLog()
		}
		tally := uiFoldTally()
		folded := func(state *S, msg M, t syslinkTurn) M {
			began := time.Now()
			out := update(state, msg, t)
			w.mu.Lock()
			paced := w.paced
			w.mu.Unlock()
			if paced && !t.drawn {
				tally.fold(began, time.Time{}, time.Time{})
				return out
			}
			viewed := time.Now()
			v := view(*state)
			drawn := time.Now()
			w.publish(v)
			tally.fold(began, viewed, drawn)
			return out
		}

		// Before the service starts, whose turns write the storage `initial` shares.
		w.publish(view(first.(S)))
		return folded, func(addr SyslinkAddress) { uiShow(w, title, addr) }
	}
}

// Events go to, and closing kills, the window's own mailbox rather than its name.
func uiShow(w *uiWindow, title string, named SyslinkAddress) {
	addr := SyslinkAddress{Name: atomNone, Id: named.Id, box: named.box}
	w.mu.Lock()
	w.addr = addr
	painter := w.painter
	w.mu.Unlock()
	if painter != nil {
		if painter.open(title, addr) {
			return
		}
		w.mu.Lock()
		w.painter = nil
		w.mu.Unlock()
		w.publish(painter.last())
	}

	page := strings.NewReplacer(
		"__TITLE__", uiEscape(title),
		"__CSS__", uiCSS,
		"__TOKEN__", w.token,
		"__EXTRA__", uiExtraScript+strings.Join(hivePageScripts, ""),
		"__ICON__", uiIconHref(),
	).Replace(uiShell)

	ready := make(chan int, 1)
	go uiServe(w, addr, page, ready)
	bound := <-ready
	if bound == 0 {
		fmt.Fprintln(os.Stderr, "hive: the window could not be opened — no port could be bound")
		return
	}
	Hold()
	url := "http://127.0.0.1:" + strconv.Itoa(bound) + "/?token=" + w.token
	if err := uiOpen(url); err != nil {

		// Not fatal: the address still works, and saying so is more use than
		// exiting on a machine with no browser to launch.
		fmt.Fprintln(os.Stderr, "hive: open "+url)
	}
}

// HIVE_FOLDS prints fold timings once a second.
type uiTally struct {
	on      bool
	mark    time.Time
	folds   int
	drawn   int
	gcs     uint32
	paused  uint64
	update  []float64
	view    []float64
	publish []float64
}

func uiFoldTally() *uiTally {
	return &uiTally{on: os.Getenv("HIVE_FOLDS") != "", mark: time.Now()}
}

func (t *uiTally) fold(began, viewed, drawn time.Time) {
	if !t.on {
		return
	}
	now := time.Now()
	t.folds++
	if viewed.IsZero() {
		t.update = append(t.update, uiMs(now.Sub(began)))
	} else {
		t.drawn++
		t.update = append(t.update, uiMs(viewed.Sub(began)))
		t.view = append(t.view, uiMs(drawn.Sub(viewed)))
		t.publish = append(t.publish, uiMs(now.Sub(drawn)))
	}
	if now.Sub(t.mark) < time.Second {
		return
	}
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Fprintf(os.Stderr, "hive: folds %d/s drawn %d/s | update %s | view %s | publish %s | gc %d, %.1fms\n",
		t.folds, t.drawn, uiSpread(t.update), uiSpread(t.view), uiSpread(t.publish),
		m.NumGC-t.gcs, float64(m.PauseTotalNs-t.paused)/1e6)
	t.gcs, t.paused = m.NumGC, m.PauseTotalNs
	t.mark, t.folds, t.drawn = now, 0, 0
	t.update, t.view, t.publish = t.update[:0], t.view[:0], t.publish[:0]
}

func uiMs(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func uiSpread(xs []float64) string {
	if len(xs) == 0 {
		return "-"
	}
	s := append([]float64(nil), xs...)
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
	return fmt.Sprintf("%.1f/%.1f/%.1fms", s[len(s)/2], s[len(s)*9/10], s[len(s)-1])
}

// What a module that draws inside a window adds to it: a script the shell puts
// on the page, and whatever that script has to load. Both are empty here and
// filled in by hive/ui_scene.go, which is written into the build only when the
// program draws a scene.
var uiExtraScript string
var uiExtraRoutes = map[string]func(http.ResponseWriter, *http.Request){}

// Everything under the program's own assets/ directory, embedded at compile
// time. Nil in a program that has no such directory; hive/assets.go fills it in.
//
// Not loaded at run time: the bytes are in the executable. A built Hive program
// is one file, and this only changes how big that file is.
var uiAssets *embed.FS

func uiAssetsAre(files embed.FS) { uiAssets = &files }

// One embedded file, named by its path under assets/. A miss is a 404 rather
// than an error the program hears about: a sound whose recording is not there
// falls back to the synthesised voice.
//
// .. cannot climb out of an embed.FS — it is not a filesystem — but a path
// that tries is a path this never meant to answer, and saying so is cheaper
// than reasoning about what ReadFile would do with it.
func uiStored(rw http.ResponseWriter, req *http.Request) {
	if uiAssets == nil {
		http.Error(rw, "not found", http.StatusNotFound)
		return
	}
	name := strings.TrimPrefix(req.URL.Path, "/_hive/asset/")
	if name == "" || strings.Contains(name, "..") {
		http.Error(rw, "not found", http.StatusNotFound)
		return
	}
	body, err := uiAssets.ReadFile("assets/" + name)
	if err != nil {
		http.Error(rw, "not found", http.StatusNotFound)
		return
	}
	rw.Header().Set("Content-Type", uiMime(name))

	// The bytes are in the executable, so they cannot change under a page that
	// kept them.
	rw.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	rw.Header().Set("Content-Length", strconv.Itoa(len(body)))
	_, _ = rw.Write(body)
}

// What an embedded file is, by the end of its name. Short deliberately: this is
// what a browser needs to decode a sound or draw a picture, and a full table of
// media types would be a table nobody in this program reads.
func uiMime(name string) string {
	cut := strings.LastIndex(name, ".")
	if cut < 0 {
		return "application/octet-stream"
	}
	switch strings.ToLower(name[cut:]) {
	case ".ogg", ".opus":
		return "audio/ogg"
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".m4a", ".aac":
		return "audio/mp4"
	case ".flac":
		return "audio/flac"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	case ".gif":
		return "image/gif"
	case ".svg":
		return "image/svg+xml"
	case ".woff2":
		return "font/woff2"
	}
	return "application/octet-stream"
}

// A subtree rather than a route each: what is under assets/ is the program's
// business, and a window serves it whether or not it draws a scene.
func init() { uiExtraRoutes["/_hive/asset/"] = uiStored }

// The window's own little server. It is deliberately not HttpServe: this needs
// the port it actually bound, a socket upgrade on one route, and nothing else.
//
// A page that has just connected is behind on both frames, whether or not
// either has changed lately.
func uiServe(w *uiWindow, addr SyslinkAddress, page string, ready chan int) {
	mux := http.NewServeMux()
	for path, handler := range uiExtraRoutes {
		mux.HandleFunc(path, handler)
	}
	for path, handler := range hivePageRoutes {
		if route, ok := handler.(func(http.ResponseWriter, *http.Request)); ok {
			mux.HandleFunc(path, route)
		}
	}
	if len(uiWindowIcon) > 0 {
		mux.HandleFunc("/_hive/icon", uiIconRoute)
	}
	mux.HandleFunc("/", func(rw http.ResponseWriter, req *http.Request) {
		if req.URL.Query().Get("token") != w.token {
			http.Error(rw, "forbidden", http.StatusForbidden)
			return
		}
		rw.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(rw, page)
	})
	mux.HandleFunc("/_hive/socket", func(rw http.ResponseWriter, req *http.Request) {
		if req.URL.Query().Get("token") != w.token {
			http.Error(rw, "forbidden", http.StatusForbidden)
			return
		}
		socket, err := wsAccept(rw, req)
		if err != nil {
			return
		}
		conn := wsConnection(socket)
		defer socket.close()
		w.mu.Lock()
		w.watchers[conn] = w.worldGen
		w.holding[conn] = w.docGen
		current := w.html
		w.mu.Unlock()
		NetWsSend(conn, "H"+current)
		w.reseed(conn)
		uiPump(w, addr, conn)
		w.mu.Lock()
		delete(w.watchers, conn)
		delete(w.holding, conn)
		empty := len(w.watchers) == 0
		w.mu.Unlock()

		// The window has gone. Whether it is *coming back* is the only question,
		// and waiting a moment is how you tell: a page being reloaded is back
		// within it, and a window that was closed is not.
		if empty {
			go w.linger()
		}
	})
	listener, bound := uiListen()
	if listener == nil {
		ready <- 0
		return
	}
	w.mu.Lock()
	w.listener = listener
	w.mu.Unlock()
	ready <- bound
	_ = http.Serve(listener, mux)
}

// The whole world, to one page that cannot draw what it was sent: it has only
// just connected, or the difference it received was taken from a frame it does
// not hold.
func (w *uiWindow) reseed(conn NetWsConnection) {
	w.mu.Lock()
	scene, cuts, insets, seq := w.scene, w.cuts, w.insets, w.worldGen
	if _, watching := w.watchers[conn]; watching {
		w.watchers[conn] = seq
	}
	w.mu.Unlock()
	if scene == "" {
		return
	}
	uiWsSend(conn, uiSceneFrame(scene, cuts, insets, "", nil, seq, 0))
}

// Everything a socket says, turned into messages and posted to the fold.
func uiPump(w *uiWindow, addr SyslinkAddress, conn NetWsConnection) {
	parts := uiFileParts{}
	for {
		got := NetWsReceive(conn)
		if got.IsError() {
			return
		}
		id, kind, value, index := uiEvent(got.Ok())
		if id == "" {
			continue
		}
		value, whole := parts.take(id, kind, value)
		if !whole {
			continue
		}

		// Not an event and never folded: a page saying it has lost the thread of
		// the world. See uiSceneFrame.
		if kind == "resync" {
			w.reseed(conn)
			continue
		}
		msg, ok := w.message(id, kind, value, index)
		switch {
		case ok && uiDrawnAfter(kind):
			syslinkPostDrawn(addr, msg)
		case ok:
			SyslinkPost(addr, msg)
		case kind == "frame":
			NetWsSend(conn, "A")
		}
	}
}

var uiCrashOnce sync.Once

func uiCrashLog() {
	uiCrashOnce.Do(func() {
		name := strings.TrimSuffix(filepath.Base(os.Args[0]), filepath.Ext(os.Args[0]))
		path := filepath.Join(os.TempDir(), name+"-crash.log")
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return
		}
		debug.SetCrashOutput(f, debug.CrashOptions{})
		f.Close()
	})
}

func uiDrawnAfter(kind string) bool {
	switch kind {
	case "frame", "click", "input", "submit", "choose", "toggle", "key", "edit", "menu", "middle", "double", "jump",
		"enter", "leave", "focus", "blur", "press", "release", "drop", "file":
		return true
	}
	return false
}

// A file crosses as its name and its bytes, each in base64, because a name may hold any character and a file any byte.
func uiFileOf(value string) (string, string, bool) {
	name, body, ok := strings.Cut(value, ",")
	if !ok {
		return "", "", false
	}
	n, err := base64.StdEncoding.DecodeString(name)
	if err != nil {
		return "", "", false
	}
	b, err := base64.StdEncoding.DecodeString(body)
	if err != nil {
		return "", "", false
	}
	return string(n), string(b), true
}

// The pieces of files still arriving, by the widget they are for.
type uiFileParts map[string]*strings.Builder

// An event as it can be delivered: a piece of a file is held, and the file's last carries the rest in front of it.
func (p uiFileParts) take(id, kind, value string) (string, bool) {
	if kind == "filepart" {
		if p[id] == nil {
			p[id] = &strings.Builder{}
		}
		p[id].WriteString(value)
		return "", false
	}
	if kind == "file" && p[id] != nil {
		name, last, _ := strings.Cut(value, ",")
		value = name + "," + p[id].String() + last
		delete(p, id)
	}
	if kind == "snapshot" && p[id] != nil {
		value = p[id].String() + value
		delete(p, id)
	}
	return value, true
}

func uiFileValue(name string, contents []byte) string {
	return base64.StdEncoding.EncodeToString([]byte(name)) + "," + base64.StdEncoding.EncodeToString(contents)
}

// Reads the four fields the shell sends. The payload is this program's own
// shell talking to this program, so a hand-written reader beats pulling the
// JSON module into every window.
func uiEvent(text string) (string, string, string, int) {
	id := uiField(text, "id")
	kind := uiField(text, "kind")
	value := uiField(text, "value")
	index, _ := strconv.Atoi(uiField(text, "index"))
	return id, kind, value, index
}

func uiField(text string, name string) string {
	key := "\"" + name + "\":"
	at := strings.Index(text, key)
	if at < 0 {
		return ""
	}
	rest := strings.TrimLeft(text[at+len(key):], " ")
	if rest == "" {
		return ""
	}
	if rest[0] != '"' {
		end := strings.IndexAny(rest, ",}")
		if end < 0 {
			end = len(rest)
		}
		return strings.TrimSpace(rest[:end])
	}
	var b strings.Builder
	for i := 1; i < len(rest); i++ {
		if rest[i] == '\\' && i+1 < len(rest) {
			i++
			switch rest[i] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case 'u':
				if i+4 < len(rest) {
					if n, err := strconv.ParseInt(rest[i+1:i+5], 16, 32); err == nil {
						b.WriteRune(rune(n))
						i += 4
					}
				}
			default:
				b.WriteByte(rest[i])
			}
			continue
		}
		if rest[i] == '"' {
			break
		}
		b.WriteByte(rest[i])
	}
	return b.String()
}

// The program's own icon, embedded by the build from `assets/icon.png`. Nil in a
// program that ships none; hive/windowicon.go fills it in.
var uiWindowIcon []byte

func uiWindowIconIs(body []byte) { uiWindowIcon = body }

// What the shell links. A program's own icon is served from the window's own
// server; without one, the mark below is the whole of what ships — one path, so
// a window is never left with a browser's blank sheet.
func uiIconHref() string {
	if len(uiWindowIcon) > 0 {
		return "/_hive/icon"
	}
	return "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'" +
		"%3E%3Cpath fill='%23f0b429' d='M12 1.5 21 6.75v10.5L12 22.5 3 17.25V6.75z'/%3E%3C/svg%3E"
}

// Serving it. Cached hard: the bytes are in the executable, so they cannot go
// stale while the program runs.
func uiIconRoute(rw http.ResponseWriter, req *http.Request) {
	rw.Header().Set("Content-Type", "image/png")
	rw.Header().Set("Cache-Control", "max-age=31536000, immutable")
	rw.Write(uiWindowIcon)
}

// Binding the port. Always a free one chosen by the operating system, and
// always on loopback: nothing outside this machine is meant to reach a window,
// so the number is an implementation detail rather than something a call
// carries — and one fewer thing that can collide with the program's own server.
func uiListen() (net.Listener, int) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "hive: ui.window could not bind a local port: "+err.Error())
		return nil, 0
	}
	return listener, listener.Addr().(*net.TCPAddr).Port
}

// What the window is opened with. A profile of its own is what makes it a program
// rather than a browser window: without one the launch is handed to a browser
// already running, and the window shares that session and dies with it.
func uiAppArguments(url string) []string {
	arguments := []string{"--app=" + url, "--window-size=1100,780"}
	profile := uiProfileDir()
	if profile == "" {
		return arguments
	}
	arguments = append(arguments,
		"--user-data-dir="+profile,
		"--no-first-run",
		"--no-default-browser-check")

	// What a window manager groups a window under. Windows and macOS have no
	// such notion and are handed none.
	if runtime.GOOS != "windows" && runtime.GOOS != "darwin" {
		arguments = append(arguments, "--class="+uiAppName())
	}
	return arguments
}

// Where that profile lives: one directory per program, under the platform's own
// cache — losing it costs a window its size and position, nothing more. Answers
// `""` where none can be made, which opens the window without one.
func uiProfileDir() string {
	root, err := os.UserCacheDir()
	if err != nil {
		root = os.TempDir()
	}

	// Named for the program and for where it is: two programs called `client`
	// are two programs, and each wants its own window back.
	sum := fnv.New32a()
	if path, err := os.Executable(); err == nil {
		sum.Write([]byte(path))
	} else {
		sum.Write([]byte(os.Args[0]))
	}
	dir := filepath.Join(root, "hive", "windows", uiAppName()+"-"+strconv.FormatUint(uint64(sum.Sum32()), 16))
	if os.MkdirAll(dir, 0o700) != nil {
		return ""
	}
	return dir
}

// The program's own name, as a window manager may be shown it.
func uiAppName() string {
	name := filepath.Base(os.Args[0])
	name = strings.TrimSuffix(name, ".exe")
	kept := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		case r >= 'A' && r <= 'Z':
			return r + 32
		}
		return -1
	}, name)
	if kept == "" {
		return "hive"
	}
	return kept
}

// Opening the window. A browser already installed in application mode is a real
// window with no address bar and no tabs; without one, an ordinary tab is a
// perfectly good fallback. Nothing here is linked into the binary, so the build
// stays free of dependencies on every platform.
//
// A browser installed as a Flatpak puts nothing on PATH, so the loop above
// finds none on a machine that has several — which is every atomic Fedora,
// Silverblue and Bluefin desktop. Asked by id instead, they are there.
func uiOpen(url string) error {
	if runtime.GOOS == "android" || os.Getenv("HIVE_WINDOW") == "print" {
		fmt.Println("hive-window " + url)
		return nil
	}
	arguments := uiAppArguments(url)
	for _, candidate := range uiBrowsers() {
		path, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		cmd := exec.Command(path, arguments...)
		if err := cmd.Start(); err == nil {
			return nil
		}
	}
	if flatpak, err := exec.LookPath("flatpak"); err == nil {
		for _, id := range uiFlatpakBrowsers() {

			// info is how you ask whether one is installed without starting it.
			if exec.Command(flatpak, "info", id).Run() != nil {
				continue
			}
			cmd := exec.Command(flatpak, append([]string{"run", id}, arguments...)...)
			if cmd.Start() == nil {
				return nil
			}
		}
	}
	switch runtime.GOOS {
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		return exec.Command("open", url).Start()
	default:
		return exec.Command("xdg-open", url).Start()
	}
}

// The Chromium-family Flatpaks worth asking about, by application id. Only
// these: application mode is a Chromium flag, and a browser that does not have
// it would open a tab, which is what the fallback below is already for.
func uiFlatpakBrowsers() []string {
	return []string{
		"com.google.Chrome",
		"org.chromium.Chromium",
		"com.microsoft.Edge",
		"com.brave.Browser",
		"com.vivaldi.Vivaldi",
		"io.github.ungoogled_software.ungoogled_chromium",
	}
}

func uiBrowsers() []string {
	switch runtime.GOOS {
	case "windows":
		return []string{
			"chrome", "msedge", "chromium",
			"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
			"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
		}
	case "darwin":
		return []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
	default:
		return []string{
			"google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
			"microsoft-edge", "brave-browser", "vivaldi",
		}
	}
}

// What every Icon is drawn as: a Lucide icon (lucide.dev, ISC; see runtime/NOTICE.md), stroked in the current colour.

var uiIconShapes = map[string]string{
	"Search":          `<path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>`,
	"Close":           `<path d="M18 6 6 18"/><path d="m6 6 12 12"/>`,
	"Check":           `<path d="M20 6 9 17l-5-5"/>`,
	"Plus":            `<path d="M5 12h14"/><path d="M12 5v14"/>`,
	"Minus":           `<path d="M5 12h14"/>`,
	"Up":              `<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>`,
	"Down":            `<path d="M12 5v14"/><path d="m19 12-7 7-7-7"/>`,
	"Left":            `<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>`,
	"Right":           `<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>`,
	"Warning":         `<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>`,
	"Info":            `<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>`,
	"Star":            `<path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>`,
	"Heart":           `<path d="M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"/>`,
	"Reply":           `<path d="M20 18v-2a4 4 0 0 0-4-4H4"/><path d="m9 17-5-5 5-5"/>`,
	"Repeat":          `<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>`,
	"Trash":           `<path d="M10 11v6"/><path d="M14 11v6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>`,
	"User":            `<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>`,
	"Menu":            `<path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/>`,
	"ChevronUp":       `<path d="m18 15-6-6-6 6"/>`,
	"ChevronDown":     `<path d="m6 9 6 6 6-6"/>`,
	"ChevronLeft":     `<path d="m15 18-6-6 6-6"/>`,
	"ChevronRight":    `<path d="m9 18 6-6-6-6"/>`,
	"ChevronsUp":      `<path d="m17 11-5-5-5 5"/><path d="m17 18-5-5-5 5"/>`,
	"ChevronsDown":    `<path d="m7 6 5 5 5-5"/><path d="m7 13 5 5 5-5"/>`,
	"ChevronsLeft":    `<path d="m11 17-5-5 5-5"/><path d="m18 17-5-5 5-5"/>`,
	"ChevronsRight":   `<path d="m6 17 5-5-5-5"/><path d="m13 17 5-5-5-5"/>`,
	"UpRight":         `<path d="M7 7h10v10"/><path d="M7 17 17 7"/>`,
	"UpLeft":          `<path d="M7 17V7h10"/><path d="M17 17 7 7"/>`,
	"DownRight":       `<path d="m7 7 10 10"/><path d="M17 7v10H7"/>`,
	"DownLeft":        `<path d="M17 7 7 17"/><path d="M17 17H7V7"/>`,
	"CornerDownLeft":  `<path d="M20 4v7a4 4 0 0 1-4 4H4"/><path d="m9 10-5 5 5 5"/>`,
	"CornerUpRight":   `<path d="m15 14 5-5-5-5"/><path d="M4 20v-7a4 4 0 0 1 4-4h12"/>`,
	"Expand":          `<path d="m15 15 6 6"/><path d="m15 9 6-6"/><path d="M21 16v5h-5"/><path d="M21 8V3h-5"/><path d="M3 16v5h5"/><path d="m3 21 6-6"/><path d="M3 8V3h5"/><path d="M9 9 3 3"/>`,
	"Shrink":          `<path d="m15 15 6 6m-6-6v4.8m0-4.8h4.8"/><path d="M9 19.8V15m0 0H4.2M9 15l-6 6"/><path d="M15 4.2V9m0 0h4.8M15 9l6-6"/><path d="M9 4.2V9m0 0H4.2M9 9 3 3"/>`,
	"Maximize":        `<path d="M8 3H5a2 2 0 0 0-2 2v3"/><path d="M21 8V5a2 2 0 0 0-2-2h-3"/><path d="M3 16v3a2 2 0 0 0 2 2h3"/><path d="M16 21h3a2 2 0 0 0 2-2v-3"/>`,
	"Minimize":        `<path d="M8 3v3a2 2 0 0 1-2 2H3"/><path d="M21 8h-3a2 2 0 0 1-2-2V3"/><path d="M3 16h3a2 2 0 0 1 2 2v3"/><path d="M16 21v-3a2 2 0 0 1 2-2h3"/>`,
	"ExternalLink":    `<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>`,
	"Undo":            `<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"/>`,
	"Redo":            `<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5A5.5 5.5 0 0 0 9.5 20H13"/>`,
	"Refresh":         `<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>`,
	"RotateLeft":      `<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>`,
	"RotateRight":     `<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>`,
	"Home":            `<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`,
	"More":            `<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>`,
	"MoreVertical":    `<circle cx="12" cy="12" r="1"/><circle cx="12" cy="5" r="1"/><circle cx="12" cy="19" r="1"/>`,
	"Grip":            `<circle cx="9" cy="12" r="1"/><circle cx="9" cy="5" r="1"/><circle cx="9" cy="19" r="1"/><circle cx="15" cy="12" r="1"/><circle cx="15" cy="5" r="1"/><circle cx="15" cy="19" r="1"/>`,
	"Move":            `<path d="M12 2v20"/><path d="m15 19-3 3-3-3"/><path d="m19 9 3 3-3 3"/><path d="M2 12h20"/><path d="m5 9-3 3 3 3"/><path d="m9 5 3-3 3 3"/>`,
	"LogIn":           `<path d="m10 17 5-5-5-5"/><path d="M15 12H3"/><path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/>`,
	"LogOut":          `<path d="m16 17 5-5-5-5"/><path d="M21 12H9"/><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>`,
	"Sidebar":         `<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/>`,
	"Columns":         `<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M12 3v18"/>`,
	"Edit":            `<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>`,
	"Copy":            `<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>`,
	"Clipboard":       `<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>`,
	"ClipboardCheck":  `<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="m9 14 2 2 4-4"/>`,
	"Cut":             `<circle cx="6" cy="6" r="3"/><path d="M8.12 8.12 12 12"/><path d="M20 4 8.12 15.88"/><circle cx="6" cy="18" r="3"/><path d="M14.8 14.8 20 20"/>`,
	"Save":            `<path d="M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7"/><path d="M7 3v4a1 1 0 0 0 1 1h7"/>`,
	"Download":        `<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>`,
	"Upload":          `<path d="M12 3v12"/><path d="m17 8-5-5-5 5"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>`,
	"Share":           `<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>`,
	"Send":            `<path d="M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"/><path d="m21.854 2.147-10.94 10.939"/>`,
	"Print":           `<path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><path d="M6 9V3a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v6"/><rect x="6" y="14" width="12" height="8" rx="1"/>`,
	"Filter":          `<path d="M10 20a1 1 0 0 0 .553.895l2 1A1 1 0 0 0 14 21v-7a2 2 0 0 1 .517-1.341L21.74 4.67A1 1 0 0 0 21 3H3a1 1 0 0 0-.742 1.67l7.225 7.989A2 2 0 0 1 10 14z"/>`,
	"Sort":            `<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>`,
	"SortUp":          `<path d="m3 8 4-4 4 4"/><path d="M7 4v16"/><path d="M11 12h4"/><path d="M11 16h7"/><path d="M11 20h10"/>`,
	"SortDown":        `<path d="m3 16 4 4 4-4"/><path d="M7 20V4"/><path d="M11 4h10"/><path d="M11 8h7"/><path d="M11 12h4"/>`,
	"ZoomIn":          `<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="11" x2="11" y1="8" y2="14"/><line x1="8" x2="14" y1="11" y2="11"/>`,
	"ZoomOut":         `<circle cx="11" cy="11" r="8"/><line x1="21" x2="16.65" y1="21" y2="16.65"/><line x1="8" x2="14" y1="11" y2="11"/>`,
	"Settings":        `<path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"/><circle cx="12" cy="12" r="3"/>`,
	"Sliders":         `<path d="M10 5H3"/><path d="M12 19H3"/><path d="M14 3v4"/><path d="M16 17v4"/><path d="M21 12h-9"/><path d="M21 19h-5"/><path d="M21 5h-7"/><path d="M8 10v4"/><path d="M8 12H3"/>`,
	"Wrench":          `<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z"/>`,
	"Lock":            `<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>`,
	"Unlock":          `<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 9.9-1"/>`,
	"Key":             `<path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/><circle cx="16.5" cy="7.5" r=".5" fill="currentColor"/>`,
	"Shield":          `<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>`,
	"ShieldCheck":     `<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>`,
	"Eye":             `<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>`,
	"EyeOff":          `<path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"/><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"/><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"/><path d="m2 2 20 20"/>`,
	"Pin":             `<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>`,
	"Unpin":           `<path d="M12 17v5"/><path d="M15 9.34V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H7.89"/><path d="m2 2 20 20"/><path d="M9 9v1.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h11"/>`,
	"Bookmark":        `<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z"/>`,
	"Tag":             `<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>`,
	"Flag":            `<path d="M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528"/>`,
	"Link":            `<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>`,
	"Unlink":          `<path d="m18.84 12.25 1.72-1.71h-.02a5.004 5.004 0 0 0-.12-7.07 5.006 5.006 0 0 0-6.95 0l-1.72 1.71"/><path d="m5.17 11.75-1.71 1.71a5.004 5.004 0 0 0 .12 7.07 5.006 5.006 0 0 0 6.95 0l1.71-1.71"/><line x1="8" x2="8" y1="2" y2="5"/><line x1="2" x2="5" y1="8" y2="8"/><line x1="16" x2="16" y1="19" y2="22"/><line x1="19" x2="22" y1="16" y2="16"/>`,
	"Paperclip":       `<path d="m16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551"/>`,
	"Archive":         `<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>`,
	"Inbox":           `<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>`,
	"Bell":            `<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/>`,
	"BellOff":         `<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M17 17H4a1 1 0 0 1-.74-1.673C4.59 13.956 6 12.499 6 8a6 6 0 0 1 .258-1.742"/><path d="m2 2 20 20"/><path d="M8.668 3.01A6 6 0 0 1 18 8c0 2.687.77 4.653 1.707 6.05"/>`,
	"Mail":            `<path d="m22 7-8.991 5.727a2 2 0 0 1-2.009 0L2 7"/><rect x="2" y="4" width="20" height="16" rx="2"/>`,
	"Message":         `<path d="M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z"/>`,
	"Messages":        `<path d="M16 10a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 14.286V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/><path d="M20 9a2 2 0 0 1 2 2v10.286a.71.71 0 0 1-1.212.502l-2.202-2.202A2 2 0 0 0 17.172 19H10a2 2 0 0 1-2-2v-1"/>`,
	"Phone":           `<path d="M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384"/>`,
	"Video":           `<path d="m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5"/><rect x="2" y="6" width="14" height="12" rx="2"/>`,
	"VideoOff":        `<path d="M10.66 6H14a2 2 0 0 1 2 2v2.5l5.248-3.062A.5.5 0 0 1 22 7.87v8.196"/><path d="M16 16a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2"/><path d="m2 2 20 20"/>`,
	"Mic":             `<path d="M12 19v3"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><rect x="9" y="2" width="6" height="13" rx="3"/>`,
	"MicOff":          `<path d="M12 19v3"/><path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"/><path d="M16.95 16.95A7 7 0 0 1 5 12v-2"/><path d="M18.89 13.23A7 7 0 0 0 19 12v-2"/><path d="m2 2 20 20"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12"/>`,
	"Camera":          `<path d="M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z"/><circle cx="12" cy="13" r="3"/>`,
	"Image":           `<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>`,
	"Film":            `<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18"/><path d="M3 7.5h4"/><path d="M3 12h18"/><path d="M3 16.5h4"/><path d="M17 3v18"/><path d="M17 7.5h4"/><path d="M17 16.5h4"/>`,
	"Music":           `<path d="M21 16V3a1 1 0 0 0-1.28-.96l-10 2.917a1 1 0 0 0-.72.96V19"/><circle cx="18" cy="16" r="3"/><circle cx="6" cy="19" r="3"/>`,
	"Headphones":      `<path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"/>`,
	"Volume":          `<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>`,
	"VolumeLow":       `<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/>`,
	"Mute":            `<path d="M11 4.702a.7.7 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.7.7 0 0 0 11 19.298z"/><path d="m16.5 14.5 5-5"/><path d="m16.5 9.5 5 5"/>`,
	"Play":            `<path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"/>`,
	"Pause":           `<rect x="14" y="3" width="5" height="18" rx="1"/><rect x="5" y="3" width="5" height="18" rx="1"/>`,
	"Stop":            `<rect width="18" height="18" x="3" y="3" rx="2"/>`,
	"SkipForward":     `<path d="M21 4v16"/><path d="M6.029 4.285A2 2 0 0 0 3 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z"/>`,
	"SkipBack":        `<path d="M17.971 4.285A2 2 0 0 1 21 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z"/><path d="M3 20V4"/>`,
	"FastForward":     `<path d="M12 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 12 18z"/><path d="M2 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 2 18z"/>`,
	"Rewind":          `<path d="M12 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 12 18z"/><path d="M22 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 22 18z"/>`,
	"Shuffle":         `<path d="m18 14 4 4-4 4"/><path d="m18 2 4 4-4 4"/><path d="M2 18h1.973a4 4 0 0 0 3.3-1.7l5.454-8.6a4 4 0 0 1 3.3-1.7H22"/><path d="M2 6h1.972a4 4 0 0 1 3.6 2.2"/><path d="M22 18h-6.041a4 4 0 0 1-3.3-1.8l-.359-.45"/>`,
	"File":            `<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/>`,
	"FileText":        `<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>`,
	"FilePlus":        `<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><path d="M9 15h6"/><path d="M12 18v-6"/>`,
	"Files":           `<path d="M15 2h-4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V8"/><path d="M16.706 2.706A2.4 2.4 0 0 0 15 2v5a1 1 0 0 0 1 1h5a2.4 2.4 0 0 0-.706-1.706z"/><path d="M5 7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 1.732-1"/>`,
	"Folder":          `<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`,
	"FolderOpen":      `<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>`,
	"FolderPlus":      `<path d="M12 10v6"/><path d="M9 13h6"/><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`,
	"Code":            `<path d="m16 18 6-6-6-6"/><path d="m8 6-6 6 6 6"/>`,
	"Terminal":        `<path d="M12 19h8"/><path d="m4 17 6-6-6-6"/>`,
	"Database":        `<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/>`,
	"Server":          `<rect width="20" height="8" x="2" y="2" rx="2" ry="2"/><rect width="20" height="8" x="2" y="14" rx="2" ry="2"/><line x1="6" x2="6.01" y1="6" y2="6"/><line x1="6" x2="6.01" y1="18" y2="18"/>`,
	"Cloud":           `<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/>`,
	"CloudUpload":     `<path d="M12 13v8"/><path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242"/><path d="m8 17 4-4 4 4"/>`,
	"CloudDownload":   `<path d="M12 13v8l-4-4"/><path d="m12 21 4-4"/><path d="M4.393 15.269A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.436 8.284"/>`,
	"HardDrive":       `<path d="M10 16h.01"/><path d="M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M21.946 12.013H2.054"/><path d="M6 16h.01"/>`,
	"Package":         `<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12"/><polyline points="3.29 7 12 12 20.71 7"/><path d="m7.5 4.27 9 5.15"/>`,
	"Layers":          `<path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z"/><path d="M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12"/><path d="M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17"/>`,
	"Dashboard":       `<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>`,
	"Grid":            `<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/>`,
	"List":            `<path d="M3 5h.01"/><path d="M3 12h.01"/><path d="M3 19h.01"/><path d="M8 5h13"/><path d="M8 12h13"/><path d="M8 19h13"/>`,
	"ListOrdered":     `<path d="M11 5h10"/><path d="M11 12h10"/><path d="M11 19h10"/><path d="M4 4h1v5"/><path d="M4 9h2"/><path d="M6.5 20H3.4c0-1 2.6-1.925 2.6-3.5a1.5 1.5 0 0 0-2.6-1.02"/>`,
	"ListChecks":      `<path d="M13 5h8"/><path d="M13 12h8"/><path d="M13 19h8"/><path d="m3 17 2 2 4-4"/><path d="m3 7 2 2 4-4"/>`,
	"Kanban":          `<path d="M5 3v14"/><path d="M12 3v8"/><path d="M19 3v18"/>`,
	"Calendar":        `<path d="M8 2v3"/><path d="M16 2v3"/><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/>`,
	"Clock":           `<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>`,
	"Timer":           `<line x1="10" x2="14" y1="2" y2="2"/><line x1="12" x2="15" y1="14" y2="11"/><circle cx="12" cy="14" r="8"/>`,
	"Hourglass":       `<path d="M5 22h14"/><path d="M5 2h14"/><path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"/><path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/>`,
	"Alarm":           `<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2"/><path d="M5 3 2 6"/><path d="m22 6-3-3"/><path d="M6.38 18.7 4 21"/><path d="M17.64 18.67 20 21"/>`,
	"History":         `<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>`,
	"Users":           `<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><path d="M16 3.128a4 4 0 0 1 0 7.744"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><circle cx="9" cy="7" r="4"/>`,
	"UserPlus":        `<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><line x1="19" x2="19" y1="8" y2="14"/><line x1="22" x2="16" y1="11" y2="11"/>`,
	"UserMinus":       `<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><line x1="22" x2="16" y1="11" y2="11"/>`,
	"UserCheck":       `<path d="m16 11 2 2 4-4"/><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>`,
	"Contact":         `<path d="M16 2v2"/><path d="M7 21v-2a2 2 0 012-2h6a2 2 0 012 2v2"/><path d="M8 2v2"/><circle cx="12" cy="10" r="3"/><rect x="3" y="3" width="18" height="18" rx="2"/>`,
	"Smile":           `<path d="M15 10V9"/><path d="M16.472 15a6 6 0 01-8.943 0"/><path d="M9 10V9"/><circle cx="12" cy="12" r="10"/>`,
	"Frown":           `<path d="M15 10V9"/><path d="M9 10V9"/><path d="M9 16a5 5 0 016 0"/><circle cx="12" cy="12" r="10"/>`,
	"Meh":             `<path d="M15 10V9"/><path d="M8 16h8"/><path d="M9 10V9"/><circle cx="12" cy="12" r="10"/>`,
	"Laugh":           `<path d="M15 10V9"/><path d="M7.084 14.302a5.12 5.12 0 009.833 0 .24.24 0 00-.235-.302H7.32a.24.24 0 00-.235.302"/><path d="M9 10V9"/><circle cx="12" cy="12" r="10"/>`,
	"ThumbsUp":        `<path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/><path d="M7 10v12"/>`,
	"ThumbsDown":      `<path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/><path d="M17 14V2"/>`,
	"Award":           `<path d="m15.477 12.89 1.515 8.526a.5.5 0 0 1-.81.47l-3.58-2.687a1 1 0 0 0-1.197 0l-3.586 2.686a.5.5 0 0 1-.81-.469l1.514-8.526"/><circle cx="12" cy="8" r="6"/>`,
	"Trophy":          `<path d="M10 14.66V17a1 1 0 0 1-1 1 2 2 0 0 0-2 2v2"/><path d="M14 14.66V17a1 1 0 0 0 1 1 2 2 0 0 1 2 2v2"/><path d="M17.916 10H19.5A2.5 2.5 0 0 0 22 7.5V5a1 1 0 0 0-1-1h-3"/><path d="M4 22h16"/><path d="M6 9a6 6 0 0 0 12 0V3a1 1 0 0 0-1-1H7a1 1 0 0 0-1 1z"/><path d="M6.084 10H4.5A2.5 2.5 0 0 1 2 7.5V5a1 1 0 0 1 1-1h3"/>`,
	"Crown":           `<path d="M11.562 3.266a.5.5 0 0 1 .876 0L15.39 8.87a1 1 0 0 0 1.516.294L21.183 5.5a.5.5 0 0 1 .798.519l-2.834 10.246a1 1 0 0 1-.956.734H5.81a1 1 0 0 1-.957-.734L2.02 6.02a.5.5 0 0 1 .798-.519l4.276 3.664a1 1 0 0 0 1.516-.294z"/><path d="M5 21h14"/>`,
	"Gift":            `<path d="M12 7v14"/><path d="M20 11v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-8"/><path d="M7.5 7a1 1 0 0 1 0-5A4.8 8 0 0 1 12 7a4.8 8 0 0 1 4.5-5 1 1 0 0 1 0 5"/><rect x="3" y="7" width="18" height="4" rx="1"/>`,
	"Cake":            `<path d="M20 21v-8a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8"/><path d="M4 16s.5-1 2-1 2.5 2 4 2 2.5-2 4-2 2.5 2 4 2 2-1 2-1"/><path d="M2 21h20"/><path d="M7 8v3"/><path d="M12 8v3"/><path d="M17 8v3"/><path d="M7 4h.01"/><path d="M12 4h.01"/><path d="M17 4h.01"/>`,
	"Hand":            `<path d="M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2"/><path d="M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2"/><path d="M10 10.5V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/>`,
	"Handshake":       `<path d="m11 17 2 2a1 1 0 1 0 3-3"/><path d="m14 14 2.5 2.5a1 1 0 1 0 3-3l-3.88-3.88a3 3 0 0 0-4.24 0l-.88.88a1 1 0 1 1-3-3l2.81-2.81a5.79 5.79 0 0 1 7.06-.87l.47.28a2 2 0 0 0 1.42.25L21 4"/><path d="m21 3 1 11h-2"/><path d="M3 3 2 14l6.5 6.5a1 1 0 1 0 3-3"/><path d="M3 4h8"/>`,
	"Accessibility":   `<circle cx="16" cy="4" r="1"/><path d="m18 19 1-7-6 1"/><path d="m5 8 3-3 5.5 3-2.36 3.5"/><path d="M4.24 14.5a5 5 0 0 0 6.88 6"/><path d="M13.76 17.5a5 5 0 0 0-6.88-6"/>`,
	"Baby":            `<path d="M10 16c.5.3 1.2.5 2 .5s1.5-.2 2-.5"/><path d="M15 12h.01"/><path d="M19.38 6.813A9 9 0 0 1 20.8 10.2a2 2 0 0 1 0 3.6 9 9 0 0 1-17.6 0 2 2 0 0 1 0-3.6A9 9 0 0 1 12 3c2 0 3.5 1.1 3.5 2.5s-.9 2.5-2 2.5c-.8 0-1.5-.4-1.5-1"/><path d="M9 12h.01"/>`,
	"CircleAlert":     `<circle cx="12" cy="12" r="10"/><line x1="12" x2="12" y1="8" y2="12"/><line x1="12" x2="12.01" y1="16" y2="16"/>`,
	"CircleX":         `<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>`,
	"CircleCheck":     `<circle cx="12" cy="12" r="10"/><path d="m16 9-5.5 5.5L8 12"/>`,
	"CircleHelp":      `<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>`,
	"Ban":             `<circle cx="12" cy="12" r="10"/><path d="M4.929 4.929 19.07 19.071"/>`,
	"Loader":          `<path d="M12 2v4"/><path d="m16.2 7.8 2.9-2.9"/><path d="M18 12h4"/><path d="m16.2 16.2 2.9 2.9"/><path d="M12 18v4"/><path d="m4.9 19.1 2.9-2.9"/><path d="M2 12h4"/><path d="m4.9 4.9 2.9 2.9"/>`,
	"Activity":        `<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>`,
	"Zap":             `<path d="M15.914 4a1.5 1.5 0 00-2.474-1.561l-9 9A1.5 1.5 0 005.5 14h4.002a.5.5 0 01.471.666L8.086 20a1.5 1.5 0 002.475 1.56l9-9A1.5 1.5 0 0018.5 10h-3.997a.5.5 0 01-.472-.667z"/>`,
	"Flame":           `<path d="M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"/>`,
	"Battery":         `<path d="M 22 14 L 22 10"/><rect x="2" y="6" width="16" height="12" rx="2"/>`,
	"BatteryLow":      `<path d="M22 14v-4"/><path d="M6 14v-4"/><rect x="2" y="6" width="16" height="12" rx="2"/>`,
	"BatteryCharging": `<path d="m11 7-3 5h4l-3 5"/><path d="M14.856 6H16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.935"/><path d="M22 14v-4"/><path d="M5.14 18H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2.936"/>`,
	"Wifi":            `<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>`,
	"WifiOff":         `<path d="M12 20h.01"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/><path d="M5 12.859a10 10 0 0 1 5.17-2.69"/><path d="M19 12.859a10 10 0 0 0-2.007-1.523"/><path d="M2 8.82a15 15 0 0 1 4.177-2.643"/><path d="M22 8.82a15 15 0 0 0-11.288-3.764"/><path d="m2 2 20 20"/>`,
	"Bluetooth":       `<path d="m7 7 10 10-5 5V2l5 5L7 17"/>`,
	"Signal":          `<path d="M2 20h.01"/><path d="M7 20v-4"/><path d="M12 20v-8"/><path d="M17 20V8"/><path d="M22 4v16"/>`,
	"Power":           `<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>`,
	"Plug":            `<path d="M12 22v-5"/><path d="M15 8V2"/><path d="M17 8a1 1 0 0 1 1 1v4a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z"/><path d="M9 8V2"/>`,
	"Cpu":             `<path d="M12 20v2"/><path d="M12 2v2"/><path d="M17 20v2"/><path d="M17 2v2"/><path d="M2 12h2"/><path d="M2 17h2"/><path d="M2 7h2"/><path d="M20 12h2"/><path d="M20 17h2"/><path d="M20 7h2"/><path d="M7 20v2"/><path d="M7 2v2"/><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="8" y="8" width="8" height="8" rx="1"/>`,
	"Monitor":         `<rect width="20" height="14" x="2" y="3" rx="2"/><line x1="8" x2="16" y1="21" y2="21"/><line x1="12" x2="12" y1="17" y2="21"/>`,
	"Laptop":          `<path d="M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z"/><path d="M20.054 15.987H3.946"/>`,
	"Smartphone":      `<rect width="14" height="20" x="5" y="2" rx="2" ry="2"/><path d="M12 18h.01"/>`,
	"Tablet":          `<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><line x1="12" x2="12.01" y1="18" y2="18"/>`,
	"Keyboard":        `<path d="M10 8h.01"/><path d="M12 12h.01"/><path d="M14 8h.01"/><path d="M16 12h.01"/><path d="M18 8h.01"/><path d="M6 8h.01"/><path d="M7 16h10"/><path d="M8 12h.01"/><rect width="20" height="16" x="2" y="4" rx="2"/>`,
	"Mouse":           `<rect x="5" y="2" width="14" height="20" rx="7"/><path d="M12 6v4"/>`,
	"Gamepad":         `<line x1="6" x2="10" y1="11" y2="11"/><line x1="8" x2="8" y1="9" y2="13"/><line x1="15" x2="15.01" y1="12" y2="12"/><line x1="18" x2="18.01" y1="10" y2="10"/><path d="M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017-.151A4 4 0 0 0 17.32 5z"/>`,
	"Tv":              `<path d="m17 2-5 5-5-5"/><rect width="20" height="15" x="2" y="7" rx="2"/>`,
	"Watch":           `<path d="M12 10v2.2l1.6 1"/><path d="m16.13 7.66-.81-4.05a2 2 0 0 0-2-1.61h-2.68a2 2 0 0 0-2 1.61l-.78 4.05"/><path d="m7.88 16.36.8 4a2 2 0 0 0 2 1.61h2.72a2 2 0 0 0 2-1.61l.81-4.05"/><circle cx="12" cy="12" r="6"/>`,
	"Speaker":         `<rect width="16" height="20" x="4" y="2" rx="2"/><path d="M12 6h.01"/><circle cx="12" cy="14" r="4"/><path d="M12 14h.01"/>`,
	"Usb":             `<circle cx="10" cy="7" r="1"/><circle cx="4" cy="20" r="1"/><path d="M4.7 19.3 19 5"/><path d="m21 3-3 1 2 2Z"/><path d="M9.26 7.68 5 12l2 5"/><path d="m10 14 5 2 3.5-3.5"/><path d="m18 12 1-1 1 1-1 1Z"/>`,
	"Router":          `<rect width="20" height="8" x="2" y="14" rx="2"/><path d="M6.01 18H6"/><path d="M10.01 18H10"/><path d="M15 10v4"/><path d="M17.84 7.17a4 4 0 0 0-5.66 0"/><path d="M20.66 4.34a8 8 0 0 0-11.31 0"/>`,
	"Network":         `<rect x="16" y="16" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="9" y="2" width="6" height="6" rx="1"/><path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/><path d="M12 12V8"/>`,
	"Satellite":       `<path d="m13.5 6.5-3.148-3.148a1.205 1.205 0 0 0-1.704 0L6.352 5.648a1.205 1.205 0 0 0 0 1.704L9.5 10.5"/><path d="M16.5 7.5 19 5"/><path d="m17.5 10.5 3.148 3.148a1.205 1.205 0 0 1 0 1.704l-2.296 2.296a1.205 1.205 0 0 1-1.704 0L13.5 14.5"/><path d="M9 21a6 6 0 0 0-6-6"/><path d="M9.352 10.648a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l4.296-4.296a1.205 1.205 0 0 0 0-1.704l-2.296-2.296a1.205 1.205 0 0 0-1.704 0z"/>`,
	"Radio":           `<path d="M16.247 7.761a6 6 0 0 1 0 8.478"/><path d="M19.075 4.933a10 10 0 0 1 0 14.134"/><path d="M4.925 19.067a10 10 0 0 1 0-14.134"/><path d="M7.753 16.239a6 6 0 0 1 0-8.478"/><circle cx="12" cy="12" r="2"/>`,
	"Rss":             `<path d="M4 11a9 9 0 0 1 9 9"/><path d="M4 4a16 16 0 0 1 16 16"/><circle cx="5" cy="19" r="1"/>`,
	"Scan":            `<path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>`,
	"QrCode":          `<rect width="5" height="5" x="3" y="3" rx="1"/><rect width="5" height="5" x="16" y="3" rx="1"/><rect width="5" height="5" x="3" y="16" rx="1"/><path d="M21 16h-3a2 2 0 0 0-2 2v3"/><path d="M21 21v.01"/><path d="M12 7v3a2 2 0 0 1-2 2H7"/><path d="M3 12h.01"/><path d="M12 3h.01"/><path d="M12 16v.01"/><path d="M16 12h1"/><path d="M21 12v.01"/><path d="M12 21v-1"/>`,
	"Barcode":         `<path d="M3 5v14"/><path d="M8 5v14"/><path d="M12 5v14"/><path d="M17 5v14"/><path d="M21 5v14"/>`,
	"Fingerprint":     `<path d="M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4"/><path d="M14 13.12c0 2.38 0 6.38-1 8.88"/><path d="M17.29 21.02c.12-.6.43-2.3.5-3.02"/><path d="M2 12a10 10 0 0 1 18-6"/><path d="M2 16h.01"/><path d="M21.8 16c.2-2 .131-5.354 0-6"/><path d="M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2"/><path d="M8.65 22c.21-.66.45-1.32.57-2"/><path d="M9 6.8a6 6 0 0 1 9 5.2v2"/>`,
	"Bot":             `<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>`,
	"Brain":           `<path d="M12 18V5"/><path d="M15 13a4.17 4.17 0 01-3-4 4.17 4.17 0 01-3 4"/><path d="M17.707 6.294A3 3 0 1012 5a3 3 0 10-5.707 1.294"/><path d="M17.996 5.125a4 4 0 012.526 5.77"/><path d="M18 18a4 4 0 002-7.465"/><path d="M19.967 17.482a4 4 0 11-7.967.517 4 4 0 11-7.967-.517"/><path d="M6 18a4 4 0 01-2-7.465"/><path d="M6.004 5.125a4 4 0 00-2.526 5.77"/>`,
	"Bug":             `<path d="M12 20v-9"/><path d="M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z"/><path d="M14.12 3.88 16 2"/><path d="M21 21a4 4 0 0 0-3.81-4"/><path d="M21 5a4 4 0 0 1-3.55 3.97"/><path d="M22 13h-4"/><path d="M3 21a4 4 0 0 1 3.81-4"/><path d="M3 5a4 4 0 0 0 3.55 3.97"/><path d="M6 13H2"/><path d="m8 2 1.88 1.88"/><path d="M9 7.13V6a3 3 0 1 1 6 0v1.13"/>`,
	"Branch":          `<path d="M15 6a9 9 0 0 0-9 9V3"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/>`,
	"Commit":          `<circle cx="12" cy="12" r="3"/><line x1="3" x2="9" y1="12" y2="12"/><line x1="15" x2="21" y1="12" y2="12"/>`,
	"Merge":           `<circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M6 21V9a9 9 0 0 0 9 9"/>`,
	"PullRequest":     `<circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M13 6h3a2 2 0 0 1 2 2v7"/><line x1="6" x2="6" y1="9" y2="21"/>`,
	"Command":         `<path d="M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3"/>`,
	"Cart":            `<path d="m2.05 2.05 1.099-.028a1 1 0 0 1 1.008.815l2.69 14.347A1 1 0 0 0 7.83 18H18"/><path d="M4.563 5h16.435a1 1 0 0 1 .981 1.204l-1.026 6.226A2 2 0 0 1 18.962 14H6.25"/><circle cx="18" cy="20" r="2"/><circle cx="8" cy="20" r="2"/>`,
	"Bag":             `<path d="M16 10a4 4 0 0 1-8 0"/><path d="M3.103 6.034h17.794"/><path d="M3.4 5.467a2 2 0 0 0-.4 1.2V20a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6.667a2 2 0 0 0-.4-1.2l-2-2.667A2 2 0 0 0 17 2H7a2 2 0 0 0-1.6.8z"/>`,
	"CreditCard":      `<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/><path d="M6 14h2"/>`,
	"Wallet":          `<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>`,
	"Dollar":          `<line x1="12" x2="12" y1="2" y2="22"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>`,
	"Euro":            `<path d="M4 10h12"/><path d="M4 14h9"/><path d="M19 6a7.7 7.7 0 0 0-5.2-2A7.9 7.9 0 0 0 6 12c0 4.4 3.5 8 7.8 8 2 0 3.8-.8 5.2-2"/>`,
	"Percent":         `<line x1="19" x2="5" y1="5" y2="19"/><circle cx="6.5" cy="6.5" r="2.5"/><circle cx="17.5" cy="17.5" r="2.5"/>`,
	"Receipt":         `<path d="M12 17V7"/><path d="M16 8h-6a2 2 0 0 0 0 4h4a2 2 0 0 1 0 4H8"/><path d="M4 3a1 1 0 0 1 1-1 1.3 1.3 0 0 1 .7.2l.933.6a1.3 1.3 0 0 0 1.4 0l.934-.6a1.3 1.3 0 0 1 1.4 0l.933.6a1.3 1.3 0 0 0 1.4 0l.933-.6a1.3 1.3 0 0 1 1.4 0l.934.6a1.3 1.3 0 0 0 1.4 0l.933-.6A1.3 1.3 0 0 1 19 2a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1 1.3 1.3 0 0 1-.7-.2l-.933-.6a1.3 1.3 0 0 0-1.4 0l-.934.6a1.3 1.3 0 0 1-1.4 0l-.933-.6a1.3 1.3 0 0 0-1.4 0l-.933.6a1.3 1.3 0 0 1-1.4 0l-.934-.6a1.3 1.3 0 0 0-1.4 0l-.933.6a1.3 1.3 0 0 1-.7.2 1 1 0 0 1-1-1z"/>`,
	"Store":           `<path d="M15 21v-5a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v5"/><path d="M17.774 10.31a1.12 1.12 0 0 0-1.549 0 2.5 2.5 0 0 1-3.451 0 1.12 1.12 0 0 0-1.548 0 2.5 2.5 0 0 1-3.452 0 1.12 1.12 0 0 0-1.549 0 2.5 2.5 0 0 1-3.77-3.248l2.889-4.184A2 2 0 0 1 7 2h10a2 2 0 0 1 1.653.873l2.895 4.192a2.5 2.5 0 0 1-3.774 3.244"/><path d="M4 10.95V19a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8.05"/>`,
	"Truck":           `<path d="M14 18V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v11a1 1 0 0 0 1 1h2"/><path d="M15 18H9"/><path d="M19 18h2a1 1 0 0 0 1-1v-3.65a1 1 0 0 0-.22-.624l-3.48-4.35A1 1 0 0 0 17.52 8H14"/><circle cx="17" cy="18" r="2"/><circle cx="7" cy="18" r="2"/>`,
	"Coins":           `<path d="M13.744 17.736a6 6 0 1 1-7.48-7.48"/><path d="M15 6h1v4"/><path d="m6.134 14.768.866-.5 2 3.464"/><circle cx="16" cy="8" r="6"/>`,
	"Banknote":        `<rect width="20" height="12" x="2" y="6" rx="2"/><circle cx="12" cy="12" r="2"/><path d="M6 12h.01M18 12h.01"/>`,
	"Calculator":      `<rect width="16" height="20" x="4" y="2" rx="2"/><line x1="8" x2="16" y1="6" y2="6"/><line x1="16" x2="16" y1="14" y2="18"/><path d="M16 10h.01"/><path d="M12 10h.01"/><path d="M8 10h.01"/><path d="M12 14h.01"/><path d="M8 14h.01"/><path d="M12 18h.01"/><path d="M8 18h.01"/>`,
	"ChartBar":        `<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>`,
	"ChartLine":       `<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="m19 9-5 5-4-4-3 3"/>`,
	"ChartPie":        `<path d="M21 12c.552 0 1.005-.449.95-.998a10 10 0 0 0-8.953-8.951c-.55-.055-.998.398-.998.95v8a1 1 0 0 0 1 1z"/><path d="M21.21 15.89A10 10 0 1 1 8 2.83"/>`,
	"TrendingUp":      `<path d="M16 7h6v6"/><path d="m22 7-8.5 8.5-5-5L2 17"/>`,
	"TrendingDown":    `<path d="M16 17h6v-6"/><path d="m22 17-8.5-8.5-5 5L2 7"/>`,
	"Gauge":           `<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>`,
	"Target":          `<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>`,
	"Map":             `<path d="M14.106 5.553a2 2 0 0 0 1.788 0l3.659-1.83A1 1 0 0 1 21 4.619v12.764a1 1 0 0 1-.553.894l-4.553 2.277a2 2 0 0 1-1.788 0l-4.212-2.106a2 2 0 0 0-1.788 0l-3.659 1.83A1 1 0 0 1 3 19.381V6.618a1 1 0 0 1 .553-.894l4.553-2.277a2 2 0 0 1 1.788 0z"/><path d="M15 5.764v15"/><path d="M9 3.236v15"/>`,
	"MapPin":          `<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>`,
	"Navigation":      `<polygon points="3 11 22 2 13 21 11 13 3 11"/>`,
	"Compass":         `<circle cx="12" cy="12" r="10"/><path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z"/>`,
	"Globe":           `<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>`,
	"Building":        `<path d="M10 12h4"/><path d="M10 8h4"/><path d="M14 21v-3a2 2 0 0 0-4 0v3"/><path d="M6 10H4a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-2"/><path d="M6 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16"/>`,
	"Factory":         `<path d="M12 16h.01"/><path d="M16 16h.01"/><path d="M3 19a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V8.5a.5.5 0 0 0-.769-.422l-4.462 2.844A.5.5 0 0 1 15 10.5v-2a.5.5 0 0 0-.769-.422L9.77 10.922A.5.5 0 0 1 9 10.5V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2z"/><path d="M8 16h.01"/>`,
	"School":          `<path d="M14 21v-3a2 2 0 0 0-4 0v3"/><path d="M18 4.933V21"/><path d="m4 6 7.106-3.79a2 2 0 0 1 1.788 0L20 6"/><path d="m6 11-3.52 2.147a1 1 0 0 0-.48.854V19a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5a1 1 0 0 0-.48-.853L18 11"/><path d="M6 4.933V21"/><circle cx="12" cy="9" r="2"/>`,
	"Hospital":        `<path d="M12 7v4"/><path d="M14 21v-3a2 2 0 0 0-4 0v3"/><path d="M14 9h-4"/><path d="M18 11h2a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2h2"/><path d="M18 21V5a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16"/>`,
	"Car":             `<path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="17" r="2"/><path d="M9 17h6"/><circle cx="17" cy="17" r="2"/>`,
	"Bus":             `<path d="M8 6v6"/><path d="M15 6v6"/><path d="M2 12h19.6"/><path d="M18 18h3s.5-1.7.8-2.8c.1-.4.2-.8.2-1.2 0-.4-.1-.8-.2-1.2l-1.4-5C20.1 6.8 19.1 6 18 6H4a2 2 0 0 0-2 2v10h3"/><circle cx="7" cy="18" r="2"/><path d="M9 18h5"/><circle cx="16" cy="18" r="2"/>`,
	"Train":           `<path d="M8 3.1V7a4 4 0 0 0 8 0V3.1"/><path d="m9 15-1-1"/><path d="m15 15 1-1"/><path d="M9 19c-2.8 0-5-2.2-5-5v-4a8 8 0 0 1 16 0v4c0 2.8-2.2 5-5 5Z"/><path d="m8 19-2 3"/><path d="m16 19 2 3"/>`,
	"Plane":           `<path d="M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z"/>`,
	"Ship":            `<path d="M12 2v2"/><path d="M12 9.189V13"/><path d="M19 12V6a2 2 0 00-2-2H7a2 2 0 00-2 2v6"/><path d="M19.38 19A11.6 11.6 0 0021 13l-8.188-3.639a2 2 0 00-1.624 0L3 13.001a11.6 11.6 0 002.81 7.76"/><path d="M2 20c.6.5 1.2 1 2.5 1 2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1s1.2 1 2.5 1c2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1"/>`,
	"Bike":            `<circle cx="18.5" cy="17.5" r="3.5"/><circle cx="5.5" cy="17.5" r="3.5"/><circle cx="15" cy="5" r="1"/><path d="M12 17.5V14l-3-3 4-3 2 3h2"/>`,
	"Rocket":          `<path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/><path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09"/><path d="M9 12a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.4 22.4 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 .05 5 .05"/>`,
	"Fuel":            `<path d="M14 13h2a2 2 0 0 1 2 2v2a2 2 0 0 0 4 0v-6.998a2 2 0 0 0-.59-1.42L18 5"/><path d="M14 21V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v16"/><path d="M2 21h13"/><path d="M3 9h11"/>`,
	"Footprints":      `<path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z"/><path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z"/><path d="M16 17h4"/><path d="M4 13h4"/>`,
	"Sun":             `<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>`,
	"Moon":            `<path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/>`,
	"Sunrise":         `<path d="M12 2v8"/><path d="m4.93 10.93 1.41 1.41"/><path d="M2 18h2"/><path d="M20 18h2"/><path d="m19.07 10.93-1.41 1.41"/><path d="M22 22H2"/><path d="m8 6 4-4 4 4"/><path d="M16 18a4 4 0 0 0-8 0"/>`,
	"Sunset":          `<path d="M12 10V2"/><path d="m4.93 10.93 1.41 1.41"/><path d="M2 18h2"/><path d="M20 18h2"/><path d="m19.07 10.93-1.41 1.41"/><path d="M22 22H2"/><path d="m16 6-4 4-4-4"/><path d="M16 18a4 4 0 0 0-8 0"/>`,
	"CloudRain":       `<path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242"/><path d="M16 14v6"/><path d="M8 14v6"/><path d="M12 16v6"/>`,
	"Snowflake":       `<path d="m10 20-1.25-2.5L6 18"/><path d="M10 4 8.75 6.5 6 6"/><path d="m14 20 1.25-2.5L18 18"/><path d="m14 4 1.25 2.5L18 6"/><path d="m17 21-3-6h-4"/><path d="m17 3-3 6 1.5 3"/><path d="M2 12h6.5L10 9"/><path d="m20 10-1.5 2 1.5 2"/><path d="M22 12h-6.5L14 15"/><path d="m4 10 1.5 2L4 14"/><path d="m7 21 3-6-1.5-3"/><path d="m7 3 3 6h4"/>`,
	"Wind":            `<path d="M12.8 19.6A2 2 0 1 0 14 16H2"/><path d="M17.5 8a2.5 2.5 0 1 1 2 4H2"/><path d="M9.8 4.4A2 2 0 1 1 11 8H2"/>`,
	"Umbrella":        `<path d="M12 13v7a2 2 0 0 0 4 0"/><path d="M12 2v2"/><path d="M20.992 13a1 1 0 0 0 .97-1.274 10.284 10.284 0 0 0-19.923 0A1 1 0 0 0 3 13z"/>`,
	"Thermometer":     `<path d="M14 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z"/>`,
	"Droplet":         `<path d="M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5s-3.5-4-4-6.5c-.5 2.5-2 4.9-4 6.5C6 11.1 5 13 5 15a7 7 0 0 0 7 7z"/>`,
	"Leaf":            `<path d="M11 20a10 10 0 0010-10 25.9 25.9 0 00-1.04-7.281 1 1 0 00-1.755-.325C15.833 5.5 13 5.5 9.8 6.1A7 7 0 0011 20"/><path d="M2 21a5 5 0 012.911-4.544C7.613 15.212 8.351 15.24 11 13"/>`,
	"Flower":          `<circle cx="12" cy="12" r="3"/><path d="M12 16.5A4.5 4.5 0 1 1 7.5 12 4.5 4.5 0 1 1 12 7.5a4.5 4.5 0 1 1 4.5 4.5 4.5 4.5 0 1 1-4.5 4.5"/><path d="M12 7.5V9"/><path d="M7.5 12H9"/><path d="M16.5 12H15"/><path d="M12 16.5V15"/><path d="m8 8 1.88 1.88"/><path d="M14.12 9.88 16 8"/><path d="m8 16 1.88-1.88"/><path d="M14.12 14.12 16 16"/>`,
	"Tree":            `<path d="m17 14 3 3.3a1 1 0 0 1-.7 1.7H4.7a1 1 0 0 1-.7-1.7L7 14h-.3a1 1 0 0 1-.7-1.7L9 9h-.2A1 1 0 0 1 8 7.3L12 3l4 4.3a1 1 0 0 1-.8 1.7H15l3 3.3a1 1 0 0 1-.7 1.7H17Z"/><path d="M12 22v-3"/>`,
	"Mountain":        `<path d="m8 3 4 8 5-5 5 15H2L8 3z"/>`,
	"Waves":           `<path d="M2 12q2.5 2 5 0t5 0 5 0 5 0"/><path d="M2 19q2.5 2 5 0t5 0 5 0 5 0"/><path d="M2 5q2.5 2 5 0t5 0 5 0 5 0"/>`,
	"Bold":            `<path d="M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8"/>`,
	"Italic":          `<line x1="19" x2="10" y1="4" y2="4"/><line x1="14" x2="5" y1="20" y2="20"/><line x1="15" x2="9" y1="4" y2="20"/>`,
	"Underline":       `<path d="M6 4v6a6 6 0 0 0 12 0V4"/><line x1="4" x2="20" y1="20" y2="20"/>`,
	"Strikethrough":   `<path d="M16 4H9a3 3 0 0 0-2.83 4"/><path d="M14 12a4 4 0 0 1 0 8H6"/><line x1="4" x2="20" y1="12" y2="12"/>`,
	"Heading":         `<path d="M6 12h12"/><path d="M6 20V4"/><path d="M18 20V4"/>`,
	"Quote":           `<path d="M16 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z"/><path d="M5 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z"/>`,
	"AlignLeft":       `<path d="M21 5H3"/><path d="M15 12H3"/><path d="M17 19H3"/>`,
	"AlignCenter":     `<path d="M21 5H3"/><path d="M17 12H7"/><path d="M19 19H5"/>`,
	"AlignRight":      `<path d="M21 5H3"/><path d="M21 12H9"/><path d="M21 19H7"/>`,
	"AlignJustify":    `<path d="M3 5h18"/><path d="M3 12h18"/><path d="M3 19h18"/>`,
	"Hash":            `<line x1="4" x2="20" y1="9" y2="9"/><line x1="4" x2="20" y1="15" y2="15"/><line x1="10" x2="8" y1="3" y2="21"/><line x1="16" x2="14" y1="3" y2="21"/>`,
	"At":              `<circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/>`,
	"Asterisk":        `<path d="M12 5v14"/><path d="m18.065 8.496-12.125 7"/><path d="m5.94 8.504 12.125 7"/>`,
	"Circle":          `<circle cx="12" cy="12" r="10"/>`,
	"Triangle":        `<path d="M13.73 4a2 2 0 0 0-3.46 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/>`,
	"Hexagon":         `<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>`,
	"Diamond":         `<path d="M2.7 10.3a2.41 2.41 0 0 0 0 3.41l7.59 7.59a2.41 2.41 0 0 0 3.41 0l7.59-7.59a2.41 2.41 0 0 0 0-3.41l-7.59-7.59a2.41 2.41 0 0 0-3.41 0Z"/>`,
	"Sparkles":        `<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/><path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>`,
	"Wand":            `<path d="m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72"/><path d="m14 7 3 3"/><path d="M5 6v4"/><path d="M19 14v4"/><path d="M10 2v2"/><path d="M7 8H3"/><path d="M21 16h-4"/><path d="M11 3H9"/>`,
	"Palette":         `<path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"/><circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/>`,
	"Brush":           `<path d="m11 10 3 3"/><path d="M6.5 21A3.5 3.5 0 1 0 3 17.5a2.62 2.62 0 0 1-.708 1.792A1 1 0 0 0 3 21z"/><path d="M9.969 17.031 21.378 5.624a1 1 0 0 0-3.002-3.002L6.967 14.031"/>`,
	"PenTool":         `<path d="m18 13-.654-4.736a4 4 0 00-2.756-3.266l-9.163-2.9a2 2 0 00-2.017.493l-.82.819a2 2 0 00-.492 2.017l2.9 9.163a4 4 0 003.266 2.756L13 18"/><path d="M18.648 12.352a1.205 1.205 0 011.704 0l1.296 1.296a1.205 1.205 0 010 1.704l-6.296 6.296a1.205 1.205 0 01-1.704 0l-1.296-1.296a1.205 1.205 0 010-1.704z"/><path d="m3 3 6.586 6.586"/><circle cx="11" cy="11" r="2"/>`,
	"Crop":            `<path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/>`,
	"Ruler":           `<path d="M21.3 15.3a2.4 2.4 0 0 1 0 3.4l-2.6 2.6a2.4 2.4 0 0 1-3.4 0L2.7 8.7a2.41 2.41 0 0 1 0-3.4l2.6-2.6a2.41 2.41 0 0 1 3.4 0Z"/><path d="m14.5 12.5 2-2"/><path d="m11.5 9.5 2-2"/><path d="m8.5 6.5 2-2"/><path d="m17.5 15.5 2-2"/>`,
	"Pipette":         `<path d="m12 9-8.414 8.414A2 2 0 0 0 3 18.828v1.344a2 2 0 0 1-.586 1.414A2 2 0 0 1 3.828 21h1.344a2 2 0 0 0 1.414-.586L15 12"/><path d="m18 9 .4.4a1 1 0 1 1-3 3l-3.8-3.8a1 1 0 1 1 3-3l.4.4 3.4-3.4a1 1 0 1 1 3 3z"/><path d="m2 22 .414-.414"/>`,
	"Eraser":          `<path d="M21 21H8a2 2 0 0 1-1.42-.587l-3.994-3.999a2 2 0 0 1 0-2.828l10-10a2 2 0 0 1 2.829 0l5.999 6a2 2 0 0 1 0 2.828L12.834 21"/><path d="m5.082 11.09 8.828 8.828"/>`,
	"Shapes":          `<path d="M8.3 10a.7.7 0 0 1-.626-1.079L11.4 3a.7.7 0 0 1 1.198-.043L16.3 8.9a.7.7 0 0 1-.572 1.1Z"/><rect x="3" y="14" width="7" height="7" rx="1"/><circle cx="17.5" cy="17.5" r="3.5"/>`,
	"Puzzle":          `<path d="M15.39 4.39a1 1 0 0 0 1.68-.474 2.5 2.5 0 1 1 3.014 3.015 1 1 0 0 0-.474 1.68l1.683 1.682a2.414 2.414 0 0 1 0 3.414L19.61 15.39a1 1 0 0 1-1.68-.474 2.5 2.5 0 1 0-3.014 3.015 1 1 0 0 1 .474 1.68l-1.683 1.682a2.414 2.414 0 0 1-3.414 0L8.61 19.61a1 1 0 0 0-1.68.474 2.5 2.5 0 1 1-3.014-3.015 1 1 0 0 0 .474-1.68l-1.683-1.682a2.414 2.414 0 0 1 0-3.414L4.39 8.61a1 1 0 0 1 1.68.474 2.5 2.5 0 1 0 3.014-3.015 1 1 0 0 1-.474-1.68l1.683-1.682a2.414 2.414 0 0 1 3.414 0z"/>`,
	"Lightbulb":       `<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>`,
	"Book":            `<path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20"/>`,
	"BookOpen":        `<path d="M12 5v16"/><path d="M20.001 19A2 2 0 0022 17V5a2 2 0 00-1.999-2L16 3.002A5 5 0 0012 5a5 5 0 00-4-2H4a2 2 0 00-2 2v12a2 2 0 001.999 2H8a5 5 0 014 2 5 5 0 014-2z"/>`,
	"Newspaper":       `<path d="M15 18h-5"/><path d="M18 14h-8"/><path d="M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-4 0v-9a2 2 0 0 1 2-2h2"/><rect width="8" height="4" x="10" y="6" rx="1"/>`,
	"GraduationCap":   `<path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/>`,
	"Briefcase":       `<path d="M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/><rect width="20" height="14" x="2" y="6" rx="2"/>`,
	"CheckSquare":     `<rect width="18" height="18" x="3" y="3" rx="2"/><path d="m16 9-5.5 5.5L8 12"/>`,
	"ToggleLeft":      `<circle cx="9" cy="12" r="3"/><rect width="20" height="14" x="2" y="5" rx="7"/>`,
	"ToggleRight":     `<circle cx="15" cy="12" r="3"/><rect width="20" height="14" x="2" y="5" rx="7"/>`,
	"Infinity":        `<path d="M6 16c5 0 7-8 12-8a4 4 0 0 1 0 8c-5 0-7-8-12-8a4 4 0 1 0 0 8"/>`,
	"Sigma":           `<path d="M18 7V5a1 1 0 0 0-1-1H6.5a.5.5 0 0 0-.4.8l4.5 6a2 2 0 0 1 0 2.4l-4.5 6a.5.5 0 0 0 .4.8H17a1 1 0 0 0 1-1v-2"/>`,
	"Crosshair":       `<circle cx="12" cy="12" r="10"/><line x1="22" x2="18" y1="12" y2="12"/><line x1="6" x2="2" y1="12" y2="12"/><line x1="12" x2="12" y1="6" y2="2"/><line x1="12" x2="12" y1="22" y2="18"/>`,
	"Focus":           `<circle cx="12" cy="12" r="3"/><path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>`,
	"Aperture":        `<circle cx="12" cy="12" r="10"/><path d="m14.31 8 5.74 9.94"/><path d="M9.69 8h11.48"/><path d="m7.38 12 5.74-9.94"/><path d="M9.69 16 3.95 6.06"/><path d="M14.31 16H2.83"/><path d="m16.62 12-5.74 9.94"/>`,
	"Feather":         `<path d="M14.086 18.412A2 2 0 0112.67 19H5v-7.672a2 2 0 01.586-1.414L11.75 3.75a6 6 0 118.49 8.49z"/><path d="M16 8 2 22"/><path d="M17.488 15H9"/>`,
	"Ghost":           `<path d="M15 10v1"/><path d="M7.528 20.472a1.6 1.6 0 012.277 0l1.057 1.056a1.6 1.6 0 002.276 0l1.057-1.056a1.6 1.6 0 012.277 0l1.114 1.114a1.4 1.4 0 002.414-1V10a8 8 0 00-16 0v10.586a1.4 1.4 0 002.414 1z"/><path d="M9 10v1"/>`,
	"Dice":            `<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><path d="M16 8h.01"/><path d="M8 8h.01"/><path d="M8 16h.01"/><path d="M16 16h.01"/><path d="M12 12h.01"/>`,
	"Megaphone":       `<path d="M11 6a13 13 0 0 0 8.4-2.8A1 1 0 0 1 21 4v12a1 1 0 0 1-1.6.8A13 13 0 0 0 11 14H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2z"/><path d="M6 14a12 12 0 0 0 2.4 7.2 2 2 0 0 0 3.2-2.4A8 8 0 0 1 10 14"/><path d="M8 6v8"/>`,
	"Coffee":          `<path d="M10 2v2"/><path d="M14 2v2"/><path d="M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1h14a4 4 0 1 1 0 8h-1"/><path d="M6 2v2"/>`,
	"Pizza":           `<path d="m12 14-1 1"/><path d="m13.75 18.25-1.25 1.42"/><path d="M17.775 5.654a15.68 15.68 0 0 0-12.121 12.12"/><path d="M18.8 9.3a1 1 0 0 0 2.1 7.7"/><path d="M21.964 20.732a1 1 0 0 1-1.232 1.232l-18-5a1 1 0 0 1-.695-1.232A19.68 19.68 0 0 1 15.732 2.037a1 1 0 0 1 1.232.695z"/>`,
	"Utensils":        `<path d="M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2"/><path d="M7 2v20"/><path d="M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7"/>`,
	"Wine":            `<path d="M8 22h8"/><path d="M7 10h10"/><path d="M12 15v7"/><path d="M12 15a5 5 0 0 0 5-5c0-2-.5-4-2-8H9c-1.5 4-2 6-2 8a5 5 0 0 0 5 5Z"/>`,
	"Apple":           `<path d="M12 6.528V3a1 1 0 0 1 1-1h0"/><path d="M18.237 21A15 15 0 0 0 22 11a6 6 0 0 0-10-4.472A6 6 0 0 0 2 11a15.1 15.1 0 0 0 3.763 10 3 3 0 0 0 3.648.648 5.5 5.5 0 0 1 5.178 0A3 3 0 0 0 18.237 21"/>`,
	"Shirt":           `<path d="M20.38 3.46 16 2a4 4 0 0 1-8 0L3.62 3.46a2 2 0 0 0-1.34 2.23l.58 3.47a1 1 0 0 0 .99.84H6v10c0 1.1.9 2 2 2h8a2 2 0 0 0 2-2V10h2.15a1 1 0 0 0 .99-.84l.58-3.47a2 2 0 0 0-1.34-2.23z"/>`,
	"Glasses":         `<circle cx="6" cy="15" r="4"/><circle cx="18" cy="15" r="4"/><path d="M14 15a2 2 0 0 0-2-2 2 2 0 0 0-2 2"/><path d="M2.5 13 5 7c.7-1.3 1.4-2 3-2"/><path d="M21.5 13 19 7c-.7-1.3-1.5-2-3-2"/>`,
	"Dog":             `<path d="M11.25 16.25h1.5L12 17z"/><path d="M16 14v.5"/><path d="M4.42 11.247A13.152 13.152 0 0 0 4 14.556C4 18.728 7.582 21 12 21s8-2.272 8-6.444a11.702 11.702 0 0 0-.493-3.309"/><path d="M8 14v.5"/><path d="M8.5 8.5c-.384 1.05-1.083 2.028-2.344 2.5-1.931.722-3.576-.297-3.656-1-.113-.994 1.177-6.53 4-7 1.923-.321 3.651.845 3.651 2.235A7.497 7.497 0 0 1 14 5.277c0-1.39 1.844-2.598 3.767-2.277 2.823.47 4.113 6.006 4 7-.08.703-1.725 1.722-3.656 1-1.261-.472-1.855-1.45-2.239-2.5"/>`,
	"Cat":             `<path d="M12 5c.67 0 1.35.09 2 .26 1.78-2 5.03-2.84 6.42-2.26 1.4.58-.42 7-.42 7 .57 1.07 1 2.24 1 3.44C21 17.9 16.97 21 12 21s-9-3-9-7.56c0-1.25.5-2.4 1-3.44 0 0-1.89-6.42-.5-7 1.39-.58 4.72.23 6.5 2.23A9.04 9.04 0 0 1 12 5Z"/><path d="M8 14v.5"/><path d="M16 14v.5"/><path d="M11.25 16.25h1.5L12 17l-.75-.75Z"/>`,
	"Bird":            `<path d="M16 7h.01"/><path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/><path d="m20 7 2 .5-2 .5"/><path d="M10 18v3"/><path d="M14 17.75V21"/><path d="M7 18a6 6 0 0 0 3.84-10.61"/>`,
	"Fish":            `<path d="M6.5 12c.94-3.46 4.94-6 8.5-6 3.56 0 6.06 2.54 7 6-.94 3.47-3.44 6-7 6s-7.56-2.53-8.5-6Z"/><path d="M18 12v.5"/><path d="M16 17.93a9.77 9.77 0 0 1 0-11.86"/><path d="M7 10.67C7 8 5.58 5.97 2.73 5.5c-1 1.5-1 5 .23 6.5-1.24 1.5-1.24 5-.23 6.5C5.58 18.03 7 16 7 13.33"/><path d="M10.46 7.26C10.2 5.88 9.17 4.24 8 3h5.8a2 2 0 0 1 1.98 1.67l.23 1.4"/><path d="m16.01 17.93-.23 1.4A2 2 0 0 1 13.8 21H9.5a5.96 5.96 0 0 0 1.49-3.98"/>`,
}
