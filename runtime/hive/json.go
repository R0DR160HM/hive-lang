// The Go for `hive.json`. A type declaration is the schema, so what is here is the
// machinery a generated codec is written against — a parsed value, the readers for
// each shape a field can take, and an error carrying the path it failed at. The
// codecs themselves are generated per type, by `emit`.
package hive

import (
	"encoding/json"
	"io"
	"strconv"
	"strings"
)

// JsonCodec is the value that says read and write it as JSON. Encoding and
// decoding read the format off the name in the source rather than off this,
// so what comes back is only ever passed around or ignored.
func JsonCodec() CodecCodec[JsonJsonError] { return CodecCodec[JsonJsonError]{} }

// JsonJsonError says why a document didn't hold what was asked of it: the
// path that failed, what was expected there, and what was found.
type JsonJsonError struct {
	Path     string
	Expected string
	Found    string
}

func (e JsonJsonError) Error() string {
	return "hive: cannot decode JSON at " + e.Path + ": expected " + e.Expected + ", found " + e.Found
}

// JsonValue is an order-preserving parsed JSON document. `Kind` is one
// letter: `n` null, `b` bool, `#` number, `s` string, `a` array, `o` object.
type JsonValue struct {
	Kind byte
	Str  string
	Num  string
	Bool bool
	Arr  []JsonValue
	Obj  []JsonMember
}

type JsonMember struct {
	Key   string
	Value JsonValue
}

func parseJsonValue(d *json.Decoder) (JsonValue, error) {
	t, err := d.Token()
	if err != nil {
		return JsonValue{}, err
	}
	return parseJsonToken(d, t)
}

func parseJsonToken(d *json.Decoder, t json.Token) (JsonValue, error) {
	switch x := t.(type) {
	case json.Delim:
		if x == '{' {
			obj := []JsonMember{}
			at := map[string]int{}
			for d.More() {
				kt, err := d.Token()
				if err != nil {
					return JsonValue{}, err
				}
				key, _ := kt.(string)
				val, err := parseJsonValue(d)
				if err != nil {
					return JsonValue{}, err
				}
				if i, seen := at[key]; seen {
					obj[i].Value = val
					continue
				}
				at[key] = len(obj)
				obj = append(obj, JsonMember{Key: key, Value: val})
			}
			if _, err := d.Token(); err != nil {
				return JsonValue{}, err
			}
			return JsonValue{Kind: 'o', Obj: obj}, nil
		}
		arr := []JsonValue{}
		for d.More() {
			val, err := parseJsonValue(d)
			if err != nil {
				return JsonValue{}, err
			}
			arr = append(arr, val)
		}
		if _, err := d.Token(); err != nil {
			return JsonValue{}, err
		}
		return JsonValue{Kind: 'a', Arr: arr}, nil
	case string:
		return JsonValue{Kind: 's', Str: x}, nil
	case json.Number:
		return JsonValue{Kind: '#', Num: x.String()}, nil
	case bool:
		return JsonValue{Kind: 'b', Bool: x}, nil
	}
	return JsonValue{Kind: 'n'}, nil
}

func jsonKindName(v JsonValue) string {
	switch v.Kind {
	case 'n':
		return "null"
	case 'b':
		return strconv.FormatBool(v.Bool)
	case '#':
		return "the number " + v.Num
	case 's':
		return "the string " + strconv.Quote(v.Str)
	case 'a':
		return "an array"
	}
	return "an object"
}

// JsonParse backs every decode; the decoder argument is what the call
// named, derived at compile time.
func JsonParse[T any](text string, dec func(JsonValue, string) (T, *JsonJsonError)) Result[T, JsonJsonError] {
	d := json.NewDecoder(strings.NewReader(text))
	d.UseNumber()
	v, err := parseJsonValue(d)
	if err != nil {
		return Err[T, JsonJsonError](JsonJsonError{Path: "$", Expected: "valid JSON", Found: err.Error()})
	}
	if _, err := d.Token(); err != io.EOF {
		return Err[T, JsonJsonError](JsonJsonError{Path: "$", Expected: "the end of the document", Found: "more text after it"})
	}
	out, jerr := dec(v, "$")
	if jerr != nil {
		return Err[T, JsonJsonError](*jerr)
	}
	return Ok[T, JsonJsonError](out)
}

