// The Go for `hive.syslink`: addressable services, in this process or on another
// machine, reached by the same statement either way. The wire half is `syslinknet`.
// ---------------------------------------------------------------------------
// hive.syslink — addressable services, in this process or on another machine
// ---------------------------------------------------------------------------
// A service is long-lived, has an identity you can pass around, and owns
// private state only it can touch. Its address is an ordinary value that
// outlives the scope that spawned it and can travel inside a message.
//
// Every choice here makes a send behave the same whether the recipient is a
// mailbox in this process or a service on another machine: the message is
// copied either way, the send never blocks and never fails, and a dead
// recipient is discovered through a monitor rather than a return value.
package hive

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

// atomNone is the "no atom" sentinel. Zero is taken (#Nil), so a negative
// value is used: no compiled atom is ever negative.
const atomNone Atom = -1

// SyslinkSyslinkError is what the fallible half of the module answers with. Reason is
// a short tag, in the same spirit as FileError and WsError: "Timeout", "Down",
// "Unreachable", "Decode", "Taken", "NoListener" or "NoPeer".
//
// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------
// A message crosses a machine boundary through the same derived encoder and
// decoder hive.json builds from a type declaration, so nothing new has to be
// derived for a type to be sendable.
type SyslinkSyslinkError struct {
	Reason  string
	Message string
}

func (e SyslinkSyslinkError) String() string { return e.Reason + ": " + e.Message }

func syslinkErr[T any](reason, message string) Result[T, SyslinkSyslinkError] {
	return Err[T, SyslinkSyslinkError](SyslinkSyslinkError{Reason: reason, Message: message})
}

// SyslinkEncoder adapts a derived encoder to the bytes the wire carries.
func SyslinkEncoder[T any](enc func(T) string) func(T) []byte {
	return func(v T) []byte { return []byte(enc(v)) }
}

// SyslinkDecoder adapts a derived decoder into the erased form a mailbox holds.
// A mailbox is typed by its handler rather than by its decoder, so the decoder
// only has to produce the right dynamic type for that handler to accept.
func SyslinkDecoder[T any](dec func(JsonValue, string) (T, *JsonJsonError)) func([]byte) (any, error) {
	return func(b []byte) (any, error) {
		r := JsonParse(string(b), dec)
		if r.IsError() {
			return nil, errors.New(jsonWhy(r.Err()))
		}
		return r.Ok(), nil
	}
}

// SyslinkReplyDecoder is the same adapter for the answer to a call, which stays
// typed because the call site said what it expected back.
func SyslinkReplyDecoder[T any](dec func(JsonValue, string) (T, *JsonJsonError)) func([]byte) (T, error) {
	return func(b []byte) (T, error) {
		r := JsonParse(string(b), dec)
		if r.IsError() {
			var zero T
			return zero, errors.New(jsonWhy(r.Err()))
		}
		return r.Ok(), nil
	}
}

// An address travels inside a message as text, which is how a service hands out
// a way to reach it without that worker needing a registered name. A registered
// name crosses as a name because atom ids are per build; an anonymous mailbox
// crosses as its id, meaningful only with the node it lives on.
func JsonEncodeAddress(a SyslinkAddress) string {
	where := a.Endpoint
	if where == "" {

		// A local address is stamped with this node's advertised endpoint, so it
		// stays dialable once it is somewhere else — including after being passed
		// on a second time.
		where = SyslinkNode()
	}
	name := ""
	if a.Name != atomNone {
		name = a.Name.String()
	}
	return JsonEncodeStr(where + "|" + name + "|" + strconv.FormatUint(a.Id, 10))
}

