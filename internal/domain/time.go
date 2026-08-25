package domain

import (
	"math"
	"time"
)

// J2000 is the Julian Date of the J2000.0 epoch (2000-01-01 12:00 TT).
const J2000 = 2451545.0

// unixJD is the Julian Date of the Unix epoch, 1970-01-01 00:00:00 UTC.
const unixJD = 2440587.5

// TimeToJD converts a wall-clock time to a Julian Date, ignoring the
// TDB-UTC offset (currently ~70 s). That is acceptable for visualisation at
// this scale — 70 s of Voyager 2 motion is about 1000 km against a 20-billion
// km baseline — but never use this for ephemeris generation, where Horizons'
// own JDTDB values are authoritative.
func TimeToJD(t time.Time) float64 {
	return unixJD + float64(t.UTC().UnixNano())/1e9/86400.0
}

// JDToTime is the inverse of TimeToJD, with the same caveat.
func JDToTime(jd float64) time.Time {
	sec := (jd - unixJD) * 86400.0
	whole, frac := math.Modf(sec)
	return time.Unix(int64(whole), int64(frac*1e9)).UTC()
}
