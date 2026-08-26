// Command export writes the twin's data bundle for the Godot front end.
//
// Godot cannot read the SQLite store, and scrubbing a 49-year timeline wants
// every sample resident in memory anyway, so the bundle is two files:
//
//	ephemeris.bin   packed float64 state vectors, one block per body
//	metadata.json   bodies, components, flyby events, and the modelled
//	                RTG power curve
//
// The power curve is exported rather than reimplemented in GDScript on
// purpose: internal/power stays the single source of truth for the physics,
// and the front end cannot silently drift from it.
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/cqagc/voyager2/internal/bodies"
	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/horizons"
	"github.com/cqagc/voyager2/internal/model"
	"github.com/cqagc/voyager2/internal/orbit"
	"github.com/cqagc/voyager2/internal/power"
	"github.com/cqagc/voyager2/internal/store"
)

// Magic identifies the ephemeris container and its layout version.
const Magic = "V2TWIN01"

// BodyMeta describes one tracked body in metadata.json.
type BodyMeta struct {
	ID           int     `json:"id"`
	Name         string  `json:"name"`
	Label        string  `json:"label"`
	MeanRadiusKm float64 `json:"mean_radius_km"`
	IsSpacecraft bool    `json:"is_spacecraft"`
	Samples      int     `json:"samples"`
	JDMin        float64 `json:"jd_min"`
	JDMax        float64 `json:"jd_max"`
	// ByteOffset is where this body's sample block starts in ephemeris.bin.
	ByteOffset int64 `json:"byte_offset"`
}

// PowerPoint is one sample of the modelled RTG output.
type PowerPoint struct {
	JD    float64 `json:"jd"`
	Watts float64 `json:"watts"`
	// FuelFraction and ConverterFraction let the UI show that fuel decay and
	// thermocouple degradation each account for about half the loss, instead
	// of the usual "the plutonium is running out" half-truth.
	FuelFraction      float64 `json:"fuel_fraction"`
	ConverterFraction float64 `json:"converter_fraction"`
}

// Event is a dated mission milestone for the timeline.
type Event struct {
	JD    float64 `json:"jd"`
	Date  string  `json:"date"`
	Label string  `json:"label"`
	// Focus names the body the camera should frame, empty for none.
	Focus string `json:"focus"`
}

// ComponentMeta is one clickable part of the spacecraft.
type ComponentMeta struct {
	ID     string `json:"id"`
	Node   string `json:"node"`
	Parent string `json:"parent,omitempty"`
	// DistinctGeometry is false when the visual model does not separate this
	// component and the ID aliases to a containing node.
	DistinctGeometry bool   `json:"distinct_geometry"`
	ConfidenceNote   string `json:"confidence_note"`
}

// SatelliteElements is a moon's Keplerian orbit, shipped so the front end can
// draw its orbit ring without needing dense ephemeris.
//
// Only the GEOMETRY is trustworthy. internal/orbit's tests measure the phase
// error against real ephemeris in the flyby windows: 19% to 200% of the
// semi-major axis, i.e. up to the opposite side of the planet, because the
// encounters are 11-21 years from the J2000 element epoch. So the front end
// must draw the ring from these elements but take the moon's POSITION from the
// ephemeris, and hide the moon where the ephemeris is too coarse to resolve
// its period.
type SatelliteElements struct {
	Name         string  `json:"name"`
	Label        string  `json:"label"`
	Parent       string  `json:"parent"`
	SemiMajorKm  float64 `json:"semi_major_km"`
	Ecc          float64 `json:"ecc"`
	IncDeg       float64 `json:"inc_deg"`
	ArgPeriDeg   float64 `json:"arg_peri_deg"`
	NodeDeg      float64 `json:"node_deg"`
	MeanAnomDeg  float64 `json:"mean_anom_deg"`
	PeriodDays   float64 `json:"period_days"`
	EpochJD      float64 `json:"epoch_jd"`
	MeanRadiusKm float64 `json:"mean_radius_km"`
	// PhaseTrustworthy is false for every satellite here, recorded explicitly
	// so the front end cannot assume otherwise by omission.
	PhaseTrustworthy bool `json:"phase_trustworthy"`
}

// SatelliteCheckPoint is one reference evaluation of the Kepler solver.
type SatelliteCheckPoint struct {
	Name string  `json:"name"`
	JD   float64 `json:"jd"`
	// ObliquityDeg is the parent obliquity used, so the front end applies the
	// same frame rotation.
	ObliquityDeg float64 `json:"obliquity_deg"`
	// OffsetKm is the expected offset from the parent in ecliptic J2000.
	OffsetKm [3]float64 `json:"offset_km"`
}

