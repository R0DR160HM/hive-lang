package hive

import "testing"

// **Every event a widget or a scene carries, delivered.** The handlers live off
// the attribute now, behind one pointer, because seven fields only an event ever
// set were seven every `at` and `paint` in a scene paid for. Nothing the page
// renders would show one of them having been dropped on the way.
func TestEveryEventIsDelivered(t *testing.T) {
	for _, c := range []struct {
		name  string
		attr  UiAttr
		kind  string
		value string
		index int
		want  any
	}{
		{"on", UiAttrOn("msg"), "click", "", 0, "msg"},
		{"onPick", UiAttrOnPick(func(n int) any { return n * 2 }), "click", "", 21, 42},
		{"onSort", UiAttrOnSort(func(n int) any { return n + 1 }), "click", "", 6, 7},
		{"onInput", UiAttrOnInput(func(s string) any { return "in:" + s }), "input", "a", 0, "in:a"},
		{"onSubmit", UiAttrOnSubmit(func(s string) any { return "sub:" + s }), "submit", "b", 0, "sub:b"},
		{"onChoose", UiAttrOnChoose(func(s string) any { return "ch:" + s }), "choose", "c", 0, "ch:c"},
		{"onToggle", UiAttrOnToggle(func(b bool) any { return b }), "toggle", "1", 0, true},
		{"onToggle, off", UiAttrOnToggle(func(b bool) any { return b }), "toggle", "", 0, false},
		{"onFrame", UiAttrOnFrame(func(n int) any { return n }), "frame", "", 17, 17},
		{"onRate", UiAttrOnRate(func(n int) any { return n }), "rate", "", 120, 120},
		{"onKeyDown", UiAttrOnKeyDown(func(s string) any { return "d:" + s }), "keydown", "w", 0, "d:w"},
		{"onKeyUp", UiAttrOnKeyUp(func(s string) any { return "u:" + s }), "keyup", "w", 0, "u:w"},
		{"onGrab", UiAttrOnGrab(func(b bool) any { return b }), "grab", "1", 0, true},
		{"onSize", UiAttrOnSize(func(w, h int) any { return w*10000 + h }), "size", "1280,720", 0, 12800720},
	} {
		w := &uiWindow{handlers: map[string][]UiAttr{"h1": {c.attr}}}
		got, ok := w.message("h1", c.kind, c.value, c.index)
		if !ok {
			t.Errorf("%s: nothing was delivered", c.name)
			continue
		}
		if got != c.want {
			t.Errorf("%s: wanted %v, got %v", c.name, c.want, got)
		}
	}
}

// The two that report a pair.
func TestEventsThatReportAPair(t *testing.T) {
	look := UiAttrOnLook(func(x, y float64) any { return x*1000 + y })
	w := &uiWindow{handlers: map[string][]UiAttr{"h1": {look}}}
	if got, ok := w.message("h1", "look", "3,4", 0); !ok || got != 3004.0 {
		t.Errorf("onLook: wanted 3004, got %v (%v)", got, ok)
	}

	pad := UiAttrOnPad(func(n int, control string, at float64) any {
		return control + ":" + string(rune('0'+n)) + ":" + string(rune('0'+int(at)))
	})
	w = &uiWindow{handlers: map[string][]UiAttr{"h1": {pad}}}
	if got, ok := w.message("h1", "pad", "a|1", 2); !ok || got != "a:2:1" {
		t.Errorf("onPad: wanted a:2:1, got %v (%v)", got, ok)
	}
}

// A table borrows the handler off the table and gives each row its own index,
// and an overlay's backdrop carries the dismiss message as a click. Both build
// an attribute by hand rather than taking one whole.
func TestBorrowedHandlers(t *testing.T) {
	v := UiTable([]UiAttr{
		UiAttrOnPick(func(n int) any { return 100 + n }),
		UiAttrOnSort(func(n int) any { return 200 + n }),
	}, [][]string{{"head a", "head b"}, {"one", "two"}, {"three", "four"}})

	r := &uiRender{handlers: map[string][]UiAttr{}}
	r.view(v)
	w := &uiWindow{handlers: r.handlers}

	picks, sorts := map[int]bool{}, map[int]bool{}
	for id, attrs := range r.handlers {
		got, ok := w.message(id, "click", "", attrs[0].Num)
		if !ok {
			t.Fatalf("%s delivered nothing", id)
		}
		if n := got.(int); n >= 200 {
			sorts[n-200] = true
		} else {
			picks[n-100] = true
		}
	}
	if len(sorts) != 2 || !sorts[0] || !sorts[1] {
		t.Errorf("wanted a sort per column, got %v", sorts)
	}
	if len(picks) != 2 || !picks[0] || !picks[1] {
		t.Errorf("wanted a pick per row, got %v", picks)
	}

	o := &uiRender{handlers: map[string][]UiAttr{}}
	o.view(UiOverlay([]UiAttr{UiAttrOnDismiss("shut")}, UiText(nil, "hi")))
	shut := &uiWindow{handlers: o.handlers}
	found := false
	for id := range o.handlers {
		if got, ok := shut.message(id, "click", "", 0); ok && got == "shut" {
			found = true
		}
	}
	if !found {
		t.Error("the backdrop did not carry the dismiss message")
	}
}
