package hive

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"math"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// Every letter half as wide as the type is tall, so what a layout comes to can be
// worked out by hand.
type uiFake struct{ copied string }

func (d *uiFake) measure(f uiFont, s string) float64 { return float64(utf8.RuneCountInString(s)) * f.px / 2 }
func (d *uiFake) tall(f uiFont) float64                 { return f.px * 1.25 }
func (d *uiFake) average(f uiFont) float64              { return f.px / 2 }
func (d *uiFake) text(uiFont, int, int, string, uiRGBA, uiClip) {}
func (d *uiFake) clipboard() string                     { return d.copied }
func (d *uiFake) setClipboard(s string)                 { d.copied = s }
func (d *uiFake) openLink(string)                       {}
func (d *uiFake) datePattern() string                   { return "dd/MM/yyyy" }

// A window with a mailbox of its own, which nothing reads but the test.
func uiLaidOut(v UiView, w, h float64) (*uiNative, *mailbox) {
	n := uiNewNative()
	n.dev = &uiFake{}
	box := newMailbox(nil, 0)
	n.addr = SyslinkAddress{Name: atomNone, Id: box.id, box: box}
	n.resize(w, h, 1)
	uiShowAgain(n, v)
	return n, box
}

func uiShowAgain(n *uiNative, v UiView) {
	n.publish(v)
	n.adopt()
	n.layout()
}

func uiClick(n *uiNative, x, y float64) {
	n.move(x, y)
	n.down(x, y)
	n.up(x, y)
}

// Everything posted so far, in order, and nothing twice.
func uiPosted(box *mailbox) string {
	box.mu.Lock()
	defer box.mu.Unlock()
	var out []string
	for _, d := range box.queue {
		out = append(out, fmt.Sprint(d.value))
	}
	box.queue = nil
	return strings.Join(out, ",")
}

func uiSaid(s string) any { return s }

func uiNear(a, b float64) bool { return math.Abs(a-b) < 0.01 }

func TestASpacerTakesWhatTheRowLeaves(t *testing.T) {
	n, _ := uiLaidOut(UiRow(nil, []UiView{UiText(nil, "abcd"), UiSpacer(), UiButton(nil, "Go")}), 400, 300)
	button := n.boxes["r/0/2"]
	if !uiNear(button.w, 44) || !uiNear(button.x, 356) {
		t.Errorf("the button is %.2f wide at %.2f, wanted 44 at 356", button.w, button.x)
	}
}

func TestATableSharesItsWidthByWhatEachColumnHolds(t *testing.T) {
	rows := Table{{"Name", "City"}, {"Ana", "Recife"}, {"Bo", "Porto Alegre do Norte"}}
	n, _ := uiLaidOut(UiColumn([]UiAttr{UiAttrWidth(300)}, []UiView{UiTable(nil, rows)}), 800, 600)
	g := n.boxes["r/0/0"].grid
	if !uiNear(g.cols[0]+g.cols[1], 300) || !uiNear(g.cols[0], 48+85*48.0/215) {
		t.Errorf("columns %v, wanted the 85 left over shared as 48 to 167", g.cols)
	}
	n, _ = uiLaidOut(UiColumn([]UiAttr{UiAttrWidth(100)}, []UiView{UiTable(nil, rows)}), 800, 600)
	g = n.boxes["r/0/0"].grid
	if !uiNear(g.cols[0], 27+21*46.0/161) {
		t.Errorf("columns %v, wanted each between its least and its most", g.cols)
	}
	if lines := len(g.wrapped[2][1]); lines < 2 || !uiNear(g.heights[2], float64(lines)*21+17) {
		t.Errorf("a long cell wrapped to %d lines and a row %.2f tall", lines, g.heights[2])
	}
}

func TestATableReportsTheRowAndTheColumn(t *testing.T) {
	rows := Table{{"Name", "City"}, {"Ana", "Recife"}, {"Bo", "Olinda"}}
	pick := UiAttrOnPick(func(i int) any { return fmt.Sprint("row ", i) })
	sort := UiAttrOnSort(func(i int) any { return fmt.Sprint("column ", i) })
	n, box := uiLaidOut(UiTable([]UiAttr{pick, sort}, rows), 400, 300)
	g := n.boxes["r/0"].grid
	uiClick(n, g.cols[0]+5, 5)
	uiClick(n, 5, g.heights[0]+g.heights[1]+5)
	if got := uiPosted(box); got != "column 1,row 1" {
		t.Errorf("heard %s", got)
	}
}

