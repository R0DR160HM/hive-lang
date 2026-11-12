// D-Bus, spoken by the program itself: what input methods and screen readers
// are reached over.

//go:build linux && !android

package hive

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type uixVariant struct {
	sig string
	v   any
}

type uixMsg struct {
	kind    byte
	flags   byte
	serial  uint32
	replyTo uint32
	path    string
	iface   string
	member  string
	errName string
	dest    string
	sender  string
	sig     string
	body    []any
}

const (
	uixCall   = 1
	uixReturn = 2
	uixError  = 3
	uixSignal = 4

	uixNoReply = 1
)

type uixBus struct {
	conn    net.Conn
	out     sync.Mutex
	serial  uint32
	mu      sync.Mutex
	waiting map[uint32]chan *uixMsg
	name    string
	handle  func(*uixMsg)
	dead    chan struct{}
}

var errUixBus = errors.New("the bus did not answer")

func uixBusDial(address string, handle func(*uixMsg)) (*uixBus, error) {
	var last error = errUixBus
	for _, one := range strings.Split(address, ";") {
		conn, err := uixBusConnect(one)
		if err != nil {
			last = err
			continue
		}
		b := &uixBus{conn: conn, waiting: map[uint32]chan *uixMsg{}, handle: handle, dead: make(chan struct{})}
		reader := bufio.NewReader(conn)
		if err := b.auth(reader); err != nil {
			conn.Close()
			last = err
			continue
		}
		go b.read(reader)
		reply, err := b.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "")
		if err != nil {
			b.close()
			last = err
			continue
		}
		b.name, _ = uixString(reply, 0)
		return b, nil
	}
	return nil, last
}

func uixBusConnect(address string) (net.Conn, error) {
	kind, rest, _ := strings.Cut(address, ":")
	keys := map[string]string{}
	for _, pair := range strings.Split(rest, ",") {
		if k, v, ok := strings.Cut(pair, "="); ok {
			keys[k] = uixUnescape(v)
		}
	}
	dial := func(network, at string) (net.Conn, error) {
		return net.DialTimeout(network, at, 2*time.Second)
	}
	switch {
	case kind == "unix" && keys["path"] != "":
		return dial("unix", keys["path"])
	case kind == "unix" && keys["abstract"] != "":
		return dial("unix", "@"+keys["abstract"])
	case kind == "tcp" && keys["port"] != "":
		host := keys["host"]
		if host == "" {
			host = "localhost"
		}
		return dial("tcp", net.JoinHostPort(host, keys["port"]))
	}
	return nil, errors.New("no address this can reach: " + address)
}

func uixUnescape(v string) string {
	var out strings.Builder
	for i := 0; i < len(v); i++ {
		if v[i] == '%' && i+2 < len(v) {
			if b, err := strconv.ParseUint(v[i+1:i+3], 16, 8); err == nil {
				out.WriteByte(byte(b))
				i += 2
				continue
			}
		}
		out.WriteByte(v[i])
	}
	return out.String()
}

func (b *uixBus) auth(r *bufio.Reader) error {
	b.conn.SetDeadline(time.Now().Add(3 * time.Second))
	defer b.conn.SetDeadline(time.Time{})
	uid := hex.EncodeToString([]byte(strconv.Itoa(os.Getuid())))
	if _, err := b.conn.Write([]byte("\x00AUTH EXTERNAL " + uid + "\r\n")); err != nil {
		return err
	}
	line, err := r.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(line, "OK") {
		return errors.New("the bus refused: " + strings.TrimSpace(line))
	}
	_, err = b.conn.Write([]byte("BEGIN\r\n"))
	return err
}

func (b *uixBus) close() {
	b.conn.Close()
}

func (b *uixBus) read(r *bufio.Reader) {
	defer func() {
		b.mu.Lock()
		for serial, wait := range b.waiting {
			close(wait)
			delete(b.waiting, serial)
		}
		b.mu.Unlock()
		close(b.dead)
	}()
	for {
		m, err := uixReadMsg(r)
		if err != nil {
			return
		}
		if m == nil {
			continue
		}
		switch m.kind {
		case uixReturn, uixError:
			b.mu.Lock()
			wait, ok := b.waiting[m.replyTo]
			delete(b.waiting, m.replyTo)
			b.mu.Unlock()
			if ok {
				wait <- m
			}
		default:
			switch {
			case b.handle != nil:
				b.handle(m)
			case m.kind == uixCall && m.flags&uixNoReply == 0:
				b.fail(m, "org.freedesktop.DBus.Error.UnknownMethod", "nothing is here")
			}
		}
	}
}

