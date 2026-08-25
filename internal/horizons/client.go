package horizons

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
)

const (
	// Endpoint is the public JPL Horizons API endpoint.
	Endpoint = "https://ssd.jpl.nasa.gov/api/horizons.api"
	// DefaultMinInterval is the default delay between outbound requests.
	DefaultMinInterval = time.Second

	// DefaultHTTPTimeout must accommodate the slowest single request the
	// project makes: Voyager 2's full 49-year daily ephemeris. Spacecraft SPK
	// queries are far slower than planetary ones -- the 2026-08-26 baseline
	// ingest lost the spacecraft itself to a 2-minute timeout -- so this is
	// deliberately generous. Segmentation bounds response size, not the
	// server-side integration work.
	DefaultHTTPTimeout = 10 * time.Minute
	// DefaultMaxRecords is the maximum number of records requested per segment.
	DefaultMaxRecords = 90000
)

// Query describes one Horizons vector ephemeris request.
type Query struct {
	BodyID domain.BodyID
	Start  string
	Stop   string
	Step   string
}

// Values returns the exact URL parameters required by Horizons.
func (q Query) Values() url.Values {
	values := url.Values{}
	values.Set("format", "text")
	values.Set("COMMAND", quote(strconv.Itoa(int(q.BodyID))))
	values.Set("EPHEM_TYPE", "VECTORS")
	values.Set("CENTER", "'@sun'")
	values.Set("REF_PLANE", "ECLIPTIC")
	values.Set("START_TIME", quote(q.Start))
	values.Set("STOP_TIME", quote(q.Stop))
	values.Set("STEP_SIZE", quote(q.Step))
	values.Set("OUT_UNITS", "'KM-S'")
	values.Set("VEC_TABLE", "'2'")
	values.Set("CSV_FORMAT", "'YES'")
	return values
}

// ClientOptions configures a Client.
type ClientOptions struct {
	HTTPClient       *http.Client
	Endpoint         string
	MinInterval      time.Duration
	DisableRateLimit bool
	CacheDir         string
}

// Client is a context-aware Horizons API client safe for concurrent use.
type Client struct {
	httpClient  *http.Client
	endpoint    string
	minInterval time.Duration
	cacheDir    string

	requestMu   sync.Mutex
	lastRequest time.Time
}

// NewClient constructs a Horizons API client.
func NewClient(options ClientOptions) *Client {
	httpClient := options.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	endpoint := options.Endpoint
	if endpoint == "" {
		endpoint = Endpoint
	}
	minInterval := options.MinInterval
	if minInterval == 0 && !options.DisableRateLimit {
		minInterval = DefaultMinInterval
	}
	if options.DisableRateLimit {
		minInterval = 0
	}
	if minInterval < 0 {
		minInterval = 0
	}

	return &Client{
		httpClient:  httpClient,
		endpoint:    endpoint,
		minInterval: minInterval,
		cacheDir:    options.CacheDir,
	}
}

// Fetch retrieves and parses one Horizons response.
func (c *Client) Fetch(ctx context.Context, query Query) ([]domain.StateVector, error) {
	values := query.Values()
	if c.cacheDir != "" {
		cached, found, err := c.readCache(values)
		if err != nil {
			return nil, err
		}
		if found {
			return Parse(bytes.NewReader(cached))
		}
	}

	if err := c.wait(ctx); err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("create Horizons request: %w", err)
	}
	req.URL.RawQuery = values.Encode()

	response, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request Horizons: %w", err)
	}
	body, readErr := io.ReadAll(response.Body)
	closeErr := response.Body.Close()
	if readErr != nil {
		err := fmt.Errorf("read Horizons response: %w", readErr)
		if closeErr != nil {
			return nil, errors.Join(err, fmt.Errorf("close Horizons response: %w", closeErr))
		}
		return nil, err
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close Horizons response: %w", closeErr)
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("horizons HTTP status %s", response.Status)
	}
	if c.cacheDir != "" {
		if err := c.writeCache(values, body); err != nil {
			return nil, err
		}
	}
	return Parse(bytes.NewReader(body))
}

// FetchSegmented splits a long interval, fetches each segment, and removes
// duplicate boundary epochs.
func (c *Client) FetchSegmented(
	ctx context.Context,
	query Query,
	maxRecords int,
) ([]domain.StateVector, error) {
	segments, err := Split(query, maxRecords)
	if err != nil {
		return nil, err
	}

	vectors := make([]domain.StateVector, 0)
	seen := make(map[float64]bool)
	for _, segment := range segments {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		part, err := c.Fetch(ctx, segment)
		if err != nil {
			return nil, fmt.Errorf(
				"fetch body %d from %s to %s: %w",
				query.BodyID, segment.Start, segment.Stop, err,
			)
		}
		for _, vector := range part {
			if seen[vector.JDTDB] {
				continue
			}
			seen[vector.JDTDB] = true
			vectors = append(vectors, vector)
		}
	}
	return vectors, nil
}

