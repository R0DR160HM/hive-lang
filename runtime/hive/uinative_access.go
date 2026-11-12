// What a screen reader is told, whichever platform tells it.
package hive

import (
	"hash/fnv"
	"math"
	"strconv"
	"strings"
)

type uiAccess struct {
	id         int32
	path       string
	role       string
	name       string
	value      string
	help       string
	level      int
	x, y, w, h float64
	focusable  bool
	focused    bool
	disabled   bool
	checked    int
	expanded   int
	selected   bool
	editable   bool
	multiline  bool
	protected  bool
	low, high  float64
	now        float64
	parent     *uiAccess
	kids       []*uiAccess
	box        *uiBox
	part       int
}

func uiAccessId(path string) int32 {
	h := fnv.New32a()
	h.Write([]byte(path))
	return int32(h.Sum32()&0x7fffffff) | 1
}

func (n *uiNative) access() *uiAccess {
	n.layout()
	if n.accessRoot != nil && n.accessStamp == n.stamp {
		return n.accessRoot
	}
	root := &uiAccess{id: uiAccessId("window"), path: "window", role: "window", checked: -1, expanded: -1,
		w: n.vw * n.scale, h: n.vh * n.scale}
	n.accessIds = map[int32]*uiAccess{root.id: root}
	if n.root != nil {
		n.accessWalk(n.root, root)
	}
	for _, l := range n.layers {
		n.accessWalk(l.panel, root)
	}
	if b := n.boxes[n.tip]; b != nil && n.tipDrawn {
		hint, _ := b.attr("hint")
		n.accessAdd(root, &uiAccess{path: n.tip + "/tip", role: "tooltip", name: hint.Word})
	}
	n.accessRoot, n.accessStamp = root, n.stamp
	n.accessBuilt++
	return root
}

func (n *uiNative) accessAdd(parent, node *uiAccess) *uiAccess {
	node.id = uiAccessId(node.path)
	if node.checked == 0 && node.role != "checkbox" {
		node.checked = -1
	}
	if node.role != "combobox" {
		node.expanded = -1
	}
	node.parent = parent
	parent.kids = append(parent.kids, node)
	n.accessIds[node.id] = node
	return node
}

func (n *uiNative) accessBounds(node *uiAccess, b *uiBox) {
	x0, y0, x1, y1 := n.rectOf(b)
	node.x, node.y, node.w, node.h = x0, y0, x1-x0, y1-y0
}

func (n *uiNative) accessWalk(b *uiBox, into *uiAccess) {
	node := n.accessNode(b)
	parent := into
	if node != nil {
		parent = n.accessAdd(into, node)
		n.accessBounds(parent, b)
		if b.kind == "table" {
			n.accessTable(b, parent)
		}
		if p := n.popup; p != nil && p.path == b.path && p.kind == "select" {
			n.accessOptions(b, parent)
		}
	}
	for _, k := range b.kids {
		n.accessWalk(k, parent)
	}
}

func (n *uiNative) accessNode(b *uiBox) *uiAccess {
	node := &uiAccess{path: b.path, box: b, disabled: b.disabled, focusable: b.focusable(), focused: b.path == n.focus,
		checked: 0, expanded: 0}
	if hint, ok := b.attr("hint"); ok {
		node.help = hint.Word
	}
	placeholder, _ := b.attr("placeholder")
	switch b.kind {
	case "text":
		if strings.TrimSpace(b.v.Text) == "" {
			return nil
		}
		node.role, node.name = "text", b.v.Text
		if h, ok := b.attr("heading"); ok && h.Num >= 1 && h.Num <= 6 {
			node.role, node.level = "heading", h.Num
		}
	case "link":
		node.role, node.name = "link", b.v.Text
		if len(b.v.Options) > 0 {
			node.value = uiHref(b.v.Options[0])
		}
	case "button":
		node.role, node.name = "button", b.v.Text
	case "checkbox":
		node.role, node.name = "checkbox", b.v.Text
		if n.checked(b) {
			node.checked = 1
		}
	case "select":
		node.role, node.value = "combobox", n.chosen(b)
		if p := n.popup; p != nil && p.path == b.path {
			node.expanded = 1
		}
	case "input":
		node.name = placeholder.Word
		switch b.input {
		case "Range":
			node.role, node.low, node.high = "slider", 0, 100
			node.now = float64(n.rangeValue(b))
			node.value = strconv.Itoa(n.rangeValue(b))
		case "Date":
			node.role, node.editable = "date", !b.disabled
			if d := n.dates[b.path]; d != nil {
				node.value = d.value()
			}
		default:
			node.role, node.editable = "edit", !b.disabled
			if f := n.fields[b.path]; f != nil {
				node.value = n.numeric(b, f)
			}
			switch b.input {
			case "Password":
				node.role, node.protected, node.value = "password", true, ""
			case "Number":
				node.role = "spin"
			}
		}
	case "textarea":
		node.role, node.name, node.editable, node.multiline = "edit", placeholder.Word, !b.disabled, true
		if f := n.fields[b.path]; f != nil {
			node.value = f.value()
		}
	case "table":
		node.role = "table"
	case "image":
		node.role, node.name = "image", b.alt()
	case "canvas":
		node.role, node.name = "image", node.help
		if node.name == "" {
			var words []string
			for _, m := range b.v.Marks {
				if m.Kind == "words" && m.Text != "" {
					words = append(words, m.Text)
				}
			}
			node.name = strings.Join(words, " ")
		}
	case "spinner":
		node.role, node.name = "progress", node.help
	case "overlay":
		node.role = "dialog"
		if b.row {
			node.role = "group"
		}
	case "row", "column":
		if node.help == "" {
			return nil
		}
		node.role = "group"
	default:
		return nil
	}
	return node
}

