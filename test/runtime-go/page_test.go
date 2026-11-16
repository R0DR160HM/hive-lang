package hive

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

func TestTheNewEventsAreDelivered(t *testing.T) {
	pair := func(what string) func(float64, float64) any {
		return func(x, y float64) any { return fmt.Sprintf("%s %g,%g", what, x, y) }
	}
	for _, c := range []struct {
		name  string
		attr  UiAttr
		kind  string
		value string
		want  any
	}{
		{"onEnter", UiAttrOnEnter("in"), "enter", "", "in"},
		{"onLeave", UiAttrOnLeave("out"), "leave", "", "out"},
		{"onFocus", UiAttrOnFocus("got"), "focus", "", "got"},
		{"onBlur", UiAttrOnBlur("lost"), "blur", "", "lost"},
		{"onWheel", UiAttrOnWheel(pair("wheel")), "wheel", "0,-100", "wheel 0,-100"},
		{"onPress", UiAttrOnPress(pair("press")), "press", "1.5,2", "press 1.5,2"},
		{"onPoint", UiAttrOnPoint(pair("point")), "point", "3,4", "point 3,4"},
		{"onRelease", UiAttrOnRelease(pair("release")), "release", "5,6", "release 5,6"},
		{"onScroll", UiAttrOnScroll(func(x, y int) any { return x*1000 + y }), "scroll", "7,8", 7008},
		{"onDrop", UiAttrOnDrop(func(s string) any { return "dropped " + s }), "drop", "card", "dropped card"},
		{"onFile", UiAttrOnFile(func(name, body string) any { return name + "=" + body }), "file",
			uiFileValue("a.txt", []byte("hi")), "a.txt=hi"},
	} {
		w := &uiWindow{handlers: map[string][]UiAttr{"h1": {c.attr}}}
		got, ok := w.message("h1", c.kind, c.value, 0)
		if !ok || got != c.want {
			t.Errorf("%s: wanted %v, got %v (%v)", c.name, c.want, got, ok)
		}
	}
}

func TestAFileCrossesWhateverItsNameAndBytes(t *testing.T) {
	body := []byte{0, 255, '\n', ',', 0xe2, 0x82}
	name, contents, ok := uiFileOf(uiFileValue("notas, ação.bin", body))
	if !ok || name != "notas, ação.bin" || contents != string(body) {
		t.Errorf("came back as %q %q (%v)", name, contents, ok)
	}
	if _, _, ok := uiFileOf("not base64"); ok {
		t.Errorf("a malformed file was taken")
	}
	parts := uiFileParts{}
	value := uiFileValue("big", []byte(strings.Repeat("x", 30)))
	name64, body64, _ := strings.Cut(value, ",")
	if _, whole := parts.take("h1", "filepart", body64[:16]); whole {
		t.Errorf("a piece was delivered on its own")
	}
	got, whole := parts.take("h1", "file", name64+","+body64[16:])
	if _, contents, ok := uiFileOf(got); !whole || !ok || contents != strings.Repeat("x", 30) {
		t.Errorf("the pieces came together as %q", contents)
	}
	if len(parts) != 0 {
		t.Errorf("pieces were kept after the file was whole")
	}
}

func uiIdsIn(html, marker string) []string {
	var ids []string
	for _, m := range regexp.MustCompile(marker+`[^>]*data-h="(h\d+)"`).FindAllStringSubmatch(html, -1) {
		ids = append(ids, m[1])
	}
	return ids
}

func TestEachChoiceAndTabSaysItsOwnOption(t *testing.T) {
	choose := UiAttrOnChoose(func(s string) any { return "chose " + s })
	r := &uiRender{handlers: map[string][]UiAttr{}}
	r.view(UiColumn(nil, []UiView{
		UiChoices([]UiAttr{choose}, []string{"red", "green"}, nil),
		UiTabs([]UiAttr{choose}, []string{"one", "two"}, "one"),
	}))
	html := r.out.String()
	choices := uiIdsIn(html, `class="h-choice"`)
	tabs := uiIdsIn(html, `class="h-tab"`)
	if len(choices) != 2 || len(tabs) != 2 {
		t.Fatalf("handlers %v %v in %s", choices, tabs, html)
	}
	w := &uiWindow{handlers: r.handlers}
	for id, want := range map[string]string{choices[1]: "chose green", tabs[0]: "chose one"} {
		if got, ok := w.message(id, "click", "", 0); !ok || got != want {
			t.Errorf("%s said %v, wanted %s", id, got, want)
		}
	}
}

func TestABranchsTwistyOpensWhatIsClosedAndItsRowIsPicked(t *testing.T) {
	r := &uiRender{handlers: map[string][]UiAttr{}}
	r.view(UiBranch([]UiAttr{UiAttrOn("picked"), UiAttrOnToggle(func(b bool) any { return b })}, "src", false,
		[]UiView{UiText(nil, "child")}))
	html := r.out.String()
	if strings.Contains(html, "child") {
		t.Errorf("a closed branch drew its children: %s", html)
	}
	twisty := regexp.MustCompile(`class="h-twisty" data-h="(h\d+)" data-toggle="1"`).FindStringSubmatch(html)
	head := regexp.MustCompile(`class="h-branch-head" data-h="(h\d+)"`).FindStringSubmatch(html)
	if twisty == nil || head == nil {
		t.Fatalf("no handlers in %s", html)
	}
	w := &uiWindow{handlers: r.handlers}
	if got, ok := w.message(twisty[1], "toggle", "1", 0); !ok || got != true {
		t.Errorf("the twisty said %v", got)
	}
	if got, ok := w.message(head[1], "click", "", 0); !ok || got != "picked" {
		t.Errorf("the row said %v", got)
	}
	if got, ok := w.message(head[1], "toggle", "1", 0); ok && got == "picked" {
		t.Errorf("the row heard a toggle as a pick")
	}
}

func TestPlaceAndSpanSpeakOnlyToAGridOrAStack(t *testing.T) {
	child := UiText([]UiAttr{UiAttrPlace("End", "Center"), UiAttrSpan(2)}, "x")
	in := UiHtml(UiGrid(nil, []UiView{child}))
	out := UiHtml(UiRow(nil, []UiView{child}))
	if !strings.Contains(in, "justify-self:end;align-self:center;") || !strings.Contains(in, "grid-column:span 2;") {
		t.Errorf("in a grid: %s", in)
	}
	if strings.Contains(out, "justify-self") || strings.Contains(out, "grid-column") {
		t.Errorf("in a row: %s", out)
	}
	nested := UiHtml(UiStack(nil, []UiView{UiRow(nil, []UiView{child})}))
	if strings.Contains(nested, "justify-self") {
		t.Errorf("a grandchild of a stack was placed: %s", nested)
	}
}

func TestAStyleAttributeNeverHoldsADoubleQuote(t *testing.T) {
	html := UiHtml(UiColumn([]UiAttr{UiAttrMono(true), UiAttrGradient("Good", UiToneHex("#123"), 1)}, []UiView{
		UiText([]UiAttr{UiAttrWeight(2000), UiAttrLines(3), UiAttrJustify("Between")}, "x"),
	}))
	if strings.Contains(html, `"Cascadia`) || !strings.Contains(html, "'Cascadia Mono'") {
		t.Errorf("a font's name ends the attribute it is in: %s", html)
	}
	if !strings.Contains(html, "font-weight:900;") || !strings.Contains(html, "linear-gradient(147.29578deg,var(--good),#123)") {
		t.Errorf("rendered %s", html)
	}
}