func JsonAddress(v JsonValue, path string) (SyslinkAddress, *JsonJsonError) {
	text, jerr := JsonStr(v, path)
	if jerr != nil {
		return SyslinkAddress{}, jerr
	}
	parts := strings.Split(text, "|")
	if len(parts) != 3 {
		return SyslinkAddress{}, &JsonJsonError{Path: path, Expected: "a syslink address", Found: JsonEncodeStr(text)}
	}
	addr := SyslinkAddress{Endpoint: parts[0], Name: atomNone}
	if parts[1] != "" {
		addr.Name = atomByName(parts[1])
	}
	if id, err := strconv.ParseUint(parts[2], 10, 64); err == nil {
		addr.Id = id
	}

	// An address that names this node is resolved back to the live mailbox, so
	// sending to it takes the local path rather than a pointless round trip.
	//
	// ---------------------------------------------------------------------------
	// Addresses
	// ---------------------------------------------------------------------------
	if b, ok := resolveLocal(addr); ok {
		addr.box = b
	}
	return addr, nil
}

func jsonWhy(e JsonJsonError) string {
	where := e.Path
	if where == "" {
		where = "the message"
	}
	return "expected " + e.Expected + " at " + where + ", found " + e.Found
}

// SyslinkAddress identifies a service: a plain value, copyable, storable and
// sendable. box is set only while the service lives in this process; a remote
// address carries its node role plus either a registered name or a mailbox id.
type SyslinkAddress struct {

	// Where the node holding this service can be reached, as it advertised
	// itself: "10.0.0.4:9100". Empty means this node. A node is identified by
	// where it is rather than by a name — an endpoint is deployment data, and
	// there is nothing for an authenticated peer to impersonate.
	Endpoint string
	Name     Atom
	Id       uint64
	box      *mailbox
}

// String renders an address the way echo shows it — <node/name> for a
// registered service, <node#id> for an anonymous one.
func (a SyslinkAddress) String() string {
	where := a.Endpoint
	if where == "" {
		where = SyslinkNode()
	}
	if where == "" {
		where = "this node"
	}
	if a.Name != atomNone {
		return "<" + where + "/" + a.Name.String() + ">"
	}
	return "<" + where + "#" + strconv.FormatUint(a.Id, 10) + ">"
}

// ---------------------------------------------------------------------------
// Mailboxes
// ---------------------------------------------------------------------------
type syslinkTurn struct {
	self  *mailbox
	drawn bool
}

func (t syslinkTurn) address() SyslinkAddress {
	return SyslinkAddress{Endpoint: SyslinkNode(), Name: t.self.name, Id: t.self.id, box: t.self}
}

// delivery is one queued message. One that arrived over the wire keeps its raw
// payload and is decoded on the recipient's own turn, so a malformed payload
// fails as that service's problem instead of tearing down a shared connection.
type delivery struct {
	value  any
	raw    []byte
	digest uint32
	ref    uint64

	// The advertised endpoint the request arrived from, so its answer can go back
	// the way it came. Empty for a request raised on this node.
	origin string
	drawn  bool
}

// watcher is one monitor registration: the death message and where to deliver
// it. A local watcher holds the mailbox directly; a remote one is addressed by
// node and mailbox id, its message pre-encoded by the node that asked.
//
// Each registration carries a mon id so a monitor fires exactly once. Without
// it, losing the node right after a service died there would deliver the death
// message twice.
type watcher struct {
	box     *mailbox
	value   any
	node    string
	id      uint64
	mon     uint64
	payload []byte
	digest  uint32
}

// A mailbox is an unbounded FIFO queue plus the goroutine that folds it into
// the service's state. Unbounded is deliberate: a bounded queue would make send
// block, breaking the send contract and letting two services deadlock.
type mailbox struct {
	id   uint64
	name Atom

	mu     sync.Mutex
	cond   *sync.Cond
	queue  []delivery
	closed bool

	// Installed at spawn: how to turn a wire payload into this mailbox's
	// message type, and the structural digest of that type. Then the table
	// every mailbox lives in, which maps a `uint64` box id to a `*mailbox`.
	decode func([]byte) (any, error)
	digest uint32

	watchers []watcher
}

var (
	boxSeq atomic.Uint64
	boxes  sync.Map

	// The registry is indexed by atom id. Registered names come from a closed,
	// compile-time set, so its size is known before main runs and a lookup is
	// an array index rather than a hash and a lock.
	registryOnce sync.Once
	registry     []atomic.Pointer[mailbox]
)