func TestAnImageKeepsItsShape(t *testing.T) {
	n := uiNewNative()
	n.dev = &uiFake{}
	n.resize(400, 300, 1)
	n.pics["p"] = &uiPicture{done: true, w: 64, h: 40, pix: make([]uint8, 64*40*4)}
	n.pics["gone"] = &uiPicture{done: true}
	uiShowAgain(n, UiColumn(nil, []UiView{
		UiImage(nil, "p", ""),
		UiImage([]UiAttr{UiAttrWidth(96)}, "p", ""),
		UiImage(nil, "gone", "x"),
	}))
	for path, want := range map[string][2]float64{"r/0/0": {400, 250}, "r/0/1": {96, 60}, "r/0/2": {400, 21}} {
		if b := n.boxes[path]; !uiNear(b.w, want[0]) || !uiNear(b.h, want[1]) {
			t.Errorf("%s is %.2f by %.2f, wanted %.0f by %.0f", path, b.w, b.h, want[0], want[1])
		}
	}
}

func TestADialogIsCentredAndItsBackdropDismissesIt(t *testing.T) {
	v := UiColumn(nil, []UiView{
		UiText(nil, "under"),
		UiOverlay([]UiAttr{UiAttrOnDismiss("dismissed")}, UiText(nil, "hi")),
	})
	n, box := uiLaidOut(v, 400, 300)
	if len(n.layers) != 1 {
		t.Fatalf("%d layers, wanted the one", len(n.layers))
	}
	p := n.layers[0].panel
	if !uiNear(p.x, 193) || !uiNear(p.y, 139.5) || !uiNear(p.w, 14) {
		t.Errorf("the panel is %.2f wide at %.2f, %.2f", p.w, p.x, p.y)
	}
	uiClick(n, 195, 145)
	if got := uiPosted(box); got != "" {
		t.Errorf("a click inside the dialog said %s", got)
	}
	uiClick(n, 10, 10)
	if got := uiPosted(box); got != "dismissed" {
		t.Errorf("a click on the backdrop said %q", got)
	}
}

func TestAPinnedPanelLetsClicksThroughAroundIt(t *testing.T) {
	v := UiColumn(nil, []UiView{
		UiButton([]UiAttr{UiAttrOn("under")}, "under"),
		UiOverlay([]UiAttr{UiAttrAlign("End"), UiAttrJustify("End")}, UiButton([]UiAttr{UiAttrOn("over")}, "x")),
	})
	n, box := uiLaidOut(v, 400, 300)
	p := n.layers[0].panel
	if !uiNear(p.x, 351) || !uiNear(p.y, 253) {
		t.Errorf("the panel is at %.2f, %.2f, wanted its corner 12px in from the window's", p.x, p.y)
	}
	uiClick(n, 5, 5)
	uiClick(n, 360, 260)
	if got := uiPosted(box); got != "under,over" {
		t.Errorf("heard %s", got)
	}
}

func TestATextareaMovesALineAtATimeAsItWraps(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{UiTextarea([]UiAttr{UiAttrWidth(100)}, "aaa bbb ccc ddd")}), 400, 300)
	b := n.boxes["r/0/0"]
	n.tab(false)
	f := n.fields[b.path]
	if spans := n.flow(b, f); len(spans) != 2 || spans[1] != (uiSpan{12, 15}) {
		t.Fatalf("wrapped as %v", spans)
	}
	f.caret, f.anchor = 5, 5
	n.key(uiKeyDown, false, false)
	if f.caret != 15 {
		t.Errorf("down went to %d, wanted the end of the short line", f.caret)
	}
	n.key(uiKeyUp, false, false)
	if f.caret != 5 {
		t.Errorf("up went to %d, wanted back to the column it left", f.caret)
	}
	n.key(uiKeyEnter, false, false)
	if string(f.text) != "aaa b\nbb ccc ddd" {
		t.Errorf("enter made %q", string(f.text))
	}
}

func TestANumberFieldReportsOnlyNumbers(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrKind("Number"), UiAttrOnInput(uiSaid)}, ""), 400, 300)
	n.tab(false)
	n.typed('1')
	n.typed('x')
	n.typed('e')
	n.key(uiKeyBack, false, false)
	n.key(uiKeyUp, false, false)
	if got := uiPosted(box); got != "1,,1,2" {
		t.Errorf("heard %s", got)
	}
	for text, valid := range map[string]bool{"1": true, "-2.5e3": true, ".5": true, "1.": false, "e3": false, "": false, "+1": false} {
		if uiValidNumber(text) != valid {
			t.Errorf("%q valid: wanted %v", text, valid)
		}
	}
}

func TestADateIsTypedASegmentAtATime(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrKind("Date"), UiAttrOnInput(uiSaid)}, ""), 400, 300)
	n.tab(false)
	for _, r := range "30092026" {
		n.typed(r)
	}
	n.key(uiKeyBack, false, false)
	n.key(uiKeyLeft, false, false)
	n.key(uiKeyUp, false, false)
	// A year is a value from its first digit, as Chrome reports it.
	if got := uiPosted(box); !strings.HasSuffix(got, "0202-09-30,2026-09-30,") {
		t.Errorf("heard %s", got)
	}
	if d := n.dates["r/0"]; d.parts != [3]int{0, 10, 30} {
		t.Errorf("the date holds %v", d.parts)
	}
}

