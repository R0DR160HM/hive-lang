package host

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/xml"
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

// releaseKey is the public half of the key the release job signs SHA256SUMS
// with, as hex. installer/windows/setup/signature.go carries the same one, and
// a test there holds them equal.
const releaseKey = "7cd76f70e5ec6d610efe887b932b543aae9c476fcb2ef164f3472909778ff0f9"

// VerifySums answers whether signature is the release key's signature of sums,
// as the release job writes it: the raw Ed25519 signature in base64.
func VerifySums(sums string, signature string) bool {
	return VerifySumsWith(releaseKey, sums, signature)
}

func VerifySumsWith(publicKey string, sums string, signature string) bool {
	key, err := hex.DecodeString(publicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(signature))
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(key), []byte(sums), sig)
}

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
	said, err := powerShell(pathScript, "HIVE_INSTALL_DIR="+dir, "HIVE_INSTALL_VARIABLE="+variable)
	if err != nil {
		return false, err
	}
	switch said {
	case "added":
		return true, nil
	case "present":
		return false, nil
	}
	return false, fmt.Errorf("PowerShell answered %q", said)
}

// The script's values come through the environment, so nothing in them is ever
// read as PowerShell.
func powerShell(script string, env ...string) (string, error) {
	shell := "powershell.exe"
	if root := os.Getenv("SystemRoot"); root != "" {
		shell = filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	}
	command := exec.Command(shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-EncodedCommand", encodedScript(script))
	command.Env = append(os.Environ(), env...)
	var said, failed bytes.Buffer
	command.Stdout, command.Stderr = &said, &failed
	if err := command.Run(); err != nil {
		why := strings.TrimSpace(failed.String())
		if why == "" {
			why = err.Error()
		}
		return "", fmt.Errorf("PowerShell said: %s", why)
	}
	return strings.TrimSpace(said.String()), nil
}

// Launcher puts the installed binary in the system's app launcher, with the PNG
// at icon where that is not "", and answers with what it wrote: a .desktop entry
// on Linux, an .app bundle on macOS, a Start Menu shortcut on Windows.
func Launcher(binary string, icon string) (string, error) {
	name := strings.TrimSuffix(filepath.Base(binary), ".exe")
	switch runtime.GOOS {
	case "windows":
		return startMenuShortcut(binary, name)
	case "darwin":
		return appBundle(binary, name, icon)
	}
	return desktopEntry(binary, name, icon)
}

func dataHome() (string, error) {
	if dir := os.Getenv("XDG_DATA_HOME"); filepath.IsAbs(dir) {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share"), nil
}

func desktopEntry(binary string, name string, icon string) (string, error) {
	data, err := dataHome()
	if err != nil {
		return "", err
	}
	shown := "application-x-executable"
	if icon != "" {
		shown = filepath.Join(data, "icons", windowClass(name)+".png")
		if err := os.MkdirAll(filepath.Dir(shown), 0o755); err != nil {
			return "", err
		}
		if err := copyFile(icon, shown); err != nil {
			return "", err
		}
	}
	entry := "[Desktop Entry]\nType=Application\nName=" + name + "\nExec=" + execQuoted(binary) +
		"\nIcon=" + strings.ReplaceAll(shown, "\\", "\\\\") + "\nStartupWMClass=" + windowClass(name) + "\nTerminal=false\n"
	path := filepath.Join(data, "applications", "hive-"+windowClass(name)+".desktop")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	return path, os.WriteFile(path, []byte(entry), 0o644)
}

// The desktop entry spec's quoting for one Exec argument, with its string escape
// of a backslash applied on top.
func execQuoted(path string) string {
	quoted := strings.NewReplacer(`\`, `\\\\`, `"`, `\\"`, "`", "\\\\`", `$`, `\\$`, `%`, `%%`).Replace(path)
	return `"` + quoted + `"`
}

// What runtime/hive's uiAppName makes of the same file, which a window carries as
// its class: the launcher groups the window under its entry by it.
func windowClass(name string) string {
	kept := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		case r >= 'A' && r <= 'Z':
			return r + 32
		}
		return -1
	}, name)
	if kept == "" {
		return "hive"
	}
	return kept
}

func appBundle(binary string, name string, icon string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	bundle := filepath.Join(home, "Applications", name+".app")
	contents := filepath.Join(bundle, "Contents")
	if _, err := Install(binary, filepath.Join(contents, "MacOS"), name); err != nil {
		return "", err
	}
	iconKey := ""
	if icon != "" {
		body, err := os.ReadFile(icon)
		if err != nil {
			return "", err
		}
		if err := os.MkdirAll(filepath.Join(contents, "Resources"), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(contents, "Resources", "icon.icns"), icns(body), 0o644); err != nil {
			return "", err
		}
		iconKey = "<key>CFBundleIconFile</key><string>icon</string>\n"
	}
	var shown strings.Builder
	xml.EscapeText(&shown, []byte(name))
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>` + shown.String() + `</string>
<key>CFBundleName</key><string>` + shown.String() + `</string>
<key>CFBundleIdentifier</key><string>dev.hive.` + windowClass(name) + `</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
` + iconKey + `</dict></plist>
`
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(plist), 0o644); err != nil {
		return "", err
	}
	return bundle, nil
}

// An .icns holding the PNG as it is, under the type for the size nearest its
// width: macOS scales it from there.
// ponytail: one size, not resampled; a set of sizes if a small icon looks soft.
func icns(png []byte) []byte {
	width := 0
	if len(png) >= 24 {
		width = int(binary.BigEndian.Uint32(png[16:20]))
	}
	kind := "ic10"
	for _, size := range []struct {
		upTo int
		kind string
	}{{24, "icp4"}, {48, "icp5"}, {96, "icp6"}, {192, "ic07"}, {384, "ic08"}, {768, "ic09"}} {
		if width <= size.upTo {
			kind = size.kind
			break
		}
	}
	out := make([]byte, 16, 16+len(png))
	copy(out, "icns")
	binary.BigEndian.PutUint32(out[4:], uint32(16+len(png)))
	copy(out[8:], kind)
	binary.BigEndian.PutUint32(out[12:], uint32(8+len(png)))
	return append(out, png...)
}

func startMenuShortcut(binary string, name string) (string, error) {
	return powerShell(shortcutScript, "HIVE_INSTALL_TARGET="+binary, "HIVE_INSTALL_NAME="+name)
}

const shortcutScript = `
$ErrorActionPreference = 'Stop'
$programs = [Environment]::GetFolderPath('Programs')
$path = Join-Path $programs ($env:HIVE_INSTALL_NAME + '.lnk')
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
$link.TargetPath = $env:HIVE_INSTALL_TARGET
$link.WorkingDirectory = Split-Path $env:HIVE_INSTALL_TARGET
$link.Save()
$path
`

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
