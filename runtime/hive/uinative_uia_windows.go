// UI Automation, which is how a screen reader on Windows reads the window.

//go:build windows

package hive

import (
	"hash/fnv"
	"math"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

var (
	uiaCore    = syscall.NewLazyDLL("uiautomationcore.dll")
	uiaOleAut  = syscall.NewLazyDLL("oleaut32.dll")
	uiaOle32   = syscall.NewLazyDLL("ole32.dll")
	uiaReturn  = uiaCore.NewProc("UiaReturnRawElementProvider")
	uiaHostOf  = uiaCore.NewProc("UiaHostProviderFromHwnd")
	uiaEvent   = uiaCore.NewProc("UiaRaiseAutomationEvent")
	uiaChanged = uiaCore.NewProc("UiaRaiseAutomationPropertyChangedEvent")
	uiaTree    = uiaCore.NewProc("UiaRaiseStructureChangedEvent")
	uiaHeard   = uiaCore.NewProc("UiaClientsAreListening")
	uiaCut     = uiaCore.NewProc("UiaDisconnectProvider")

	uiaSysAlloc  = uiaOleAut.NewProc("SysAllocString")
	uiaSysFree   = uiaOleAut.NewProc("SysFreeString")
	uiaVector    = uiaOleAut.NewProc("SafeArrayCreateVector")
	uiaPutItem   = uiaOleAut.NewProc("SafeArrayPutElement")
	uiaComInit   = uiaOle32.NewProc("CoInitializeEx")
	uiaHeap      = uiwKernel32.NewProc("GetProcessHeap")
	uiaAlloc     = uiwKernel32.NewProc("HeapAlloc")
	uiaFree      = uiwKernel32.NewProc("HeapFree")
	uiaReserve   = uiwKernel32.NewProc("VirtualAlloc")
	uiaProtect   = uiwKernel32.NewProc("VirtualProtect")
	uiaFlushCode = uiwKernel32.NewProc("FlushInstructionCache")
	uiaProcess   = uiwKernel32.NewProc("GetCurrentProcess")
	uiaThreadId  = uiwKernel32.NewProc("GetCurrentThreadId")
	uiaSendWait  = uiwUser32.NewProc("SendMessageTimeoutW")
	uiaToScreen  = uiwUser32.NewProc("ClientToScreen")
)

const (
	uiaWmCall    = 0x8010
	uiaWmNotice  = 0x8011
	uiaGetObject = 0x003D

	uiaOk          = 0
	uiaNoInterface = 0x80004002
	uiaFailed      = 0x80004005
	uiaBadArgument = 0x80070057
	uiaGoneError   = 0x80040201
	uiaNotEnabled  = 0x80040200
	uiaNotAllowed  = 0x80131509
)

const (
	uiaFaceSimple = iota
	uiaFaceFragment
	uiaFaceRoot
	uiaFaceInvoke
	uiaFaceToggle
	uiaFaceValue
	uiaFaceRange
	uiaFaceExpand
	uiaFaceItem
	uiaFaces
)

const uiaWord = unsafe.Sizeof(uintptr(0))

const uiaFaceSize = 2 * uiaWord

type uiaGuid [16]byte

func uiaIid(s string) uiaGuid {
	var hex []byte
	for i := 0; i < len(s); i++ {
		if s[i] != '-' {
			hex = append(hex, s[i])
		}
	}
	var raw [16]byte
	for i := range raw {
		v, _ := strconv.ParseUint(string(hex[2*i:2*i+2]), 16, 8)
		raw[i] = byte(v)
	}
	return uiaGuid{raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6],
		raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]}
}

var uiaIids = map[uiaGuid]int{
	uiaIid("00000000-0000-0000-c000-000000000046"): uiaFaceSimple,
	uiaIid("d6dd68d1-86fd-4332-8666-9abedea2d24c"): uiaFaceSimple,
	uiaIid("f7063da8-8359-439c-9297-bbc5299a7d87"): uiaFaceFragment,
	uiaIid("620ce2a5-ab8f-40a9-86cb-de3c75599b58"): uiaFaceRoot,
	uiaIid("54fcb24b-e18e-47a2-b4d3-eccbe77599a2"): uiaFaceInvoke,
	uiaIid("56d00bd0-c4f4-433c-a836-1a52a57e0892"): uiaFaceToggle,
	uiaIid("c7935180-6fb3-4201-b174-7df73adbf64a"): uiaFaceValue,
	uiaIid("36dc7aef-33e6-4691-afe1-2be7274b3d33"): uiaFaceRange,
	uiaIid("d847d3a5-cab0-4a98-8c32-ecb45c59ad24"): uiaFaceExpand,
	uiaIid("2acad808-b2d4-452d-a407-91ff1ad167b2"): uiaFaceItem,
}