func TestAClosedSelectChoosesWithTheArrowsAndItsLetters(t *testing.T) {
	n, box := uiLaidOut(UiSelect([]UiAttr{UiAttrOnChoose(uiSaid)}, []string{"a", "b", "c"}, "a"), 400, 300)
	n.tab(false)
	n.key(uiKeyDown, false, false)
	n.key(uiKeyDown, false, false)
	n.key(uiKeyDown, false, false)
	n.typed('a')
	if got := uiPosted(box); got != "b,c,a" {
		t.Errorf("heard %s", got)
	}
}

func TestACheckboxShowsItsTickUntilTheProgramDrawsAgain(t *testing.T) {
	v := UiCheckbox([]UiAttr{UiAttrOnToggle(func(on bool) any { return on })}, "done", false)
	n, box := uiLaidOut(v, 400, 300)
	b := n.boxes["r/0"]
	uiClick(n, b.x+5, b.y+5)
	if got := uiPosted(box); got != "true" || !n.checked(n.boxes["r/0"]) {
		t.Errorf("heard %s", got)
	}
	uiShowAgain(n, v)
	if n.checked(n.boxes["r/0"]) {
		t.Errorf("still ticked after a view that says it is not")
	}
}

func TestASliderFollowsTheKeys(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrKind("Range"), UiAttrOnInput(uiSaid)}, "30"), 400, 300)
	n.tab(false)
	n.key(uiKeyEnd, false, false)
	n.key(uiKeyLeft, false, false)
	n.key(uiKeyPageDown, false, false)
	if got := uiPosted(box); got != "100,99,89" {
		t.Errorf("heard %s", got)
	}
}

func TestTabSkipsWhatIsDisabled(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{
		UiButton([]UiAttr{UiAttrDisabled(true)}, "no"),
		UiInput(nil, ""),
		UiButton(nil, "yes"),
	}), 400, 300)
	n.tab(false)
	first := n.focus
	n.tab(false)
	if first != "r/0/1" || n.focus != "r/0/2" {
		t.Errorf("tab went to %s then %s", first, n.focus)
	}
}

func TestARasterCoversWhatIsInsideAndHalfOfAnEdge(t *testing.T) {
	var r uiRaster
	cover := func(pts []float64, x, y int) uint8 {
		r.reset(10, 10)
		r.polygon(pts)
		return r.mask(nil)[y*10+x]
	}
	cases := []struct {
		pts  []float64
		x, y int
		want uint8
	}{
		{[]float64{2, 2, 6, 2, 6, 6, 2, 6}, 3, 3, 255},
		{[]float64{2, 2, 6, 2, 6, 6, 2, 6}, 7, 7, 0},
		{[]float64{2.5, 2, 6, 2, 6, 6, 2.5, 6}, 2, 3, 128},
		{[]float64{-5, 2, 6, 2, 6, 6, -5, 6}, 0, 3, 255},
		{[]float64{2, 2, 50, 2, 50, 6, 2, 6}, 9, 3, 255},
	}
	for _, c := range cases {
		if got := cover(c.pts, c.x, c.y); got != c.want {
			t.Errorf("%v at %d,%d covers %d, wanted %d", c.pts, c.x, c.y, got, c.want)
		}
	}
	r.reset(12, 12)
	for _, p := range uiStroke([]float64{2, 2, 8, 8, 2, 8}, 1) {
		r.polygon(p)
	}
	if m := r.mask(nil); m[7*12+7] != 255 || m[5*12+5] != 255 {
		t.Errorf("a stroke's join and its middle cover %d and %d", m[7*12+7], m[5*12+5])
	}
}

func TestDraggingOverTextSelectsItAndCopyTakesIt(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{UiText(nil, "hello world"), UiText(nil, "again")}), 400, 300)
	n.down(0, 5)
	n.move(35, 5)
	n.up(35, 5)
	if got := n.selectedText(); got != "hello" {
		t.Errorf("dragging selected %q", got)
	}
	n.key(uiKeyAll, false, true)
	n.key(uiKeyCopy, false, true)
	if got := n.dev.clipboard(); got != "hello world\nagain" {
		t.Errorf("copied %q", got)
	}
	uiClick(n, 60, 5)
	uiClick(n, 60, 5)
	if got := n.selectedText(); got != "world" {
		t.Errorf("a double click selected %q", got)
	}
}

