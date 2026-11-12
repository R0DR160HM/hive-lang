// The wire half of `hive.syslink`: one persistent, multiplexed, mutually
// authenticated TLS connection per node pair, dialed lazily, carrying
// length-prefixed frames. It carries no markers of its own because nothing in Hive
// source names it — it arrives because `hive.syslink` is written against it.
package hive

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// hive.syslink — the wire
// ---------------------------------------------------------------------------
// One persistent, multiplexed connection per node pair, carrying
// length-prefixed frames. Message order is guaranteed between a pair of nodes,
// which means exactly one FIFO pipe per pair.
//
// The connection is symmetric, so a node that can only dial out still takes
// part fully. Either end may dial, and when both do at once exactly one
// survives — see install.
//
// Every connection is TLS 1.3, mutually authenticated, always: no plaintext
// path and no flag to negotiate one away. Certificates are generated at boot
// and thrown away — they carry keys, not identity. Identity comes from a
// cluster secret proven over the pair of certificates as each side locally
// sees them, which stops an attacker terminating TLS on both sides from
// relaying one side's proof to the other.
const (
	syslinkMagic = "HIVE-SL1"

	// The period between health checks while a peer is answering, and how much a
	// check that went unanswered brings the next one forward. A peer that looks
	// unwell is probed *more* eagerly rather than less: 15s, then 10s, then 5s.
	//
	// Then the two sizes: a frame larger than `syslinkMaxFrame` is refused rather
	// than buffered, and past `syslinkMaxOutbox` a node is declared unreachable.
	syslinkTickEvery = 15 * time.Second
	syslinkTickStep  = 5 * time.Second
	syslinkMaxFrame  = 8 << 20
	syslinkMaxOutbox = 64 << 20
)

// syslinkSilenceBudget is how long a peer may go without a word before its
// connection is declared dead: the sum of the shrinking probe periods. Deriving
// it keeps those two constants the only place the timing is written down.
//
// kindNoProc answers a request that found no service, or whose service died
// before it could answer. It is a distinct kind rather than an empty reply
// because an empty reply is a legitimate answer.
//
// kindDown reports a death to a monitor on another node. id is the
// watching mailbox, ref the monitor id it was registered under, and the
// payload is the death message the watcher chose.
func syslinkSilenceBudget() time.Duration {
	total := time.Duration(0)
	for wait := syslinkTickEvery; wait > 0; wait -= syslinkTickStep {
		total += wait
	}
	return total
}

type frameKind byte

const (
	kindCast frameKind = iota + 1
	kindRequest
	kindReply
	kindMonitor
	kindStop
	kindTick
	kindNoProc
	kindDown

	// kindPong answers a kindTick, which is what makes a health check a round
	// trip. "Somebody said something lately" is not enough: both ends probe on
	// schedules of their own, so a period that happens not to line up would
	// read as silence from a peer that is perfectly healthy.
	kindPong
)

// frame is one multiplexed message. name addresses a registered service and
// travels as text, because atom ids are assigned per build: #Cache may be 7 in
// one binary and 11 in another. id addresses an anonymous mailbox instead.
type frame struct {
	kind    frameKind
	name    Atom
	id      uint64
	ref     uint64
	watcher uint64
	digest  uint32
	payload []byte
}

// ---------------------------------------------------------------------------
// Node identity and peer endpoints
// ---------------------------------------------------------------------------
//
// What this node tells peers to dial it on. It is an endpoint, not a name:
// there is no cluster-wide namespace to register in and nothing to collide
// over, and where a node lives is configuration rather than source.
//
// Live connections, keyed by the peer's *advertised* endpoint rather than by
// whatever string was dialed. That canonical key is what stops
// "localhost:9101" and "127.0.0.1:9101" opening two connections to the same
// node — which would quietly break the ordering guarantee.
var (
	nodeMu       sync.RWMutex
	selfEndpoint string
	sessions     = map[string]*session{}

	// as-dialed endpoint -> the peer's advertised endpoint, so a repeat send
	// finds the existing connection without dialing again. `watches` holds the
	// local watchers waiting on a remote node.
	dialed    = map[string]string{}
	watchesMu sync.Mutex
	watches   = map[string][]watcher{}
	monSeq    atomic.Uint64
)

