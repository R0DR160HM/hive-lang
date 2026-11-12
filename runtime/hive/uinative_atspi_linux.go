// AT-SPI, which is how a screen reader on Linux reads the window.

//go:build linux && !android

package hive

import (
	"os"
	"strconv"
	"strings"
	"unicode"
)

const (
	uixA11yPrefix = "/org/a11y/atspi/accessible/"
	uixA11yRoot   = "/org/a11y/atspi/accessible/root"
	uixA11yNull   = "/org/a11y/atspi/null"
)

type uixA11y struct {
	w         *uixWindow
	bus       *uixBus
	desktop   []any
	id        int32
	listeners int
	built     uint64
	focus     int32
	active    bool
	seen      map[int32]uixSeen
}

type uixSeen struct {
	parent   int32
	index    int
	name     string
	value    string
	checked  int
	expanded int
}

type uixRole struct {
	code uint32
	name string
}

var uixRoles = map[string]uixRole{
	"window": {23, "frame"}, "text": {29, "label"}, "heading": {83, "heading"}, "link": {88, "link"},
	"button": {43, "push button"}, "checkbox": {7, "check box"}, "combobox": {11, "combo box"},
	"edit": {79, "entry"}, "password": {40, "password text"}, "spin": {52, "spin button"},
	"date": {12, "date editor"}, "slider": {51, "slider"}, "table": {55, "table"}, "row": {90, "table row"},
	"cell": {56, "table cell"}, "columnheader": {57, "table column header"}, "image": {27, "image"},
	"progress": {42, "progress bar"}, "dialog": {16, "dialog"}, "group": {39, "panel"},
	"list": {98, "list box"}, "listitem": {32, "list item"}, "tooltip": {64, "tool tip"},
}

func uixRoleOf(node *uiAccess) uixRole {
	if node.role == "edit" && node.multiline {
		return uixRole{61, "text"}
	}
	if r, ok := uixRoles[node.role]; ok {
		return r
	}
	return uixRole{67, "unknown"}
}

func uixConnectA11y(w *uixWindow, address string) {
	if address == "" {
		address = os.Getenv("AT_SPI_BUS_ADDRESS")
	}
	if address == "" {
		session := os.Getenv("DBUS_SESSION_BUS_ADDRESS")
		if session == "" {
			return
		}
		s, err := uixBusDial(session, nil)
		if err != nil {
			return
		}
		reply, err := s.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", "")
		s.close()
		found, ok := uixString(reply, 0)
		if err != nil || !ok || found == "" {
			return
		}
		address = found
	}
	a := &uixA11y{w: w, seen: map[int32]uixSeen{}, listeners: 1}
	bus, err := uixBusDial(address, a.heard)
	if err != nil {
		return
	}
	a.bus = bus
	reply, err := bus.call("org.a11y.atspi.Registry", uixA11yRoot, "org.a11y.atspi.Socket", "Embed", "(so)",
		[]any{bus.name, uixA11yRoot})
	if err != nil {
		bus.close()
		return
	}
	if len(reply) > 0 {
		a.desktop, _ = reply[0].([]any)
	}
	bus.match("type='signal',interface='org.a11y.atspi.Registry'")
	if events, err := bus.call("org.a11y.atspi.Registry", "/org/a11y/atspi/registry", "org.a11y.atspi.Registry",
		"GetRegisteredEvents", ""); err == nil && len(events) > 0 {
		list, _ := events[0].([]any)
		a.listeners = len(list)
	}
	w.post(func() { w.a11y = a })
}

func (a *uixA11y) heard(m *uixMsg) {
	switch {
	case m.kind == uixSignal && m.iface == "org.a11y.atspi.Registry":
		switch m.member {
		case "EventListenerRegistered":
			a.w.post(func() { a.listeners++ })
		case "EventListenerDeregistered":
			a.w.post(func() { a.listeners = max(a.listeners-1, 0) })
		}
	case m.kind == uixCall:
		go a.serve(m)
	}
}