func registrySlots() []atomic.Pointer[mailbox] {
	registryOnce.Do(func() {
		registry = make([]atomic.Pointer[mailbox], len(atomNames))
	})
	return registry
}

func newMailbox(decode func([]byte) (any, error), digest uint32) *mailbox {
	b := &mailbox{id: boxSeq.Add(1), name: atomNone, decode: decode, digest: digest}
	b.cond = sync.NewCond(&b.mu)
	boxes.Store(b.id, b)
	return b
}

// post enqueues one delivery. A send to a service that has already died is a
// no-op, not an error: that is what the monitor is for.
func (b *mailbox) post(d delivery) {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		failDelivery(d, "Down", "the service is no longer running")
		return
	}
	b.queue = append(b.queue, d)
	b.mu.Unlock()
	b.cond.Signal()
}

func (b *mailbox) take() (delivery, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for len(b.queue) == 0 && !b.closed {
		b.cond.Wait()
	}
	if len(b.queue) == 0 {
		return delivery{}, false
	}
	d := b.queue[0]
	b.queue = b.queue[1:]
	return d, true
}

// value resolves a delivery to a message value, decoding a wire payload on the
// recipient's turn. A digest mismatch is reported here, where it can name the
// service, rather than silently decoding another type's bytes.
func (b *mailbox) value(d delivery) (any, error) {
	if d.raw == nil {
		return d.value, nil
	}
	if d.digest != 0 && b.digest != 0 && d.digest != b.digest {
		return nil, fmt.Errorf(
			"message type digest %08x does not match the mailbox's %08x — the sender was built from a different message type",
			d.digest, b.digest)
	}
	if b.decode == nil {
		return nil, fmt.Errorf("this service cannot decode messages from the wire")
	}
	return b.decode(d.raw)
}

// die closes the mailbox, frees its name first so whoever hears of the death can
// reuse it, fails every call still waiting on it and notifies its watchers.
func (b *mailbox) die(reason string) {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	ws := b.watchers
	b.watchers = nil
	if b.name != atomNone {
		slots := registrySlots()
		if int(b.name) >= 0 && int(b.name) < len(slots) {
			slots[b.name].CompareAndSwap(b, nil)
		}
	}

	// Requests still queued will never be handled, so their callers are told
	// now rather than left to wait out a timeout.
	orphans := b.queue
	b.queue = nil
	b.mu.Unlock()
	b.cond.Broadcast()

	for _, d := range orphans {
		failDelivery(d, "Down", "the service died before answering: "+reason)
	}
	boxes.Delete(b.id)
	failCallsTo(b.id, reason)
	for _, w := range ws {
		notifyWatcher(w)
	}
}

// failDelivery tells the caller of an unanswerable request that it will never be
// answered. A local caller gets it through its pending channel; one on another
// node gets a frame, so either way it fails fast instead of timing out.
func failDelivery(d delivery, reason, message string) {
	if d.ref == 0 {
		return
	}
	if d.origin == "" {
		deliverAnswer(d.ref, answer{err: &SyslinkSyslinkError{Reason: reason, Message: message}})
		return
	}

	// The reason has to survive the wire, so it travels ahead of the message.
	//
	// ---------------------------------------------------------------------------
	// Spawning
	// ---------------------------------------------------------------------------
	sendFrame(d.origin, frame{kind: kindNoProc, ref: d.ref, payload: []byte(reason + "|" + message)})
}

func notifyWatcher(w watcher) {
	if w.box != nil {
		w.box.post(delivery{value: w.value, origin: ""})
		return
	}
	sendFrame(w.node, frame{
		kind:    kindDown,
		name:    atomNone,
		id:      w.id,
		ref:     w.mon,
		digest:  w.digest,
		payload: w.payload,
	})
}

const SyslinkUnnamed = atomNone

