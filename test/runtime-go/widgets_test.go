package hive

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func uiAt(what string) func(float64, float64) any {
	return func(x, y float64) any { return fmt.Sprintf("%s %g,%g", what, x, y) }
}

func uiPair2(what string) func(int, int) any {
	return func(x, y int) any { return fmt.Sprintf("%s %d,%d", what, x, y) }
}

func uiBoxAt(t *testing.T, n *uiNative, path string, x, y, w, h float64) {
	t.Helper()
	b, ok := n.boxes[path]
	if !ok {
		t.Fatalf("no box at %s", path)
	}
	if !uiNear(b.x, x) || !uiNear(b.y, y) || !uiNear(b.w, w) || !uiNear(b.h, h) {
		t.Errorf("%s is %.2f,%.2f %.2fx%.2f, wanted %.2f,%.2f %.2fx%.2f", path, b.x, b.y, b.w, b.h, x, y, w, h)
	}
}

func TestARowThatWrapsStartsANewLineWhereTheNextWidgetWouldNotFit(t *testing.T) {
	n, _ := uiLaidOut(UiRow([]UiAttr{UiAttrWrap(true), UiAttrGap(10)}, []UiView{
		UiText(nil, "aaaa"), UiText(nil, "bbbbbb"), UiText(nil, "cc"),
	}), 80, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 28, 21)
	uiBoxAt(t, n, "r/0/1", 38, 0, 42, 21)
	uiBoxAt(t, n, "r/0/2", 0, 31, 14, 21)
	if b := n.boxes["r/0"]; !uiNear(b.h, 52) {
		t.Errorf("the row is %.2f tall, wanted two lines and a gap", b.h)
	}
}

func TestAGridSizesItsAutoColumnToWhatItHoldsAndSharesTheRest(t *testing.T) {
	n, _ := uiLaidOut(UiGrid([]UiAttr{UiAttrColumns([]int{0, 1}), UiAttrGap(8)}, []UiView{
		UiText(nil, "Name"), UiInput(nil, ""), UiText(nil, "Long label"), UiInput(nil, ""),
	}), 300, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 70, 39)
	uiBoxAt(t, n, "r/0/1", 78, 0, 222, 39)
	uiBoxAt(t, n, "r/0/2", 0, 47, 70, 39)
	uiBoxAt(t, n, "r/0/3", 78, 47, 222, 39)
}

func TestAGridChildSpansColumnsAndTheNextWrapsBelowIt(t *testing.T) {
	n, _ := uiLaidOut(UiGrid([]UiAttr{UiAttrColumns([]int{1, 1})}, []UiView{
		UiText([]UiAttr{UiAttrSpan(2)}, "wide"), UiText(nil, "a"), UiText(nil, "b"),
	}), 200, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 200, 21)
	uiBoxAt(t, n, "r/0/1", 0, 21, 100, 21)
	uiBoxAt(t, n, "r/0/2", 100, 21, 100, 21)
}

func TestAStackLaysItsChildrenOverOneAnother(t *testing.T) {
	n, _ := uiLaidOut(UiStack([]UiAttr{UiAttrWidth(200), UiAttrHeight(100)}, []UiView{
		UiColumn([]UiAttr{UiAttrBackground("Muted")}, nil),
		UiText([]UiAttr{UiAttrPlace("End", "Start")}, "new"),
		UiText([]UiAttr{UiAttrPlace("Center", "End")}, "mid"),
	}), 400, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 200, 100)
	uiBoxAt(t, n, "r/0/1", 179, 0, 21, 21)
	uiBoxAt(t, n, "r/0/2", 89.5, 79, 21, 21)
}

