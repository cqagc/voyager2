// Package bodies holds the static physical and appearance parameters of the
// solar-system bodies this project renders.
//
// It lives in Go rather than in the front end on purpose: these numbers are
// data, they came from cited sources, and having a second hand-maintained copy
// in GDScript is a drift risk. cmd/export ships them to the front end.
//
// Sources:
//   - Obliquity to orbit and sidereal rotation period: NASA Planetary Fact
//     Sheet, cross-checked against Wikipedia's axial-tilt table. The two use
//     different conventions -- "tilt + retrograde" (Venus 2.64 deg retrograde,
//     Uranus 82.23 deg retrograde) versus "obliquity to orbit" (177.4, 97.77) --
//     and they reconcile: 180-2.64 = 177.36, 180-82.23 = 97.77. This package
//     uses obliquity to orbit, which is directly the spin-axis tilt to render.
//   - Ring geometry: Wikipedia's Rings of Saturn / Rings of Uranus / Rings of
//     Neptune, radii in km from the planet's centre.
//   - Equatorial radii: NASA Planetary Fact Sheet.
package bodies

// Appearance selects which procedural surface treatment the renderer applies.
type Appearance string

const (
	KindRocky  Appearance = "rocky"
	KindVenus  Appearance = "venus"
	KindEarth  Appearance = "earth"
	KindMars   Appearance = "mars"
	KindGas    Appearance = "gas"
	KindIce    Appearance = "ice"
	KindIo     Appearance = "io"
	KindEuropa Appearance = "europa"
	KindTitan  Appearance = "titan"
	KindTriton Appearance = "triton"
	KindMoon   Appearance = "moon"
)

// Profile is everything the renderer needs about one body beyond its ephemeris.
type Profile struct {
	Name string `json:"name"`
	// ObliquityDeg is the tilt of the spin axis to the orbital plane. Values
	// above 90 mean the body spins retrograde: Venus 177.4, Uranus 97.77.
	ObliquityDeg float64 `json:"obliquity_deg"`
	// RotationHours is the sidereal rotation period. Negative is retrograde.
	RotationHours float64 `json:"rotation_hours"`
	// EquatorialRadiusKm is used to scale ring systems.
	EquatorialRadiusKm float64 `json:"equatorial_radius_km"`
	// Kind selects the procedural surface treatment.
	Kind Appearance `json:"kind"`
	// AtmosphereColor and AtmospherePower drive the limb glow. Power 0 means
	// no atmosphere.
	AtmosphereColor [3]float64 `json:"atmosphere_color"`
	AtmospherePower float64    `json:"atmosphere_power"`
	// SurfaceColor is the base albedo colour.
	SurfaceColor [3]float64 `json:"surface_color"`
	// Rings is empty for bodies without a ring system.
	Rings []RingBand `json:"rings,omitempty"`
	// RingTint colours the whole ring system.
	RingTint [3]float64 `json:"ring_tint,omitempty"`
}

// RingBand is one named ring or gap, in km from the planet's centre.
//
// Opacity is a rendering choice, not a measurement: it encodes the relative
// optical depth well enough to read (Saturn's B ring is nearly opaque, the
// Cassini Division is nearly empty, Uranus's rings are all very dark).
type RingBand struct {
	Name      string  `json:"name"`
	InnerKm   float64 `json:"inner_km"`
	OuterKm   float64 `json:"outer_km"`
	Opacity   float64 `json:"opacity"`
	IsGap     bool    `json:"is_gap,omitempty"`
	Brightest bool    `json:"brightest,omitempty"`
}

// MinRenderWidthKm is the width a ring is widened to for rendering when it is
// genuinely narrower than a pixel could ever show. Uranus's epsilon ring is
// 20-96 km wide against a 25,559 km planet radius -- at any sane zoom it is
// far thinner than one pixel, so drawing it at true width means drawing
// nothing. Widening it is a deliberate, documented distortion.
const MinRenderWidthKm = 260.0

