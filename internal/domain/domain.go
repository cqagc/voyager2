// Package domain defines the shared data contract for the Voyager 2 digital twin.
//
// Conventions fixed here are binding for every other package:
//
//   - Reference frame: heliocentric ecliptic J2000 (Horizons: CENTER='@sun',
//     REF_PLANE='ECLIPTIC').
//   - Length in km, velocity in km/s, always float64. Never float32 anywhere
//     on the Go side; precision loss is the renderer's problem, not ours.
//   - Canonical epoch is Barycentric Dynamical Time as a Julian Date (JDTDB),
//     exactly what Horizons emits. UTC conversion is a display concern.
package domain

import "time"

// AU is one astronomical unit in kilometres (IAU 2012 definition, exact).
const AU = 149597870.7

// Vec3 is a 3-component double-precision vector in the frame documented by
// whatever carries it. Always km or km/s.
type Vec3 struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
}

// StateVector is one body's position and velocity at one epoch, in
// heliocentric ecliptic J2000.
type StateVector struct {
	// JDTDB is the epoch as a Julian Date in Barycentric Dynamical Time.
	JDTDB float64 `json:"jdtdb"`
	// Pos is position in km.
	Pos Vec3 `json:"pos"`
	// Vel is velocity in km/s.
	Vel Vec3 `json:"vel"`
}

// BodyID is a JPL Horizons target code. Negative values are spacecraft.
type BodyID int

// Bodies tracked by the twin. Codes are Horizons COMMAND values.
const (
	BodyVoyager2 BodyID = -32
	BodySun      BodyID = 10
	BodyMercury  BodyID = 199
	BodyVenus    BodyID = 299
	BodyEarth    BodyID = 399
	BodyMars     BodyID = 499
	BodyJupiter  BodyID = 599
	BodySaturn   BodyID = 699
	BodyUranus   BodyID = 799
	BodyNeptune  BodyID = 899

	// Flyby-relevant satellites.
	BodyIo       BodyID = 501
	BodyEuropa   BodyID = 502
	BodyGanymede BodyID = 503
	BodyCallisto BodyID = 504
	BodyTitan    BodyID = 606
	BodyMiranda  BodyID = 705
	BodyTriton   BodyID = 801
)

// Body is a tracked object's static metadata.
type Body struct {
	ID BodyID `json:"id"`
	// Name is the stable machine-facing key, e.g. "voyager2", "jupiter".
	Name string `json:"name"`
	// Label is the human-facing name, e.g. "旅行者2号".
	Label string `json:"label"`
	// MeanRadiusKm is 0 for spacecraft.
	MeanRadiusKm float64 `json:"mean_radius_km"`
	// IsSpacecraft distinguishes the probe from natural bodies.
	IsSpacecraft bool `json:"is_spacecraft"`
}

// Provenance declares where a value actually came from. Every number the UI
// shows must carry one of these. This exists because Voyager 2 publishes NO
// public engineering telemetry: modelled values must never be presentable as
// measurements.
type Provenance string

const (
	// ProvMeasured is real archived instrument or ephemeris data.
	ProvMeasured Provenance = "measured"
	// ProvLive is data observed in near-real-time (currently only the DSN link).
	ProvLive Provenance = "live"
	// ProvModelled is computed from a physical model, not observed.
	ProvModelled Provenance = "modelled"
	// ProvInterpolated is measured data resampled between known samples.
	ProvInterpolated Provenance = "interpolated"
)

// Sample is one scalar value with units and provenance.
type Sample struct {
	JDTDB     float64    `json:"jdtdb"`
	Value     float64    `json:"value"`
	Unit      string     `json:"unit"`
	Prov      Provenance `json:"prov"`
	Confident bool       `json:"confident"`
}

// LinkState is the Deep Space Network downlink status for one spacecraft.
// This is the twin's only genuinely live signal.
type LinkState struct {
	// ObservedAt is wall-clock time the DSN feed was read.
	ObservedAt time.Time `json:"observed_at"`
	// Spacecraft is the DSN feed's spacecraft identifier, e.g. "VGR2".
	Spacecraft string `json:"spacecraft"`
	// Antenna is the dish designation, e.g. "DSS 43".
	Antenna string `json:"antenna"`
	// Site is the complex, e.g. "Canberra".
	Site string `json:"site"`
	// DownlinkBitrate is bits per second, 0 when not downlinking.
	DownlinkBitrate float64 `json:"downlink_bitrate_bps"`
	// DownlinkFreqHz is the received carrier frequency.
	DownlinkFreqHz float64 `json:"downlink_freq_hz"`
	// SignalPowerDBm is received signal power, typically strongly negative.
	SignalPowerDBm float64 `json:"signal_power_dbm"`
	// UplinkPowerKW is transmitted uplink power, 0 when not uplinking.
	UplinkPowerKW float64 `json:"uplink_power_kw"`
	// RoundTripLightTimeSec is the feed's RTLT for this target.
	RoundTripLightTimeSec float64 `json:"rtlt_sec"`
	// Connected reports whether any dish is currently carrying this target.
	Connected bool `json:"connected"`
}

// ComponentID identifies a physical part of the spacecraft. These strings are
// the contract between the Blender export, the Godot scene tree, and the
// backend's per-component state. Changing one means changing all three.
type ComponentID string

const (
	CompBus              ComponentID = "Bus"
	CompHighGainAntenna  ComponentID = "HighGainAntenna"
	CompRTG1             ComponentID = "RTG_1"
	CompRTG2             ComponentID = "RTG_2"
	CompRTG3             ComponentID = "RTG_3"
	CompRTGBoom          ComponentID = "RTGBoom"
	CompMagnetometerBoom ComponentID = "MagnetometerBoom"
	CompScienceBoom      ComponentID = "ScienceBoom"
	CompScanPlatform     ComponentID = "ScanPlatform"
	CompThrusters        ComponentID = "Thrusters"
	CompInstrumentCRS    ComponentID = "Instrument_CRS"
	CompInstrumentLECP   ComponentID = "Instrument_LECP"
	CompInstrumentPLS    ComponentID = "Instrument_PLS"
	CompInstrumentMAG    ComponentID = "Instrument_MAG"
	CompInstrumentPWS    ComponentID = "Instrument_PWS"
)

// AllComponents is the authoritative component list. The Blender split must
// produce exactly these node names (CompRTGBoom et al. may be structural
// parents rather than leaf meshes).
var AllComponents = []ComponentID{
	CompBus, CompHighGainAntenna,
	CompRTGBoom, CompRTG1, CompRTG2, CompRTG3,
	CompMagnetometerBoom, CompScienceBoom, CompScanPlatform, CompThrusters,
	CompInstrumentCRS, CompInstrumentLECP, CompInstrumentPLS,
	CompInstrumentMAG, CompInstrumentPWS,
}