func TestLimitsAndAnAspectSetASize(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{
		UiRow([]UiAttr{UiAttrMaxWidth(120)}, []UiView{UiText(nil, "x")}),
		UiRow(nil, []UiView{UiText([]UiAttr{UiAttrMinWidth(50)}, "ab")}),
		UiColumn([]UiAttr{UiAttrAspect(2, 1)}, nil),
		UiColumn([]UiAttr{UiAttrMinHeight(30), UiAttrMaxHeight(10)}, nil),
	}), 400, 600)
	if b := n.boxes["r/0/0"]; !uiNear(b.w, 120) {
		t.Errorf("a row held to 120 is %.2f wide", b.w)
	}
	if b := n.boxes["r/0/1/0"]; !uiNear(b.w, 50) {
		t.Errorf("a text at least 50 wide is %.2f", b.w)
	}
	if b := n.boxes["r/0/2"]; !uiNear(b.h, 200) {
		t.Errorf("a box twice as wide as tall is %.2f tall at %.2f wide", b.h, b.w)
	}
	if b := n.boxes["r/0/3"]; !uiNear(b.h, 30) {
		t.Errorf("a least height beats a greatest one: %.2f", b.h)
	}
}

func TestATextKeepsItsLinesAndCutsTheLastShort(t *testing.T) {
	n, _ := uiLaidOut(UiColumn([]UiAttr{UiAttrWidth(70)}, []UiView{
		UiText([]UiAttr{UiAttrLines(2)}, "aaaa bbbb cccc dddd eeee"),
		UiText([]UiAttr{UiAttrWrap(false)}, "aaaa bbbb cccc"),
	}), 400, 300)
	if b := n.boxes["r/0/0"]; len(b.lines) != 2 || b.lines[1] != "cccc dddd…" || !uiNear(b.h, 42) {
		t.Errorf("clamped to %q, %.2f tall", b.lines, b.h)
	}
	if b := n.boxes["r/0/1"]; len(b.lines) != 1 {
		t.Errorf("an unwrapped text broke into %q", b.lines)
	}
}

func TestATextLineIsPlacedAsItsJustifySays(t *testing.T) {
	n, _ := uiLaidOut(UiColumn([]UiAttr{UiAttrWidth(70)}, []UiView{
		UiText([]UiAttr{UiAttrJustify("Center")}, "ab"),
		UiText([]UiAttr{UiAttrJustify("End")}, "ab"),
		UiText([]UiAttr{UiAttrJustify("Between")}, "a b cc dd e"),
	}), 400, 300)
	if shift, _ := n.lineShift(n.boxes["r/0/0"], 0, "ab", 70); !uiNear(shift, 28) {
		t.Errorf("a centred line starts at %.2f", shift)
	}
	if shift, _ := n.lineShift(n.boxes["r/0/1"], 0, "ab", 70); !uiNear(shift, 56) {
		t.Errorf("an ended line starts at %.2f", shift)
	}
	b := n.boxes["r/0/2"]
	if _, spread := n.lineShift(b, 0, b.lines[0], 70); spread <= 0 {
		t.Errorf("a justified line that is not the last spreads %.2f", spread)
	}
	if _, spread := n.lineShift(b, len(b.lines)-1, b.lines[len(b.lines)-1], 70); spread != 0 {
		t.Errorf("the last line of a paragraph spreads %.2f", spread)
	}
}

func TestAParagraphFlowsItsWordsAndALinkInItIsFollowed(t *testing.T) {
	n, box := uiLaidOut(UiColumn([]UiAttr{UiAttrWidth(70)}, []UiView{
		UiParagraph(nil, []UiView{
			UiText(nil, "aa bb "),
			UiLink([]UiAttr{UiAttrOn("followed")}, "/x", "cc dd"),
			UiText(nil, " ee"),
		}),
	}), 400, 300)
	p := n.boxes["r/0/0"]
	if !uiNear(p.h, 42) || p.layout == nil {
		t.Fatalf("the paragraph is %.2f tall", p.h)
	}
	var lines []string
	line, text := 0, ""
	for _, f := range p.layout.frags {
		if f.line != line {
			lines, line, text = append(lines, text), f.line, ""
		}
		text += f.text
	}
	lines = append(lines, text)
	if strings.Join(lines, "|") != "aa bb cc |dd ee" {
		t.Errorf("laid out as %q", lines)
	}
	uiClick(n, 45, 10)
	uiClick(n, 3, 31)
	uiClick(n, 3, 10)
	if got := uiPosted(box); got != "followed,followed" {
		t.Errorf("heard %s", got)
	}
}

