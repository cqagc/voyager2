package store

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/horizons"
)

func TestStoreFixtureRoundTripAndInterpolation(t *testing.T) {
	store := openTestStore(t)
	vectors := loadFixtureVectors(t)
	body := domain.Body{
		ID:           domain.BodyVoyager2,
		Name:         "voyager2",
		Label:        "旅行者2号",
		IsSpacecraft: true,
	}
	if err := store.Init(); err != nil {
		t.Fatalf("Init() second call error: %v", err)
	}
	if err := store.UpsertBodies([]domain.Body{body}); err != nil {
		t.Fatalf("UpsertBodies(voyager2) error: %v", err)
	}
	if err := store.UpsertStateVectors(body.ID, vectors); err != nil {
		t.Fatalf("UpsertStateVectors(voyager2, fixture) error: %v", err)
	}

	got, err := store.GetRange(body.ID, vectors[0].JDTDB, vectors[len(vectors)-1].JDTDB)
	if err != nil {
		t.Fatalf("GetRange(voyager2, fixture range) error: %v", err)
	}
	if len(got) != len(vectors) {
		t.Fatalf("len(GetRange(voyager2, fixture range)) = %d, want %d", len(got), len(vectors))
	}
	for i := range vectors {
		if got[i] != vectors[i] {
			t.Errorf("GetRange(voyager2, fixture range)[%d] = %+v, want %+v", i, got[i], vectors[i])
		}
	}

	exact, err := store.StateAt(body.ID, vectors[2].JDTDB)
	if err != nil {
		t.Fatalf("StateAt(voyager2, sample epoch) error: %v", err)
	}
	assertVectorNear(t, "StateAt(voyager2, sample epoch)", exact, vectors[2], 1e-6)

	lower := vectors[3]
	upper := vectors[4]
	midpointJD := (lower.JDTDB + upper.JDTDB) / 2
	midpoint, err := store.StateAt(body.ID, midpointJD)
	if err != nil {
		t.Fatalf("StateAt(voyager2, midpoint) error: %v", err)
	}
	assertBetween(t, "midpoint.Pos.X", midpoint.Pos.X, lower.Pos.X, upper.Pos.X)
	assertBetween(t, "midpoint.Pos.Y", midpoint.Pos.Y, lower.Pos.Y, upper.Pos.Y)
	assertBetween(t, "midpoint.Pos.Z", midpoint.Pos.Z, lower.Pos.Z, upper.Pos.Z)
	assertBetween(t, "midpoint.Vel.X", midpoint.Vel.X, lower.Vel.X, upper.Vel.X)
	assertBetween(t, "midpoint.Vel.Y", midpoint.Vel.Y, lower.Vel.Y, upper.Vel.Y)
	assertBetween(t, "midpoint.Vel.Z", midpoint.Vel.Z, lower.Vel.Z, upper.Vel.Z)

	for _, jd := range []float64{vectors[0].JDTDB - 1, vectors[len(vectors)-1].JDTDB + 1} {
		if _, err := store.StateAt(body.ID, jd); !errors.Is(err, ErrOutsideCoverage) {
			t.Errorf("StateAt(voyager2, %.9f) error = %v, want ErrOutsideCoverage", jd, err)
		}
	}

	if err := store.UpsertStateVectors(body.ID, vectors); err != nil {
		t.Fatalf("UpsertStateVectors(voyager2, duplicate fixture) error: %v", err)
	}
	minimum, maximum, count, err := store.Coverage(body.ID)
	if err != nil {
		t.Fatalf("Coverage(voyager2) error: %v", err)
	}
	if minimum != vectors[0].JDTDB || maximum != vectors[len(vectors)-1].JDTDB {
		t.Errorf(
			"Coverage(voyager2) range = [%.9f, %.9f], want [%.9f, %.9f]",
			minimum, maximum, vectors[0].JDTDB, vectors[len(vectors)-1].JDTDB,
		)
	}
	if got, want := count, int64(6); got != want {
		t.Errorf("Coverage(voyager2) count = %d, want %d", got, want)
	}
}

func openTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "ephemeris.db"))
	if err != nil {
		t.Fatalf("Open(test database) error: %v", err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("Store.Close() error: %v", err)
		}
	})
	return store
}

func loadFixtureVectors(t *testing.T) []domain.StateVector {
	t.Helper()
	fixture, err := os.Open("../horizons/testdata/voyager2_vectors_csv.txt")
	if err != nil {
		t.Fatalf("os.Open(fixture) error: %v", err)
	}
	t.Cleanup(func() {
		if err := fixture.Close(); err != nil {
			t.Errorf("fixture.Close() error: %v", err)
		}
	})
	vectors, err := horizons.Parse(fixture)
	if err != nil {
		t.Fatalf("horizons.Parse(fixture) error: %v", err)
	}
	return vectors
}

func assertVectorNear(
	t *testing.T,
	name string,
	got, want domain.StateVector,
	relativeTolerance float64,
) {
	t.Helper()
	gotValues := [...]float64{
		got.JDTDB,
		got.Pos.X, got.Pos.Y, got.Pos.Z,
		got.Vel.X, got.Vel.Y, got.Vel.Z,
	}
	wantValues := [...]float64{
		want.JDTDB,
		want.Pos.X, want.Pos.Y, want.Pos.Z,
		want.Vel.X, want.Vel.Y, want.Vel.Z,
	}
	for i := range gotValues {
		scale := math.Max(math.Abs(gotValues[i]), math.Abs(wantValues[i]))
		if gotValues[i] != wantValues[i] && math.Abs(gotValues[i]-wantValues[i]) > relativeTolerance*scale {
			t.Errorf("%s component %d = %.15g, want %.15g", name, i, gotValues[i], wantValues[i])
		}
	}
}

func assertBetween(t *testing.T, name string, got, endpoint0, endpoint1 float64) {
	t.Helper()
	minimum := math.Min(endpoint0, endpoint1)
	maximum := math.Max(endpoint0, endpoint1)
	if got < minimum || got > maximum {
		t.Errorf("%s = %.15g, want between %.15g and %.15g", name, got, minimum, maximum)
	}
}
