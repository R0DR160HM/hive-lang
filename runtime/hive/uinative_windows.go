// Win32 through syscall, so the build still needs no C compiler: the window, its
// messages, text set by GDI, and the clipboard.

//go:build windows

package hive

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

func init() { uiNativePainter = func() uiPainter { return &uiwWindow{n: uiNewNative()} } }

var (
	uiwUser32   = syscall.NewLazyDLL("user32.dll")
	uiwGdi32    = syscall.NewLazyDLL("gdi32.dll")
	uiwKernel32 = syscall.NewLazyDLL("kernel32.dll")
	uiwDwmapi   = syscall.NewLazyDLL("dwmapi.dll")
	uiwAdvapi32 = syscall.NewLazyDLL("advapi32.dll")
	uiwImm32    = syscall.NewLazyDLL("imm32.dll")

	uiwRegisterClassEx     = uiwUser32.NewProc("RegisterClassExW")
	uiwCreateWindowEx      = uiwUser32.NewProc("CreateWindowExW")
	uiwSetWindowText       = uiwUser32.NewProc("SetWindowTextW")
	uiwMapVirtualKey       = uiwUser32.NewProc("MapVirtualKeyW")
	uiwDefWindowProc       = uiwUser32.NewProc("DefWindowProcW")
	uiwShowWindow          = uiwUser32.NewProc("ShowWindow")
	uiwUpdateWindow        = uiwUser32.NewProc("UpdateWindow")
	uiwGetMessage          = uiwUser32.NewProc("GetMessageW")
	uiwTranslateMessage    = uiwUser32.NewProc("TranslateMessage")
	uiwDispatchMessage     = uiwUser32.NewProc("DispatchMessageW")
	uiwPostMessage         = uiwUser32.NewProc("PostMessageW")
	uiwSendMessage         = uiwUser32.NewProc("SendMessageW")
	uiwPostQuitMessage     = uiwUser32.NewProc("PostQuitMessage")
	uiwBeginPaint          = uiwUser32.NewProc("BeginPaint")
	uiwEndPaint            = uiwUser32.NewProc("EndPaint")
	uiwInvalidateRect      = uiwUser32.NewProc("InvalidateRect")
	uiwGetClientRect       = uiwUser32.NewProc("GetClientRect")
	uiwLoadCursor          = uiwUser32.NewProc("LoadCursorW")
	uiwSetCursor           = uiwUser32.NewProc("SetCursor")
	uiwSetCapture          = uiwUser32.NewProc("SetCapture")
	uiwReleaseCapture      = uiwUser32.NewProc("ReleaseCapture")
	uiwTrackMouseEvent     = uiwUser32.NewProc("TrackMouseEvent")
	uiwSetTimer            = uiwUser32.NewProc("SetTimer")
	uiwKillTimer           = uiwUser32.NewProc("KillTimer")
	uiwGetKeyState         = uiwUser32.NewProc("GetKeyState")
	uiwScreenToClient      = uiwUser32.NewProc("ScreenToClient")
	uiwSetWindowPos        = uiwUser32.NewProc("SetWindowPos")
	uiwGetDpiForWindow     = uiwUser32.NewProc("GetDpiForWindow")
	uiwGetDpiForSystem     = uiwUser32.NewProc("GetDpiForSystem")
	uiwSetDpiAwareness     = uiwUser32.NewProc("SetProcessDpiAwarenessContext")
	uiwOpenClipboard       = uiwUser32.NewProc("OpenClipboard")
	uiwCloseClipboard      = uiwUser32.NewProc("CloseClipboard")
	uiwEmptyClipboard      = uiwUser32.NewProc("EmptyClipboard")
	uiwGetClipboardData    = uiwUser32.NewProc("GetClipboardData")
	uiwSetClipboardData    = uiwUser32.NewProc("SetClipboardData")
	uiwCreateIconFromBytes = uiwUser32.NewProc("CreateIconFromResourceEx")
	uiwDestroyIcon         = uiwUser32.NewProc("DestroyIcon")
	uiwClipCursor          = uiwUser32.NewProc("ClipCursor")
	uiwSetCursorPos        = uiwUser32.NewProc("SetCursorPos")
	uiwClientToScreen      = uiwUser32.NewProc("ClientToScreen")

	uiwCreateCompatibleDC = uiwGdi32.NewProc("CreateCompatibleDC")
	uiwCreateDIBSection   = uiwGdi32.NewProc("CreateDIBSection")
	uiwSelectObject       = uiwGdi32.NewProc("SelectObject")
	uiwDeleteObject       = uiwGdi32.NewProc("DeleteObject")
	uiwDeleteDC           = uiwGdi32.NewProc("DeleteDC")
	uiwBitBlt             = uiwGdi32.NewProc("BitBlt")
	uiwCreateFont         = uiwGdi32.NewProc("CreateFontW")
	uiwGetTextExtent      = uiwGdi32.NewProc("GetTextExtentPoint32W")
	uiwGetTextMetrics     = uiwGdi32.NewProc("GetTextMetricsW")
	uiwGetGlyphIndices    = uiwGdi32.NewProc("GetGlyphIndicesW")
	uiwExtTextOut         = uiwGdi32.NewProc("ExtTextOutW")
	uiwSetTextColor       = uiwGdi32.NewProc("SetTextColor")
	uiwSetBkMode          = uiwGdi32.NewProc("SetBkMode")
	uiwGdiFlush           = uiwGdi32.NewProc("GdiFlush")
	uiwGetStockObject     = uiwGdi32.NewProc("GetStockObject")

	uiwGetModuleHandle = uiwKernel32.NewProc("GetModuleHandleW")
	uiwGlobalAlloc     = uiwKernel32.NewProc("GlobalAlloc")
	uiwGlobalLock      = uiwKernel32.NewProc("GlobalLock")
	uiwGlobalUnlock    = uiwKernel32.NewProc("GlobalUnlock")
	uiwGetLocaleInfoEx = uiwKernel32.NewProc("GetLocaleInfoEx")

	uiwDwmSetWindowAttribute = uiwDwmapi.NewProc("DwmSetWindowAttribute")
	uiwDwmFlush              = uiwDwmapi.NewProc("DwmFlush")
	uiwRegGetValue           = uiwAdvapi32.NewProc("RegGetValueW")

	uiwImmGetContext           = uiwImm32.NewProc("ImmGetContext")
	uiwImmReleaseContext       = uiwImm32.NewProc("ImmReleaseContext")
	uiwImmSetCompositionWindow = uiwImm32.NewProc("ImmSetCompositionWindow")
)

