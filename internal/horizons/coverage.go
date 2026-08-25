package horizons

import (
	"fmt"
	"regexp"
	"time"
)

// earliestEpochPattern matches the message Horizons returns when the requested
// window starts before a target's SPK coverage, e.g.
//
//	No ephemeris for target "Voyager 2 (spacecraft)" prior to A.D. 1977-AUG-20 15:32:32.1830 TDB
//
// Spacecraft coverage begins at launch, not at midnight, so a request for the
// launch DAY is rejected outright. Rather than dropping the most important body
// in the project, the client parses the epoch out of the refusal and retries
// from there.
var earliestEpochPattern = regexp.MustCompile(
	`prior to A\.D\.\s+(\d{4})-([A-Za-z]{3})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?`)

var monthAbbrev = map[string]time.Month{
	"JAN": time.January, "FEB": time.February, "MAR": time.March,
	"APR": time.April, "MAY": time.May, "JUN": time.June,
	"JUL": time.July, "AUG": time.August, "SEP": time.September,
	"OCT": time.October, "NOV": time.November, "DEC": time.December,
}

// EarliestEpochFromError extracts the first epoch a target has ephemeris for,
// out of a Horizons "No ephemeris for target ... prior to ..." message.
//
// The returned time is rounded UP to the next whole minute, because asking for
// the exact boundary instant is itself sometimes refused.
func EarliestEpochFromError(err error) (time.Time, bool) {
	if err == nil {
		return time.Time{}, false
	}
	m := earliestEpochPattern.FindStringSubmatch(err.Error())
	if m == nil {
		return time.Time{}, false
	}
	month, ok := monthAbbrev[upper(m[2])]
	if !ok {
		return time.Time{}, false
	}
	year, day := atoi(m[1]), atoi(m[3])
	hour, minute, sec := atoi(m[4]), atoi(m[5]), atoi(m[6])
	t := time.Date(year, month, day, hour, minute, sec, 0, time.UTC)

	// Round UP to the next whole minute, because Horizons only accepts
	// minute-resolution START_TIME and asking for a time before coverage is
	// what got us here.
	//
	// This must be a real ceiling, not an unconditional +1 minute. When the
	// coverage start is already on an exact minute boundary (seconds and
	// fractional seconds both zero), advancing anyway would permanently skip
	// the first valid epoch -- a silent, unrecoverable data loss at the very
	// start of the mission.
	hasSubMinute := sec != 0 || (len(m) > 7 && nonZeroDigits(m[7]))
	t = t.Truncate(time.Minute)
	if hasSubMinute {
		t = t.Add(time.Minute)
	}
	return t, true
}

// nonZeroDigits reports whether a fractional-seconds string carries any
// non-zero digit, i.e. whether the epoch really has sub-second precision.
func nonZeroDigits(s string) bool {
	for _, c := range s {
		if c >= '1' && c <= '9' {
			return true
		}
	}
	return false
}

func upper(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 32
		}
	}
	return string(b)
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return n
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// FormatHorizonsTime renders a time in the format Horizons accepts for
// START_TIME / STOP_TIME when sub-day precision is required.
func FormatHorizonsTime(t time.Time) string {
	return fmt.Sprintf("%04d-%02d-%02d %02d:%02d",
		t.Year(), int(t.Month()), t.Day(), t.Hour(), t.Minute())
}
