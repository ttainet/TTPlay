package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"ttplay/media_library/internal/clientlogs"
	"ttplay/media_library/internal/db"
)

func doTextReq(srv *Server, method, path, remoteAddr string, headers map[string]string, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if remoteAddr != "" {
		req.RemoteAddr = remoteAddr
	} else {
		req.RemoteAddr = "198.51.100.10:12345"
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	srv.Mux.ServeHTTP(rec, req)
	return rec
}

func TestClientLogsUploadAndAdminEndpoints(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")
	adminTok := mustLoginReadyAdmin(t, srv)
	userTok, _, _, _ := mustRegisterAndLoginDevice(t, srv, "clientlog_user", db.DeviceClassDesktop, "10.10.0.2:1000", true)

	// Explicitly disable public metadata to verify client log uploads remain allowed without auth.
	if res := doJSONReq(srv, http.MethodPatch, "/api/admin/settings", adminTok, "127.0.0.1:2000", nil, map[string]any{
		"allow_public_metadata": false,
	}); res.Code != http.StatusOK {
		t.Fatalf("disable allow_public_metadata failed: %d %s", res.Code, res.Body.String())
	}

	now := time.Date(2026, 11, 26, 16, 15, 0, 0, time.UTC) // 2026-11-27 00:15 UTC+8
	srv.ClientLogs.SetClock(func() time.Time { return now })

	// 1. Upload via /logs (matches Flutter client)
	payload1 := "TTPlay v2.26.15 (175)\nAndroid 12 (API 31)\nXiaomi TV Box\nTV mode: yes\n---\n[00:15:00.000] [ERROR] Quark timeout"
	up1 := doTextReq(srv, http.MethodPost, "/logs", "203.0.113.10:5000", map[string]string{
		"X-Client-Device": url.PathEscape("客厅电视盒子"),
	}, payload1)
	if up1.Code != http.StatusOK {
		t.Fatalf("POST /logs failed: %d %s", up1.Code, up1.Body.String())
	}
	var up1Parsed struct {
		Code      int    `json:"code"`
		ID        string `json:"id"`
		CreatedAt int64  `json:"created_at"`
	}
	_ = json.Unmarshal(up1.Body.Bytes(), &up1Parsed)
	if up1Parsed.ID == "" || up1Parsed.Code != 0 {
		t.Fatalf("unexpected upload response: %+v", up1Parsed)
	}

	// 2. Upload via /api/v1/public/client-logs on a different day
	now = now.Add(25 * time.Hour) // 2026-11-27 17:15 UTC == 2026-11-28 01:15 UTC+8
	payload2 := "TTPlay v2.26.15 (175)\nmacOS 15.1\nMacBookPro18,3\n---\n[01:15:00.000] [INFO] all good"
	up2 := doTextReq(srv, http.MethodPost, "/api/v1/public/client-logs", "203.0.113.11:5001", nil, payload2)
	if up2.Code != http.StatusOK {
		t.Fatalf("POST /api/v1/public/client-logs failed: %d %s", up2.Code, up2.Body.String())
	}
	var up2Parsed struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(up2.Body.Bytes(), &up2Parsed)

	// 3. Validation & payload limit checks
	emptyRes := doTextReq(srv, http.MethodPost, "/logs", "203.0.113.12:5002", nil, "   \n  ")
	if emptyRes.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on empty body, got %d", emptyRes.Code)
	}
	oversized := strings.Repeat("x", clientlogs.MaxPayloadBytes+10)
	bigRes := doTextReq(srv, http.MethodPost, "/logs", "203.0.113.13:5003", nil, oversized)
	if bigRes.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 on oversized body, got %d %s", bigRes.Code, bigRes.Body.String())
	}

	// 4. Rate limit check (20 per IP per 10m; 21st returns 429)
	for i := 0; i < 20; i++ {
		r := doTextReq(srv, http.MethodPost, "/logs", "203.0.113.99:9000", nil, "TTPlay v1.0\nLinux x\nhost\n---\nhi")
		if r.Code != http.StatusOK {
			t.Fatalf("upload %d unexpectedly failed: %d %s", i, r.Code, r.Body.String())
		}
	}
	rlRes := doTextReq(srv, http.MethodPost, "/logs", "203.0.113.99:9000", nil, "TTPlay v1.0\nLinux x\nhost\n---\nhi")
	if rlRes.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 rate limited on 21st upload, got %d", rlRes.Code)
	}

	// 5. Isolation: normal user token cannot access admin client-logs endpoints
	if res := doJSONReq(srv, http.MethodGet, "/api/admin/client-logs", userTok, "", nil, nil); res.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for user token on admin client-logs, got %d", res.Code)
	}

	// 6. Admin filter by device & timezone date
	listRes := doJSONReq(
		srv,
		http.MethodGet,
		"/api/admin/client-logs?device="+url.QueryEscape("客厅电视盒子")+"&date_from=2026-11-27&date_to=2026-11-27&tz_offset=-480",
		adminTok,
		"127.0.0.1:2000",
		nil,
		nil,
	)
	if listRes.Code != http.StatusOK {
		t.Fatalf("admin list client-logs failed: %d %s", listRes.Code, listRes.Body.String())
	}
	var listParsed struct {
		Total     int                        `json:"total"`
		Items     []clientlogs.RecordSummary `json:"items"`
		Devices   []string                   `json:"devices"`
		Platforms []string                   `json:"platforms"`
	}
	_ = json.Unmarshal(listRes.Body.Bytes(), &listParsed)
	if listParsed.Total != 1 || listParsed.Items[0].ID != up1Parsed.ID || !listParsed.Items[0].IsTV {
		t.Fatalf("unexpected filtered client-logs list: %+v", listParsed)
	}

	// 7. Get detail & download
	detailRes := doJSONReq(srv, http.MethodGet, "/api/admin/client-logs/"+up1Parsed.ID, adminTok, "127.0.0.1:2000", nil, nil)
	if detailRes.Code != http.StatusOK || !strings.Contains(detailRes.Body.String(), "Quark timeout") {
		t.Fatalf("admin get client-log failed: %d %s", detailRes.Code, detailRes.Body.String())
	}
	dlRes := doJSONReq(srv, http.MethodGet, "/api/admin/client-logs/"+up2Parsed.ID+"/download", adminTok, "127.0.0.1:2000", nil, nil)
	if dlRes.Code != http.StatusOK || !strings.Contains(dlRes.Header().Get("Content-Disposition"), ".log") || !strings.Contains(dlRes.Body.String(), "all good") {
		t.Fatalf("admin download client-log failed: %d %s", dlRes.Code, dlRes.Body.String())
	}

	// 8. Delete single & prune remaining
	delRes := doJSONReq(srv, http.MethodDelete, "/api/admin/client-logs/"+up1Parsed.ID, adminTok, "127.0.0.1:2000", nil, nil)
	if delRes.Code != http.StatusOK {
		t.Fatalf("admin delete client-log failed: %d %s", delRes.Code, delRes.Body.String())
	}
	if getAfterDel := doJSONReq(srv, http.MethodGet, "/api/admin/client-logs/"+up1Parsed.ID, adminTok, "127.0.0.1:2000", nil, nil); getAfterDel.Code != http.StatusNotFound {
		t.Fatalf("expected 404 after delete, got %d", getAfterDel.Code)
	}

	pruneRes := doJSONReq(srv, http.MethodPost, "/api/admin/client-logs/prune", adminTok, "127.0.0.1:2000", nil, map[string]any{
		"all": true,
	})
	if pruneRes.Code != http.StatusOK || !strings.Contains(pruneRes.Body.String(), `"deleted":21`) {
		t.Fatalf("admin prune client-logs failed: %d %s", pruneRes.Code, pruneRes.Body.String())
	}
}