var uiaPatternFaces = map[uintptr]int{
	10000: uiaFaceInvoke,
	10002: uiaFaceValue,
	10003: uiaFaceRange,
	10005: uiaFaceExpand,
	10010: uiaFaceItem,
	10015: uiaFaceToggle,
}

type uiaObj struct {
	base uintptr
	refs int32
	id   int32
	host *uiaHost
}

type uiaHost struct {
	w      *uiwWindow
	hwnd   uintptr
	thread uintptr
	objs   map[int32]*uiaObj
	root   *uiaObj
	gone   atomic.Bool
	seen   uint64
	posted bool
	focus  int32
	shape  uint64
	kept   uiaKept
	queue  chan func()
}

type uiaKept struct {
	id     int32
	value  string
	toggle int32
	expand int32
	now    float64
}

type uiaCall struct {
	fn func() uintptr
	hr uintptr
}

var (
	uiaMu      sync.Mutex
	uiaObjs    = map[uintptr]*uiaObj{}
	uiaHosts   sync.Map
	uiaCalls   sync.Map
	uiaSerial  uintptr
	uiaVtables [uiaFaces][]uintptr
	uiaSetup   sync.Once
	uiaRootId  = uiAccessId("window")
)

func (w *uiwWindow) uiaHost() *uiaHost {
	if h, ok := uiaHosts.Load(w); ok {
		return h.(*uiaHost)
	}
	h := &uiaHost{w: w, objs: map[int32]*uiaObj{}}
	actual, _ := uiaHosts.LoadOrStore(w, h)
	return actual.(*uiaHost)
}

func (w *uiwWindow) uiaHandle(msg, wp, lp uintptr) (uintptr, bool) {
	switch msg {
	case uiwWmCreate:
		h := w.uiaHost()
		h.hwnd, h.thread = w.hwnd, uiwCall(uiaThreadId)
		uiwCall(uiaComInit, 0, 2)
	case uiaGetObject:
		if int32(lp) != -25 || uiaReturn.Find() != nil {
			return 0, false
		}
		h := w.uiaHost()
		if h.gone.Load() {
			return 0, false
		}
		uiaSetup.Do(uiaBuild)
		if h.root == nil {
			h.root = h.object(uiaRootId)
		}
		return uiwCall(uiaReturn, w.hwnd, wp, lp, h.root.face(uiaFaceSimple)), true
	case uiaWmCall:
		if found, ok := uiaCalls.Load(wp); ok {
			c := found.(*uiaCall)
			atomic.StoreUintptr(&c.hr, c.fn())
		}
		return 0, true
	case uiaWmNotice:
		h := w.uiaHost()
		h.posted = false
		h.notice()
		return 0, true
	case uiwWmDestroy:
		w.uiaHost().close()
	}
	return 0, false
}

func (w *uiwWindow) uiaNotice() {
	found, ok := uiaHosts.Load(w)
	if !ok {
		return
	}
	h := found.(*uiaHost)
	if h.root == nil || h.gone.Load() || h.posted || h.seen == w.n.stamp {
		return
	}
	h.seen = w.n.stamp
	if uiwCall(uiaHeard) == 0 {
		return
	}
	h.posted = true
	uiwCall(uiwPostMessage, w.hwnd, uiaWmNotice, 0, 0)
}

func (h *uiaHost) close() {
	if h.gone.Swap(true) || uiaReturn.Find() != nil {
		return
	}
	uiwCall(uiaReturn, h.hwnd, 0, 0, 0)
	uiaMu.Lock()
	var live []*uiaObj
	for _, o := range h.objs {
		live = append(live, o)
	}
	uiaMu.Unlock()
	if uiaCut.Find() == nil {
		for _, o := range live {
			uiwCall(uiaCut, o.face(uiaFaceSimple))
		}
	}
	if h.root != nil {
		h.root.release()
	}
	if h.queue != nil {
		close(h.queue)
	}
}

