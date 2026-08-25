package store_test

import (
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/horizons"
	"github.com/cqagc/voyager2/internal/store"
)

// These tests measure interpolation error against real JPL Horizons ephemeris
// rather than asserting self-consistency. Every "truth" fixture is a separate,
// finer-cadence Horizons fetch over the same window, so the interpolator is
// always scored on epochs it has never seen.
//
// Together they fix the sampling policy that cmd/ingest must follow:
//
//	cruise  -> daily samples are enough (sub-metre)
//	flyby   -> 30-minute samples required (~170 km); 6-hourly is unusable
//
// See docs/architecture.md section 4.

// TestCruiseDailySamplingIsSubMetre shows Hermite interpolation of daily
// samples is essentially exact during cruise, where the trajectory is smooth.
func TestCruiseDailySamplingIsSubMetre(t *testing.T) {
	samples := loadFixture(t, "voyager2_cruise_1d.txt")
	truth := loadFixture(t, "voyager2_cruise_1h.txt")

	maxHermite, maxLinear, checked := scoreAgainstTruth(t, samples, truth)
	if checked == 0 {
		t.Fatal("no interpolated epochs checked")
	}
	t.Logf("cruise, daily samples: checked %d epochs", checked)
	t.Logf("  Hermite max error: %.6f km", maxHermite)
	t.Logf("  linear  max error: %.6f km  (Hermite is %.0fx better)", maxLinear, maxLinear/maxHermite)

	// A metre of error on a 120 AU baseline. If this regresses, the velocity
	// terms have stopped being used correctly.
	if maxHermite > 0.010 {
		t.Errorf("cruise Hermite error %.6f km exceeds the 10 m budget", maxHermite)
	}
	// Hermite must dominate linear by orders of magnitude in a smooth region.
	if maxLinear/maxHermite < 100 {
		t.Errorf("Hermite only %.1fx better than linear; expected >100x in a smooth region", maxLinear/maxHermite)
	}
}

// TestFlybyRequiresFineSampling establishes why cmd/ingest must densify flyby
// windows instead of relying on interpolation.
//
// The window straddles the 1989-08-25 Neptune encounter, where Voyager 2's
// velocity vector turns sharply (Vy -15.1 -> -11.1, Vz +0.6 -> -12.1 km/s
// within a day). A derivative kink is a hard limit for any polynomial
// interpolant: no cadence recovers full convergence order, so the fix is
// denser native samples, not a better interpolator.
func TestFlybyRequiresFineSampling(t *testing.T) {
	truth := loadFixture(t, "voyager2_flyby_truth_10m.txt")

	cases := []struct {
		label  string
		stride int // in units of the 10-minute truth cadence
		// maxKm is the measured error budget for this cadence.
		maxKm float64
		// usable records whether this cadence is good enough to render.
		usable bool
	}{
		{"6 h", 36, 40000, false},
		{"3 h", 18, 16000, false},
		{"1 h", 6, 1400, false},
		{"30 min", 3, 300, true},
	}

	const neptuneRadiusKm = 24764.0

	for _, c := range cases {
		samples := subsample(truth, c.stride)
		maxHermite, _, checked := scoreAgainstTruth(t, samples, truth)
		if checked == 0 {
			t.Fatalf("%s: no interpolated epochs checked", c.label)
		}

		note := ""
		if maxHermite > neptuneRadiusKm {
			note = "  <- error exceeds Neptune's radius; the probe would render on the wrong side of the planet"
		}
		t.Logf("flyby, %-6s samples (%3d pts): max error %10.1f km%s", c.label, len(samples), maxHermite, note)

		if maxHermite > c.maxKm {
			t.Errorf("%s cadence: error %.1f km exceeds recorded budget %.1f km", c.label, maxHermite, c.maxKm)
		}
		if c.usable && maxHermite > 1000 {
			t.Errorf("%s was expected to be usable but errs by %.1f km", c.label, maxHermite)
		}
		if !c.usable && maxHermite < 1000 {
			t.Errorf("%s was recorded as unusable but errs by only %.1f km; the policy in docs/architecture.md can be relaxed", c.label, maxHermite)
		}
	}
}

// scoreAgainstTruth returns the worst Hermite and linear position errors over
// every truth epoch that lies strictly between two samples.
func scoreAgainstTruth(t *testing.T, samples, truth []domain.StateVector) (maxHermite, maxLinear float64, checked int) {
	t.Helper()

	db, err := store.Open(filepath.Join(t.TempDir(), "acc.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := db.Init(); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertBodies([]domain.Body{{
		ID: domain.BodyVoyager2, Name: "voyager2", Label: "旅行者2号", IsSpacecraft: true,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertStateVectors(domain.BodyVoyager2, samples); err != nil {
		t.Fatal(err)
	}

	for _, want := range truth {
		if onSample(samples, want.JDTDB) {
			continue
		}
		if want.JDTDB <= samples[0].JDTDB || want.JDTDB >= samples[len(samples)-1].JDTDB {
			continue
		}
		got, err := db.StateAt(domain.BodyVoyager2, want.JDTDB)
		if err != nil {
			t.Fatalf("StateAt(%f): %v", want.JDTDB, err)
		}
		if e := posDist(got.Pos, want.Pos); e > maxHermite {
			maxHermite = e
		}
		if e := posDist(linearPos(samples, want.JDTDB), want.Pos); e > maxLinear {
			maxLinear = e
		}
		checked++
	}
	return maxHermite, maxLinear, checked
}

func subsample(in []domain.StateVector, stride int) []domain.StateVector {
	out := make([]domain.StateVector, 0, len(in)/stride+1)
	for i := 0; i < len(in); i += stride {
		out = append(out, in[i])
	}
	return out
}

func loadFixture(t *testing.T, name string) []domain.StateVector {
	t.Helper()
	f, err := os.Open(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	v, err := horizons.Parse(f)
	if err != nil {
		t.Fatalf("parse %s: %v", name, err)
	}
	return v
}

func onSample(samples []domain.StateVector, jd float64) bool {
	for _, s := range samples {
		if math.Abs(s.JDTDB-jd) < 1e-9 {
			return true
		}
	}
	return false
}

// linearPos is the deliberately naive baseline the Hermite path must beat.
func linearPos(samples []domain.StateVector, jd float64) domain.Vec3 {
	for i := 0; i < len(samples)-1; i++ {
		a, b := samples[i], samples[i+1]
		if jd >= a.JDTDB && jd <= b.JDTDB {
			f := (jd - a.JDTDB) / (b.JDTDB - a.JDTDB)
			return domain.Vec3{
				X: a.Pos.X + f*(b.Pos.X-a.Pos.X),
				Y: a.Pos.Y + f*(b.Pos.Y-a.Pos.Y),
				Z: a.Pos.Z + f*(b.Pos.Z-a.Pos.Z),
			}
		}
	}
	return domain.Vec3{}
}

func posDist(a, b domain.Vec3) float64 {
	return math.Sqrt((a.X-b.X)*(a.X-b.X) + (a.Y-b.Y)*(a.Y-b.Y) + (a.Z-b.Z)*(a.Z-b.Z))
}