// SyslinkNode is the endpoint this node advertises.
func SyslinkNode() string {
	nodeMu.RLock()
	defer nodeMu.RUnlock()
	return selfEndpoint
}

// SyslinkPeers is every node this one is connected to right now, each as the
// endpoint it advertised — the string to hand to on, not whatever was dialed.
//
// It needs no bookkeeping of its own because a connection is the record: both
// ends share one, filed under the peer's advertised endpoint. So sending to a
// node puts it in this list, a node that dials in appears without this node
// doing anything, and losing the connection takes it out again.
//
// Sorted: a Go map has no order, and a peer list that reshuffles between two
// reads is miserable to program against. Backs hive.syslink.peers.
func SyslinkPeers() []string {
	nodeMu.RLock()
	peers := make([]string, 0, len(sessions))
	for node := range sessions {
		peers = append(peers, node)
	}
	nodeMu.RUnlock()
	sort.Strings(peers)
	return peers
}

// SyslinkListen starts accepting connections from other nodes. endpoint is what
// this node tells peers to dial it on. The port is taken from it and bound on
// every interface — only a loopback host is bound as written, since nothing
// off this machine could dial it anyway; the whole string is advertised, which
// lets an address handed to one node stay dialable when passed on to a third.
//
// There is no port-mapper daemon and no cluster-wide name registry: a node is
// simply where it is.
//
// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------
func bindHost(endpoint, port string) string {
	host := strings.Trim(strings.TrimSuffix(endpoint, ":"+port), "[]")
	if ip := net.ParseIP(host); host == "localhost" || (ip != nil && ip.IsLoopback()) {
		return host
	}
	return ""
}

func SyslinkListen(endpoint string) Result[string, SyslinkSyslinkError] {
	if _, err := clusterSecret(); err != nil {
		return syslinkErr[string]("NoKey", err.Error())
	}
	cert, err := ephemeralCert()
	if err != nil {
		return syslinkErr[string]("NoKey", "could not generate this node's key: "+err.Error())
	}
	port := endpoint
	if i := strings.LastIndex(endpoint, ":"); i >= 0 {
		port = endpoint[i+1:]
	}
	if _, err := strconv.Atoi(port); err != nil {
		return syslinkErr[string]("NoListener",
			"`"+endpoint+"` is not a host:port this node can listen on")
	}
	ln, err := tls.Listen("tcp", net.JoinHostPort(bindHost(endpoint, port), port), serverTLS(cert))
	if err != nil {
		return syslinkErr[string]("NoListener", "could not listen on port "+port+": "+err.Error())
	}

	// A node is identified by where it can be dialed, so a port the kernel chose
	// replaces the 0 that asked for it. The host is left as written — what this
	// machine advertises is the program's to answer, with hive.net.localAddress.
	if shown := ln.Addr().String(); strings.LastIndex(shown, ":") >= 0 {
		bound := shown[strings.LastIndex(shown, ":")+1:]
		endpoint = endpoint[:len(endpoint)-len(port)] + bound
	}
	nodeMu.Lock()
	selfEndpoint = endpoint
	nodeMu.Unlock()

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go acceptSession(conn.(*tls.Conn))
		}
	}()
	return Ok[string, SyslinkSyslinkError](endpoint)
}

// session is one connection to one peer node, with an unbounded outbox drained
// by a single writer goroutine. send therefore never touches the socket on the
// caller's goroutine and never blocks.
//
// The peer's advertised endpoint, learned in the handshake.
type session struct {
	node string
	conn *tls.Conn

	// Which end dialed. Both nodes have to agree on which of two simultaneous
	// connections survives, and direction is the only thing they can compare
	// without another round trip.
	outbound bool

	mu     sync.Mutex
	cond   *sync.Cond
	out    [][]byte
	bytes  int
	closed bool

	lastSeen time.Time
}

