// Package store persists ephemeris bodies and state vectors in SQLite.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cqagc/voyager2/internal/domain"
	_ "modernc.org/sqlite"
)

var (
	// ErrNoCoverage indicates that a body has no stored state vectors.
	ErrNoCoverage = errors.New("body has no state-vector coverage")
	// ErrOutsideCoverage indicates that interpolation would require extrapolation.
	ErrOutsideCoverage = errors.New("epoch is outside stored state-vector coverage")
)

// Store is a SQLite-backed ephemeris store.
type Store struct {
	db *sql.DB
}

// Open opens a SQLite database and initializes its schema.
func Open(path string) (*Store, error) {
	if path == "" {
		return nil, errors.New("database path is empty")
	}
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("create database directory for %q: %w", path, err)
		}
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open SQLite database %q: %w", path, err)
	}
	// 单连接可确保连接级 PRAGMA 始终生效，并避免内存库连接彼此隔离。
	db.SetMaxOpenConns(1)

	store := &Store{db: db}
	if err := store.Init(); err != nil {
		if closeErr := db.Close(); closeErr != nil {
			return nil, errors.Join(err, fmt.Errorf("close SQLite database: %w", closeErr))
		}
		return nil, err
	}
	return store, nil
}

// Close closes the underlying SQLite database.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("close SQLite database: %w", err)
	}
	return nil
}

// Init creates the schema if it does not already exist.
func (s *Store) Init() error {
	return s.InitContext(context.Background())
}

// InitContext creates the schema if it does not already exist.
func (s *Store) InitContext(ctx context.Context) error {
	statements := [...]string{
		`PRAGMA journal_mode = WAL`,
		`CREATE TABLE IF NOT EXISTS bodies (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL UNIQUE,
			label TEXT NOT NULL,
			mean_radius_km REAL NOT NULL,
			is_spacecraft INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS state_vectors (
			body_id INTEGER NOT NULL,
			jdtdb REAL NOT NULL,
			x REAL NOT NULL,
			y REAL NOT NULL,
			z REAL NOT NULL,
			vx REAL NOT NULL,
			vy REAL NOT NULL,
			vz REAL NOT NULL,
			PRIMARY KEY (body_id, jdtdb)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_state_vectors_jdtdb
			ON state_vectors (jdtdb)`,
	}
	for _, statement := range statements {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("initialize SQLite schema: %w", err)
		}
	}
	return nil
}

// UpsertBodies inserts or updates body metadata in one transaction.
func (s *Store) UpsertBodies(bodies []domain.Body) error {
	return s.UpsertBodiesContext(context.Background(), bodies)
}

// UpsertBodiesContext inserts or updates body metadata in one transaction.
func (s *Store) UpsertBodiesContext(ctx context.Context, bodies []domain.Body) error {
	return s.withTransaction(ctx, func(tx *sql.Tx) error {
		statement, err := tx.PrepareContext(ctx, `
			INSERT INTO bodies (id, name, label, mean_radius_km, is_spacecraft)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(id) DO UPDATE SET
				name = excluded.name,
				label = excluded.label,
				mean_radius_km = excluded.mean_radius_km,
				is_spacecraft = excluded.is_spacecraft`)
		if err != nil {
			return fmt.Errorf("prepare body upsert: %w", err)
		}
		for _, body := range bodies {
			if err := ctx.Err(); err != nil {
				if closeErr := statement.Close(); closeErr != nil {
					return errors.Join(err, fmt.Errorf("close body upsert statement: %w", closeErr))
				}
				return err
			}
			if _, err := statement.ExecContext(
				ctx,
				body.ID,
				body.Name,
				body.Label,
				body.MeanRadiusKm,
				body.IsSpacecraft,
			); err != nil {
				if closeErr := statement.Close(); closeErr != nil {
					return errors.Join(
						fmt.Errorf("upsert body %d: %w", body.ID, err),
						fmt.Errorf("close body upsert statement: %w", closeErr),
					)
				}
				return fmt.Errorf("upsert body %d: %w", body.ID, err)
			}
		}
		if err := statement.Close(); err != nil {
			return fmt.Errorf("close body upsert statement: %w", err)
		}
		return nil
	})
}

