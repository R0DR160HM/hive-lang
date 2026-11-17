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
	start, end := termFlagSpan(words)
	shape := TermFlagShape{Long: []string{"name", "tag"}, Short: []string{"", ""}, Bool: []bool{false, false}}
	flags, err := termFlags(words[start:end], shape)
	if err != nil || len(flags) != 2 || flags[0].Key != "name" || flags[0].Value != "my notes" || flags[1].Key != "tag" || flags[1].Value != "a b" {
		t.Errorf("read %+v, %v", flags, err)
	}
	if got := TermPositional(termLine([]string{"install", "notes.hive", "--name", "my notes", "--", "-x", "--y"})); strings.Join(got, "|") != "install|notes.hive|-x|--y" {
		t.Errorf("the words were %q", got)
	}
}

// Words before the first flag, and after a lone --, are the program's; between
// them, a Bool takes only true or false, a short name is its flag, a negative
// number is a value, and anything else is an error that says what it was.
func TestWordsArePairedAgainstWhatTheFlagsAre(t *testing.T) {
	shape := TermFlagShape{
		Long:  []string{"model", "code", "count", "tag"},
		Short: []string{"m", "", "", "t"},
		Bool:  []bool{false, true, false, false},
	}
	read := func(line string) string {
		words, werr := termWords(line)
		if werr != nil {
			return "words: " + werr.Expected
		}
		start, end := termFlagSpan(words)
		pairs, err := termFlags(words[start:end], shape)
		if err != nil {
			return err.Path + ": expected " + err.Expected + ", found " + err.Found
		}
		out := []string{}
		for _, p := range pairs {
			if p.Bare {
				out = append(out, p.Written+"="+p.Key)
			} else {
				out = append(out, p.Written+"="+p.Key+":"+p.Value)
			}
		}
		return strings.Join(out, " ")
	}
	for _, c := range []struct{ line, want string }{
		{"--model llama --code", "--model=model:llama --code=code"},
		{"-m llama -m=qwen", "-m=model:llama -m=model:qwen"},
		{"--code true --count -5 -t=-x", "--code=code:true --count=count:-5 -t=tag:-x"},
		{"explain this --code -- and that", "--code=code"},
		{"--code explain", `$: expected a flag (words go before the flags or after --), found "explain"`},
		{"--modle llama", "--modle: expected --model/-m, --code, --count or --tag/-t, found a flag nothing declares"},
		{"--code -x", "-x: expected --model/-m, --code, --count or --tag/-t, found a flag nothing declares"},
		{"--model --code", "--model=model --code=code"},
		{"--model '-quoted'", "--model=model:-quoted"},
	} {
		if got := read(c.line); got != c.want {
			t.Errorf("%q read as %q, want %q", c.line, got, c.want)
		}
	}
	for _, c := range []struct {
		line string
		want []string
	}{
		{"what is this", []string{"what", "is", "this"}},
		{"-m llama -- what is this", []string{"what", "is", "this"}},
		{"-- --code", []string{"--code"}},
		{"'-not a flag' --code", []string{"-not a flag"}},
		{"-5 apples --code", []string{"-5", "apples"}},
		{"--code 'open", []string{}},
	} {
		if got := TermPositional(c.line); strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%q has the words %q, want %q", c.line, got, c.want)
		}
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

// Every key a terminal sends, named as hive.ui names it, with what it types.
func TestATerminalsBytesAreNamedAsAWindowNamesItsKeys(t *testing.T) {
	for _, c := range []struct {
		sent, name, text string
	}{
		{"a", "a", "a"},
		{"A", "A", "A"},
		{"ç", "ç", "ç"},
		{" ", "Space", " "},
		{"\r", "Enter", ""},
		{"\n", "Enter", ""},
		{"\r\n", "Enter", ""},
		{"\t", "Tab", ""},
		{"\x7f", "Backspace", ""},
		{"\x08", "Backspace", ""},
		{"\x1b", "Escape", ""},
		{"\x01", "Ctrl+A", ""},
		{"\x03", "Ctrl+C", ""},
		{"\x00", "Ctrl+Space", ""},
		{"\x1f", "Ctrl+/", ""},
		{"\x1b[A", "ArrowUp", ""},
		{"\x1bOB", "ArrowDown", ""},
		{"\x1b[1;5C", "Ctrl+ArrowRight", ""},
		{"\x1b[1;2D", "Shift+ArrowLeft", ""},
		{"\x1b[1;3H", "Alt+Home", ""},
		{"\x1b[1;6F", "Ctrl+Shift+End", ""},
		{"\x1b[Z", "Shift+Tab", ""},
		{"\x1b[2~", "Insert", ""},
		{"\x1b[3;5~", "Ctrl+Delete", ""},
		{"\x1b[5~", "PageUp", ""},
		{"\x1b[6~", "PageDown", ""},
		{"\x1bOP", "F1", ""},
		{"\x1b[15~", "F5", ""},
		{"\x1b[24;2~", "Shift+F12", ""},
		{"\x1bx", "Alt+X", ""},
		{"\x1bX", "Shift+Alt+X", ""},
		{"\x1b1", "Alt+1", ""},
		{"\x1b\r", "Alt+Enter", ""},
		{"\x1b\x01", "Ctrl+Alt+A", ""},
		{"\x1b[", "Alt+[", ""},
		{"\x1b[200~two\r\nlines\rhere\x1b[201~", "Paste", "two\nlines\nhere"},
	} {
		key, used, whole := termNextKey([]byte(c.sent))
		if !whole || used != len(c.sent) || key.Name != c.name || key.Text != c.text {
			t.Errorf("%q read as %q typing %q, %d of %d bytes, whole %v; want %q typing %q", c.sent, key.Name, key.Text, used, len(c.sent), whole, c.name, c.text)
		}
	}
}

// A sequence that has not finished arriving waits for the rest, and one nobody
// asked for — the pointer, the focus — is passed over whole.
func TestAKeyIsReadOnlyOnceItHasArrivedWhole(t *testing.T) {
	for _, partial := range []string{"\x1b[1;", "\x1bO", "\x1b[200~half a paste", "\xc3"} {
		if _, _, whole := termNextKey([]byte(partial)); whole {
			t.Errorf("%q was read before the rest of it arrived", partial)
		}
	}
	for _, unasked := range []string{"\x1b[I", "\x1b[O", "\x1b[<0;10;5M", "\x1b[99~"} {
		key, used, whole := termNextKey([]byte(unasked))
		if !whole || used != len(unasked) || key.Name != "" {
			t.Errorf("%q read as %q from %d bytes", unasked, key.Name, used)
		}
	}
	key, used, _ := termNextKey([]byte("ab\x1b[A"))
	if key.Name != "a" || used != 1 {
		t.Errorf("the first of several keys read as %q from %d bytes", key.Name, used)
	}
}