const (
	uiwWmCreate        = 0x0001
	uiwWmDestroy       = 0x0002
	uiwWmSize          = 0x0005
	uiwWmSetFocus      = 0x0007
	uiwWmKillFocus     = 0x0008
	uiwWmPaint         = 0x000F
	uiwWmClose         = 0x0010
	uiwWmEraseBkgnd    = 0x0014
	uiwWmSettingChange = 0x001A
	uiwWmSetCursor     = 0x0020
	uiwWmNcCreate      = 0x0081
	uiwWmKeyDown       = 0x0100
	uiwWmChar          = 0x0102
	uiwWmKeyUp         = 0x0101
	uiwWmSysKeyDown    = 0x0104
	uiwWmImeStart      = 0x010D
	uiwWmTimer         = 0x0113
	uiwWmMouseMove     = 0x0200
	uiwWmLButtonDown   = 0x0201
	uiwWmLButtonUp     = 0x0202
	uiwWmRButtonUp     = 0x0205
	uiwWmMButtonUp     = 0x0208
	uiwWmMouseWheel    = 0x020A
	uiwWmMouseHWheel   = 0x020E
	uiwWmMouseLeave    = 0x02A3
	uiwWmDpiChanged    = 0x02E0
	uiwWmSetIcon       = 0x0080
	uiwWmAppView       = 0x8001
	uiwWmAppTick       = 0x8002
	uiwWmSysKeyUp      = 0x0105
	uiwWmRButtonDown   = 0x0204
	uiwWmMButtonDown   = 0x0207
	uiwWsOverlapped    = 0x00CF0000
	uiwCwUseDefault    = 0x80000000
	uiwTransparent     = 1
	uiwEtoClipped      = 4
	uiwCfUnicodeText   = 13
	uiwBlinkTimer      = 1
	uiwFrameTimer      = 2
)

type uiwRect struct{ left, top, right, bottom int32 }
type uiwPoint struct{ x, y int32 }

type uiwClass struct {
	size      uint32
	style     uint32
	proc      uintptr
	clsExtra  int32
	wndExtra  int32
	instance  uintptr
	icon      uintptr
	cursor    uintptr
	brush     uintptr
	menu      *uint16
	name      *uint16
	iconSmall uintptr
}

type uiwMsg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      uiwPoint
	private uint32
}

type uiwPaint struct {
	hdc       uintptr
	erase     int32
	paint     uiwRect
	restore   int32
	incUpdate int32
	reserved  [32]byte
}

type uiwBitmapInfo struct {
	size         uint32
	width        int32
	height       int32
	planes       uint16
	bitCount     uint16
	compression  uint32
	sizeImage    uint32
	xPels        int32
	yPels        int32
	clrUsed      uint32
	clrImportant uint32
	colours      [1]uint32
}

type uiwTextMetric struct {
	height, ascent, descent, internalLeading, externalLeading int32
	aveCharWidth, maxCharWidth, weight, overhang              int32
	aspectX, aspectY                                          int32
	firstChar, lastChar, defaultChar, breakChar               uint16
	italic, underlined, struckOut, pitchAndFamily, charSet    byte
}

type uiwTrack struct {
	size  uint32
	flags uint32
	hwnd  uintptr
	hover uint32
}

type uiwComposition struct {
	style uint32
	at    uiwPoint
	area  uiwRect
}

type uiwCreate struct {
	params uintptr
}

func uiwCall(p *syscall.LazyProc, args ...uintptr) uintptr {
	r, _, _ := p.Call(args...)
	return r
}

func uiwText(s string) []uint16 {
	u, err := syscall.UTF16FromString(s)
	if err != nil {
		u, _ = syscall.UTF16FromString("")
	}
	return u
}

func uiwAt(p uintptr) unsafe.Pointer { return *(*unsafe.Pointer)(unsafe.Pointer(&p)) }

var (
	uiwWindows  sync.Map
	uiwOpening  sync.Map
	uiwSerial   uintptr
	uiwSetup    sync.Once
	uiwClassErr error
	uiwProcPtr  uintptr
	uiwClassNm  = uiwText("HiveWindow")
)

type uiwMetrics struct {
	tall, ascent, average float64
}

type uiwWindow struct {
	n        *uiNative
	mu       sync.Mutex
	hwnd     uintptr
	dc       uintptr
	bitmap   uintptr
	bits     unsafe.Pointer
	bw, bh   int
	fonts    map[uiFont]uintptr
	metrics  map[uiFont]uiwMetrics
	selected uintptr
	dirtyGdi bool
	tracking bool
	active   bool
	high     uint16
	icons    []uintptr
	dark     bool
	title    string
	swallow  bool
	msg      uiwMsg

	grabbed bool
	centre  uiwPoint
	ticks   chan struct{}
	ticked  atomic.Bool
	padHere [4]bool
	padBeat int
}

func (w *uiwWindow) show(v UiView) {
	if !w.n.publish(v) {
		return
	}
	w.mu.Lock()
	hwnd := w.hwnd
	w.mu.Unlock()
	if hwnd != 0 {
		uiwCall(uiwPostMessage, hwnd, uiwWmAppView, 0, 0)
	}
}

func (w *uiwWindow) last() UiView { return w.n.latest() }

func (w *uiwWindow) open(title string, addr SyslinkAddress) bool {
	if uiStageReady != nil && !uiStageReady() {
		return false
	}
	w.n.addr = addr
	opened := make(chan bool, 1)
	go w.run(title, opened)
	if !<-opened {
		return false
	}
	Hold()
	return true
}