type uixAnswer struct {
	sig    string
	body   []any
	failed string
}

func (a *uixA11y) serve(m *uixMsg) {
	var out uixAnswer
	if !a.w.do(func() { out = a.answer(m) }) {
		a.bus.fail(m, "org.freedesktop.DBus.Error.Failed", "the window did not answer")
		return
	}
	if out.failed != "" {
		a.bus.fail(m, out.failed, m.member)
		return
	}
	a.bus.reply(m, out.sig, out.body...)
}

func uixAnswered(sig string, body ...any) uixAnswer { return uixAnswer{sig: sig, body: body} }

var uixUnknown = uixAnswer{failed: "org.freedesktop.DBus.Error.UnknownMethod"}

func (a *uixA11y) path(node *uiAccess) string {
	if node == nil {
		return uixA11yNull
	}
	return uixA11yPrefix + strconv.Itoa(int(node.id))
}

func (a *uixA11y) ref(node *uiAccess) []any {
	if node == nil {
		return []any{"", uixA11yNull}
	}
	return []any{a.bus.name, a.path(node)}
}

func (a *uixA11y) appRef() []any { return []any{a.bus.name, uixA11yRoot} }

func (a *uixA11y) answer(m *uixMsg) uixAnswer {
	switch {
	case m.iface == "org.freedesktop.DBus.Introspectable":
		return uixAnswered("s", "<node/>")
	case m.iface == "org.a11y.atspi.Cache" && m.member == "GetItems":
		return uixAnswered("a((so)(so)(so)iiassusau)", []any{})
	}
	if m.path == uixA11yRoot {
		return a.application(m)
	}
	id, err := strconv.Atoi(strings.TrimPrefix(m.path, uixA11yPrefix))
	node := a.w.n.accessFind(int32(id))
	if err != nil || !strings.HasPrefix(m.path, uixA11yPrefix) || node == nil {
		return uixAnswer{failed: "org.freedesktop.DBus.Error.UnknownObject"}
	}
	switch m.iface {
	case "org.freedesktop.DBus.Properties":
		return a.properties(m, node)
	case "org.a11y.atspi.Accessible":
		return a.accessible(m, node)
	case "org.a11y.atspi.Component":
		return a.component(m, node)
	case "org.a11y.atspi.Action":
		return a.action(m, node)
	case "org.a11y.atspi.Text":
		return a.text(m, node)
	case "org.a11y.atspi.EditableText":
		return a.editable(m, node)
	}
	return uixUnknown
}

func (a *uixA11y) application(m *uixMsg) uixAnswer {
	frame := a.w.n.access()
	switch m.iface + "." + m.member {
	case "org.freedesktop.DBus.Properties.Get":
		iface, _ := uixString(m.body, 0)
		name, _ := uixString(m.body, 1)
		if v, ok := a.appProperty(iface, name, frame); ok {
			return uixAnswered("v", v)
		}
		return uixAnswer{failed: "org.freedesktop.DBus.Error.UnknownProperty"}
	case "org.freedesktop.DBus.Properties.GetAll":
		iface, _ := uixString(m.body, 0)
		var all []any
		for _, name := range []string{"Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId",
			"ToolkitName", "Version", "AtspiVersion", "Id"} {
			if v, ok := a.appProperty(iface, name, frame); ok {
				all = append(all, []any{name, v})
			}
		}
		return uixAnswered("a{sv}", all)
	case "org.freedesktop.DBus.Properties.Set":
		if name, _ := uixString(m.body, 1); name == "Id" && len(m.body) > 2 {
			if v, ok := m.body[2].(uixVariant); ok {
				a.id = int32(uixNumber(v.v))
			}
		}
		return uixAnswered("")
	case "org.a11y.atspi.Accessible.GetChildAtIndex":
		if i := int(uixNumber(m.body[0])); i == 0 {
			return uixAnswered("(so)", a.ref(frame))
		}
		return uixAnswered("(so)", a.ref(nil))
	case "org.a11y.atspi.Accessible.GetChildren":
		return uixAnswered("a(so)", []any{a.ref(frame)})
	case "org.a11y.atspi.Accessible.GetIndexInParent":
		return uixAnswered("i", int32(-1))
	case "org.a11y.atspi.Accessible.GetRelationSet":
		return uixAnswered("a(ua(so))", []any{})
	case "org.a11y.atspi.Accessible.GetRole":
		return uixAnswered("u", uint32(75))
	case "org.a11y.atspi.Accessible.GetRoleName", "org.a11y.atspi.Accessible.GetLocalizedRoleName":
		return uixAnswered("s", "application")
	case "org.a11y.atspi.Accessible.GetState":
		return uixAnswered("au", []any{uint32(0), uint32(0)})
	case "org.a11y.atspi.Accessible.GetAttributes":
		return uixAnswered("a{ss}", []any{[]any{"toolkit", "hive"}})
	case "org.a11y.atspi.Accessible.GetApplication":
		return uixAnswered("(so)", a.appRef())
	case "org.a11y.atspi.Accessible.GetInterfaces":
		return uixAnswered("as", []string{"org.a11y.atspi.Accessible", "org.a11y.atspi.Application"})
	case "org.a11y.atspi.Application.GetLocale":
		return uixAnswered("s", uixLocale())
	}
	return uixUnknown
}

