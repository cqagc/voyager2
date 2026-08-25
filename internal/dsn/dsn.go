// Package dsn parses and polls the NASA Deep Space Network live feed.
package dsn

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
)

const (
	feedURL            = "https://eyes.nasa.gov/dsn/data/dsn.xml"
	defaultInterval    = 60 * time.Second
	defaultHistorySize = 1440
	defaultHTTPTimeout = 15 * time.Second
	initialBackoff     = time.Second
)

// Clock returns the current wall-clock time.
type Clock func() time.Time

// Feed is one complete DSN response, including every station and dish.
type Feed struct {
	// Stations contains every complex declared by the response.
	Stations []Station
	// Dishes contains every antenna with its resolved complex.
	Dishes []Dish
	// Timestamp is the feed timestamp in Unix milliseconds, when present.
	Timestamp *float64
}

// Station describes one DSN complex from the feed.
type Station struct {
	// Name is the DSN machine-facing complex name.
	Name string
	// FriendlyName is the human-facing complex name.
	FriendlyName string
	// TimeUTC is the complex timestamp in Unix milliseconds, when present.
	TimeUTC *float64
	// TimeZoneOffsetMsec is the complex UTC offset in milliseconds, when present.
	TimeZoneOffsetMsec *float64
}

// Dish describes one DSN antenna and all of its signals and targets.
type Dish struct {
	// Name is the DSS antenna designation.
	Name string
	// Site is the resolved DSN complex name.
	Site string
	// AzimuthAngle is the antenna azimuth in degrees, when present.
	AzimuthAngle *float64
	// ElevationAngle is the antenna elevation in degrees, when present.
	ElevationAngle *float64
	// WindSpeed is the reported wind speed, when present.
	WindSpeed *float64
	// IsMSPA reports whether multiple spacecraft share one antenna aperture.
	IsMSPA bool
	// IsArray reports whether the antenna is operating in an array.
	IsArray bool
	// IsDDOR reports whether the antenna is performing delta-DOR tracking.
	IsDDOR bool
	// Activity is the feed's human-facing activity description.
	Activity string
	// UpSignals contains all uplink signals on the antenna.
	UpSignals []Signal
	// DownSignals contains all downlink signals on the antenna.
	DownSignals []Signal
	// Targets contains all ranging targets on the antenna.
	Targets []Target
}

// Signal describes one uplink or downlink carried by a dish.
type Signal struct {
	// Active reports whether the signal is currently active.
	Active bool
	// SignalType is the feed's signal classification.
	SignalType string
	// DataRate is the signal data rate in bits per second, when present.
	DataRate *float64
	// Frequency is the signal frequency in hertz, when present.
	Frequency *float64
	// Band is the DSN radio band designation.
	Band string
	// Power is the reported signal power, when present.
	Power *float64
	// Spacecraft is the DSN spacecraft name.
	Spacecraft string
	// SpacecraftID is the JPL spacecraft identifier, when present.
	SpacecraftID *int
}

// Target describes ranging information for a dish target.
type Target struct {
	// Name is the DSN target name.
	Name string
	// ID is the unsigned target identifier used by target elements, when present.
	ID *int
	// UplegRange is the reported uplink range, when present.
	UplegRange *float64
	// DownlegRange is the reported downlink range, when present.
	DownlegRange *float64
	// RTLT is the round-trip light time in seconds, when present.
	RTLT *float64
}

// Options configures a Poller. Zero values select the documented defaults.
type Options struct {
	// Client performs feed requests; nil selects a timeout-enabled default.
	Client *http.Client
	// Interval controls successful poll spacing; non-positive selects 60 seconds.
	Interval time.Duration
	// HistorySize controls snapshot retention; non-positive selects 1440.
	HistorySize int
	// Clock supplies observation times; nil selects time.Now.
	Clock Clock
}

// Callback receives a snapshot when the observed link state changes.
// Callbacks run synchronously and should return promptly.
type Callback func(domain.LinkState)