func TestARadioGroupChoosesAndItsArrowsMoveTheChoice(t *testing.T) {
	n, box := uiLaidOut(UiRadio([]UiAttr{UiAttrOnChoose(uiSaid)}, []string{"one", "two"}, "one"), 400, 300)
	uiBoxAt(t, n, "r/0/r1", 0, 27, 400, 21)
	uiClick(n, 10, 30)
	if n.focus != "r/0/r1" {
		t.Errorf("the focus is on %q", n.focus)
	}
	n.key(uiKeyUp, false, false)
	if got := uiPosted(box); got != "two,one" {
		t.Errorf("heard %s", got)
	}
}

func TestTabsAndChoicesSayWhatWasChosen(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiTabs([]UiAttr{UiAttrOnChoose(uiSaid)}, []string{"First", "Second"}, "First"),
		UiChoices([]UiAttr{UiAttrOnChoose(uiSaid)}, []string{"red", "green"}, []string{"green"}),
	}), 400, 300)
	uiBoxAt(t, n, "r/0/0/t1", 63, 0, 66, 39)
	uiBoxAt(t, n, "r/0/1/c1", 5, 39+38, 390, 33)
	uiClick(n, 70, 10)
	uiClick(n, 20, 39+45)
	if got := uiPosted(box); got != "Second,green" {
		t.Errorf("heard %s", got)
	}
	if n.itemOn(n.boxes["r/0/1/c1"]) {
		t.Errorf("a chosen option clicked is still shown chosen")
	}
}

func TestABranchIsPickedByItsRowAndOpenedByItsTwisty(t *testing.T) {
	branch := func(open bool) UiView {
		return UiTree(nil, []UiView{UiBranch([]UiAttr{UiAttrOn("picked"),
			UiAttrOnToggle(func(b bool) any { return fmt.Sprint("open ", b) })}, "src", open,
			[]UiView{UiText(nil, "child")})})
	}
	n, box := uiLaidOut(branch(false), 400, 300)
	uiBoxAt(t, n, "r/0/0/b0", 0, 0, 400, 25)
	uiBoxAt(t, n, "r/0/0/b0/t0", 4, 4.5, 16, 16)
	if _, open := n.boxes["r/0/0/0"]; open {
		t.Errorf("a closed branch shows its children")
	}
	uiClick(n, 10, 10)
	uiClick(n, 40, 10)
	if got := uiPosted(box); got != "open true,picked" {
		t.Errorf("heard %s", got)
	}
	uiShowAgain(n, branch(true))
	uiBoxAt(t, n, "r/0/0/0", 16, 25, 384, 21)
	uiClick(n, 10, 10)
	if got := uiPosted(box); got != "open false" {
		t.Errorf("heard %s", got)
	}
}

func TestAProgressBarRunsTheWidthItIsGiven(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{UiProgress(nil, 0.25)}), 400, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 400, 6)
	if uiDone(n.boxes["r/0/0"].v) != 0.25 {
		t.Errorf("the bar says %v", uiDone(n.boxes["r/0/0"].v))
	}
}

func TestAnIconIsASquareOfItsTypeInALineOfIt(t *testing.T) {
	n, _ := uiLaidOut(UiRow(nil, []UiView{UiIconOf(nil, "Star")}), 400, 300)
	uiBoxAt(t, n, "r/0/0", 0, 0, 14, 21)
	if pix := n.iconPixels("Star", uiRGBA{0, 0, 0, 255}, 24); len(pix) != 24*24*4 {
		t.Errorf("a star drawn 24 wide is %d bytes", len(pix))
	}
}

func TestThePointerArrivingLeavingPressingMovingAndLettingGoIsHeard(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiColumn([]UiAttr{UiAttrWidth(100), UiAttrHeight(100), UiAttrOnEnter("in"), UiAttrOnLeave("out"),
			UiAttrOnPress(uiAt("press")), UiAttrOnPoint(uiAt("point")), UiAttrOnRelease(uiAt("release"))}, nil),
	}), 400, 300)
	uiClick(n, 10, 20)
	n.move(10, 200)
	if got := uiPosted(box); got != "in,point 10,20,press 10,20,release 10,20,out" {
		t.Errorf("heard %s", got)
	}
}