func TestAFieldUndoesARunOfTypingAtOnce(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrOnInput(uiSaid)}, ""), 400, 300)
	n.tab(false)
	for _, r := range "ab cd" {
		n.typed(r)
	}
	f := n.fields["r/0"]
	n.key(uiKeyUndo, false, true)
	n.key(uiKeyUndo, false, true)
	after := string(f.text)
	n.key(uiKeyRedo, false, true)
	if after != "ab" || string(f.text) != "ab " {
		t.Errorf("undone to %q, redone to %q", after, string(f.text))
	}
	if got := uiPosted(box); !strings.HasSuffix(got, "ab cd,ab ,ab,ab ") {
		t.Errorf("heard %s", got)
	}
}

func TestAFieldsMenuActsOnIt(t *testing.T) {
	n, _ := uiLaidOut(UiInput(nil, "one two"), 400, 300)
	b := n.boxes["r/0"]
	n.menu(b.x+15, b.y+10)
	if n.popup == nil || n.popup.kind != "menu" {
		t.Fatalf("no menu opened")
	}
	for i, it := range n.menuItems {
		if it.label == "Select all" {
			n.runMenu(i)
		}
	}
	f := n.fields["r/0"]
	if f.anchor != 0 || f.caret != 7 || n.popup != nil {
		t.Errorf("select all left %d..%d and the menu %v", f.anchor, f.caret, n.popup != nil)
	}
}

func TestAScrollBarCanBeDragged(t *testing.T) {
	var rows []UiView
	for i := 0; i < 40; i++ {
		rows = append(rows, UiText(nil, "line"))
	}
	n, _ := uiLaidOut(UiColumn([]UiAttr{UiAttrHeight(210), UiAttrScroll("Vertical")}, rows), 400, 300)
	b := n.boxes["r/0"]
	n.down(b.x+b.w-3, b.y+5)
	n.move(b.x+b.w-3, b.y+55)
	n.up(b.x+b.w-3, b.y+55)
	n.layout()
	want := 50 * (b.extentH - b.h) / (b.h - math.Max(b.h*b.h/b.extentH, 24))
	if got := n.scrolls["r/0"][1]; !uiNear(got, want) {
		t.Errorf("scrolled to %.2f, wanted %.2f", got, want)
	}
}

func TestATextareaGrowsFromItsCorner(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{UiTextarea(nil, "")}), 400, 300)
	b := n.boxes["r/0/0"]
	n.down(b.x+b.w-3, b.y+b.h-3)
	n.move(b.x+b.w-3, b.y+b.h+37)
	n.up(b.x+b.w-3, b.y+b.h+37)
	n.layout()
	if got := n.boxes["r/0/0"].h; !uiNear(got, 104) {
		t.Errorf("the textarea is %.2f tall, wanted 104", got)
	}
}

func TestAMovingGifIsItsFramesInTurn(t *testing.T) {
	palette := color.Palette{color.RGBA{0, 0, 0, 0}, color.RGBA{255, 0, 0, 255}, color.RGBA{0, 0, 255, 255}}
	still := func(c uint8) *image.Paletted {
		img := image.NewPaletted(image.Rect(0, 0, 2, 2), palette)
		for i := range img.Pix {
			img.Pix[i] = c
		}
		return img
	}
	var out bytes.Buffer
	if err := gif.EncodeAll(&out, &gif.GIF{Image: []*image.Paletted{still(1), still(2)}, Delay: []int{5, 20}}); err != nil {
		t.Fatal(err)
	}
	frames, w, h, ok := uiDecodeFrames(out.Bytes())
	if !ok || len(frames) != 2 || w != 2 || h != 2 || frames[1].delay != 200*time.Millisecond || frames[1].pix[2] != 255 {
		t.Fatalf("decoded %d frames of %dx%d", len(frames), w, h)
	}
	p := &uiPicture{frames: frames, start: time.Now().Add(-60 * time.Millisecond)}
	if at, left := p.frameNow(); at != 1 || left <= 0 || left > 200*time.Millisecond {
		t.Errorf("60ms in shows frame %d for %v more", at, left)
	}
}

func TestALinkTakesItsOwnColourOrTheAccent(t *testing.T) {
	v := UiColumn(nil, []UiView{
		UiLink([]UiAttr{UiAttrTone(UiToneHex("#e5c07b"))}, "#", "a"),
		UiLink(nil, "#", "b"),
	})
	n, _ := uiLaidOut(v, 400, 300)
	own, _ := uiParseColour("#e5c07b")
	if got := n.boxes["r/0/0"].colour; got != own {
		t.Fatalf("a link with a colour of its own is drawn in %v, not %v", got, own)
	}
	if got := n.boxes["r/0/1"].colour; got != n.pal.accent {
		t.Fatalf("a link with no tone is drawn in %v, not the accent %v", got, n.pal.accent)
	}
}