func SyslinkSpawn[S any, M any](
	handler func(*S, M) M,
	name Atom,
	initial S,
	decode func([]byte) (any, error),
	digest uint32,
	encode func(M) []byte,
	clone func(M) M,
) Result[SyslinkAddress, SyslinkSyslinkError] {
	turn := func(state *S, msg M, _ syslinkTurn) M { return handler(state, msg) }
	return spawnService(starterOf(funcKey(handler)), turn, name, initial, decode, digest, encode, clone)
}

func SyslinkSpawnAddressed[S any, M any](
	handler func(*S, M, SyslinkAddress) M,
	name Atom,
	initial S,
	decode func([]byte) (any, error),
	digest uint32,
	encode func(M) []byte,
	clone func(M) M,
) Result[SyslinkAddress, SyslinkSyslinkError] {
	turn := func(state *S, msg M, t syslinkTurn) M { return handler(state, msg, t.address()) }
	return spawnService(starterOf(funcKey(handler)), turn, name, initial, decode, digest, encode, clone)
}

// How a window starts, found by its handler's identity: that survives the
// handler being stored or passed, where a method on a func type would not.
type syslinkStarter func(turn any, initial any) (any, func(SyslinkAddress))

var starters sync.Map

func funcKey[F any](f F) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&f))
}

func startsAs(key unsafe.Pointer, s syslinkStarter) {
	starters.Store(key, s)
}

func starterOf(key unsafe.Pointer) syslinkStarter {
	if s, ok := starters.Load(key); ok {
		return s.(syslinkStarter)
	}
	return nil
}

// The name is claimed before the service runs, so a taken one starts nothing.
func spawnService[S any, M any](
	starter syslinkStarter,
	turn func(*S, M, syslinkTurn) M,
	name Atom,
	initial S,
	decode func([]byte) (any, error),
	digest uint32,
	encode func(M) []byte,
	clone func(M) M,
) Result[SyslinkAddress, SyslinkSyslinkError] {
	var started func(SyslinkAddress)
	if starter != nil {
		folded, then := starter(turn, initial)
		turn = folded.(func(*S, M, syslinkTurn) M)
		started = then
	}
	b := newMailbox(decode, digest)
	addr := SyslinkAddress{Name: atomNone, Id: b.id, box: b}
	if name != atomNone {
		b.name = name
		slots := registrySlots()
		if int(name) < 0 || int(name) >= len(slots) || !slots[name].CompareAndSwap(nil, b) {
			boxes.Delete(b.id)
			return syslinkErr[SyslinkAddress]("Taken", "the name "+name.String()+" is already registered on this node")
		}
		addr = SyslinkAddress{Endpoint: SyslinkNode(), Name: name, Id: b.id, box: b}
	}
	go runService(b, turn, initial, encode, clone)
	if started != nil {
		started(addr)
	}
	return Ok[SyslinkAddress, SyslinkSyslinkError](addr)
}

func runService[S any, M any](
	b *mailbox,
	turn func(*S, M, syslinkTurn) M,
	initial S,
	encode func(M) []byte,
	clone func(M) M,
) {
	state := initial
	reason := "normal"
	for {
		d, ok := b.take()
		if !ok {
			break
		}
		raw, err := b.value(d)
		if err != nil {
			fmt.Fprintln(os.Stderr, "hive: "+serviceLabel(b)+" dropped a message: "+err.Error())
			failDelivery(d, "Decode", serviceLabel(b)+" could not read the message: "+err.Error())
			continue
		}
		msg, fits := raw.(M)
		if !fits {
			fmt.Fprintln(os.Stderr, "hive: "+serviceLabel(b)+" dropped a message of an unexpected type")
			failDelivery(d, "Decode", serviceLabel(b)+" does not handle messages of that type")
			continue
		}
		out, crashed := serviceTurn(turn, &state, msg, syslinkTurn{self: b, drawn: d.drawn})
		if crashed != nil {
			reason = Show(crashed)
			fmt.Fprintln(os.Stderr, "hive: "+serviceLabel(b)+" crashed: "+reason)
			failDelivery(d, "Down", "the service crashed while handling the request: "+reason)
			break
		}
		replyTo(d, out, encode, clone)
	}
	b.die(reason)
}