func TestACanvasIsPointedAtInItsOwnUnits(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiCanvas([]UiAttr{UiAttrRegion(0, 0, 10, 10), UiAttrWidth(100), UiAttrHeight(100), UiAttrOnPress(uiAt("press"))}, nil),
	}), 400, 300)
	uiClick(n, 50, 20)
	if got := uiPosted(box); got != "press 5,2" {
		t.Errorf("heard %s", got)
	}
}

func TestTheFocusArrivingAndLeavingAColumnIsHeard(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiColumn([]UiAttr{UiAttrOnFocus("focused"), UiAttrOnBlur("blurred")}, []UiView{UiButton(nil, "a")}),
		UiButton(nil, "b"),
	}), 400, 300)
	n.key(uiKeyTab, false, false)
	n.key(uiKeyTab, false, false)
	if got := uiPosted(box); got != "focused,blurred" {
		t.Errorf("heard %s", got)
	}
}

func TestTheWheelAScrollAndASizeAreHeard(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiColumn([]UiAttr{UiAttrHeight(40), UiAttrOnWheel(uiAt("wheel"))}, nil),
		UiColumn([]UiAttr{UiAttrScroll("Vertical"), UiAttrHeight(50), UiAttrOnScroll(uiPair2("scroll")),
			UiAttrOnSize(uiPair2("size"))}, []UiView{UiText(nil, strings.Repeat("line\n", 9)+"line")}),
	}), 400, 300)
	if got := uiPosted(box); got != "size 400,50" {
		t.Errorf("laid out, heard %s", got)
	}
	n.wheel(10, 10, 1, false)
	n.wheel(10, 60, -1, false)
	n.layout()
	if got := uiPosted(box); got != "wheel 0,-100,scroll 0,100" {
		t.Errorf("heard %s", got)
	}
}

func TestSomethingCarriedIsDroppedWhereItIsLetGo(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiText([]UiAttr{UiAttrCarry("card")}, "drag"),
		UiColumn([]UiAttr{UiAttrHeight(50), UiAttrOnDrop(uiSaid)}, nil),
	}), 400, 300)
	n.move(5, 5)
	n.down(5, 5)
	n.move(5, 40)
	n.up(5, 40)
	if got := uiPosted(box); got != "card" {
		t.Errorf("heard %s", got)
	}
}

func TestAFileDroppedOnTheWindowGoesToWhatHearsFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiColumn([]UiAttr{UiAttrHeight(50), UiAttrOnFile(func(name, contents string) any { return name + ":" + contents })}, nil),
	}), 400, 300)
	if !n.filesDropped(10, 10, []string{path}) {
		t.Fatalf("the drop was not taken")
	}
	got := ""
	for deadline := time.Now().Add(2 * time.Second); got == "" && time.Now().Before(deadline); {
		got = uiPosted(box)
		time.Sleep(10 * time.Millisecond)
	}
	if got != "note.txt:hello" {
		t.Errorf("heard %s", got)
	}
}

func TestASliderAndANumberKeepToTheirLimitsAndSteps(t *testing.T) {
	n, box := uiLaidOut(UiColumn(nil, []UiView{
		UiInput([]UiAttr{UiAttrKind("Range"), UiAttrLimits(0, 1, 0.25), UiAttrOnInput(uiSaid)}, "0.5"),
		UiInput([]UiAttr{UiAttrKind("Number"), UiAttrLimits(0, 10, 2), UiAttrOnInput(uiSaid)}, "3"),
	}), 400, 300)
	n.down(300, 10)
	n.up(300, 10)
	n.key(uiKeyRight, false, false)
	n.key(uiKeyTab, false, false)
	n.key(uiKeyUp, false, false)
	if got := uiPosted(box); got != "0.75,1,4" {
		t.Errorf("heard %s", got)
	}
}

