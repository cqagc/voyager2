package bodies_test

import (
	"math"
	"testing"

	"github.com/cqagc/voyager2/internal/bodies"
)

// TestRingsLieOutsideTheirPlanet catches the most basic way ring data can be
// wrong: a radius quoted from the surface instead of from the centre, or the
// wrong planet radius, would put rings inside the body.
func TestRingsLieOutsideTheirPlanet(t *testing.T) {
	for _, p := range bodies.Profiles {
		for _, r := range p.Rings {
			if r.InnerKm <= p.EquatorialRadiusKm {
				t.Errorf("%s %s: inner radius %.0f km is inside the planet (R=%.0f km)",
					p.Name, r.Name, r.InnerKm, p.EquatorialRadiusKm)
			}
			if r.OuterKm <= r.InnerKm {
				t.Errorf("%s %s: outer %.0f <= inner %.0f", p.Name, r.Name, r.OuterKm, r.InnerKm)
			}
		}
	}
}

// TestSaturnRingOrdering pins the structure everyone recognises: C inside B,
// the Cassini Division between B and A, and the Encke and Keeler gaps nested
// inside the A ring.
func TestSaturnRingOrdering(t *testing.T) {
	p, ok := bodies.ByName("saturn")
	if !ok {
		t.Fatal("no saturn profile")
	}
	get := func(name string) bodies.RingBand {
		for _, r := range p.Rings {
			if r.Name == name {
				return r
			}
		}
		t.Fatalf("missing ring %q", name)
		return bodies.RingBand{}
	}
	c, b, cas, a := get("C 环"), get("B 环"), get("卡西尼缝"), get("A 环")
	enc, kee := get("恩克缝"), get("基勒缝")

	if c.OuterKm != b.InnerKm {
		t.Errorf("C ring outer %.0f should meet B ring inner %.0f", c.OuterKm, b.InnerKm)
	}
	if cas.InnerKm != b.OuterKm || cas.OuterKm != a.InnerKm {
		t.Errorf("Cassini Division [%.0f, %.0f] should sit exactly between B (ends %.0f) and A (starts %.0f)",
			cas.InnerKm, cas.OuterKm, b.OuterKm, a.InnerKm)
	}
	for _, g := range []bodies.RingBand{enc, kee} {
		if g.InnerKm < a.InnerKm || g.OuterKm > a.OuterKm {
			t.Errorf("%s [%.0f, %.0f] should be nested inside the A ring [%.0f, %.0f]",
				g.Name, g.InnerKm, g.OuterKm, a.InnerKm, a.OuterKm)
		}
	}
	// The B ring is the bright one.
	if !b.Brightest {
		t.Error("Saturn's B ring should be flagged brightest")
	}
}

// TestBrightestRingIsUnique guards against flagging two rings as the brightest.
func TestBrightestRingIsUnique(t *testing.T) {
	for _, p := range bodies.Profiles {
		n := 0
		for _, r := range p.Rings {
			if r.Brightest {
				n++
			}
		}
		if len(p.Rings) > 0 && n != 1 {
			t.Errorf("%s has %d rings flagged brightest, want exactly 1", p.Name, n)
		}
	}
}

// TestRetrogradeBodiesAreConsistent checks the two ways retrograde motion is
// encoded agree with each other -- but only for the PLANETS.
//
// The rule "obliquity > 90 deg <=> negative rotation period" does not hold for
// tidally locked moons. Triton is the counterexample: it is locked to Neptune,
// so its rotation follows its ORBIT, and that orbit is retrograde
// (inclination 157.3 deg). Its obliquity to its own orbit is therefore about
// zero while its rotation period is negative. That is a real physical
// distinction, not a data error -- the first version of this test asserted the
// rule for every body and flagged Triton, which was the test being wrong.
func TestRetrogradeBodiesAreConsistent(t *testing.T) {
	planets := map[string]bool{
		"mercury": true, "venus": true, "earth": true, "mars": true,
		"jupiter": true, "saturn": true, "uranus": true, "neptune": true,
	}
	for _, p := range bodies.Profiles {
		if !planets[p.Name] {
			continue
		}
		byObliquity := p.ObliquityDeg > 90.0
		byPeriod := p.RotationHours < 0
		if byObliquity != byPeriod {
			t.Errorf("%s: obliquity %.2f deg says retrograde=%v but rotation %.2f h says %v",
				p.Name, p.ObliquityDeg, byObliquity, p.RotationHours, byPeriod)
		}
	}
	// Venus and Uranus are the retrograde planets.
	for _, want := range []string{"venus", "uranus"} {
		p, _ := bodies.ByName(want)
		if p.ObliquityDeg <= 90 {
			t.Errorf("%s should be retrograde (obliquity > 90), got %.2f", want, p.ObliquityDeg)
		}
	}
	// Uranus is the one lying on its side.
	u, _ := bodies.ByName("uranus")
	if math.Abs(u.ObliquityDeg-90) > 20 {
		t.Errorf("Uranus obliquity %.2f should be near 90 (it spins on its side)", u.ObliquityDeg)
	}
	// Triton's retrograde rotation is a consequence of its retrograde orbit.
	tr, _ := bodies.ByName("triton")
	if tr.RotationHours >= 0 {
		t.Error("Triton should rotate retrograde: it is tidally locked to a retrograde orbit")
	}
}

// TestNarrowRingsWouldBeInvisibleAtTrueWidth documents why MinRenderWidthKm
// exists, using the actual numbers.
func TestNarrowRingsWouldBeInvisibleAtTrueWidth(t *testing.T) {
	u, _ := bodies.ByName("uranus")
	var narrow int
	for _, r := range u.Rings {
		w := r.OuterKm - r.InnerKm
		if w < bodies.MinRenderWidthKm {
			narrow++
			t.Logf("%s %s is %.0f km wide against R=%.0f km -- %.5f%% of the planet radius",
				u.Name, r.Name, w, u.EquatorialRadiusKm, w/u.EquatorialRadiusKm*100)
		}
	}
	if narrow == 0 {
		t.Error("expected several Uranian rings narrower than the render floor")
	}
	t.Logf("%d of %d Uranian rings are narrower than the %.0f km render floor",
		narrow, len(u.Rings), bodies.MinRenderWidthKm)
}
