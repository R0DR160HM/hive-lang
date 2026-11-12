// SVG, drawn at whatever size it is shown: the document, its styles and its units.
package hive

import (
	"bytes"
	"encoding/xml"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

type uiSvgNode struct {
	tag    string
	attrs  map[string]string
	kids   []*uiSvgNode
	parent *uiSvgNode
	text   strings.Builder
	decl   map[string]string
}

type uiSvgDoc struct {
	root *uiSvgNode
	ids  map[string]*uiSvgNode
}

const uiSvgMostNodes = 200000

func uiSvgSniff(b []byte) bool {
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf"))
	for {
		b = bytes.TrimLeft(b, " \t\r\n")
		switch {
		case bytes.HasPrefix(b, []byte("<?")):
			end := bytes.Index(b, []byte("?>"))
			if end < 0 {
				return false
			}
			b = b[end+2:]
		case bytes.HasPrefix(b, []byte("<!--")):
			end := bytes.Index(b, []byte("-->"))
			if end < 0 {
				return false
			}
			b = b[end+3:]
		case bytes.HasPrefix(b, []byte("<!")):
			depth, i := 0, 2
			for ; i < len(b); i++ {
				if b[i] == '[' {
					depth++
				} else if b[i] == ']' {
					depth--
				} else if b[i] == '>' && depth <= 0 {
					break
				}
			}
			if i >= len(b) {
				return false
			}
			b = b[i+1:]
		default:
			if !bytes.HasPrefix(b, []byte("<")) {
				return false
			}
			name := b[1:]
			end := bytes.IndexAny(name, " \t\r\n/>")
			if end < 0 {
				return false
			}
			name = name[:end]
			if colon := bytes.IndexByte(name, ':'); colon >= 0 {
				name = name[colon+1:]
			}
			return string(name) == "svg"
		}
	}
}

func uiParseSVG(body []byte) (uiVector, bool) {
	if !uiSvgSniff(body) {
		return nil, false
	}
	d := xml.NewDecoder(bytes.NewReader(body))
	d.Strict = false
	d.AutoClose = xml.HTMLAutoClose
	d.Entity = xml.HTMLEntity
	d.CharsetReader = func(_ string, in io.Reader) (io.Reader, error) { return in, nil }
	doc := &uiSvgDoc{ids: map[string]*uiSvgNode{}}
	var at *uiSvgNode
	count := 0
	for count < uiSvgMostNodes {
		tok, err := d.Token()
		if err != nil {
			break
		}
		switch t := tok.(type) {
		case xml.StartElement:
			count++
			n := &uiSvgNode{tag: t.Name.Local, attrs: map[string]string{}, parent: at}
			for _, a := range t.Attr {
				key := a.Name.Local
				if a.Name.Space != "" && key != "href" && a.Name.Space != "xmlns" && a.Name.Space != "http://www.w3.org/2000/svg" {
					continue
				}
				if _, has := n.attrs[key]; key == "href" && has && a.Name.Space != "" {
					continue
				}
				n.attrs[key] = a.Value
			}
			if at == nil {
				if doc.root != nil {
					continue
				}
				doc.root = n
			} else {
				at.kids = append(at.kids, n)
			}
			if id := n.attrs["id"]; id != "" {
				if _, taken := doc.ids[id]; !taken {
					doc.ids[id] = n
				}
			}
			at = n
		case xml.EndElement:
			if at != nil {
				at = at.parent
			}
		case xml.CharData:
			if at != nil && at.tag == "style" && at.text.Len() < 1<<20 {
				at.text.Write(t)
			}
		}
	}
	if doc.root == nil || doc.root.tag != "svg" {
		return nil, false
	}
	doc.cascade()
	return doc, true
}

var uiSvgProperties = map[string]bool{
	"fill": true, "fill-opacity": true, "fill-rule": true, "stroke": true, "stroke-width": true,
	"stroke-opacity": true, "stroke-linecap": true, "stroke-linejoin": true, "stroke-miterlimit": true,
	"stroke-dasharray": true, "stroke-dashoffset": true, "opacity": true, "display": true, "visibility": true,
	"color": true, "stop-color": true, "stop-opacity": true, "clip-path": true, "clip-rule": true, "transform": true,
}

type uiSvgRule struct {
	chain [][]string
	kinds []byte
	spec  int
	order int
	decl  [][2]string
	force bool
}

func uiSvgDecls(s string) (normal, important [][2]string) {
	for _, part := range strings.Split(s, ";") {
		colon := strings.IndexByte(part, ':')
		if colon < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(part[:colon]))
		value := strings.TrimSpace(part[colon+1:])
		if i := strings.Index(strings.ToLower(value), "!important"); i >= 0 {
			important = append(important, [2]string{key, strings.TrimSpace(value[:i])})
			continue
		}
		normal = append(normal, [2]string{key, value})
	}
	return
}

