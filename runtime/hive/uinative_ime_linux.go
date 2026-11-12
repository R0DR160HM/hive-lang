// Input methods, through Fcitx or IBus.

//go:build linux && !android

package hive

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

type uixIME struct {
	bus     *uixBus
	dest    string
	path    string
	iface   string
	fcitx   bool
	focused bool
	spot    [4]int32
}

const uixIBusRelease = 1 << 30

func uixConnectIME(w *uixWindow) {
	var ime *uixIME
	if address := os.Getenv("DBUS_SESSION_BUS_ADDRESS"); address != "" {
		ime = uixFcitx(w, address)
	}
	if ime == nil {
		ime = uixIBus(w)
	}
	if ime != nil {
		w.post(func() { w.ime = ime })
	}
}

func uixFcitx(w *uixWindow, address string) *uixIME {
	ime := &uixIME{fcitx: true, iface: "org.fcitx.Fcitx.InputContext1"}
	bus, err := uixBusDial(address, func(m *uixMsg) { ime.heard(w, m) })
	if err != nil {
		return nil
	}
	for _, at := range [][2]string{{"org.fcitx.Fcitx5", "/inputmethod"}, {"org.freedesktop.portal.Fcitx", "/org/freedesktop/portal/inputmethod"}} {
		if !bus.owned(at[0]) {
			continue
		}
		reply, err := bus.call(at[0], at[1], "org.fcitx.Fcitx.InputMethod1", "CreateInputContext", "a(ss)",
			[]any{[]any{"program", uiAppName()}, []any{"display", "x11:" + os.Getenv("DISPLAY")}})
		if path, ok := uixString(reply, 0); err == nil && ok {
			ime.bus, ime.dest, ime.path = bus, at[0], path
			bus.match("type='signal',path='" + path + "'")
			bus.call(ime.dest, path, ime.iface, "SetCapability", "t", uint64(0))
			return ime
		}
	}
	bus.close()
	return nil
}

func uixIBus(w *uixWindow) *uixIME {
	address := os.Getenv("IBUS_ADDRESS")
	if address == "" {
		address = uixIBusAddress()
	}
	if address == "" {
		return nil
	}
	ime := &uixIME{dest: "org.freedesktop.IBus", iface: "org.freedesktop.IBus.InputContext"}
	bus, err := uixBusDial(address, func(m *uixMsg) { ime.heard(w, m) })
	if err != nil {
		return nil
	}
	reply, err := bus.call("org.freedesktop.IBus", "/org/freedesktop/IBus", "org.freedesktop.IBus", "CreateInputContext", "s", uiAppName())
	path, ok := uixString(reply, 0)
	if err != nil || !ok {
		bus.close()
		return nil
	}
	ime.bus, ime.path = bus, path
	bus.match("type='signal',path='" + path + "'")
	bus.call(ime.dest, path, ime.iface, "SetCapabilities", "u", uint32(8))
	return ime
}

func uixIBusAddress() string {
	id := ""
	for _, file := range []string{"/var/lib/dbus/machine-id", "/etc/machine-id"} {
		if b, err := os.ReadFile(file); err == nil {
			id = strings.TrimSpace(string(b))
			break
		}
	}
	display := os.Getenv("DISPLAY")
	host, number, _ := strings.Cut(display, ":")
	number, _, _ = strings.Cut(number, ".")
	if host == "" {
		host = "unix"
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		home, _ := os.UserHomeDir()
		config = filepath.Join(home, ".config")
	}
	data, err := os.ReadFile(filepath.Join(config, "ibus", "bus", id+"-"+host+"-"+number))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "IBUS_ADDRESS="); ok {
			return v
		}
	}
	return ""
}

func (ime *uixIME) heard(w *uixWindow, m *uixMsg) {
	if m.kind != uixSignal || m.path != ime.path {
		return
	}
	switch m.member {
	case "CommitString", "CommitText":
		text := ""
		if len(m.body) > 0 {
			text = uixIMEText(m.body[0])
		}
		if text != "" {
			w.post(func() {
				for _, r := range text {
					w.typed(r)
				}
			})
		}
	case "ForwardKey", "ForwardKeyEvent":
		if len(m.body) < 3 {
			return
		}
		sym, state := uint32(uixNumber(m.body[0])), uint32(uixNumber(m.body[1]))
		if release, _ := m.body[2].(bool); ime.fcitx && release {
			return
		}
		if !ime.fcitx {
			state = uint32(uixNumber(m.body[2]))
		}
		if state&uixIBusRelease != 0 {
			return
		}
		w.post(func() { w.pressed(sym, uint16(state), true) })
	}
}

func uixIMEText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case uixVariant:
		return uixIMEText(x.v)
	case []any:
		if len(x) > 2 {
			if s, ok := x[2].(string); ok {
				return s
			}
		}
	}
	return ""
}

func (ime *uixIME) key(sym uint32, code byte, state uint16, release bool, stamp uint32) bool {
	var reply []any
	var err error
	if ime.fcitx {
		reply, err = ime.bus.callWithin(time.Second, ime.dest, ime.path, ime.iface, "ProcessKeyEvent", "uuubu",
			sym, uint32(code), uint32(state), release, stamp)
	} else {
		mask := uint32(state)
		if release {
			mask |= uixIBusRelease
		}
		reply, err = ime.bus.callWithin(time.Second, ime.dest, ime.path, ime.iface, "ProcessKeyEvent", "uuu",
			sym, uint32(code)-8, mask)
	}
	if err != nil || len(reply) == 0 {
		return false
	}
	handled, _ := reply[0].(bool)
	return handled
}

func (ime *uixIME) focus(on bool) {
	if on == ime.focused {
		return
	}
	ime.focused = on
	member := "FocusOut"
	if on {
		member = "FocusIn"
	}
	ime.bus.tell(ime.dest, ime.path, ime.iface, member, "")
	if !on {
		ime.spot = [4]int32{}
	}
}

func (ime *uixIME) place(x, y, h int32) {
	spot := [4]int32{x, y, 1, h}
	if spot == ime.spot {
		return
	}
	ime.spot = spot
	member := "SetCursorLocation"
	if ime.fcitx {
		member = "SetCursorRect"
	}
	ime.bus.tell(ime.dest, ime.path, ime.iface, member, "iiii", x, y, int32(1), h)
}
