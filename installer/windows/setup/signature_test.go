package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"os"
	"regexp"
	"testing"
)

func TestVerifySums(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key := hex.EncodeToString(public)
	sums := []byte("aaa  hivec-windows-amd64.exe\n")
	signature := []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(private, sums)) + "\n")

	if err := verifySumsWith(key, sums, signature); err != nil {
		t.Errorf("a good signature was refused: %v", err)
	}
	if verifySumsWith(key, []byte("bbb  hivec-windows-amd64.exe\n"), signature) == nil {
		t.Error("a changed SHA256SUMS was accepted")
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if verifySumsWith(hex.EncodeToString(other), sums, signature) == nil {
		t.Error("a signature by another key was accepted")
	}
	if verifySumsWith(key, sums, []byte("not base64")) == nil {
		t.Error("a garbled signature was accepted")
	}
	if verifySumsWith("RELEASE_KEY_PENDING", sums, signature) == nil {
		t.Error("an installer with no key accepted a download")
	}
}

// The installer and the compiler check releases against one key.
func TestReleaseKeyMatchesTheCompiler(t *testing.T) {
	source, err := os.ReadFile("../../../src/host.go")
	if err != nil {
		t.Fatal(err)
	}
	found := regexp.MustCompile(`const releaseKey = "([^"]*)"`).FindSubmatch(source)
	if found == nil {
		t.Fatal("src/host.go declares no releaseKey")
	}
	if string(found[1]) != releaseKey {
		t.Errorf("src/host.go's releaseKey is %q and the installer's is %q", found[1], releaseKey)
	}
}
