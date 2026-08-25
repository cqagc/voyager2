package dsn

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func TestPollerPollOnceUsesCacheBusterAndStoresSnapshot(t *testing.T) {
	fixture, err := os.ReadFile("testdata/dsn_synthetic_vgr2.xml")
	if err != nil {
		t.Fatalf("os.ReadFile(synthetic fixture) returned error: %v", err)
	}
	fixedTime := time.Date(2026, time.August, 26, 12, 0, 0, 123000000, time.UTC)
	var requestedURL string
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		requestedURL = req.URL.String()
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader(string(fixture))),
			Header:     make(http.Header),
		}, nil
	})}
	poller := NewPoller(-32, Options{
		Client:      client,
		HistorySize: 2,
		Clock:       func() time.Time { return fixedTime },
	})

	var callbackCount int
	unsubscribe := poller.Subscribe(func(state domain.LinkState) {
		callbackCount++
	})
	defer unsubscribe()
	got, err := poller.PollOnce(context.Background())
	if err != nil {
		t.Fatalf("Poller.PollOnce() returned error: %v", err)
	}
	if !strings.Contains(requestedURL, "r=1787745600123") {
		t.Errorf("Poller.PollOnce() URL = %q, want cache-buster r=1787745600123", requestedURL)
	}
	if !got.Connected {
		t.Errorf("Poller.PollOnce() connected = false, want true")
	}
	latest, ok := poller.Latest()
	if !ok || latest != got {
		t.Errorf("Poller.Latest() = (%+v, %t), want (%+v, true)", latest, ok, got)
	}
	if callbackCount != 1 {
		t.Errorf("Poller callback count = %d, want 1", callbackCount)
	}

	if _, err := poller.PollOnce(context.Background()); err != nil {
		t.Fatalf("second Poller.PollOnce() returned error: %v", err)
	}
	if callbackCount != 1 {
		t.Errorf("Poller callback count after unchanged state = %d, want 1", callbackCount)
	}
	if got, want := len(poller.History()), 2; got != want {
		t.Errorf("len(Poller.History()) = %d, want %d", got, want)
	}
}

func TestPollerHistoryRing(t *testing.T) {
	poller := NewPoller(-32, Options{HistorySize: 2})
	for i := 1; i <= 3; i++ {
		poller.store(domain.LinkState{ObservedAt: time.Unix(int64(i), 0)})
	}
	history := poller.History()
	if got, want := len(history), 2; got != want {
		t.Fatalf("len(Poller.History()) = %d, want %d", got, want)
	}
	if got, want := history[0].ObservedAt.Unix(), int64(2); got != want {
		t.Errorf("Poller.History()[0].ObservedAt = %d, want %d", got, want)
	}
	if got, want := history[1].ObservedAt.Unix(), int64(3); got != want {
		t.Errorf("Poller.History()[1].ObservedAt = %d, want %d", got, want)
	}
}

func TestPollerSubscribeStateChanges(t *testing.T) {
	poller := NewPoller(-32, Options{})
	var states []domain.LinkState
	unsubscribe := poller.Subscribe(func(state domain.LinkState) {
		states = append(states, state)
	})

	disconnected := domain.LinkState{Spacecraft: "VGR2"}
	connected := domain.LinkState{Spacecraft: "VGR2", Connected: true, Antenna: "DSS43"}
	poller.store(disconnected)
	poller.store(disconnected)
	poller.store(connected)
	unsubscribe()
	poller.store(disconnected)

	if got, want := len(states), 2; got != want {
		t.Fatalf("Poller.Subscribe() callback count = %d, want %d", got, want)
	}
	if states[0].Connected {
		t.Errorf("Poller.Subscribe() first state connected = true, want false")
	}
	if !states[1].Connected {
		t.Errorf("Poller.Subscribe() second state connected = false, want true")
	}
}

func TestPollerRunRetriesAndNotifiesConnection(t *testing.T) {
	disconnectedXML, err := os.ReadFile("testdata/dsn_sample.xml")
	if err != nil {
		t.Fatalf("os.ReadFile(dsn_sample.xml) returned error: %v", err)
	}
	connectedXML, err := os.ReadFile("testdata/dsn_synthetic_vgr2.xml")
	if err != nil {
		t.Fatalf("os.ReadFile(dsn_synthetic_vgr2.xml) returned error: %v", err)
	}

	attempts := 0
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			return nil, errors.New("temporary network failure")
		}
		body := disconnectedXML
		if attempts >= 3 {
			body = connectedXML
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Body:       io.NopCloser(strings.NewReader(string(body))),
			Header:     make(http.Header),
		}, nil
	})}
	poller := NewPoller(-32, Options{Client: client, Interval: 2 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var states []domain.LinkState
	unsubscribe := poller.Subscribe(func(state domain.LinkState) {
		states = append(states, state)
		if state.Connected {
			cancel()
		}
	})
	defer unsubscribe()

	err = poller.Run(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("Poller.Run() error = %v, want context.Canceled", err)
	}
	if got, want := attempts, 3; got != want {
		t.Errorf("Poller.Run() attempts = %d, want %d", got, want)
	}
	if got, want := len(states), 2; got != want {
		t.Fatalf("Poller.Run() notification count = %d, want %d", got, want)
	}
	if states[0].Connected || !states[1].Connected {
		t.Errorf("Poller.Run() connected sequence = [%t %t], want [false true]", states[0].Connected, states[1].Connected)
	}
}

func TestPollerConcurrentRead(t *testing.T) {
	poller := NewPoller(-32, Options{HistorySize: 4})
	var wait sync.WaitGroup
	for i := 0; i < 20; i++ {
		wait.Add(2)
		go func(n int) {
			defer wait.Done()
			poller.store(domain.LinkState{DownlinkBitrate: float64(n)})
		}(i)
		go func() {
			defer wait.Done()
			poller.Latest()
			poller.History()
		}()
	}
	wait.Wait()
}