// Poller periodically fetches DSN state and stores concurrency-safe snapshots.
type Poller struct {
	client       *http.Client
	interval     time.Duration
	historySize  int
	clock        Clock
	spacecraftID int

	mu          sync.RWMutex
	latest      domain.LinkState
	hasLatest   bool
	history     []domain.LinkState
	historyNext int
	subscribers map[uint64]Callback
	nextID      uint64
}

// NewPoller creates a DSN poller for spacecraftID.
func NewPoller(spacecraftID int, options Options) *Poller {
	client := options.Client
	if client == nil {
		client = &http.Client{Timeout: defaultHTTPTimeout}
	}
	interval := options.Interval
	if interval <= 0 {
		interval = defaultInterval
	}
	historySize := options.HistorySize
	if historySize <= 0 {
		historySize = defaultHistorySize
	}
	clock := options.Clock
	if clock == nil {
		clock = time.Now
	}

	return &Poller{
		client:       client,
		interval:     interval,
		historySize:  historySize,
		clock:        clock,
		spacecraftID: spacecraftID,
		history:      make([]domain.LinkState, 0, historySize),
		subscribers:  make(map[uint64]Callback),
	}
}

// Parse decodes a complete DSN feed without filtering its dishes.
func Parse(r io.Reader) (Feed, error) {
	decoder := xml.NewDecoder(r)
	var feed Feed
	var currentSite string
	seenRoot := false

	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return Feed{}, fmt.Errorf("parse DSN XML: %w", err)
		}

		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		if !seenRoot {
			if start.Name.Local != "dsn" {
				return Feed{}, fmt.Errorf("parse DSN XML: root element is %q, want %q", start.Name.Local, "dsn")
			}
			seenRoot = true
			continue
		}

		switch start.Name.Local {
		case "station":
			station, err := decodeStation(decoder, start)
			if err != nil {
				return Feed{}, err
			}
			feed.Stations = append(feed.Stations, station)
			currentSite = station.FriendlyName
		case "dish":
			dish, err := decodeDish(decoder, start)
			if err != nil {
				return Feed{}, err
			}
			// station 和 dish 是兄弟节点，且 CDN 内容顺序可能变化。因此以稳定的
			// DSS 编号映射为主判据，仅在未知编号时使用前置 station 兜底。
			dish.Site = siteForDish(dish.Name, currentSite)
			feed.Dishes = append(feed.Dishes, dish)
		case "timestamp":
			var value string
			if err := decoder.DecodeElement(&value, &start); err != nil {
				return Feed{}, fmt.Errorf("parse DSN timestamp: %w", err)
			}
			feed.Timestamp, err = parseOptionalFloat("timestamp", strings.TrimSpace(value))
			if err != nil {
				return Feed{}, err
			}
		}
	}

	if !seenRoot {
		return Feed{}, fmt.Errorf("parse DSN XML: missing root element")
	}
	return feed, nil
}

// LinkState extracts the active downlink state for spacecraftID.
func (f Feed) LinkState(spacecraftID int, observedAt time.Time) (domain.LinkState, error) {
	state := domain.LinkState{ObservedAt: observedAt}
	if spacecraftID == int(domain.BodyVoyager2) {
		state.Spacecraft = "VGR2"
	}

	for _, dish := range f.Dishes {
		for _, downlink := range dish.DownSignals {
			if !downlink.Active || !signalMatches(downlink, spacecraftID) {
				continue
			}

			state.Connected = true
			state.Spacecraft = downlink.Spacecraft
			state.Antenna = dish.Name
			state.Site = dish.Site
			state.DownlinkBitrate = valueOrZero(downlink.DataRate)
			state.DownlinkFreqHz = valueOrZero(downlink.Frequency)
			state.SignalPowerDBm = valueOrZero(downlink.Power)
			state.UplinkPowerKW = activeUplinkPower(dish.UpSignals, spacecraftID)
			state.RoundTripLightTimeSec = targetRTLT(dish.Targets, spacecraftID, downlink.Spacecraft)
			return state, nil
		}
	}

	return state, nil
}