func (a *uixA11y) appProperty(iface, name string, frame *uiAccess) (uixVariant, bool) {
	switch name {
	case "Name":
		return uixVariant{"s", uiAppName()}, true
	case "Description", "AccessibleId", "HelpText":
		return uixVariant{"s", ""}, true
	case "Parent":
		if len(a.desktop) == 2 {
			return uixVariant{"(so)", a.desktop}, true
		}
		return uixVariant{"(so)", []any{"org.a11y.atspi.Registry", uixA11yRoot}}, true
	case "ChildCount":
		return uixVariant{"i", int32(1)}, true
	case "Locale":
		return uixVariant{"s", uixLocale()}, true
	case "ToolkitName":
		return uixVariant{"s", "hive"}, true
	case "Version":
		return uixVariant{"s", "1"}, true
	case "AtspiVersion":
		return uixVariant{"s", "2.1"}, true
	case "Id":
		return uixVariant{"i", a.id}, true
	}
	return uixVariant{}, false
}

func uixLocale() string {
	for _, name := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if v := os.Getenv(name); v != "" {
			return strings.SplitN(v, ".", 2)[0]
		}
	}
	return "C"
}

func (a *uixA11y) parentRef(node *uiAccess) []any {
	if node.parent == nil {
		return a.appRef()
	}
	return a.ref(node.parent)
}

func uixIndexIn(node *uiAccess) int32 {
	if node.parent == nil {
		return 0
	}
	for i, k := range node.parent.kids {
		if k == node {
			return int32(i)
		}
	}
	return -1
}

func (a *uixA11y) states(node *uiAccess) []any {
	var bits uint64
	set := func(s uint) { bits |= 1 << s }
	if !node.disabled {
		set(8)
		set(24)
	}
	if node.w > 0 && node.h > 0 {
		set(30)
		set(25)
	}
	if node.focusable {
		set(11)
	}
	if node.focused {
		set(12)
	}
	switch node.role {
	case "window":
		set(21)
		if a.w.focused {
			set(1)
		}
	case "checkbox":
		set(41)
		if node.checked == 1 {
			set(4)
		}
	case "combobox":
		set(9)
		set(42)
		if node.expanded == 1 {
			set(10)
		} else {
			set(5)
		}
	case "listitem":
		set(22)
		if node.selected {
			set(23)
		}
	case "progress":
		set(3)
		set(32)
	case "slider":
		set(14)
	case "dialog":
		set(16)
	}
	if node.editable {
		set(7)
		set(38)
		if node.multiline {
			set(17)
		} else {
			set(26)
		}
	}
	return []any{uint32(bits), uint32(bits >> 32)}
}

