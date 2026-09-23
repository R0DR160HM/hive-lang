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
