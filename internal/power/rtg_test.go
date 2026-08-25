package power

import (
	"math"
	"testing"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
)

// TestAnchorsReproduced checks the model passes through its calibration points.
func TestAnchorsReproduced(t *testing.T) {
	for _, a := range PowerAnchors {
		got := TotalWatts(a.When)
		if math.Abs(got-a.Watts) > 0.5 {
			t.Errorf("anchor %s: got %.2f W, want %.2f W", a.Source, got, a.Watts)
		}
	}
}

// TestDeclineRateMatchesIndependentFigure is the model's out-of-sample check.
//
// The fit uses only two power magnitudes (470 W and 220 W) and never sees a
// slope. NASA separately and independently reports the decline as
// "about 4 watts per year". If a two-term exponential fitted only to
// magnitudes also reproduces that slope, the functional form is right rather
// than merely tuned. A decay-only model cannot do this.
func TestDeclineRateMatchesIndependentFigure(t *testing.T) {
	now := time.Date(2026, 8, 26, 0, 0, 0, 0, time.UTC)
	got := -DeclineWattsPerYear(now)
	if got < 3.0 || got > 5.0 {
		t.Errorf("modelled decline %.2f W/yr is outside the independently reported ~4 W/yr band", got)
	}
	t.Logf("modelled decline at 2026-08: %.2f W/yr (independent figure: ~4 W/yr)", got)
}

// TestDecayOnlyModelWouldBeWrong documents why the thermocouple term exists.
// Without it the model overestimates 2026 output by roughly 100 W.
func TestDecayOnlyModelWouldBeWrong(t *testing.T) {
	when := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	age := yearsSinceLaunch(when)
	decayOnly := BeginningOfLifeWatts * math.Exp(-decayLambda*age)
	full := TotalWatts(when)
	gap := decayOnly - full
	if gap < 80 || gap > 120 {
		t.Errorf("decay-only overestimate is %.1f W, expected roughly 100 W", gap)
	}
	t.Logf("decay-only: %.1f W, two-term: %.1f W, converter losses account for %.1f W", decayOnly, full, gap)
}

// TestTwoMechanismsContributeEqually records a non-obvious result the model
// surfaced: the calibrated constants come out nearly identical
// (lambda ~= 0.0079/yr, mu ~= 0.0077/yr), so by 2026 fuel decay and converter
// degradation have each cost almost exactly the same fraction of output.
//
// The intuitive story -- "the plutonium is running out" -- is only half true.
// Roughly half the lost power is fuel, half is the thermocouples wearing out.
// The twin should say that, because it is what the numbers actually show.
func TestTwoMechanismsContributeEqually(t *testing.T) {
	when := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	fuel := FuelFractionRemaining(when)
	conv := ConverterEfficiencyFraction(when)

	if fuel < 0.60 || fuel > 0.75 {
		t.Errorf("fuel remaining %.3f outside plausible range", fuel)
	}
	// The two mechanisms should be within a few percent of each other.
	if math.Abs(fuel-conv) > 0.05 {
		t.Errorf("mechanisms diverged: fuel %.3f vs converter %.3f; the equal-contribution finding no longer holds and the UI narrative must be revisited", fuel, conv)
	}
	// Their product must reconstruct the observed output ratio.
	wantRatio := 220.0 / BeginningOfLifeWatts
	if math.Abs(fuel*conv-wantRatio) > 0.005 {
		t.Errorf("fuel*converter = %.4f, expected %.4f", fuel*conv, wantRatio)
	}
	t.Logf("2026: fuel remaining %.1f%%, converter efficiency %.1f%% -- near-equal contributions", fuel*100, conv*100)
	t.Logf("constants: lambda=%.6f/yr (fuel), mu=%.6f/yr (converters)", Lambda(), Mu())
}

func TestBeforeLaunchIsZero(t *testing.T) {
	if got := TotalWatts(time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC)); got != 0 {
		t.Errorf("pre-launch power should be 0, got %v", got)
	}
}

func TestPerRTGSumsToTotal(t *testing.T) {
	when := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if diff := math.Abs(PerRTGWatts(when)*RTGCount - TotalWatts(when)); diff > 1e-9 {
		t.Errorf("per-RTG times %d does not sum to total, diff %v", RTGCount, diff)
	}
}

// TestSampleIsAlwaysModelled guards the honesty invariant: this package must
// never emit a value that looks measured.
func TestSampleIsAlwaysModelled(t *testing.T) {
	for _, when := range []time.Time{
		LaunchTime,
		time.Date(1989, 8, 25, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 8, 26, 0, 0, 0, 0, time.UTC),
		time.Date(2050, 1, 1, 0, 0, 0, 0, time.UTC),
	} {
		if got := TotalSample(when).Prov; got != domain.ProvModelled {
			t.Errorf("at %s provenance is %q, must always be %q", when, got, domain.ProvModelled)
		}
	}
	// Far extrapolation must not claim confidence.
	if TotalSample(time.Date(2050, 1, 1, 0, 0, 0, 0, time.UTC)).Confident {
		t.Error("2050 extrapolation must not be marked confident")
	}
}