// Profiles is the table the renderer consumes.
var Profiles = []Profile{
	{
		Name: "mercury", ObliquityDeg: 0.034, RotationHours: 1407.6,
		EquatorialRadiusKm: 2440.5, Kind: KindRocky,
		SurfaceColor: [3]float64{0.62, 0.60, 0.57},
	},
	{
		Name: "venus", ObliquityDeg: 177.4, RotationHours: -5832.6,
		EquatorialRadiusKm: 6051.8, Kind: KindVenus,
		SurfaceColor:    [3]float64{0.90, 0.82, 0.62},
		AtmosphereColor: [3]float64{1.0, 0.86, 0.55}, AtmospherePower: 0.85,
	},
	{
		Name: "earth", ObliquityDeg: 23.44, RotationHours: 23.93,
		EquatorialRadiusKm: 6378.1, Kind: KindEarth,
		SurfaceColor:    [3]float64{0.29, 0.53, 0.79},
		AtmosphereColor: [3]float64{0.42, 0.68, 1.0}, AtmospherePower: 0.95,
	},
	{
		Name: "mars", ObliquityDeg: 25.19, RotationHours: 24.62,
		EquatorialRadiusKm: 3396.2, Kind: KindMars,
		SurfaceColor:    [3]float64{0.78, 0.42, 0.28},
		AtmosphereColor: [3]float64{1.0, 0.68, 0.52}, AtmospherePower: 0.35,
	},
	{
		Name: "jupiter", ObliquityDeg: 3.12, RotationHours: 9.93,
		EquatorialRadiusKm: 71492, Kind: KindGas,
		SurfaceColor:    [3]float64{0.80, 0.68, 0.53},
		AtmosphereColor: [3]float64{1.0, 0.82, 0.62}, AtmospherePower: 0.55,
	},
	{
		Name: "saturn", ObliquityDeg: 26.73, RotationHours: 10.66,
		EquatorialRadiusKm: 60268, Kind: KindGas,
		SurfaceColor:    [3]float64{0.87, 0.79, 0.60},
		AtmosphereColor: [3]float64{1.0, 0.90, 0.70}, AtmospherePower: 0.45,
		RingTint: [3]float64{0.86, 0.79, 0.66},
		Rings: []RingBand{
			{Name: "C 环", InnerKm: 74658, OuterKm: 92000, Opacity: 0.26},
			{Name: "B 环", InnerKm: 92000, OuterKm: 117580, Opacity: 0.94, Brightest: true},
			{Name: "卡西尼缝", InnerKm: 117580, OuterKm: 122170, Opacity: 0.08, IsGap: true},
			{Name: "A 环", InnerKm: 122170, OuterKm: 136775, Opacity: 0.62},
			{Name: "恩克缝", InnerKm: 133589, OuterKm: 133914, Opacity: 0.06, IsGap: true},
			{Name: "基勒缝", InnerKm: 136470, OuterKm: 136512, Opacity: 0.06, IsGap: true},
		},
	},
	{
		Name: "uranus", ObliquityDeg: 97.77, RotationHours: -17.24,
		EquatorialRadiusKm: 25559, Kind: KindIce,
		SurfaceColor:    [3]float64{0.56, 0.79, 0.83},
		AtmosphereColor: [3]float64{0.62, 0.92, 0.96}, AtmospherePower: 0.60,
		// Uranus's rings are extremely dark (albedo a few percent) and almost
		// all of them are only kilometres wide. Voyager 2 is the reason we know
		// their structure at all -- it imaged them during the 1986 encounter.
		//
		// The tint below is LIFTED above the true albedo on purpose: rendered
		// at their real darkness they are invisible next to the planet, which
		// is accurate but useless. The lift is a deliberate, documented
		// distortion, the same kind as MinRenderWidthKm.
		RingTint: [3]float64{0.58, 0.60, 0.66},
		Rings: []RingBand{
			{Name: "ζ 环", InnerKm: 37850, OuterKm: 41350, Opacity: 0.10},
			{Name: "6 环", InnerKm: 41837, OuterKm: 41839, Opacity: 0.34},
			{Name: "5 环", InnerKm: 42234, OuterKm: 42237, Opacity: 0.34},
			{Name: "4 环", InnerKm: 42570, OuterKm: 42573, Opacity: 0.34},
			{Name: "α 环", InnerKm: 44718, OuterKm: 44726, Opacity: 0.42},
			{Name: "β 环", InnerKm: 45661, OuterKm: 45670, Opacity: 0.42},
			{Name: "η 环", InnerKm: 47175, OuterKm: 47177, Opacity: 0.30},
			{Name: "γ 环", InnerKm: 47627, OuterKm: 47631, Opacity: 0.38},
			{Name: "δ 环", InnerKm: 48300, OuterKm: 48305, Opacity: 0.38},
			{Name: "λ 环", InnerKm: 50023, OuterKm: 50024, Opacity: 0.16},
			{Name: "ε 环", InnerKm: 51149, OuterKm: 51245, Opacity: 0.86, Brightest: true},
			{Name: "ν 环", InnerKm: 66100, OuterKm: 69900, Opacity: 0.07},
			{Name: "μ 环", InnerKm: 86000, OuterKm: 103000, Opacity: 0.04},
		},
	},
	{
		Name: "neptune", ObliquityDeg: 28.33, RotationHours: 16.11,
		EquatorialRadiusKm: 24764, Kind: KindIce,
		SurfaceColor:    [3]float64{0.31, 0.45, 0.78},
		AtmosphereColor: [3]float64{0.42, 0.60, 1.0}, AtmospherePower: 0.65,
		// Also a Voyager 2 discovery in detail: the Adams ring's five arcs
		// were resolved during the 1989 encounter. Tint lifted for visibility,
		// same caveat as Uranus.
		RingTint: [3]float64{0.60, 0.64, 0.76},
		Rings: []RingBand{
			{Name: "伽勒环", InnerKm: 40900, OuterKm: 42900, Opacity: 0.08},
			{Name: "勒威耶环", InnerKm: 53200, OuterKm: 53313, Opacity: 0.36},
			{Name: "拉塞尔环", InnerKm: 53313, OuterKm: 57200, Opacity: 0.06},
			{Name: "阿拉戈环", InnerKm: 57200, OuterKm: 57300, Opacity: 0.20},
			{Name: "亚当斯环", InnerKm: 63930, OuterKm: 63980, Opacity: 0.62, Brightest: true},
		},
	},
	{Name: "moon", ObliquityDeg: 6.68, RotationHours: 655.72,
		EquatorialRadiusKm: 1738.1, Kind: KindMoon,
		SurfaceColor: [3]float64{0.62, 0.61, 0.58}},
	{Name: "io", ObliquityDeg: 0.0, RotationHours: 42.46,
		EquatorialRadiusKm: 1821.6, Kind: KindIo,
		SurfaceColor: [3]float64{0.85, 0.80, 0.45}},
	{Name: "europa", ObliquityDeg: 0.1, RotationHours: 85.22,
		EquatorialRadiusKm: 1560.8, Kind: KindEuropa,
		SurfaceColor: [3]float64{0.80, 0.78, 0.72}},
	{Name: "ganymede", ObliquityDeg: 0.2, RotationHours: 171.71,
		EquatorialRadiusKm: 2634.1, Kind: KindRocky,
		SurfaceColor: [3]float64{0.62, 0.58, 0.54}},
	{Name: "callisto", ObliquityDeg: 0.0, RotationHours: 400.54,
		EquatorialRadiusKm: 2410.3, Kind: KindRocky,
		SurfaceColor: [3]float64{0.45, 0.42, 0.40}},
	{Name: "titan", ObliquityDeg: 0.3, RotationHours: 382.68,
		EquatorialRadiusKm: 2574.7, Kind: KindTitan,
		SurfaceColor:    [3]float64{0.83, 0.66, 0.36},
		AtmosphereColor: [3]float64{1.0, 0.72, 0.35}, AtmospherePower: 0.75},
	{Name: "miranda", ObliquityDeg: 0.0, RotationHours: 33.92,
		EquatorialRadiusKm: 235.8, Kind: KindRocky,
		SurfaceColor: [3]float64{0.65, 0.65, 0.68}},
	{Name: "triton", ObliquityDeg: 0.0, RotationHours: -141.04,
		EquatorialRadiusKm: 1353.4, Kind: KindTriton,
		SurfaceColor: [3]float64{0.72, 0.75, 0.78}},
}

// ByName looks up a body's profile.
func ByName(name string) (Profile, bool) {
	for _, p := range Profiles {
		if p.Name == name {
			return p, true
		}
	}
	return Profile{}, false
}