// Split divides a query into overlapping segments with at most maxRecords
// expected records each.
func Split(query Query, maxRecords int) ([]Query, error) {
	if maxRecords < 2 {
		return nil, fmt.Errorf("maxRecords must be at least 2, got %d", maxRecords)
	}
	start, err := parseDate(query.Start)
	if err != nil {
		return nil, fmt.Errorf("parse start time %q: %w", query.Start, err)
	}
	stop, err := parseDate(query.Stop)
	if err != nil {
		return nil, fmt.Errorf("parse stop time %q: %w", query.Stop, err)
	}
	if stop.Before(start) {
		return nil, fmt.Errorf("stop time %q is before start time %q", query.Stop, query.Start)
	}
	step, err := parseStep(query.Step)
	if err != nil {
		return nil, err
	}

	recordSpan := int64(maxRecords - 1)
	if step > time.Duration((1<<63-1)/recordSpan) {
		return nil, fmt.Errorf("step size %q and maxRecords %d overflow a duration", query.Step, maxRecords)
	}
	span := time.Duration(recordSpan) * step
	segments := make([]Query, 0, int(stop.Sub(start)/span)+1)
	for segmentStart := start; ; {
		segmentStop := segmentStart.Add(span)
		if segmentStop.After(stop) {
			segmentStop = stop
		}
		segments = append(segments, Query{
			BodyID: query.BodyID,
			Start:  formatQueryTime(segmentStart),
			Stop:   formatQueryTime(segmentStop),
			Step:   query.Step,
		})
		if !segmentStop.Before(stop) {
			break
		}
		segmentStart = segmentStop
	}
	return segments, nil
}

func (c *Client) wait(ctx context.Context) error {
	c.requestMu.Lock()
	defer c.requestMu.Unlock()

	delay := time.Until(c.lastRequest.Add(c.minInterval))
	if delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
	c.lastRequest = time.Now()
	return nil
}

func (c *Client) readCache(values url.Values) ([]byte, bool, error) {
	path := c.cachePath(values)
	body, err := os.ReadFile(path)
	if err == nil {
		return body, true, nil
	}
	if os.IsNotExist(err) {
		return nil, false, nil
	}
	return nil, false, fmt.Errorf("read Horizons cache %q: %w", path, err)
}

func (c *Client) writeCache(values url.Values, body []byte) error {
	if err := os.MkdirAll(c.cacheDir, 0o755); err != nil {
		return fmt.Errorf("create Horizons cache directory %q: %w", c.cacheDir, err)
	}
	path := c.cachePath(values)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write Horizons cache %q: %w", path, err)
	}
	return nil
}

func (c *Client) cachePath(values url.Values) string {
	digest := sha256.Sum256([]byte(values.Encode()))
	return filepath.Join(c.cacheDir, fmt.Sprintf("%x.txt", digest))
}

func quote(value string) string {
	trimmed := strings.TrimSpace(value)
	if strings.HasPrefix(trimmed, "'") && strings.HasSuffix(trimmed, "'") {
		return trimmed
	}
	return "'" + trimmed + "'"
}

func parseDate(value string) (time.Time, error) {
	value = strings.Trim(strings.TrimSpace(value), "'")
	var parseErr error
	for _, layout := range []string{
		time.DateOnly,
		"2006-01-02 15:04",
		"2006-01-02 15:04:05",
		time.RFC3339,
	} {
		parsed, err := time.Parse(layout, value)
		if err == nil {
			return parsed, nil
		}
		parseErr = err
	}
	return time.Time{}, parseErr
}

func formatQueryTime(value time.Time) string {
	if value.Hour() == 0 && value.Minute() == 0 && value.Second() == 0 {
		return value.Format(time.DateOnly)
	}
	return value.Format("2006-01-02 15:04:05")
}

func parseStep(value string) (time.Duration, error) {
	fields := strings.Fields(strings.Trim(strings.TrimSpace(value), "'"))
	if len(fields) != 2 {
		return 0, fmt.Errorf("unsupported Horizons step size %q", value)
	}
	count, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil || count <= 0 {
		return 0, fmt.Errorf("unsupported Horizons step size %q", value)
	}

	var unit time.Duration
	switch strings.ToLower(fields[1]) {
	case "d", "day", "days":
		unit = 24 * time.Hour
	case "h", "hour", "hours":
		unit = time.Hour
	case "m", "min", "minute", "minutes":
		unit = time.Minute
	default:
		return 0, fmt.Errorf("unsupported Horizons step size %q", value)
	}
	if count > int64((1<<63-1)/unit) {
		return 0, fmt.Errorf("horizons step size %q overflows a duration", value)
	}
	return time.Duration(count) * unit, nil
}
