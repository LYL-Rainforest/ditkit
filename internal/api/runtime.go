package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type Config struct {
	Port    int
	Token   string
	DataDir string
}

type RuntimeInfo struct {
	Port      int    `json:"port"`
	Token     string `json:"token"`
	PID       int    `json:"pid"`
	Version   string `json:"version"`
	DataDir   string `json:"data_dir"`
	StartedAt string `json:"started_at"`
}

func (c Config) RuntimePath() string {
	return filepath.Join(c.DataDir, "runtime.json")
}

func WriteRuntime(path string, info RuntimeInfo) error {
	b, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o600)
}

func ReadRuntime(path string) (RuntimeInfo, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return RuntimeInfo{}, fmt.Errorf("读取 runtime.json（后端是否已启动）: %w", err)
	}
	var info RuntimeInfo
	if err := json.Unmarshal(b, &info); err != nil {
		return RuntimeInfo{}, err
	}
	if info.Port < 1 || info.Token == "" {
		return RuntimeInfo{}, errors.New("runtime.json 内容不完整")
	}
	return info, nil
}

func RemoveRuntime(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Serve 仅监听 127.0.0.1，端口为 0 时由内核分配随机端口，并写入 runtime.json 供 SwiftUI 发现。
func Serve(ctx context.Context, cfg Config, h http.Handler, shutdown <-chan struct{}, writeRuntime bool) error {
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port)))
	if err != nil {
		return fmt.Errorf("监听本机端口失败: %w", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	runtimePath := cfg.RuntimePath()
	if writeRuntime {
		if err := WriteRuntime(runtimePath, RuntimeInfo{
			Port: port, Token: cfg.Token, PID: os.Getpid(), Version: Version,
			DataDir: cfg.DataDir, StartedAt: time.Now().Format(time.RFC3339),
		}); err != nil {
			_ = ln.Close()
			return fmt.Errorf("写入 runtime.json: %w", err)
		}
		defer func() { _ = RemoveRuntime(runtimePath) }()
	}
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 120 * time.Second}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(ln) }()

	select {
	case <-ctx.Done():
	case <-shutdown:
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_ = srv.Shutdown(stopCtx)
	return nil
}
