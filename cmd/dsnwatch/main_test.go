package main

import (
	"strings"
	"testing"
)

// TestFormatLightTimeNeverFakesZero guards the bug found while testing against
// the live DSN feed: the feed uses rtlt="-1" for "no data", which normalises to
// 0, and printing that as "0.00 小时" made JWST -- 1.5 million km out, about a
// 10 s round trip -- report zero light time. Absent data must look absent.
func TestFormatLightTimeNeverFakesZero(t *testing.T) {
	for _, sec := range []float64{0, -1, -3600} {
		got := formatLightTime(sec)
		if !strings.Contains(got, "未提供") {
			t.Errorf("formatLightTime(%v) = %q; absent data must not render as a number", sec, got)
		}
	}
}

func TestFormatLightTimeScales(t *testing.T) {
	cases := []struct {
		sec  float64
		unit string
	}{
		{10, "秒"},     // JWST-class
		{600, "分钟"},   // Mars-class
		{68400, "小时"}, // Voyager 2: about 19 h one way
	}
	for _, c := range cases {
		got := formatLightTime(c.sec)
		if !strings.Contains(got, c.unit) {
			t.Errorf("formatLightTime(%v) = %q, want unit %q", c.sec, got, c.unit)
		}
	}
}

// TestVoyager2LightTimeIsPlausible pins the figure that makes the twin worth
// looking at: a command to Voyager 2 takes most of a day to get an answer back.
func TestVoyager2LightTimeIsPlausible(t *testing.T) {
	// 143.77 AU measured from the ingested ephemeris, round trip.
	const auKm = 149597870.7
	const c = 299792.458
	rtlt := 2 * 143.77 * auKm / c
	got := formatLightTime(rtlt)
	if !strings.Contains(got, "小时") {
		t.Fatalf("expected hours, got %q", got)
	}
	hours := rtlt / 3600
	if hours < 35 || hours > 45 {
		t.Errorf("round-trip light time %.1f h is outside the plausible 35-45 h band", hours)
	}
	t.Logf("Voyager 2 at 143.77 AU: %s", got)
}