func (b *uixBus) write(m *uixMsg) (uint32, error) {
	b.out.Lock()
	defer b.out.Unlock()
	b.serial++
	data, err := m.marshal(b.serial)
	if err != nil {
		return 0, err
	}
	_, err = b.conn.Write(data)
	return b.serial, err
}

func (b *uixBus) call(dest, path, iface, member, sig string, args ...any) ([]any, error) {
	return b.callWithin(3*time.Second, dest, path, iface, member, sig, args...)
}

func (b *uixBus) callWithin(limit time.Duration, dest, path, iface, member, sig string, args ...any) ([]any, error) {
	wait := make(chan *uixMsg, 1)
	b.out.Lock()
	b.serial++
	serial := b.serial
	m := &uixMsg{kind: uixCall, dest: dest, path: path, iface: iface, member: member, sig: sig, body: args}
	data, err := m.marshal(serial)
	if err != nil {
		b.out.Unlock()
		return nil, err
	}
	b.mu.Lock()
	b.waiting[serial] = wait
	b.mu.Unlock()
	_, err = b.conn.Write(data)
	b.out.Unlock()
	if err != nil {
		b.forget(serial)
		return nil, err
	}
	select {
	case reply, ok := <-wait:
		if !ok || reply == nil {
			return nil, errUixBus
		}
		if reply.kind == uixError {
			text, _ := uixString(reply.body, 0)
			return nil, errors.New(reply.errName + ": " + text)
		}
		return reply.body, nil
	case <-time.After(limit):
		b.forget(serial)
		return nil, errUixBus
	}
}

func (b *uixBus) forget(serial uint32) {
	b.mu.Lock()
	delete(b.waiting, serial)
	b.mu.Unlock()
}

func (b *uixBus) tell(dest, path, iface, member, sig string, args ...any) {
	b.write(&uixMsg{kind: uixCall, flags: uixNoReply, dest: dest, path: path, iface: iface, member: member, sig: sig, body: args})
}

func (b *uixBus) signal(path, iface, member, sig string, args ...any) {
	b.write(&uixMsg{kind: uixSignal, path: path, iface: iface, member: member, sig: sig, body: args})
}

func (b *uixBus) reply(to *uixMsg, sig string, args ...any) {
	if to.flags&uixNoReply != 0 {
		return
	}
	b.write(&uixMsg{kind: uixReturn, replyTo: to.serial, dest: to.sender, sig: sig, body: args})
}

func (b *uixBus) fail(to *uixMsg, name, text string) {
	if to.flags&uixNoReply != 0 {
		return
	}
	b.write(&uixMsg{kind: uixError, replyTo: to.serial, dest: to.sender, errName: name, sig: "s", body: []any{text}})
}

func (b *uixBus) match(rule string) {
	b.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", rule)
}

func (b *uixBus) owned(name string) bool {
	reply, err := b.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", name)
	if err != nil || len(reply) == 0 {
		return false
	}
	has, _ := reply[0].(bool)
	return has
}

func uixString(body []any, at int) (string, bool) {
	if at < len(body) {
		s, ok := body[at].(string)
		return s, ok
	}
	return "", false
}

func (m *uixMsg) marshal(serial uint32) ([]byte, error) {
	body := &uixEnc{}
	types := uixTypes(m.sig)
	if len(types) != len(m.body) {
		return nil, errors.New("the body does not match its signature " + m.sig)
	}
	for i, t := range types {
		if err := body.put(t, m.body[i]); err != nil {
			return nil, err
		}
	}
	var fields []any
	field := func(code byte, sig string, v any) { fields = append(fields, []any{code, uixVariant{sig, v}}) }
	if m.path != "" {
		field(1, "o", m.path)
	}
	if m.iface != "" {
		field(2, "s", m.iface)
	}
	if m.member != "" {
		field(3, "s", m.member)
	}
	if m.errName != "" {
		field(4, "s", m.errName)
	}
	if m.replyTo != 0 {
		field(5, "u", m.replyTo)
	}
	if m.dest != "" {
		field(6, "s", m.dest)
	}
	if m.sig != "" {
		field(8, "g", m.sig)
	}
	head := &uixEnc{b: []byte{'l', m.kind, m.flags, 1}}
	head.b = binary.LittleEndian.AppendUint32(head.b, uint32(len(body.b)))
	head.b = binary.LittleEndian.AppendUint32(head.b, serial)
	if err := head.put("a(yv)", fields); err != nil {
		return nil, err
	}
	head.align(8)
	return append(head.b, body.b...), nil
}

