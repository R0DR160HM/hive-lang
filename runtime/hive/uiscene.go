// The Go for `hive.ui.scene`: three dimensions in a window. The set of shapes
// is small on purpose — a shape is here only if it cannot be made out of the
// others — and the drawing is done by the engine in `scene/`, built on Filament:
// beside the program for a window it draws itself, and as WebAssembly for a page.
// hive.ui's third dimension.
//
// A scene is a widget like any other, rendering to a box on the page that a
// small engine draws into. What makes it different is that the box is
// kept: the payload travels on a frame of its own (see publish in ui.go), so
// the world can be redrawn sixty times a second without the document around it
// being re-sent or the canvas replaced.
//
// The shapes are a closed set and the attributes are semantic tokens, for the
// same reason the widgets are: at, turn and paint mean something to any
// renderer, where a mesh and a shader would mean something only to this one.
//
// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------
package hive

import (
	"embed"
	"encoding/binary"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

// The engine as a page runs it, placed at compile time against a pinned digest
// and embedded here. Nothing is loaded from the network when the program runs: a
// built Hive program is one file, and a window opening a socket to a CDN would
// end that.
//
//go:embed hive-scene.js hive-scene.wasm
var uiSceneLib embed.FS

// What the window serves and puts on the page. This runs because the file is
// in the build, and the file is in the build because the program draws a
// scene — which is how hive.ui learns it has a third dimension today.
func init() {
	uiExtraScript = "<script type=\"module\" src=\"/_hive/scene.js\"></script>"
	uiExtraRoutes["/_hive/scene.js"] = uiSceneText("text/javascript", uiSceneJS)
	uiExtraRoutes["/_hive/terrain/"] = uiSceneTerrainData
	uiExtraRoutes["/_hive/hive-scene.js"] = uiSceneAsset("hive-scene.js", "text/javascript; charset=utf-8")
	uiExtraRoutes["/_hive/hive-scene.wasm"] = uiSceneAsset("hive-scene.wasm", "application/wasm")

}

func uiSceneText(mime string, body string) func(http.ResponseWriter, *http.Request) {
	return func(rw http.ResponseWriter, _ *http.Request) {
		rw.Header().Set("Content-Type", mime+"; charset=utf-8")
		rw.Header().Set("Cache-Control", "no-store")
		_, _ = rw.Write([]byte(body))
	}
}

// A file of the embedded engine. It carries no token: it is the same public
// bytes on every machine, it says nothing about the program serving it, and the
// page that loads it was already let in.
func uiSceneAsset(name, mime string) func(http.ResponseWriter, *http.Request) {
	return func(rw http.ResponseWriter, _ *http.Request) {
		body, err := uiSceneLib.ReadFile(name)
		if err != nil {
			http.Error(rw, "not found", http.StatusNotFound)
			return
		}
		rw.Header().Set("Content-Type", mime)

		// ---------------------------------------------------------------------------
		// The shapes
		// ---------------------------------------------------------------------------
		rw.Header().Set("Cache-Control", "no-store")
		_, _ = rw.Write(body)
	}
}

// UiShape is one thing in a scene. Kind names it, Nums carries the dimensions
// its kind takes, and Text the words a label shows — the same arrangement
// UiView uses, and for the same reason.
//
// A shape is deliberately not a UiView. Two closed sets with two meanings, and
// keeping them apart is what makes a button inside a scene something the
// compiler refuses rather than something the renderer drops.
type UiShape struct {
	Kind   string
	Attrs  []UiAttr
	Nums   []float64
	Text   string
	Paints []UiTone
}

func UiBox(attrs []UiAttr, width float64, height float64, depth float64) UiShape {
	return UiShape{Kind: "box", Attrs: attrs, Nums: []float64{width, height, depth}}
}

func UiSphere(attrs []UiAttr, radius float64) UiShape {
	return UiShape{Kind: "sphere", Attrs: attrs, Nums: []float64{radius}}
}

func UiCylinder(attrs []UiAttr, radius float64, height float64) UiShape {
	return UiShape{Kind: "cylinder", Attrs: attrs, Nums: []float64{radius, height}}
}

// A cone, given both of its radii rather than only the base one. A cone in the
// world is hardly ever the perfect one: a track marker is snub-nosed, a stack
// of tyres narrows without coming to a point. Nought for the top is the
// perfect one.
func UiCone(attrs []UiAttr, top float64, bottom float64, height float64) UiShape {
	return UiShape{Kind: "cone", Attrs: attrs, Nums: []float64{top, bottom, height}}
}

// A pitched roof. The alternative — two boxes leaned together — leaves the
// gable ends open and costs a second solid on every building in the scene.
func UiRoof(attrs []UiAttr, wide float64, tall float64, long float64) UiShape {
	return UiShape{Kind: "roof", Attrs: attrs, Nums: []float64{wide, tall, long}}
}

// A plane that lies flat, because that is what a floor is. It takes no rotation
// to be one — the geometry is built lying down — so the common case costs
// nothing and turn still means what it means everywhere else.
func UiGround(attrs []UiAttr, width float64, depth float64) UiShape {
	return UiShape{Kind: "ground", Attrs: attrs, Nums: []float64{width, depth}}
}

// Words standing in the world at a position, always turned to face whoever is
// looking. A name over somebody's head is the case this is for, and it is why it
// takes no rotation: a label you can read from one side only is not a label.
func UiSprite(attrs []UiAttr, image string, wide float64, tall float64) UiShape {
	return UiShape{Kind: "sprite", Attrs: attrs, Text: image,
		Nums: []float64{wide, tall}}
}

func UiLabel(attrs []UiAttr, words string) UiShape {
	return UiShape{Kind: "label", Attrs: attrs, Text: words}
}

// A body out of a skinned glTF under assets/: a person, an animal, anything
// made of bones and a skin over them, which no number of boxes stands in for
// once it is near.
//
// The bones are numbers, three a bone — its turn on top of how it stands in
// the file, in the file's order — so a program poses a body the way it places
// a box, and a walk is a walk worked out by the program rather than a clip
// played back by the renderer. The paints are a colour a part, a part being
// one of the mesh's primitives: a shirt in a colour, the skin under it in a
// colour that is see-through, and so not drawn at all.
func UiFigure(attrs []UiAttr, model string, bones []float64, paints []UiTone) UiShape {
	return UiShape{Kind: "figure", Attrs: attrs, Text: model, Nums: bones, Paints: paints}
}

// The ground, as one surface: a height at every corner of a grid so many corners
// across and so many metres between them, and a colour at every corner, 0xRRGGBB.
//
// It is the one shape too big to say again sixty times a second — an island is a
// quarter of a megabyte of heights — so what a frame carries is a name for what
// the ground is, worked out from every number in it, and the page asks for the
// numbers themselves when the name is one it has not got. A program hands over
// the same two vectors every frame and nothing crosses; a shell digs a crater,
// the name changes, and the page fetches the ground once.
var uiTerrainLock sync.Mutex
var uiTerrainData = map[string][]byte{}
var uiTerrainSeen = map[string]uint64{}
var uiTerrainTick uint64

func UiTerrain(attrs []UiAttr, wide int, cell float64, heights []float64, colours []int) UiShape {
	if wide < 2 || len(heights) < wide*2 {
		return UiShape{Kind: "terrain", Attrs: attrs}
	}
	rows := len(heights) / wide
	count := rows * wide
	h := uint64(1469598103934665603)
	h = (h ^ uint64(wide)) * 1099511628211
	h = (h ^ math.Float64bits(cell)) * 1099511628211
	for _, v := range heights[:count] {
		h = (h ^ math.Float64bits(v)) * 1099511628211
	}
	for i := 0; i < count && i < len(colours); i++ {
		h = (h ^ uint64(colours[i])) * 1099511628211
	}
	id := strconv.FormatUint(h, 16)
	uiTerrainLock.Lock()
	uiTerrainTick++
	if _, ok := uiTerrainData[id]; !ok {
		data := make([]byte, 12+count*7)
		binary.LittleEndian.PutUint32(data[0:], uint32(wide))
		binary.LittleEndian.PutUint32(data[4:], uint32(rows))
		binary.LittleEndian.PutUint32(data[8:], math.Float32bits(float32(cell)))
		for i := 0; i < count; i++ {
			binary.LittleEndian.PutUint32(data[12+i*4:], math.Float32bits(float32(heights[i])))
		}
		tint := data[12+count*4:]
		for i := 0; i < count; i++ {
			c := 0x808080
			if i < len(colours) {
				c = colours[i]
			}
			tint[i*3] = byte(c >> 16)
			tint[i*3+1] = byte(c >> 8)
			tint[i*3+2] = byte(c)
		}
		uiTerrainData[id] = data
		// The ones nobody has named for longest go, once there are more than a scene
		// could be showing.
		for len(uiTerrainData) > 16 {
			oldest, when := "", uiTerrainTick
			for k, seen := range uiTerrainSeen {
				if seen < when {
					oldest, when = k, seen
				}
			}
			if oldest == "" {
				break
			}
			delete(uiTerrainData, oldest)
			delete(uiTerrainSeen, oldest)
		}
	}
	uiTerrainSeen[id] = uiTerrainTick
	uiTerrainLock.Unlock()
	return UiShape{Kind: "terrain", Attrs: attrs, Text: id}
}

func uiSceneTerrainData(w http.ResponseWriter, req *http.Request) {
	id := strings.TrimPrefix(req.URL.Path, "/_hive/terrain/")
	uiTerrainLock.Lock()
	data, ok := uiTerrainData[id]
	uiTerrainLock.Unlock()
	if !ok {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(data)
}

// A sound at a place in the world: something in the scene that is heard from
// where it stands instead of drawn where it stands.
//
// Its payload is a name, and the name is its identity across frames — the one
// place audio cannot follow the rule the solids follow. A box is matched to
// whatever was in its slot last frame, and a box rebuilt anyway is one nobody
// can tell was rebuilt. An oscillator rebuilt anyway is a click, sixty a
// second, and a slot cannot promise sameness: a scene is free to stop drawing
// the car in front, and every sound after it would shift up a place.
//
// So sounds are matched by what they are called: a name in both frames carries
// on, a new one starts, a departed one fades out. Which of those a voice
// actually does is the voice's own business — see the JS.
func UiSound(attrs []UiAttr, name string) UiShape {
	return UiShape{Kind: "sound", Attrs: attrs, Text: name}
}

// The one shape whose position is its payload rather than an attribute: a line
// is *between* two places, and there is no third one to call its own. A tracer
// is what this is for.
func UiLine(attrs []UiAttr, fromX float64, fromY float64, fromZ float64, toX float64, toY float64, toZ float64) UiShape {
	return UiShape{
		Kind:  "line",
		Attrs: attrs,
		Nums:  []float64{fromX, fromY, fromZ, toX, toY, toZ},
	}
}

// ---------------------------------------------------------------------------
// The attributes a scene and its shapes take
// ---------------------------------------------------------------------------
func UiAttrAt(x float64, y float64, z float64) UiAttr {
	return uiNums("at", []float64{x, y, z})
}

func UiAttrTurn(x float64, y float64, z float64) UiAttr {
	return uiNums("turn", []float64{x, y, z})
}

// How many times its own size a figure is drawn, each way: the one shape whose size
// is in a file and not in what the program says of it.
func UiAttrScale(x float64, y float64, z float64) UiAttr {
	return uiNums("scale", []float64{x, y, z})
}

// What it is made of. Absent, a shape is made of what its kind used to imply
// on its own — a floor is turf, a barrel is staves — so nothing that never
// mentions a surface draws differently for this existing.
func UiAttrSurface(v UiSurface) UiAttr { return uiEnum("surface", string(v)) }

// Which noise, and the two numbers every noise is bent by. Pitch and volume are
// multiples of what the voice is at rest rather than hertz and gain, so a
// program says "twice as fast" and never holds an opinion about a filter.
func UiAttrVoice(v UiVoice) UiAttr  { return uiEnum("voice", string(v)) }
func UiAttrPitch(v float64) UiAttr  { return uiNums("pitch", []float64{v}) }
func UiAttrVolume(v float64) UiAttr { return uiNums("volume", []float64{v}) }

// Which recording the voice is of, named by its path under assets/. The voice
// still says what the noise *is*; this says which one of it the program has to
// hand, and where there is none the oscillators answer as they always did.
func UiAttrTrack(v string) UiAttr { return uiStr("track", v) }

func UiAttrEye(x float64, y float64, z float64) UiAttr {
	return uiNums("eye", []float64{x, y, z})
}

func UiAttrAim(yaw float64, pitch float64) UiAttr {
	return uiNums("aim", []float64{yaw, pitch})
}

// Where the sun stands, said as a camera's aim is: a bearing, and how high.
// Absent, it stands where it always has.
func UiAttrSun(yaw float64, pitch float64) UiAttr {
	return uiNums("sun", []float64{yaw, pitch})
}

func UiAttrLens(fov int) UiAttr      { return uiNum("lens", fov) }
func UiAttrGrain(px int) UiAttr      { return uiNum("grain", px) }
func UiAttrBits(each int) UiAttr     { return uiNum("bits", each) }
func UiAttrFog(far int) UiAttr       { return uiNum("fog", far) }
func UiAttrCast(far int) UiAttr      { return uiNum("cast", far) }
func UiAttrGrab(on bool) UiAttr      { return UiAttr{Kind: "grab", Flag: on} }
func UiAttrCrosshair(on bool) UiAttr { return UiAttr{Kind: "crosshair", Flag: on} }

// Whether the sun casts. **Absent means yes**, so a scene written before this
// existed draws exactly as it did — and a program that wants the frames back
// has one thing to say rather than a lighting rig to describe.
//
// ---------------------------------------------------------------------------
// The frame a scene comes to
// ---------------------------------------------------------------------------
func UiAttrShadows(on bool) UiAttr { return UiAttr{Kind: "shadows", Flag: on} }

func UiAttrOnFrame(f func(int) any) UiAttr { return UiAttr{Kind: "onFrame", heard: &uiHeard{FnInt: f}} }
func UiAttrOnRate(f func(int) any) UiAttr  { return UiAttr{Kind: "onRate", heard: &uiHeard{FnInt: f}} }
func UiAttrOnKeyDown(f func(string) any) UiAttr {
	return UiAttr{Kind: "onKeyDown", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnKeyUp(f func(string) any) UiAttr {
	return UiAttr{Kind: "onKeyUp", heard: &uiHeard{FnStr: f}}
}
func UiAttrOnGrab(f func(bool) any) UiAttr { return UiAttr{Kind: "onGrab", heard: &uiHeard{FnBool: f}} }

func UiAttrOnLook(f func(float64, float64) any) UiAttr {
	return UiAttr{Kind: "onLook", heard: &uiHeard{FnLook: f}}
}

func UiAttrOnPad(f func(int, string, float64) any) UiAttr {
	return UiAttr{Kind: "onPad", heard: &uiHeard{FnPad: f}}
}

func UiAttrOnSize(f func(int, int) any) UiAttr {
	return UiAttr{Kind: "onSize", heard: &uiHeard{FnSize: f}}
}

// UiScene is the widget. The tree keeps the attributes — the layout ones are
// what put the box on the page — and the whole description of the world is
// written out here, once, into the payload the window sends on its own frame.
//
// Room for the whole frame, asked for once. A builder not told how big the
// answer will be doubles its buffer as it fills, and doubling copies
// everything so far — a hundred-kilobyte frame was seventeen allocations and
// half a megabyte of copying before a single shape was described. The
// estimate need not be right, only close enough that the doubling stops.
func UiScene(attrs []UiAttr, shapes []UiShape) UiView {
	var b strings.Builder
	b.Grow(len(shapes)*64 + 256)
	uiSceneCamera(&b, attrs)
	uiPackU32(&b, len(shapes))

	// Where each record starts, and after the last of them where it ends. One
	// integer a shape, and all the window needs to send one without its
	// neighbours — see uiSceneFrame.
	cuts := make([]int32, len(shapes)+1)
	for i := range shapes {
		cuts[i] = int32(b.Len())
		uiSceneShape(&b, &shapes[i])
	}
	cuts[len(shapes)] = int32(b.Len())
	return UiView{Kind: "scene", Attrs: attrs, Text: b.String(), Cuts: cuts}
}

// UiInset is the second look at that world, and it holds no world of its own —
// only a camera. What it draws is whatever the scene is drawing, which is why
// it is affordable: a picture-in-picture carrying its own shapes would be a
// second description of where everything is.
//
// Its children are ordinary views, laid out as a column would lay them out and
// over the picture rather than in it.
func UiInset(attrs []UiAttr, views []UiView) UiView {
	var b strings.Builder
	uiSceneCamera(&b, attrs)
	return UiView{Kind: "inset", Attrs: attrs, Children: views, Text: b.String()}
}

// Where the eye is, where it is looking, and what the world around it looks
// like. Every one has an answer whether or not the program gave one: a scene
// with no camera attributes is a metre and a half above the origin looking
// down -Z, which is a view of something rather than a blank.
//
// Which of the rest of it there is, in one byte, so that a camera saying
// nothing about its lens costs nothing for the lens it did not name.
//
// The sky is the widget's own background, which is the same attribute a
// column paints itself with: what is behind the content, in the one place
// where what is behind the content is the sky.
//
// Set only when it is false, which is what makes "absent means yes" true on
// the page as well as here: a scene that says nothing gets shadows.
func uiSceneCamera(b *strings.Builder, attrs []UiAttr) {
	eye := uiSceneNums(attrs, "eye", uiSceneEyeAt)
	aim := uiSceneNums(attrs, "aim", uiSceneAimAt)
	uiPackF32(b, eye[0])
	uiPackF32(b, eye[1])
	uiPackF32(b, eye[2])
	uiPackF32(b, aim[0])
	uiPackF32(b, aim[1])
	lens, hasLens := uiFind(attrs, "lens")
	fog, hasFog := uiFind(attrs, "fog")
	sky, hasSky := uiFind(attrs, "background")
	bits := 0
	if hasLens {
		bits |= uiSceneEyeLens
	}
	if hasFog {
		bits |= uiSceneEyeFog
	}
	if hasSky {
		bits |= uiSceneEyeSky
	}
	if grab, ok := uiFind(attrs, "grab"); ok && grab.Flag {
		bits |= uiSceneEyeGrab
	}
	if lit, ok := uiFind(attrs, "shadows"); ok && !lit.Flag {
		bits |= uiSceneEyeFlat
	}
	grain, hasGrain := uiFind(attrs, "grain")
	depth, hasBits := uiFind(attrs, "bits")
	if hasGrain {
		bits |= uiSceneEyeGrain
	}
	if hasBits {
		bits |= uiSceneEyeBits
	}
	sunAt, hasSun := uiFind(attrs, "sun")
	shade, hasShade := uiFind(attrs, "cast")
	if hasSun || hasShade {
		bits |= uiSceneEyeSun
	}
	uiPackU8(b, bits)
	if hasLens {
		uiPackU16(b, lens.Num)
	}
	if hasFog {
		uiPackU16(b, fog.Num)
	}
	if hasGrain {
		uiPackU16(b, grain.Num)
	}
	if hasBits {
		uiPackU16(b, depth.Num)
	}
	if hasSky {
		uiPackWord(b, uiSceneTone(sky.Word, "#8ecbff"))
	}
	if hasSun || hasShade {
		yaw, pitch, far := 0.0, -100.0, 0
		if hasSun && len(sunAt.Nums) >= 2 {
			yaw, pitch = sunAt.Nums[0], sunAt.Nums[1]
		}
		if hasShade {
			far = shade.Num
		}
		uiPackF32(b, yaw)
		uiPackF32(b, pitch)
		uiPackU16(b, far)
	}

	// Which events the program is actually listening for. A page that would only
	// be telling the fold about frames nobody folds says nothing instead.
	//
	// Working out what the screen can do costs a sort of two seconds of gaps
	// once a second. A scene that does not ask does not pay for it.
	uiPackWord(b, uiSceneWants(attrs))
}

func uiSceneWants(attrs []UiAttr) string {
	var b strings.Builder
	if _, ok := uiFind(attrs, "onFrame"); ok {
		b.WriteString("f")
	}
	if _, ok := uiFind(attrs, "onRate"); ok {
		b.WriteString("r")
	}
	if _, ok := uiFind(attrs, "onKeyDown"); ok {
		b.WriteString("k")
	}
	if _, ok := uiFind(attrs, "onKeyUp"); ok {
		b.WriteString("u")
	}
	if _, ok := uiFind(attrs, "onLook"); ok {
		b.WriteString("l")
	}
	if _, ok := uiFind(attrs, "onGrab"); ok {
		b.WriteString("g")
	}

	// Reading the pads costs a poll every frame, because the browser offers no
	// event for one. A scene that does not fold them does not pay for them.
	if _, ok := uiFind(attrs, "onPad"); ok {
		b.WriteString("p")
	}
	if _, ok := uiFind(attrs, "onSize"); ok {
		b.WriteString("s")
	}
	return b.String()
}

// The three defaults a scene falls back on, written down once. They used to be
// slice literals in the argument list — which meant one allocation per shape,
// per frame, to describe a position that was about to be overwritten anyway.
var (
	uiSceneEyeAt  = []float64{0, 1.7, 0}
	uiSceneAimAt  = []float64{0, 0}
	uiSceneOrigin = []float64{0, 0, 0}
)

// The attributes this writer looks for, found in one pass instead of one pass
// each.
//
// uiFind walks the whole slice and hands back a UiAttr by value — a hundred and
// fifty bytes of strings, closures and a slice header, because it is one shape
// for every attribute in the module. A shape asked for up to five, so
// describing one meant five walks and five copies about to be ignored.
//
// This is the same question asked once, answered with pointers into the
// caller's own slice. First match wins, which is what uiFind does.
type uiSceneParts struct {
	at, turn, paint, surface, voice, track, pitch, volume, scale *UiAttr
}

func uiScenePartsOf(attrs []UiAttr) uiSceneParts {
	var p uiSceneParts
	for i := range attrs {
		one := &attrs[i]
		switch one.Kind {
		case "at":
			if p.at == nil {
				p.at = one
			}
		case "scale":
			if p.scale == nil {
				p.scale = one
			}
		case "turn":
			if p.turn == nil {
				p.turn = one
			}
		case "paint":
			if p.paint == nil {
				p.paint = one
			}
		case "surface":
			if p.surface == nil {
				p.surface = one
			}
		case "voice":
			if p.voice == nil {
				p.voice = one
			}
		case "track":
			if p.track == nil {
				p.track = one
			}
		case "pitch":
			if p.pitch == nil {
				p.pitch = one
			}
		case "volume":
			if p.volume == nil {
				p.volume = one
			}
		}
	}
	return p
}

// The numbers an attribute carries, or the default where it carries the wrong
// count. The same rule uiSceneNums applies, against a part already found.
//
// Written into the frame rather than assembled beside it. Every line below
// used to join its pieces with a plus and hand the result to the builder, so
// a shape allocated once per part and once per join. These write to the
// builder directly: the same bytes, and none of the rubbish.
//
// A sound has no colour, no dimensions, no rotation and nothing to shade.
// Writing all four sixty times a second for something nobody can see is why
// this is a branch of its own rather than four more conditionals below.
//
// A sound that names no recording says nothing, and is the sound this
// renderer has always made.
func uiScenePartNums(one *UiAttr, fallback []float64) []float64 {
	if one != nil && len(one.Nums) == len(fallback) {
		return one.Nums
	}
	return fallback
}

func uiScenePartOne(one *UiAttr, fallback float64) float64 {
	if one != nil && len(one.Nums) == 1 {
		return one.Nums[0]
	}
	return fallback
}

func uiScenePartEnum(one *UiAttr) string {
	if one != nil {
		return one.Word
	}
	return ""
}

func uiSceneShape(b *strings.Builder, s *UiShape) {
	p := uiScenePartsOf(s.Attrs)
	if s.Kind == "sound" {
		voice := uiScenePartEnum(p.voice)
		track := ""
		if p.track != nil {
			track = p.track.Word
		}
		mask := 0
		if voice != "" {
			mask |= uiSceneHasVoice
		}
		if track != "" {
			mask |= uiSceneHasTrack
		}
		uiPackU8(b, uiSceneSound)
		uiPackU8(b, mask)
		uiSceneVecTo(b, uiScenePartNums(p.at, uiSceneOrigin))
		uiPackLong(b, s.Text)
		if voice != "" {
			uiPackWord(b, voice)
		}
		if track != "" {
			uiPackWord(b, track)
		}
		uiPackF32(b, uiScenePartOne(p.pitch, 1))
		uiPackF32(b, uiScenePartOne(p.volume, 1))
		return
	}
	made := uiScenePartEnum(p.surface)
	mask := 0

	// A line carries both its ends in its payload, so it has no position of its
	// own and no rotation to apply to it.
	if s.Kind != "line" {
		mask |= uiSceneHasAt
		if p.turn != nil && uiSceneAny(p.turn.Nums) {
			mask |= uiSceneHasTurn
		}
		if p.scale != nil {
			mask |= uiSceneHasScale
		}
	}
	if len(s.Nums) > 0 {
		mask |= uiSceneHasSize
	}
	if made != "" {
		mask |= uiSceneHasSurface
	}
	if s.Text != "" {
		mask |= uiSceneHasWords
	}
	if len(s.Paints) > 0 {
		mask |= uiSceneHasPaints
	}
	uiPackU8(b, uiSceneKindCode(s.Kind))
	uiPackU8(b, mask)

	// A sprite unpainted is white, where every solid unpainted is grey. A picture
	// already has its own colours and the tint multiplies them, so the default has
	// to be the one that changes nothing; grey would quietly darken every sprite
	// nobody had an opinion about.
	bare := "#cfd6de"
	if s.Kind == "sprite" || s.Kind == "terrain" {
		bare = "#ffffff"
	}
	uiPackWord(b, uiSceneTone(uiScenePartEnum(p.paint), bare))
	if mask&uiSceneHasAt != 0 {
		uiSceneVecTo(b, uiScenePartNums(p.at, uiSceneOrigin))
	}
	if mask&uiSceneHasTurn != 0 {
		uiSceneVecTo(b, uiScenePartNums(p.turn, uiSceneOrigin))
	}
	if mask&uiSceneHasScale != 0 {
		uiSceneVecTo(b, uiScenePartNums(p.scale, []float64{1, 1, 1}))
	}
	if mask&uiSceneHasSize != 0 {
		uiPackU8(b, len(s.Nums))
		for _, n := range s.Nums {
			uiPackF32(b, n)
		}
	}
	if mask&uiSceneHasSurface != 0 {
		uiPackWord(b, made)
	}
	if mask&uiSceneHasWords != 0 {
		uiPackLong(b, s.Text)
	}
	if mask&uiSceneHasPaints != 0 {
		uiPackU8(b, len(s.Paints))
		for _, t := range s.Paints {
			uiPackWord(b, uiSceneTone(string(t), "#cfd6de"))
		}
	}
}

// The kinds as numbers, which of a shape's parts its record carries, and which
// of a camera's. Together they make a record self-describing, so the page can
// tell where one ends without a length in front of it. KINDS and the masks
// read in uiSceneJs are the other half of this and move with it.
const (
	uiSceneBox      = 0
	uiSceneSphere   = 1
	uiSceneCylinder = 2
	uiSceneCone     = 3
	uiSceneGround   = 4
	uiSceneLabel    = 5
	uiSceneLine     = 6
	uiSceneSound    = 7
	uiSceneSprite   = 8
	uiSceneRoof     = 9
	uiSceneFigure   = 10
	uiSceneTerrain  = 11

	uiSceneHasAt      = 1
	uiSceneHasTurn    = 2
	uiSceneHasSize    = 4
	uiSceneHasSurface = 8
	uiSceneHasWords   = 16
	uiSceneHasVoice   = 32
	uiSceneHasTrack   = 64
	uiSceneHasPaints  = 128
	uiSceneHasScale   = 32

	uiSceneEyeLens  = 1
	uiSceneEyeFog   = 2
	uiSceneEyeSky   = 4
	uiSceneEyeGrab  = 8
	uiSceneEyeFlat  = 16
	uiSceneEyeGrain = 32
	uiSceneEyeBits  = 64
	uiSceneEyeSun   = 128
)

// A kind the page does not know is drawn as a box, which is what an unknown
// kind has always come out as.
func uiSceneKindCode(kind string) int {
	switch kind {
	case "sphere":
		return uiSceneSphere
	case "cylinder":
		return uiSceneCylinder
	case "cone":
		return uiSceneCone
	case "ground":
		return uiSceneGround
	case "label":
		return uiSceneLabel
	case "sprite":
		return uiSceneSprite
	case "line":
		return uiSceneLine
	case "sound":
		return uiSceneSound
	case "roof":
		return uiSceneRoof
	case "figure":
		return uiSceneFigure
	case "terrain":
		return uiSceneTerrain
	}
	return uiSceneBox
}

// The colour a UiTone comes to in a world. A role has to be answered with a
// value here rather than with a class — there is no stylesheet in a scene — so
// these five are the palette, and they are the same five the page uses.
func uiSceneTone(enum string, fallback string) string {
	if colour, ok := uiToneColour(enum); ok {
		return colour
	}
	switch enum {
	case "Normal":
		return "#d8dee6"
	case "Muted":
		return "#8b98a5"
	case "Good":
		return "#2fbf71"
	case "Warn":
		return "#f0b429"
	case "Danger":
		return "#e14b3a"
	}
	return fallback
}

func uiSceneEnum(attrs []UiAttr, kind string) string {
	if a, ok := uiFind(attrs, kind); ok {
		return a.Word
	}
	return ""
}

func uiSceneNums(attrs []UiAttr, kind string, fallback []float64) []float64 {
	if a, ok := uiFind(attrs, kind); ok && len(a.Nums) == len(fallback) {
		return a.Nums
	}
	return fallback
}

// One number off an attribute that carries exactly one, or what it means when
// the attribute is not there at all. Both of the two are 1: a sound that says
// nothing about its pitch or its volume is a sound at rest, not a silent one.
func uiSceneOne(attrs []UiAttr, kind string, fallback float64) float64 {
	if a, ok := uiFind(attrs, kind); ok && len(a.Nums) == 1 {
		return a.Nums[0]
	}
	return fallback
}

func uiSceneAny(nums []float64) bool {
	for _, n := range nums {
		if n != 0 {
			return true
		}
	}
	return false
}

func uiSceneVecTo(b *strings.Builder, nums []float64) {
	for _, n := range nums {
		uiPackF32(b, n)
	}
}

// The JavaScript a scene is drawn by: the half of `hive.ui.scene` that runs in
// the page, talking to the same socket the rest of a window uses.
// The page's half of hive.ui.scene, served at /_hive/scene.js.
const uiSceneJS = `
import summon from "./hive-scene.js";

` +
	// The canvas lives here, outside the element the window swaps on every repaint.
	// A canvas inside it would be destroyed by each swap, and with it the WebGL
	// context, every geometry on the card, and — impossible to work around — the
	// pointer lock, which the browser drops when its element leaves the document.
	`var holder = document.createElement("div");
holder.className = "h-world";
holder.style.display = "none";
document.body.appendChild(holder);
var canvas = document.createElement("canvas");
canvas.id = "h-world-canvas";
holder.appendChild(canvas);

var engine = null;
var host = null, handle = "", world = {grab: false};
var boxes = [], insetsSaid = "";
var seen = {left: -1, top: -1, width: -1, height: -1};

` +
	// Whether that rectangle might be out of date, the observer that says so, and
	// how many frames since it was last read regardless. See watchBox.
	`var boxMoved = true, boxWatch = null, boxWatched = false, boxBeat = 0;
var sizeSaid = [-1, -1];

` +
	// Set by a frame this page cannot make sense of, cleared once the ask for the
	// whole world has gone out. See paint.
	`var needFull = false;

var want = "", grabbing = false, lookX = 0, lookY = 0, last = 0, dirty = false;
var held = {};

` +
	// What the engine asked for, answered between frames and never from inside it,
	// and the stretch of its memory a frame or a picture is handed over in.
	`var asks = [], room = 0, roomAt = 0;

function lent(bytes) {
  if (bytes.length > room) {
    if (roomAt) { engine._free(roomAt); }
    room = Math.max(bytes.length, room * 2, 65536);
    roomAt = engine._malloc(room);
  }
  engine.HEAPU8.set(bytes, roomAt);
  return roomAt;
}

function worded(text) { return engine.stringToNewUTF8(text); }

` +
	// A frame cut from one this page never drew is not taken, and the whole world
	// is asked for instead. See tick.
	`function paint(frame) {
  var bytes = new Uint8Array(frame);
  if (!engine._hs_frame(lent(bytes), bytes.length)) {
    needFull = true;
    return;
  }
  world = JSON.parse(engine.UTF8ToString(engine._hs_told()));
  want = world.on || "";
  if (world.sounds.length || voices.size) { sounds(world.sounds, world); }
  if (!world.grab && grabbing) { document.exitPointerLock(); }
  dirty = true;
}

function answer() {
  if (!asks.length) { return; }
  var waiting = asks;
  asks = [];
  for (var i = 0; i < waiting.length; i++) {
    var kind = waiting[i][0], first = waiting[i][1], second = waiting[i][2];
    if (kind === 0) {
      pictured(first);
    } else if (kind === 1) {
      filed(first);
    } else if (kind === 2) {
      grounded(first);
    } else {
      sign(first, second);
    }
  }
}

function assetOf(path) {
  return "/_hive/asset/" + path.split("/").map(encodeURIComponent).join("/");
}

function handed(name, bytes, give) {
  var word = worded(name);
  give(word, bytes ? lent(bytes) : 0, bytes ? bytes.length : 0);
  engine._free(word);
  dirty = true;
}

` +
	// A picture goes over as straight pixels, rows from the top. One that is not
	// there is said to be missing, so the engine stops waiting for it.
	`function pictured(path) {
  fetch(assetOf(path))
    .then(function (r) { if (!r.ok) { throw new Error(r.status); } return r.blob(); })
    .then(function (blob) {
      return createImageBitmap(blob, {premultiplyAlpha: "none", colorSpaceConversion: "none"});
    })
    .then(function (shot) {
      var flat = document.createElement("canvas");
      flat.width = shot.width;
      flat.height = shot.height;
      var ctx = flat.getContext("2d", {willReadFrequently: true});
      ctx.drawImage(shot, 0, 0);
      return ctx.getImageData(0, 0, flat.width, flat.height);
    })
    .then(function (shot) {
      handed(path, shot.data, function (word, at) { engine._hs_picture(word, shot.width, shot.height, at); });
    }, function () {
      handed(path, null, function (word) { engine._hs_picture(word, 0, 0, 0); });
    });
}

function filed(path) {
  fetch(assetOf(path))
    .then(function (r) { if (!r.ok) { throw new Error(r.status); } return r.arrayBuffer(); })
    .then(function (buf) {
      handed(path, new Uint8Array(buf), function (word, at, size) { engine._hs_file(word, at, size, 1); });
    }, function () {
      handed(path, null, function (word) { engine._hs_file(word, 0, 0, 0); });
    });
}

function grounded(id) {
  fetch("/_hive/terrain/" + id)
    .then(function (r) { if (!r.ok) { throw new Error(r.status); } return r.arrayBuffer(); })
    .then(function (buf) {
      handed(id, new Uint8Array(buf), function (word, at, size) { engine._hs_terrain(word, at, size); });
    }, function () {});
}

` +
	// A label is words drawn once onto a canvas, in the page's own typeface, and
	// kept by the engine from then on.
	`function sign(text, colour) {
  var pad = 16, size = 52;
  var face = "bold " + size + "px system-ui, -apple-system, Segoe UI, sans-serif";
  var plate = document.createElement("canvas");
  var ctx = plate.getContext("2d");
  ctx.font = face;
  plate.width = Math.ceil(ctx.measureText(text).width) + pad * 2;
  plate.height = size + pad * 2;

` +
	// Sizing the canvas resets everything about the context, so the font goes on
	// again after it.
	`  ctx = plate.getContext("2d", {willReadFrequently: true});
  ctx.font = face;
  ctx.fillStyle = "rgba(10,12,16,0.5)";
  ctx.fillRect(0, 0, plate.width, plate.height);
  ctx.fillStyle = colour;
  ctx.textBaseline = "middle";
  ctx.fillText(text, pad, plate.height / 2 + 2);
  var px = ctx.getImageData(0, 0, plate.width, plate.height).data;
  var word = worded(text), tint = worded(colour);
  engine._hs_label(word, tint, plate.width, plate.height, lent(px));
  engine._free(word);
  engine._free(tint);
  dirty = true;
}

` +
	// --- the box the picture goes in -------------------------------------------
	//
	// Called after every document swap: the element is a new one each time, so what
	// is found again here is where the canvas has to be laid over.
	`function attach() {
  boxed();
  var el = document.querySelector(".h-scene[data-scene]");
  if (!el) {
    host = null;
    handle = "";
    holder.style.display = "none";
    release();
    silence();
    return;
  }
  host = el;
  handle = el.getAttribute("data-h") || "";

` +
	// A new element every time the page changes shape, so the observer moves
	// onto this one.
	`  watchBox(el);
  holder.style.display = "block";
  follow(true);
}

` +
	// Notice the box moving, rather than asking after it sixty times a second.
	// Reading a rectangle forces a layout, and from an animation frame it forces
	// the whole document's — on a racing HUD, three per cent of the window spent
	// discovering the box had moved four times in eleven hundred frames.
	//
	// So it is read when a resize, a window resize or a scroll anywhere says it
	// might have changed, and once in every thirty frames regardless: none of
	// those catches a sibling growing taller above a box of fixed height, and
	// half a second of drift is cheaper than a layout in every frame.
	`function watchBox(el) {
  if (!boxWatched) {
    boxWatched = true;
    var moved = function () { boxMoved = true; };
    if (window.ResizeObserver) { boxWatch = new ResizeObserver(moved); }
    window.addEventListener("resize", moved);

` +
	// Captured, because a box can sit inside a panel that scrolls, and a
	// scroll there never reaches the window.
	`    window.addEventListener("scroll", moved, true);
  }
  if (boxWatch) {
    boxWatch.disconnect();
    boxWatch.observe(el);
  }
  boxMoved = true;
}

function follow(force) {
  if (!host || !engine) { return; }
  var mark = host.classList.contains("h-aiming") ? "h-world h-aiming" : "h-world";
  if (holder.className !== mark) { holder.className = mark; }

` +
	// That class is free to read. The rectangle below costs a layout — see
	// watchBox for when it is worth one.
	`boxBeat++;
if (!force && !boxMoved && boxBeat % 30 !== 0) { return; }
boxMoved = false;
var r = host.getBoundingClientRect();
var w = Math.max(1, Math.round(r.width)), h = Math.max(1, Math.round(r.height));

` +
	// Said before the rectangle is held against the last one, because a scene
	// whose payload arrived after the box had settled would otherwise never be
	// told a size it is listening for.
	`  if (want.indexOf("s") >= 0 && (w !== sizeSaid[0] || h !== sizeSaid[1])) {
    if (post("size", w + "," + h, 0)) { sizeSaid = [w, h]; }
  }
  if (!force && r.left === seen.left && r.top === seen.top && w === seen.width && h === seen.height) {
    return;
  }
  seen = {left: r.left, top: r.top, width: w, height: h};
  holder.style.left = r.left + "px";
  holder.style.top = r.top + "px";
  holder.style.width = w + "px";
  holder.style.height = h + "px";
  canvas.width = w;
  canvas.height = h;
  engine._hs_sized(w, h, w, h);
  insetsSaid = "";
  dirty = true;
}

` +
	// Every inset in the document, filed under the index its element carries. Found
	// again after each swap for the reason the scene box is: the elements are new
	// every time, and one holding a reference to the old would be drawn where it
	// used to be.
	`function boxed() {
  boxes = [];
  var found = document.querySelectorAll(".h-inset[data-inset]");
  for (var i = 0; i < found.length; i++) {
    boxes[+found[i].getAttribute("data-inset")] = found[i];
  }
}

` +
	// An inset is a box on the page and a camera: the engine draws it into the
	// scene's own canvas, where its box landed, so it has to be over the picture.
	// Told only when a box moved.
	`function insets() {
  var flat = [];
  for (var i = 0; i < boxes.length; i++) {
    var box = boxes[i];
    if (!box) {
      flat.push(0, 0, 0, 0);
      continue;
    }
    var r = box.getBoundingClientRect();
    var left = Math.max(0, Math.round(r.left - seen.left));
    var top = Math.max(0, Math.round(r.top - seen.top));
    var right = Math.min(seen.width, Math.round(r.right - seen.left));
    var low = Math.min(seen.height, Math.round(r.bottom - seen.top));
    flat.push(left, top, Math.max(0, right - left), Math.max(0, low - top));
  }
  var said = flat.join(",");
  if (said === insetsSaid) { return; }
  insetsSaid = said;
  engine._hs_insets(lent(new Uint8Array(new Int32Array(flat).buffer)), boxes.length);
}

` +
	// --- the clock -------------------------------------------------------------
	//
	// The browser's own frame, which is the only clock worth stepping a picture by:
	// it is the refresh rate, it stops while the window is hidden, and it never runs
	// twice for one paint.
	//
	// A page that has lost the thread of the world asks for the whole of it, and
	// goes on asking until the ask gets out.
	//
	// Before the frame is reported rather than after, so the fold hears the stick
	// move and *then* is told to step the world by it.
	//
	// And the frame before the picture rather than after it. See reported.
	`function tick(now) {
  requestAnimationFrame(tick);
  paced(now);
  if (!engine || !host) { last = now; return; }
  follow(false);
  if (needFull && post("resync", "", 0)) { needFull = false; }
  if (lookX || lookY) {
    if (want.indexOf("l") >= 0) { post("look", round(lookX) + "," + round(lookY), 0); }
    lookX = 0;
    lookY = 0;
  }
  if (want.indexOf("p") >= 0) { pads(); touches(); }
  reported(now);
  if (pendingScenes.length) { flushScene(); }
  answer();
  if (dirty || engine._hs_stale()) {
    insets();
    engine._hs_draw();
    dirty = false;
  }
}
requestAnimationFrame(tick);

` +
	// Tell the program a frame went by, so that it folds the next world.
	//
	// Said before this frame is drawn rather than after it: the fold is the
	// program's work and the picture is this window's, and there is no reason they
	// should take turns. Reported after the render they are strictly serial, and
	// the answer arrives at a thread already busy with the next picture — seven
	// milliseconds round trip for a fold that takes one and a half. What is drawn
	// is unaffected; a frame always draws the world the last fold sent.
	//
	// A gap longer than a tenth of a second is reported as that: the window was
	// busy or hidden, and a world stepped by the real gap would teleport.
	//
	// It is told when the program is ready to hear it, not sixty times a second
	// regardless. While an answer is outstanding this does nothing — and crucially
	// leaves last alone, so the gap goes on growing and the frame that eventually
	// goes carries the whole of the time that passed. That is the difference
	// between reporting sixty frames of seventeen milliseconds to a program
	// managing twenty, and reporting the twenty frames of fifty that happened.
	//
	// The first frame starts the clock and reports nothing, no time having passed
	// between two frames yet. Seeding last above the guard instead, so a skipped
	// frame did not keep its time, left every gap measuring nought and every frame
	// skipped for being nought long.
	`function reported(now) {
  var ms = last ? Math.round(now - last) : 0;
  if (want.indexOf("f") < 0) { last = now; return; }
  if (!last) { last = now; return; }
  if (ms <= 0 || hiveOwed) { return; }
  last = now;
  hiveOwed = true;
  if (!post("frame", "", Math.min(100, ms))) { hiveOwed = false; }
}

` +
	// --- what the screen can do -------------------------------------------------
	//
	// The display's refresh rate, not what this program is achieving: a program
	// that measured what it was managing and aimed at that would settle at whatever
	// it was already doing and call it a success.
	//
	// So, the tenth percentile of the last few seconds of gaps between animation
	// frames. A window painting forty a second on a screen refreshing a hundred and
	// twenty still sees plenty of eight-millisecond gaps, and it is those that say
	// what the screen can do; the slow ones say only that this program was busy.
	// Told once a second and only when the answer changed.
	`var gaps = new Float64Array(240), gapAt = 0, gapsIn = 0;
var beatLast = 0, rateSaid = 0, rateAsked = 0;

function paced(now) {
  if (beatLast) {
    var ms = now - beatLast;

` +
	// A gap outside these is the window having been hidden or throttled, and
	// says nothing about the screen.
	`    if (ms > 0.5 && ms < 200) {
      gaps[gapAt] = ms;
      gapAt = (gapAt + 1) % gaps.length;
      if (gapsIn < gaps.length) { gapsIn++; }
    }
  }
  beatLast = now;
  if (want.indexOf("r") < 0 || gapsIn < 30 || now - rateAsked < 1000) { return; }
  rateAsked = now;
  var sorted = Array.prototype.slice.call(gaps.subarray(0, gapsIn));
  sorted.sort(function (a, b) { return a - b; });
  var hz = Math.round(1000 / sorted[Math.floor(gapsIn / 10)]);
  hz = Math.max(20, Math.min(480, hz));
  if (hz !== rateSaid && post("rate", "", hz)) { rateSaid = hz; }
}

function round(n) { return Math.round(n * 100) / 100; }

` +
	// Nothing is sent while the socket is behind. A frame the program has not
	// folded yet is not made fresher by queueing another after it.
	//
	// It says whether it went, and one caller cares: a pad keeps a record of what
	// it has told the program, and a message that was dropped was never told.
	`function post(kind, value, index) {
  if (!handle || sock.readyState !== 1 || sock.bufferedAmount > 65536) { return false; }
  send(handle, kind, value, index);
  return true;
}

` +
	// --- what a world sounds like ----------------------------------------------
	//
	// A sound is a shape you cannot see: listed in the scene beside the solids and
	// standing at a place in the world as they do. The difference is what happens
	// between two frames — a solid is redrawn, a sound is carried on, which is why
	// a sound carries a name and every map below is keyed by one.
	//
	// Nothing is downloaded. Every voice is oscillators and filtered noise, for the
	// same reason the grain patterns are drawn rather than fetched: a built Hive
	// program is one file. It buys something too — a voice made of a frequency can
	// be bent, where an engine that is a recording played faster can be heard
	// looping.
	//
	// A sound naming a track is no exception: the recording was embedded at compile
	// time and comes off this window's own server. Where it is missing the
	// oscillators answer instead, so a track is always something a scene gains and
	// never something it depends on.
	`var ears = null, master = null, hiss = null, voices = new Map();

` +
	// The recordings, by the path a scene named them with. One entry per track: a
	// name asked for while it is still decoding gets the promise the first ask
	// made, so ten cars naming one crowd fetch it once.
	//
	// A track that fails resolves to null rather than rejecting, and null is a
	// voice that falls back to its oscillators.
	`var recordings = new Map();

function recorded(name) {
  var held = recordings.get(name);
  if (held) { return held; }
  var asked = fetch("/_hive/asset/" + name.split("/").map(encodeURIComponent).join("/"))
    .then(function (r) { return r.ok ? r.arrayBuffer() : null; })
    .then(function (bytes) {
      if (!bytes) { return null; }
      return ears.decodeAudioData(bytes);
    })
    .catch(function () { return null; });
  recordings.set(name, asked);
  return asked;
}

` +
	// The context, built the first time a scene asks for a noise.
	//
	// A browser will not let a page make one until somebody has touched it, and
	// says so by handing back a suspended context rather than by failing. So there
	// is nothing to detect: build it, nudge it on every gesture until one takes.
	`function hearing() {
  if (ears) { return ears; }
  var Sound = window.AudioContext || window.webkitAudioContext;
  if (!Sound) { return null; }
  ears = new Sound();
  master = ears.createGain();
  master.gain.value = 0.8;
  master.connect(ears.destination);

` +
	// Two seconds of white noise, made once and shared by everything with a hiss
	// in it — tyres, brakes, wind, crowd, impact. All five are this one buffer
	// through a different filter.
	`  var run = Math.floor(ears.sampleRate * 2);
  hiss = ears.createBuffer(1, run, ears.sampleRate);
  var grains = hiss.getChannelData(0);
  for (var i = 0; i < run; i++) { grains[i] = Math.random() * 2 - 1; }
  wake();
  return ears;
}

function wake() {
  if (ears && ears.state === "suspended") { ears.resume(); }
}

function noise() {
  var src = ears.createBufferSource();
  src.buffer = hiss;
  src.loop = true;
  src.start();
  return src;
}

` +
	// Where a voice stands. A panner rather than a stereo balance, because what is
	// being modelled is a car going past: the distance falling away and the sound
	// crossing from one ear to the other, and only a panner does both.
	`function sited(gain) {
  var pan = ears.createPanner();
  pan.panningModel = "equalpower";
  pan.distanceModel = "inverse";
  pan.refDistance = 7;
  pan.maxDistance = 400;
  pan.rolloffFactor = 1.2;
  gain.connect(pan);
  pan.connect(master);
  return pan;
}

` +
	// A panner moved. The named parameters are the current spelling and the two
	// setters are the old one; a browser has one or the other, and both mean this.
	`function standing(pan, p) {
  if (!pan || !p) { return; }
  if (pan.positionX) {
    pan.positionX.value = p[0];
    pan.positionY.value = p[1];
    pan.positionZ.value = p[2];
  } else if (pan.setPosition) {
    pan.setPosition(p[0], p[1], p[2]);
  }
}

` +
	// One sustained voice, built to its name and silent until it is told how loud.
	//
	// Every one is the same three pieces — a source, a filter, and the gain the
	// whole thing hangs on — and what makes an engine an engine rather than a crowd
	// is which source through which filter. A voice with nothing to bend has none.
	//
	// Music is the one voice with nowhere to stand. It is not in the world, it
	// is over it, so it goes straight to the master and is never panned.
	//
	// A recording answers for the voice instead of the oscillators. Everything
	// downstream is the same graph — the same gain, panner and fade — so a track
	// is a different source and not a different kind of sound.
	//
	// Two oscillators an octave apart with the top taken off. The saw is the
	// firing and the square under it is the part you feel rather than hear —
	// one alone is a wasp, which is what every synthesised engine that stopped
	// at a single oscillator sounds like.
	//
	// The filter opens with the revs, which is the whole of why a car on the
	// throttle sounds harder than the same car coasting at the same speed.
	//
	// A squeal is a narrow band with a tone sitting in the middle of it, and
	// the tone is what makes it a brake rather than a hiss.
	//
	// Filtered noise is a crowd already; what it is missing is that a crowd
	// *breathes*. The slow swell under it is one oscillator on the filter, and
	// it is the difference between a grandstand and a waterfall.
	`function sustained(kind, track) {
  var gain = ears.createGain();
  gain.gain.value = 0;
  var voice = {kind: kind, gain: gain, pan: null, parts: [], bend: null,
    track: track || "", pitch: 1, gone: false};
  if (kind === "Music") { gain.connect(master); }
  else { voice.pan = sited(gain); }
  if (voice.track) {
    played(voice);
    return voice;
  }
  if (kind === "Engine") {
    var low = ears.createBiquadFilter();
    low.type = "lowpass";
    low.Q.value = 3.5;
    low.connect(gain);
    var saw = ears.createOscillator(), body = ears.createOscillator();
    saw.type = "sawtooth";
    body.type = "square";
    body.detune.value = -1200;
    saw.connect(low);
    body.connect(low);
    saw.start();
    body.start();
    voice.parts = [saw, body];
    voice.bend = function (p) {
      var revs = Math.max(18, 54 * p);
      saw.frequency.setTargetAtTime(revs, ears.currentTime, 0.04);
      body.frequency.setTargetAtTime(revs, ears.currentTime, 0.04);
      low.frequency.setTargetAtTime(340 + revs * 11, ears.currentTime, 0.06);
    };
  } else if (kind === "Tyres") {
    var scrub = ears.createBiquadFilter();
    scrub.type = "bandpass";
    scrub.Q.value = 1.1;
    scrub.connect(gain);
    var rough = noise();
    rough.connect(scrub);
    voice.parts = [rough];
    voice.bend = function (p) {
      scrub.frequency.setTargetAtTime(Math.max(120, 780 * p), ears.currentTime, 0.05);
    };
  } else if (kind === "Brakes") {
    var narrow = ears.createBiquadFilter();
    narrow.type = "bandpass";
    narrow.Q.value = 9;
    narrow.connect(gain);
    var grit = noise();
    grit.connect(narrow);
    var squeal = ears.createOscillator();
    squeal.type = "triangle";
    var cry = ears.createGain();
    cry.gain.value = 0.16;
    squeal.connect(cry);
    cry.connect(gain);
    squeal.start();
    voice.parts = [grit, squeal];
    voice.bend = function (p) {
      narrow.frequency.setTargetAtTime(Math.max(400, 2400 * p), ears.currentTime, 0.03);
      squeal.frequency.setTargetAtTime(Math.max(300, 1750 * p), ears.currentTime, 0.03);
    };
  } else if (kind === "Wind") {
    var rush = ears.createBiquadFilter();
    rush.type = "bandpass";
    rush.Q.value = 0.4;
    rush.connect(gain);
    var air = noise();
    air.connect(rush);
    voice.parts = [air];
    voice.bend = function (p) {
      rush.frequency.setTargetAtTime(Math.max(90, 320 * p), ears.currentTime, 0.1);
    };
  } else if (kind === "Crowd") {
    var murmur = ears.createBiquadFilter();
    murmur.type = "bandpass";
    murmur.Q.value = 0.8;
    murmur.frequency.value = 620;
    murmur.connect(gain);
    var many = noise();
    many.connect(murmur);
    var swell = ears.createOscillator();
    swell.type = "sine";
    swell.frequency.value = 0.13;
    var depth = ears.createGain();
    depth.gain.value = 260;
    swell.connect(depth);
    depth.connect(murmur.frequency);
    swell.start();
    voice.parts = [many, swell];

` +
	// A crowd reacting to something is a brighter noise than one talking among
	// itself, which is entirely in where the band sits. This voice took no
	// pitch at all before, so the one attribute a sound has for saying how
	// excited it is was the one it ignored. The swell adds to the same
	// parameter, so a crowd asking for 1.0 is the crowd it always was.
	`    voice.bend = function (p) {
      murmur.frequency.setTargetAtTime(
        Math.max(180, 620 * p), ears.currentTime, 0.25);
    };
  } else if (kind === "Music") {
    voice.at = ears.currentTime;
    voice.step = 0;
  }
  return voice;
}

` +
	// A voice's recording, started as soon as there is one to start.
	//
	// It is asynchronous and the rest of this file is not, which is what the guard
	// below is for: a fetch that began sixty frames ago comes back to a voice whose
	// name may have left the scene, or come back naming something else.
	//
	// The loop is the whole buffer — where a bed should stop is a question the
	// scene answers by not naming it any more.
	`function played(voice) {
  var want = voice.track;
  recorded(want).then(function (buffer) {
    if (!buffer || voice.gone || voice.track !== want) { return; }
    var src = ears.createBufferSource();
    src.buffer = buffer;
    src.loop = true;
    src.connect(voice.gain);
    src.start();
    voice.parts = [src];

` +
	// Pitch on a recording is the speed it is played at, which is the only
	// thing it can be — and is why a bed asks for 1.0 and means it.
	`    voice.bend = function (p) {
      src.playbackRate.setTargetAtTime(Math.max(0.06, p), ears.currentTime, 0.08);
    };
    voice.bend(voice.pitch);
  });
}

` +
	// The bed. Four bars, a bass note under each and a figure over the top,
	// scheduled a little ahead of the clock rather than when a frame comes round —
	// a sequencer hung off the render loop would be in time with the frame rate,
	// and a frame rate is not a tempo.
	//
	// It is not much of a tune and is not meant to be: something you stop hearing
	// by the second lap is exactly what a bed is for.
	`var TUNE = [
  [-12, 0, 3, 7],
  [-10, 2, 5, 9],
  [-15, -3, 0, 4],
  [-8, 0, 4, 7]
];

function note(step) { return 55 * Math.pow(2, step / 12); }

function music(voice, now) {

` +
	// Half a second of runway. Less, and a busy frame arrives too late to
	// schedule the next note; more, and a change of volume takes a bar to tell.
	`  while (voice.at < now + 0.5) {
    var beat = voice.step % 8, bar = Math.floor(voice.step / 8) % TUNE.length;
    var chord = TUNE[bar];
    if (beat === 0 || beat === 5) {
      pluck(voice, note(chord[0]), voice.at, 0.5, "triangle", 0.5);
    }
    pluck(voice, note(chord[1 + (voice.step % 3)] + 12), voice.at, 0.22, "square", 0.1);
    voice.at = voice.at + 0.19;
    voice.step = voice.step + 1;
  }
}

` +
	// One note: an oscillator with an envelope on it, started and stopped in the
	// future and then let go of. Nothing keeps a reference — a note that has
	// finished sounding is a note nobody can do anything to.
	`function pluck(voice, freq, at, run, shape, loud) {
  var osc = ears.createOscillator();
  osc.type = shape;
  osc.frequency.value = freq;
  var env = ears.createGain();
  env.gain.setValueAtTime(0.0001, at);
  env.gain.exponentialRampToValueAtTime(loud, at + 0.012);
  env.gain.exponentialRampToValueAtTime(0.0001, at + run);
  osc.connect(env);
  env.connect(voice.gain);
  osc.start(at);
  osc.stop(at + run + 0.02);
}

` +
	// The two voices that fire rather than last. Both are built, started and
	// forgotten in one call: there is nothing to carry forward, because the thing
	// they stand for has already happened.
	//
	// A struck recording is the same bargain the struck oscillators make: it
	// fires once and there is nothing left to hold. The difference is that the
	// bytes may not be here yet, so one still decoding when it was struck is
	// simply not heard — which is what a sound that has already happened is.
	`var STRUCK = {Impact: true, Chime: true, Talk: true};

` +
	// **A struck voice is positioned once and never again**, because a struck
	// voice is a thing that happened rather than a thing that is happening: there
	// is nothing left to move. That is right for an impact, which happened at a
	// place, and wrong for `Talk`, which did not happen anywhere. Panned, a line
	// of commentary is pinned to whatever spot the camera stood on when it began
	// and the car then drives away from it — quieter every metre, and off to one
	// side. So this one connects straight to the master, exactly as `Music` does
	// in `sustained` and for the same reason.
	`function strike(kind, s) {
  var gain = ears.createGain();
  if (kind === "Talk") { gain.connect(master); }
  else { standing(sited(gain), s.p); }
  var now = ears.currentTime;
  var loud = Math.max(0.0001, s.g === undefined ? 1 : s.g);
  var pitch = s.h === undefined ? 1 : s.h;
  if (s.t) {
    recorded(s.t).then(function (buffer) {
      if (!buffer) { return; }
      var one = ears.createBufferSource();
      one.buffer = buffer;
      one.playbackRate.value = Math.max(0.06, pitch);
      one.connect(gain);
      gain.gain.value = loud;
      one.start();
    });
    return;
  }
  if (kind === "Chime") {
    var ring = ears.createOscillator();
    ring.type = "sine";
    ring.frequency.value = Math.max(80, 660 * pitch);
    ring.connect(gain);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(loud, now + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.55);
    ring.start(now);
    ring.stop(now + 0.6);
    return;
  }

` +
	// An impact is two things at once and has to be: the noise of it, broadband
	// and dead in a third of a second, and the weight of it, one low tone sliding
	// down. The noise alone is a hiss and the tone alone is a drum.
	`  var burst = ears.createBufferSource();
  burst.buffer = hiss;
  var dull = ears.createBiquadFilter();
  dull.type = "lowpass";
  dull.frequency.setValueAtTime(Math.max(400, 3200 * pitch), now);
  dull.frequency.exponentialRampToValueAtTime(200, now + 0.3);
  burst.connect(dull);
  dull.connect(gain);
  var thud = ears.createOscillator();
  thud.type = "sine";
  thud.frequency.setValueAtTime(Math.max(50, 150 * pitch), now);
  thud.frequency.exponentialRampToValueAtTime(45, now + 0.22);
  var weight = ears.createGain();
  weight.gain.value = 0.7;
  thud.connect(weight);
  weight.connect(gain);
  gain.gain.setValueAtTime(loud, now);
  gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.38);
  burst.start(now);
  burst.stop(now + 0.4);
  thud.start(now);
  thud.stop(now + 0.4);
}

` +
	// A voice whose name has left the scene. It is faded rather than cut, because
	// a gain taken to nought in one sample is a click — the same click that
	// restarting an oscillator every frame would make, arriving at the other end.
	`function hush(name) {
  var voice = voices.get(name);
  voices.delete(name);
  if (!voice || voice.struck) { return; }

` +
	// Said before the fade rather than after it, and it is not a formality: a
	// recording still being decoded comes back to this voice, and this is the
	// only thing between it and a source started into a gain already falling.
	`  voice.gone = true;
  var now = ears.currentTime;
  voice.gain.gain.setTargetAtTime(0, now, 0.05);
  for (var i = 0; i < voice.parts.length; i++) {
    try { voice.parts[i].stop(now + 0.3); } catch (e) {}
  }
}

function silence() {
  if (!ears) { return; }
  var going = [];
  voices.forEach(function (voice, name) { going.push(name); });
  for (var i = 0; i < going.length; i++) { hush(going[i]); }
}

` +
	// Every sound in the frame, against every voice already going. Three cases: a
	// new name starts a voice, a name still here bends the one it has, and a voice
	// whose name has gone fades out.
	//
	// A name that has come back as a different voice is a different sound
	// wearing the same label, and the old one goes before the new one starts.
	// A different recording under the same name is the same thing said another
	// way, and is how a scene changes the bed between races.
	//
	// Kept as well as applied, because a recording still decoding has nothing
	// to bend yet and will want to know what it missed.
	`function sounds(list, w) {
  if (!hearing()) { return; }
  attend(w);
  var now = ears.currentTime, here = {};
  for (var i = 0; i < list.length; i++) {
    var s = list[i], name = s.x || "", kind = s.v || "Engine", track = s.t || "";
    here[name] = true;
    var voice = voices.get(name);
    if (voice && (voice.kind !== kind || voice.track !== track)) {
      hush(name);
      voice = null;
    }
    if (!voice) {
      if (STRUCK[kind]) {
        strike(kind, s);
        voices.set(name, {kind: kind, struck: true, parts: [], track: track});
        continue;
      }
      voice = sustained(kind, track);
      voices.set(name, voice);
    }
    if (voice.struck) { continue; }
    standing(voice.pan, s.p);
    voice.gain.gain.setTargetAtTime(Math.max(0, s.g === undefined ? 1 : s.g), now, 0.06);
    voice.pitch = s.h === undefined ? 1 : s.h;
    if (voice.bend) { voice.bend(voice.pitch); }

` +
	// A bed that is a recording plays itself. The sequencer is what a scene
	// gets when it asks for music and has none of its own.
	`    if (voice.kind === "Music" && !voice.track) { music(voice, now); }
  }
  var going = [];
  voices.forEach(function (voice, name) { if (!here[name]) { going.push(name); } });
  for (var g = 0; g < going.length; g++) { hush(going[g]); }
}

` +
	// The ears, put where the camera is and pointed where it is pointing. The
	// forward vector is the camera's own -Z through the same yaw-then-pitch the
	// renderer applies, so what is heard on the left is what is drawn on the left.
	`function attend(w) {
  var ear = ears.listener, p = w.eye, yaw = w.aim[0], tip = w.aim[1];
  var fx = -Math.sin(yaw) * Math.cos(tip);
  var fy = Math.sin(tip);
  var fz = -Math.cos(yaw) * Math.cos(tip);
  if (ear.positionX) {
    ear.positionX.value = p[0];
    ear.positionY.value = p[1];
    ear.positionZ.value = p[2];
    ear.forwardX.value = fx;
    ear.forwardY.value = fy;
    ear.forwardZ.value = fz;
    ear.upX.value = 0;
    ear.upY.value = 1;
    ear.upZ.value = 0;
  } else if (ear.setPosition) {
    ear.setPosition(p[0], p[1], p[2]);
    ear.setOrientation(fx, fy, fz, 0, 1, 0);
  }
}

` +
	// --- what the player did ---------------------------------------------------
	//
	// A browser will not let a page make a noise until somebody has touched it,
	// so every gesture nudges the audio context. Watched for here, with the rest
	// of the input, because that is what it is: the one event a program never
	// hears about.
	//
	// Taking the mouse is watched for on the whole document rather than on the
	// canvas, and that is not laziness. A browser only grants the pointer on a
	// click, and a panel drawn over the picture — "click to play", put up because
	// the program does not have the mouse yet — would swallow the very click
	// meant to take it. It cannot be done by folding the click through the
	// program either: by then the browser no longer counts it as a gesture.
	//
	// The click that takes hold of the mouse is not also a shot.
	//
	// Escape gives the mouse back, and anything still held down at that moment
	// is not held any more.
	//
	// Held is held: the operating system's repeat is not a second press.
	`function listen() {
  document.addEventListener("mousedown", wake, true);
  document.addEventListener("keydown", wake, true);
  document.addEventListener("touchstart", wake, true);
  document.addEventListener("mousedown", function (e) {
    if (world && world.grab && !grabbing) {
      if (interactive(e.target)) { return; }
      canvas.requestPointerLock();
      e.preventDefault();
      return;
    }
    if (grabbing || holder.contains(e.target)) { down("mouse" + (e.button + 1)); }
  });
  document.addEventListener("mouseup", function (e) {
    if (grabbing || holder.contains(e.target)) { up("mouse" + (e.button + 1)); }
  });
  holder.addEventListener("contextmenu", function (e) { if (grabbing) { e.preventDefault(); } });
  document.addEventListener("pointerlockchange", function () {
    grabbing = document.pointerLockElement === canvas;
    if (!grabbing) { release(); }
    if (want.indexOf("g") >= 0) { post("grab", grabbing ? "1" : "", 0); }
  });
  document.addEventListener("mousemove", function (e) {
    if (!grabbing) { return; }
    lookX += e.movementX || 0;
    lookY += e.movementY || 0;
  });
  window.addEventListener("keydown", function (e) {
    if (typing(e)) { return; }
    var k = named(e);
    if (!k) { return; }
    if (grabbing && swallow(k)) { e.preventDefault(); }
    if (e.repeat) { return; }
    down(k);
  });
  window.addEventListener("keyup", function (e) {
    var k = named(e);
    if (k) { up(k); }
  });

` +
	// A key held as the window loses focus would otherwise still be held when it
	// comes back — a player who alt-tabbed mid-stride and returned to find
	// themselves still running.
	`  window.addEventListener("blur", release);
  document.addEventListener("pointerdown", pressed, true);
  document.addEventListener("pointermove", dragged, true);
  document.addEventListener("pointerup", lifted, true);
  document.addEventListener("pointercancel", lifted, true);
}

` +
	// Whether a click landed on something the program is listening to. Those keep
	// their click; everything else is fair game for taking the mouse. The scene is
	// excluded: clicking the picture is the most obvious way to ask for the mouse.
	`function interactive(el) {
  while (el && el !== document.body) {
    if (el.classList && el.classList.contains("h-scene")) { return false; }
    if (el.getAttribute && el.getAttribute("data-h")) { return true; }
    var tag = el.tagName;
    if (tag === "BUTTON" || tag === "A" || tag === "INPUT" || tag === "TEXTAREA" ||
        tag === "SELECT" || tag === "LABEL") {
      return true;
    }
    el = el.parentNode;
  }
  return false;
}

` +
	// Typing is typing. A window with a text field in it must not read the field as
	// movement, and this is the whole rule that keeps the two apart. A slider only
	// types with the keys that move it; everything else, Escape above all, is still
	// the program's. A release is never typing: a key held into a field has to let go.
	`function typing(e) {
  var el = document.activeElement;
  if (!el || el === document.body) { return false; }
  var tag = el.tagName;
  if (tag === "INPUT" && el.type === "range") {
    var k = e.key || "";
    return k.indexOf("Arrow") === 0 || k.indexOf("Page") === 0 || k === "Home" || k === "End";
  }
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable;
}

` +
	// The keys the page would otherwise act on itself while the mouse is held: space
	// and the arrows scroll, and tab walks out of the window.
	//
	// --- the pads ----------------------------------------------------------------
	`function swallow(k) {
  return k === "space" || k === "tab" || k === "up" || k === "down" ||
    k === "left" || k === "right";
}

function down(k) {
  if (held[k]) { return; }
  held[k] = true;
  if (want.indexOf("k") >= 0) { post("keydown", k, 0); }
}

function up(k) {
  if (!held[k]) { return; }
  delete held[k];
  if (want.indexOf("u") >= 0) { post("keyup", k, 0); }
}

function release() {
  for (var k in held) {
    if (want.indexOf("u") >= 0) { post("keyup", k, 0); }
  }
  held = {};
  fingers = {};
}

var fingers = {}, touchNames = {}, touchTold = {};

function pressed(e) {
  var el = e.target && e.target.closest ? e.target.closest("[data-touch]") : null;
  if (!el) { return; }
  e.preventDefault();
  var name = el.getAttribute("data-touch");
  touchNames[name] = true;
  fingers[e.pointerId] = { name: name, box: el.getBoundingClientRect(), x: 0, y: 0 };
  dragged(e);
}

function dragged(e) {
  var f = fingers[e.pointerId];
  if (!f) { return; }
  var x = (e.clientX - f.box.left - f.box.width / 2) / Math.max(1, f.box.width / 2);
  var y = (e.clientY - f.box.top - f.box.height / 2) / Math.max(1, f.box.height / 2);
  var far = Math.sqrt(x * x + y * y);
  if (far > 1) { x /= far; y /= far; }
  f.x = x;
  f.y = y;
}

function lifted(e) {
  delete fingers[e.pointerId];
}

function touches() {
  var now = {};
  for (var name in touchNames) { now[name] = 0; now[name + "X"] = 0; now[name + "Y"] = 0; }
  for (var id in fingers) {
    var f = fingers[id];
    if (now[f.name] === 1) { continue; }
    now[f.name] = 1;
    now[f.name + "X"] = f.x;
    now[f.name + "Y"] = f.y;
  }
  for (var control in now) {
    var told = touchTold[control] || 0;
    if (now[control] === told || (now[control] !== 0 && Math.abs(now[control] - told) < 0.02)) { continue; }
    if (post("pad", control + "|" + round(now[control]), -1)) { touchTold[control] = now[control]; }
  }
}

` +
	// A gamepad is the one input a browser will not tell you about. There is no
	// event for a stick moving, only a snapshot you have to ask for, so a pad is
	// read once a frame and what goes out is what changed since the last look. The
	// names are the standard mapping's, by position.
	//
	// Every pad is reported, not only those the browser calls "standard": it leaves
	// the mapping empty for any pad missing from its table, which on Linux is most
	// of them, while the ordering underneath is XInput in almost every case.
	//
	// One the browser could not name says so on the way in — "here" arrives as 2
	// rather than 1, a cue that the names are a good guess rather than a promise.
	// Past the end of the lists a control is reported by its number.
	`var PAD_BUTTONS = ["a", "b", "x", "y", "lb", "rb", "lt", "rt", "back", "start",
  "lstick", "rstick", "up", "down", "left", "right", "guide"];
var PAD_AXES = ["leftX", "leftY", "rightX", "rightY"];

` +
	// And the other layout there is. The XInput order is not the only order, and
	// assuming it was made a controller on Linux unusable rather than merely
	// mislabelled: a browser that cannot name a pad usually reports eleven buttons
	// and eight axes, with the triggers among the axes. Read as XInput, lt and rt
	// land on Back and Start, so pressing Start is full throttle.
	//
	// Not a guess between equals: six or more axes and no more than twelve buttons
	// puts the triggers on axes, because there is nowhere else for them to be.
	`var PAD_LOOSE_BUTTONS = ["a", "b", "x", "y", "lb", "rb", "back", "start",
  "guide", "lstick", "rstick"];
var PAD_LOOSE_AXES = ["leftX", "leftY", "lt", "rightX", "rightY", "rt",
  "dpadX", "dpadY"];
var padWas = [];

function loose(pad) {
  return pad.mapping !== "standard" && pad.axes.length >= 6
    && pad.buttons.length <= 12;
}

function buttonName(at, wide) {
  var names = wide ? PAD_LOOSE_BUTTONS : PAD_BUTTONS;
  return at < names.length ? names[at] : "b" + at;
}

function axisName(at, wide) {
  var names = wide ? PAD_LOOSE_AXES : PAD_AXES;
  return at < names.length ? names[at] : "axis" + at;
}

function pads() {
  var all = navigator.getGamepads ? navigator.getGamepads() : [];
  for (var i = 0; i < all.length; i++) {
    var pad = all[i];
    if (!pad || !pad.connected) {
      if (padWas[i]) { padLeft(i); }
      continue;
    }
    var wide = loose(pad);
    if (!padWas[i]) {
      padWas[i] = {};
      post("pad", pad.mapping === "standard" ? "here|1" : "here|2", i);
    }
    var b = 0;
    for (; b < pad.buttons.length; b++) {
      padMoved(i, buttonName(b, wide), pad.buttons[b].value);
    }
    var a = 0;
    for (; a < pad.axes.length; a++) {
      padAxis(i, axisName(a, wide), pad.axes[a]);
    }
  }
}

` +
	// One axis, reported as whatever it actually is. Three of them are not sticks:
	// a pedal reads -1 to 1 and means 0 to 1, and a dpad on an axis is two buttons
	// that happen to be sharing a number.
	`function padAxis(pad, control, at) {
  if (control === "lt" || control === "rt") {
    padMoved(pad, control, pedal(at));
    return;
  }
  if (control === "dpadX") {
    padMoved(pad, "left", at < -0.5 ? 1 : 0);
    padMoved(pad, "right", at > 0.5 ? 1 : 0);
    return;
  }
  if (control === "dpadY") {
    padMoved(pad, "up", at < -0.5 ? 1 : 0);
    padMoved(pad, "down", at > 0.5 ? 1 : 0);
    return;
  }
  padMoved(pad, control, deadzone(at));
}

` +
	// A pedal that arrived as an axis. It rests at -1 and reads 1 held down.
	//
	// Exactly nought is treated as untouched rather than held halfway: a driver
	// that has not seen the trigger move reports 0, and taking that at face value
	// is a car that pulls away on its own the moment the window opens.
	`function pedal(at) {
  if (at === 0) { return 0; }
  return Math.max(0, Math.min(1, (at + 1) / 2));
}

` +
	// A hundredth of travel is not a movement, it is a stick sitting still, and a
	// pad that reported that would post sixty messages a second saying nothing.
	`function padMoved(pad, control, now) {
  var was = padWas[pad];
  var before = was[control] || 0;
  if (Math.abs(now - before) < 0.02) { return; }

` +
	// Written down only once it has actually gone. What this record holds is what
	// the program has been told, and a message dropped because the socket was
	// behind was never told — writing it down anyway is a stick that moves once,
	// is not heard, and then never moves again.
	`  if (post("pad", control + "|" + round(now), pad)) { was[control] = now; }
}

` +
	// A stick at rest is never quite at rest. The dead zone is applied here rather
	// than left to the program because every program would apply the same one, and
	// nothing is thrown away past the first eight percent.
	`function deadzone(v) {
  if (v > -0.08 && v < 0.08) { return 0; }
  return v;
}

` +
	// A pad that is unplugged lets go of everything on the way out. Without this a
	// car whose controller ran flat mid-corner keeps turning.
	`function padLeft(pad) {
  var was = padWas[pad];
  for (var control in was) {
    if (was[control]) { post("pad", control + "|0", pad); }
  }
  padWas[pad] = null;
  post("pad", "here|0", pad);
}

` +
	// One name per key, and the same name on every keyboard layout the browser can
	// report: a letter or a digit is itself, and everything else is the word for it.
	`function named(e) {
  var k = e.key;
  if (!k) { return ""; }
  if (k === " " || k === "Spacebar") { return "space"; }
  if (k === "Control") { return "ctrl"; }
  if (k === "ArrowUp") { return "up"; }
  if (k === "ArrowDown") { return "down"; }
  if (k === "ArrowLeft") { return "left"; }
  if (k === "ArrowRight") { return "right"; }
  return k.toLowerCase();
}

summon({wanted: function (kind, first, second) { asks.push([kind, first, second]); }}).then(function (made) {
  var name = made.stringToNewUTF8("#h-world-canvas");
  var started = made._hs_start(name);
  made._free(name);
  if (!started) {
    console.error("hive: this window cannot draw a scene");
    return;
  }
  engine = made;
  listen();
  window.hiveSceneReady(paint, attach);
});
`
