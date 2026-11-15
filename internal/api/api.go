// Package api 只做协议转换：把 smart 包产出的中文报告通过本机 HTTP/SSE 提供给 SwiftUI。
package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/LYL-Rainforest/ditkit/internal/smart"
)

const Version = "0.1.0"

type Server struct {
	Client   smart.Client
	Token    string
	Started  time.Time
	Shutdown chan<- struct{}
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
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+s.Token {
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
	disks, err := s.Client.Scan(r.Context())
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
	disk, err := s.Client.Resolve(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, "not_found", err.Error())
		return
	}
	raw, err := s.Client.Read(r.Context(), disk)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "read_failed", err.Error())
		return
	}
	report, err := smart.BuildReport(disk, raw)
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