func (w *uiwWindow) run(title string, opened chan bool) {
	runtime.LockOSThread()
	uiwSetup.Do(uiwRegister)
	if uiwClassErr != nil {
		opened <- false
		return
	}
	instance := uiwCall(uiwGetModuleHandle, 0)
	dpi := 96.0
	if uiwGetDpiForSystem.Find() == nil {
		dpi = float64(uiwCall(uiwGetDpiForSystem))
	}
	id := w.register()
	w.title = title
	name := uiwText(title)
	hwnd := uiwCall(uiwCreateWindowEx, 0,
		uintptr(unsafe.Pointer(&uiwClassNm[0])), uintptr(unsafe.Pointer(&name[0])),
		uiwWsOverlapped, uiwCwUseDefault, uiwCwUseDefault,
		uintptr(math.Round(1100*dpi/96)), uintptr(math.Round(780*dpi/96)),
		0, 0, instance, id)
	uiwOpening.Delete(id)
	if hwnd == 0 {
		opened <- false
		return
	}
	w.n.wake = func() { uiwCall(uiwPostMessage, hwnd, uiwWmAppView, 0, 0) }
	w.linkIcon()
	w.restyle()
	uiwCall(uiwShowWindow, hwnd, 1)
	uiwCall(uiwUpdateWindow, hwnd)
	uiwCall(uiwSetTimer, hwnd, uiwBlinkTimer, 530, 0)
	opened <- true
	msg := &w.msg
	for {
		got := int32(uiwCall(uiwGetMessage, uintptr(unsafe.Pointer(msg)), 0, 0, 0))
		if got <= 0 {
			return
		}
		uiwCall(uiwTranslateMessage, uintptr(unsafe.Pointer(msg)))
		uiwCall(uiwDispatchMessage, uintptr(unsafe.Pointer(msg)))
	}
}

func (w *uiwWindow) register() uintptr {
	id := atomic.AddUintptr(&uiwSerial, 1)
	uiwOpening.Store(id, w)
	return id
}

func uiwRegister() {
	if uiwSetDpiAwareness.Find() == nil {
		uiwCall(uiwSetDpiAwareness, ^uintptr(3))
	}
	uiwProcPtr = syscall.NewCallback(uiwProc)
	class := uiwClass{
		proc:     uiwProcPtr,
		instance: uiwCall(uiwGetModuleHandle, 0),
		cursor:   uiwCall(uiwLoadCursor, 0, 32512),
		name:     &uiwClassNm[0],
	}
	class.size = uint32(unsafe.Sizeof(class))
	if uiwCall(uiwRegisterClassEx, uintptr(unsafe.Pointer(&class))) == 0 {
		uiwClassErr = fmt.Errorf("the window class could not be registered")
	}
}

func uiwProc(hwnd, msg, wp, lp uintptr) uintptr {
	if msg == uiwWmNcCreate {
		id := (*uiwCreate)(uiwAt(lp)).params
		if found, ok := uiwOpening.Load(id); ok {
			w := found.(*uiwWindow)
			w.mu.Lock()
			w.hwnd = hwnd
			w.mu.Unlock()
			uiwWindows.Store(hwnd, w)
		}
	}
	if found, ok := uiwWindows.Load(hwnd); ok {
		w := found.(*uiwWindow)
		if answer, mine := w.uiaHandle(msg, wp, lp); mine {
			return answer
		}
		answer, handled := w.handle(msg, wp, lp)
		w.uiaNotice()
		if handled {
			return answer
		}
	}
	return uiwCall(uiwDefWindowProc, hwnd, msg, wp, lp)
}

func uiwLow(v uintptr) int  { return int(int16(uint16(v))) }
func uiwHigh(v uintptr) int { return int(int16(uint16(v >> 16))) }

func uiwHeld(vk uintptr) bool { return int16(uiwCall(uiwGetKeyState, vk)) < 0 }

