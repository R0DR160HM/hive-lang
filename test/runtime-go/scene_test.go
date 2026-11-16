package hive

import (
	"encoding/binary"
	"fmt"
	"math"
	"testing"
)

// A frame read back by the rules the engine reads it by.
type uiFrameReader struct {
	b  []byte
	at int
}

func (r *uiFrameReader) u8() int { v := int(r.b[r.at]); r.at++; return v }
func (r *uiFrameReader) u16() int {
	v := int(binary.LittleEndian.Uint16(r.b[r.at:]))
	r.at += 2
	return v
}
func (r *uiFrameReader) u32() int {
	v := int(binary.LittleEndian.Uint32(r.b[r.at:]))
	r.at += 4
	return v
}
func (r *uiFrameReader) f32() float64 {
	v := float64(math.Float32frombits(binary.LittleEndian.Uint32(r.b[r.at:])))
	r.at += 4
	return v
}
func (r *uiFrameReader) word() string {
	n := r.u8()
	s := string(r.b[r.at : r.at+n])
	r.at += n
	return s
}
func (r *uiFrameReader) long() string {
	n := r.u16()
	s := string(r.b[r.at : r.at+n])
	r.at += n
	return s
}

type uiReadEye struct {
	eye, aim                                     [3]float64
	wants                                        string
	roll, ortho, near, far, ambientAt, sunlightAt float64
	ambient, sunlight, panorama                   string
}

func (r *uiFrameReader) eye() uiReadEye {
	var e uiReadEye
	for i := 0; i < 3; i++ {
		e.eye[i] = r.f32()
	}
	e.aim[0], e.aim[1] = r.f32(), r.f32()
	bits := r.u8()
	for _, b := range []int{uiSceneEyeLens, uiSceneEyeFog, uiSceneEyeGrain, uiSceneEyeBits} {
		if bits&b != 0 {
			r.u16()
		}
	}
	if bits&uiSceneEyeSky != 0 {
		r.word()
	}
	if bits&uiSceneEyeSun != 0 {
		r.f32()
		r.f32()
		r.u16()
	}
	e.wants = r.word()
	more := r.u8()
	e.near, e.far = 0.08, 800
	if more&1 != 0 {
		e.roll = r.f32()
	}
	if more&2 != 0 {
		e.ortho = r.f32()
	}
	if more&4 != 0 {
		e.near, e.far = r.f32(), r.f32()
	}
	if more&8 != 0 {
		e.ambient, e.ambientAt = r.word(), r.f32()
	}
	if more&16 != 0 {
		e.sunlight, e.sunlightAt = r.word(), r.f32()
	}
	if more&32 != 0 {
		e.panorama = r.word()
	}
	return e
}

type uiReadShape struct {
	kind, mask, more, flags int
	colour, surface, words  string
	at, turn, scale, size   []float64
	matrix                  []float64
	shine                   [3]float64
	pic, bump, clip         string
	tile                    [2]float64
	clipAt                  float64
	loop                    bool
}

func (r *uiFrameReader) shape() uiReadShape {
	s := uiReadShape{kind: r.u8(), mask: r.u8(), shine: [3]float64{-1, -1, 0}}
	s.colour = r.word()
	vec := func() []float64 { return []float64{r.f32(), r.f32(), r.f32()} }
	if s.mask&uiSceneHasAt != 0 {
		s.at = vec()
	}
	if s.mask&uiSceneHasTurn != 0 {
		s.turn = vec()
	}
	if s.mask&uiSceneHasScale != 0 {
		s.scale = vec()
	}
	if s.mask&uiSceneHasSize != 0 {
		n := r.u8()
		for i := 0; i < n; i++ {
			s.size = append(s.size, r.f32())
		}
	}
	if s.mask&uiSceneHasSurface != 0 {
		s.surface = r.word()
	}
	if s.mask&uiSceneHasWords != 0 {
		s.words = r.long()
	}
	if s.mask&uiSceneHasPaints != 0 {
		n := r.u8()
		for i := 0; i < n; i++ {
			r.word()
		}
	}
	if s.mask&uiSceneHasMore == 0 {
		return s
	}
	s.more = r.u16()
	if s.more&uiSceneMoreMatrix != 0 {
		for i := 0; i < 12; i++ {
			s.matrix = append(s.matrix, r.f32())
		}
	}
	if s.more&uiSceneMoreLook != 0 {
		s.shine[0], s.shine[1] = r.f32(), r.f32()
	}
	if s.more&uiSceneMoreGlow != 0 {
		s.shine[2] = r.f32()
	}
	if s.more&uiSceneMoreFlags != 0 {
		s.flags = r.u8()
	}
	if s.more&uiSceneMoreTexture != 0 {
		s.pic, s.bump = r.word(), r.word()
		s.tile = [2]float64{r.f32(), r.f32()}
	}
	if s.more&uiSceneMorePlay != 0 {
		s.clip, s.clipAt, s.loop = r.word(), r.f32(), r.u8() != 0
	}
	return s
}

