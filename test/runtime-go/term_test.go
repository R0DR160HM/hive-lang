package hive

import (
	"os"
	"strings"
	"testing"
)

// The line hive.term.flags() makes, split as the flag codec splits it, is the
// arguments it was made from, word for word, and a flag is still a flag.
func TestTheArgumentsLineSplitsBackIntoTheSameWords(t *testing.T) {
	for _, args := range [][]string{
		{},
		{"--name", "my notes"},
		{"--name=my notes", "plain", ""},
		{"--say", `a "quoted" word`, `back\slash`, "it's", "tab\there"},
		{"--", "--after"},
		{"-5", "--count=-5", "--empty=", "--value=--like-a-flag"},
		{"--tag", "--looks-like-a-flag"},
	} {
		line := termLine(args)
		words, err := termWords(line)
		if err != nil {
			t.Fatalf("%q made %q, which does not split: %s", args, line, err.Expected)
		}
		if len(words) != len(args) {
			t.Fatalf("%q made %q, which splits into %d words", args, line, len(words))
		}
		for i, w := range words {
			if w.text != args[i] {
				t.Errorf("%q made %q, whose word %d is %q", args, line, i, w.text)
			}
			if strings.HasPrefix(args[i], "--") && w.quoted {
				t.Errorf("%q made %q, where the flag %q opens quoted", args, line, args[i])
			}
		}
	}
}

func TestAQuotedValueIsReadWhole(t *testing.T) {
	words, _ := termWords(termLine([]string{"install", "notes.hive", "--name", "my notes", "--tag=a b"}))
	flags := termFlags(words)
	if len(flags) != 2 || flags[0].Key != "name" || flags[0].Value != "my notes" || flags[1].Key != "tag" || flags[1].Value != "a b" {
		t.Errorf("read %+v", flags)
	}
}

func TestFlagsAreThisProgramsArguments(t *testing.T) {
	was := os.Args
	defer func() { os.Args = was }()
	os.Args = []string{"program", "--name", "Ada Lovelace", "--dry-run"}
	if got := TermFlags(); got != `--name "Ada Lovelace" --dry-run` {
		t.Errorf("got %q", got)
	}
}