func (w *uiwWindow) handle(msg, wp, lp uintptr) (uintptr, bool) {
	n := w.n
	switch msg {
	case uiwWmCreate:
		w.dc = uiwCall(uiwCreateCompatibleDC, 0)
		w.fonts = map[uiFont]uintptr{}
		w.metrics = map[uiFont]uiwMetrics{}
		n.dev = w
		n.adopt()
		w.retitle()
		return 0, true
	case uiwWmPaint:
		var ps uiwPaint
		hdc := uiwCall(uiwBeginPaint, w.hwnd, uintptr(unsafe.Pointer(&ps)))
		area := uiClip{int(ps.paint.left), int(ps.paint.top), int(ps.paint.right), int(ps.paint.bottom)}
		w.render(area)
		if w.bitmap != 0 {
			uiwCall(uiwBitBlt, hdc, uintptr(area.x0), uintptr(area.y0), uintptr(area.x1-area.x0), uintptr(area.y1-area.y0),
				w.dc, uintptr(area.x0), uintptr(area.y0), 0x00CC0020)
		}
		uiwCall(uiwEndPaint, w.hwnd, uintptr(unsafe.Pointer(&ps)))
		if due := n.frameDue(); due > 0 {
			uiwCall(uiwSetTimer, w.hwnd, uiwFrameTimer, uintptr(max(due.Milliseconds(), 1)), 0)
		}
		return 0, true
	case uiwWmEraseBkgnd:
		return 1, true
	case uiwWmSize:
		if w.grabbed {
			w.grabbed = false
			w.holding(true)
		}
		w.invalidate()
		return 0, true
	case uiwWmAppView:
		n.adopt()
		w.retitle()
		if n.staged() {
			w.invalidate()
		}
		return 0, true
	case uiwWmAppTick:
		w.ticked.Store(false)
		if n.stage != nil {
			n.stage.tick()
		}
		return 0, true
	case uiwWmDpiChanged:
		r := (*uiwRect)(uiwAt(lp))
		uiwCall(uiwSetWindowPos, w.hwnd, 0, uintptr(r.left), uintptr(r.top),
			uintptr(r.right-r.left), uintptr(r.bottom-r.top), 0x0014)
		w.dropFonts()
		w.invalidate()
		return 0, true
	case uiwWmSettingChange:
		w.restyle()
		w.invalidate()
		return 0, false
	case uiwWmSetCursor:
		if uiwLow(lp) != 1 {
			return 0, false
		}
		var shape uintptr = 32512
		switch n.cursor(n.pointer[0]*n.scale, n.pointer[1]*n.scale) {
		case "none":
			uiwCall(uiwSetCursor, 0)
			return 1, true
		case "text":
			shape = 32513
		case "hand":
			shape = 32649
		case "resize":
			shape = 32645
		case "cols":
			shape = 32644
		}
		uiwCall(uiwSetCursor, uiwCall(uiwLoadCursor, 0, shape))
		return 1, true
	case uiwWmMouseMove:
		if !w.tracking {
			track := uiwTrack{flags: 2, hwnd: w.hwnd}
			track.size = uint32(unsafe.Sizeof(track))
			uiwCall(uiwTrackMouseEvent, uintptr(unsafe.Pointer(&track)))
			w.tracking = true
		}
		if w.grabbed {
			dx, dy := uiwLow(lp)-int(w.centre.x), uiwHigh(lp)-int(w.centre.y)
			if (dx != 0 || dy != 0) && n.stage != nil {
				n.stage.looked(float64(dx)/n.scale, float64(dy)/n.scale)
				w.recentre()
			}
			return 0, true
		}
		if n.stage != nil {
			n.stage.drag(float64(uiwLow(lp))/n.scale, float64(uiwHigh(lp))/n.scale)
		}
		n.ctrl = wp&0x0008 != 0
		if n.move(float64(uiwLow(lp)), float64(uiwHigh(lp))) {
			w.invalidate()
		}
		return 0, true
	case uiwWmKeyUp, uiwWmSysKeyUp:
		if n.stage != nil {
			n.stage.key(w.sceneKey(wp), false)
		}
		if wp == 0x11 && n.setCtrl(false) {
			w.invalidate()
		}
		return 0, false
	case uiwWmMouseLeave:
		w.tracking = false
		if n.leave() {
			w.invalidate()
		}
		return 0, true
	case uiwWmMButtonDown, uiwWmRButtonDown:
		button := 3
		if msg == uiwWmMButtonDown {
			button = 2
		}
		if n.stage != nil && n.stage.press(button, float64(uiwLow(lp))/n.scale, float64(uiwHigh(lp))/n.scale) {
			return 0, true
		}
		return 0, false
	case uiwWmMButtonUp:
		if n.stage != nil && n.stage.lift(2) {
			return 0, true
		}
		if n.middle(float64(uiwLow(lp)), float64(uiwHigh(lp))) {
			w.invalidate()
		}
		return 0, true
	case uiwWmLButtonDown:
		if n.stage != nil && n.stage.press(1, float64(uiwLow(lp))/n.scale, float64(uiwHigh(lp))/n.scale) {
			if !w.grabbed {
				uiwCall(uiwSetCapture, w.hwnd)
			}
			return 0, true
		}
		uiwCall(uiwSetCapture, w.hwnd)
		n.ctrl = wp&0x0008 != 0
		if n.down(float64(uiwLow(lp)), float64(uiwHigh(lp))) {
			w.invalidate()
		}
		return 0, true
	case uiwWmLButtonUp:
		if n.stage != nil && n.stage.lift(1) {
			if !w.grabbed {
				uiwCall(uiwReleaseCapture)
			}
			return 0, true
		}
		uiwCall(uiwReleaseCapture)
		if n.up(float64(uiwLow(lp)), float64(uiwHigh(lp))) {
			w.invalidate()
		}
		return 0, true
	case uiwWmRButtonUp:
		if n.stage != nil && n.stage.lift(3) {
			return 0, true
		}
		if n.menu(float64(uiwLow(lp)), float64(uiwHigh(lp))) {
			w.invalidate()
		}
		return 0, true
	case uiwWmMouseWheel, uiwWmMouseHWheel:
		at := uiwPoint{int32(uiwLow(lp)), int32(uiwHigh(lp))}
		uiwCall(uiwScreenToClient, w.hwnd, uintptr(unsafe.Pointer(&at)))
		lines := float64(uiwHigh(wp)) / 120
		sideways := msg == uiwWmMouseHWheel || uiwHeld(0x10)
		if msg == uiwWmMouseHWheel {
			lines = -lines
		}
		if n.wheel(float64(at.x), float64(at.y), lines, sideways) {
			w.invalidate()
		}
		return 0, true
	case uiwWmKeyDown, uiwWmSysKeyDown:
		w.swallow = false
		if n.stage != nil && n.stage.key(w.sceneKey(wp), true) {
			w.swallow = true
			return 0, true
		}
		if wp == 0x11 {
			if n.setCtrl(true) {
				w.invalidate()
			}
			return 0, false
		}
		if n.claim(w.named(wp)) {
			w.swallow = true
			w.invalidate()
			return 0, true
		}
		if msg == uiwWmSysKeyDown {
			return 0, false
		}
		if w.key(wp) {
			w.invalidate()
			return 0, true
		}
		return 0, false
	case uiwWmChar:
		if w.swallow {
			w.swallow = false
			return 0, true
		}
		if unit := rune(wp); unit > 0x20 && unit < 0xD800 && unit != 0x7F && n.claim(string(unit)) {
			w.invalidate()
			return 0, true
		}
		unit := uint16(wp)
		var r rune
		switch {
		case unit >= 0xD800 && unit < 0xDC00:
			w.high = unit
			return 0, true
		case unit >= 0xDC00 && unit < 0xE000:
			r = (rune(w.high)-0xD800)<<10 + (rune(unit) - 0xDC00) + 0x10000
			w.high = 0
		default:
			r = rune(unit)
		}
		if n.typed(r) {
			w.invalidate()
		}
		return 0, true
	case uiwWmImeStart:
		if x, y, ok := n.caretSpot(); ok {
			ctx := uiwCall(uiwImmGetContext, w.hwnd)
			form := uiwComposition{style: 2, at: uiwPoint{int32(x), int32(y)}}
			uiwCall(uiwImmSetCompositionWindow, ctx, uintptr(unsafe.Pointer(&form)))
			uiwCall(uiwImmReleaseContext, w.hwnd, ctx)
		}
		return 0, false
	case uiwWmTimer:
		if wp == uiwFrameTimer {
			uiwCall(uiwKillTimer, w.hwnd, uiwFrameTimer)
			if area := n.moving(); area.empty() {
				w.invalidate()
			} else {
				r := uiwRect{int32(area.x0), int32(area.y0), int32(area.x1), int32(area.y1)}
				uiwCall(uiwInvalidateRect, w.hwnd, uintptr(unsafe.Pointer(&r)), 0)
			}
			return 0, true
		}
		if n.typing() {
			n.blink = w.active && !n.blink
			w.invalidate()
		}
		return 0, true
	case uiwWmKillFocus:
		if n.stage != nil {
			n.stage.blur()
		}
		w.active = false
		n.blink = false
		n.unfocused()
		w.invalidate()
		return 0, false
	case uiwWmSetFocus:
		w.active = true
		n.blink = true
		w.invalidate()
		return 0, false
	case uiwWmClose:
		return 0, false
	case uiwWmDestroy:
		w.closed()
		return 0, true
	}
	return 0, false
}

