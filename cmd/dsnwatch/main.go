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

	rtltHours := state.RoundTripLightTimeSec / 3600
	oneWayHours := rtltHours / 2
	fmt.Printf("正在跟踪｜天线 %s｜站点 %s｜下行 %.0f bps｜信号 %.1f dBm｜往返光时 %.2f 小时（单程 %.2f 小时）\n",
		state.Antenna, state.Site, state.DownlinkBitrate, state.SignalPowerDBm, rtltHours, oneWayHours)
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
