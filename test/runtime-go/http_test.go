package hive

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A line is handed over when it arrives, not when the body ends: the server
// holds the rest back until the client has read the first.
func TestALineArrivesBeforeTheBodyEnds(t *testing.T) {
	read := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "first\r\n")
		w.(http.Flusher).Flush()
		select {
		case <-read:
		case <-time.After(5 * time.Second):
			t.Error("the first line was not handed over while the body was still arriving")
		}
		io.WriteString(w, "second\nlast, with no newline")
	}))
	defer server.Close()

	opened := NetHttpOpen(NetHttpRequest{Method: "get", Url: server.URL})
	stream, ok := okOf(opened)
	if !ok || stream.Status != 200 {
		t.Fatalf("opened %+v", opened)
	}
	first := NetHttpReceiveLine(stream)
	close(read)
	for _, want := range []string{"first", "second", "last, with no newline"} {
		got := first
		if want != "first" {
			got = NetHttpReceiveLine(stream)
		}
		if line, ok := okOf(got); !ok || line != want {
			t.Fatalf("read %+v, want %q", got, want)
		}
	}
	ended := NetHttpReceiveLine(stream)
	if why, ok := errOf(ended); !ok || why.Reason != "Closed" || why.Message != "the body has ended" {
		t.Errorf("after the last line: %+v", ended)
	}
}

// Closing a stream from another thread lets go of a receive waiting on it, which
// answers Closed, and the server sees the connection go.
func TestClosingReleasesAWaitingReceive(t *testing.T) {
	gone := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(gone)
	}))
	defer server.Close()

	stream, _ := okOf(NetHttpOpen(NetHttpRequest{Method: "POST", Url: server.URL, Body: "{}"}))
	answered := make(chan Result[string, NetHttpStreamError], 1)
	go func() { answered <- NetHttpReceiveLine(stream) }()
	time.Sleep(100 * time.Millisecond)
	NetHttpClose(stream)
	NetHttpClose(stream)

	select {
	case got := <-answered:
		if why, ok := errOf(got); !ok || why.Reason != "Closed" || why.Message != "the stream was closed" {
			t.Errorf("the waiting receive answered %+v", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the waiting receive was never let go")
	}
	select {
	case <-gone:
	case <-time.After(5 * time.Second):
		t.Error("the server never saw the connection close")
	}
}

func TestAShortReadIsWhateverHasArrived(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, strings.Repeat("x", 10))
	}))
	defer server.Close()

	stream, _ := okOf(NetHttpOpen(NetHttpRequest{Method: "GET", Url: server.URL}))
	if got, _ := okOf(NetHttpReceive(stream, 4)); got != "xxxx" {
		t.Errorf("read %q", got)
	}
	if got, _ := okOf(NetHttpReceive(stream, 100)); got != "xxxxxx" {
		t.Errorf("read %q", got)
	}
	if why, ok := errOf(NetHttpReceive(stream, 100)); !ok || why.Reason != "Closed" {
		t.Errorf("past the end: %+v", why)
	}
}

func TestAStreamWithNothingBehindItIsClosed(t *testing.T) {
	stream := NetHttpStream{Status: 200}
	if why, ok := errOf(NetHttpReceiveLine(stream)); !ok || why.Reason != "Closed" {
		t.Errorf("read %+v", why)
	}
	NetHttpClose(stream)
}

func TestAServerNobodyAnswersAtIsAnHttpError(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	url := server.URL
	server.Close()
	if why, ok := errOf(NetHttpOpen(NetHttpRequest{Method: "GET", Url: url})); !ok || why.Url != url {
		t.Errorf("opened anyway: %+v", why)
	}
}
