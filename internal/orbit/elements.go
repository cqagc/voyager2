// Package orbit computes satellite positions from Keplerian orbital elements.
//
// Why this exists: the ephemeris store samples most of the mission daily, but
// Io orbits Jupiter every 1.77 days and Miranda orbits Uranus every 1.41 days.
// Daily samples cannot resolve those orbits at all -- interpolating them yields
// aliased nonsense. Densifying the store to 2-hour cadence for seven moons over
// 49 years would add roughly 84 MB to the exported bundle. Computing the orbits
// analytically from published elements costs a few hundred bytes instead.
//
// Honesty about what this model is and is not:
//
//   - The orbit's GEOMETRY (size, shape, inclination, orientation) is accurate:
//     the elements come from JPL's published satellite mean elements.
//   - The PHASE along the orbit is only reliable near the J2000 epoch. Published
//     period values disagree with GM-derived periods by 0.004%-0.5%, which over
//     49 years accumulates to between 0.04 and 5.24 full orbits of phase error
//     (see TestPhaseDriftIsDocumented). So satellite positions from this model
//     are domain.ProvModelled, never ProvMeasured.
//   - Where the store does have adequate sampling -- the four 30-minute flyby
//     windows -- the real ephemeris is phase-correct and should be preferred.
//     TestModelAgainstEphemeris measures how far apart the two actually are.
//   - The elements are given in each body's local Laplace plane. This package
//     approximates that plane by the parent's equatorial plane, which is a good
//     approximation for these close-in satellites but is an approximation.
package orbit

import (
	"math"

	"github.com/cqagc/voyager2/internal/domain"
)

// J2000 is the epoch all published elements below refer to (2000-01-01.5 TDB).
const J2000 = 2451545.0

// Elements is a satellite's Keplerian orbit around its parent.
type Elements struct {
	// Name matches the body name used elsewhere in the project.
	Name string
	// Parent is the primary this satellite orbits.
	Parent string
	// SemiMajorKm is the semi-major axis.
	SemiMajorKm float64
	// Ecc is the eccentricity.
	Ecc float64
	// IncDeg is the inclination to the parent's Laplace plane. Values above 90
	// encode a retrograde orbit -- Triton's 157.3 deg is the real reason it
	// orbits Neptune backwards.
	IncDeg float64
	// ArgPeriDeg is the argument of periapsis.
	ArgPeriDeg float64
	// NodeDeg is the longitude of the ascending node.
	NodeDeg float64
	// MeanAnomDeg is the mean anomaly at J2000.
	MeanAnomDeg float64
	// PeriodDays is the published sidereal orbital period. Preferred over
	// deriving it from the parent's GM: the derived value differs by up to
	// 0.5% and phase error accumulates linearly with elapsed time.
	PeriodDays float64
	// MeanRadiusKm is the body's own radius, for rendering.
	MeanRadiusKm float64
	// Label is the human-facing name.
	Label string
	// Frame names the plane the angular elements are referred to.
	//
	// This matters and getting it wrong is visible: the Moon's classic mean
	// elements are referred to the ECLIPTIC, but treating them as Earth-
	// equatorial and applying the 23.44 deg obliquity rotation tilts the whole
	// orbit by that much. Measured against real ephemeris, the orbit-plane
	// normal was off by 16-26 deg with the rotation applied and 0.14 deg
	// without it at J2000 (see TestMoonOrbitPlaneFrame). The drawn ring then
	// misses the Moon entirely, which is exactly what a user reported.
	//
	// "ecliptic" -> angles already in ecliptic J2000, apply no tilt.
	// "laplace"  -> approximate the local Laplace plane by the parent's
	//               equator, i.e. tilt by the parent's obliquity.
	Frame string
}