func newSession(node string, conn *tls.Conn, outbound bool) *session {
	s := &session{node: node, conn: conn, outbound: outbound, lastSeen: time.Now()}
	s.cond = sync.NewCond(&s.mu)
	return s
}

// enqueue queues an encoded frame. Past the water mark the peer is declared
// unreachable rather than growing the queue without bound: that turns an
// unbounded memory problem into the failure the programmer already handles.
func (s *session) enqueue(b []byte) bool {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return false
	}
	if s.bytes+len(b) > syslinkMaxOutbox {
		s.mu.Unlock()
		s.shutdown("the outbox passed " + strconv.Itoa(syslinkMaxOutbox) + " bytes")
		return false
	}
	s.out = append(s.out, b)
	s.bytes += len(b)
	s.mu.Unlock()
	s.cond.Signal()
	return true
}

func (s *session) drain() ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for len(s.out) == 0 && !s.closed {
		s.cond.Wait()
	}
	if len(s.out) == 0 {
		return nil, false
	}
	b := s.out[0]
	s.out = s.out[1:]
	s.bytes -= len(b)
	return b, true
}

// shutdown drops the connection and reports the node down: every call waiting
// on it fails, and every local watcher on one of its services is told. Queued
// messages are discarded — delivery is best-effort.
func (s *session) shutdown(reason string) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.out = nil
	s.bytes = 0
	s.mu.Unlock()
	s.cond.Broadcast()
	s.conn.Close()

	nodeMu.Lock()
	if sessions[s.node] == s {
		delete(sessions, s.node)
	}
	for typed, canonical := range dialed {
		if canonical == s.node {
			delete(dialed, typed)
		}
	}
	nodeMu.Unlock()

	failCallsToNode(s.node, "the node at "+s.node+" is unreachable: "+reason)
	nodeDown(s.node)
	fmt.Fprintln(os.Stderr, "hive: the node at "+s.node+" is down ("+reason+")")
}

func (s *session) writer() {
	w := bufio.NewWriter(s.conn)
	for {
		b, ok := s.drain()
		if !ok {
			return
		}
		if _, err := w.Write(b); err != nil {
			s.shutdown("write failed: " + err.Error())
			return
		}

		// Flush only when the queue has drained, so a burst of sends becomes one
		// write without ever leaving a message sitting in the buffer.
		//
		// A read deadline one step behind the health check, as a backstop for a
		// connection that is wedged rather than idle. The check is meant to win that
		// race: it knows the peer stopped answering, where a deadline can only
		// report that nothing arrived.
		s.mu.Lock()
		more := len(s.out) > 0
		s.mu.Unlock()
		if !more {
			if err := w.Flush(); err != nil {
				s.shutdown("flush failed: " + err.Error())
				return
			}
		}
	}
}

func (s *session) reader() {
	r := bufio.NewReader(s.conn)
	quiet := syslinkSilenceBudget() + syslinkTickStep
	for {
		s.conn.SetReadDeadline(time.Now().Add(quiet))
		f, err := readFrame(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				s.shutdown("the peer hung up")
			} else {
				s.shutdown("read failed: " + err.Error())
			}
			return
		}
		s.mu.Lock()
		s.lastSeen = time.Now()
		s.mu.Unlock()
		switch f.kind {
		case kindTick:
			s.enqueue(writeFrame(frame{kind: kindPong}))
		case kindPong:

			// The stamp above was the whole point of it.
		default:
			routeFrame(s.node, f)
		}
	}
}