// Bundle is metadata.json.
type Bundle struct {
	Generated  string          `json:"generated"`
	Magic      string          `json:"ephemeris_magic"`
	Frame      string          `json:"frame"`
	Units      string          `json:"units"`
	AUkm       float64         `json:"au_km"`
	Bodies     []BodyMeta      `json:"bodies"`
	Components []ComponentMeta `json:"components"`
	PowerCurve []PowerPoint    `json:"power_curve"`
	Events     []Event         `json:"events"`
	// Profiles carries obliquity, rotation, ring systems and appearance for
	// every body. Kept in Go (internal/bodies) rather than duplicated in
	// GDScript so the two cannot drift apart.
	Profiles   []bodies.Profile    `json:"profiles"`
	Satellites []SatelliteElements `json:"satellites"`
	// RingRenderFloorKm is the width narrow rings are widened to for
	// rendering. Uranus's rings are 1-96 km wide against a 25,559 km planet;
	// at true width they would be far thinner than a pixel at any zoom.
	RingRenderFloorKm float64 `json:"ring_render_floor_km"`
	// SatelliteCheck is a cross-language contract fixture. The front end
	// reimplements the Kepler solver in GDScript for per-frame use; these
	// reference values let it verify it agrees with the Go implementation
	// instead of the two silently drifting apart.
	SatelliteCheck []SatelliteCheckPoint `json:"satellite_check"`
	// ProvenanceLegend spells out what each label means, so the front end
	// cannot present a modelled number as a measurement by omission.
	ProvenanceLegend map[string]string `json:"provenance_legend"`
}

func main() {
	dbPath := flag.String("db", "data/voyager2.db", "SQLite 数据库路径")
	outDir := flag.String("out", "godot/data", "输出目录")
	assignPath := flag.String("assignment", "assets/generated/assignment.json", "组件归属文件")
	powerStep := flag.Int("power-step-days", 30, "RTG 功率曲线采样间隔（天）")
	flag.Parse()

	if err := run(*dbPath, *outDir, *assignPath, *powerStep); err != nil {
		slog.Error("export failed", "err", err)
		os.Exit(1)
	}
}

func run(dbPath, outDir, assignPath string, powerStepDays int) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	db, err := store.Open(dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	binPath := filepath.Join(outDir, "ephemeris.bin")
	f, err := os.Create(binPath)
	if err != nil {
		return err
	}
	defer f.Close()

	if _, err := f.WriteString(Magic); err != nil {
		return err
	}
	offset := int64(len(Magic))

	var metas []BodyMeta
	for _, body := range horizons.Bodies {
		lo, hi, count, err := db.Coverage(body.ID)
		if err != nil || count == 0 {
			slog.Warn("skipping body with no data", "body", body.Name)
			continue
		}
		vectors, err := db.GetRange(body.ID, lo, hi)
		if err != nil {
			return fmt.Errorf("read %s: %w", body.Name, err)
		}

		buf := make([]byte, 0, len(vectors)*56)
		for _, v := range vectors {
			for _, d := range [7]float64{v.JDTDB, v.Pos.X, v.Pos.Y, v.Pos.Z, v.Vel.X, v.Vel.Y, v.Vel.Z} {
				buf = binary.LittleEndian.AppendUint64(buf, math.Float64bits(d))
			}
		}
		if _, err := f.Write(buf); err != nil {
			return err
		}

		metas = append(metas, BodyMeta{
			ID: int(body.ID), Name: body.Name, Label: body.Label,
			MeanRadiusKm: body.MeanRadiusKm, IsSpacecraft: body.IsSpacecraft,
			Samples: len(vectors), JDMin: vectors[0].JDTDB,
			JDMax: vectors[len(vectors)-1].JDTDB, ByteOffset: offset,
		})
		offset += int64(len(buf))
		slog.Info("packed body", "body", body.Name, "samples", len(vectors))
	}
	if len(metas) == 0 {
		return fmt.Errorf("no bodies had data in %s; run cmd/ingest first", dbPath)
	}

	components, err := componentMeta(assignPath)
	if err != nil {
		return err
	}

	bundle := Bundle{
		Generated: time.Now().UTC().Format(time.RFC3339),
		Magic:     Magic,
		Frame:     "heliocentric ecliptic J2000",
		Units:     "km, km/s, JDTDB",
		AUkm:      domain.AU,
		Bodies:    metas, Components: components,
		PowerCurve:        powerCurve(powerStepDays),
		Events:            events(),
		Profiles:          bodies.Profiles,
		Satellites:        satelliteElements(),
		RingRenderFloorKm: bodies.MinRenderWidthKm,
		SatelliteCheck:    satelliteCheck(),
		ProvenanceLegend: map[string]string{
			string(domain.ProvMeasured):     "归档实测数据",
			string(domain.ProvLive):         "近实时观测（目前仅 DSN 链路状态）",
			string(domain.ProvModelled):     "物理模型推演，非测量值",
			string(domain.ProvInterpolated): "实测样本之间的插值结果",
		},
	}
	jsonPath := filepath.Join(outDir, "metadata.json")
	jf, err := os.Create(jsonPath)
	if err != nil {
		return err
	}
	defer jf.Close()
	enc := json.NewEncoder(jf)
	enc.SetIndent("", " ")
	if err := enc.Encode(bundle); err != nil {
		return err
	}

	info, _ := f.Stat()
	slog.Info("export complete",
		"ephemeris", binPath, "ephemeris_bytes", info.Size(),
		"metadata", jsonPath, "bodies", len(metas),
		"components", len(components), "power_points", len(bundle.PowerCurve))
	return nil
}