func TestTheTitleBarFollowsTheOutermostWidget(t *testing.T) {
	if got := uiTitleOf(UiColumn([]UiAttr{UiAttrTitle("contagem 3")}, nil)); got != "contagem 3" {
		t.Fatalf("the title is %q", got)
	}
	if got := uiTitleOf(UiColumn(nil, []UiView{UiText([]UiAttr{UiAttrTitle("inner")}, "x")})); got != "" {
		t.Fatalf("a title below the outermost widget is %q, not ignored", got)
	}
}

func TestAKeyGoesToTheInnermostWidgetThatTakesIt(t *testing.T) {
	said := func(where string) func(string) any { return func(k string) any { return where + ":" + k } }
	v := UiColumn([]UiAttr{UiAttrKeys([]string{"Ctrl+S", "Escape"}), UiAttrOnKey(said("window"))}, []UiView{
		UiInput([]UiAttr{UiAttrKeys([]string{"Escape", "ArrowUp"}), UiAttrOnKey(said("field"))}, ""),
		UiTextarea([]UiAttr{UiAttrKeys([]string{"Any"}), UiAttrOnKey(said("editor"))}, ""),
	})
	n, box := uiLaidOut(v, 400, 300)
	if !n.claim("Ctrl+S") || uiPosted(box) != "window:Ctrl+S" {
		t.Fatal("with nothing focused, the outermost widget does not hear its key")
	}
	n.focus = "r/0/0"
	n.claim("Escape")
	n.claim("Ctrl+S")
	if got := uiPosted(box); got != "field:Escape,window:Ctrl+S" {
		t.Fatalf("from the field, the keys went to %q", got)
	}
	if n.claim("Enter") || uiPosted(box) != "" {
		t.Fatal("a key nothing takes was taken")
	}
	n.focus = "r/0/1"
	n.claim("j")
	n.claim("Ctrl+S")
	if got := uiPosted(box); got != "editor:j,editor:Ctrl+S" {
		t.Fatalf("Any does not take every key: %q", got)
	}
}

func TestKeysAreNamedModifiersFirst(t *testing.T) {
	for _, c := range []struct {
		key               string
		ctrl, shift, alt bool
		want              string
	}{
		{"S", true, false, false, "Ctrl+S"},
		{"P", true, true, false, "Ctrl+Shift+P"},
		{"O", true, false, true, "Ctrl+Alt+O"},
		{"Tab", false, true, false, "Shift+Tab"},
		{"", true, false, false, ""},
	} {
		if got := uiCombo(c.key, c.ctrl, c.shift, c.alt); got != c.want {
			t.Fatalf("%+v is named %q", c, got)
		}
	}
}

func TestACodeEditorTellsWhatAnEditReplaced(t *testing.T) {
	edited := func(from, to int, put string) any { return fmt.Sprintf("edit %d %d %q", from, to, put) }
	moved := func(a, h int) any { return fmt.Sprintf("caret %d %d", a, h) }
	text := "func main() {\n\treturn\n}"
	v := UiCode([]UiAttr{UiAttrOnEdit(edited), UiAttrOnCaret(moved), UiAttrCaret(15, 15, 0)}, text, []UiRun{
		UiInk(0, 4, UiToneHex("#c678dd")), UiSquiggle(15, 21, UiTone("Danger")), UiMarker(1, UiTone("Good")),
	})
	n, box := uiLaidOut(v, 400, 300)
	b := n.boxes["r/0"]
	if b == nil || !b.code || b.kind != "textarea" || !b.font.mono {
		t.Fatalf("a code editor is not a fixed-width textarea: %+v", b)
	}
	f := n.fields["r/0"]
	if f.caret != 15 || f.anchor != 15 {
		t.Fatalf("the caret the program set is at %d,%d", f.anchor, f.caret)
	}
	n.focus = "r/0"
	n.typed('x')
	n.key(uiKeyEnter, false, false)
	n.key(uiKeyTab, false, false)
	if got := uiPosted(box); got != `edit 15 15 "x",edit 16 16 "\n\t",edit 18 18 "\t"` {
		t.Fatalf("the edits told were %s", got)
	}
	if string(f.text) != "func main() {\n\tx\n\t\treturn\n}" {
		t.Fatalf("the text is %q", string(f.text))
	}
	if spans := n.flow(b, f); len(spans) != 4 || spans[2] != (uiSpan{17, 25}) {
		t.Fatalf("a code editor's lines are %v", spans)
	}
	// Two tabs reach column 8, wherever the font puts its letters.
	if got, want := n.runeX(b, f, 17, 19), 8*n.cellW(b); !uiNear(got, want) {
		t.Fatalf("two tabs reach %v, not %v", got, want)
	}
}