func (h *uiaHost) run(fn func() uintptr) uintptr {
	if h.gone.Load() {
		return uiaGoneError
	}
	if uiwCall(uiaThreadId) == h.thread {
		return fn()
	}
	c := &uiaCall{fn: fn, hr: uiaGoneError}
	key := atomic.AddUintptr(&uiaSerial, 1)
	uiaCalls.Store(key, c)
	defer uiaCalls.Delete(key)
	var result uintptr
	if uiwCall(uiaSendWait, h.hwnd, uiaWmCall, key, 0, 0x22, 10000, uintptr(unsafe.Pointer(&result))) == 0 {
		return uiaGoneError
	}
	return atomic.LoadUintptr(&c.hr)
}

func (h *uiaHost) object(id int32) *uiaObj {
	uiaMu.Lock()
	defer uiaMu.Unlock()
	if o := h.objs[id]; o != nil {
		o.refs++
		return o
	}
	base := uiwCall(uiaAlloc, uiwCall(uiaHeap), 8, uiaFaces*uiaFaceSize)
	for i := 0; i < uiaFaces; i++ {
		face := base + uintptr(i)*uiaFaceSize
		*(*uintptr)(uiwAt(face)) = uintptr(unsafe.Pointer(&uiaVtables[i][0]))
		*(*uintptr)(uiwAt(face + uiaWord)) = uintptr(i)
	}
	o := &uiaObj{base: base, refs: 1, id: id, host: h}
	h.objs[id] = o
	uiaObjs[base] = o
	return o
}

func (o *uiaObj) face(i int) uintptr { return o.base + uintptr(i)*uiaFaceSize }

func (o *uiaObj) addRef() int32 {
	uiaMu.Lock()
	defer uiaMu.Unlock()
	o.refs++
	return o.refs
}

func (o *uiaObj) release() int32 {
	uiaMu.Lock()
	o.refs--
	refs := o.refs
	if refs == 0 {
		delete(uiaObjs, o.base)
		if o.host.objs[o.id] == o {
			delete(o.host.objs, o.id)
		}
	}
	uiaMu.Unlock()
	if refs == 0 {
		uiwCall(uiaFree, uiwCall(uiaHeap), 0, o.base)
	}
	return refs
}

func uiaFrom(this uintptr) *uiaObj {
	if this == 0 {
		return nil
	}
	i := *(*uintptr)(uiwAt(this + uiaWord))
	uiaMu.Lock()
	defer uiaMu.Unlock()
	return uiaObjs[this-i*uiaFaceSize]
}

func uiaOn(this uintptr, fn func(o *uiaObj, a *uiAccess, n *uiNative) uintptr) uintptr {
	o := uiaFrom(this)
	if o == nil {
		return uiaGoneError
	}
	return o.host.run(func() uintptr {
		n := o.host.w.n
		a := n.accessFind(o.id)
		if a == nil {
			return uiaGoneError
		}
		return fn(o, a, n)
	})
}

func (h *uiaHost) give(out uintptr, a *uiAccess, face int) {
	if out == 0 {
		return
	}
	if a == nil {
		*(*uintptr)(uiwAt(out)) = 0
		return
	}
	*(*uintptr)(uiwAt(out)) = h.object(a.id).face(face)
}

func uiaSet(out uintptr, v uintptr) {
	if out != 0 {
		*(*uintptr)(uiwAt(out)) = v
	}
}

func uiaBuild() {
	unknown := []uintptr{syscall.NewCallback(uiaQuery), syscall.NewCallback(uiaAddRef), syscall.NewCallback(uiaRelease)}
	with := func(methods ...interface{}) []uintptr {
		table := append([]uintptr(nil), unknown...)
		for _, m := range methods {
			switch m := m.(type) {
			case uintptr:
				table = append(table, m)
			default:
				table = append(table, syscall.NewCallback(m))
			}
		}
		return table
	}
	point, setRange := uiaFloatMethods()
	uiaVtables[uiaFaceSimple] = with(uiaOptions, uiaPattern, uiaProperty, uiaHostProvider)
	uiaVtables[uiaFaceFragment] = with(uiaNavigate, uiaRuntimeId, uiaBounds, uiaEmbedded, uiaSetFocus, uiaFragmentRoot)
	uiaVtables[uiaFaceRoot] = with(point, uiaFocusIn)
	uiaVtables[uiaFaceInvoke] = with(uiaInvoke)
	uiaVtables[uiaFaceToggle] = with(uiaToggle, uiaToggleState)
	uiaVtables[uiaFaceValue] = with(uiaSetValue, uiaValue, uiaValueReadOnly)
	uiaVtables[uiaFaceRange] = with(setRange, uiaRangeValue, uiaRangeReadOnly, uiaRangeHigh, uiaRangeLow, uiaRangeLarge, uiaRangeSmall)
	uiaVtables[uiaFaceExpand] = with(uiaExpand, uiaCollapse, uiaExpandState)
	uiaVtables[uiaFaceItem] = with(uiaSelect, uiaSelect, uiaUnselect, uiaIsSelected, uiaContainer)
}