func (n *uiNative) accessTable(b *uiBox, table *uiAccess) {
	g := b.grid
	left := b.x + b.padX + b.border
	top := b.y + b.padY + b.border
	at := top
	for r, cells := range g.cells {
		y := at
		if r == 0 {
			y = top + g.stuck
		}
		row := n.accessAdd(table, &uiAccess{path: b.path + "/row" + strconv.Itoa(r), role: "row", box: b, part: -1,
			x: left * n.scale, y: y * n.scale, w: (b.w - 2*b.padX - 2*b.border) * n.scale, h: g.heights[r] * n.scale})
		if r > 0 && g.pickable {
			row.part = r - 1
			row.focusable = !b.disabled
		}
		x := left
		for c := range cells[:g.count[r]] {
			cell := &uiAccess{path: row.path + "/" + strconv.Itoa(c), role: "cell", name: cells[c], box: b, part: -1,
				x: x * n.scale, y: y * n.scale, w: g.cols[c] * n.scale, h: g.heights[r] * n.scale}
			if r == 0 {
				cell.role = "columnheader"
				if g.sortable {
					cell.part = -2 - c
				}
			}
			n.accessAdd(row, cell)
			x += g.cols[c]
		}
		at += g.heights[r]
	}
}

func (n *uiNative) accessOptions(b *uiBox, combo *uiAccess) {
	p := n.popup
	s := n.scale
	list := n.accessAdd(combo, &uiAccess{path: b.path + "/list", role: "list", box: b, part: -1,
		x: p.x * s, y: p.y * s, w: p.w * s, h: p.h * s})
	for i, o := range b.v.Options {
		item := n.accessAdd(list, &uiAccess{path: list.path + "/" + strconv.Itoa(i), role: "listitem", name: o, box: b,
			part: i, selected: i == p.lit, x: p.x * s, y: (p.y + 4 + float64(i-p.top)*p.rowH) * s, w: p.w * s, h: p.rowH * s})
		if i < p.top || i >= p.top+n.popupRows(b) {
			item.h = 0
		}
	}
}

func (n *uiNative) accessFind(id int32) *uiAccess {
	n.access()
	return n.accessIds[id]
}

func (n *uiNative) accessAt(x, y float64) *uiAccess {
	var deepest func(a *uiAccess) *uiAccess
	deepest = func(a *uiAccess) *uiAccess {
		for i := len(a.kids) - 1; i >= 0; i-- {
			k := a.kids[i]
			if x >= k.x && x < k.x+k.w && y >= k.y && y < k.y+k.h {
				if d := deepest(k); d != nil {
					return d
				}
				return k
			}
		}
		return nil
	}
	root := n.access()
	if d := deepest(root); d != nil {
		return d
	}
	return root
}

func (n *uiNative) accessFocused() *uiAccess {
	root := n.access()
	if a := n.accessIds[uiAccessId(n.focus)]; a != nil && n.focus != "" {
		return a
	}
	return root
}

func (n *uiNative) accessAct(id int32, action string) bool {
	a := n.accessFind(id)
	if a == nil || a.box == nil || a.box.disabled {
		return false
	}
	n.touched()
	b := a.box
	switch action {
	case "focus":
		if !b.focusable() {
			return false
		}
		n.focus, n.keyboard, n.blink = b.path, true, true
		return true
	case "press":
		switch {
		case a.role == "listitem":
			n.choose(b, a.part)
			n.popup = nil
		case b.kind == "select" || b.kind == "input" && b.input == "Date":
			if n.popup != nil && n.popup.path == b.path {
				n.popup = nil
			} else {
				n.open(b)
			}
		case b.kind == "table":
			if a.part == -1 {
				return false
			}
			n.activate(b, a.part)
		default:
			n.activate(b, 0)
		}
		return true
	}
	return false
}

func (n *uiNative) accessSet(id int32, value string) bool {
	a := n.accessFind(id)
	if a == nil || a.box == nil || a.box.disabled {
		return false
	}
	n.touched()
	b := a.box
	switch {
	case b.kind == "select":
		for i, o := range b.v.Options {
			if o == value {
				n.choose(b, i)
				return true
			}
		}
	case b.kind == "input" && b.input == "Range":
		v, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err == nil {
			n.setRange(b, int(math.Round(v)))
			return true
		}
	case b.kind == "input" && b.input == "Date":
		if d := n.dates[b.path]; d != nil {
			d.set(value)
			d.sent = ""
			n.dateChanged(b, d)
			return true
		}
	case b.editable():
		if f := n.fields[b.path]; f != nil {
			n.edit(b, f, 0, len(f.text), value)
			return true
		}
	}
	return false
}
