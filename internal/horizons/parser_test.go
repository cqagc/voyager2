package horizons

import (
	"errors"
	"math"
	"os"
	"strings"
	"testing"
)

func TestParseFixture(t *testing.T) {
	fixture, err := os.Open("testdata/voyager2_vectors_csv.txt")
	if err != nil {
		t.Fatalf("os.Open(fixture) error: %v", err)
	}
	t.Cleanup(func() {
		if err := fixture.Close(); err != nil {
			t.Errorf("fixture.Close() error: %v", err)
		}
	})

	vectors, err := Parse(fixture)
	if err != nil {
		t.Fatalf("Parse(fixture) error: %v", err)
	}
	if got, want := len(vectors), 6; got != want {
		t.Fatalf("len(Parse(fixture)) = %d, want %d", got, want)
	}
	if got, want := vectors[0].JDTDB, 2447762.5; got != want {
		t.Errorf("Parse(fixture)[0].JDTDB = %.15g, want %.15g", got, want)
	}
	if got, want := vectors[0].Pos.X, 8.963427376298125e+08; !nearlyEqual(got, want, 1e-14) {
		t.Errorf("Parse(fixture)[0].Pos.X = %.15g, want %.15g", got, want)
	}
}

func TestParseErrors(t *testing.T) {
	fixtureBytes, err := os.ReadFile("testdata/voyager2_vectors_csv.txt")
	if err != nil {
		t.Fatalf("os.ReadFile(fixture) error: %v", err)
	}
	fixture := string(fixtureBytes)
	sectionStart := strings.Index(fixture, "$$SOE\n") + len("$$SOE\n")
	sectionEnd := strings.Index(fixture, "$$EOE")
	if sectionStart < len("$$SOE\n") || sectionEnd < sectionStart {
		t.Fatal("fixture does not contain a valid $$SOE/$$EOE section")
	}
	lines := strings.Split(strings.TrimSpace(fixture[sectionStart:sectionEnd]), "\n")
	malformedLines := append([]string(nil), lines...)
	malformedFields := strings.Split(malformedLines[0], ",")
	malformedLines[0] = strings.Join(malformedFields[:7], ",")
	malformed := fixture[:sectionStart] + strings.Join(malformedLines, "\n") + "\n" + fixture[sectionEnd:]
	empty := fixture[:sectionStart] + fixture[sectionEnd:]

	tests := []struct {
		name  string
		input string
		want  error
	}{
		{
			name:  "Horizons_error",
			input: "No ephemeris for target -32 after A.D. 2100-Jan-01\n" + fixture,
			want:  ErrNoEphemeris,
		},
		{
			name:  "cannot_interpret",
			input: "Cannot interpret date. Check START_TIME.\n" + fixture,
			want:  ErrNoEphemeris,
		},
		{
			name:  "empty_section",
			input: empty,
			want:  ErrNoEphemeris,
		},
		{
			name:  "missing_EOE",
			input: strings.Replace(fixture, "$$EOE", "", 1),
			want:  ErrMalformedResponse,
		},
		{
			name:  "wrong_field_count",
			input: malformed,
			want:  ErrMalformedResponse,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Parse(strings.NewReader(test.input))
			if !errors.Is(err, test.want) {
				t.Errorf("Parse(%q) error = %v, want errors.Is(_, %v)", test.input, err, test.want)
			}
		})
	}
}

func nearlyEqual(got, want, relativeTolerance float64) bool {
	if got == want {
		return true
	}
	return math.Abs(got-want) <= relativeTolerance*math.Max(math.Abs(got), math.Abs(want))
}