func TestACodeEditorTellsTheCaretItMovedToAndNotTheOneItWasGiven(t *testing.T) {
	moved := func(a, h int) any { return fmt.Sprintf("caret %d %d", a, h) }
	v := UiCode([]UiAttr{UiAttrOnCaret(moved), UiAttrCaret(2, 2, 0)}, "abc\ndef", nil)
	n, box := uiLaidOut(v, 400, 300)
	b, f := n.boxes["r/0"], n.fields["r/0"]
	n.codeTell(b, f, n.flow(b, f))
	if got := uiPosted(box); got != "" {
		t.Fatalf("the caret the program set was told back to it: %s", got)
	}
	n.focus = "r/0"
	n.key(uiKeyDown, true, false)
	n.codeTell(b, f, n.flow(b, f))
	if got := uiPosted(box); got != "caret 2 6" {
		t.Fatalf("a selection made with the keys was told as %q", got)
	}
}

func TestACodeEditorKeepsItsCaretWhenItsProgramChangesTheText(t *testing.T) {
	n, _ := uiLaidOut(UiCode(nil, "abc\ndef", nil), 400, 300)
	f := n.fields["r/0"]
	f.caret, f.anchor = 5, 5
	uiShowAgain(n, UiCode(nil, "abc\ndefgh", nil))
	if string(f.text) != "abc\ndefgh" || f.caret != 5 {
		t.Fatalf("the program's text left the caret at %d in %q", f.caret, string(f.text))
	}
}

func TestThePointersOwnEventsGoToWhatHearsThem(t *testing.T) {
	said := func(s string) any { return s }
	dragged := func(dx, dy int, done bool) any { return fmt.Sprintf("drag %d %d %v", dx, dy, done) }
	v := UiColumn(nil, []UiView{
		UiRow([]UiAttr{UiAttrPad(6), UiAttrOnMenu(said("menu")), UiAttrOnMiddle(said("middle")), UiAttrOnDouble(said("double"))}, []UiView{UiText(nil, "row")}),
		UiColumn([]UiAttr{UiAttrHeight(5), UiAttrOnDrag(dragged)}, nil),
	})
	n, box := uiLaidOut(v, 400, 300)
	row, grip := n.boxes["r/0/0"], n.boxes["r/0/1"]
	rx, ry := row.x+10, row.y+10
	n.menu(rx, ry)
	n.middle(rx, ry)
	uiClick(n, rx, ry)
	uiClick(n, rx, ry)
	if got := uiPosted(box); got != "menu,middle,double" {
		t.Fatalf("the row heard %q", got)
	}
	gx, gy := grip.x+50, grip.y+2
	n.down(gx, gy)
	n.move(gx+3, gy-20)
	n.move(gx+3, gy-40)
	n.up(gx+3, gy-40)
	if got := uiPosted(box); got != "drag 3 -20 false,drag 3 -40 false,drag 3 -40 true" {
		t.Fatalf("the grip heard %q", got)
	}
	if got := n.cursor(gx, gy); got != "resize" {
		t.Fatalf("a grip wider than it is tall shows %q", got)
	}
}

func TestACodeEditorTellsTheCharacterUnderThePointer(t *testing.T) {
	at := func(i int) any { return fmt.Sprintf("at %d", i) }
	jumped := func(i int) any { return fmt.Sprintf("jump %d", i) }
	n, box := uiLaidOut(UiCode([]UiAttr{UiAttrOnHover(at), UiAttrOnJump(jumped)}, "abc def\nx", nil), 400, 300)
	b := n.boxes["r/0"]
	cell := n.cellW(b)
	left, top := b.x+b.border+b.padX, b.y+b.border+b.padY
	n.move(left+4.5*cell, top+2)
	n.move(left+4.6*cell, top+2)
	n.move(left+20*cell, top+2)
	n.leave()
	if got := uiPosted(box); got != "at 4,at -1,at -1" {
		t.Fatalf("the pointer over the editor was told as %q", got)
	}
	n.ctrl = true
	n.down(left+0.5*cell, top+b.lineH+2)
	n.ctrl = false
	if got := uiPosted(box); !strings.HasPrefix(got, "jump 8") {
		t.Fatalf("a Ctrl+click was told as %q", got)
	}
}

func TestAnAnchoredOverlayOpensWhereThePointerWasAndClosesOnAPressElsewhere(t *testing.T) {
	said := func(s string) any { return s }
	v := UiColumn(nil, []UiView{
		UiText(nil, "page"),
		UiOverlay([]UiAttr{UiAttrAnchor(UiAnchor("Pointer")), UiAttrOnDismiss(said("dismiss"))}, UiText(nil, "menu")),
	})
	n, box := uiLaidOut(v, 400, 300)
	n.down(390, 290)
	n.up(390, 290)
	uiShowAgain(n, v)
	p := n.layers[0].panel
	if p.x+p.w > 400-4+0.01 || p.y+p.h > 300-4+0.01 || p.x < 300 || p.y < 200 {
		t.Fatalf("the panel is at %v,%v %vx%v", p.x, p.y, p.w, p.h)
	}
	if got := uiPosted(box); got != "dismiss" {
		t.Fatalf("a press outside the panel posted %q", got)
	}
	n.down(p.x+2, p.y+2)
	if got := uiPosted(box); got != "" {
		t.Fatalf("a press on the panel posted %q", got)
	}
}