func TestATimeIsTypedASegmentAtATime(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrKind("Time"), UiAttrOnInput(uiSaid)}, ""), 400, 300)
	n.tab(false)
	for _, r := range "0930" {
		n.typed(r)
	}
	if got := uiPosted(box); got != "09:03,09:30" {
		t.Errorf("heard %s", got)
	}
	d := &uiDate{kind: "DateTime"}
	d.set("2026-11-16T09:30")
	if d.value() != "2026-11-16T09:30" {
		t.Errorf("a date and time came back as %q", d.value())
	}
	d.set("2026-11-16")
	if d.value() != "" || d.dayValue() != "2026-11-16" {
		t.Errorf("a date with no time is %q", d.value())
	}
}

func TestAColourIsPickedFromItsPopup(t *testing.T) {
	n, box := uiLaidOut(UiInput([]UiAttr{UiAttrKind("Color"), UiAttrOnInput(uiSaid)}, "#ff0000"), 400, 300)
	n.down(20, 10)
	p := n.popup
	if p == nil || p.kind != "colour" {
		t.Fatalf("the picker did not open")
	}
	n.down(p.x+10, p.y+10)
	n.up(p.x+10, p.y+10)
	if got := uiPosted(box); got != "#ffffff" {
		t.Errorf("heard %s", got)
	}
	if n.colourValue(n.boxes["r/0"]) != "#ffffff" {
		t.Errorf("the field shows %s", n.colourValue(n.boxes["r/0"]))
	}
}

func TestAChangeThatEasesIsDrawnOnTheWayThere(t *testing.T) {
	look := func(hex string) UiView {
		return UiColumn(nil, []UiView{UiColumn([]UiAttr{UiAttrEase(1000), UiAttrBackground(UiToneHex(hex)), UiAttrHeight(20)}, nil)})
	}
	n, _ := uiLaidOut(look("#000000"), 400, 300)
	uiShowAgain(n, look("#ffffff"))
	if b := n.boxes["r/0/0"]; !n.easingLive || b.fill.r > 64 {
		t.Errorf("an eased change landed at once: %v", b.fill)
	}
}

func TestTheNewWidgetsAreToldToAScreenReader(t *testing.T) {
	n, _ := uiLaidOut(UiColumn(nil, []UiView{
		UiRadio(nil, []string{"one", "two"}, "two"),
		UiTabs(nil, []string{"a"}, "a"),
		UiTree(nil, []UiView{UiBranch(nil, "src", true, []UiView{UiText(nil, "x")})}),
		UiProgress(nil, 0.5),
		UiParagraph(nil, []UiView{UiText(nil, "said "), UiText(nil, "whole")}),
	}), 400, 600)
	roles := map[string]int{}
	var walk func(a *uiAccess)
	walk = func(a *uiAccess) {
		roles[a.role]++
		if a.role == "radio" && a.name == "two" && !a.selected {
			t.Errorf("the chosen radio is not selected")
		}
		if a.role == "treeitem" && a.expanded != 1 {
			t.Errorf("an open branch is not expanded")
		}
		if a.role == "text" && strings.HasPrefix(a.name, "said") && a.name != "said whole" {
			t.Errorf("a paragraph reads %q", a.name)
		}
		for _, k := range a.kids {
			walk(k)
		}
	}
	walk(n.access())
	for role, want := range map[string]int{"radio": 2, "tab": 1, "tablist": 1, "tree": 1, "treeitem": 1, "progress": 1} {
		if roles[role] != want {
			t.Errorf("%d nodes of role %s, wanted %d", roles[role], role, want)
		}
	}
}

func uiDrawn(t *testing.T, marks []UiMark) (*uiNative, func(x, y int) uiRGBA) {
	t.Helper()
	n, _ := uiLaidOut(UiColumn(nil, []UiView{
		UiCanvas([]UiAttr{UiAttrRegion(0, 0, 10, 10), UiAttrWidth(100), UiAttrHeight(100)}, marks),
	}), 100, 100)
	cv := &uiCanvas{pix: make([]uint32, 100*100), w: 100, h: 100, flush: func() {}}
	n.paint(cv)
	return n, func(x, y int) uiRGBA {
		p := cv.pix[y*100+x]
		return uiRGBA{uint8(p >> 16), uint8(p >> 8), uint8(p), 255}
	}
}

var uiRed = UiToneHex("#ff0000")