func JsonStr(v JsonValue, path string) (string, *JsonJsonError) {
	if v.Kind == 's' {
		return v.Str, nil
	}
	return "", &JsonJsonError{Path: path, Expected: "Str", Found: jsonKindName(v)}
}

// A field read into a Secret that did not decode: what was wanted and
// where, but only the kind of what came — never the text, which is the
// part that was meant to be secret.
func JsonSecretError(e *JsonJsonError, v JsonValue) *JsonJsonError {
	found := "an object"
	switch v.Kind {
	case 'n':
		found = "null"
	case 'b':
		found = "a boolean"
	case '#':
		found = "a number"
	case 's':
		found = "a string"
	case 'a':
		found = "an array"
	}
	return &JsonJsonError{Path: e.Path, Expected: e.Expected, Found: found}
}

func JsonInt(v JsonValue, path string) (int, *JsonJsonError) {
	if v.Kind == '#' {
		if i, err := strconv.Atoi(v.Num); err == nil {
			return i, nil
		}
	}
	return 0, &JsonJsonError{Path: path, Expected: "Int", Found: jsonKindName(v)}
}

func JsonSized[T Whole](v JsonValue, path string, signed bool, bits int, name string) (T, *JsonJsonError) {
	if v.Kind == '#' {
		if signed {
			if n, err := strconv.ParseInt(v.Num, 10, bits); err == nil {
				return T(n), nil
			}
		} else if n, err := strconv.ParseUint(v.Num, 10, bits); err == nil {
			return T(n), nil
		}
	}
	return 0, &JsonJsonError{Path: path, Expected: name, Found: jsonKindName(v)}
}

func JsonFloat32(v JsonValue, path string) (float32, *JsonJsonError) {
	if v.Kind == '#' {
		if f, err := strconv.ParseFloat(v.Num, 32); err == nil {
			return float32(f), nil
		}
	}
	return 0, &JsonJsonError{Path: path, Expected: "Float32", Found: jsonKindName(v)}
}

func JsonFloat(v JsonValue, path string) (float64, *JsonJsonError) {
	if v.Kind == '#' {
		if f, err := strconv.ParseFloat(v.Num, 64); err == nil {
			return f, nil
		}
	}
	return 0, &JsonJsonError{Path: path, Expected: "Float", Found: jsonKindName(v)}
}

func JsonBool(v JsonValue, path string) (bool, *JsonJsonError) {
	if v.Kind == 'b' {
		return v.Bool, nil
	}
	return false, &JsonJsonError{Path: path, Expected: "Bool", Found: jsonKindName(v)}
}

// JsonAtom decodes a JSON string holding an atom's visual form.
func JsonAtom(v JsonValue, path string) (Atom, *JsonJsonError) {
	if v.Kind == 's' {
		for i, name := range atomNames {
			if name == v.Str {
				return Atom(i), nil
			}
		}
	}
	return 0, &JsonJsonError{Path: path, Expected: "a known atom", Found: jsonKindName(v)}
}

func JsonObject(v JsonValue, path string) ([]JsonMember, *JsonJsonError) {
	if v.Kind == 'o' {
		return v.Obj, nil
	}
	return nil, &JsonJsonError{Path: path, Expected: "an object", Found: jsonKindName(v)}
}

func JsonField(obj []JsonMember, key string, path string) (JsonValue, *JsonJsonError) {
	for _, m := range obj {
		if m.Key == key {
			return m.Value, nil
		}
	}
	return JsonValue{}, &JsonJsonError{Path: path + "." + key, Expected: "a value", Found: "nothing"}
}