// Satellites are the moons this project renders.
//
// Elements: JPL Solar System Dynamics, planetary satellite mean elements
// (https://ssd.jpl.nasa.gov/sats/elem/), epoch 2000-01-01.5, Laplace plane.
// Periods and radii: published values cross-checked against GM-derived periods,
// which agree to within 0.5% (see TestPeriodsAgreeWithTwoBodyDerivation).
var Satellites = []Elements{
	{
		Name: "moon", Parent: "earth", Label: "月球", Frame: "ecliptic",
		SemiMajorKm: 384399, Ecc: 0.0549, IncDeg: 5.145,
		ArgPeriDeg: 318.15, NodeDeg: 125.08, MeanAnomDeg: 135.27,
		PeriodDays: 27.321582, MeanRadiusKm: 1737.4,
	},
	{
		Name: "io", Frame: "laplace", Parent: "jupiter", Label: "木卫一",
		SemiMajorKm: 421800, Ecc: 0.004, IncDeg: 0.0,
		ArgPeriDeg: 49.1, NodeDeg: 0.0, MeanAnomDeg: 330.9,
		PeriodDays: 1.769300, MeanRadiusKm: 1821.6,
	},
	{
		Name: "europa", Frame: "laplace", Parent: "jupiter", Label: "木卫二",
		SemiMajorKm: 671100, Ecc: 0.009, IncDeg: 0.5,
		ArgPeriDeg: 45.0, NodeDeg: 184.0, MeanAnomDeg: 345.4,
		PeriodDays: 3.550400, MeanRadiusKm: 1560.8,
	},
	{
		Name: "ganymede", Frame: "laplace", Parent: "jupiter", Label: "木卫三",
		SemiMajorKm: 1070400, Ecc: 0.001, IncDeg: 0.2,
		ArgPeriDeg: 198.3, NodeDeg: 58.5, MeanAnomDeg: 324.8,
		PeriodDays: 7.155600, MeanRadiusKm: 2634.1,
	},
	{
		Name: "callisto", Frame: "laplace", Parent: "jupiter", Label: "木卫四",
		SemiMajorKm: 1882700, Ecc: 0.007, IncDeg: 0.3,
		ArgPeriDeg: 43.8, NodeDeg: 309.1, MeanAnomDeg: 87.4,
		PeriodDays: 16.690000, MeanRadiusKm: 2410.3,
	},
	{
		Name: "titan", Frame: "laplace", Parent: "saturn", Label: "土卫六",
		SemiMajorKm: 1221900, Ecc: 0.029, IncDeg: 0.3,
		ArgPeriDeg: 78.3, NodeDeg: 78.6, MeanAnomDeg: 11.7,
		PeriodDays: 15.945000, MeanRadiusKm: 2574.7,
	},
	{
		Name: "miranda", Frame: "laplace", Parent: "uranus", Label: "天卫五",
		SemiMajorKm: 129846, Ecc: 0.001, IncDeg: 4.4,
		ArgPeriDeg: 154.8, NodeDeg: 100.9, MeanAnomDeg: 73.0,
		PeriodDays: 1.413000, MeanRadiusKm: 235.8,
	},
	{
		Name: "triton", Frame: "laplace", Parent: "neptune", Label: "海卫一",
		SemiMajorKm: 354800, Ecc: 0.000, IncDeg: 157.3,
		ArgPeriDeg: 0.0, NodeDeg: 178.1, MeanAnomDeg: 63.0,
		PeriodDays: 5.877000, MeanRadiusKm: 1353.4,
	},
}

// ParentGM holds each primary's gravitational parameter in km^3/s^2, used only
// to cross-check the published periods.
var ParentGM = map[string]float64{
	"earth":   398600.4418,
	"jupiter": 1.26686534e8,
	"saturn":  3.7931187e7,
	"uranus":  5.793939e6,
	"neptune": 6.836529e6,
}

// ByName looks up a satellite's elements.
func ByName(name string) (Elements, bool) {
	for _, e := range Satellites {
		if e.Name == name {
			return e, true
		}
	}
	return Elements{}, false
}