var uiwNamed = map[uintptr]string{
	0x08: "Backspace", 0x09: "Tab", 0x0D: "Enter", 0x1B: "Escape", 0x20: "Space",
	0x21: "PageUp", 0x22: "PageDown", 0x23: "End", 0x24: "Home",
	0x25: "ArrowLeft", 0x26: "ArrowUp", 0x27: "ArrowRight", 0x28: "ArrowDown",
	0x2D: "Insert", 0x2E: "Delete",
}

func (w *uiwWindow) named(vk uintptr) string {
	ctrl, shift, alt := uiwHeld(0x11), uiwHeld(0x10), uiwHeld(0x12)
	if name, ok := uiwNamed[vk]; ok {
		return uiCombo(name, ctrl, shift, alt)
	}
	if vk >= 0x70 && vk <= 0x7B {
		return uiCombo("F"+strconv.Itoa(int(vk-0x6F)), ctrl, shift, alt)
	}
	if !ctrl && !alt {
		return ""
	}
	r := rune(uiwCall(uiwMapVirtualKey, vk, 2) & 0x7FFFFFFF)
	if r <= 0x20 {
		return ""
	}
	return uiCombo(strings.ToUpper(string(r)), ctrl, shift, alt)
}

func (w *uiwWindow) key(vk uintptr) bool {
	shift, ctrl := uiwHeld(0x10), uiwHeld(0x11)
	k := uiKeyNone
	switch vk {
	case 0x08:
		k = uiKeyBack
	case 0x09:
		k = uiKeyTab
	case 0x0D:
		k = uiKeyEnter
	case 0x1B:
		k = uiKeyEscape
	case 0x21:
		k = uiKeyPageUp
	case 0x22:
		k = uiKeyPageDown
	case 0x23:
		k = uiKeyEnd
	case 0x24:
		k = uiKeyHome
	case 0x25:
		k = uiKeyLeft
	case 0x26:
		k = uiKeyUp
	case 0x27:
		k = uiKeyRight
	case 0x28:
		k = uiKeyDown
	case 0x2E:
		k = uiKeyDelete
	case 0x41:
		if ctrl {
			k = uiKeyAll
		}
	case 0x43:
		if ctrl {
			k = uiKeyCopy
		}
	case 0x56:
		if ctrl {
			k = uiKeyPaste
		}
	case 0x58:
		if ctrl {
			k = uiKeyCut
		}
	case 0x59:
		if ctrl {
			k = uiKeyRedo
		}
	case 0x5A:
		if ctrl && shift {
			k = uiKeyRedo
		} else if ctrl {
			k = uiKeyUndo
		}
	case 0x5D:
		k = uiKeyMenu
	case 0x79:
		if shift {
			k = uiKeyMenu
		}
	}
	if k == uiKeyNone {
		return false
	}
	return w.n.key(k, shift, ctrl)
}

func (w *uiwWindow) invalidate() { uiwCall(uiwInvalidateRect, w.hwnd, 0, 0) }

func (w *uiwWindow) retitle() {
	title := uiTitleOf(w.n.latest())
	if title == "" || title == w.title {
		return
	}
	w.title = title
	name := uiwText(title)
	uiwCall(uiwSetWindowText, w.hwnd, uintptr(unsafe.Pointer(&name[0])))
}

func (w *uiwWindow) scale() float64 {
	if uiwGetDpiForWindow.Find() != nil {
		return 1
	}
	dpi := uiwCall(uiwGetDpiForWindow, w.hwnd)
	if dpi == 0 {
		return 1
	}
	return float64(dpi) / 96
}

func (w *uiwWindow) render(area uiClip) {
	var r uiwRect
	uiwCall(uiwGetClientRect, w.hwnd, uintptr(unsafe.Pointer(&r)))
	bw, bh := int(r.right-r.left), int(r.bottom-r.top)
	if bw <= 0 || bh <= 0 {
		return
	}
	if bw != w.bw || bh != w.bh || w.bitmap == 0 {
		w.surface(bw, bh)
		area = uiClip{}
	}
	if w.bitmap == 0 {
		return
	}
	s := w.scale()
	w.n.resize(float64(bw)/s, float64(bh)/s, s)
	canvas := &uiCanvas{
		pix:   unsafe.Slice((*uint32)(w.bits), bw*bh),
		w:     bw,
		h:     bh,
		flush: w.flushGdi,
		dirty: area,
	}
	w.n.paint(canvas)
	w.flushGdi()
}