func serviceTurn[S any, M any](
	turn func(*S, M, syslinkTurn) M,
	state *S,
	msg M,
	t syslinkTurn,
) (out M, crashed any) {
	defer func() {
		if r := recover(); r != nil {
			crashed = r
		}
	}()
	return turn(state, msg, t), nil
}

func replyTo[M any](d delivery, out M, encode func(M) []byte, clone func(M) M) {
	if d.ref == 0 {
		return
	}
	if d.origin != "" {
		sendFrame(d.origin, frame{kind: kindReply, ref: d.ref, payload: encode(out)})
		return
	}
	if syslinkStrict() {
		deliverAnswer(d.ref, answer{raw: encode(out)})
		return
	}
	deliverAnswer(d.ref, answer{value: clone(out)})
}

func serviceLabel(b *mailbox) string {
	if b.name != atomNone {
		return "service " + b.name.String()
	}
	return "service #" + strconv.FormatUint(b.id, 10)
}

// SyslinkKill shuts a service down. Its mailbox closes, its watchers are told,
// and calling it twice is harmless.
//
// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------
func SyslinkKill(addr SyslinkAddress) {
	if b, ok := resolveLocal(addr); ok {
		b.die("killed")
		return
	}
	sendFrame(addr.Endpoint, frame{kind: kindStop, name: addr.Name, id: addr.Id})
}

// SyslinkAt is the address of a named service on a node role. It performs no
// I/O and cannot fail: address construction, not a lookup, which is what lets a
// program name a service that is not running yet and still type-check.
func SyslinkAt(name Atom) SyslinkAddress {
	if b := lookupName(name); b != nil {
		return SyslinkAddress{Name: name, Id: b.id, box: b}
	}
	return SyslinkAddress{Name: name, Id: 0}
}

// SyslinkOn is the address of a named service on the node reachable at endpoint.
// Like SyslinkAt it performs no I/O and cannot fail, so a program can name a
// service that is not running yet — or a node temporarily down — and still run.
func SyslinkOn(endpoint string, name Atom) SyslinkAddress {
	if endpoint == "" || endpoint == SyslinkNode() {
		return SyslinkAt(name)
	}
	return SyslinkAddress{Endpoint: endpoint, Name: name, Id: 0}
}

func lookupName(name Atom) *mailbox {
	slots := registrySlots()
	if int(name) < 0 || int(name) >= len(slots) {
		return nil
	}
	return slots[name].Load()
}

// resolveLocal answers with the mailbox behind an address when the service
// lives in this process — either because the address carries it directly, or
// because it names this node.
//
// A named address is resolved through the registry every time, never through
// the mailbox it happened to find when it was built. The name is the
// identity: a replacement registered under it has to be picked up by
// everyone still holding the address. A cached mailbox would make a restart
// invisible to the holder — and since a send never fails, it would never
// find out.
func resolveLocal(addr SyslinkAddress) (*mailbox, bool) {
	if addr.Endpoint != "" && addr.Endpoint != SyslinkNode() {
		return nil, false
	}
	if addr.Name != atomNone {
		if b := lookupName(addr.Name); b != nil {
			return b, true
		}
		return nil, false
	}

	// An anonymous address is only ever itself. There is nothing to re-resolve to,
	// so its mailbox dying is final.
	//
	// ---------------------------------------------------------------------------
	// Sending
	// ---------------------------------------------------------------------------
	if addr.box != nil {
		return addr.box, true
	}
	if addr.Id != 0 {
		if b, ok := boxes.Load(addr.Id); ok {
			return b.(*mailbox), true
		}
	}
	return nil, false
}

func missingLocal(addr SyslinkAddress) (string, string) {
	if addr.Name != atomNone {
		return "NoProc", "no service is registered as #" + addr.Name.String() + " on this node"
	}
	return "Down", "the service is no longer running"
}