// UpsertStateVectors inserts or updates vectors in one streaming transaction.
func (s *Store) UpsertStateVectors(bodyID domain.BodyID, vectors []domain.StateVector) error {
	return s.UpsertStateVectorsContext(context.Background(), bodyID, vectors)
}

// UpsertStateVectorsContext inserts or updates vectors in one streaming
// transaction.
func (s *Store) UpsertStateVectorsContext(
	ctx context.Context,
	bodyID domain.BodyID,
	vectors []domain.StateVector,
) error {
	return s.withTransaction(ctx, func(tx *sql.Tx) error {
		statement, err := tx.PrepareContext(ctx, `
			INSERT INTO state_vectors (body_id, jdtdb, x, y, z, vx, vy, vz)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(body_id, jdtdb) DO UPDATE SET
				x = excluded.x,
				y = excluded.y,
				z = excluded.z,
				vx = excluded.vx,
				vy = excluded.vy,
				vz = excluded.vz`)
		if err != nil {
			return fmt.Errorf("prepare state-vector upsert: %w", err)
		}
		for _, vector := range vectors {
			if err := ctx.Err(); err != nil {
				if closeErr := statement.Close(); closeErr != nil {
					return errors.Join(err, fmt.Errorf("close state-vector upsert statement: %w", closeErr))
				}
				return err
			}
			if _, err := statement.ExecContext(
				ctx,
				bodyID,
				vector.JDTDB,
				vector.Pos.X,
				vector.Pos.Y,
				vector.Pos.Z,
				vector.Vel.X,
				vector.Vel.Y,
				vector.Vel.Z,
			); err != nil {
				if closeErr := statement.Close(); closeErr != nil {
					return errors.Join(
						fmt.Errorf("upsert state vector at %.9f: %w", vector.JDTDB, err),
						fmt.Errorf("close state-vector upsert statement: %w", closeErr),
					)
				}
				return fmt.Errorf("upsert state vector at %.9f: %w", vector.JDTDB, err)
			}
		}
		if err := statement.Close(); err != nil {
			return fmt.Errorf("close state-vector upsert statement: %w", err)
		}
		return nil
	})
}

// GetRange returns every sample in the inclusive JDTDB range.
func (s *Store) GetRange(
	bodyID domain.BodyID,
	jd0, jd1 float64,
) ([]domain.StateVector, error) {
	return s.GetRangeContext(context.Background(), bodyID, jd0, jd1)
}

// GetRangeContext returns every sample in the inclusive JDTDB range.
func (s *Store) GetRangeContext(
	ctx context.Context,
	bodyID domain.BodyID,
	jd0, jd1 float64,
) ([]domain.StateVector, error) {
	if jd1 < jd0 {
		return nil, fmt.Errorf("range end %.9f is before start %.9f", jd1, jd0)
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT jdtdb, x, y, z, vx, vy, vz
		FROM state_vectors
		WHERE body_id = ? AND jdtdb BETWEEN ? AND ?
		ORDER BY jdtdb`, bodyID, jd0, jd1)
	if err != nil {
		return nil, fmt.Errorf("query state-vector range for body %d: %w", bodyID, err)
	}

	var vectors []domain.StateVector
	for rows.Next() {
		vector, err := scanVector(rows)
		if err != nil {
			if closeErr := rows.Close(); closeErr != nil {
				return nil, errors.Join(err, fmt.Errorf("close state-vector rows: %w", closeErr))
			}
			return nil, err
		}
		vectors = append(vectors, vector)
	}
	iterationErr := rows.Err()
	closeErr := rows.Close()
	if iterationErr != nil {
		err := fmt.Errorf("iterate state-vector range for body %d: %w", bodyID, iterationErr)
		if closeErr != nil {
			return nil, errors.Join(err, fmt.Errorf("close state-vector rows: %w", closeErr))
		}
		return nil, err
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close state-vector rows: %w", closeErr)
	}
	return vectors, nil
}

// Coverage returns the minimum and maximum JDTDB plus stored row count.
func (s *Store) Coverage(bodyID domain.BodyID) (float64, float64, int64, error) {
	return s.CoverageContext(context.Background(), bodyID)
}

// CoverageContext returns the minimum and maximum JDTDB plus stored row count.
func (s *Store) CoverageContext(
	ctx context.Context,
	bodyID domain.BodyID,
) (float64, float64, int64, error) {
	var (
		minimum sql.NullFloat64
		maximum sql.NullFloat64
		count   int64
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT MIN(jdtdb), MAX(jdtdb), COUNT(*)
		FROM state_vectors
		WHERE body_id = ?`, bodyID).Scan(&minimum, &maximum, &count)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("query coverage for body %d: %w", bodyID, err)
	}
	if count == 0 || !minimum.Valid || !maximum.Valid {
		return 0, 0, 0, fmt.Errorf("body %d: %w", bodyID, ErrNoCoverage)
	}
	return minimum.Float64, maximum.Float64, count, nil
}