func (w *uiwWindow) surface(bw, bh int) {
	info := uiwBitmapInfo{width: int32(bw), height: -int32(bh), planes: 1, bitCount: 32}
	info.size = 40
	var bits uintptr
	bitmap := uiwCall(uiwCreateDIBSection, w.dc, uintptr(unsafe.Pointer(&info)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bitmap == 0 {
		return
	}
	old := uiwCall(uiwSelectObject, w.dc, bitmap)
	if w.bitmap != 0 {
		uiwCall(uiwDeleteObject, old)
	}
	w.bitmap, w.bits, w.bw, w.bh = bitmap, uiwAt(bits), bw, bh
}

func (w *uiwWindow) flushGdi() {
	if w.dirtyGdi {
		uiwCall(uiwGdiFlush)
		w.dirtyGdi = false
	}
}

func (w *uiwWindow) font(f uiFont) uintptr {
	if h, ok := w.fonts[f]; ok {
		return h
	}
	face, weight := "Segoe UI", f.weight
	if f.weight == 600 {
		face, weight = "Segoe UI Semibold", 400
	}
	if f.icon {
		face = "Segoe UI Symbol"
	}
	if f.mono {
		face = "Consolas"
	}
	name := uiwText(face)
	px := int32(-math.Round(f.px * w.n.scale))
	h := uiwCall(uiwCreateFont, uintptr(px), 0, 0, 0, uintptr(weight), 0, 0, 0, 1, 0, 0, 5, 0,
		uintptr(unsafe.Pointer(&name[0])))
	w.fonts[f] = h
	return h
}

func (w *uiwWindow) dropFonts() {
	uiwCall(uiwSelectObject, w.dc, uiwCall(uiwGetStockObject, 17))
	for _, h := range w.fonts {
		uiwCall(uiwDeleteObject, h)
	}
	w.fonts = map[uiFont]uintptr{}
	w.metrics = map[uiFont]uiwMetrics{}
	w.selected = 0
}

func (w *uiwWindow) use(f uiFont) {
	h := w.font(f)
	if h != w.selected {
		uiwCall(uiwSelectObject, w.dc, h)
		w.selected = h
	}
}

func (w *uiwWindow) face(f uiFont, s string) uiFont {
	if f.icon && w.has(uiFont{px: f.px, weight: f.weight}, s) {
		return uiFont{px: f.px, weight: f.weight}
	}
	return f
}

func (w *uiwWindow) measure(f uiFont, s string) float64 {
	f = w.face(f, s)
	w.use(f)
	u := uiwText(s)
	var size [2]int32
	uiwCall(uiwGetTextExtent, w.dc, uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&size)))
	return float64(size[0]) / w.n.scale
}

func (w *uiwWindow) metric(f uiFont) uiwMetrics {
	if m, ok := w.metrics[f]; ok {
		return m
	}
	w.use(f)
	var tm uiwTextMetric
	uiwCall(uiwGetTextMetrics, w.dc, uintptr(unsafe.Pointer(&tm)))
	m := uiwMetrics{
		tall:    float64(tm.height) / w.n.scale,
		ascent:  float64(tm.ascent),
		average: float64(tm.aveCharWidth) / w.n.scale,
	}
	w.metrics[f] = m
	return m
}

func (w *uiwWindow) tall(f uiFont) float64    { return w.metric(uiFont{px: f.px, weight: f.weight}).tall }
func (w *uiwWindow) average(f uiFont) float64 { return w.metric(f).average }

func (w *uiwWindow) text(f uiFont, x, y int, s string, c uiRGBA, clip uiClip) {
	if s == "" || clip.empty() {
		return
	}
	if g := w.face(f, s); g.icon {
		text := uiFont{px: f.px, weight: f.weight}
		y += int(math.Round(w.metric(text).ascent - w.metric(g).ascent))
		f = g
	} else {
		f = g
	}
	w.use(f)
	u := uiwText(s)
	box := uiwRect{int32(clip.x0), int32(clip.y0), int32(clip.x1), int32(clip.y1)}
	uiwCall(uiwSetBkMode, w.dc, uiwTransparent)
	uiwCall(uiwSetTextColor, w.dc, uintptr(c.r)|uintptr(c.g)<<8|uintptr(c.b)<<16)
	uiwCall(uiwExtTextOut, w.dc, uintptr(x), uintptr(y), uiwEtoClipped, uintptr(unsafe.Pointer(&box)),
		uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), 0)
	w.dirtyGdi = true
}

func (w *uiwWindow) has(f uiFont, s string) bool {
	w.use(f)
	u := uiwText(s)
	glyphs := make([]uint16, len(u))
	uiwCall(uiwGetGlyphIndices, w.dc, uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1),
		uintptr(unsafe.Pointer(&glyphs[0])), 1)
	for _, g := range glyphs[:len(u)-1] {
		if g == 0xFFFF {
			return false
		}
	}
	return true
}

func (w *uiwWindow) clipboard() string {
	if uiwCall(uiwOpenClipboard, w.hwnd) == 0 {
		return ""
	}
	defer uiwCall(uiwCloseClipboard)
	h := uiwCall(uiwGetClipboardData, uiwCfUnicodeText)
	if h == 0 {
		return ""
	}
	p := uiwCall(uiwGlobalLock, h)
	if p == 0 {
		return ""
	}
	defer uiwCall(uiwGlobalUnlock, h)
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

func (w *uiwWindow) setClipboard(s string) {
	if uiwCall(uiwOpenClipboard, w.hwnd) == 0 {
		return
	}
	defer uiwCall(uiwCloseClipboard)
	uiwCall(uiwEmptyClipboard)
	u := uiwText(s)
	h := uiwCall(uiwGlobalAlloc, 2, uintptr(len(u)*2))
	if h == 0 {
		return
	}
	p := uiwCall(uiwGlobalLock, h)
	copy(unsafe.Slice((*uint16)(uiwAt(p)), len(u)), u)
	uiwCall(uiwGlobalUnlock, h)
	uiwCall(uiwSetClipboardData, uiwCfUnicodeText, h)
}

func (w *uiwWindow) datePattern() string {
	buf := make([]uint16, 80)
	if uiwGetLocaleInfoEx.Find() != nil || uiwCall(uiwGetLocaleInfoEx, 0, 0x1F, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf))) == 0 {
		return "MM/dd/yyyy"
	}
	return syscall.UTF16ToString(buf)
}

