package hive

import (
	"strconv"
	"strings"
	"time"
)

func TimeNow() int { return int(time.Now().UnixMilli()) }

func TimeTimezone() string {
	name, _ := time.Now().Zone()
	return name
}

// Minutes east of UTC, so UTC+2 is 120 and UTC-3 is -180.
func TimeTimezoneOffset() int {
	_, offset := time.Now().Zone()
	return offset / 60
}

// Built in local time, so a stamp round-trips with TimeFormat. A field
// out of range carries into the next one the way time.Date does: month
// 13 is January of the year after.
func TimeDateFrom(year, month, day int) int {
	return TimeDateTimeFrom(year, month, day, 0, 0, 0)
}

func TimeDateTimeFrom(year, month, day, hour, minute, second int) int {
	t := time.Date(year, time.Month(month), day, hour, minute, second, 0, time.Local)
	return int(t.UnixMilli())
}

// The fields of the current instant, in local time.
func TimeYear() int { return time.Now().Year() }

func TimeMonth() int { return int(time.Now().Month()) }

func TimeDay() int { return time.Now().Day() }

func TimeHour() int { return time.Now().Hour() }

func TimeMinute() int { return time.Now().Minute() }

func TimeSecond() int { return time.Now().Second() }

func TimeMillisecond() int { return time.Now().Nanosecond() / 1000000 }

// Monday is 1 and Sunday 7, the ISO numbering, where Go counts Sunday 0.
func TimeWeekday() int {
	d := int(time.Now().Weekday())
	if d == 0 {
		return 7
	}
	return d
}

// Day 0 of next month is the day before its 1st, so the normalising
// time.Date already does gives the length of this one, leap years and all.
func TimeLastDayOfMonth() int {
	now := time.Now()
	return time.Date(now.Year(), now.Month()+1, 0, 0, 0, 0, 0, time.Local).Day()
}

// A strftime-style template, which is familiar rather than Go's reference
// date. An unrecognised %x passes through verbatim.
func TimeFormat(stamp int, template string) string {
	t := time.UnixMilli(int64(stamp))
	var out strings.Builder
	runes := []rune(template)
	for i := 0; i < len(runes); i++ {
		if runes[i] != '%' || i+1 >= len(runes) {
			out.WriteRune(runes[i])
			continue
		}
		i++
		out.WriteString(directive(t, runes[i]))
	}
	return out.String()
}

func directive(t time.Time, code rune) string {
	zone, offset := t.Zone()
	switch code {
	case 'Y':
		return pad(t.Year(), 4)
	case 'y':
		return pad(t.Year()%100, 2)
	case 'm':
		return pad(int(t.Month()), 2)
	case 'd':
		return pad(t.Day(), 2)
	case 'H':
		return pad(t.Hour(), 2)
	case 'I':
		return pad(hour12(t.Hour()), 2)
	case 'M':
		return pad(t.Minute(), 2)
	case 'S':
		return pad(t.Second(), 2)
	case 'j':
		return pad(t.YearDay(), 3)
	case 'p':
		if t.Hour() < 12 {
			return "AM"
		}
		return "PM"
	case 'A':
		return t.Weekday().String()
	case 'a':
		return t.Weekday().String()[:3]
	case 'B':
		return t.Month().String()
	case 'b':
		return t.Month().String()[:3]
	case 'Z':
		return zone
	case 'z':
		sign := "+"
		if offset < 0 {
			sign = "-"
			offset = -offset
		}
		return sign + pad(offset/3600, 2) + pad((offset%3600)/60, 2)
	case '%':
		return "%"
	}
	return "%" + string(code)
}

func hour12(h int) int {
	h = h % 12
	if h == 0 {
		return 12
	}
	return h
}

func pad(n, width int) string {
	s := strconv.Itoa(n)
	for len(s) < width {
		s = "0" + s
	}
	return s
}
