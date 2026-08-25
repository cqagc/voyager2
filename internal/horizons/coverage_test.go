package horizons

import (
	"errors"
	"testing"
	"time"
)

func TestEarliestEpochFromError(t *testing.T) {
	// The exact message that made the 2026-08-26 baseline ingest drop
	// Voyager 2 -- the one body the whole project is about.
	err := errors.New(`fetch body -32: horizons response "No ephemeris for target ` +
		`\"Voyager 2 (spacecraft)\" prior to A.D. 1977-AUG-20 15:32:32.1830 TDB": ` +
		`horizons returned no ephemeris data`)

	got, ok := EarliestEpochFromError(err)
	if !ok {
		t.Fatal("failed to recognise the coverage-start refusal")
	}
	want := time.Date(1977, 8, 20, 15, 33, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Errorf("got %s, want %s", got, want)
	}
	if s := FormatHorizonsTime(got); s != "1977-08-20 15:33" {
		t.Errorf("FormatHorizonsTime = %q", s)
	}
}

func TestEarliestEpochFromErrorIgnoresOtherErrors(t *testing.T) {
	for _, err := range []error{
		nil,
		errors.New("context deadline exceeded"),
		errors.New(`Cannot interpret "COMMAND"`),
		ErrNoEphemeris,
	} {
		if _, ok := EarliestEpochFromError(err); ok {
			t.Errorf("unexpectedly matched %v", err)
		}
	}
}

func TestAllMonthAbbreviationsParse(t *testing.T) {
	for abbrev, want := range monthAbbrev {
		err := errors.New(`prior to A.D. 1980-` + abbrev + `-01 00:00:00.0000 TDB`)
		got, ok := EarliestEpochFromError(err)
		if !ok {
			t.Fatalf("%s did not parse", abbrev)
		}
		if got.Month() != want {
			t.Errorf("%s -> %s, want %s", abbrev, got.Month(), want)
		}
	}
}

func TestFetchableExcludesFrameOrigin(t *testing.T) {
	all, fetchable := Bodies, Fetchable()
	if len(fetchable) != len(all)-1 {
		t.Fatalf("Fetchable returned %d bodies, want %d", len(fetchable), len(all)-1)
	}
	for _, b := range fetchable {
		if b.ID == FrameOrigin {
			t.Errorf("frame origin %d must not be fetchable; Horizons stalls on target == center", b.ID)
		}
	}
	// The spacecraft must always survive the filter.
	var hasV2 bool
	for _, b := range fetchable {
		if b.Name == "voyager2" {
			hasV2 = true
		}
	}
	if !hasV2 {
		t.Error("voyager2 missing from Fetchable")
	}
}

// TestEarliestEpochCeilingIsExact guards a data-loss bug the cross-model review
// caught: rounding up unconditionally.
//
// When Horizons reports coverage starting on an exact minute boundary, adding a
// minute anyway silently drops the first valid epoch forever. The ceiling must
// only advance when there really are sub-minute components.
func TestEarliestEpochCeilingIsExact(t *testing.T) {
	cases := []struct {
		msg  string
		want time.Time
	}{
		// Exact minute boundary: must NOT advance.
		{"prior to A.D. 1977-AUG-20 15:32:00.0000 TDB",
			time.Date(1977, 8, 20, 15, 32, 0, 0, time.UTC)},
		// Whole seconds present: must advance.
		{"prior to A.D. 1977-AUG-20 15:32:32.1830 TDB",
			time.Date(1977, 8, 20, 15, 33, 0, 0, time.UTC)},
		// Only fractional seconds: must advance.
		{"prior to A.D. 1977-AUG-20 15:32:00.5000 TDB",
			time.Date(1977, 8, 20, 15, 33, 0, 0, time.UTC)},
		// Fractional seconds present but all zero: must NOT advance.
		{"prior to A.D. 1977-AUG-20 15:32:00.0000000 TDB",
			time.Date(1977, 8, 20, 15, 32, 0, 0, time.UTC)},
		// No fractional part at all, exact minute: must NOT advance.
		{"prior to A.D. 1980-JAN-01 00:00:00 TDB",
			time.Date(1980, 1, 1, 0, 0, 0, 0, time.UTC)},
	}
	for _, c := range cases {
		got, ok := EarliestEpochFromError(errors.New(c.msg))
		if !ok {
			t.Fatalf("%q did not parse", c.msg)
		}
		if !got.Equal(c.want) {
			t.Errorf("%q -> %s, want %s", c.msg, got.Format(time.RFC3339), c.want.Format(time.RFC3339))
		}
	}
}