// JsonLook is JsonField for a field with somewhere to fall back to: a key
// that is not there is an answer rather than an error.
func JsonLook(obj []JsonMember, key string) (JsonValue, bool) {
	for _, m := range obj {
		if m.Key == key {
			return m.Value, true
		}
	}
	return JsonValue{}, false
}

// JsonVariant unwraps the {"VariantName": {...}} encoding of tagged
// unions.
func JsonVariant(v JsonValue, path string) (string, JsonValue, *JsonJsonError) {
	if v.Kind == 'o' && len(v.Obj) == 1 {
		return v.Obj[0].Key, v.Obj[0].Value, nil
	}
	return "", JsonValue{}, &JsonJsonError{Path: path, Expected: "an object with a single variant key", Found: jsonKindName(v)}
}

func JsonVec[T any](v JsonValue, path string, elem func(JsonValue, string) (T, *JsonJsonError)) ([]T, *JsonJsonError) {
	if v.Kind != 'a' {
		return nil, &JsonJsonError{Path: path, Expected: "a vector", Found: jsonKindName(v)}
	}
	out := make([]T, 0, len(v.Arr))
	for i, item := range v.Arr {
		e, jerr := elem(item, path+"["+strconv.Itoa(i)+"]")
		if jerr != nil {
			return nil, jerr
		}
		out = append(out, e)
	}
	return out, nil
}

// JsonVecN also enforces the static length of e.g. Str[3].
func JsonVecN[T any](v JsonValue, path string, n int, elem func(JsonValue, string) (T, *JsonJsonError)) ([]T, *JsonJsonError) {
	if v.Kind != 'a' || len(v.Arr) != n {
		return nil, &JsonJsonError{Path: path, Expected: "a vector of length " + strconv.Itoa(n), Found: jsonKindName(v)}
	}
	return JsonVec(v, path, elem)
}

func JsonWhole(v JsonValue) (int, bool) {
	if v.Kind != '#' {
		return 0, false
	}
	i, err := strconv.Atoi(v.Num)
	return i, err == nil
}

func JsonEncodeStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func JsonEncodeInt(i int) string { return strconv.Itoa(i) }

func JsonEncodeFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func JsonEncodeBool(b bool) string { return strconv.FormatBool(b) }

// Atoms encode as their visual form.
func JsonEncodeAtom(a Atom) string { return JsonEncodeStr(a.String()) }

func JsonEncodeVec[T any](items []T, elem func(T) string) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(elem(item))
	}
	b.WriteByte(']')
	return b.String()
}

// A Float always reads back as one: `1.0`, never `1`.
func JsonEncodeFraction(f float64) string {
	s := JsonEncodeFloat(f)
	if strings.ContainsAny(s, ".eEnN") {
		return s
	}
	return s + ".0"
}

func JsonEncodeDict[V any](d Dict[string, V], value func(V) string) string {
	var b strings.Builder
	b.WriteByte('{')
	for i, key := range d.order {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(JsonEncodeStr(key))
		b.WriteByte(':')
		b.WriteString(value(d.byKey[key]))
	}
	b.WriteByte('}')
	return b.String()
}

// JsonEncodeDynamic is the fallback when the compiler couldn't infer a
// static type for hive.json.encode's argument.
func JsonEncodeDynamic(v any) string {
	switch x := v.(type) {
	case string:
		return JsonEncodeStr(x)
	case int:
		return JsonEncodeInt(x)
	case float64:
		return JsonEncodeFloat(x)
	case bool:
		return JsonEncodeBool(x)
	case Atom:
		return JsonEncodeAtom(x)
	case []string:
		return JsonEncodeVec(x, JsonEncodeStr)
	}
	panic("hive: json.encode: cannot derive an encoder for this value")
}