// syslinkStrict forces a local send through the same encode/decode path a
// remote one takes, so a message that could not survive the wire fails in a
// single-process test run rather than the first time a peer is added.
var strictOnce sync.Once
var strict bool

func syslinkStrict() bool {
	strictOnce.Do(func() {
		strict = os.Getenv("HIVE_SYSLINK_STRICT") != ""
	})
	return strict
}

// SyslinkPost delivers a message to a service on this node without encoding it,
// and is how a runtime module posts to a service it spawned itself.
//
// Deliberately not reachable from Hive. The one thing it does that SyslinkSend
// cannot is skip the codec, and it may only do that because sender and service
// are the same process by construction. A non-local address is dropped rather
// than half-sent.
func SyslinkPost(addr SyslinkAddress, msg any) {
	if b, ok := resolveLocal(addr); ok {
		b.post(delivery{value: msg, origin: ""})
	}
}

func syslinkPostDrawn(addr SyslinkAddress, msg any) {
	if b, ok := resolveLocal(addr); ok {
		b.post(delivery{value: msg, origin: "", drawn: true})
	}
}

// SyslinkSend delivers one message and returns immediately. It never blocks and
// never fails — a dead or unreachable recipient is not an error at the send
// site, which is what keeps a local send and a remote one the same statement.
//
// ---------------------------------------------------------------------------
// Request / response
// ---------------------------------------------------------------------------
func SyslinkSend[M any](addr SyslinkAddress, msg M, encode func(M) []byte, digest uint32) {
	if b, ok := resolveLocal(addr); ok {
		if syslinkStrict() {
			b.post(delivery{raw: encode(msg), digest: digest, origin: ""})
			return
		}
		b.post(delivery{value: msg, origin: ""})
		return
	}
	sendFrame(addr.Endpoint, frame{
		kind:    kindCast,
		name:    addr.Name,
		id:      addr.Id,
		digest:  digest,
		payload: encode(msg),
	})
}

// answer is one reply travelling back to a waiting call: a value for a local
// exchange, raw bytes for one that crossed the wire, or a failure.
type answer struct {
	value any
	raw   []byte
	err   *SyslinkSyslinkError
}

type pendingCall struct {
	reply  chan answer
	target uint64
	node   string
	born   time.Time
}

var (
	refSeq  atomic.Uint64
	pendMu  sync.Mutex
	pending = map[uint64]pendingCall{}
)

// How long an outstanding request is kept before it is assumed abandoned. A
// request whose value is never awaited would otherwise sit in the table forever;
// this is the backstop, not the timeout (that lives at the await site).
const syslinkRefLifetime = 10 * time.Minute

func awaitRef(target uint64, node string) (uint64, chan answer) {
	ref := refSeq.Add(1)
	ch := make(chan answer, 1)
	pendMu.Lock()
	pending[ref] = pendingCall{reply: ch, target: target, node: node, born: time.Now()}

	// Sweep abandoned requests on the way in, so no timer goroutine is needed
	// and a program that never abandons one never pays for this.
	if len(pending) > 64 {
		cutoff := time.Now().Add(-syslinkRefLifetime)
		for old, p := range pending {
			if p.born.Before(cutoff) {
				delete(pending, old)
			}
		}
	}
	pendMu.Unlock()
	return ref, ch
}

func dropRef(ref uint64) {
	pendMu.Lock()
	delete(pending, ref)
	pendMu.Unlock()
}

func deliverAnswer(ref uint64, a answer) {
	pendMu.Lock()
	p, ok := pending[ref]
	delete(pending, ref)
	pendMu.Unlock()
	if ok {
		p.reply <- a
	}
}

// failCallsTo fails every call waiting on a service that has just died, so a
// caller learns immediately instead of waiting out its timeout.
func failCallsTo(target uint64, reason string) {
	pendMu.Lock()
	hit := []pendingCall{}
	for ref, p := range pending {
		if p.target == target {
			hit = append(hit, p)
			delete(pending, ref)
		}
	}
	pendMu.Unlock()
	for _, p := range hit {
		p.reply <- answer{err: &SyslinkSyslinkError{Reason: "Down", Message: "the service died before answering: " + reason}}
	}
}