func uiSvgStripComments(s string) string {
	for {
		i := strings.Index(s, "/*")
		if i < 0 {
			return s
		}
		j := strings.Index(s[i+2:], "*/")
		if j < 0 {
			return s[:i]
		}
		s = s[:i] + " " + s[i+2+j+2:]
	}
}

func uiSvgRules(css string, order *int) []uiSvgRule {
	css = uiSvgStripComments(css)
	var rules []uiSvgRule
	for len(css) > 0 {
		open := strings.IndexByte(css, '{')
		if open < 0 {
			break
		}
		head := strings.TrimSpace(css[:open])
		depth, end := 1, open+1
		for ; end < len(css) && depth > 0; end++ {
			switch css[end] {
			case '{':
				depth++
			case '}':
				depth--
			}
		}
		body := css[open+1 : max(open+1, end-1)]
		css = css[end:]
		if strings.HasPrefix(head, "@") {
			continue
		}
		normal, important := uiSvgDecls(body)
		for _, sel := range strings.Split(head, ",") {
			chain, kinds, spec, ok := uiSvgSelector(strings.TrimSpace(sel))
			if !ok {
				continue
			}
			*order++
			rules = append(rules, uiSvgRule{chain: chain, kinds: kinds, spec: spec, order: *order, decl: normal})
			if len(important) > 0 {
				rules = append(rules, uiSvgRule{chain: chain, kinds: kinds, spec: spec, order: *order, decl: important, force: true})
			}
		}
	}
	return rules
}

func uiSvgSelector(s string) ([][]string, []byte, int, bool) {
	if s == "" {
		return nil, nil, 0, false
	}
	s = strings.ReplaceAll(s, ">", " > ")
	var chain [][]string
	var kinds []byte
	spec := 0
	next := byte(' ')
	for _, word := range strings.Fields(s) {
		if word == ">" {
			next = '>'
			continue
		}
		var parts []string
		for i := 0; i < len(word); {
			j := i + 1
			for j < len(word) && word[j] != '.' && word[j] != '#' {
				j++
			}
			part := word[i:j]
			switch {
			case strings.ContainsAny(part, ":[]()+~*") && part != "*":
				return nil, nil, 0, false
			case part[0] == '#':
				spec += 10000
			case part[0] == '.':
				spec += 100
			case part != "*":
				spec++
			}
			parts = append(parts, part)
			i = j
		}
		chain = append(chain, parts)
		kinds = append(kinds, next)
		next = ' '
	}
	return chain, kinds, spec, len(chain) > 0
}

func (n *uiSvgNode) matches(parts []string) bool {
	classes := strings.Fields(n.attrs["class"])
	for _, p := range parts {
		switch {
		case p == "*":
		case p[0] == '#':
			if n.attrs["id"] != p[1:] {
				return false
			}
		case p[0] == '.':
			found := false
			for _, c := range classes {
				if c == p[1:] {
					found = true
				}
			}
			if !found {
				return false
			}
		default:
			if n.tag != p {
				return false
			}
		}
	}
	return true
}

func (r *uiSvgRule) applies(n *uiSvgNode) bool {
	last := len(r.chain) - 1
	if !n.matches(r.chain[last]) {
		return false
	}
	at := n.parent
	for i := last - 1; i >= 0; i-- {
		child := r.kinds[i+1] == '>'
		for at != nil && !at.matches(r.chain[i]) {
			if child {
				return false
			}
			at = at.parent
		}
		if at == nil {
			return false
		}
		at = at.parent
	}
	return true
}

