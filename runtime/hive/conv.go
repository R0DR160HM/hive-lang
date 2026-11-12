package hive

import (
	"math"
	"strconv"
)

type ConvConversionError struct {
	Input   string
	Message string
}

func ConvCeil(v float64) int  { return int(math.Ceil(v)) }
func ConvFloor(v float64) int { return int(math.Floor(v)) }

// Round half away from zero, which is the rule a reader expects and not
// the one Go's own printing uses.
func ConvRound(v float64) int {
	if v < 0 {
		return -int(math.Floor(-v + 0.5))
	}
	return int(math.Floor(v + 0.5))
}

func ConvItf(v int) float64          { return float64(v) }
func ConvItf32(v int) float32        { return float32(v) }
func ConvBytesOf(s string) []uint8   { return []uint8(s) }
func ConvFromBytes(b []uint8) string { return string(b) }
func ConvIts(v int) string           { return strconv.Itoa(v) }
func ConvFts(v float64) string       { return strconv.FormatFloat(v, 'g', -1, 64) }

func ConvSti(text string) Result[int, ConvConversionError] {
	n, err := strconv.Atoi(text)
	if err != nil {
		return Err[int, ConvConversionError](ConvConversionError{Input: text, Message: "not a whole number"})
	}
	return Ok[int, ConvConversionError](n)
}

func ConvStf(text string) Result[float64, ConvConversionError] {
	f, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return Err[float64, ConvConversionError](ConvConversionError{Input: text, Message: "not a number"})
	}
	return Ok[float64, ConvConversionError](f)
}