func uixReadMsg(r *bufio.Reader) (*uixMsg, error) {
	fixed := make([]byte, 16)
	if _, err := io.ReadFull(r, fixed); err != nil {
		return nil, err
	}
	var order binary.ByteOrder = binary.LittleEndian
	if fixed[0] == 'B' {
		order = binary.BigEndian
	}
	bodyLen := int(order.Uint32(fixed[4:]))
	fieldsLen := int(order.Uint32(fixed[12:]))
	if bodyLen > 1<<27 || fieldsLen > 1<<26 {
		return nil, errors.New("a message too large to be one")
	}
	headEnd := (16 + fieldsLen + 7) &^ 7
	whole := make([]byte, headEnd+bodyLen)
	copy(whole, fixed)
	if _, err := io.ReadFull(r, whole[16:]); err != nil {
		return nil, err
	}
	m := &uixMsg{kind: fixed[1], flags: fixed[2], serial: order.Uint32(fixed[8:])}
	d := &uixDec{b: whole[:headEnd], at: 12, order: order}
	raw, err := d.get("a(yv)")
	if err != nil {
		return nil, err
	}
	fields, _ := raw.([]any)
	for _, f := range fields {
		pair, _ := f.([]any)
		if len(pair) != 2 {
			continue
		}
		code, _ := pair[0].(byte)
		v, _ := pair[1].(uixVariant)
		switch code {
		case 1:
			m.path, _ = v.v.(string)
		case 2:
			m.iface, _ = v.v.(string)
		case 3:
			m.member, _ = v.v.(string)
		case 4:
			m.errName, _ = v.v.(string)
		case 5:
			m.replyTo, _ = v.v.(uint32)
		case 6:
			m.dest, _ = v.v.(string)
		case 7:
			m.sender, _ = v.v.(string)
		case 8:
			m.sig, _ = v.v.(string)
		}
	}
	bd := &uixDec{b: whole[headEnd:], order: order}
	for _, t := range uixTypes(m.sig) {
		v, err := bd.get(t)
		if err != nil {
			return nil, nil
		}
		m.body = append(m.body, v)
	}
	return m, nil
}

func uixTypes(sig string) []string {
	var out []string
	for sig != "" {
		n := uixTypeLen(sig)
		if n <= 0 {
			return out
		}
		out = append(out, sig[:n])
		sig = sig[n:]
	}
	return out
}

func uixTypeLen(sig string) int {
	if sig == "" {
		return 0
	}
	switch sig[0] {
	case 'a':
		return 1 + uixTypeLen(sig[1:])
	case '(', '{':
		depth := 0
		for i := 0; i < len(sig); i++ {
			switch sig[i] {
			case '(', '{':
				depth++
			case ')', '}':
				depth--
				if depth == 0 {
					return i + 1
				}
			}
		}
		return -1
	}
	return 1
}

func uixAlignOf(t byte) int {
	switch t {
	case 'y', 'g', 'v':
		return 1
	case 'n', 'q':
		return 2
	case 'x', 't', 'd', '(', '{':
		return 8
	}
	return 4
}

type uixEnc struct{ b []byte }

func (e *uixEnc) align(n int) {
	for len(e.b)%n != 0 {
		e.b = append(e.b, 0)
	}
}

func uixNumber(v any) uint64 {
	switch x := v.(type) {
	case byte:
		return uint64(x)
	case bool:
		if x {
			return 1
		}
		return 0
	case int:
		return uint64(x)
	case int16:
		return uint64(x)
	case uint16:
		return uint64(x)
	case int32:
		return uint64(x)
	case uint32:
		return uint64(x)
	case int64:
		return uint64(x)
	case uint64:
		return x
	case float64:
		return uint64(x)
	}
	return 0
}