func TestAFieldIsFocusedOnceForEachRequest(t *testing.T) {
	view := func(serial int) UiView {
		return UiColumn(nil, []UiView{UiInput(nil, "a"), UiColumn([]UiAttr{UiAttrFocus(serial)}, []UiView{UiText(nil, "x"), UiInput(nil, "b")})})
	}
	n, _ := uiLaidOut(view(1), 400, 300)
	if n.focus != "r/0/1/1" {
		t.Fatalf("a request on a column focuses %q, not the field in it", n.focus)
	}
	n.focus = "r/0/0"
	uiShowAgain(n, view(1))
	if n.focus != "r/0/0" {
		t.Fatal("the same request took the focus back")
	}
	uiShowAgain(n, view(2))
	if n.focus != "r/0/1/1" {
		t.Fatal("a new request did not")
	}
}

func TestAReadOnlyEditorSelectsAndCopiesButDoesNotChange(t *testing.T) {
	n, box := uiLaidOut(UiCode([]UiAttr{UiAttrReadOnly(true), UiAttrOnInput(uiSaid)}, "abc", nil), 400, 300)
	n.focus = "r/0"
	n.typed('x')
	n.key(uiKeyAll, false, true)
	n.key(uiKeyCopy, false, true)
	n.key(uiKeyBack, false, false)
	if f := n.fields["r/0"]; string(f.text) != "abc" || uiPosted(box) != "" {
		t.Fatalf("a read-only editor holds %q", string(f.text))
	}
	if n.dev.clipboard() != "abc" {
		t.Fatal("its selection was not copied")
	}
}

func TestTheClipboardAndAFieldsCommandsAreCarriedOutOncePerSerial(t *testing.T) {
	view := func(clip, command string, serial int) UiView {
		return UiColumn([]UiAttr{UiAttrClip(clip, serial)}, []UiView{UiCode([]UiAttr{UiAttrPerform(command, serial)}, "hello", nil)})
	}
	n, _ := uiLaidOut(view("first", "", 0), 400, 300)
	if n.dev.clipboard() != "" {
		t.Fatal("what was there when the window opened was copied")
	}
	uiShowAgain(n, view("path/to/file", "selectAll", 1))
	if n.dev.clipboard() != "path/to/file" {
		t.Fatalf("the clipboard holds %q", n.dev.clipboard())
	}
	f := n.fields["r/0/0"]
	if f.anchor != 0 || f.caret != 5 || n.focus != "r/0/0" {
		t.Fatalf("select all left %d..%d, focus %q", f.anchor, f.caret, n.focus)
	}
	f.caret, f.anchor = 2, 2
	uiShowAgain(n, view("path/to/file", "selectAll", 1))
	if f.caret != 2 {
		t.Fatal("the same command ran twice")
	}
}

func TestACodeEditorSaysHowManyColumnsAndRowsFit(t *testing.T) {
	fit := func(cols, rows int) any { return fmt.Sprintf("fit %d %d", cols, rows) }
	pasted := func(s string) any { return "paste " + s }
	n, box := uiLaidOut(UiCode([]UiAttr{UiAttrOnFit(fit), UiAttrOnPaste(pasted), UiAttrKeys([]string{"Any"}), UiAttrOnKey(uiSaid)}, "", nil), 400, 300)
	b, f := n.boxes["r/0"], n.fields["r/0"]
	n.codeTell(b, f, n.flow(b, f))
	want := fmt.Sprintf("fit %d %d", int((b.w-2*b.padX-2*b.border)/n.cellW(b)), int((b.h-2*b.padY-2*b.border)/b.lineH))
	if got := uiPosted(box); got != want {
		t.Fatalf("told %q, want %q", got, want)
	}
	n.focus = "r/0"
	n.dev.setClipboard("a\r\nb")
	if !n.claim("Ctrl+V") || uiPosted(box) != "paste a\nb" {
		t.Fatal("Ctrl+V did not hand over the clipboard")
	}
}


