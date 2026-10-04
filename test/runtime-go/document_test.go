package hive

import (
	"math/rand"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// A view from a seed, differing between two seeds the ways a fold differs: text
// that moved, attributes that changed, children that came and went, a widget
// that swapped for another kind.
func spun(rng *rand.Rand, depth int) UiView {
	switch rng.Intn(11) {
	case 0:
		return UiText([]UiAttr{UiAttrSize(UiTextSize("Caption"))},
			"t"+strconv.Itoa(rng.Intn(1000))+" & <x> \"q\" 'a'")
	case 1:
		return UiText([]UiAttr{UiAttrHeading(1 + rng.Intn(6))}, "h"+strconv.Itoa(rng.Intn(50)))
	case 2:
		return UiButton([]UiAttr{UiAttrDisabled(rng.Intn(2) == 0)}, "b"+strconv.Itoa(rng.Intn(20)))
	case 3:
		return UiInput([]UiAttr{UiAttrPlaceholder("p" + strconv.Itoa(rng.Intn(9)))},
			"v"+strconv.Itoa(rng.Intn(99)))
	case 4:
		return UiCheckbox(nil, "c"+strconv.Itoa(rng.Intn(9)), rng.Intn(2) == 0)
	case 5:
		opts := []string{"one", "two", "three"}[:1+rng.Intn(3)]
		return UiSelect(nil, opts, opts[rng.Intn(len(opts))])
	case 6:
		return UiSpacer()
	case 7:
		return UiNone()
	case 8:
		return UiImage(nil, "i"+strconv.Itoa(rng.Intn(5))+".png", "alt & <a>")
	default:
		if depth <= 0 {
			return UiText(nil, "leaf"+strconv.Itoa(rng.Intn(100)))
		}
		kids := make([]UiView, 0, 4)
		for n := rng.Intn(5); n > 0; n-- {
			kids = append(kids, spun(rng, depth-1))
		}
		attrs := []UiAttr{UiAttrGap(rng.Intn(20))}
		if rng.Intn(3) == 0 {
			attrs = append(attrs, UiAttrTone(UiTone("Good")))
		}
		if rng.Intn(2) == 0 {
			return UiRow(attrs, kids)
		}
		return UiColumn(attrs, kids)
	}
}

func drawn(v UiView) string {
	r := &uiRender{}
	r.view(v)
	return r.out.String()
}

// The node an edit names, found in the tree the edit is against.
func nodeAt(nodes []uiDom, path string) (int32, bool) {
	at := int32(0)
	if path == "" {
		return at, true
	}
	for _, part := range strings.Split(path, ".") {
		want, err := strconv.Atoi(part)
		if err != nil {
			return 0, false
		}
		kid := nodes[at].head
		for i := 0; i < want; i++ {
			if kid == 0 {
				return 0, false
			}
			kid = nodes[kid].next
		}
		if kid == 0 {
			return 0, false
		}
		at = kid
	}
	return at, true
}

// **What a difference has to be true of.** An edit carries the whole of the new
// node it names, and no edit is ever emitted inside another, so writing each one
// over the node it names — left to right, since they come in document order —
// has to leave exactly the document the difference was taken to.
//
// It is the whole of the correctness of `uiDocEdits`, and it holds the trees to
// describing the documents they were read from: a tree pointing into the wrong
// string reproduces the wrong page, or none.
func applied(t *testing.T, was string, old []uiDom, edits []uiEdit) string {
	t.Helper()
	var out strings.Builder
	at := 0
	for _, e := range edits {
		i, ok := nodeAt(old, e.path)
		if !ok {
			t.Fatalf("an edit named %q, which the document it is against has not got", e.path)
		}
		if old[i].from < at {
			t.Fatalf("an edit at %q reaches back into one already written", e.path)
		}
		out.WriteString(was[at:old[i].from])
		out.WriteString(e.html)
		at = old[i].to
	}
	out.WriteString(was[at:])
	return out.String()
}

func TestADifferenceRebuildsTheDocument(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	pairs := 0
	for i := 0; i < 500; i++ {
		was := drawn(spun(rng, 4))
		now := drawn(spun(rng, 4))
		if was == now {
			continue
		}
		pairs++
		old := uiScan(was, nil)
		fresh := uiScan(now, nil)
		got := applied(t, was, old, uiDocEdits(was, old, now, fresh))
		if got != now {
			t.Fatalf("pair %d:\n from %s\n want %s\n got  %s", i, was, now, got)
		}
	}
	if pairs < 300 {
		t.Fatalf("only %d pairs differed; the seeds are not exercising this", pairs)
	}
}

// The same, over successive folds of one view rather than unrelated ones, which
// is what a window actually sends.
func TestSuccessiveFoldsRebuildTheDocument(t *testing.T) {
	rows := func(n int, label string) UiView {
		kids := make([]UiView, 0, n+1)
		kids = append(kids, UiText(nil, label))
		for i := 0; i < n; i++ {
			kids = append(kids, UiRow([]UiAttr{UiAttrGap(i % 7)}, []UiView{
				UiText(nil, "row "+strconv.Itoa(i)),
				UiText([]UiAttr{UiAttrTone(UiTone("Good"))}, "value "+strconv.Itoa(i*i)),
			}))
		}
		return UiColumn([]UiAttr{UiAttrPad(8)}, kids)
	}

	was := drawn(rows(40, "first"))
	old := uiScan(was, nil)
	var spare []uiDom
	for _, step := range []struct {
		n     int
		label string
	}{{40, "first"}, {41, "second"}, {90, "third"}, {5, "fourth"}, {5, "fourth"}, {60, "fifth"}} {
		now := drawn(rows(step.n, step.label))
		if now == was {
			continue
		}
		fresh := uiScan(now, spare)
		if got := applied(t, was, old, uiDocEdits(was, old, now, fresh)); got != now {
			t.Fatalf("%s: the difference did not rebuild the document", step.label)
		}
		was, spare, old = now, old, fresh
	}
}

// **A fold that changes nothing leaves the nodes alone with the document.** The
// tree it measured against is then still the live one, and anything recycling it
// has the next scan write over what the next difference is taken from. That read
// the old page with the new page's offsets, and a window crashed on a click.
func TestFoldsThatChangeNothing(t *testing.T) {
	accepted := make(chan NetWsConnection, 4)
	server := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		socket, err := wsAccept(rw, req)
		if err != nil {
			t.Error(err)
			return
		}
		accepted <- NetWsConnection{ws: socket}
		select {}
	}))
	defer server.Close()

	got := NetWsConnect("ws" + strings.TrimPrefix(server.URL, "http") + "/")
	if got.IsError() {
		t.Fatalf("dial: %v", got.Err())
	}
	page := got.Ok()
	w := &uiWindow{
		watchers: map[NetWsConnection]uint32{},
		holding:  map[NetWsConnection]uint32{},
	}
	watching := <-accepted
	w.watchers[watching] = 0
	w.holding[watching] = 0

	view := func(n int, label string) UiView {
		kids := make([]UiView, 0, n+1)
		kids = append(kids, UiText(nil, label))
		for i := 0; i < n; i++ {
			kids = append(kids, UiText([]UiAttr{UiAttrGap(i % 5)}, "row "+strconv.Itoa(i)))
		}
		return UiColumn(nil, kids)
	}

	held := ""
	for _, step := range []struct {
		n     int
		label string
	}{
		{40, "first"}, {40, "first"}, {90, "second"},
		{90, "second"}, {5, "third"}, {5, "third"}, {60, "fourth"},
	} {
		w.publish(view(step.n, step.label))
		if frame := read(t, page); frame != "A" {
			t.Fatalf("a fold answers first, and this said %q", frame)
		}
		w.mu.Lock()
		want := w.html
		w.mu.Unlock()
		if want == held {
			continue
		}
		frame := read(t, page)
		switch frame[0] {
		case 'H':
			if frame[1:] != want {
				t.Fatal("the whole document was not the document")
			}
		case 'P':
			// It is JSON, and it is the difference against what the page holds.
			if !strings.HasPrefix(frame, "P[[") {
				t.Fatalf("a difference wanted edits, got %.40q", frame)
			}
		default:
			t.Fatalf("neither a document nor a difference: %.20q", frame)
		}
		held = want
	}
}