// ticker is the health check. It sends a probe, and if nothing has come back by
// the time the next falls due it brings that one forward by syslinkTickStep —
// 15s, then 10s, then 5s, and then the peer is declared unreachable. Silence
// costs 30 seconds rather than the 45 a fixed period would spend.
//
// Any frame counts as an answer, since anything arriving proves what a pong
// proves; one word from the peer puts the period back to full.
func (s *session) ticker() {
	wait := syslinkTickEvery

	// The first probe goes out now rather than a period from now, so the first
	// look at lastSeen is asking after an answer this node actually asked for.
	probed := time.Now()
	s.enqueue(writeFrame(frame{kind: kindTick}))
	for {
		time.Sleep(wait)
		s.mu.Lock()
		closed, answered := s.closed, s.lastSeen.After(probed)
		s.mu.Unlock()
		if closed {
			return
		}
		if answered {
			wait = syslinkTickEvery
		} else {
			wait -= syslinkTickStep
			if wait <= 0 {
				s.shutdown("it answered no health check in " + syslinkSilenceBudget().String())
				return
			}
		}
		probed = time.Now()
		s.enqueue(writeFrame(frame{kind: kindTick}))
	}
}

func (s *session) start() {
	go s.writer()
	go s.reader()
	go s.ticker()
}

// sessionFor hands back the live connection to a node, dialing one if there is
// none. It is the only place a connection is created, so a node pair can never
// end up with two.
func sessionFor(endpoint string) (*session, *SyslinkSyslinkError) {
	if endpoint == "" {
		return nil, &SyslinkSyslinkError{Reason: "NoPeer", Message: "the address does not say where its node is"}
	}
	nodeMu.RLock()
	canonical, known := dialed[endpoint]
	s, ok := sessions[endpoint]
	if !ok && known {
		s, ok = sessions[canonical]
	}
	nodeMu.RUnlock()
	if ok {
		return s, nil
	}
	if SyslinkNode() == "" {
		return nil, &SyslinkSyslinkError{
			Reason:  "NoListener",
			Message: "this node is not listening yet — call hive.syslink.listen before addressing another node",
		}
	}
	return dialSession(endpoint)
}

func dialSession(endpoint string) (*session, *SyslinkSyslinkError) {
	cert, err := ephemeralCert()
	if err != nil {
		return nil, &SyslinkSyslinkError{Reason: "NoKey", Message: err.Error()}
	}
	raw, err := tls.Dial("tcp", endpoint, clientTLS(cert))
	if err != nil {
		return nil, &SyslinkSyslinkError{
			Reason:  "Unreachable",
			Message: "could not reach the node at " + endpoint + ": " + err.Error(),
		}
	}

	// The peer's own advertised endpoint comes back from the handshake, and that
	// is what the connection is filed under — not the string that was dialed.
	advertised, err := handshakeInitiator(raw)
	if err != nil {
		raw.Close()
		return nil, &SyslinkSyslinkError{Reason: "Unreachable", Message: err.Error()}
	}
	nodeMu.Lock()
	dialed[endpoint] = advertised
	nodeMu.Unlock()
	return install(advertised, raw, true)
}

// install adopts a freshly authenticated connection. Without a tiebreak a pair
// of nodes that dial each other at once ends up with two pipes, silently
// breaking the ordering guarantee — so exactly one survives: the one dialed by
// the lexicographically smaller node name.
//
// Each side asks only "should this connection have been dialed by me?", and
// since the two disagree in exactly the complementary way they always keep the
// same TCP connection. Comparing anything local — which arrived first, say — is
// what the earlier version got wrong: each then closed the other's.
func install(node string, conn *tls.Conn, outbound bool) (*session, *SyslinkSyslinkError) {
	keep := preferOutbound(node) == outbound

	nodeMu.Lock()
	existing, clash := sessions[node]
	if clash {
		if !keep {
			nodeMu.Unlock()
			conn.Close()
			return existing, nil
		}
		delete(sessions, node)
	}
	s := newSession(node, conn, outbound)
	sessions[node] = s
	nodeMu.Unlock()

	if clash {

		// A replaced duplicate is not a node going down: nothing failed, and
		// reporting it would fire monitors for a peer that is perfectly healthy.
		existing.closeQuietly()
	}
	s.start()
	return s, nil
}

// preferOutbound: whether the surviving connection to node is the one this
// node dialed. True for the lexicographically smaller name, so the two ends
// always reach complementary answers.
func preferOutbound(node string) bool {
	return SyslinkNode() < node
}

