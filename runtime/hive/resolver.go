// Android has no `/etc/resolv.conf`: its resolvers live in a service, and Go's
// own note on the matter is that a name needs the cgo resolver there. With no
// cgo there is none, so the pure resolver falls back to `127.0.0.1:53` and
// every lookup fails against a server nothing is running. The host writes the
// addresses it is using into a file, and this dials those instead.
//
// Required by `net`, `syslink` and `sql` — the three that resolve a name — so a
// program that touches no network carries none of it.
package hive

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Installed before any lookup can happen: this package's init runs after
// `net` is itself initialised and before any Hive code.
func init() {
	if runtime.GOOS != "android" {
		return
	}
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: resolverDial}
}

// The address handed in is the one read out of a resolv.conf that is not
// there, so it is dropped and a real server dialled in its place. Each in
// turn, because the first may be on an interface that has just gone.
func resolverDial(ctx context.Context, network string, _ string) (net.Conn, error) {
	servers := resolvers()
	if len(servers) == 0 {
		return nil, errors.New("no resolver: nothing has written " +
			resolverFile() + ", so a name cannot be looked up here")
	}
	var dialer net.Dialer
	var last error
	for _, server := range servers {
		conn, err := dialer.DialContext(ctx, network, server)
		if err == nil {
			return conn, nil
		}
		last = err
	}
	return nil, last
}

// Read again whenever the file has been written, which is what makes a
// handset moving between networks keep working: the host rewrites it and
// the next lookup sees the new servers.
var resolverMu sync.Mutex
var resolverStamp time.Time
var resolverCache []string

func resolvers() []string {
	path := resolverFile()
	if path == "" {
		return nil
	}
	resolverMu.Lock()
	defer resolverMu.Unlock()
	at, err := os.Stat(path)
	if err != nil {
		resolverCache = nil
		resolverStamp = time.Time{}
		return nil
	}
	if at.ModTime().Equal(resolverStamp) {
		return resolverCache
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return resolverCache
	}
	resolverStamp = at.ModTime()
	resolverCache = resolverAddresses(string(body))
	return resolverCache
}

func resolverFile() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".hive", "resolvers")
}

// One address a line, a blank line or a `#` ignored. A port is added where
// none was written — SplitHostPort refuses both a bare v4 address and a
// bare v6 one, and JoinHostPort brackets the second.
func resolverAddresses(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if _, _, err := net.SplitHostPort(line); err != nil {
			line = net.JoinHostPort(line, "53")
		}
		out = append(out, line)
	}
	return out
}
