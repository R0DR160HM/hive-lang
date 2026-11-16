package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unicode/utf16"
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

// BinDir is where `hive install` puts a program: a folder of the user's own that a
// shell looks in for commands.
func BinDir() (string, error) {
	if runtime.GOOS == "windows" {
		local := os.Getenv("LOCALAPPDATA")
		if local == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return "", err
			}
			local = filepath.Join(home, "AppData", "Local")
		}
		return filepath.Join(local, "Programs", "Hive", "bin"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "bin"), nil
}

// Install copies built into dir as name, executable, in place of whatever had that
// name, and answers with where it is now.
//
// The copy lands beside the old one and is renamed over it rather than written
// into it: a copy of the program still running keeps the file it started from,
// and macOS kills a program whose file changed under a signature it checked.
// Windows refuses to rename over a running program, so the old one is moved aside
// first, and goes the next time nothing has it open.
func Install(built string, dir string, name string) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	target := filepath.Join(dir, name)
	partial := target + ".partial"
	if err := copyFile(built, partial); err != nil {
		os.Remove(partial)
		return "", err
	}
	if err := os.Chmod(partial, 0o755); err != nil {
		os.Remove(partial)
		return "", err
	}
	if runtime.GOOS != "windows" {
		if err := os.Rename(partial, target); err != nil {
			os.Remove(partial)
			return "", err
		}
		return target, nil
	}
	aside := target + "~"
	os.Remove(aside)
	moved := false
	if _, err := os.Stat(target); err == nil {
		if err := os.Rename(target, aside); err != nil {
			os.Remove(partial)
			return "", err
		}
		moved = true
	}
	if err := os.Rename(partial, target); err != nil {
		if moved {
			os.Rename(aside, target)
		}
		os.Remove(partial)
		return "", err
	}
	os.Remove(aside)
	return target, nil
}

func copyFile(from string, to string) error {
	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()
	made, err := os.Create(to)
	if err != nil {
		return err
	}
	_, err = io.Copy(made, source)
	if closed := made.Close(); err == nil {
		err = closed
	}
	return err
}

// OnPath says whether this process's PATH names dir.
func OnPath(dir string) bool {
	want := filepath.Clean(dir)
	for _, entry := range filepath.SplitList(os.Getenv("PATH")) {
		if entry == "" {
			continue
		}
		have := filepath.Clean(entry)
		if have == want || runtime.GOOS == "windows" && strings.EqualFold(have, want) {
			return true
		}
	}
	return false
}

// AddToUserPath puts dir on the PATH every new program of this user starts with,
// on Windows, and answers whether it had to: false where the user's or the
// machine's PATH already names it.
func AddToUserPath(dir string) (bool, error) {
	if runtime.GOOS != "windows" {
		return false, errors.New("only Windows keeps a PATH for the user apart from the shell")
	}
	return addToUserVariable(dir, "Path")
}

// Through Windows' own PowerShell, which every Windows has, because the registry
// is reached from Go only by a file built for Windows alone. The value keeps its
// kind and its unexpanded entries, and running programs are told it changed.
func addToUserVariable(dir string, variable string) (bool, error) {
	shell := "powershell.exe"
	if root := os.Getenv("SystemRoot"); root != "" {
		shell = filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	}
	command := exec.Command(shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-EncodedCommand", encodedScript(pathScript))
	command.Env = append(os.Environ(), "HIVE_INSTALL_DIR="+dir, "HIVE_INSTALL_VARIABLE="+variable)
	var said, failed bytes.Buffer
	command.Stdout, command.Stderr = &said, &failed
	if err := command.Run(); err != nil {
		why := strings.TrimSpace(failed.String())
		if why == "" {
			why = err.Error()
		}
		return false, fmt.Errorf("PowerShell could not change it: %s", why)
	}
	switch strings.TrimSpace(said.String()) {
	case "added":
		return true, nil
	case "present":
		return false, nil
	}
	return false, fmt.Errorf("PowerShell answered %q", strings.TrimSpace(said.String()))
}

// What -EncodedCommand takes: the script as UTF-16, little-endian, in base64.
func encodedScript(script string) string {
	units := utf16.Encode([]rune(script))
	raw := make([]byte, len(units)*2)
	for i, u := range units {
		binary.LittleEndian.PutUint16(raw[i*2:], u)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

const pathScript = `
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = $env:HIVE_INSTALL_DIR
$name = $env:HIVE_INSTALL_VARIABLE
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
$raw = [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
if ($key.GetValueNames() -contains $name) { $kind = $key.GetValueKind($name) }
$want = [IO.Path]::GetFullPath($dir).TrimEnd('\')
$machine = [string][Environment]::GetEnvironmentVariable($name, 'Machine')
foreach ($entry in (($raw -split ';') + ($machine -split ';'))) {
    $entry = $entry.Trim()
    if ($entry -eq '') { continue }
    $have = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
    if ([string]::Equals($have, $want, [StringComparison]::OrdinalIgnoreCase)) {
        'present'
        exit 0
    }
}
if ($raw.Trim() -eq '') { $next = $dir } elseif ($raw.EndsWith(';')) { $next = $raw + $dir } else { $next = $raw + ';' + $dir }
$key.SetValue($name, $next, $kind)
$key.Close()
Add-Type -Namespace Hive -Name Settings -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);'
$answer = [UIntPtr]::Zero
[void][Hive.Settings]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$answer)
'added'
`