func uiaFloatMethods() (uintptr, uintptr) {
	if runtime.GOARCH == "386" {
		return syscall.NewCallback(uiaFromPoint386), syscall.NewCallback(uiaSetRange386)
	}
	point := syscall.NewCallback(uiaFromPoint)
	setRange := syscall.NewCallback(uiaSetRange)
	var pointCode, rangeCode []byte
	switch runtime.GOARCH {
	case "amd64":
		pointCode = append([]byte{0x66, 0x48, 0x0F, 0x7E, 0xCA, 0x66, 0x49, 0x0F, 0x7E, 0xD0, 0x48, 0xB8}, uiaBytes(uint64(point))...)
		pointCode = append(pointCode, 0xFF, 0xE0)
		rangeCode = append([]byte{0x66, 0x48, 0x0F, 0x7E, 0xCA, 0x48, 0xB8}, uiaBytes(uint64(setRange))...)
		rangeCode = append(rangeCode, 0xFF, 0xE0)
	case "arm64":
		pointCode = append(uiaWords(0xAA0103E3, 0x9E660001, 0x9E660022, 0x58000070, 0xD61F0200, 0xD503201F), uiaBytes(uint64(point))...)
		rangeCode = append(uiaWords(0x9E660001, 0x58000070, 0xD61F0200, 0xD503201F), uiaBytes(uint64(setRange))...)
	default:
		return point, setRange
	}
	p, r := uiaCode(pointCode), uiaCode(rangeCode)
	if p == 0 || r == 0 {
		return point, setRange
	}
	return p, r
}

func uiaBytes(v uint64) []byte {
	var b [8]byte
	for i := range b {
		b[i] = byte(v >> (8 * i))
	}
	return b[:]
}

func uiaWords(ws ...uint32) []byte {
	var out []byte
	for _, w := range ws {
		out = append(out, uiaBytes(uint64(w))[:4]...)
	}
	return out
}

func uiaCode(code []byte) uintptr {
	page := uiwCall(uiaReserve, 0, 4096, 0x3000, 0x04)
	if page == 0 {
		return 0
	}
	copy(unsafe.Slice((*byte)(uiwAt(page)), len(code)), code)
	var old uint32
	uiwCall(uiaProtect, page, 4096, 0x20, uintptr(unsafe.Pointer(&old)))
	uiwCall(uiaFlushCode, uiwCall(uiaProcess), page, 4096)
	return page
}

func uiaQuery(this, riid, out uintptr) uintptr {
	uiaSet(out, 0)
	o := uiaFrom(this)
	if o == nil || riid == 0 {
		return uiaNoInterface
	}
	face, ok := uiaIids[*(*uiaGuid)(uiwAt(riid))]
	if !ok || face == uiaFaceRoot && o.id != uiaRootId {
		return uiaNoInterface
	}
	o.addRef()
	uiaSet(out, o.face(face))
	return uiaOk
}

func uiaAddRef(this uintptr) uintptr {
	if o := uiaFrom(this); o != nil {
		return uintptr(o.addRef())
	}
	return 0
}

func uiaRelease(this uintptr) uintptr {
	if o := uiaFrom(this); o != nil {
		return uintptr(o.release())
	}
	return 0
}

func uiaOptions(this, out uintptr) uintptr {
	if out != 0 {
		*(*int32)(uiwAt(out)) = 2
	}
	return uiaOk
}