// closeQuietly drops a connection without declaring the node down.
func (s *session) closeQuietly() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.out = nil
	s.bytes = 0
	s.mu.Unlock()
	s.cond.Broadcast()
	s.conn.Close()
}

func acceptSession(conn *tls.Conn) {
	peer, err := handshakeResponder(conn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "hive: rejected a connection: "+err.Error())

		// Tell the caller it was turned away, without saying which check failed:
		// "EOF" is a miserable thing to debug against, and an unauthenticated
		// caller has no business learning why.
		reject := append([]byte(syslinkMagic), 0, 0)
		conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		conn.Write(reject)
		conn.Close()
		return
	}
	install(peer, conn, false)
}

// sendFrame is the one path out of this node. A failure to reach the peer is
// reported back for call to turn into a Result.Error; a cast ignores it,
// because a send never fails at its own call site.
func sendFrame(endpoint string, f frame) *SyslinkSyslinkError {
	s, err := sessionFor(endpoint)
	if err != nil {
		return err
	}
	if !s.enqueue(writeFrame(f)) {
		return &SyslinkSyslinkError{Reason: "Unreachable", Message: "the node at " + endpoint + " is unreachable"}
	}
	return nil
}

// routeFrame hands an arrived frame to its mailbox. The payload is not decoded
// here: that happens on the recipient's own turn, so a bad message cannot take
// down a connection shared with every other service on this node.
//
// The reason travels ahead of the message, so a "never answered" is not
// flattened into a "no such service".
func routeFrame(from string, f frame) {
	switch f.kind {
	case kindCast, kindRequest:
		dest := SyslinkAddress{Name: f.name, Id: f.id}
		b, ok := resolveLocal(dest)
		if !ok {
			if f.kind == kindRequest {
				sendFrame(from, frame{
					kind:    kindNoProc,
					ref:     f.ref,
					payload: []byte("NoProc|no service is registered here under that name"),
				})
			}
			return
		}
		ref := uint64(0)
		origin := ""
		if f.kind == kindRequest {
			ref = f.ref
			origin = from
		}
		b.post(delivery{raw: f.payload, digest: f.digest, ref: ref, origin: origin})
	case kindReply:
		deliverAnswer(f.ref, answer{raw: f.payload})
	case kindNoProc:
		reason, message := "NoProc", string(f.payload)
		if i := strings.Index(message, "|"); i >= 0 {
			reason, message = message[:i], message[i+1:]
		}
		deliverAnswer(f.ref, answer{err: &SyslinkSyslinkError{Reason: reason, Message: message}})
	case kindMonitor:
		registerRemoteWatcher(
			SyslinkAddress{Name: f.name, Id: f.id},
			from, f.watcher, f.ref, f.payload, f.digest)
	case kindDown:

		// The death was reported, so the fallback record for this monitor is
		// spent: dropping it here is what keeps a monitor one-shot when the node
		// goes on to disappear as well.
		forgetRemoteWatch(from, f.ref)
		if b, ok := boxes.Load(f.id); ok {
			b.(*mailbox).post(delivery{raw: f.payload, digest: f.digest, origin: ""})
		}
	case kindStop:
		if b, ok := resolveLocal(SyslinkAddress{Name: f.name, Id: f.id}); ok {
			b.die("killed")
		}
	}
}

// rememberRemoteWatch records that a local service is waiting on a service that
// lives on another node, so that losing the node fires the monitor.
func rememberRemoteWatch(node string, w watcher) {
	watchesMu.Lock()
	watches[node] = append(watches[node], w)
	watchesMu.Unlock()
}

func forgetRemoteWatch(node string, mon uint64) {
	watchesMu.Lock()
	defer watchesMu.Unlock()
	kept := watches[node][:0]
	for _, w := range watches[node] {
		if w.mon != mon {
			kept = append(kept, w)
		}
	}
	if len(kept) == 0 {
		delete(watches, node)
		return
	}
	watches[node] = kept
}

func nodeDown(node string) {
	watchesMu.Lock()
	ws := watches[node]
	delete(watches, node)
	watchesMu.Unlock()
	for _, w := range ws {
		notifyWatcher(w)
	}
}