// failCallsToNode fails every call waiting on a node that has just been
// declared unreachable.
func failCallsToNode(node string, reason string) {
	pendMu.Lock()
	hit := []pendingCall{}
	for ref, p := range pending {
		if p.node == node {
			hit = append(hit, p)
			delete(pending, ref)
		}
	}
	pendMu.Unlock()
	for _, p := range hit {
		p.reply <- answer{err: &SyslinkSyslinkError{Reason: "Unreachable", Message: reason}}
	}
}

// syslinkDefaultWait is how long a send waits for its answer when the call site
// gives no with timeout of its own.
const syslinkDefaultWait = 5000

// SyslinkPending is a request in flight: the send has gone out and the answer
// has not arrived yet.
//
// Deliberately not an *Async: no goroutine is parked waiting. The reply arrives
// on the connection's own reader goroutine, so a request costs a channel and
// nothing else, and an await-all over sends spawns nothing at all.
type SyslinkPending[M any] struct {
	ref    uint64
	reply  chan answer
	decode func([]byte) (M, error)

	mu       sync.Mutex
	resolved bool
	result   Result[M, SyslinkSyslinkError]
}

// SyslinkSendAwaitable starts a request and returns immediately. The message has
// already been copied by the caller, exactly as for a fire-and-forget send:
// whether an answer is wanted changes nothing about how the message travels.
func SyslinkSendAwaitable[M any](
	addr SyslinkAddress,
	msg M,
	encode func(M) []byte,
	digest uint32,
	decode func([]byte) (M, error),
) *SyslinkPending[M] {
	local, isLocal := resolveLocal(addr)

	target := uint64(0)
	node := ""
	if isLocal {
		target = local.id
	} else {
		node = addr.Endpoint
	}
	ref, ch := awaitRef(target, node)
	p := &SyslinkPending[M]{ref: ref, reply: ch, decode: decode}

	if isLocal {
		if syslinkStrict() {
			local.post(delivery{raw: encode(msg), digest: digest, ref: ref, origin: ""})
		} else {
			local.post(delivery{value: msg, ref: ref, origin: ""})
		}
		return p
	}
	if addr.Endpoint == "" || addr.Endpoint == SyslinkNode() {
		dropRef(ref)
		p.settle(syslinkErr[M](missingLocal(addr)))
		return p
	}
	if err := sendFrame(addr.Endpoint, frame{
		kind:    kindRequest,
		name:    addr.Name,
		id:      addr.Id,
		ref:     ref,
		digest:  digest,
		payload: encode(msg),
	}); err != nil {

		// Unreachable before the request even left: settle now, so awaiting is
		// instant rather than a pointless wait for an answer that cannot come.
		dropRef(ref)
		p.settle(syslinkErr[M](err.Reason, err.Message))
	}
	return p
}

func (p *SyslinkPending[M]) settle(r Result[M, SyslinkSyslinkError]) {
	p.mu.Lock()
	p.resolved = true
	p.result = r
	p.mu.Unlock()
}

// SyslinkAwait waits for the answer to a request. This is the one place in the
// module that reports failure, because it is the one place with somewhere to
// report it to: a timeout, a service that died mid-request and an unreachable
// node all arrive here as a Result.Error.
//
// A settled answer is remembered, so awaiting twice returns it instantly. A
// timeout is not: the request is still outstanding and the answer may yet
// arrive, so the same handle can be awaited again with more patience.
func SyslinkAwait[M any](p *SyslinkPending[M], ms int) Result[M, SyslinkSyslinkError] {
	if p == nil {
		return syslinkErr[M]("NoProc", "there is no request to wait for")
	}
	p.mu.Lock()
	if p.resolved {
		r := p.result
		p.mu.Unlock()
		return r
	}
	p.mu.Unlock()

	if ms <= 0 {
		ms = syslinkDefaultWait
	}
	timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
	defer timer.Stop()

	select {
	case a := <-p.reply:
		r := p.interpret(a)
		p.settle(r)
		return r
	case <-timer.C:
		return syslinkErr[M]("Timeout", "no answer within "+strconv.Itoa(ms)+"ms")
	}
}

