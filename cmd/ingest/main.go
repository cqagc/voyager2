// The ingest command downloads Horizons vectors into the local SQLite store.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/horizons"
	"github.com/cqagc/voyager2/internal/store"
)

const voyager2LaunchDate = "1977-08-20"

var errPartialFailure = errors.New("one or more bodies failed")

type config struct {
	dbPath   string
	start    string
	stop     string
	step     string
	bodies   string
	cacheDir string
	dryRun   bool
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Args[1:]); err != nil {
		if !errors.Is(err, errPartialFailure) {
			slog.Error("ingest failed", "err", err)
		}
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) (resultErr error) {
	cfg, err := parseFlags(args)
	if err != nil {
		return err
	}
	bodies, err := selectBodies(cfg.bodies)
	if err != nil {
		return err
	}
	if err := validateDates(cfg.start, cfg.stop); err != nil {
		return err
	}

	if cfg.dryRun {
		return printDryRun(bodies, cfg)
	}

	database, err := store.Open(cfg.dbPath)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := database.Close(); closeErr != nil {
			resultErr = errors.Join(resultErr, closeErr)
		}
	}()
	if err := database.UpsertBodies(bodies); err != nil {
		return err
	}

	client := horizons.NewClient(horizons.ClientOptions{
		HTTPClient:  &http.Client{Timeout: 2 * time.Minute},
		MinInterval: horizons.DefaultMinInterval,
		CacheDir:    cfg.cacheDir,
	})
	failures := 0
	for _, body := range bodies {
		if err := ctx.Err(); err != nil {
			return err
		}
		query, err := queryForBody(body, cfg)
		if err != nil {
			failures++
			slog.Error("body skipped", "body", body.Name, "err", err)
			continue
		}

		slog.Info(
			"fetching body",
			"body", body.Name,
			"body_id", body.ID,
			"start", query.Start,
			"stop", query.Stop,
			"step", query.Step,
		)
		vectors, err := client.FetchSegmented(ctx, query, horizons.DefaultMaxRecords)
		if err != nil {
			failures++
			slog.Error("body fetch failed", "body", body.Name, "body_id", body.ID, "err", err)
			continue
		}
		if err := database.UpsertStateVectorsContext(ctx, body.ID, vectors); err != nil {
			failures++
			slog.Error("body persistence failed", "body", body.Name, "body_id", body.ID, "err", err)
			continue
		}
		minimum, maximum, count, err := database.CoverageContext(ctx, body.ID)
		if err != nil {
			failures++
			slog.Error("body coverage failed", "body", body.Name, "body_id", body.ID, "err", err)
			continue
		}
		slog.Info(
			"body complete",
			"body", body.Name,
			"body_id", body.ID,
			"records", len(vectors),
			"coverage_min_jdtdb", minimum,
			"coverage_max_jdtdb", maximum,
			"coverage_count", count,
		)
	}

	slog.Info("ingest complete", "bodies", len(bodies), "failures", failures)
	if failures > 0 {
		return errPartialFailure
	}
	return nil
}

func parseFlags(args []string) (config, error) {
	var cfg config
	flags := flag.NewFlagSet("ingest", flag.ContinueOnError)
	flags.StringVar(&cfg.dbPath, "db", "data/voyager2.db", "SQLite 数据库路径")
	flags.StringVar(&cfg.start, "start", voyager2LaunchDate, "开始日期 YYYY-MM-DD")
	flags.StringVar(&cfg.stop, "stop", time.Now().Format(time.DateOnly), "结束日期 YYYY-MM-DD")
	flags.StringVar(&cfg.step, "step", "1 d", "Horizons 采样步长")
	flags.StringVar(&cfg.bodies, "bodies", "all", "逗号分隔的天体 name，all 表示全部")
	flags.StringVar(&cfg.cacheDir, "cache-dir", "data/raw", "Horizons 原始响应缓存目录")
	flags.BoolVar(&cfg.dryRun, "dry-run", false, "只打印抓取计划")
	if err := flags.Parse(args); err != nil {
		return config{}, fmt.Errorf("parse flags: %w", err)
	}
	return cfg, nil
}

func selectBodies(value string) ([]domain.Body, error) {
	if strings.EqualFold(strings.TrimSpace(value), "all") || strings.TrimSpace(value) == "" {
		return append([]domain.Body(nil), horizons.Bodies...), nil
	}

	byName := make(map[string]domain.Body, len(horizons.Bodies))
	for _, body := range horizons.Bodies {
		byName[strings.ToLower(body.Name)] = body
	}
	seen := make(map[domain.BodyID]bool)
	selected := make([]domain.Body, 0)
	for _, name := range strings.Split(value, ",") {
		key := strings.ToLower(strings.TrimSpace(name))
		body, found := byName[key]
		if !found {
			return nil, fmt.Errorf("unknown body name %q", name)
		}
		if seen[body.ID] {
			continue
		}
		seen[body.ID] = true
		selected = append(selected, body)
	}
	return selected, nil
}

func validateDates(startValue, stopValue string) error {
	start, err := time.Parse(time.DateOnly, startValue)
	if err != nil {
		return fmt.Errorf("parse start date %q: %w", startValue, err)
	}
	stop, err := time.Parse(time.DateOnly, stopValue)
	if err != nil {
		return fmt.Errorf("parse stop date %q: %w", stopValue, err)
	}
	if stop.Before(start) {
		return fmt.Errorf("stop date %q is before start date %q", stopValue, startValue)
	}
	return nil
}

func queryForBody(body domain.Body, cfg config) (horizons.Query, error) {
	start := cfg.start
	if body.ID == domain.BodyVoyager2 && start < voyager2LaunchDate {
		start = voyager2LaunchDate
		slog.Warn(
			"adjusted Voyager 2 start to launch date",
			"requested_start", cfg.start,
			"effective_start", start,
		)
	}
	if body.ID == domain.BodyVoyager2 && cfg.stop < voyager2LaunchDate {
		return horizons.Query{}, fmt.Errorf(
			"requested stop %s precedes Voyager 2 launch %s",
			cfg.stop, voyager2LaunchDate,
		)
	}
	return horizons.Query{
		BodyID: body.ID,
		Start:  start,
		Stop:   cfg.stop,
		Step:   cfg.step,
	}, nil
}

func printDryRun(bodies []domain.Body, cfg config) error {
	failures := 0
	for _, body := range bodies {
		query, err := queryForBody(body, cfg)
		if err != nil {
			failures++
			slog.Error("body skipped", "body", body.Name, "err", err)
			continue
		}
		segments, err := horizons.Split(query, horizons.DefaultMaxRecords)
		if err != nil {
			return fmt.Errorf("plan body %s: %w", body.Name, err)
		}
		slog.Info(
			"dry-run body",
			"body", body.Name,
			"body_id", body.ID,
			"start", query.Start,
			"stop", query.Stop,
			"step", query.Step,
			"segments", len(segments),
		)
	}
	if failures > 0 {
		return errPartialFailure
	}
	return nil
}
