package hive

import "math"

// Every one of these takes and answers with a Float, and there is no
// integer twin: Hive never widens a number behind your back.
func MathPi() float64                { return math.Pi }
func MathSin(x float64) float64      { return math.Sin(x) }
func MathCos(x float64) float64      { return math.Cos(x) }
func MathTan(x float64) float64      { return math.Tan(x) }
func MathAsin(x float64) float64     { return math.Asin(x) }
func MathAcos(x float64) float64     { return math.Acos(x) }
func MathAtan2(y, x float64) float64 { return math.Atan2(y, x) }
func MathSqrt(x float64) float64     { return math.Sqrt(x) }
func MathHypot(x, y float64) float64 { return math.Hypot(x, y) }
func MathAbs(x float64) float64      { return math.Abs(x) }
func MathMin(a, b float64) float64   { return math.Min(a, b) }
func MathMax(a, b float64) float64   { return math.Max(a, b) }

// Exactly min(max(value, low), high), so bounds the wrong way round answer
// with high.
func MathClamp(value, low, high float64) float64 {
	return math.Min(math.Max(value, low), high)
}
