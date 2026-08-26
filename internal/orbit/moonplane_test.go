package orbit_test

import (
	"math"
	"os"
	"testing"

	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/orbit"
	"github.com/cqagc/voyager2/internal/store"
)

// TestMoonOrbitPlaneFrame settles which reference frame the Moon's elements are
// in. The drawn orbit ring must lie in the same plane the ephemeris puts the
// Moon in, otherwise the Moon visibly floats off its own ring.
func TestMoonOrbitPlaneFrame(t *testing.T) {
	if _, err := os.Stat("../../data/voyager2.db"); err != nil {
		t.Skip("no db")
	}
	db, err := store.Open("../../data/voyager2.db")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	e, _ := orbit.ByName("moon")

	// Orbit normal from the real ephemeris: r x v of the Moon relative to Earth.
	normalFromEphemeris := func(jd float64) [3]float64 {
		ms, _ := db.StateAt(domain.BodyMoon, jd)
		es, _ := db.StateAt(domain.BodyEarth, jd)
		rx, ry, rz := ms.Pos.X-es.Pos.X, ms.Pos.Y-es.Pos.Y, ms.Pos.Z-es.Pos.Z
		vx, vy, vz := ms.Vel.X-es.Vel.X, ms.Vel.Y-es.Vel.Y, ms.Vel.Z-es.Vel.Z
		nx, ny, nz := ry*vz-rz*vy, rz*vx-rx*vz, rx*vy-ry*vx
		l := math.Sqrt(nx*nx + ny*ny + nz*nz)
		return [3]float64{nx / l, ny / l, nz / l}
	}
	// Orbit normal from the model: cross product of two sampled positions.
	normalFromModel := func(obl float64) [3]float64 {
		a := e.PositionEclipticOffset(orbit.J2000, obl)
		b := e.PositionEclipticOffset(orbit.J2000+e.PeriodDays*0.25, obl)
		nx, ny, nz := a.Y*b.Z-a.Z*b.Y, a.Z*b.X-a.X*b.Z, a.X*b.Y-a.Y*b.X
		l := math.Sqrt(nx*nx + ny*ny + nz*nz)
		return [3]float64{nx / l, ny / l, nz / l}
	}
	angle := func(p, q [3]float64) float64 {
		d := p[0]*q[0] + p[1]*q[1] + p[2]*q[2]
		return math.Acos(math.Max(-1, math.Min(1, math.Abs(d)))) * 180 / math.Pi
	}

	// 结论已固化进 Elements.Frame="ecliptic"：传进去的倾角会被忽略。
	// 这里断言结果本身 —— 模型的轨道面必须贴近星历给出的轨道面。
	//
	// 曆元附近应当几乎完全吻合；远离曆元会因为**交点退行**（18.6 年周期，
	// 月球轨道面真的在进动）张开到 10 度左右。固定曆元的要素抓不住这个，
	// 所以月球的轨道环最终改为直接用星历画（见 twin.gd 的
	// _rebuild_satellite_orbit），本测试保留下来记录这个限度。
	worstNear := 0.0
	worstFar := 0.0
	for _, jd := range []float64{2443376.5, 2447000.5, 2451545.0, 2461278.0} {
		ne := normalFromEphemeris(jd)
		got := angle(ne, normalFromModel(23.44))
		nearEpoch := math.Abs(jd-orbit.J2000) < 400
		if nearEpoch {
			worstNear = math.Max(worstNear, got)
		} else {
			worstFar = math.Max(worstFar, got)
		}
		t.Logf("jd %.1f  距曆元 %7.0f 天  轨道面法向夹角 %6.2f°", jd, jd-orbit.J2000, got)
	}
	t.Logf("曆元附近最大 %.2f°，远离曆元最大 %.2f°（交点退行所致）", worstNear, worstFar)
	if worstNear > 1.0 {
		t.Errorf("曆元附近轨道面偏差 %.2f°，说明参考系仍然选错了", worstNear)
	}
	if worstFar < 2.0 {
		t.Error("远离曆元没有出现预期的进动偏差，测试可能没在真正比较")
	}
}