func uiaPatterns(a *uiAccess) []uintptr {
	switch a.role {
	case "button", "link":
		if a.role == "link" {
			return []uintptr{10000, 10002}
		}
		return []uintptr{10000}
	case "listitem":
		return []uintptr{10000, 10010}
	case "row", "columnheader":
		if a.part != -1 {
			return []uintptr{10000}
		}
	case "checkbox":
		return []uintptr{10015}
	case "edit", "password", "spin":
		return []uintptr{10002}
	case "date", "combobox":
		return []uintptr{10002, 10005}
	case "slider":
		return []uintptr{10002, 10003}
	}
	return nil
}

func uiaPattern(this, pattern, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		for _, p := range uiaPatterns(a) {
			if p == pattern {
				o.addRef()
				uiaSet(out, o.face(uiaPatternFaces[p]))
			}
		}
		return uiaOk
	})
}

var uiaControlTypes = map[string]int32{
	"text": 50020, "heading": 50020, "link": 50005, "button": 50000, "checkbox": 50002,
	"combobox": 50003, "list": 50008, "listitem": 50007, "edit": 50004, "password": 50004, "spin": 50004,
	"date": 50004, "slider": 50015, "table": 50036, "row": 50029, "cell": 50020, "columnheader": 50035,
	"image": 50006, "progress": 50012, "dialog": 50032, "group": 50026, "tooltip": 50022,
}

func uiaControlType(a *uiAccess) int32 {
	if a.role == "row" && len(a.kids) > 0 && a.kids[0].role == "columnheader" {
		return 50034
	}
	if t, ok := uiaControlTypes[a.role]; ok {
		return t
	}
	return 50025
}

func uiaProperty(this, property, out uintptr) uintptr {
	if out == 0 {
		return uiaBadArgument
	}
	uiaEmpty(out)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		root := a.parent == nil
		switch property {
		case 30003:
			if !root {
				uiaInt(out, uiaControlType(a))
			}
		case 30005:
			if !root {
				uiaString(out, a.name)
			}
		case 30008:
			uiaBool(out, a.focused && o.host.w.active)
		case 30009:
			uiaBool(out, a.focusable)
		case 30010:
			uiaBool(out, !a.disabled)
		case 30011:
			if !root {
				uiaString(out, a.path)
			}
		case 30013:
			if a.help != "" {
				uiaString(out, a.help)
			}
		case 30019:
			uiaBool(out, a.protected)
		case 30022:
			if !root {
				uiaBool(out, uiaOffscreen(a, n))
			}
		case 30024:
			uiaString(out, "Hive")
		case 30173:
			if a.role == "heading" && a.level > 0 {
				uiaInt(out, 80050+int32(a.level))
			}
		case 30174:
			uiaBool(out, a.role == "dialog")
		}
		return uiaOk
	})
}

func uiaOffscreen(a *uiAccess, n *uiNative) bool {
	return a.w <= 0 || a.h <= 0 || a.x+a.w <= 0 || a.y+a.h <= 0 || a.x >= n.vw*n.scale || a.y >= n.vh*n.scale
}

func uiaHostProvider(this, out uintptr) uintptr {
	uiaSet(out, 0)
	o := uiaFrom(this)
	if o == nil || o.id != uiaRootId || uiaHostOf.Find() != nil {
		return uiaOk
	}
	return uiwCall(uiaHostOf, o.host.hwnd, out)
}

func uiaNavigate(this, direction, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		var next *uiAccess
		switch direction {
		case 0:
			next = a.parent
		case 1, 2:
			if a.parent != nil {
				kids := a.parent.kids
				for i, k := range kids {
					if k == a && direction == 1 && i+1 < len(kids) {
						next = kids[i+1]
					}
					if k == a && direction == 2 && i > 0 {
						next = kids[i-1]
					}
				}
			}
		case 3:
			if len(a.kids) > 0 {
				next = a.kids[0]
			}
		case 4:
			if len(a.kids) > 0 {
				next = a.kids[len(a.kids)-1]
			}
		}
		o.host.give(out, next, uiaFaceFragment)
		return uiaOk
	})
}

func uiaRuntimeId(this, out uintptr) uintptr {
	uiaSet(out, 0)
	o := uiaFrom(this)
	if o == nil {
		return uiaGoneError
	}
	if o.id == uiaRootId {
		return uiaOk
	}
	array := uiwCall(uiaVector, 3, 0, 2)
	if array == 0 {
		return uiaFailed
	}
	for i, v := range []int32{3, o.id} {
		index := int32(i)
		uiwCall(uiaPutItem, array, uintptr(unsafe.Pointer(&index)), uintptr(unsafe.Pointer(&v)))
	}
	uiaSet(out, array)
	return uiaOk
}

