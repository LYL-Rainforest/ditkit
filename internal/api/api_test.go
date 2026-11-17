package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// 鉴权必须只接受完全一致的 Bearer 令牌；错误或缺失令牌一律 401。
func TestAuthRejectsWrongToken(t *testing.T) {
	s := &Server{Token: "s3cr3t-token", Started: time.Now()}
	var reached bool
	h := s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		w.WriteHeader(http.StatusOK)
	}))

	cases := []struct {
		name   string
		header string
		want   int
	}{
		{"correct", "Bearer s3cr3t-token", http.StatusOK},
		{"wrong", "Bearer wrong-token", http.StatusUnauthorized},
		{"missing", "", http.StatusUnauthorized},
		{"wrong scheme", "Basic s3cr3t-token", http.StatusUnauthorized},
		{"prefix only", "Bearer s3cr3t-toke", http.StatusUnauthorized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reached = false
			req := httptest.NewRequest("GET", "/api/v1/health", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("%s: got %d, want %d", tc.name, rec.Code, tc.want)
			}
			if tc.want == http.StatusOK && !reached {
				t.Fatal("正确令牌应放行到下游 handler")
			}
			if tc.want == http.StatusUnauthorized && reached {
				t.Fatal("错误令牌不应放行到下游 handler")
			}
		})
	}
}