// PollOnce fetches, parses, and stores one DSN snapshot.
func (p *Poller) PollOnce(ctx context.Context) (domain.LinkState, error) {
	requestURL, err := url.Parse(feedURL)
	if err != nil {
		return domain.LinkState{}, fmt.Errorf("parse DSN URL: %w", err)
	}
	now := p.clock()
	query := requestURL.Query()
	query.Set("r", strconv.FormatInt(now.UnixMilli(), 10))
	requestURL.RawQuery = query.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return domain.LinkState{}, fmt.Errorf("create DSN request: %w", err)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return domain.LinkState{}, fmt.Errorf("fetch DSN feed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return domain.LinkState{}, fmt.Errorf("fetch DSN feed: unexpected HTTP status %s", resp.Status)
	}

	feed, err := Parse(resp.Body)
	if err != nil {
		return domain.LinkState{}, err
	}
	state, err := feed.LinkState(p.spacecraftID, now)
	if err != nil {
		return domain.LinkState{}, err
	}
	p.store(state)
	return state, nil
}

// Run polls until ctx is cancelled. Transient failures are retried with
// exponential backoff and do not stop the poller.
func (p *Poller) Run(ctx context.Context) error {
	backoff := min(initialBackoff, p.interval)
	for {
		_, err := p.PollOnce(ctx)
		if err != nil && ctx.Err() != nil {
			return ctx.Err()
		}

		delay := p.interval
		if err != nil {
			delay = backoff
			backoff = min(backoff*2, p.interval)
		} else {
			backoff = min(initialBackoff, p.interval)
		}

		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// Latest returns the newest snapshot and whether one has been stored.
func (p *Poller) Latest() (domain.LinkState, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.latest, p.hasLatest
}

// History returns retained snapshots in chronological order.
func (p *Poller) History() []domain.LinkState {
	p.mu.RLock()
	defer p.mu.RUnlock()

	result := make([]domain.LinkState, len(p.history))
	if len(p.history) < p.historySize || p.historyNext == 0 {
		copy(result, p.history)
		return result
	}
	count := copy(result, p.history[p.historyNext:])
	copy(result[count:], p.history[:p.historyNext])
	return result
}

// Subscribe registers a callback and returns an unsubscribe function.
func (p *Poller) Subscribe(callback Callback) func() {
	p.mu.Lock()
	id := p.nextID
	p.nextID++
	p.subscribers[id] = callback
	p.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			p.mu.Lock()
			delete(p.subscribers, id)
			p.mu.Unlock()
		})
	}
}

func (p *Poller) store(state domain.LinkState) {
	p.mu.Lock()
	changed := !p.hasLatest || !sameLinkState(p.latest, state)
	p.latest = state
	p.hasLatest = true
	if len(p.history) < p.historySize {
		p.history = append(p.history, state)
		p.historyNext = len(p.history) % p.historySize
	} else {
		p.history[p.historyNext] = state
		p.historyNext = (p.historyNext + 1) % p.historySize
	}

	callbacks := make([]Callback, 0, len(p.subscribers))
	if changed {
		for _, callback := range p.subscribers {
			callbacks = append(callbacks, callback)
		}
	}
	p.mu.Unlock()

	for _, callback := range callbacks {
		callback(state)
	}
}

func sameLinkState(a, b domain.LinkState) bool {
	a.ObservedAt = time.Time{}
	b.ObservedAt = time.Time{}
	return a == b
}

type rawStation struct {
	Name           string `xml:"name,attr"`
	FriendlyName   string `xml:"friendlyName,attr"`
	TimeUTC        string `xml:"timeUTC,attr"`
	TimeZoneOffset string `xml:"timeZoneOffset,attr"`
}