// ---------------------------------------------------------------------------
// Frame codec
// ---------------------------------------------------------------------------
func writeFrame(f frame) []byte {
	name := ""
	if f.name != atomNone {
		name = f.name.String()
	}
	body := make([]byte, 0, 32+len(name)+len(f.payload))
	body = append(body, byte(f.kind))
	body = binary.BigEndian.AppendUint64(body, f.ref)
	body = binary.BigEndian.AppendUint64(body, f.id)
	body = binary.BigEndian.AppendUint64(body, f.watcher)
	body = binary.BigEndian.AppendUint32(body, f.digest)
	body = binary.BigEndian.AppendUint16(body, uint16(len(name)))
	body = append(body, name...)
	body = binary.BigEndian.AppendUint32(body, uint32(len(f.payload)))
	body = append(body, f.payload...)

	out := binary.BigEndian.AppendUint32(make([]byte, 0, 4+len(body)), uint32(len(body)))
	return append(out, body...)
}

func readFrame(r *bufio.Reader) (frame, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return frame{}, err
	}
	size := binary.BigEndian.Uint32(head[:])
	if size > syslinkMaxFrame {
		return frame{}, fmt.Errorf("frame of %d bytes exceeds the %d byte limit", size, syslinkMaxFrame)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return frame{}, err
	}
	if len(body) < 31 {
		return frame{}, errors.New("truncated frame header")
	}
	f := frame{kind: frameKind(body[0])}
	f.ref = binary.BigEndian.Uint64(body[1:9])
	f.id = binary.BigEndian.Uint64(body[9:17])
	f.watcher = binary.BigEndian.Uint64(body[17:25])
	f.digest = binary.BigEndian.Uint32(body[25:29])
	nameLen := int(binary.BigEndian.Uint16(body[29:31]))
	rest := body[31:]
	if len(rest) < nameLen+4 {
		return frame{}, errors.New("truncated frame name")
	}
	f.name = atomNone
	if nameLen > 0 {
		f.name = atomByName(string(rest[:nameLen]))
	}
	rest = rest[nameLen:]
	payloadLen := int(binary.BigEndian.Uint32(rest[:4]))
	rest = rest[4:]
	if len(rest) < payloadLen {
		return frame{}, errors.New("truncated frame payload")
	}
	f.payload = rest[:payloadLen]
	return f, nil
}

// atomByName resolves a name that arrived from the wire back to this build's
// atom. A name this binary never compiled resolves to no atom, so the frame is
// routed nowhere — which is what a service that does not exist here means.
//
// ---------------------------------------------------------------------------
// Transport security
// ---------------------------------------------------------------------------
var (
	atomIndexOnce sync.Once
	atomIndex     map[string]Atom
)

func atomByName(name string) Atom {
	atomIndexOnce.Do(func() {
		atomIndex = make(map[string]Atom, len(atomNames))
		for i, n := range atomNames {
			atomIndex[n] = Atom(i)
		}
	})
	if a, ok := atomIndex[name]; ok {
		return a
	}
	return atomNone
}

// clusterSecret is what proves a peer belongs. It never crosses the wire and
// never encrypts anything: TLS 1.3 is always ECDHE, so leaking this secret
// tomorrow does not decrypt traffic captured today.
var (
	secretOnce sync.Once
	secretVal  Secret
	secretErr  error
	chosenMu   sync.RWMutex
	chosenKey  Secret
)