func read(t *testing.T, c NetWsConnection) string {
	t.Helper()
	got := NetWsReceive(c)
	if got.IsError() {
		t.Fatalf("receive: %v", got.Err())
	}
	return got.Ok()
}

func TestAPageCarriesTheTitleItAsksFor(t *testing.T) {
	out := drawn(UiColumn([]UiAttr{UiAttrTitle("a & b")}, nil))
	if !strings.Contains(out, ` data-title="a &amp; b"`) {
		t.Fatalf("the page does not carry its title: %s", out)
	}
}

func TestAWidgetSaysWhichKeysItTakes(t *testing.T) {
	r := &uiRender{handlers: map[string][]UiAttr{}}
	r.view(UiColumn([]UiAttr{UiAttrKeys([]string{"Ctrl+S", "Escape"}), UiAttrOnKey(func(k string) any { return k })}, nil))
	out := r.out.String()
	if !strings.Contains(out, ` data-keys="Ctrl+S Escape"`) || !strings.Contains(out, ` data-h=`) {
		t.Fatalf("the page does not say which keys the widget takes: %s", out)
	}
	for _, attrs := range r.handlers {
		if msg, ok := uiMeaning(attrs, "key", "Ctrl+S", 0); ok && msg == "Ctrl+S" {
			return
		}
	}
	t.Fatal("a key the page reports means nothing")
}