// MeanAnomalyAt returns the mean anomaly in radians at a Julian date.
func (e Elements) MeanAnomalyAt(jd float64) float64 {
	n := 2 * math.Pi / e.PeriodDays
	m := deg2rad(e.MeanAnomDeg) + n*(jd-J2000)
	return math.Mod(math.Mod(m, 2*math.Pi)+2*math.Pi, 2*math.Pi)
}

// eccentricAnomaly solves Kepler's equation E - e*sin(E) = M by Newton
// iteration. Converges in a handful of steps for these near-circular orbits.
func eccentricAnomaly(m, ecc float64) float64 {
	eA := m
	for i := 0; i < 32; i++ {
		f := eA - ecc*math.Sin(eA) - m
		fp := 1 - ecc*math.Cos(eA)
		if math.Abs(fp) < 1e-15 {
			break
		}
		d := f / fp
		eA -= d
		if math.Abs(d) < 1e-14 {
			break
		}
	}
	return eA
}

// PositionParentFrame returns the satellite's position relative to its parent,
// in the parent's Laplace/equatorial frame, in km.
func (e Elements) PositionParentFrame(jd float64) domain.Vec3 {
	m := e.MeanAnomalyAt(jd)
	eA := eccentricAnomaly(m, e.Ecc)

	// Position in the orbital plane.
	xv := e.SemiMajorKm * (math.Cos(eA) - e.Ecc)
	yv := e.SemiMajorKm * math.Sqrt(1-e.Ecc*e.Ecc) * math.Sin(eA)

	w := deg2rad(e.ArgPeriDeg)
	i := deg2rad(e.IncDeg)
	om := deg2rad(e.NodeDeg)

	cw, sw := math.Cos(w), math.Sin(w)
	ci, si := math.Cos(i), math.Sin(i)
	co, so := math.Cos(om), math.Sin(om)

	// Rotate: argument of periapsis, then inclination, then node.
	x1 := xv*cw - yv*sw
	y1 := xv*sw + yv*cw
	y2 := y1 * ci
	z2 := y1 * si

	return domain.Vec3{
		X: x1*co - y2*so,
		Y: x1*so + y2*co,
		Z: z2,
	}
}

// PositionEclipticOffset returns the satellite's offset from its parent in the
// ecliptic J2000 frame, in km.
//
// The parent's equatorial plane is obtained by tilting the ecliptic by the
// parent's obliquity about the ecliptic X axis. A rigorous transform needs the
// parent's pole right ascension and declination (IAU alpha0/delta0), which this
// project does not carry; the single-angle tilt keeps each satellite system in
// the correct plane relative to its primary's spin axis, which is what the
// visualisation needs.
func (e Elements) PositionEclipticOffset(jd float64, parentObliquityDeg float64) domain.Vec3 {
	p := e.PositionParentFrame(jd)
	// Elements already referred to the ecliptic need no tilt.
	if e.Frame == "ecliptic" {
		parentObliquityDeg = 0
	}
	t := deg2rad(parentObliquityDeg)
	ct, st := math.Cos(t), math.Sin(t)
	return domain.Vec3{
		X: p.X,
		Y: p.Y*ct - p.Z*st,
		Z: p.Y*st + p.Z*ct,
	}
}

// SamplesPerOrbit reports how many ephemeris samples of the given spacing fall
// within one orbital period. Below about 8 the store cannot represent the orbit
// and the analytic model must be used instead.
func (e Elements) SamplesPerOrbit(spacingDays float64) float64 {
	if spacingDays <= 0 {
		return math.Inf(1)
	}
	return e.PeriodDays / spacingDays
}

// TwoBodyPeriodDays derives the period from the parent's GM. Used only as a
// cross-check on the published period.
func (e Elements) TwoBodyPeriodDays() (float64, bool) {
	gm, ok := ParentGM[e.Parent]
	if !ok {
		return 0, false
	}
	a := e.SemiMajorKm
	return 2 * math.Pi * math.Sqrt(a*a*a/gm) / 86400.0, true
}

func deg2rad(d float64) float64 { return d * math.Pi / 180.0 }