func (a *uixA11y) interfaces(node *uiAccess) []string {
	out := []string{"org.a11y.atspi.Accessible", "org.a11y.atspi.Component"}
	if _, ok := uixPressName(node); ok {
		out = append(out, "org.a11y.atspi.Action")
	}
	if uixValued(node) {
		out = append(out, "org.a11y.atspi.Value")
	}
	if node.role != "window" && node.role != "table" && node.role != "row" && node.role != "group" &&
		node.role != "dialog" && node.role != "list" && node.role != "image" && node.role != "progress" &&
		node.role != "slider" {
		out = append(out, "org.a11y.atspi.Text")
	}
	if node.editable {
		out = append(out, "org.a11y.atspi.EditableText")
	}
	return out
}

func uixValued(node *uiAccess) bool { return node.role == "slider" || node.role == "spin" }

func uixPressName(node *uiAccess) (string, bool) {
	if node.box == nil || node.disabled {
		return "", false
	}
	switch node.role {
	case "button", "link", "listitem":
		return "click", true
	case "checkbox":
		return "toggle", true
	case "combobox", "date":
		return "press", true
	case "row", "columnheader":
		return "click", node.part != -1
	}
	return "", false
}

func (a *uixA11y) name(node *uiAccess) string {
	switch {
	case node.role == "window" && node.name == "":
		return a.w.title
	case node.role == "combobox" && node.name == "":
		return node.value
	}
	return node.name
}

func (a *uixA11y) property(node *uiAccess, iface, name string) (uixVariant, bool) {
	switch name {
	case "Name":
		return uixVariant{"s", a.name(node)}, true
	case "Description", "HelpText":
		return uixVariant{"s", node.help}, true
	case "Parent":
		return uixVariant{"(so)", a.parentRef(node)}, true
	case "ChildCount":
		return uixVariant{"i", int32(len(node.kids))}, true
	case "Locale":
		return uixVariant{"s", uixLocale()}, true
	case "AccessibleId":
		return uixVariant{"s", node.path}, true
	case "NActions":
		if _, ok := uixPressName(node); ok {
			return uixVariant{"i", int32(1)}, true
		}
		return uixVariant{"i", int32(0)}, true
	case "CharacterCount":
		return uixVariant{"i", int32(len([]rune(a.content(node))))}, true
	case "CaretOffset":
		return uixVariant{"i", a.caret(node)}, true
	}
	if uixValued(node) {
		value, _ := strconv.ParseFloat(node.value, 64)
		switch name {
		case "MinimumValue":
			if node.role == "spin" {
				return uixVariant{"d", -1e300}, true
			}
			return uixVariant{"d", node.low}, true
		case "MaximumValue":
			if node.role == "spin" {
				return uixVariant{"d", 1e300}, true
			}
			return uixVariant{"d", node.high}, true
		case "MinimumIncrement":
			return uixVariant{"d", 1.0}, true
		case "CurrentValue":
			return uixVariant{"d", value}, true
		case "Text":
			return uixVariant{"s", node.value}, true
		}
	}
	return uixVariant{}, false
}

func (a *uixA11y) properties(m *uixMsg, node *uiAccess) uixAnswer {
	iface, _ := uixString(m.body, 0)
	switch m.member {
	case "Get":
		name, _ := uixString(m.body, 1)
		if v, ok := a.property(node, iface, name); ok {
			return uixAnswered("v", v)
		}
		return uixAnswer{failed: "org.freedesktop.DBus.Error.UnknownProperty"}
	case "GetAll":
		var names []string
		switch iface {
		case "org.a11y.atspi.Accessible":
			names = []string{"Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText"}
		case "org.a11y.atspi.Action":
			names = []string{"NActions"}
		case "org.a11y.atspi.Text":
			names = []string{"CharacterCount", "CaretOffset"}
		case "org.a11y.atspi.Value":
			names = []string{"MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text"}
		}
		var all []any
		for _, name := range names {
			if v, ok := a.property(node, iface, name); ok {
				all = append(all, []any{name, v})
			}
		}
		return uixAnswered("a{sv}", all)
	case "Set":
		name, _ := uixString(m.body, 1)
		if name == "CurrentValue" && len(m.body) > 2 {
			if v, ok := m.body[2].(uixVariant); ok {
				f, _ := v.v.(float64)
				a.w.n.accessSet(node.id, strconv.FormatFloat(f, 'f', -1, 64))
				a.w.dirty = true
			}
		}
		return uixAnswered("")
	}
	return uixUnknown
}