func (h *uiaHost) origin() (float64, float64) {
	var at uiwPoint
	uiwCall(uiaToScreen, h.hwnd, uintptr(unsafe.Pointer(&at)))
	return float64(at.x), float64(at.y)
}

func uiaBounds(this, out uintptr) uintptr {
	if out == 0 {
		return uiaBadArgument
	}
	*(*[4]float64)(uiwAt(out)) = [4]float64{}
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.parent == nil {
			return uiaOk
		}
		x, y := o.host.origin()
		*(*[4]float64)(uiwAt(out)) = [4]float64{x + a.x, y + a.y, math.Max(a.w, 0), math.Max(a.h, 0)}
		return uiaOk
	})
}

func uiaEmbedded(this, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOk
}

func (h *uiaHost) acted(done bool) uintptr {
	h.w.invalidate()
	if !done {
		return uiaNotAllowed
	}
	return uiaOk
}

func uiaSetFocus(this uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.parent == nil {
			return uiaOk
		}
		return o.host.acted(n.accessAct(a.id, "focus"))
	})
}

func uiaFragmentRoot(this, out uintptr) uintptr {
	uiaSet(out, 0)
	o := uiaFrom(this)
	if o == nil {
		return uiaGoneError
	}
	h := o.host
	if h.gone.Load() || h.root == nil {
		return uiaGoneError
	}
	h.root.addRef()
	uiaSet(out, h.root.face(uiaFaceRoot))
	return uiaOk
}

func uiaFromPoint(this, xBits, yBits, out uintptr) uintptr {
	return uiaAtPoint(this, math.Float64frombits(uint64(xBits)), math.Float64frombits(uint64(yBits)), out)
}

func uiaFromPoint386(this, xLow, xHigh, yLow, yHigh, out uintptr) uintptr {
	x := math.Float64frombits(uint64(xLow) | uint64(xHigh)<<32)
	y := math.Float64frombits(uint64(yLow) | uint64(yHigh)<<32)
	return uiaAtPoint(this, x, y, out)
}

func uiaAtPoint(this uintptr, x, y float64, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		left, top := o.host.origin()
		found := n.accessAt(x-left, y-top)
		if found != nil && found.parent != nil {
			o.host.give(out, found, uiaFaceFragment)
		}
		return uiaOk
	})
}

func uiaFocusIn(this, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if found := n.accessFocused(); found != nil && found.parent != nil {
			o.host.give(out, found, uiaFaceFragment)
		}
		return uiaOk
	})
}

func uiaPress(this uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.disabled {
			return uiaNotEnabled
		}
		return o.host.acted(n.accessAct(a.id, "press"))
	})
}

func uiaInvoke(this uintptr) uintptr { return uiaPress(this) }
func uiaToggle(this uintptr) uintptr { return uiaPress(this) }
func uiaSelect(this uintptr) uintptr { return uiaPress(this) }

func uiaUnselect(this uintptr) uintptr { return uiaNotAllowed }

func uiaToggleState(this, out uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if out != 0 {
			*(*int32)(uiwAt(out)) = uiaToggled(a)
		}
		return uiaOk
	})
}

func uiaToggled(a *uiAccess) int32 {
	if a.checked == 1 {
		return 1
	}
	return 0
}

func uiaText(p uintptr) string {
	if p == 0 {
		return ""
	}
	var units []uint16
	for i := uintptr(0); ; i += 2 {
		c := *(*uint16)(uiwAt(p + i))
		if c == 0 {
			break
		}
		units = append(units, c)
	}
	return syscall.UTF16ToString(units)
}

func uiaSetValue(this, text uintptr) uintptr {
	value := uiaText(text)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.disabled {
			return uiaNotEnabled
		}
		return o.host.acted(n.accessSet(a.id, value))
	})
}

func uiaValueOf(a *uiAccess) string {
	if a.role == "slider" {
		return strconv.FormatFloat(a.now, 'f', -1, 64)
	}
	return a.value
}

func uiaValue(this, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		uiaSet(out, uiaBstr(uiaValueOf(a)))
		return uiaOk
	})
}