func (p *SyslinkPending[M]) interpret(a answer) Result[M, SyslinkSyslinkError] {
	if a.err != nil {
		return Err[M, SyslinkSyslinkError](*a.err)
	}
	if a.raw != nil {
		v, err := p.decode(a.raw)
		if err != nil {
			return syslinkErr[M]("Decode", "the answer did not match this service's message type: "+err.Error())
		}
		return Ok[M, SyslinkSyslinkError](v)
	}
	v, fits := a.value.(M)
	if !fits {
		return syslinkErr[M]("Decode", "the service answered with a value that is not one of its own messages")
	}
	return Ok[M, SyslinkSyslinkError](v)
}

// SyslinkAwaitAll is the barrier behind await on a vector of requests: one
// deadline across all of them, so a laggard becomes a Timeout error in its own
// slot rather than failing the whole vector.
func SyslinkAwaitAll[M any](ps []*SyslinkPending[M], ms int) []Result[M, SyslinkSyslinkError] {
	if ms <= 0 {
		ms = syslinkDefaultWait
	}
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	out := make([]Result[M, SyslinkSyslinkError], len(ps))
	for i, p := range ps {
		left := int(time.Until(deadline) / time.Millisecond)
		if left <= 0 {
			left = 1
		}
		out[i] = SyslinkAwait(p, left)
	}
	return out
}

// ---------------------------------------------------------------------------
// Monitors
// ---------------------------------------------------------------------------
//
// The target's node holds the registration and reports the death. Keep a
// local record too, so losing the node fires the monitor even though the
// service itself never got the chance to.
func SyslinkMonitor[M any](by SyslinkAddress, target SyslinkAddress, msg M, encode func(M) []byte, digest uint32) {
	me, ok := resolveLocal(by)
	if !ok {
		return
	}
	if b, ok := resolveLocal(target); ok {
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			me.post(delivery{value: msg, origin: ""})
			return
		}
		b.watchers = append(b.watchers, watcher{box: me, value: msg})
		b.mu.Unlock()
		return
	}
	mon := monSeq.Add(1)
	w := watcher{box: me, value: msg, mon: mon}
	rememberRemoteWatch(target.Endpoint, w)
	if err := sendFrame(target.Endpoint, frame{
		kind:    kindMonitor,
		name:    target.Name,
		id:      target.Id,
		watcher: me.id,
		ref:     mon,
		digest:  digest,
		payload: encode(msg),
	}); err != nil {

		// A node we cannot even reach is indistinguishable from a service that
		// has already died, so the monitor fires now rather than waiting for a
		// connection that may never exist.
		forgetRemoteWatch(target.Endpoint, mon)
		notifyWatcher(w)
	}
}

// registerRemoteWatcher records a monitor asked for by another node.
func registerRemoteWatcher(target SyslinkAddress, from string, watcherID, mon uint64, payload []byte, digest uint32) {
	w := watcher{node: from, id: watcherID, mon: mon, payload: payload, digest: digest}
	b, ok := resolveLocal(target)
	if !ok {
		notifyWatcher(w)
		return
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		notifyWatcher(w)
		return
	}
	b.watchers = append(b.watchers, w)
	b.mu.Unlock()
}

// SyslinkDigest is the structural fingerprint of a message type, carried in
// every frame so a peer built from a different declaration fails loudly instead
// of decoding another type's bytes into this one.
//
// The compiler writes the type's signature and the hash is taken here rather
// than there: FNV-1a wants exclusive-or and a byte's value, and Hive has
// neither. What matters is that both ends compute the same number.
func SyslinkDigest(signature string) uint32 {
	hash := uint32(2166136261)
	for _, b := range []byte(signature) {
		hash ^= uint32(b)
		hash *= 16777619
	}
	return hash
}