func (a *uixA11y) accessible(m *uixMsg, node *uiAccess) uixAnswer {
	role := uixRoleOf(node)
	switch m.member {
	case "GetChildAtIndex":
		i := int(uixNumber(m.body[0]))
		if i >= 0 && i < len(node.kids) {
			return uixAnswered("(so)", a.ref(node.kids[i]))
		}
		return uixAnswered("(so)", a.ref(nil))
	case "GetChildren":
		kids := make([]any, len(node.kids))
		for i, k := range node.kids {
			kids[i] = a.ref(k)
		}
		return uixAnswered("a(so)", kids)
	case "GetIndexInParent":
		return uixAnswered("i", uixIndexIn(node))
	case "GetRelationSet":
		return uixAnswered("a(ua(so))", []any{})
	case "GetRole":
		return uixAnswered("u", role.code)
	case "GetRoleName", "GetLocalizedRoleName":
		return uixAnswered("s", role.name)
	case "GetState":
		return uixAnswered("au", a.states(node))
	case "GetAttributes":
		attrs := []any{[]any{"toolkit", "hive"}}
		if node.level > 0 {
			attrs = append(attrs, []any{"level", strconv.Itoa(node.level)})
		}
		return uixAnswered("a{ss}", attrs)
	case "GetApplication":
		return uixAnswered("(so)", a.appRef())
	case "GetInterfaces":
		return uixAnswered("as", a.interfaces(node))
	}
	return uixUnknown
}

func (a *uixA11y) extents(node *uiAccess, coords uint32) (int32, int32, int32, int32) {
	x, y := node.x, node.y
	switch coords {
	case 0:
		ox, oy := a.w.originOnRoot()
		x, y = x+float64(ox), y+float64(oy)
	case 2:
		if node.parent != nil {
			x, y = x-node.parent.x, y-node.parent.y
		}
	}
	return int32(x), int32(y), int32(node.w), int32(node.h)
}

func (a *uixA11y) component(m *uixMsg, node *uiAccess) uixAnswer {
	n := a.w.n
	coords := func(at int) uint32 {
		if at < len(m.body) {
			return uint32(uixNumber(m.body[at]))
		}
		return 0
	}
	switch m.member {
	case "GetExtents":
		x, y, w, h := a.extents(node, coords(0))
		return uixAnswered("(iiii)", []any{x, y, w, h})
	case "GetPosition":
		x, y, _, _ := a.extents(node, coords(0))
		return uixAnswered("ii", x, y)
	case "GetSize":
		_, _, w, h := a.extents(node, 1)
		return uixAnswered("ii", w, h)
	case "Contains", "GetAccessibleAtPoint":
		px, py := float64(int32(uixNumber(m.body[0]))), float64(int32(uixNumber(m.body[1])))
		if coords(2) == 0 {
			ox, oy := a.w.originOnRoot()
			px, py = px-float64(ox), py-float64(oy)
		}
		if m.member == "Contains" {
			return uixAnswered("b", px >= node.x && px < node.x+node.w && py >= node.y && py < node.y+node.h)
		}
		hit := n.accessAt(px, py)
		for at := hit; at != nil; at = at.parent {
			if at == node {
				return uixAnswered("(so)", a.ref(hit))
			}
		}
		return uixAnswered("(so)", a.ref(nil))
	case "GetLayer":
		if node.role == "window" {
			return uixAnswered("u", uint32(7))
		}
		return uixAnswered("u", uint32(3))
	case "GetMDIZOrder":
		return uixAnswered("n", int16(0))
	case "GrabFocus":
		ok := n.accessAct(node.id, "focus")
		a.w.dirty = true
		return uixAnswered("b", ok)
	case "GetAlpha":
		return uixAnswered("d", 1.0)
	case "ScrollTo", "ScrollToPoint":
		return uixAnswered("b", true)
	case "SetExtents", "SetPosition", "SetSize":
		return uixAnswered("b", false)
	}
	return uixUnknown
}