func uiaReadOnly(a *uiAccess) bool {
	switch a.role {
	case "edit", "password", "spin", "date":
		return !a.editable
	case "link":
		return true
	}
	return a.disabled
}

func uiaValueReadOnly(this, out uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		uiaSetBool(out, uiaReadOnly(a))
		return uiaOk
	})
}

func uiaSetBool(out uintptr, b bool) {
	if out != 0 {
		*(*int32)(uiwAt(out)) = 0
		if b {
			*(*int32)(uiwAt(out)) = 1
		}
	}
}

func uiaSetRange(this, bits uintptr) uintptr {
	return uiaRangeTo(this, math.Float64frombits(uint64(bits)))
}

func uiaSetRange386(this, low, high uintptr) uintptr {
	return uiaRangeTo(this, math.Float64frombits(uint64(low)|uint64(high)<<32))
}

func uiaRangeTo(this uintptr, v float64) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.disabled {
			return uiaNotEnabled
		}
		if v < a.low || v > a.high || math.IsNaN(v) {
			return uiaBadArgument
		}
		return o.host.acted(n.accessSet(a.id, strconv.FormatFloat(v, 'f', -1, 64)))
	})
}

func uiaDouble(this, out uintptr, pick func(a *uiAccess) float64) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if out != 0 {
			*(*float64)(uiwAt(out)) = pick(a)
		}
		return uiaOk
	})
}

func uiaRangeValue(this, out uintptr) uintptr {
	return uiaDouble(this, out, func(a *uiAccess) float64 { return a.now })
}

func uiaRangeHigh(this, out uintptr) uintptr {
	return uiaDouble(this, out, func(a *uiAccess) float64 { return a.high })
}

func uiaRangeLow(this, out uintptr) uintptr {
	return uiaDouble(this, out, func(a *uiAccess) float64 { return a.low })
}

func uiaRangeLarge(this, out uintptr) uintptr {
	return uiaDouble(this, out, func(a *uiAccess) float64 { return 10 })
}

func uiaRangeSmall(this, out uintptr) uintptr {
	return uiaDouble(this, out, func(a *uiAccess) float64 { return 1 })
}

func uiaRangeReadOnly(this, out uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		uiaSetBool(out, a.disabled)
		return uiaOk
	})
}

func uiaOpen(a *uiAccess, n *uiNative) bool {
	return n.popup != nil && n.popup.path == a.path
}

func uiaExpandTo(this uintptr, open bool) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if a.disabled {
			return uiaNotEnabled
		}
		if uiaOpen(a, n) == open {
			return uiaOk
		}
		return o.host.acted(n.accessAct(a.id, "press"))
	})
}

func uiaExpand(this uintptr) uintptr   { return uiaExpandTo(this, true) }
func uiaCollapse(this uintptr) uintptr { return uiaExpandTo(this, false) }

func uiaExpandState(this, out uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		if out != 0 {
			*(*int32)(uiwAt(out)) = uiaExpanded(a, n)
		}
		return uiaOk
	})
}

func uiaExpanded(a *uiAccess, n *uiNative) int32 {
	if uiaOpen(a, n) {
		return 1
	}
	return 0
}

func uiaIsSelected(this, out uintptr) uintptr {
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		uiaSetBool(out, a.selected)
		return uiaOk
	})
}

func uiaContainer(this, out uintptr) uintptr {
	uiaSet(out, 0)
	return uiaOn(this, func(o *uiaObj, a *uiAccess, n *uiNative) uintptr {
		o.host.give(out, a.parent, uiaFaceSimple)
		return uiaOk
	})
}

func uiaEmpty(out uintptr) {
	size := int(8 + 2*uiaWord)
	clear(unsafe.Slice((*byte)(uiwAt(out)), size))
}

func uiaInt(out uintptr, v int32) {
	*(*uint16)(uiwAt(out)) = 3
	*(*int32)(uiwAt(out + 8)) = v
}

func uiaBool(out uintptr, b bool) {
	*(*uint16)(uiwAt(out)) = 11
	*(*int16)(uiwAt(out + 8)) = 0
	if b {
		*(*int16)(uiwAt(out + 8)) = -1
	}
}

func uiaDoubleVariant(out uintptr, v float64) {
	*(*uint16)(uiwAt(out)) = 5
	*(*float64)(uiwAt(out + 8)) = v
}