func clusterSecret() (Secret, error) {
	chosenMu.RLock()
	chosen := chosenKey
	chosenMu.RUnlock()
	if chosen.p != nil {
		return chosen, nil
	}
	secretOnce.Do(func() {
		if env := os.Getenv("HIVE_SYSLINK_KEY"); env != "" {
			secretVal, secretErr = keptKey([]byte(env))
			return
		}
		home, err := os.UserHomeDir()
		if err != nil {
			secretErr = errors.New("no HIVE_SYSLINK_KEY is set and this machine has no home directory to keep one in")
			return
		}
		dir := filepath.Join(home, ".hive")
		path := filepath.Join(dir, "syslink.key")
		if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
			secretVal, secretErr = keptKey(b)
			return
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			secretErr = errors.New("could not create " + dir + ": " + err.Error())
			return
		}
		fresh := make([]byte, 32)
		if _, err := rand.Read(fresh); err != nil {
			secretErr = err
			return
		}
		if err := os.WriteFile(path, fresh, 0o600); err != nil {
			secretErr = errors.New("could not write " + path + ": " + err.Error())
			return
		}
		secretVal, secretErr = keptKey(fresh)
	})
	return secretVal, secretErr
}

func keptKey(b []byte) (Secret, error) {
	s, err := hideBytes(b)
	if err != nil {
		return s, errors.New("the cluster key: " + err.Message)
	}
	return s, nil
}

// SyslinkSetKey is this program's key from here on, held in memory and nowhere
// else. A connection made or accepted after it proves itself with it; one already
// open stays as it is.
func SyslinkSetKey(key Secret) {
	if len(key.bytes()) == 0 {
		panic("hive: syslink.setKey: an empty key proves nothing about who holds it")
	}
	chosenMu.Lock()
	chosenKey = key
	chosenMu.Unlock()
}

// ephemeralCert is this node's certificate: a fresh Ed25519 key, self-signed,
// generated once at boot and never written to disk. It carries a key, not an
// identity — identity is established by the proof below.
var (
	certOnce sync.Once
	certVal  tls.Certificate
	certErr  error
)

func ephemeralCert() (tls.Certificate, error) {
	certOnce.Do(func() {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			certErr = err
			return
		}
		serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if err != nil {
			certErr = err
			return
		}
		template := x509.Certificate{
			SerialNumber:          serial,
			Subject:               pkix.Name{CommonName: "hive-syslink"},
			NotBefore:             time.Now().Add(-time.Hour),
			NotAfter:              time.Now().Add(24 * 365 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
		}
		der, err := x509.CreateCertificate(rand.Reader, &template, &template, pub, priv)
		if err != nil {
			certErr = err
			return
		}
		certVal = tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	})
	return certVal, certErr
}

func serverTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		MaxVersion:   tls.VersionTLS13,

		// Any certificate is accepted, because the certificate is not the
		// identity. Requiring one is what makes the peer's key available for the
		// binding below.
		ClientAuth: tls.RequireAnyClientCert,
	}
}

func clientTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
	}
}

// bindingProof ties knowledge of the cluster secret to this exact pair of
// certificates, as seen from one end. Both ends compute it from their own view
// and agree only when the same two certificates sit at the two ends. An
// attacker terminating TLS on both sides holds a proof over (peer, itself) and
// needs one over (itself, other peer), which it cannot produce.
func bindingProof(secret Secret, role string, mine, theirs []byte) []byte {
	defer runtime.KeepAlive(secret)
	mac := hmac.New(sha256.New, secret.bytes())
	mac.Write([]byte("hive-syslink-v1|"))
	mac.Write([]byte(role))
	mac.Write([]byte("|"))
	mac.Write(mine)
	mac.Write(theirs)
	return mac.Sum(nil)
}

func certHashes(conn *tls.Conn) (mine, theirs []byte, err error) {
	cert, err := ephemeralCert()
	if err != nil {
		return nil, nil, err
	}
	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil, nil, errors.New("the peer presented no certificate")
	}
	m := sha256.Sum256(cert.Certificate[0])
	t := sha256.Sum256(state.PeerCertificates[0].Raw)
	return m[:], t[:], nil
}