func (e *uixEnc) put(t string, v any) error {
	le := binary.LittleEndian
	e.align(uixAlignOf(t[0]))
	switch t[0] {
	case 'y':
		e.b = append(e.b, byte(uixNumber(v)))
	case 'b', 'i', 'u', 'h':
		e.b = le.AppendUint32(e.b, uint32(uixNumber(v)))
	case 'n', 'q':
		e.b = le.AppendUint16(e.b, uint16(uixNumber(v)))
	case 'x', 't':
		e.b = le.AppendUint64(e.b, uixNumber(v))
	case 'd':
		f, _ := v.(float64)
		e.b = le.AppendUint64(e.b, math.Float64bits(f))
	case 's', 'o':
		s, _ := v.(string)
		e.b = le.AppendUint32(e.b, uint32(len(s)))
		e.b = append(append(e.b, s...), 0)
	case 'g':
		s, _ := v.(string)
		e.b = append(append(append(e.b, byte(len(s))), s...), 0)
	case 'v':
		inner, ok := v.(uixVariant)
		if !ok {
			return errors.New("a variant that is not one")
		}
		e.b = append(append(append(e.b, byte(len(inner.sig))), inner.sig...), 0)
		return e.put(inner.sig, inner.v)
	case 'a':
		at := len(e.b)
		e.b = le.AppendUint32(e.b, 0)
		e.align(uixAlignOf(t[1]))
		start := len(e.b)
		elem := t[1:]
		switch items := v.(type) {
		case []byte:
			e.b = append(e.b, items...)
		case []string:
			for _, s := range items {
				if err := e.put(elem, s); err != nil {
					return err
				}
			}
		case []any:
			for _, item := range items {
				if err := e.put(elem, item); err != nil {
					return err
				}
			}
		case nil:
		default:
			return errors.New("an array that is not one")
		}
		le.PutUint32(e.b[at:], uint32(len(e.b)-start))
	case '(', '{':
		fields, _ := v.([]any)
		types := uixTypes(t[1 : len(t)-1])
		if len(fields) != len(types) {
			return errors.New("a struct that does not match " + t)
		}
		for i, ft := range types {
			if err := e.put(ft, fields[i]); err != nil {
				return err
			}
		}
	default:
		return errors.New("a type this does not write: " + t)
	}
	return nil
}

type uixDec struct {
	b     []byte
	at    int
	order binary.ByteOrder
}

var errUixShort = errors.New("a message cut short")

func (d *uixDec) align(n int) {
	d.at = (d.at + n - 1) / n * n
}

func (d *uixDec) take(n int) ([]byte, error) {
	if d.at+n > len(d.b) || n < 0 {
		return nil, errUixShort
	}
	out := d.b[d.at : d.at+n]
	d.at += n
	return out, nil
}

func (d *uixDec) get(t string) (any, error) {
	d.align(uixAlignOf(t[0]))
	switch t[0] {
	case 'y':
		b, err := d.take(1)
		if err != nil {
			return nil, err
		}
		return b[0], nil
	case 'b', 'i', 'u', 'h':
		b, err := d.take(4)
		if err != nil {
			return nil, err
		}
		v := d.order.Uint32(b)
		switch t[0] {
		case 'b':
			return v != 0, nil
		case 'i':
			return int32(v), nil
		}
		return v, nil
	case 'n', 'q':
		b, err := d.take(2)
		if err != nil {
			return nil, err
		}
		if t[0] == 'n' {
			return int16(d.order.Uint16(b)), nil
		}
		return d.order.Uint16(b), nil
	case 'x', 't', 'd':
		b, err := d.take(8)
		if err != nil {
			return nil, err
		}
		v := d.order.Uint64(b)
		switch t[0] {
		case 'x':
			return int64(v), nil
		case 'd':
			return math.Float64frombits(v), nil
		}
		return v, nil
	case 's', 'o':
		b, err := d.take(4)
		if err != nil {
			return nil, err
		}
		s, err := d.take(int(d.order.Uint32(b)) + 1)
		if err != nil {
			return nil, err
		}
		return string(s[:len(s)-1]), nil
	case 'g':
		b, err := d.take(1)
		if err != nil {
			return nil, err
		}
		s, err := d.take(int(b[0]) + 1)
		if err != nil {
			return nil, err
		}
		return string(s[:len(s)-1]), nil
	case 'v':
		sig, err := d.get("g")
		if err != nil {
			return nil, err
		}
		inner := sig.(string)
		if uixTypeLen(inner) != len(inner) || inner == "" {
			return nil, errors.New("a variant of no one type")
		}
		v, err := d.get(inner)
		return uixVariant{inner, v}, err
	case 'a':
		b, err := d.take(4)
		if err != nil {
			return nil, err
		}
		size := int(d.order.Uint32(b))
		d.align(uixAlignOf(t[1]))
		end := d.at + size
		if end > len(d.b) {
			return nil, errUixShort
		}
		if t[1] == 'y' {
			out := append([]byte(nil), d.b[d.at:end]...)
			d.at = end
			return out, nil
		}
		out := []any{}
		for d.at < end {
			v, err := d.get(t[1:])
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case '(', '{':
		var out []any
		for _, ft := range uixTypes(t[1 : len(t)-1]) {
			v, err := d.get(ft)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	}
	return nil, errors.New("a type this does not read: " + t)
}