func uiReadScene(t *testing.T, v UiView) (uiReadEye, []uiReadShape) {
	t.Helper()
	r := &uiFrameReader{b: []byte(v.Text)}
	e := r.eye()
	n := r.u32()
	var shapes []uiReadShape
	for i := 0; i < n; i++ {
		if r.at != int(v.Cuts[i]) {
			t.Fatalf("shape %d starts at %d, its cut says %d", i, r.at, v.Cuts[i])
		}
		shapes = append(shapes, r.shape())
	}
	if r.at != len(r.b) || r.at != int(v.Cuts[n]) {
		t.Fatalf("read %d of %d bytes", r.at, len(r.b))
	}
	return e, shapes
}

func uiNearly(a, b float64) bool { return math.Abs(a-b) < 1e-4 }

func TestAShapeSayingNothingNewIsTheRecordItAlwaysWas(t *testing.T) {
	_, shapes := uiReadScene(t, UiScene(nil, []UiShape{UiBox([]UiAttr{UiAttrAt(1, 2, 3)}, 1, 2, 3)}))
	if s := shapes[0]; s.mask&uiSceneHasMore != 0 || s.kind != uiSceneBox || !uiNearly(s.at[1], 2) {
		t.Errorf("read back %+v", s)
	}
}

func TestAGroupCarriesWhatItHolds(t *testing.T) {
	scene := UiScene(nil, []UiShape{UiGroup([]UiAttr{UiAttrAt(1, 0, 0), UiAttrTurn(0, math.Pi/2, 0), UiAttrTag(3)}, []UiShape{
		UiBox([]UiAttr{UiAttrAt(1, 0, 0)}, 1, 1, 1),
		UiLabel([]UiAttr{UiAttrAt(0, 2, 0)}, "over it"),
		UiLine([]UiAttr{UiAttrThick(0.2)}, 0, 0, 0, 0, 1, 0),
	})})
	_, shapes := uiReadScene(t, scene)
	if len(shapes) != 3 {
		t.Fatalf("a group of three came out as %d", len(shapes))
	}
	box := shapes[0]
	if box.more&uiSceneMoreMatrix == 0 || box.at != nil || !uiNearly(box.matrix[3], 1) || !uiNearly(box.matrix[11], -1) {
		t.Errorf("the box stands at %v", box.matrix)
	}
	if label := shapes[1]; label.more != 0 || !uiNearly(label.at[0], 1) || !uiNearly(label.at[1], 2) {
		t.Errorf("the label stands at %v", label.at)
	}
	bar := shapes[2]
	if bar.kind != uiSceneCylinder || len(bar.matrix) != 12 || !uiNearly(bar.matrix[7], 0.5) {
		t.Errorf("a thick line came out as kind %d, %v", bar.kind, bar.matrix)
	}
	if det := bar.matrix[0]*(bar.matrix[5]*bar.matrix[10]-bar.matrix[6]*bar.matrix[9]) -
		bar.matrix[1]*(bar.matrix[4]*bar.matrix[10]-bar.matrix[6]*bar.matrix[8]) +
		bar.matrix[2]*(bar.matrix[4]*bar.matrix[9]-bar.matrix[5]*bar.matrix[8]); det <= 0 {
		t.Errorf("the bar is turned inside out: %v", det)
	}
}

func TestAShapeSaysHowItShines(t *testing.T) {
	_, shapes := uiReadScene(t, UiScene(nil, []UiShape{UiSphere([]UiAttr{UiAttrRough(0.25), UiAttrGlow(2),
		UiAttrUnlit(true), UiAttrWire(true), UiAttrShadows(false), UiAttrTexture("a.png"), UiAttrRelief("b.png"),
		UiAttrTile(3, 4)}, 1)}))
	s := shapes[0]
	if s.shine != [3]float64{0.25, -1, 2} || s.flags != 7 || s.pic != "a.png" || s.bump != "b.png" || s.tile != [2]float64{3, 4} {
		t.Errorf("read back %+v", s)
	}
	_, shapes = uiReadScene(t, UiScene(nil, []UiShape{UiModel([]UiAttr{UiAttrPlay("walk", 1.5, true)}, "man.glb")}))
	if s := shapes[0]; s.kind != uiSceneFigure || s.words != "man.glb" || s.clip != "walk" || s.clipAt != 1.5 || !s.loop {
		t.Errorf("a model playing read back %+v", s)
	}
}