func (doc *uiSvgDoc) cascade() {
	var rules []uiSvgRule
	order := 0
	var styles func(n *uiSvgNode)
	styles = func(n *uiSvgNode) {
		if n.tag == "style" {
			rules = append(rules, uiSvgRules(n.text.String(), &order)...)
		}
		for _, k := range n.kids {
			styles(k)
		}
	}
	styles(doc.root)
	sort.SliceStable(rules, func(i, j int) bool {
		if rules[i].force != rules[j].force {
			return !rules[i].force
		}
		if rules[i].spec != rules[j].spec {
			return rules[i].spec < rules[j].spec
		}
		return rules[i].order < rules[j].order
	})
	var walk func(n *uiSvgNode)
	walk = func(n *uiSvgNode) {
		n.decl = map[string]string{}
		for k, v := range n.attrs {
			if uiSvgProperties[k] && k != "transform" {
				n.decl[k] = strings.TrimSpace(v)
			}
		}
		normal, important := uiSvgDecls(n.attrs["style"])
		forced := false
		for _, r := range rules {
			if r.force && !forced {
				for _, d := range normal {
					n.decl[d[0]] = d[1]
				}
				forced = true
			}
			if r.applies(n) {
				for _, d := range r.decl {
					n.decl[d[0]] = d[1]
				}
			}
		}
		if !forced {
			for _, d := range normal {
				n.decl[d[0]] = d[1]
			}
		}
		for _, d := range important {
			n.decl[d[0]] = d[1]
		}
		for _, k := range n.kids {
			walk(k)
		}
	}
	walk(doc.root)
}

type uiSvgColor [4]float64

func uiSvgHex(v uint32) uiSvgColor {
	return uiSvgColor{float64(v>>16&0xff) / 255, float64(v>>8&0xff) / 255, float64(v&0xff) / 255, 1}
}

func uiSvgFunctionArgs(s string) []string {
	s = strings.NewReplacer(",", " ", "/", " / ").Replace(s)
	return strings.Fields(s)
}

func uiSvgChannel(s string, scale float64) (float64, bool) {
	if strings.HasSuffix(s, "%") {
		v, err := strconv.ParseFloat(s[:len(s)-1], 64)
		return uiClamp(v/100, 0, 1), err == nil
	}
	v, err := strconv.ParseFloat(s, 64)
	return uiClamp(v/scale, 0, 1), err == nil
}

func uiSvgParseColor(s string, current uiSvgColor) (uiSvgColor, bool) {
	s = strings.ToLower(strings.TrimSpace(s))
	switch {
	case s == "currentcolor":
		return current, true
	case s == "transparent":
		return uiSvgColor{}, true
	case strings.HasPrefix(s, "#"):
		h := s[1:]
		if len(h) == 3 || len(h) == 4 {
			var b strings.Builder
			for i := 0; i < len(h); i++ {
				b.WriteByte(h[i])
				b.WriteByte(h[i])
			}
			h = b.String()
		}
		if len(h) == 6 {
			h += "ff"
		}
		v, err := strconv.ParseUint(h, 16, 32)
		if err != nil || len(h) != 8 {
			return uiSvgColor{}, false
		}
		c := uiSvgHex(uint32(v >> 8))
		c[3] = float64(v&0xff) / 255
		return c, true
	case strings.HasPrefix(s, "rgb(") || strings.HasPrefix(s, "rgba("):
		open, close := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
		if close < open {
			return uiSvgColor{}, false
		}
		args := uiSvgFunctionArgs(s[open+1 : close])
		var c uiSvgColor
		c[3] = 1
		n := 0
		for _, a := range args {
			if a == "/" {
				continue
			}
			scale := 255.0
			if n == 3 {
				scale = 1
			}
			v, ok := uiSvgChannel(a, scale)
			if !ok || n > 3 {
				return uiSvgColor{}, false
			}
			c[n] = v
			n++
		}
		return c, n >= 3
	case strings.HasPrefix(s, "hsl(") || strings.HasPrefix(s, "hsla("):
		open, close := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
		if close < open {
			return uiSvgColor{}, false
		}
		var vals []float64
		alpha := 1.0
		for i, a := range uiSvgFunctionArgs(s[open+1 : close]) {
			if a == "/" {
				continue
			}
			if len(vals) == 3 {
				alpha, _ = uiSvgChannel(a, 1)
				continue
			}
			a = strings.TrimSuffix(strings.TrimSuffix(a, "deg"), "%")
			v, err := strconv.ParseFloat(a, 64)
			if err != nil {
				return uiSvgColor{}, false
			}
			if i > 0 {
				v /= 100
			}
			vals = append(vals, v)
		}
		if len(vals) < 3 {
			return uiSvgColor{}, false
		}
		h := math.Mod(math.Mod(vals[0], 360)+360, 360) / 360
		sat, l := uiClamp(vals[1], 0, 1), uiClamp(vals[2], 0, 1)
		q := l + sat - l*sat
		if l < 0.5 {
			q = l * (1 + sat)
		}
		p := 2*l - q
		hue := func(t float64) float64 {
			t = t - math.Floor(t)
			switch {
			case t < 1.0/6:
				return p + (q-p)*6*t
			case t < 0.5:
				return q
			case t < 2.0/3:
				return p + (q-p)*(2.0/3-t)*6
			}
			return p
		}
		return uiSvgColor{hue(h + 1.0/3), hue(h), hue(h - 1.0/3), alpha}, true
	}
	if v, ok := uiSvgNamed[s]; ok {
		return uiSvgHex(v), true
	}
	return uiSvgColor{}, false
}

