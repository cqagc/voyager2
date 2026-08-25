package horizons

import "github.com/cqagc/voyager2/internal/domain"

// Bodies lists every natural body and spacecraft tracked by the twin.
// FrameOrigin is the body that sits at the origin of the reference frame the
// whole project uses (heliocentric ecliptic J2000). Its state vector is
// identically zero by definition, so it must never be fetched: Horizons treats
// target == center as a degenerate request and stalls for minutes before
// timing out. The 2026-08-26 baseline ingest lost two minutes exactly this way.
const FrameOrigin = domain.BodySun

// Fetchable returns the bodies that should actually be requested from
// Horizons, i.e. every tracked body except the frame origin.
func Fetchable() []domain.Body {
	out := make([]domain.Body, 0, len(Bodies))
	for _, b := range Bodies {
		if b.ID == FrameOrigin {
			continue
		}
		out = append(out, b)
	}
	return out
}

var Bodies = []domain.Body{
	{
		ID:           domain.BodyVoyager2,
		Name:         "voyager2",
		Label:        "旅行者2号",
		IsSpacecraft: true,
	},
	{
		ID:           domain.BodySun,
		Name:         "sun",
		Label:        "太阳",
		MeanRadiusKm: 695700,
	},
	{
		ID:           domain.BodyMercury,
		Name:         "mercury",
		Label:        "水星",
		MeanRadiusKm: 2439.4,
	},
	{
		ID:           domain.BodyVenus,
		Name:         "venus",
		Label:        "金星",
		MeanRadiusKm: 6051.8,
	},
	{
		ID:           domain.BodyEarth,
		Name:         "earth",
		Label:        "地球",
		MeanRadiusKm: 6371.0084,
	},
	{
		ID:           domain.BodyMars,
		Name:         "mars",
		Label:        "火星",
		MeanRadiusKm: 3389.5,
	},
	{
		ID:           domain.BodyJupiter,
		Name:         "jupiter",
		Label:        "木星",
		MeanRadiusKm: 69911,
	},
	{
		ID:           domain.BodySaturn,
		Name:         "saturn",
		Label:        "土星",
		MeanRadiusKm: 58232,
	},
	{
		ID:           domain.BodyUranus,
		Name:         "uranus",
		Label:        "天王星",
		MeanRadiusKm: 25362,
	},
	{
		ID:           domain.BodyNeptune,
		Name:         "neptune",
		Label:        "海王星",
		MeanRadiusKm: 24622,
	},
	{
		ID:           domain.BodyIo,
		Name:         "io",
		Label:        "木卫一",
		MeanRadiusKm: 1821.6,
	},
	{
		ID:           domain.BodyEuropa,
		Name:         "europa",
		Label:        "木卫二",
		MeanRadiusKm: 1560.8,
	},
	{
		ID:           domain.BodyGanymede,
		Name:         "ganymede",
		Label:        "木卫三",
		MeanRadiusKm: 2634.1,
	},
	{
		ID:           domain.BodyCallisto,
		Name:         "callisto",
		Label:        "木卫四",
		MeanRadiusKm: 2410.3,
	},
	{
		ID:           domain.BodyTitan,
		Name:         "titan",
		Label:        "土卫六",
		MeanRadiusKm: 2574.73,
	},
	{
		ID:           domain.BodyMiranda,
		Name:         "miranda",
		Label:        "天卫五",
		MeanRadiusKm: 235.8,
	},
	{
		ID:           domain.BodyTriton,
		Name:         "triton",
		Label:        "海卫一",
		MeanRadiusKm: 1353.4,
	},
}
