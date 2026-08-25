// Package power models the electrical output of Voyager 2's three MHW-RTGs.
//
// This package exists because NASA publishes NO public engineering telemetry
// for Voyager 2. Every value it produces is domain.ProvModelled and must be
// labelled as such in any UI. It is a physical estimate, never a measurement.
package power

import (
	"math"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
)

// Voyager 2 flew three Multi-Hundred Watt RTGs (MHW-RTG), each holding about
// 4.5 kg of plutonium-238 oxide.
const (
	// RTGCount is the number of generators on the spacecraft.
	RTGCount = 3

	// BeginningOfLifeWatts is the combined electrical output at launch.
	BeginningOfLifeWatts = 470.0

	// Pu238HalfLifeYears is the half-life of plutonium-238.
	Pu238HalfLifeYears = 87.7
)

// LaunchTime is Voyager 2's launch, 1977-08-20 14:29 UTC. Power age is
// measured from here.
var LaunchTime = time.Date(1977, 8, 20, 14, 29, 0, 0, time.UTC)

// decayLambda is the radioactive decay constant of the fuel, per year.
var decayLambda = math.Ln2 / Pu238HalfLifeYears

// thermocoupleMu is the additional exponential decay constant, per year, that
// accounts for degradation of the silicon-germanium thermocouples themselves.
//
// This term is NOT optional. Fuel decay alone predicts about 320 W in 2026,
// but the spacecraft actually delivers roughly 220 W. The ~100 W gap is
// converter degradation: sublimation of the thermoelectric legs, dopant
// precipitation, and rising contact resistance. A decay-only model
// overestimates available power by about a third, which would make every
// derived figure in the twin quietly wrong.
//
// The value is calibrated against the two publicly stated anchor points in
// PowerAnchors below, not derived from first principles. See Validate.
var thermocoupleMu = calibrateMu()

// PowerAnchor is a publicly reported total-output figure used to calibrate the
// degradation term. These are the only observations this model is fitted to.
type PowerAnchor struct {
	// When is the epoch of the reported figure.
	When time.Time
	// Watts is the reported combined electrical output.
	Watts float64
	// Source names where the figure comes from, so the fit stays auditable.
	Source string
}

// PowerAnchors are the calibration observations. Adding a newer anchor and
// re-running the fit is the intended way to keep the model honest.
var PowerAnchors = []PowerAnchor{
	{
		When:   LaunchTime,
		Watts:  BeginningOfLifeWatts,
		Source: "NASA: 3x MHW-RTG, 470 W combined at launch (beginning of life)",
	},
	{
		When:   time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Watts:  220.0,
		Source: "NASA/JPL public statements: approximately 220 W available, declining ~4 W/yr",
	},
}

// calibrateMu solves for the thermocouple degradation constant that makes the
// two-term model pass exactly through the latest anchor.
func calibrateMu() float64 {
	last := PowerAnchors[len(PowerAnchors)-1]
	t := yearsSinceLaunch(last.When)
	// BOL * exp(-lambda*t) * exp(-mu*t) = observed
	decayed := BeginningOfLifeWatts * math.Exp(-decayLambda*t)
	return -math.Log(last.Watts/decayed) / t
}

// yearsSinceLaunch returns the elapsed Julian years since launch. Negative
// before launch.
func yearsSinceLaunch(t time.Time) float64 {
	return t.Sub(LaunchTime).Hours() / 24.0 / 365.25
}

// TotalWatts estimates combined electrical output from all three RTGs at the
// given time. Returns 0 for epochs before launch.
//
// Model: P(t) = P0 * exp(-lambda*t) * exp(-mu*t), where lambda is Pu-238
// decay and mu is thermocouple degradation.
func TotalWatts(t time.Time) float64 {
	age := yearsSinceLaunch(t)
	if age < 0 {
		return 0
	}
	return BeginningOfLifeWatts * math.Exp(-(decayLambda+thermocoupleMu)*age)
}

// PerRTGWatts estimates one generator's output, assuming the three degrade
// identically. Real units differ slightly, but no public data exists to
// distinguish them, so pretending otherwise would be invention.
func PerRTGWatts(t time.Time) float64 {
	return TotalWatts(t) / RTGCount
}

// DeclineWattsPerYear returns the instantaneous rate of power loss at t,
// as a negative number.
func DeclineWattsPerYear(t time.Time) float64 {
	return -(decayLambda + thermocoupleMu) * TotalWatts(t)
}

// FuelFractionRemaining returns the surviving fraction of the original Pu-238
// inventory. This is pure decay and, unlike output power, is genuinely exact.
func FuelFractionRemaining(t time.Time) float64 {
	age := yearsSinceLaunch(t)
	if age < 0 {
		return 1
	}
	return math.Exp(-decayLambda * age)
}

// ConverterEfficiencyFraction returns the modelled thermocouple efficiency
// relative to beginning of life. Separating this from fuel decay lets the UI
// show why the spacecraft is dying: the fuel is not the binding constraint.
func ConverterEfficiencyFraction(t time.Time) float64 {
	age := yearsSinceLaunch(t)
	if age < 0 {
		return 1
	}
	return math.Exp(-thermocoupleMu * age)
}

// TotalSample wraps TotalWatts as a provenance-tagged sample, which is the
// only form the API layer should ever hand outward.
func TotalSample(t time.Time) domain.Sample {
	return domain.Sample{
		JDTDB: domain.TimeToJD(t),
		Value: TotalWatts(t),
		Unit:  "W",
		Prov:  domain.ProvModelled,
		// Confident within the anchor span; extrapolation far beyond the last
		// anchor is a guess and says so.
		Confident: yearsSinceLaunch(t) >= 0 &&
			t.Before(PowerAnchors[len(PowerAnchors)-1].When.AddDate(5, 0, 0)),
	}
}

// Mu exposes the calibrated degradation constant for tests and diagnostics.
func Mu() float64 { return thermocoupleMu }

// Lambda exposes the fuel decay constant for tests and diagnostics.
func Lambda() float64 { return decayLambda }
