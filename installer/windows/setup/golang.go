package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const goListing = "https://go.dev/dl/?mode=json"

const needsGo = "Hive builds and runs programs with Go 1.24 or newer"

type goRelease struct {
	Version string   `json:"version"`
	Stable  bool     `json:"stable"`
	Files   []goFile `json:"files"`
}

type goFile struct {
	Filename string `json:"filename"`
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	Kind     string `json:"kind"`
	SHA256   string `json:"sha256"`
}

func offerGo() error {
	found := installedGo()
	if found != "" && recentEnough(found) {
		return nil
	}
	question := needsGo + ", which this computer does not have.\n\nDownload and install Go now?"
	if found != "" {
		question = needsGo + ", and this computer has " + found + ".\n\nDownload and install the latest Go now?"
	}
	if !ask(question) {
		return nil
	}
	if err := installGo(); err != nil {
		tell("Go could not be installed: " + err.Error() + "\n\nhttps://go.dev/dl/ has it.")
		return err
	}
	return nil
}

// installedGo is the version of the go.exe a new terminal would run, or "".
func installedGo() string {
	for _, dir := range freshPath() {
		program := filepath.Join(dir, "go.exe")
		if _, err := os.Stat(program); err != nil {
			continue
		}
		said, err := quietly(program, "env", "GOVERSION").Output()
		if err == nil {
			return strings.TrimSpace(string(said))
		}
	}
	return ""
}

// recentEnough reads `go1.24`, `go1.24.3` or `go1.25rc1` as at least go1.24.
func recentEnough(version string) bool {
	parts := strings.SplitN(strings.TrimPrefix(version, "go"), ".", 3)
	if len(parts) < 2 {
		return false
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(leadingDigits(parts[1]))
	if majorErr != nil || minorErr != nil {
		return false
	}
	return major > 1 || (major == 1 && minor >= 24)
}

func leadingDigits(s string) string {
	end := 0
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end++
	}
	return s[:end]
}

func goInstaller(listing []byte, arch string) (goFile, error) {
	var released []goRelease
	if err := json.Unmarshal(listing, &released); err != nil {
		return goFile{}, err
	}
	for _, release := range released {
		if !release.Stable {
			continue
		}
		for _, file := range release.Files {
			if file.OS == "windows" && file.Arch == arch && file.Kind == "installer" {
				return file, nil
			}
		}
	}
	return goFile{}, fmt.Errorf("go.dev lists no Go installer for windows/%s", arch)
}

func installGo() error {
	listing, err := get(goListing)
	if err != nil {
		return err
	}
	file, err := goInstaller(listing, nativeArch())
	if err != nil {
		return err
	}
	path := filepath.Join(os.TempDir(), file.Filename)
	got, err := download("https://go.dev/dl/"+file.Filename, path)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	if got != file.SHA256 {
		return fmt.Errorf("%s is not the file go.dev lists (expected SHA-256 %s, got %s)", file.Filename, file.SHA256, got)
	}
	return runMsi(path)
}

// Hive's own installer may still be finishing, and Windows runs one at a time.
func runMsi(path string) error {
	const anotherInstall = 1618
	deadline := time.Now().Add(2 * time.Minute)
	for {
		err := exec.Command("msiexec", "/i", path).Run()
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == anotherInstall && time.Now().Before(deadline) {
			time.Sleep(3 * time.Second)
			continue
		}
		if errors.As(err, &exit) && (exit.ExitCode() == 1602 || exit.ExitCode() == 3010) {
			return nil
		}
		return err
	}
}
