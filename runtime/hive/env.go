package hive

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
)

type EnvEnvironmentError struct {
	Key     string
	Message string
}

var envOnce sync.Once
var envFile = map[string]string{}

// The .env file is read once, when the first get runs.
func loadEnvFile() {
	dirs := []string{}
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		dirs = append(dirs, wd)
	}
	paths := []string{}
	for _, dir := range append(append([]string{}, dirs...), parentsOf(dirs)...) {
		path := filepath.Join(dir, ".env")
		if !slices.Contains(paths, path) {
			paths = append(paths, path)
		}
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			line = strings.TrimPrefix(line, "export ")
			at := strings.Index(line, "=")
			if at < 0 {
				continue
			}
			key := strings.TrimSpace(line[:at])
			value := strings.TrimSpace(line[at+1:])
			value = strings.Trim(value, "\"'")
			if _, seen := envFile[key]; !seen {
				envFile[key] = value
			}
		}
	}
}

func parentsOf(dirs []string) []string {
	out := []string{}
	for _, dir := range dirs {
		out = append(out, filepath.Dir(dir))
	}
	return out
}

// Resolved in this order: the .env beside the executable, the one in the
// working directory, the one in the parent of either, and then the OS
// environment.
func EnvGet(name string) Result[string, EnvEnvironmentError] {
	envOnce.Do(loadEnvFile)
	if v, seen := envFile[name]; seen {
		return Ok[string, EnvEnvironmentError](v)
	}
	if v, seen := os.LookupEnv(name); seen {
		return Ok[string, EnvEnvironmentError](v)
	}
	return Err[string, EnvEnvironmentError](EnvEnvironmentError{Key: name, Message: "not set"})
}

// EnvGetSecret is EnvGet as a Secret. The environment and a .env file still
// hold it as text; only the program's own copy is locked.
func EnvGetSecret(name string) Result[Secret, EnvEnvironmentError] {
	got := EnvGet(name)
	if got.IsError() {
		return Err[Secret, EnvEnvironmentError](got.Err())
	}
	hidden := Hide(got.Ok())
	if hidden.IsError() {
		return Err[Secret, EnvEnvironmentError](EnvEnvironmentError{Key: name, Message: hidden.Err().Message})
	}
	return Ok[Secret, EnvEnvironmentError](hidden.Ok())
}
