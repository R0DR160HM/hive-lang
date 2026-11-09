package main

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
	"strings"
	"time"
)

const releases = "https://github.com/R0DR160HM/hive-lang/releases/download/"

const stalled = 60 * time.Second

var client = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 30 * time.Second}).DialContext,
	TLSHandshakeTimeout:   30 * time.Second,
	ResponseHeaderTimeout: stalled,
}}

// fetchHive puts release `version`'s compiler for this machine at dir\hive.exe.
func fetchHive(version string, dir string) error {
	tag := "v" + strings.TrimPrefix(version, "v")
	asset := "hivec-windows-" + nativeArch() + ".exe"
	sums, err := get(releases + tag + "/SHA256SUMS")
	if err != nil {
		return fmt.Errorf("could not read the checksums of Hive %s: %w", tag, err)
	}
	want := digestIn(string(sums), asset)
	if want == "" {
		return fmt.Errorf("Hive %s has no %s", tag, asset)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	target := filepath.Join(dir, "hive.exe")
	incoming := target + ".download"
	got, err := download(releases+tag+"/"+asset, incoming)
	if err != nil {
		return fmt.Errorf("could not download %s: %w", asset, err)
	}
	if got != want {
		os.Remove(incoming)
		return fmt.Errorf("%s is not the file Hive %s's SHA256SUMS names (expected %s, got %s)", asset, tag, want, got)
	}
	return place(incoming, target)
}

// A running executable can be renamed but not overwritten.
func place(incoming string, target string) error {
	if os.Rename(incoming, target) == nil {
		return nil
	}
	aside := target + "~"
	os.Remove(aside)
	if err := os.Rename(target, aside); err != nil {
		os.Remove(incoming)
		return err
	}
	if err := os.Rename(incoming, target); err != nil {
		os.Rename(aside, target)
		os.Remove(incoming)
		return err
	}
	return nil
}

func digestIn(sums string, asset string) string {
	for _, line := range strings.Split(sums, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == asset {
			return fields[0]
		}
	}
	return ""
}

func get(url string) ([]byte, error) {
	response, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", url, response.Status)
	}
	return io.ReadAll(response.Body)
}

// download streams url into path and answers with its SHA-256 in lowercase hex.
func download(url string, path string) (string, error) {
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
		return "", fmt.Errorf("%s answered %s", url, response.Status)
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