func (a *uixA11y) action(m *uixMsg, node *uiAccess) uixAnswer {
	name, ok := uixPressName(node)
	switch m.member {
	case "GetActions":
		if !ok {
			return uixAnswered("a(sss)", []any{})
		}
		return uixAnswered("a(sss)", []any{[]any{name, "", ""}})
	case "GetName", "GetLocalizedName":
		return uixAnswered("s", name)
	case "GetDescription", "GetKeyBinding":
		return uixAnswered("s", "")
	case "DoAction":
		done := ok && a.w.n.accessAct(node.id, "press")
		a.w.dirty = true
		return uixAnswered("b", done)
	}
	return uixUnknown
}

func (a *uixA11y) content(node *uiAccess) string {
	if node.editable || node.role == "password" || node.role == "date" {
		return node.value
	}
	return a.name(node)
}

func (a *uixA11y) caret(node *uiAccess) int32 {
	if node.box != nil && node.focused {
		if f := a.w.n.fields[node.box.path]; f != nil {
			return int32(f.caret)
		}
	}
	return 0
}

func uixSpan(text []rune, at int, kind uint32) (int, int) {
	at = max(0, min(at, len(text)))
	switch kind {
	case 0:
		return at, min(at+1, len(text))
	case 1, 2:
		start, end := at, at
		for start > 0 && !unicode.IsSpace(text[start-1]) {
			start--
		}
		for end < len(text) && !unicode.IsSpace(text[end]) {
			end++
		}
		for end < len(text) && unicode.IsSpace(text[end]) && kind == 1 {
			end++
		}
		return start, end
	}
	start, end := at, at
	for start > 0 && text[start-1] != '\n' {
		start--
	}
	for end < len(text) && text[end] != '\n' {
		end++
	}
	if end < len(text) {
		end++
	}
	return start, end
}