// StateAt interpolates the state at jd with cubic Hermite interpolation.
func (s *Store) StateAt(bodyID domain.BodyID, jd float64) (domain.StateVector, error) {
	return s.StateAtContext(context.Background(), bodyID, jd)
}

// StateAtContext interpolates the state at jd with cubic Hermite
// interpolation.
func (s *Store) StateAtContext(
	ctx context.Context,
	bodyID domain.BodyID,
	jd float64,
) (domain.StateVector, error) {
	lower, err := s.vectorAtOrBefore(ctx, bodyID, jd)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.StateVector{}, fmt.Errorf("body %d at %.9f: %w", bodyID, jd, ErrOutsideCoverage)
	}
	if err != nil {
		return domain.StateVector{}, err
	}
	upper, err := s.vectorAtOrAfter(ctx, bodyID, jd)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.StateVector{}, fmt.Errorf("body %d at %.9f: %w", bodyID, jd, ErrOutsideCoverage)
	}
	if err != nil {
		return domain.StateVector{}, err
	}
	if lower.JDTDB == upper.JDTDB {
		return lower, nil
	}
	return interpolateHermite(lower, upper, jd), nil
}

func (s *Store) vectorAtOrBefore(
	ctx context.Context,
	bodyID domain.BodyID,
	jd float64,
) (domain.StateVector, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT jdtdb, x, y, z, vx, vy, vz
		FROM state_vectors
		WHERE body_id = ? AND jdtdb <= ?
		ORDER BY jdtdb DESC
		LIMIT 1`, bodyID, jd)
	vector, err := scanVector(row)
	if err != nil {
		return domain.StateVector{}, fmt.Errorf("query lower state vector for body %d: %w", bodyID, err)
	}
	return vector, nil
}

func (s *Store) vectorAtOrAfter(
	ctx context.Context,
	bodyID domain.BodyID,
	jd float64,
) (domain.StateVector, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT jdtdb, x, y, z, vx, vy, vz
		FROM state_vectors
		WHERE body_id = ? AND jdtdb >= ?
		ORDER BY jdtdb
		LIMIT 1`, bodyID, jd)
	vector, err := scanVector(row)
	if err != nil {
		return domain.StateVector{}, fmt.Errorf("query upper state vector for body %d: %w", bodyID, err)
	}
	return vector, nil
}

func (s *Store) withTransaction(ctx context.Context, work func(*sql.Tx) error) (err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin SQLite transaction: %w", err)
	}
	defer func() {
		if err == nil {
			return
		}
		if rollbackErr := tx.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
			err = errors.Join(err, fmt.Errorf("rollback SQLite transaction: %w", rollbackErr))
		}
	}()

	if err = work(tx); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return fmt.Errorf("commit SQLite transaction: %w", err)
	}
	return nil
}

type vectorScanner interface {
	Scan(dest ...any) error
}

func scanVector(scanner vectorScanner) (domain.StateVector, error) {
	var vector domain.StateVector
	if err := scanner.Scan(
		&vector.JDTDB,
		&vector.Pos.X,
		&vector.Pos.Y,
		&vector.Pos.Z,
		&vector.Vel.X,
		&vector.Vel.Y,
		&vector.Vel.Z,
	); err != nil {
		return domain.StateVector{}, fmt.Errorf("scan state vector: %w", err)
	}
	return vector, nil
}