func TestTheEyeOrbitsAndLooksToward(t *testing.T) {
	e, _ := uiReadScene(t, UiScene([]UiAttr{UiAttrOrbit(0, 1, 0, 0, -0.5, 10)}, nil))
	if !uiNearly(e.eye[1], 1+10*math.Sin(0.5)) || !uiNearly(e.eye[2], 10*math.Cos(0.5)) || !uiNearly(e.aim[1], -0.5) {
		t.Errorf("orbiting, the eye is at %v aiming %v", e.eye, e.aim)
	}
	e, _ = uiReadScene(t, UiScene([]UiAttr{UiAttrEye(3, 0, 0), UiAttrToward(0, 0, 0)}, nil))
	if !uiNearly(e.aim[0], math.Pi/2) || !uiNearly(e.aim[1], 0) {
		t.Errorf("looking toward the origin from +x aims %v", e.aim)
	}
}

func TestTheCameraCarriesWhatWasNamed(t *testing.T) {
	e, _ := uiReadScene(t, UiScene([]UiAttr{UiAttrRoll(0.3), UiAttrOrtho(12), UiAttrDepth(1, 50),
		UiAttrAmbient(UiToneHex("#102030"), 0.5), UiAttrSunlight(UiTone("Warn"), 2), UiAttrPanorama("sky.png"),
		UiAttrBackground(UiToneRGBA(0, 0, 0, 0)), UiAttrSnapshot(4), UiAttrOnSnapshot(func(string) any { return nil }),
		UiAttrOnHit(func(int, float64, float64, float64) any { return nil })}, nil))
	if !uiNearly(e.roll, 0.3) || e.ortho != 12 || e.near != 1 || e.far != 50 || e.ambient != "#102030" ||
		e.ambientAt != 0.5 || e.sunlight != "#f0b429" || e.sunlightAt != 2 || e.panorama != "sky.png" {
		t.Errorf("read back %+v", e)
	}
	if e.wants != "ht#4" {
		t.Errorf("the scene wants %q", e.wants)
	}
	e, _ = uiReadScene(t, UiScene(nil, nil))
	if e.near != 0.08 || e.far != 800 || e.wants != "" {
		t.Errorf("a camera saying nothing read back %+v", e)
	}
}

func uiPointedAt(t *testing.T, attrs []UiAttr, shapes []UiShape, x, y float64) (int, [3]float64) {
	t.Helper()
	heard := append(attrs, UiAttrOnHit(func(int, float64, float64, float64) any { return nil }))
	v := UiScene(heard, shapes)
	tag, px, py, pz := uiScenePick(v.Attrs, fmt.Sprintf("%g,%g,200,100", x, y))
	return tag, [3]float64{px, py, pz}
}

func TestWhatIsUnderThePointer(t *testing.T) {
	ahead := []UiShape{
		UiSphere([]UiAttr{UiAttrAt(0, 1.7, -5), UiAttrTag(7)}, 1),
		UiBox([]UiAttr{UiAttrAt(0, 1.7, -9), UiAttrTag(8)}, 4, 8, 1),
	}
	if tag, at := uiPointedAt(t, nil, ahead, 100, 50); tag != 7 || !uiNearly(at[2], -4) {
		t.Errorf("straight ahead is %d at %v", tag, at)
	}
	if tag, at := uiPointedAt(t, nil, ahead, 100, 30); tag != 8 || !uiNearly(at[2], -8.5) {
		t.Errorf("above the ball is %d at %v", tag, at)
	}
	if tag, _ := uiPointedAt(t, nil, ahead, 100, 99); tag != -1 {
		t.Errorf("below everything is %d", tag)
	}
	held := []UiShape{UiGroup([]UiAttr{UiAttrAt(0, 1.7, -5), UiAttrTag(4)}, []UiShape{UiBox(nil, 1, 1, 1)})}
	if tag, _ := uiPointedAt(t, nil, held, 100, 50); tag != 4 {
		t.Errorf("a box in a group answers %d", tag)
	}
	ring := []UiShape{UiTorus([]UiAttr{UiAttrAt(0, 1.7, -5), UiAttrTurn(math.Pi/2, 0, 0), UiAttrTag(2)}, 1, 0.25)}
	if tag, _ := uiPointedAt(t, nil, ring, 100, 50); tag != -1 {
		t.Errorf("through the hole is %d", tag)
	}
	if tag, at := uiPointedAt(t, []UiAttr{UiAttrOrtho(4)}, ring, 125, 50); tag != 2 || !uiNearly(at[0], 1) {
		t.Errorf("an ortho ray a metre right meets %d at %v", tag, at)
	}
	pill := []UiShape{UiCapsule([]UiAttr{UiAttrAt(0, 1.7, -5), UiAttrTag(5)}, 0.5, 3)}
	if tag, at := uiPointedAt(t, nil, pill, 100, 50); tag != 5 || !uiNearly(at[2], -4.5) {
		t.Errorf("a capsule ahead is %d at %v", tag, at)
	}
	flat := []UiShape{UiMesh([]UiAttr{UiAttrAt(0, 1.7, -5), UiAttrTag(9)}, []float64{-1, -1, 0, 1, -1, 0, 0, 1, 0}, []int{0, 1, 2}, nil)}
	if tag, at := uiPointedAt(t, nil, flat, 100, 50); tag != 9 || !uiNearly(at[2], -5) {
		t.Errorf("a triangle ahead is %d at %v", tag, at)
	}
	hills := []UiShape{UiTerrain([]UiAttr{UiAttrTag(6)}, 3, 10, []float64{0, 0, 0, 0, 0, 0, 0, 0, 0}, nil)}
	if tag, at := uiPointedAt(t, []UiAttr{UiAttrAim(0, -0.5)}, hills, 100, 50); tag != 6 || !uiNearly(at[1], 0) {
		t.Errorf("the ground ahead is %d at %v", tag, at)
	}
}

