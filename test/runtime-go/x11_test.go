//go:build linux && !android

package hive

import (
	"bufio"
	"io"
	"testing"
)

type uiLooker struct {
	uiStaging
	x, y float64
}

func (l *uiLooker) looked(dx, dy float64) { l.x, l.y = l.x+dx, l.y+dy }

func uixMotion(x, y int) []byte {
	ev := make([]byte, 32)
	ev[0] = 6
	uixLE.PutUint16(ev[24:], uint16(x))
	uixLE.PutUint16(ev[26:], uint16(y))
	return ev
}

func TestAHeldPointerCountsAMoveOnceHoweverLateTheWarpLands(t *testing.T) {
	n, looked := uiNewNative(), &uiLooker{}
	n.stage = looked
	w := &uixWindow{n: n, c: &uixConn{out: bufio.NewWriter(io.Discard)}, w: 400, h: 300, scale: 1, grabbed: true}
	for _, ev := range [][]byte{uixMotion(200, 150), uixMotion(205, 150), uixMotion(210, 152), uixMotion(215, 152), uixMotion(200, 150)} {
		w.handle(ev)
	}
	if looked.x != 15 || looked.y != 2 {
		t.Errorf("looked %.0f,%.0f for a mouse that moved 15,2", looked.x, looked.y)
	}
}
