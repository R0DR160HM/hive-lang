// The Go for `hive.file.csv(<path>, <separator>)`. Separate from the spreadsheet
// readers because the two have nothing in common but the answer they give: this is
// one standard library call, and that one is a zip archive full of XML.
// The matcher behind every string pattern. A module of its own because `regexp` is
// worth carrying only where a pattern is written at all.
package hive

import "regexp"

// CompilePattern is one string pattern, compiled once when the program starts.
// Nothing here can fail: the compiler reads every pattern before writing it
// out, so one that would not compile never reaches this file.
func CompilePattern(pattern string) *regexp.Regexp {
	return regexp.MustCompile(pattern)
}

// MatchPattern answers with what the template's holes bound, in the order
// the template writes them. The whole expression is anchored, so a match
// covers the whole string or there is no match at all.
func MatchPattern(s string, re *regexp.Regexp) ([]string, bool) {
	found := re.FindStringSubmatch(s)
	if found == nil {
		return nil, false
	}
	return found[1:], true
}