type rawDish struct {
	Name           string      `xml:"name,attr"`
	AzimuthAngle   string      `xml:"azimuthAngle,attr"`
	ElevationAngle string      `xml:"elevationAngle,attr"`
	WindSpeed      string      `xml:"windSpeed,attr"`
	IsMSPA         bool        `xml:"isMSPA,attr"`
	IsArray        bool        `xml:"isArray,attr"`
	IsDDOR         bool        `xml:"isDDOR,attr"`
	Activity       string      `xml:"activity,attr"`
	UpSignals      []rawSignal `xml:"upSignal"`
	DownSignals    []rawSignal `xml:"downSignal"`
	Targets        []rawTarget `xml:"target"`
}

type rawSignal struct {
	Active       bool   `xml:"active,attr"`
	SignalType   string `xml:"signalType,attr"`
	DataRate     string `xml:"dataRate,attr"`
	Frequency    string `xml:"frequency,attr"`
	Band         string `xml:"band,attr"`
	Power        string `xml:"power,attr"`
	Spacecraft   string `xml:"spacecraft,attr"`
	SpacecraftID string `xml:"spacecraftID,attr"`
}

type rawTarget struct {
	Name         string `xml:"name,attr"`
	ID           string `xml:"id,attr"`
	UplegRange   string `xml:"uplegRange,attr"`
	DownlegRange string `xml:"downlegRange,attr"`
	RTLT         string `xml:"rtlt,attr"`
}

func decodeStation(decoder *xml.Decoder, start xml.StartElement) (Station, error) {
	var raw rawStation
	if err := decoder.DecodeElement(&raw, &start); err != nil {
		return Station{}, fmt.Errorf("parse DSN station: %w", err)
	}
	timeUTC, err := parseOptionalFloat("station timeUTC", raw.TimeUTC)
	if err != nil {
		return Station{}, err
	}
	timeZoneOffset, err := parseOptionalFloat("station timeZoneOffset", raw.TimeZoneOffset)
	if err != nil {
		return Station{}, err
	}
	return Station{
		Name:               raw.Name,
		FriendlyName:       raw.FriendlyName,
		TimeUTC:            timeUTC,
		TimeZoneOffsetMsec: timeZoneOffset,
	}, nil
}

func decodeDish(decoder *xml.Decoder, start xml.StartElement) (Dish, error) {
	var raw rawDish
	if err := decoder.DecodeElement(&raw, &start); err != nil {
		return Dish{}, fmt.Errorf("parse DSN dish: %w", err)
	}

	azimuth, err := parseOptionalFloat("dish azimuthAngle", raw.AzimuthAngle)
	if err != nil {
		return Dish{}, err
	}
	elevation, err := parseOptionalFloat("dish elevationAngle", raw.ElevationAngle)
	if err != nil {
		return Dish{}, err
	}
	windSpeed, err := parseOptionalFloat("dish windSpeed", raw.WindSpeed)
	if err != nil {
		return Dish{}, err
	}

	dish := Dish{
		Name:           raw.Name,
		AzimuthAngle:   azimuth,
		ElevationAngle: elevation,
		WindSpeed:      windSpeed,
		IsMSPA:         raw.IsMSPA,
		IsArray:        raw.IsArray,
		IsDDOR:         raw.IsDDOR,
		Activity:       raw.Activity,
		UpSignals:      make([]Signal, 0, len(raw.UpSignals)),
		DownSignals:    make([]Signal, 0, len(raw.DownSignals)),
		Targets:        make([]Target, 0, len(raw.Targets)),
	}
	for _, signal := range raw.UpSignals {
		parsed, err := parseSignal(signal)
		if err != nil {
			return Dish{}, err
		}
		dish.UpSignals = append(dish.UpSignals, parsed)
	}
	for _, signal := range raw.DownSignals {
		parsed, err := parseSignal(signal)
		if err != nil {
			return Dish{}, err
		}
		dish.DownSignals = append(dish.DownSignals, parsed)
	}
	for _, target := range raw.Targets {
		parsed, err := parseTarget(target)
		if err != nil {
			return Dish{}, err
		}
		dish.Targets = append(dish.Targets, parsed)
	}
	return dish, nil
}