func uiaString(out uintptr, s string) {
	*(*uint16)(uiwAt(out)) = 8
	*(*uintptr)(uiwAt(out + 8)) = uiaBstr(s)
}

func uiaBstr(s string) uintptr {
	u := uiwText(s)
	return uiwCall(uiaSysAlloc, uintptr(unsafe.Pointer(&u[0])))
}

type uiaVariant [3]uint64

func (v *uiaVariant) at() uintptr { return uintptr(unsafe.Pointer(v)) }

func (h *uiaHost) notice() {
	if h.gone.Load() || h.root == nil || uiwCall(uiaHeard) == 0 {
		return
	}
	n := h.w.n
	root := n.access()
	focused := n.accessFocused()
	var raise []func()
	if focused != nil && focused.parent != nil && focused.id != h.focus {
		o := h.object(focused.id)
		raise = append(raise, func() {
			uiwCall(uiaEvent, o.face(uiaFaceSimple), 20005)
			o.release()
		})
	}
	if focused != nil {
		h.focus = focused.id
	}
	shape := uiaShape(root)
	if h.shape != 0 && shape != h.shape {
		h.root.addRef()
		raise = append(raise, func() {
			uiwCall(uiaTree, h.root.face(uiaFaceSimple), 2, 0, 0)
			h.root.release()
		})
	}
	h.shape = shape
	if focused != nil && focused.parent != nil {
		now := uiaKept{id: focused.id, value: uiaValueOf(focused), toggle: uiaToggled(focused),
			expand: uiaExpanded(focused, n), now: focused.now}
		was := h.kept
		h.kept = now
		if was.id == now.id {
			raise = append(raise, h.changes(focused.id, was, now)...)
		}
	}
	if len(raise) == 0 {
		return
	}
	if h.queue == nil {
		h.queue = make(chan func(), 256)
		go uiaRaiser(h.queue)
	}
	for _, r := range raise {
		select {
		case h.queue <- r:
		default:
		}
	}
}

func (h *uiaHost) changes(id int32, was, now uiaKept) []func() {
	var out []func()
	property := func(prop uintptr, before, after uiaVariant, strings bool) {
		o := h.object(id)
		out = append(out, func() {
			if runtime.GOARCH == "386" {
				args := []uintptr{o.face(uiaFaceSimple), prop}
				for _, v := range []uiaVariant{before, after} {
					args = append(args, uintptr(v[0]), uintptr(v[0]>>32), uintptr(v[1]), uintptr(v[1]>>32))
				}
				uiwCall(uiaChanged, args...)
			} else {
				uiwCall(uiaChanged, o.face(uiaFaceSimple), prop, before.at(), after.at())
			}
			if strings {
				uiwCall(uiaSysFree, uintptr(before[1]))
				uiwCall(uiaSysFree, uintptr(after[1]))
			}
			o.release()
		})
	}
	var before, after uiaVariant
	if was.value != now.value {
		uiaString(before.at(), was.value)
		uiaString(after.at(), now.value)
		property(30045, before, after, true)
	}
	if was.toggle != now.toggle {
		uiaInt(before.at(), was.toggle)
		uiaInt(after.at(), now.toggle)
		property(30086, before, after, false)
	}
	if was.expand != now.expand {
		uiaInt(before.at(), was.expand)
		uiaInt(after.at(), now.expand)
		property(30070, before, after, false)
	}
	if was.now != now.now {
		uiaDoubleVariant(before.at(), was.now)
		uiaDoubleVariant(after.at(), now.now)
		property(30047, before, after, false)
	}
	return out
}

func uiaRaiser(queue chan func()) {
	runtime.LockOSThread()
	uiwCall(uiaComInit, 0, 0)
	for raise := range queue {
		raise()
	}
}

func uiaShape(root *uiAccess) uint64 {
	h := fnv.New64a()
	var walk func(a *uiAccess, depth byte)
	walk = func(a *uiAccess, depth byte) {
		var b [5]byte
		b[0] = depth
		b[1], b[2], b[3], b[4] = byte(a.id), byte(a.id>>8), byte(a.id>>16), byte(a.id>>24)
		h.Write(b[:])
		for _, k := range a.kids {
			walk(k, depth+1)
		}
	}
	walk(root, 0)
	return h.Sum64() | 1
}