func componentMeta(path string) ([]ComponentMeta, error) {
	a, err := model.Load(path)
	if err != nil {
		return nil, fmt.Errorf("load assignment (run tools/model/assign.py --mode export): %w", err)
	}
	if err := a.Verify(); err != nil {
		return nil, fmt.Errorf("assignment violates the domain contract: %w", err)
	}
	out := make([]ComponentMeta, 0, len(domain.AllComponents))
	for _, c := range domain.AllComponents {
		node, distinct := a.Resolve(c)
		out = append(out, ComponentMeta{
			ID: string(c), Node: node, Parent: a.Parents[string(c)],
			DistinctGeometry: distinct,
			ConfidenceNote:   a.Components[node].ConfidenceNote,
		})
	}
	return out, nil
}

func powerCurve(stepDays int) []PowerPoint {
	var out []PowerPoint
	end := time.Date(2035, 1, 1, 0, 0, 0, 0, time.UTC)
	for t := power.LaunchTime; t.Before(end); t = t.AddDate(0, 0, stepDays) {
		out = append(out, PowerPoint{
			JD: domain.TimeToJD(t), Watts: power.TotalWatts(t),
			FuelFraction:      power.FuelFractionRemaining(t),
			ConverterFraction: power.ConverterEfficiencyFraction(t),
		})
	}
	return out
}

func events() []Event {
	type raw struct {
		date, label, focus string
	}
	rows := []raw{
		{"1977-08-20", "发射（卡纳维拉尔角，泰坦 IIIE/半人马座）", ""},
		{"1979-07-09", "木星最近接近", "jupiter"},
		{"1981-08-26", "土星最近接近", "saturn"},
		{"1986-01-24", "天王星最近接近（人类唯一一次造访）", "uranus"},
		{"1989-08-25", "海王星最近接近（人类唯一一次造访）", "neptune"},
		{"2018-11-05", "穿越日球层顶，进入星际空间", ""},
	}
	out := make([]Event, 0, len(rows))
	for _, r := range rows {
		t, err := time.Parse(time.DateOnly, r.date)
		if err != nil {
			continue
		}
		out = append(out, Event{JD: domain.TimeToJD(t), Date: r.date, Label: r.label, Focus: r.focus})
	}
	return out
}

func satelliteElements() []SatelliteElements {
	out := make([]SatelliteElements, 0, len(orbit.Satellites))
	for _, e := range orbit.Satellites {
		out = append(out, SatelliteElements{
			Name: e.Name, Label: e.Label, Parent: e.Parent,
			SemiMajorKm: e.SemiMajorKm, Ecc: e.Ecc, IncDeg: e.IncDeg,
			ArgPeriDeg: e.ArgPeriDeg, NodeDeg: e.NodeDeg,
			MeanAnomDeg: e.MeanAnomDeg, PeriodDays: e.PeriodDays,
			EpochJD: orbit.J2000, MeanRadiusKm: e.MeanRadiusKm,
			PhaseTrustworthy: false,
		})
	}
	return out
}

// satelliteCheck evaluates the Go Kepler solver at fixed epochs so the front
// end can prove its GDScript port matches.
func satelliteCheck() []SatelliteCheckPoint {
	epochs := []float64{orbit.J2000, orbit.J2000 + 0.37, orbit.J2000 + 1234.5,
		orbit.J2000 - 8000.25, 2461278.0}
	out := make([]SatelliteCheckPoint, 0, len(orbit.Satellites)*len(epochs))
	for _, e := range orbit.Satellites {
		prof, ok := bodies.ByName(e.Parent)
		obl := 0.0
		if ok {
			obl = prof.ObliquityDeg
		}
		for _, jd := range epochs {
			p := e.PositionEclipticOffset(jd, obl)
			out = append(out, SatelliteCheckPoint{
				Name: e.Name, JD: jd, ObliquityDeg: obl,
				OffsetKm: [3]float64{p.X, p.Y, p.Z},
			})
		}
	}
	return out
}