func parseSignal(raw rawSignal) (Signal, error) {
	dataRate, err := parseOptionalFloat("signal dataRate", raw.DataRate)
	if err != nil {
		return Signal{}, err
	}
	frequency, err := parseOptionalFloat("signal frequency", raw.Frequency)
	if err != nil {
		return Signal{}, err
	}
	power, err := parseOptionalFloat("signal power", raw.Power)
	if err != nil {
		return Signal{}, err
	}
	spacecraftID, err := parseOptionalInt("signal spacecraftID", raw.SpacecraftID)
	if err != nil {
		return Signal{}, err
	}
	return Signal{
		Active:       raw.Active,
		SignalType:   raw.SignalType,
		DataRate:     dataRate,
		Frequency:    frequency,
		Band:         raw.Band,
		Power:        power,
		Spacecraft:   raw.Spacecraft,
		SpacecraftID: spacecraftID,
	}, nil
}

func parseTarget(raw rawTarget) (Target, error) {
	id, err := parseOptionalInt("target id", raw.ID)
	if err != nil {
		return Target{}, err
	}
	uplegRange, err := parseOptionalFloat("target uplegRange", raw.UplegRange)
	if err != nil {
		return Target{}, err
	}
	downlegRange, err := parseOptionalFloat("target downlegRange", raw.DownlegRange)
	if err != nil {
		return Target{}, err
	}
	rtlt, err := parseOptionalFloat("target rtlt", raw.RTLT)
	if err != nil {
		return Target{}, err
	}
	return Target{
		Name:         raw.Name,
		ID:           id,
		UplegRange:   uplegRange,
		DownlegRange: downlegRange,
		RTLT:         rtlt,
	}, nil
}

func parseOptionalFloat(field, value string) (*float64, error) {
	if value == "" || value == "-1" {
		return nil, nil
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return nil, fmt.Errorf("parse DSN %s %q: %w", field, value, err)
	}
	return &parsed, nil
}

func parseOptionalInt(field, value string) (*int, error) {
	if value == "" || value == "-1" {
		return nil, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return nil, fmt.Errorf("parse DSN %s %q: %w", field, value, err)
	}
	return &parsed, nil
}

func siteForDish(name, fallback string) string {
	switch name {
	case "DSS14", "DSS24", "DSS26":
		return "Goldstone"
	case "DSS34", "DSS35", "DSS36", "DSS43":
		return "Canberra"
	case "DSS53", "DSS54", "DSS55", "DSS56", "DSS63", "DSS65":
		return "Madrid"
	default:
		return fallback
	}
}

func signalMatches(signal Signal, spacecraftID int) bool {
	if signal.SpacecraftID != nil {
		return *signal.SpacecraftID == spacecraftID
	}
	return spacecraftID == int(domain.BodyVoyager2) && signal.Spacecraft == "VGR2"
}

func activeUplinkPower(signals []Signal, spacecraftID int) float64 {
	for _, signal := range signals {
		if signal.Active && signalMatches(signal, spacecraftID) {
			return valueOrZero(signal.Power)
		}
	}
	return 0
}

func targetRTLT(targets []Target, spacecraftID int, spacecraft string) float64 {
	targetID := spacecraftID
	if targetID < 0 {
		targetID = -targetID
	}
	for _, target := range targets {
		if target.ID != nil && *target.ID == targetID {
			return valueOrZero(target.RTLT)
		}
		if target.ID == nil && target.Name == spacecraft {
			return valueOrZero(target.RTLT)
		}
	}
	return 0
}

func valueOrZero(value *float64) float64 {
	if value == nil {
		return 0
	}
	return *value
}