func TestACutoutLeavesItsHolesEmpty(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiCutout([]UiAttr{UiAttrPaint(uiRed)}, UiDot(nil, 5, 5, 4), []UiMark{UiDot(nil, 5, 5, 2)})})
	if c := at(50, 50); c != uiWhite {
		t.Errorf("the hole is %v", c)
	}
	if c := at(80, 50); c != (uiRGBA{255, 0, 0, 255}) {
		t.Errorf("the ring is %v", c)
	}
}

func TestAnEdgeWithNoPaintIsARing(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiDot([]UiAttr{UiAttrEdge(uiRed), UiAttrThick(1)}, 5, 5, 4)})
	if c := at(50, 50); c != uiWhite {
		t.Errorf("the inside is %v", c)
	}
	if c := at(90, 50); c != (uiRGBA{255, 0, 0, 255}) {
		t.Errorf("the edge is %v", c)
	}
}

func TestASymbolTurnsAndScalesWhatItHolds(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiSymbol(nil, 5, 5, math.Pi/2, 2, []UiMark{UiBar([]UiAttr{UiAttrPaint(uiRed)}, 1, 0, 1, 0.5)})})
	if c := at(50, 70); c != (uiRGBA{255, 0, 0, 255}) {
		t.Errorf("below the middle is %v", c)
	}
	if c := at(70, 50); c != uiWhite {
		t.Errorf("right of the middle is %v", c)
	}
}

func TestACropKeepsOnlyWhatIsInsideIt(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiSymbol([]UiAttr{UiAttrCrop(-4, -4, 4, 8)}, 5, 5, 0, 1,
		[]UiMark{UiDot([]UiAttr{UiAttrPaint(uiRed)}, 0, 0, 3)})})
	if c := at(30, 50); c != (uiRGBA{255, 0, 0, 255}) {
		t.Errorf("inside the crop is %v", c)
	}
	if c := at(70, 50); c != uiWhite {
		t.Errorf("outside the crop is %v", c)
	}
}

func TestAGradientRunsFromOneToneToTheOther(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiBar([]UiAttr{UiAttrGradient(UiToneHex("#000000"), UiToneHex("#ffffff"), 0)}, 5, 5, 10, 10)})
	left, right := at(2, 50), at(97, 50)
	if left.r > 20 || right.r < 235 || at(50, 50).r < 110 || at(50, 50).r > 145 {
		t.Errorf("left %v, middle %v, right %v", left, at(50, 50), right)
	}
}

func TestAPartlySeeThroughSymbolIsFadedAsAWhole(t *testing.T) {
	_, at := uiDrawn(t, []UiMark{UiSymbol([]UiAttr{UiAttrOpacity(0.5)}, 5, 5, 0, 1, []UiMark{
		UiBar([]UiAttr{UiAttrPaint(uiRed)}, 0, 0, 6, 6), UiBar([]UiAttr{UiAttrPaint(uiRed)}, 1, 0, 6, 6)})})
	if c := at(52, 50); c.r != 255 || c.g < 120 || c.g > 135 {
		t.Errorf("two overlapping marks faded together came out %v", c)
	}
}

func TestDashesFollowTheLine(t *testing.T) {
	got := uiDashed([]float64{0, 0, 10, 0}, 2, 1)
	if len(got) != 4 || !uiNear(got[1][0], 3) || !uiNear(got[3][len(got[3])-2], 10) {
		t.Errorf("dashed as %v", got)
	}
}

func TestWordsAreAsWideAsMeasureSays(t *testing.T) {
	if got := UiMeasure("Mi", 10); !uiNear(got, (833+222)/100.0) {
		t.Errorf("Mi at 10 measures %.4f", got)
	}
	if got := UiMeasure("日本", 2); !uiNear(got, 4) {
		t.Errorf("two wide letters at 2 measure %.4f", got)
	}
	x, y := uiAnchored([]UiAttr{UiAttrJustify("Start"), UiAttrAlign("End")}, 10, 10, 6, 2)
	if !uiNear(x, 13) || !uiNear(y, 9) {
		t.Errorf("words from their start and bottom sit at %.2f,%.2f", x, y)
	}
}
