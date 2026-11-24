package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
)

// releaseKey is the public half of the key the release job signs SHA256SUMS
// with, as hex. src/host.go carries the same one, and a test holds them equal.
const releaseKey = "7cd76f70e5ec6d610efe887b932b543aae9c476fcb2ef164f3472909778ff0f9"

// verifySums answers nil when signature is the release key's signature of
// sums, as the release job writes it: the raw Ed25519 signature in base64.
func verifySums(sums []byte, signature []byte) error {
	return verifySumsWith(releaseKey, sums, signature)
}

func verifySumsWith(publicKey string, sums []byte, signature []byte) error {
	key, err := hex.DecodeString(publicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return errors.New("this installer carries no release key to check the download with")
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(signature)))
	if err != nil || !ed25519.Verify(ed25519.PublicKey(key), sums, sig) {
		return errors.New("its SHA256SUMS is not signed by Hive's release key")
	}
	return nil
}