func (a *uixA11y) text(m *uixMsg, node *uiAccess) uixAnswer {
	text := []rune(a.content(node))
	clampRange := func(from, to int) (int, int) {
		if to < 0 || to > len(text) {
			to = len(text)
		}
		from = max(0, min(from, to))
		return from, to
	}
	num := func(i int) int {
		if i < len(m.body) {
			return int(int32(uixNumber(m.body[i])))
		}
		return 0
	}
	switch m.member {
	case "GetText":
		from, to := clampRange(num(0), num(1))
		return uixAnswered("s", string(text[from:to]))
	case "GetCharacterAtOffset":
		if at := num(0); at >= 0 && at < len(text) {
			return uixAnswered("i", int32(text[at]))
		}
		return uixAnswered("i", int32(0))
	case "GetTextAtOffset", "GetTextBeforeOffset", "GetTextAfterOffset":
		at, kind := num(0), uint32(num(1))
		from, to := uixSpan(text, at, kind)
		switch m.member {
		case "GetTextBeforeOffset":
			if from > 0 {
				from, to = uixSpan(text, from-1, kind)
			} else {
				from, to = 0, 0
			}
		case "GetTextAfterOffset":
			if to < len(text) {
				from, to = uixSpan(text, to, kind)
			} else {
				from, to = len(text), len(text)
			}
		}
		return uixAnswered("sii", string(text[from:to]), int32(from), int32(to))
	case "GetStringAtOffset":
		kinds := map[int]uint32{0: 0, 1: 1, 2: 5, 3: 5, 4: 5}
		from, to := uixSpan(text, num(0), kinds[num(1)])
		return uixAnswered("sii", string(text[from:to]), int32(from), int32(to))
	case "GetNSelections":
		if from, to := a.selection(node); from != to {
			return uixAnswered("i", int32(1))
		}
		return uixAnswered("i", int32(0))
	case "GetSelection":
		from, to := a.selection(node)
		return uixAnswered("ii", int32(from), int32(to))
	case "SetCaretOffset", "SetSelection", "AddSelection":
		f := a.field(node)
		if f == nil {
			return uixAnswered("b", false)
		}
		from, to := num(0), num(0)
		switch m.member {
		case "SetSelection":
			from, to = num(1), num(2)
		case "AddSelection":
			from, to = num(0), num(1)
		}
		from, to = clampRange(from, to)
		f.anchor, f.caret = min(from, len(f.text)), min(to, len(f.text))
		a.w.dirty = true
		return uixAnswered("b", true)
	case "RemoveSelection":
		if f := a.field(node); f != nil {
			f.anchor = f.caret
			a.w.dirty = true
		}
		return uixAnswered("b", true)
	case "GetCharacterExtents":
		x, y, w, h := a.extents(node, uint32(num(1)))
		return uixAnswered("iiii", x, y, w, h)
	case "GetRangeExtents":
		x, y, w, h := a.extents(node, uint32(num(2)))
		return uixAnswered("(iiii)", []any{x, y, w, h})
	case "GetOffsetAtPoint":
		return uixAnswered("i", int32(0))
	case "GetAttributes", "GetAttributeRun":
		return uixAnswered("a{ss}ii", []any{}, int32(0), int32(len(text)))
	case "GetDefaultAttributes":
		return uixAnswered("a{ss}", []any{})
	case "GetDefaultAttributeSet":
		return uixAnswered("as", []string{})
	case "GetAttributeValue":
		return uixAnswered("s", "")
	case "GetBoundedRanges":
		return uixAnswered("a(iisv)", []any{})
	}
	return uixUnknown
}

func (a *uixA11y) field(node *uiAccess) *uiEntry {
	if node.box == nil || !node.editable {
		return nil
	}
	return a.w.n.fields[node.box.path]
}

func (a *uixA11y) selection(node *uiAccess) (int, int) {
	if f := a.field(node); f != nil && node.focused {
		return min(f.caret, f.anchor), max(f.caret, f.anchor)
	}
	return 0, 0
}

func (a *uixA11y) editable(m *uixMsg, node *uiAccess) uixAnswer {
	n := a.w.n
	text := []rune(node.value)
	num := func(i int) int {
		if i < len(m.body) {
			return max(0, min(int(int32(uixNumber(m.body[i]))), len(text)))
		}
		return 0
	}
	set := func(value string) uixAnswer {
		ok := node.editable && n.accessSet(node.id, value)
		a.w.dirty = true
		return uixAnswered("b", ok)
	}
	switch m.member {
	case "SetTextContents":
		value, _ := uixString(m.body, 0)
		return set(value)
	case "InsertText":
		at := num(0)
		insert, _ := uixString(m.body, 1)
		return set(string(text[:at]) + insert + string(text[at:]))
	case "DeleteText", "CutText":
		from, to := num(0), num(1)
		from, to = min(from, to), max(from, to)
		if m.member == "CutText" {
			a.w.setClipboard(string(text[from:to]))
		}
		return set(string(text[:from]) + string(text[to:]))
	case "CopyText":
		from, to := num(0), num(1)
		a.w.setClipboard(string(text[min(from, to):max(from, to)]))
		return uixAnswered("")
	case "PasteText":
		at := num(0)
		return set(string(text[:at]) + a.w.clipboard() + string(text[at:]))
	}
	return uixUnknown
}

func (a *uixA11y) emit(node *uiAccess, member, kind string, d1, d2 int32, v uixVariant) {
	a.bus.signal(a.path(node), "org.a11y.atspi.Event.Object", member, "siiva{sv}", kind, d1, d2, v, []any{})
}

