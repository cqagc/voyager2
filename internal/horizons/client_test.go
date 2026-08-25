package horizons

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/cqagc/voyager2/internal/domain"
)

func TestClientFetchUsesParametersAndCache(t *testing.T) {
	fixture, err := os.ReadFile("testdata/voyager2_vectors_csv.txt")
	if err != nil {
		t.Fatalf("os.ReadFile(fixture) error: %v", err)
	}

	var requestCount atomic.Int32
	httpClient := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		requestCount.Add(1)
		want := map[string]string{
			"format":     "text",
			"COMMAND":    "'-32'",
			"EPHEM_TYPE": "VECTORS",
			"CENTER":     "'@sun'",
			"REF_PLANE":  "ECLIPTIC",
			"START_TIME": "'1989-08-24'",
			"STOP_TIME":  "'1989-08-29'",
			"STEP_SIZE":  "'1 d'",
			"OUT_UNITS":  "'KM-S'",
			"VEC_TABLE":  "'2'",
			"CSV_FORMAT": "'YES'",
		}
		for key, value := range want {
			if got := r.URL.Query().Get(key); got != value {
				t.Errorf("request parameter %q = %q, want %q", key, got, value)
			}
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(bytes.NewReader(fixture)),
			Header:     make(http.Header),
			Request:    r,
		}, nil
	})}

	client := NewClient(ClientOptions{
		HTTPClient:       httpClient,
		Endpoint:         "https://example.test/horizons.api",
		DisableRateLimit: true,
		CacheDir:         t.TempDir(),
	})
	query := Query{
		BodyID: domain.BodyVoyager2,
		Start:  "1989-08-24",
		Stop:   "1989-08-29",
		Step:   "1 d",
	}
	for i := 0; i < 2; i++ {
		vectors, err := client.Fetch(context.Background(), query)
		if err != nil {
			t.Fatalf("Fetch(ctx, query) call %d error: %v", i+1, err)
		}
		if got, want := len(vectors), 6; got != want {
			t.Errorf("len(Fetch(ctx, query)) call %d = %d, want %d", i+1, got, want)
		}
	}
	if got, want := requestCount.Load(), int32(1); got != want {
		t.Errorf("HTTP request count = %d, want %d", got, want)
	}
}

func TestSplit(t *testing.T) {
	query := Query{
		BodyID: domain.BodyVoyager2,
		Start:  "2000-01-01",
		Stop:   "2000-01-05",
		Step:   "1 d",
	}
	segments, err := Split(query, 3)
	if err != nil {
		t.Fatalf("Split(%+v, 3) error: %v", query, err)
	}
	if got, want := len(segments), 2; got != want {
		t.Fatalf("len(Split(%+v, 3)) = %d, want %d", query, got, want)
	}
	wantRanges := []string{"2000-01-01/2000-01-03", "2000-01-03/2000-01-05"}
	for i, segment := range segments {
		if got := fmt.Sprintf("%s/%s", segment.Start, segment.Stop); got != wantRanges[i] {
			t.Errorf("Split(%+v, 3)[%d] range = %q, want %q", query, i, got, wantRanges[i])
		}
	}
}

func TestFetchSegmentedDeduplicatesBoundaries(t *testing.T) {
	fixture, err := os.ReadFile("testdata/voyager2_vectors_csv.txt")
	if err != nil {
		t.Fatalf("os.ReadFile(fixture) error: %v", err)
	}
	responses := map[string]string{
		"'1989-08-24'": fixtureRecords(t, string(fixture), 0, 3),
		"'1989-08-26'": fixtureRecords(t, string(fixture), 2, 5),
	}
	var requestCount atomic.Int32
	httpClient := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		requestCount.Add(1)
		body, found := responses[r.URL.Query().Get("START_TIME")]
		if !found {
			return nil, fmt.Errorf("unexpected segment start %q", r.URL.Query().Get("START_TIME"))
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     make(http.Header),
			Request:    r,
		}, nil
	})}
	client := NewClient(ClientOptions{
		HTTPClient:       httpClient,
		Endpoint:         "https://example.test/horizons.api",
		DisableRateLimit: true,
	})
	vectors, err := client.FetchSegmented(context.Background(), Query{
		BodyID: domain.BodyVoyager2,
		Start:  "1989-08-24",
		Stop:   "1989-08-28",
		Step:   "1 d",
	}, 3)
	if err != nil {
		t.Fatalf("FetchSegmented(ctx, query, 3) error: %v", err)
	}
	if got, want := len(vectors), 5; got != want {
		t.Fatalf("len(FetchSegmented(ctx, query, 3)) = %d, want %d", got, want)
	}
	for i, vector := range vectors {
		if got, want := vector.JDTDB, 2447762.5+float64(i); got != want {
			t.Errorf("FetchSegmented(ctx, query, 3)[%d].JDTDB = %.1f, want %.1f", i, got, want)
		}
	}
	if got, want := requestCount.Load(), int32(2); got != want {
		t.Errorf("HTTP request count = %d, want %d", got, want)
	}
}

func TestFetchRejectsHTTP200ErrorBody(t *testing.T) {
	httpClient := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader("Cannot interpret START_TIME")),
			Header:     make(http.Header),
			Request:    r,
		}, nil
	})}

	client := NewClient(ClientOptions{
		HTTPClient:       httpClient,
		Endpoint:         "https://example.test/horizons.api",
		DisableRateLimit: true,
	})
	_, err := client.Fetch(context.Background(), Query{
		BodyID: domain.BodyVoyager2,
		Start:  "bad",
		Stop:   "bad",
		Step:   "1 d",
	})
	if err == nil || !strings.Contains(err.Error(), "Cannot interpret") {
		t.Errorf("Fetch(ctx, error query) error = %v, want Cannot interpret error", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func fixtureRecords(t *testing.T, fixture string, first, last int) string {
	t.Helper()
	sectionStart := strings.Index(fixture, "$$SOE\n") + len("$$SOE\n")
	sectionEnd := strings.Index(fixture, "$$EOE")
	if sectionStart < len("$$SOE\n") || sectionEnd < sectionStart {
		t.Fatal("fixture does not contain a valid $$SOE/$$EOE section")
	}
	lines := strings.Split(strings.TrimSpace(fixture[sectionStart:sectionEnd]), "\n")
	if first < 0 || last > len(lines) || first >= last {
		t.Fatalf("fixture record range [%d:%d] is invalid for %d records", first, last, len(lines))
	}
	return fixture[:sectionStart] + strings.Join(lines[first:last], "\n") + "\n" + fixture[sectionEnd:]
}
