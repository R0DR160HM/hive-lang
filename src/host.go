package host

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// A whole-download deadline would fail a slow line that is still making progress.
const stalled = 60 * time.Second

var client = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 30 * time.Second}).DialContext,
	TLSHandshakeTimeout:   30 * time.Second,
	ResponseHeaderTimeout: stalled,
}}

func Executable() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(path)
}

func Platform() string {
	return runtime.GOOS + "/" + runtime.GOARCH
}

func MakeExecutable(path string) error {
	return os.Chmod(path, 0o755)
}

// Download streams url into path and answers with its SHA-256, in lowercase hex.
func Download(url string, path string) (string, error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("the server answered %s", response.Status)
	}
	file, err := os.Create(path)
	if err != nil {
		return "", err
	}
	digest, err := copyWatched(ctx, cancel, file, response.Body)
	if closed := file.Close(); err == nil {
		err = closed
	}
	if err != nil {
		os.Remove(path)
		return "", err
	}
	return digest, nil
}

func copyWatched(ctx context.Context, cancel context.CancelFunc, to io.Writer, from io.Reader) (string, error) {
	watchdog := time.AfterFunc(stalled, cancel)
	defer watchdog.Stop()
	hash := sha256.New()
	buffer := make([]byte, 64*1024)
	for {
		n, err := from.Read(buffer)
		if n > 0 {
			watchdog.Reset(stalled)
			if _, werr := to.Write(buffer[:n]); werr != nil {
				return "", werr
			}
			hash.Write(buffer[:n])
		}
		if errors.Is(err, io.EOF) {
			return hex.EncodeToString(hash.Sum(nil)), nil
		}
		if err != nil {
			if ctx.Err() != nil {
				return "", fmt.Errorf("the download stalled: nothing arrived for %s", stalled)
			}
			return "", err
		}
	}
}
