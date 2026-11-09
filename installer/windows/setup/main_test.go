package main

import "testing"

func TestDigestIn(t *testing.T) {
	sums := "aaa  hivec-linux-amd64\nbbb  hivec-windows-amd64.exe\r\nccc *hivec-windows-arm64.exe\n"
	cases := map[string]string{
		"hivec-windows-amd64.exe": "bbb",
		"hivec-windows-arm64.exe": "ccc",
		"hivec-linux-amd64":       "aaa",
		"hivec-darwin-arm64":      "",
		"hivec-windows":           "",
	}
	for asset, want := range cases {
		if got := digestIn(sums, asset); got != want {
			t.Errorf("digestIn(%q) = %q, want %q", asset, got, want)
		}
	}
}

func TestRecentEnough(t *testing.T) {
	cases := map[string]bool{
		"go1.24":     true,
		"go1.24.3":   true,
		"go1.27.1":   true,
		"go1.25rc1":  true,
		"go2.0":      true,
		"go1.23.9":   false,
		"go1.9":      false,
		"":           false,
		"devel +abc": false,
	}
	for version, want := range cases {
		if got := recentEnough(version); got != want {
			t.Errorf("recentEnough(%q) = %v, want %v", version, got, want)
		}
	}
}

func TestGoInstallerPicksTheNewestStableForThisArch(t *testing.T) {
	listing := []byte(`[
		{"version": "go1.28rc1", "stable": false, "files": [
			{"filename": "go1.28rc1.windows-amd64.msi", "os": "windows", "arch": "amd64", "kind": "installer", "sha256": "rc"}]},
		{"version": "go1.27.1", "stable": true, "files": [
			{"filename": "go1.27.1.windows-amd64.zip", "os": "windows", "arch": "amd64", "kind": "archive", "sha256": "zip"},
			{"filename": "go1.27.1.windows-arm64.msi", "os": "windows", "arch": "arm64", "kind": "installer", "sha256": "arm"},
			{"filename": "go1.27.1.windows-amd64.msi", "os": "windows", "arch": "amd64", "kind": "installer", "sha256": "x64"}]},
		{"version": "go1.26.5", "stable": true, "files": [
			{"filename": "go1.26.5.windows-amd64.msi", "os": "windows", "arch": "amd64", "kind": "installer", "sha256": "old"}]}
	]`)
	file, err := goInstaller(listing, "amd64")
	if err != nil || file.Filename != "go1.27.1.windows-amd64.msi" || file.SHA256 != "x64" {
		t.Errorf("goInstaller(amd64) = %+v, %v", file, err)
	}
	file, err = goInstaller(listing, "arm64")
	if err != nil || file.SHA256 != "arm" {
		t.Errorf("goInstaller(arm64) = %+v, %v", file, err)
	}
	if _, err := goInstaller(listing, "386"); err == nil {
		t.Error("goInstaller(386) found an installer that is not listed")
	}
}

func TestSamePlaceIgnoresCaseAndATrailingSeparator(t *testing.T) {
	dir := `C:\Users\me\AppData\Local\Hive`
	for _, entry := range []string{dir, dir + `\`, ` c:\users\ME\appdata\local\hive\ `, `C:\Users\me\AppData\Local\Hive\.`} {
		if !samePlace(entry, dir) {
			t.Errorf("samePlace(%q) = false", entry)
		}
	}
	if samePlace(`C:\Users\me\AppData\Local\Hive2`, dir) || samePlace("", dir) {
		t.Error("samePlace matched a different folder")
	}
}

func TestWithEntryAppendsAndWithoutEntryUndoesIt(t *testing.T) {
	cases := map[string]string{
		"":                 `D:\Hive`,
		`C:\a`:             `C:\a;D:\Hive`,
		`C:\a;`:            `C:\a;D:\Hive;`,
		`%USERPROFILE%\b;`: `%USERPROFILE%\b;D:\Hive;`,
	}
	same := func(s string) string { return s }
	for raw, want := range cases {
		got := withEntry(raw, `D:\Hive`)
		if got != want {
			t.Errorf("withEntry(%q) = %q, want %q", raw, got, want)
		}
		if back := withoutEntry(got, `D:\Hive`, same); back != raw {
			t.Errorf("withoutEntry(%q) = %q, want %q", got, back, raw)
		}
	}
}

func TestWithoutEntryKeepsEverythingElseAsWritten(t *testing.T) {
	expand := func(s string) string {
		if s == `%LOCALAPPDATA%\Hive` {
			return `C:\Users\me\AppData\Local\Hive`
		}
		return s
	}
	raw := `%USERPROFILE%\bin;C:\Users\me\AppData\Local\Hive\;;%LOCALAPPDATA%\Hive;C:\tools;`
	if got := withoutEntry(raw, `C:\Users\me\AppData\Local\Hive`, expand); got != `%USERPROFILE%\bin;;C:\tools;` {
		t.Errorf("withoutEntry = %q", got)
	}
}