func (w *uiwWindow) openLink(href string) {
	exec.Command("rundll32", "url.dll,FileProtocolHandler", href).Start()
}

func (w *uiwWindow) restyle() {
	dark := false
	key := uiwText("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")
	value := uiwText("AppsUseLightTheme")
	var light, size uint32 = 1, 4
	if uiwRegGetValue.Find() == nil {
		status := uiwCall(uiwRegGetValue, 0x80000001, uintptr(unsafe.Pointer(&key[0])), uintptr(unsafe.Pointer(&value[0])),
			0x10, 0, uintptr(unsafe.Pointer(&light)), uintptr(unsafe.Pointer(&size)))
		dark = status == 0 && light == 0
	}
	w.n.theme(dark)
	if uiwDwmSetWindowAttribute.Find() == nil {
		on := uint32(0)
		if dark {
			on = 1
		}
		uiwCall(uiwDwmSetWindowAttribute, w.hwnd, 20, uintptr(unsafe.Pointer(&on)), 4)
	}
}

func (w *uiwWindow) linkIcon() {
	for which, size := range []float64{16, 32} {
		side := int(math.Round(size * w.scale()))
		image := uiWindowIcon
		if len(image) == 0 {
			image = uiwMark(side)
		}
		icon := uiwCall(uiwCreateIconFromBytes, uintptr(unsafe.Pointer(&image[0])), uintptr(len(image)),
			1, 0x00030000, uintptr(side), uintptr(side), 0)
		if icon != 0 {
			uiwCall(uiwSendMessage, w.hwnd, uiwWmSetIcon, uintptr(which), icon)
			w.icons = append(w.icons, icon)
		}
	}
}

func uiwMark(side int) []byte {
	corners := [][2]float64{{12, 1.5}, {21, 6.75}, {21, 17.25}, {12, 22.5}, {3, 17.25}, {3, 6.75}}
	inside := func(x, y float64) bool {
		for i := range corners {
			a, b := corners[i], corners[(i+1)%len(corners)]
			if (b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0]) < 0 {
				return false
			}
		}
		return true
	}
	var out []byte
	word := func(v uint32) { out = append(out, byte(v), byte(v>>8), byte(v>>16), byte(v>>24)) }
	half := func(v uint16) { out = append(out, byte(v), byte(v>>8)) }
	word(40)
	word(uint32(side))
	word(uint32(2 * side))
	half(1)
	half(32)
	for i := 0; i < 6; i++ {
		word(0)
	}
	scale := 24 / float64(side)
	for y := side - 1; y >= 0; y-- {
		for x := 0; x < side; x++ {
			hits := 0
			for sy := 0; sy < 4; sy++ {
				for sx := 0; sx < 4; sx++ {
					if inside((float64(x)+(float64(sx)+0.5)/4)*scale, (float64(y)+(float64(sy)+0.5)/4)*scale) {
						hits++
					}
				}
			}
			out = append(out, 0x29, 0xb4, 0xf0, byte(hits*255/16))
		}
	}
	return append(out, make([]byte, side*((side+31)/32*4))...)
}

var uiwSceneKeys = map[uintptr]string{
	0x08: "backspace", 0x09: "tab", 0x0D: "enter", 0x10: "shift", 0x11: "ctrl", 0x12: "alt", 0x13: "pause",
	0x14: "capslock", 0x1B: "escape", 0x20: "space", 0x21: "pageup", 0x22: "pagedown", 0x23: "end", 0x24: "home",
	0x25: "left", 0x26: "up", 0x27: "right", 0x28: "down", 0x2C: "printscreen", 0x2D: "insert", 0x2E: "delete",
	0x5B: "meta", 0x5C: "meta", 0x5D: "contextmenu", 0x6A: "*", 0x6B: "+", 0x6D: "-", 0x6E: ".", 0x6F: "/",
	0x90: "numlock", 0x91: "scrolllock",
}

func (w *uiwWindow) sceneKey(vk uintptr) string {
	switch {
	case vk >= 0x30 && vk <= 0x39:
		return string(rune(vk))
	case vk >= 0x41 && vk <= 0x5A:
		return string(rune(vk + 32))
	case vk >= 0x60 && vk <= 0x69:
		return string(rune('0' + vk - 0x60))
	case vk >= 0x70 && vk <= 0x87:
		return "f" + strconv.Itoa(int(vk-0x6F))
	}
	if name, ok := uiwSceneKeys[vk]; ok {
		return name
	}
	if r := rune(uiwCall(uiwMapVirtualKey, vk, 2) & 0x7FFF); r > 0x20 {
		return strings.ToLower(string(r))
	}
	return ""
}

func (w *uiwWindow) ticking(on bool) {
	if on == (w.ticks != nil) {
		return
	}
	if !on {
		close(w.ticks)
		w.ticks = nil
		return
	}
	stop := make(chan struct{})
	w.ticks = stop
	hwnd := w.hwnd
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			began := time.Now()
			if uiwDwmFlush.Find() != nil || uiwCall(uiwDwmFlush) != 0 || time.Since(began) < 2*time.Millisecond {
				time.Sleep(8 * time.Millisecond)
			}
			if w.ticked.CompareAndSwap(false, true) {
				uiwCall(uiwPostMessage, hwnd, uiwWmAppTick, 0, 0)
			}
		}
	}()
}

