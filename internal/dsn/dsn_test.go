package dsn

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestParseFixture(t *testing.T) {
	feed := parseFixture(t, "testdata/dsn_sample.xml")

	if got, want := len(feed.Dishes), 15; got != want {
		t.Errorf("Parse(dsn_sample.xml) dish count = %d, want %d", got, want)
	}

	siteTests := []struct {
		name string
		want string
	}{
		{name: "DSS14", want: "Goldstone"},
		{name: "DSS53", want: "Madrid"},
		{name: "DSS43", want: "Canberra"},
	}
	for _, test := range siteTests {
		t.Run(test.name, func(t *testing.T) {
			dish := findDish(t, feed, test.name)
			if dish.Site != test.want {
				t.Errorf("Parse(dsn_sample.xml) site for %s = %q, want %q", test.name, dish.Site, test.want)
			}
		})
	}

	dss14 := findDish(t, feed, "DSS14")
	if dss14.WindSpeed != nil {
		t.Errorf("Parse(dsn_sample.xml) DSS14 wind speed = %v, want nil", *dss14.WindSpeed)
	}
	dss24 := findDish(t, feed, "DSS24")
	if got, want := valueOrZero(dss24.DownSignals[0].DataRate), 54610.0; got != want {
		t.Errorf("Parse(dsn_sample.xml) SOHO data rate = %v, want %v", got, want)
	}
	if got, want := valueOrZero(dss24.DownSignals[0].Power), -130.0; got != want {
		t.Errorf("Parse(dsn_sample.xml) SOHO power = %v, want %v", got, want)
	}
	if got, want := dss24.DownSignals[0].Band, "S"; got != want {
		t.Errorf("Parse(dsn_sample.xml) SOHO band = %q, want %q", got, want)
	}
	if dss24.Targets[0].RTLT != nil {
		t.Errorf("Parse(dsn_sample.xml) SOHO RTLT = %v, want nil", *dss24.Targets[0].RTLT)
	}
}

func TestFeedLinkState(t *testing.T) {
	fixedTime := time.Date(2026, time.August, 26, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name         string
		fixture      string
		spacecraftID int
		connected    bool
		antenna      string
		site         string
		bitrate      float64
		frequency    float64
		power        float64
		uplinkPower  float64
		rtlt         float64
	}{
		{
			name:         "SOHO",
			fixture:      "testdata/dsn_sample.xml",
			spacecraftID: -21,
			connected:    true,
			antenna:      "DSS24",
			site:         "Goldstone",
			bitrate:      54610,
			power:        -130,
			uplinkPower:  1.7,
		},
		{
			name:         "Voyager 2 not tracked",
			fixture:      "testdata/dsn_sample.xml",
			spacecraftID: -32,
			connected:    false,
		},
		{
			name:         "Voyager 2 synthetic downlink",
			fixture:      "testdata/dsn_synthetic_vgr2.xml",
			spacecraftID: -32,
			connected:    true,
			antenna:      "DSS43",
			site:         "Canberra",
			bitrate:      160,
			frequency:    8415000000,
			power:        -158.5,
			uplinkPower:  18,
			rtlt:         136800,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			feed := parseFixture(t, test.fixture)
			got, err := feed.LinkState(test.spacecraftID, fixedTime)
			if err != nil {
				t.Fatalf("Feed.LinkState(%d) returned error: %v", test.spacecraftID, err)
			}
			if got.Connected != test.connected || got.Antenna != test.antenna || got.Site != test.site ||
				got.DownlinkBitrate != test.bitrate || got.DownlinkFreqHz != test.frequency ||
				got.SignalPowerDBm != test.power || got.UplinkPowerKW != test.uplinkPower ||
				got.RoundTripLightTimeSec != test.rtlt || !got.ObservedAt.Equal(fixedTime) {
				t.Errorf("Feed.LinkState(%d) = %+v, want connected=%t antenna=%q site=%q bitrate=%v frequency=%v power=%v uplink=%v rtlt=%v observedAt=%v",
					test.spacecraftID, got, test.connected, test.antenna, test.site, test.bitrate, test.frequency,
					test.power, test.uplinkPower, test.rtlt, fixedTime)
			}
		})
	}
}

func TestParseMalformedXML(t *testing.T) {
	if _, err := Parse(strings.NewReader(`<dsn><dish name="DSS43"></dsn>`)); err == nil {
		t.Error("Parse(malformed XML) error = nil, want non-nil")
	}
}

func parseFixture(t *testing.T, path string) Feed {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("os.Open(%q) returned error: %v", path, err)
	}
	t.Cleanup(func() {
		if err := file.Close(); err != nil {
			t.Errorf("Close(%q) returned error: %v", path, err)
		}
	})
	feed, err := Parse(file)
	if err != nil {
		t.Fatalf("Parse(%q) returned error: %v", path, err)
	}
	return feed
}

func findDish(t *testing.T, feed Feed, name string) Dish {
	t.Helper()
	for _, dish := range feed.Dishes {
		if dish.Name == name {
			return dish
		}
	}
	t.Fatalf("findDish(%q) found no dish", name)
	return Dish{}
}