func (a *uixA11y) notice() {
	n := a.w.n
	if a.listeners == 0 {
		return
	}
	root := n.access()
	if active := a.w.focused; active != a.active {
		a.active = active
		member := "Deactivate"
		if active {
			member = "Activate"
		}
		a.bus.signal(a.path(root), "org.a11y.atspi.Event.Window", member, "siiva{sv}", "", int32(0), int32(0),
			uixVariant{"i", int32(0)}, []any{})
	}
	if n.accessBuilt == a.built {
		return
	}
	a.built = n.accessBuilt
	now := map[int32]uixSeen{}
	nodes := map[int32]*uiAccess{}
	var order []*uiAccess
	var walk func(node *uiAccess)
	walk = func(node *uiAccess) {
		seen := uixSeen{index: int(uixIndexIn(node)), name: a.name(node), value: node.value, checked: node.checked,
			expanded: node.expanded}
		if node.parent != nil {
			seen.parent = node.parent.id
		}
		now[node.id] = seen
		nodes[node.id] = node
		order = append(order, node)
		for _, k := range node.kids {
			walk(k)
		}
	}
	walk(root)
	first := len(a.seen) == 0
	told := 0
	for id, was := range a.seen {
		if _, ok := now[id]; ok || told > 64 {
			continue
		}
		if parent := nodes[was.parent]; parent != nil {
			a.emit(parent, "ChildrenChanged", "remove", int32(was.index), 0,
				uixVariant{"(so)", []any{a.bus.name, uixA11yPrefix + strconv.Itoa(int(id))}})
			told++
		}
	}
	for _, node := range order {
		is, was := now[node.id], a.seen[node.id]
		_, had := a.seen[node.id]
		switch {
		case first:
		case !had:
			if node.parent != nil && told <= 64 {
				a.emit(node.parent, "ChildrenChanged", "add", int32(is.index), 0, uixVariant{"(so)", a.ref(node)})
				told++
			}
		default:
			if is.name != was.name {
				a.emit(node, "PropertyChange", "accessible-name", 0, 0, uixVariant{"s", is.name})
			}
			if is.value != was.value {
				a.valueChanged(node, was.value, is.value)
			}
			if is.checked != was.checked {
				a.emit(node, "StateChanged", "checked", int32(max(is.checked, 0)), 0, uixVariant{"i", int32(0)})
			}
			if is.expanded != was.expanded {
				a.emit(node, "StateChanged", "expanded", int32(max(is.expanded, 0)), 0, uixVariant{"i", int32(0)})
			}
		}
	}
	a.seen = now
	focused := n.accessFocused()
	if focused.id != a.focus {
		if old := nodes[a.focus]; old != nil {
			a.emit(old, "StateChanged", "focused", 0, 0, uixVariant{"i", int32(0)})
		}
		a.emit(focused, "StateChanged", "focused", 1, 0, uixVariant{"i", int32(0)})
		a.bus.signal(a.path(focused), "org.a11y.atspi.Event.Focus", "Focus", "siiva{sv}", "", int32(0), int32(0),
			uixVariant{"i", int32(0)}, []any{})
		a.focus = focused.id
	}
}

func (a *uixA11y) valueChanged(node *uiAccess, was, is string) {
	if uixValued(node) && !node.editable || node.role == "slider" || node.role == "combobox" {
		a.emit(node, "PropertyChange", "accessible-value", 0, 0, uixVariant{"s", is})
		return
	}
	if !node.editable {
		return
	}
	old, now := []rune(was), []rune(is)
	start := 0
	for start < len(old) && start < len(now) && old[start] == now[start] {
		start++
	}
	endOld, endNow := len(old), len(now)
	for endOld > start && endNow > start && old[endOld-1] == now[endNow-1] {
		endOld--
		endNow--
	}
	if endOld > start {
		a.emit(node, "TextChanged", "delete", int32(start), int32(endOld-start), uixVariant{"s", string(old[start:endOld])})
	}
	if endNow > start {
		a.emit(node, "TextChanged", "insert", int32(start), int32(endNow-start), uixVariant{"s", string(now[start:endNow])})
	}
}