type uiSvgPaint struct {
	none  bool
	color uiSvgColor
	ref   string
	back  *uiSvgPaint
}

func uiSvgParsePaint(s string, current uiSvgColor) (uiSvgPaint, bool) {
	s = strings.TrimSpace(s)
	if s == "none" {
		return uiSvgPaint{none: true}, true
	}
	if strings.HasPrefix(s, "url(") {
		close := strings.IndexByte(s, ')')
		if close < 0 {
			return uiSvgPaint{}, false
		}
		ref := strings.Trim(strings.TrimSpace(s[4:close]), "'\"")
		p := uiSvgPaint{ref: strings.TrimPrefix(ref, "#")}
		if rest := strings.TrimSpace(s[close+1:]); rest != "" {
			if back, ok := uiSvgParsePaint(rest, current); ok {
				p.back = &back
			}
		}
		return p, true
	}
	c, ok := uiSvgParseColor(s, current)
	return uiSvgPaint{color: c}, ok
}

func uiSvgNumbers(s string) []float64 {
	var out []float64
	p := uiSvgScanner{s: s}
	for {
		v, ok := p.number()
		if !ok {
			return out
		}
		out = append(out, v)
	}
}

func uiSvgLength(s string, of float64) (float64, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	units := map[string]float64{"px": 1, "pt": 4.0 / 3, "pc": 16, "mm": 96 / 25.4, "cm": 96 / 2.54, "in": 96, "em": 16, "ex": 8, "rem": 16}
	scale := 1.0
	switch {
	case strings.HasSuffix(s, "%"):
		scale, s = of/100, s[:len(s)-1]
	case len(s) > 2 && units[s[len(s)-2:]] != 0 && (s[len(s)-3] >= '0' && s[len(s)-3] <= '9' || s[len(s)-3] == '.'):
		scale, s = units[s[len(s)-2:]], s[:len(s)-2]
	case len(s) > 3 && strings.HasSuffix(s, "rem"):
		scale, s = 16, s[:len(s)-3]
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	return v * scale, true
}

type uiSvgM [6]float64

var uiSvgIdentity = uiSvgM{1, 0, 0, 1, 0, 0}

func (m uiSvgM) mul(n uiSvgM) uiSvgM {
	return uiSvgM{
		m[0]*n[0] + m[2]*n[1], m[1]*n[0] + m[3]*n[1],
		m[0]*n[2] + m[2]*n[3], m[1]*n[2] + m[3]*n[3],
		m[0]*n[4] + m[2]*n[5] + m[4], m[1]*n[4] + m[3]*n[5] + m[5],
	}
}

func (m uiSvgM) apply(x, y float64) (float64, float64) {
	return m[0]*x + m[2]*y + m[4], m[1]*x + m[3]*y + m[5]
}

func (m uiSvgM) invert() (uiSvgM, bool) {
	det := m[0]*m[3] - m[1]*m[2]
	if det == 0 || math.IsNaN(det) {
		return uiSvgM{}, false
	}
	return uiSvgM{m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
		(m[2]*m[5] - m[3]*m[4]) / det, (m[1]*m[4] - m[0]*m[5]) / det}, true
}

func (m uiSvgM) scale() float64 { return math.Sqrt(math.Abs(m[0]*m[3] - m[1]*m[2])) }

func uiSvgTransform(s string) uiSvgM {
	m := uiSvgIdentity
	s = strings.NewReplacer("deg", "", "px", "").Replace(s)
	for {
		open := strings.IndexByte(s, '(')
		close := strings.IndexByte(s, ')')
		if open < 0 || close < open {
			return m
		}
		name := strings.TrimSpace(strings.Trim(strings.TrimSpace(s[:open]), ","))
		v := uiSvgNumbers(s[open+1 : close])
		s = s[close+1:]
		var t uiSvgM
		switch {
		case name == "matrix" && len(v) == 6:
			t = uiSvgM{v[0], v[1], v[2], v[3], v[4], v[5]}
		case name == "translate" && len(v) == 1:
			t = uiSvgM{1, 0, 0, 1, v[0], 0}
		case name == "translate" && len(v) == 2:
			t = uiSvgM{1, 0, 0, 1, v[0], v[1]}
		case name == "scale" && len(v) == 1:
			t = uiSvgM{v[0], 0, 0, v[0], 0, 0}
		case name == "scale" && len(v) == 2:
			t = uiSvgM{v[0], 0, 0, v[1], 0, 0}
		case name == "rotate" && (len(v) == 1 || len(v) == 3):
			a := v[0] * math.Pi / 180
			t = uiSvgM{math.Cos(a), math.Sin(a), -math.Sin(a), math.Cos(a), 0, 0}
			if len(v) == 3 {
				t = uiSvgM{1, 0, 0, 1, v[1], v[2]}.mul(t).mul(uiSvgM{1, 0, 0, 1, -v[1], -v[2]})
			}
		case name == "skewX" && len(v) == 1:
			t = uiSvgM{1, 0, math.Tan(v[0] * math.Pi / 180), 1, 0, 0}
		case name == "skewY" && len(v) == 1:
			t = uiSvgM{1, math.Tan(v[0] * math.Pi / 180), 0, 1, 0, 0}
		default:
			return uiSvgIdentity
		}
		m = m.mul(t)
	}
}

func uiSvgFit(box []float64, how string, x, y, w, h float64) uiSvgM {
	sx, sy := w/box[2], h/box[3]
	fields := strings.Fields(how)
	if len(fields) > 0 && fields[0] == "defer" {
		fields = fields[1:]
	}
	align, slice := "xMidYMid", false
	if len(fields) > 0 {
		align = fields[0]
	}
	if len(fields) > 1 {
		slice = fields[1] == "slice"
	}
	if align == "none" {
		return uiSvgM{sx, 0, 0, sy, x - box[0]*sx, y - box[1]*sy}
	}
	s := math.Min(sx, sy)
	if slice {
		s = math.Max(sx, sy)
	}
	ax, ay := 0.5, 0.5
	if strings.HasPrefix(align, "xMin") {
		ax = 0
	} else if strings.HasPrefix(align, "xMax") {
		ax = 1
	}
	if strings.HasSuffix(align, "YMin") {
		ay = 0
	} else if strings.HasSuffix(align, "YMax") {
		ay = 1
	}
	return uiSvgM{s, 0, 0, s, x - box[0]*s + ax*(w-box[2]*s), y - box[1]*s + ay*(h-box[3]*s)}
}

func uiSvgViewBox(s string) []float64 {
	v := uiSvgNumbers(s)
	if len(v) != 4 || v[2] <= 0 || v[3] <= 0 {
		return nil
	}
	return v
}

func (doc *uiSvgDoc) size() (float64, float64) {
	box := uiSvgViewBox(doc.root.attrs["viewBox"])
	w, wok := uiSvgAbsolute(doc.root.attrs["width"])
	h, hok := uiSvgAbsolute(doc.root.attrs["height"])
	switch {
	case wok && hok:
	case wok && box != nil:
		h = w * box[3] / box[2]
	case hok && box != nil:
		w = h * box[2] / box[3]
	case box != nil:
		w, h = box[2], box[3]
	default:
		w, h = 300, 150
	}
	if !(w > 0 && h > 0) || w > 16384 || h > 16384 {
		return 300, 150
	}
	return w, h
}

func uiSvgAbsolute(s string) (float64, bool) {
	if strings.HasSuffix(strings.TrimSpace(s), "%") {
		return 0, false
	}
	v, ok := uiSvgLength(s, 0)
	return v, ok && v > 0
}

func (doc *uiSvgDoc) render(w, h int) []uint8 {
	if w <= 0 || h <= 0 || w > 16384 || h > 16384 {
		return nil
	}
	nw, nh := doc.size()
	r := &uiSvgRender{doc: doc, w: w, h: h, vp: [][2]float64{{nw, nh}}}
	var m uiSvgM
	if box := uiSvgViewBox(doc.root.attrs["viewBox"]); box != nil {
		m = uiSvgFit(box, doc.root.attrs["preserveAspectRatio"], 0, 0, float64(w), float64(h))
		r.vp[0] = [2]float64{box[2], box[3]}
	} else {
		m = uiSvgM{float64(w) / nw, 0, 0, float64(h) / nh, 0, 0}
	}
	out := make([]uint8, w*h*4)
	st := uiSvgInitial()
	st = r.style(doc.root, st)
	if !st.display || st.opacity <= 0 {
		return out
	}
	if st.opacity >= 1 {
		r.children(doc.root, m, st, out, 0)
		return out
	}
	layer := make([]uint8, len(out))
	r.children(doc.root, m, st, layer, 0)
	r.merge(out, layer, st.opacity, nil)
	return out
}
