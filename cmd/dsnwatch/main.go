// The dsnwatch command observes one spacecraft in the live DSN feed.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/cqagc/voyager2/internal/domain"
	"github.com/cqagc/voyager2/internal/dsn"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	interval := flag.Duration("interval", 60*time.Second, "DSN 轮询间隔")
	spacecraftID := flag.Int("spacecraft", -32, "DSN spacecraftID")
	once := flag.Bool("once", false, "只抓取一次后退出")
	jsonOutput := flag.Bool("json", false, "以 JSON 输出")
	flag.Parse()

	poller := dsn.NewPoller(*spacecraftID, dsn.Options{Interval: *interval})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *once {
		state, err := poller.PollOnce(ctx)
		if err != nil {
			return fmt.Errorf("poll DSN once: %w", err)
		}
		return printState(state, nil, *jsonOutput)
	}

	unsubscribe := poller.Subscribe(func(state domain.LinkState) {
		if err := printState(state, poller.History(), *jsonOutput); err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
	})
	defer unsubscribe()
	if err := poller.Run(ctx); err != nil && ctx.Err() == nil {
		return fmt.Errorf("run DSN poller: %w", err)
	}
	return nil
}

func printState(state domain.LinkState, history []domain.LinkState, jsonOutput bool) error {
	if jsonOutput {
		if err := json.NewEncoder(os.Stdout).Encode(state); err != nil {
			return fmt.Errorf("encode DSN state: %w", err)
		}
		return nil
	}

	if !state.Connected {
		lastConnected := lastConnectedAt(history)
		if lastConnected.IsZero() {
			fmt.Println("当前未跟踪｜上次连接：无记录")
		} else {
			fmt.Printf("当前未跟踪｜上次连接：%s\n", lastConnected.Local().Format(time.DateTime))
		}
		return nil
	}

	fmt.Printf("正在跟踪｜天线 %s｜站点 %s｜下行 %.0f bps｜信号 %.1f dBm｜%s\n",
		state.Antenna, state.Site, state.DownlinkBitrate, state.SignalPowerDBm,
		formatLightTime(state.RoundTripLightTimeSec))
	return nil
}

func lastConnectedAt(history []domain.LinkState) time.Time {
	for i := len(history) - 1; i >= 0; i-- {
		if history[i].Connected {
			return history[i].ObservedAt
		}
	}
	return time.Time{}
}

// formatLightTime renders round-trip light time at a scale a human can read,
// and says so when the feed has no value.
//
// The DSN feed uses rtlt="-1" for "no data", which the parser normalises to 0.
// Printing that as "0.00 小时" is a lie: it made JWST -- 1.5 million km away,
// about 10 s round trip -- report zero light time. Absent data must look absent.
func formatLightTime(sec float64) string {
	if sec <= 0 {
		return "往返光时：该馈送未提供"
	}
	if sec < 120 {
		return fmt.Sprintf("往返光时 %.1f 秒（单程 %.1f 秒）", sec, sec/2)
	}
	if sec < 7200 {
		return fmt.Sprintf("往返光时 %.1f 分钟（单程 %.1f 分钟）", sec/60, sec/120)
	}
	return fmt.Sprintf("往返光时 %.2f 小时（单程 %.2f 小时）", sec/3600, sec/7200)
}
