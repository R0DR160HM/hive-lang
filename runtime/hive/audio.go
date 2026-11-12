// The Go for `hive.audio`: sound that is not in a scene — a recording or a live
// stream, played by name until it is stopped. It is a module of its own and asks
// nothing of `hive.ui`: what it keeps is which streams the program wants, and it
// offers the window, should the program open one, a script that plays them and a
// route that tells it when they change. A Hive program's sound is played by its
// window, a scene's included, because that is where the platform's decoders are.
package hive

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"sync"
)

// What the program wants playing, by the name it gave each — the name is the
// stream's identity, as a sound's is in a scene — and a channel closed and
// replaced each time that changes, which is how a page waiting on it wakes.
type audioStream struct {
	URL    string  `json:"url"`
	Volume float64 `json:"volume"`
}

var audioMu sync.Mutex
var audioStreams = map[string]audioStream{}
var audioChanged = make(chan struct{})

func audioTell() {
	close(audioChanged)
	audioChanged = make(chan struct{})
}

// Asking for what is already playing changes nothing, so a program may say
// what it wants every frame and the page hears only when that differs.
func AudioPlay(name string, url string, volume float64) {
	want := audioStream{URL: url, Volume: math.Max(0, math.Min(volume, 1))}
	audioMu.Lock()
	defer audioMu.Unlock()
	if had, ok := audioStreams[name]; ok && had == want {
		return
	}
	audioStreams[name] = want
	audioTell()
}

func AudioStop(name string) {
	audioMu.Lock()
	defer audioMu.Unlock()
	if _, ok := audioStreams[name]; !ok {
		return
	}
	delete(audioStreams, name)
	audioTell()
}

// Every stream wanted, as server-sent events: the whole set when the page
// connects and again whenever it changes. A page reloaded reconnects by itself
// and is told the whole set again.
func audioEvents(rw http.ResponseWriter, req *http.Request) {
	flusher, ok := rw.(http.Flusher)
	if !ok {
		http.Error(rw, "no streaming here", http.StatusInternalServerError)
		return
	}
	rw.Header().Set("Content-Type", "text/event-stream")
	rw.Header().Set("Cache-Control", "no-store")
	for {
		audioMu.Lock()
		said, _ := json.Marshal(audioStreams)
		changed := audioChanged
		audioMu.Unlock()
		fmt.Fprintf(rw, "data: %s\n\n", said)
		flusher.Flush()
		select {
		case <-changed:
		case <-req.Context().Done():
			return
		}
	}
}

func audioScript(rw http.ResponseWriter, _ *http.Request) {
	rw.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	rw.Header().Set("Cache-Control", "no-store")
	_, _ = rw.Write([]byte(audioJS))
}

func init() {
	hivePageScripts = append(hivePageScripts, "<script src=\"/_hive/audio.js\"></script>")
	hivePageRoutes["/_hive/audio"] = audioEvents
	hivePageRoutes["/_hive/audio.js"] = audioScript
}

// The page's half: an audio element per stream, which is the browser's own
// decoder and buffering, so a live stream is no different from a file.
//
// A page may not make a noise until somebody has touched it, and says so by
// refusing play rather than by failing loudly; a stream refused is tried
// again on every touch until one takes. One that drops — a station's server
// restarting, a network coming back — is picked up again after a moment
// rather than left silent, because a live stream has no end to reach.
const audioJS = `(function () {
  var playing = {};
  function attempt(el) {
    var p = el.play();
    if (p && p.catch) { p.catch(function () {}); }
  }
  function start(name, want) {
    var el = new Audio();
    el.preload = "none";
    el.volume = want.volume;
    el.src = want.url;
    playing[name] = { url: want.url, el: el };
    var again = function () {
      setTimeout(function () {
        var now = playing[name];
        if (now && now.el === el) { el.src = want.url; attempt(el); }
      }, 2000);
    };
    el.addEventListener("error", again);
    el.addEventListener("ended", again);
    attempt(el);
  }
  function stop(name) {
    var el = playing[name].el;
    delete playing[name];
    el.pause();
    el.removeAttribute("src");
    el.load();
  }
  function apply(wanted) {
    var name;
    for (name in playing) {
      if (!wanted[name] || wanted[name].url !== playing[name].url) { stop(name); }
    }
    for (name in wanted) {
      if (!playing[name]) { start(name, wanted[name]); }
      else { playing[name].el.volume = wanted[name].volume; }
    }
  }
  function nudge() {
    for (var name in playing) {
      if (playing[name].el.paused) { attempt(playing[name].el); }
    }
  }
  ["pointerdown", "keydown", "touchstart"].forEach(function (kind) {
    addEventListener(kind, nudge, true);
  });
  new EventSource("/_hive/audio").onmessage = function (e) { apply(JSON.parse(e.data)); };
})();
`
