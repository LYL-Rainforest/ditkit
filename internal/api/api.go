// Package api 只做协议转换：把 smart 包产出的中文报告通过本机 HTTP/SSE 提供给 SwiftUI。
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/LYL-Rainforest/ditkit/internal/smart"
)

const Version = "0.3.1"

// scanCacheTTL 磁盘列表变化很少，短时间内复用扫描结果，避免每次 SMART 请求都重复跑 smartctl --scan。
const scanCacheTTL = 30 * time.Second

type Server struct {
	Client   smart.Client
	Token    string
	Started  time.Time
	Shutdown chan<- struct{}

	scanMu    sync.Mutex
	scanDisks []smart.Disk
	scanAt    time.Time
}

// cachedScan 在 TTL 内复用磁盘列表；过期或首次调用才真正执行扫描。
func (s *Server) cachedScan(ctx context.Context) ([]smart.Disk, error) {
	s.scanMu.Lock()
	if s.scanAt.After(time.Now().Add(-scanCacheTTL)) && s.scanDisks != nil {
		disks := s.scanDisks
		s.scanMu.Unlock()
		return disks, nil
	}
	s.scanMu.Unlock()

	disks, err := s.Client.Scan(ctx)
	if err != nil {
		return nil, err
	}
	s.scanMu.Lock()
	s.scanDisks = disks
	s.scanAt = time.Now()
	s.scanMu.Unlock()
	return disks, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", s.handleHealth)
	mux.HandleFunc("GET /api/v1/disks", s.handleDisks)
	mux.HandleFunc("GET /api/v1/smart", s.handleSmart)
	mux.HandleFunc("POST /api/v1/shutdown", s.handleShutdown)
	return s.recoverer(s.auth(mux))
}

func (s *Server) auth(next http.Handler) http.Handler {
	expected := []byte("Bearer " + s.Token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		provided := []byte(r.Header.Get("Authorization"))
		// 常量时间比较，避免通过响应耗时侧信道逐字节推断令牌。
		if subtle.ConstantTimeCompare(provided, expected) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "本机访问令牌无效")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				writeError(w, http.StatusInternalServerError, "internal", fmt.Sprintf("服务内部错误：%v", v))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "ok",
		"version":  Version,
		"uptime_s": int(time.Since(s.Started).Seconds()),
		"smartctl": s.Client.Binary,
	})
}

func (s *Server) handleDisks(w http.ResponseWriter, r *http.Request) {
	disks, err := s.cachedScan(r.Context())
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "scan_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"disks": disks, "count": len(disks)})
}

// handleSmart 的 device 参数只能是扫描白名单中的 ID，不接受任意路径，杜绝命令注入。
func (s *Server) handleSmart(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("device")
	if id == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "缺少 device 参数，请先调用 /api/v1/disks")
		return
	}
	// 从缓存的扫描白名单里按 ID 查找：既保留白名单校验（杜绝任意路径），又避免每次重复扫描。
	disks, err := s.cachedScan(r.Context())
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "scan_failed", err.Error())
		return
	}
	var disk *smart.Disk
	for i := range disks {
		if disks[i].ID == id {
			disk = &disks[i]
			break
		}
	}
	if disk == nil {
		writeError(w, http.StatusNotFound, "not_found", fmt.Sprintf("设备 %s 不在扫描结果中", id))
		return
	}
	raw, err := s.Client.Read(r.Context(), *disk)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "read_failed", err.Error())
		return
	}
	report, err := smart.BuildReport(*disk, raw)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "parse_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, report)
}

func (s *Server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "正在退出"})
	select {
	case s.Shutdown <- struct{}{}:
	default:
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": message}})
}