func (w *uiwWindow) recentre() {
	at := w.centre
	uiwCall(uiwClientToScreen, w.hwnd, uintptr(unsafe.Pointer(&at)))
	uiwCall(uiwSetCursorPos, uintptr(at.x), uintptr(at.y))
}

func (w *uiwWindow) holding(on bool) {
	if on == w.grabbed {
		return
	}
	w.grabbed = on
	if !on {
		uiwCall(uiwClipCursor, 0)
		uiwCall(uiwReleaseCapture)
		return
	}
	var r uiwRect
	uiwCall(uiwGetClientRect, w.hwnd, uintptr(unsafe.Pointer(&r)))
	w.centre = uiwPoint{(r.right - r.left) / 2, (r.bottom - r.top) / 2}
	from, to := uiwPoint{0, 0}, uiwPoint{r.right, r.bottom}
	uiwCall(uiwClientToScreen, w.hwnd, uintptr(unsafe.Pointer(&from)))
	uiwCall(uiwClientToScreen, w.hwnd, uintptr(unsafe.Pointer(&to)))
	clip := uiwRect{from.x, from.y, to.x, to.y}
	uiwCall(uiwClipCursor, uintptr(unsafe.Pointer(&clip)))
	uiwCall(uiwSetCapture, w.hwnd)
	w.recentre()
	uiwCall(uiwSetCursor, 0)
}

func (w *uiwWindow) blot(f uiFont, s string) (int, int, []uint8) {
	wide := int(math.Ceil(w.measure(f, s) * w.n.scale))
	tall := int(math.Ceil(w.metric(f).tall * w.n.scale))
	if wide < 1 || tall < 1 {
		return 0, 0, nil
	}
	dc := uiwCall(uiwCreateCompatibleDC, 0)
	info := uiwBitmapInfo{width: int32(wide), height: -int32(tall), planes: 1, bitCount: 32}
	info.size = 40
	var bits uintptr
	bitmap := uiwCall(uiwCreateDIBSection, dc, uintptr(unsafe.Pointer(&info)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bitmap == 0 {
		uiwCall(uiwDeleteDC, dc)
		return 0, 0, nil
	}
	was := uiwCall(uiwSelectObject, dc, bitmap)
	face := uiwCall(uiwSelectObject, dc, w.font(f))
	uiwCall(uiwSetBkMode, dc, uiwTransparent)
	uiwCall(uiwSetTextColor, dc, 0xFFFFFF)
	u := uiwText(s)
	uiwCall(uiwExtTextOut, dc, 0, 0, 0, 0, uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), 0)
	uiwCall(uiwGdiFlush)
	cover := make([]uint8, wide*tall)
	for i, p := range unsafe.Slice((*uint32)(uiwAt(bits)), wide*tall) {
		cover[i] = uint8((p>>16&0xff + p>>8&0xff + p&0xff) / 3)
	}
	uiwCall(uiwSelectObject, dc, face)
	uiwCall(uiwSelectObject, dc, was)
	uiwCall(uiwDeleteObject, bitmap)
	uiwCall(uiwDeleteDC, dc)
	return wide, tall, cover
}

type uiwPadState struct {
	packet         uint32
	buttons        uint16
	lt, rt         uint8
	lx, ly, rx, ry int16
}

var (
	uiwPadOnce sync.Once
	uiwPadRead *syscall.LazyProc
)

var uiwPadButtons = []struct {
	bit  uint16
	name string
}{
	{0x0001, "up"}, {0x0002, "down"}, {0x0004, "left"}, {0x0008, "right"}, {0x0010, "start"}, {0x0020, "back"},
	{0x0040, "lstick"}, {0x0080, "rstick"}, {0x0100, "lb"}, {0x0200, "rb"}, {0x1000, "a"}, {0x2000, "b"},
	{0x4000, "x"}, {0x8000, "y"},
}

func (w *uiwWindow) pads() map[int]uiGamepad {
	uiwPadOnce.Do(func() {
		for _, name := range []string{"xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll"} {
			dll := syscall.NewLazyDLL(name)
			if dll.Load() == nil {
				uiwPadRead = dll.NewProc("XInputGetState")
				return
			}
		}
	})
	out := map[int]uiGamepad{}
	if uiwPadRead == nil {
		return out
	}
	w.padBeat++
	for i := 0; i < 4; i++ {
		if !w.padHere[i] && w.padBeat%60 != i*15 {
			continue
		}
		var st uiwPadState
		w.padHere[i] = uiwCall(uiwPadRead, uintptr(i), uintptr(unsafe.Pointer(&st))) == 0
		if !w.padHere[i] {
			continue
		}
		stick := func(v int16) float64 { return math.Max(-1, float64(v)/32767) }
		c := map[string]float64{
			"leftX": stick(st.lx), "leftY": -stick(st.ly), "rightX": stick(st.rx), "rightY": -stick(st.ry),
			"lt": float64(st.lt) / 255, "rt": float64(st.rt) / 255,
		}
		for _, b := range uiwPadButtons {
			c[b.name] = 0
			if st.buttons&b.bit != 0 {
				c[b.name] = 1
			}
		}
		out[i] = uiGamepad{named: true, controls: c}
	}
	return out
}

func (w *uiwWindow) closed() {
	w.ticking(false)
	w.holding(false)
	if w.n.stage != nil {
		w.n.stage.close()
	}
	uiwCall(uiwKillTimer, w.hwnd, uiwBlinkTimer)
	uiwCall(uiwKillTimer, w.hwnd, uiwFrameTimer)
	uiwWindows.Delete(w.hwnd)
	w.dropFonts()
	if w.bitmap != 0 {
		uiwCall(uiwDeleteObject, w.bitmap)
	}
	uiwCall(uiwDeleteDC, w.dc)
	for _, icon := range w.icons {
		uiwCall(uiwDestroyIcon, icon)
	}
	SyslinkKill(w.n.addr)
	if Release() == 0 {
		fmt.Fprintln(os.Stderr, "hive: the window was closed")
		os.Exit(0)
	}
	uiwCall(uiwPostQuitMessage, 0)
}
