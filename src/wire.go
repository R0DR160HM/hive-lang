package wire

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	once     sync.Once
	incoming = make(chan string, 64)
)

func listen() {
	in := bufio.NewReader(os.Stdin)
	for {
		length := -1
		for {
			line, err := in.ReadString('\n')
			if err != nil {
				close(incoming)
				return
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			name, value, found := strings.Cut(line, ":")
			if found && strings.EqualFold(name, "Content-Length") {
				length, _ = strconv.Atoi(strings.TrimSpace(value))
			}
		}
		if length < 0 {
			continue
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(in, body); err != nil {
			close(incoming)
			return
		}
		incoming <- string(body)
	}
}

// Read answers "" once wait milliseconds pass with no message; a negative wait is forever.
func Read(wait int) (string, error) {
	once.Do(func() { go listen() })
	if wait < 0 {
		body, open := <-incoming
		if !open {
			return "", errors.New("closed")
		}
		return body, nil
	}
	select {
	case body, open := <-incoming:
		if !open {
			return "", errors.New("closed")
		}
		return body, nil
	case <-time.After(time.Duration(wait) * time.Millisecond):
		return "", nil
	}
}

func Write(body string) {
	os.Stdout.WriteString(fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(body), body))
}

// Path is the file a `file:` URI names, written with `/`, or "" for any other URI.
func Path(uri string) string {
	parsed, err := url.Parse(uri)
	if err != nil || parsed.Scheme != "file" {
		return ""
	}
	path := parsed.Path
	if parsed.Host != "" {
		return "//" + parsed.Host + path
	}
	if len(path) >= 3 && path[0] == '/' && path[2] == ':' {
		return path[1:]
	}
	return path
}

func Link(path string) string {
	path = strings.ReplaceAll(path, "\\", "/")
	if strings.HasPrefix(path, "//") {
		host, rest, _ := strings.Cut(path[2:], "/")
		return (&url.URL{Scheme: "file", Host: host, Path: "/" + rest}).String()
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return (&url.URL{Scheme: "file", Path: path}).String()
}