// handshakeInitiator runs the dialing half: prove we hold the cluster key,
// bound to this exact pair of certificates, and learn where the peer says it
// can be reached. That advertised endpoint is what the connection is filed
// under, so two spellings of the same node share one pipe.
//
// Note what is not checked: there is no node name to claim and none to verify.
// A node is identified by where it is, and you reached it by dialing there.
func handshakeInitiator(conn *tls.Conn) (string, error) {
	if err := conn.Handshake(); err != nil {
		return "", errors.New("TLS handshake failed: " + err.Error())
	}
	secret, err := clusterSecret()
	if err != nil {
		return "", err
	}
	mine, theirs, err := certHashes(conn)
	if err != nil {
		return "", err
	}

	hello := []byte(syslinkMagic)
	hello = appendString(hello, SyslinkNode())
	hello = append(hello, bindingProof(secret, "initiator", mine, theirs)...)
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(hello); err != nil {
		return "", err
	}

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(conn)
	magic := make([]byte, len(syslinkMagic))
	if _, err := io.ReadFull(r, magic); err != nil {
		return "", err
	}
	if string(magic) != syslinkMagic {
		return "", errors.New("the peer does not speak syslink")
	}
	advertised, err := readString(r)
	if err != nil {
		return "", err
	}
	if advertised == "" {
		return "", errors.New(
			"the peer turned this connection away — its cluster key does not match this node's")
	}
	proof := make([]byte, sha256.Size)
	if _, err := io.ReadFull(r, proof); err != nil {
		return "", err
	}
	want := bindingProof(secret, "responder", theirs, mine)
	if !hmac.Equal(proof, want) {
		return "", errors.New("the peer could not prove it shares this cluster's key")
	}
	conn.SetReadDeadline(time.Time{})
	conn.SetWriteDeadline(time.Time{})
	return advertised, nil
}

// handshakeResponder runs the accepting half and answers with its own advertised
// endpoint.
func handshakeResponder(conn *tls.Conn) (string, error) {
	if err := conn.Handshake(); err != nil {
		return "", errors.New("TLS handshake failed: " + err.Error())
	}
	secret, err := clusterSecret()
	if err != nil {
		return "", err
	}
	mine, theirs, err := certHashes(conn)
	if err != nil {
		return "", err
	}

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(conn)
	magic := make([]byte, len(syslinkMagic))
	if _, err := io.ReadFull(r, magic); err != nil {
		return "", err
	}
	if string(magic) != syslinkMagic {
		return "", errors.New("the caller does not speak syslink")
	}
	advertised, err := readString(r)
	if err != nil {
		return "", err
	}
	proof := make([]byte, sha256.Size)
	if _, err := io.ReadFull(r, proof); err != nil {
		return "", err
	}
	want := bindingProof(secret, "initiator", theirs, mine)
	if !hmac.Equal(proof, want) {
		return "", errors.New("the caller could not prove it shares this cluster's key")
	}
	if advertised == "" {
		return "", errors.New("the caller did not say where it can be reached")
	}

	hello := []byte(syslinkMagic)
	hello = appendString(hello, SyslinkNode())
	hello = append(hello, bindingProof(secret, "responder", mine, theirs)...)
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(hello); err != nil {
		return "", err
	}
	conn.SetReadDeadline(time.Time{})
	conn.SetWriteDeadline(time.Time{})

	// The reader goroutine takes over from here. Anything the caller pipelined
	// after its hello is still buffered in r, so hand that buffer on rather
	// than dropping it.
	if r.Buffered() > 0 {
		buffered, _ := io.ReadAll(io.LimitReader(r, int64(r.Buffered())))
		return advertised, pushBack(conn, buffered)
	}
	return advertised, nil
}

// pushBack is a guard rather than a mechanism: the handshake is strictly
// request/response, so a well-behaved peer never pipelines frames behind its
// hello. If one ever does, fail loudly instead of silently losing messages.
func pushBack(conn *tls.Conn, buffered []byte) error {
	if len(bytes.TrimSpace(buffered)) == 0 {
		return nil
	}
	return errors.New("the caller sent frames before its handshake was acknowledged")
}

func appendString(dst []byte, s string) []byte {
	dst = binary.BigEndian.AppendUint16(dst, uint16(len(s)))
	return append(dst, s...)
}

func readString(r *bufio.Reader) (string, error) {
	var head [2]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return "", err
	}
	n := int(binary.BigEndian.Uint16(head[:]))
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return "", err
	}
	return string(b), nil
}
