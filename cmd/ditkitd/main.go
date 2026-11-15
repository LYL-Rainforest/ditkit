// ditkitd 是 SMART 采集后端：调用 smartctl、输出简体中文报告，并提供本机 HTTP 接口给 SwiftUI。
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/LYL-Rainforest/ditkit/internal/api"
	"github.com/LYL-Rainforest/ditkit/internal/smart"
)

func main() {
	var (
		port        int
		dataDir     string
		noRuntime   bool
		showVersion bool
	)
	flag.IntVar(&port, "port", 0, "监听端口，0 表示随机端口")
	flag.StringVar(&dataDir, "data-dir", "", "数据目录，默认 ~/Library/Application Support/DitKit")
	flag.BoolVar(&noRuntime, "no-runtime", false, "不写 runtime.json")
	flag.BoolVar(&showVersion, "version", false, "打印版本")
	flag.Parse()
	if showVersion {
		fmt.Println(api.Version)
		return
	}

	client, err := smart.NewClient()
	if err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		os.Exit(1)
	}

	home, _ := os.UserHomeDir()
	if dataDir == "" {
		dataDir = filepath.Join(home, "Library", "Application Support", "DitKit")
	}
	cfg := api.Config{Port: port, Token: randomToken(), DataDir: dataDir}
	shutdown := make(chan struct{}, 1)
	srv := &api.Server{Client: client, Token: cfg.Token, Started: time.Now(), Shutdown: shutdown}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := api.Serve(ctx, cfg, srv.Handler(), shutdown, !noRuntime); err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		os.Exit(1)
	}
}

func randomToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