// The rounded box and ring, drawn a row's middle at a time, cover exactly what
// the distance to their edge says, pixel for pixel.
func TestARoundedBoxIsDrawnAsItsDistanceSays(t *testing.T) {
	reference := func(w, h int, x0, y0, x1, y1, radius, width float64, ring bool, c uiRGBA) []uint32 {
		pix := make([]uint32, w*h)
		radius = math.Min(radius, math.Min(x1-x0, y1-y0)/2)
		cx, cy := (x0+x1)/2, (y0+y1)/2
		hx, hy := (x1-x0)/2-radius, (y1-y0)/2-radius
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				if float64(x) < math.Floor(x0) || float64(x) >= math.Ceil(x1) || float64(y) < math.Floor(y0) || float64(y) >= math.Ceil(y1) {
					continue
				}
				qx := math.Abs(float64(x)+0.5-cx) - hx
				qy := math.Abs(float64(y)+0.5-cy) - hy
				d := math.Hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - radius
				cover := uiClamp(0.5-d, 0, 1)
				if ring {
					cover -= uiClamp(0.5-(d+width), 0, 1)
				}
				if cover > 0 {
					pix[y*w+x] = uiBlendPixel(pix[y*w+x], c, cover)
				}
			}
		}
		return pix
	}
	c := uiRGBA{200, 100, 50, 255}
	for _, k := range []struct{ x0, y0, x1, y1, radius, width float64 }{
		{3.3, 2.7, 57.6, 31.2, 8, 1}, {0, 0, 60, 40, 0, 2}, {10, 5, 20, 35, 16, 3}, {1.5, 1.5, 58.5, 38.5, 4, 6}, {5, 5, 55, 9, 8, 1},
	} {
		for _, ring := range []bool{false, true} {
			cv := &uiCanvas{pix: make([]uint32, 60*40), w: 60, h: 40, flush: func() {}}
			if ring {
				cv.ring(k.x0, k.y0, k.x1, k.y1, k.radius, k.width, c, uiClip{0, 0, 60, 40})
			} else {
				cv.round(k.x0, k.y0, k.x1, k.y1, k.radius, c, uiClip{0, 0, 60, 40})
			}
			want := reference(60, 40, k.x0, k.y0, k.x1, k.y1, k.radius, k.width, ring, c)
			for i := range want {
				if cv.pix[i] != want[i] {
					t.Fatalf("%+v ring=%v: pixel %d,%d is %08x, not %08x", k, ring, i%60, i/60, cv.pix[i], want[i])
				}
			}
		}
	}
}

func TestAFramedWidgetPaintsItsOwnColourAndEdge(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{
		UiButton([]UiAttr{UiAttrBackground(UiToneHex("#204060"))}, "Go"),
		UiButton([]UiAttr{UiAttrBorder(2), UiAttrBorderTone(UiToneHex("#ff0000"))}, "Edge"),
	}), 400, 300)
	coloured, edged := n.boxes["r/0/0"], n.boxes["r/0/1"]
	if w, _ := n.edgeOf(coloured, true); w != 0 {
		t.Fatalf("a button in its own colour has a %v px edge", w)
	}
	if w, c := n.edgeOf(edged, false); w != 2 || c != (uiRGBA{255, 0, 0, 255}) {
		t.Fatalf("the edge asked for is %v px in %v", w, c)
	}
}

func TestTheBoxUnderThePointerLightsUpAndALinkInItIsNotUnderlined(t *testing.T) {
	v := UiColumn(nil, []UiView{
		UiRow([]UiAttr{UiAttrHover(UiToneHex("#80808030")), UiAttrPad(4)}, []UiView{UiLink([]UiAttr{UiAttrOn("open")}, "#", "file.hive")}),
		UiText(nil, "below"),
	})
	n, _ := uiLaidOut(v, 400, 300)
	row := n.boxes["r/0/0"]
	if !n.move(row.x+2, row.y+2) || n.lit != "r/0/0" {
		t.Fatalf("the row under the pointer is not lit: %q", n.lit)
	}
	below := n.boxes["r/0/1"]
	if !n.move(below.x+2, below.y+2) || n.lit != "" {
		t.Fatalf("moving off the row left %q lit", n.lit)
	}
}

func TestCtrlOverAnEditorProbesTheCharacterUnderThePointer(t *testing.T) {
	probed := func(at int) any { return fmt.Sprintf("probe %d", at) }
	n, box := uiLaidOut(UiCode([]UiAttr{UiAttrOnProbe(probed), UiAttrOnJump(probed)}, "abc def", nil), 400, 300)
	b := n.boxes["r/0"]
	cell := n.cellW(b)
	x, y := b.x+b.border+b.padX+4.5*cell, b.y+b.border+b.padY+2
	n.move(x, y)
	if got := uiPosted(box); got != "" {
		t.Fatalf("without Ctrl the editor was told %q", got)
	}
	n.setCtrl(true)
	if n.cursor(x*n.scale, y*n.scale) != "hand" {
		t.Fatal("Ctrl over a name does not show the hand")
	}
	n.setCtrl(false)
	if got := uiPosted(box); got != "probe 4,probe -1" {
		t.Fatalf("Ctrl down and up told %q", got)
	}
}