func TestACodeEditorIsItsTextOverItsRuns(t *testing.T) {
	out := drawn(UiCode([]UiAttr{UiAttrNumbers(true), UiAttrCaret(1, 3, 0)}, "ab<c\nd", []UiRun{
		UiInk(0, 2, UiToneHex("#ff0000")), UiShade(1, 3, UiTone("Warn")), UiMarker(1, UiTone("Good")),
	}))
	for _, want := range []string{
		` data-caret="1,3,0"`,
		`<span style="color:#ff0000;">a</span><span style="color:#ff0000;background:var(--warn);">b</span><span style="background:var(--warn);">&lt;</span>c`,
		`1` + "\n" + `<span class="h-mk" style="box-shadow:inset 3px 0 0 var(--good)">2</span>`,
		`<textarea class="h-mono"`,
		">\nab&lt;c\nd</textarea>",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("the editor does not draw %q:\n%s", want, out)
		}
	}
}

func TestAnElementSaysWhichOfThePointersEventsItHears(t *testing.T) {
	r := &uiRender{handlers: map[string][]UiAttr{}}
	r.view(UiColumn(nil, []UiView{
		UiRow([]UiAttr{UiAttrOnMenu("m"), UiAttrOnDrag(func(int, int, bool) any { return nil })}, nil),
		UiOverlay([]UiAttr{UiAttrAnchor(UiAnchor("Caret")), UiAttrOnDismiss("d")}, UiText(nil, "x")),
	}))
	out := r.out.String()
	for _, want := range []string{` data-ev="menu drag"`, `class="h-backdrop h-pinned h-anchored" data-anchor="Caret" data-h=`} {
		if !strings.Contains(out, want) {
			t.Fatalf("the page does not say %q:\n%s", want, out)
		}
	}
	for _, attrs := range r.handlers {
		if msg, ok := uiMeaning(attrs, "drag", "3,-4,1", 0); ok && msg == nil {
			return
		}
	}
	t.Fatal("a drag means nothing")
}

func TestAButtonInItsOwnColourHasNoEdgeUnlessItAsks(t *testing.T) {
	plain := drawn(UiButton([]UiAttr{UiAttrBackground(UiToneHex("#2a2e36")), UiAttrRadius(4), UiAttrRing(false)}, "Run"))
	for _, want := range []string{"border-color:transparent;", "border-radius:4px;", " h-noring"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("the button does not say %q: %s", want, plain)
		}
	}
	edged := drawn(UiInput([]UiAttr{UiAttrBackground(UiToneHex("#22252c")), UiAttrBorder(1), UiAttrBorderTone(UiToneHex("#333333"))}, ""))
	if strings.Contains(edged, "transparent") || !strings.Contains(edged, "border-width:1px;border-style:solid;") || !strings.Contains(edged, "border-color:#333333;") {
		t.Fatalf("the field lost the edge it asked for: %s", edged)
	}
}

func TestAnEditorsNotesFollowTheirLineAndAreNotItsText(t *testing.T) {
	out := drawn(UiCode(nil, "ab\ncd\nef", []UiRun{UiBand(1, UiToneHex("#ff000024")), UiNote(1, "erro <aqui>", UiTone("Danger"))}))
	if !strings.Contains(out, `<span class="h-band" style="top:calc(8px + 1 * 1.5em);background:#ff000024"></span>`) {
		t.Fatalf("no band behind line 1: %s", out)
	}
	if !strings.Contains(out, "ab\ncd<span class=\"h-note\" data-note=\"erro &lt;aqui&gt;\" style=\"color:var(--danger)\"></span>\nef") {
		t.Fatalf("the note is not at the end of line 1: %s", out)
	}
}