// Every triangle a generated mesh holds faces the way its points say they face.
func uiFacesOutward(t *testing.T, name string, s UiShape) {
	t.Helper()
	held := uiMeshOf(s.Text)
	if held == nil {
		t.Fatalf("%s left no mesh", name)
	}
	count := binary.LittleEndian.Uint32(held.data)
	normal := func(i uint32) [3]float64 {
		at := 8 + int(i)*17*4 + 12
		var n [3]float64
		for k := 0; k < 3; k++ {
			n[k] = float64(math.Float32frombits(binary.LittleEndian.Uint32(held.data[at+k*4:])))
		}
		return n
	}
	wrong, total := 0, 0
	for i := 0; i+2 < len(held.index); i += 3 {
		a, b, c := held.index[i], held.index[i+1], held.index[i+2]
		if a >= count || b >= count || c >= count {
			t.Fatalf("%s points past its %d points", name, count)
		}
		p := func(k uint32) [3]float64 {
			return [3]float64{float64(held.points[k*3]), float64(held.points[k*3+1]), float64(held.points[k*3+2])}
		}
		face := uiCross3(uiSub(p(b), p(a)), uiSub(p(c), p(a)))
		if uiLen(face) < 1e-12 {
			continue
		}
		n := normal(a)
		n2, n3 := normal(b), normal(c)
		total++
		if uiDot(face, [3]float64{n[0] + n2[0] + n3[0], n[1] + n2[1] + n3[1], n[2] + n2[2] + n3[2]}) <= 0 {
			wrong++
		}
	}
	if total == 0 || wrong > 0 {
		t.Errorf("%s: %d of %d triangles face away from their points", name, wrong, total)
	}
}

func TestBuiltShapesFaceOutward(t *testing.T) {
	uiFacesOutward(t, "a tube", UiTube(nil, []float64{0, 0, 0, 0, 1, 0, 1, 2, 0, 2, 2, 1}, 0.2))
	uiFacesOutward(t, "an outline one way", UiExtrude(nil, []float64{0, 0, 2, 0, 2, 1, 1, 2, 0, 1}, 1))
	uiFacesOutward(t, "an outline the other way", UiExtrude(nil, []float64{0, 1, 1, 2, 2, 1, 2, 0, 0, 0}, 1))
	uiFacesOutward(t, "a lathe", UiLathe(nil, []float64{0, 0, 1, 0, 1.2, 0.5, 0.4, 1, 0.5, 1.5, 0, 1.6}, 24))
	uiFacesOutward(t, "a cloud", UiCloud(nil, []float64{0, 0, 0, 1, 1, 1}, 0.1))
	uiFacesOutward(t, "a mesh", UiMesh(nil, []float64{0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0},
		[]int{0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3}, nil))
}

func TestAMeshTravelsByName(t *testing.T) {
	s := UiMesh(nil, []float64{0, 0, 0, 1, 0, 0, 0, 1, 0}, []int{0, 1, 2, 0, 5, 1}, []int{0xff0000})
	data, ok := uiSceneData(s.Text)
	if !ok || binary.LittleEndian.Uint32(data) != 3 || binary.LittleEndian.Uint32(data[4:]) != 3 || !s.coloured {
		t.Fatalf("a mesh named %q holds %v", s.Text, data[:8])
	}
	if again := UiMesh(nil, []float64{0, 0, 0, 1, 0, 0, 0, 1, 0}, []int{0, 1, 2}, []int{0xff0000}); again.Text != s.Text {
		t.Errorf("the same mesh is named %q and %q", s.Text, again.Text)
	}
	_, shapes := uiReadScene(t, UiScene(nil, []UiShape{s}))
	if shapes[0].kind != uiSceneMesh || shapes[0].words != s.Text || shapes[0].colour != "#ffffff" {
		t.Errorf("read back %+v", shapes[0])
	}
}
