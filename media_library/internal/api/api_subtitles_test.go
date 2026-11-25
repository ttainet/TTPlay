package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"ttplay/media_library/internal/account"
	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/events"
	"ttplay/media_library/internal/ingest"
	"ttplay/media_library/internal/library"
	"ttplay/media_library/internal/metadata"
	"ttplay/media_library/internal/platform"
	"ttplay/media_library/internal/security"
	"ttplay/media_library/internal/source"
	"ttplay/media_library/internal/vault"
)

func TestSubtitleAPIEndpoints(t *testing.T) {
	var mockSub *httptest.Server
	mockSub = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/xunlei":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"code": 0,
				"data": []map[string]any{
					{
						"cid":  "c1",
						"url":  mockSub.URL + "/sub.srt",
						"ext":  "srt",
						"name": "Test.Movie.2024.chs.srt",
					},
				},
			})
		case "/sub.srt":
			_, _ = w.Write([]byte("1\n00:00:01,000 --> 00:00:02,000\n测试字幕\n"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockSub.Close()

	dataDir := t.TempDir()
	v, err := vault.Open(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dataDir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	xlBase := mockSub.URL + "/xunlei"
	falseVal := false
	trueVal := true
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		XunleiSubEnabled:    &trueVal,
		XunleiSubAPIBase:    &xlBase,
		AllowPublicMetadata: &trueVal,
		AssrtEnabled:        &falseVal,
		SubDLEnabled:        &falseVal,
		OpenSubtitlesEnabled: &falseVal,
	}); err != nil {
		t.Fatal(err)
	}

	metaSvc := metadata.NewService(store)
	scraper := library.NewScraper(store, metaSvc)
	hub := events.NewHub()
	limiter := security.NewLoginLimiter()
	platSvc, err := platform.NewService(store, limiter, "")
	if err != nil {
		t.Fatal(err)
	}
	accSvc := account.NewService(store, limiter)
	srcSvc := source.NewService(store, hub)
	ingSvc := ingest.NewService(store, hub, limiter)
	srv := NewServer(store, metaSvc, scraper, hub, platSvc, accSvc, srcSvc, ingSvc)
	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	// 1. Public config
	cfgResp, err := http.Get(ts.URL + "/api/v1/public/subtitles/config")
	if err != nil || cfgResp.StatusCode != http.StatusOK {
		t.Fatalf("config failed: resp=%v err=%v", cfgResp, err)
	}
	var cfgBody struct {
		Code             int      `json:"code"`
		EnabledProviders []string `json:"enabled_providers"`
	}
	_ = json.NewDecoder(cfgResp.Body).Decode(&cfgBody)
	_ = cfgResp.Body.Close()
	if cfgBody.Code != 0 || len(cfgBody.EnabledProviders) != 1 || cfgBody.EnabledProviders[0] != "xunlei" {
		t.Fatalf("unexpected config body: %+v", cfgBody)
	}

	// 2. Public search validation (missing params -> 400)
	badSearch, err := http.Get(ts.URL + "/api/v1/public/subtitles/search")
	if err != nil || badSearch.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for empty search, got %v err=%v", badSearch, err)
	}
	_ = badSearch.Body.Close()

	// 3. Public search
	searchResp, err := http.Get(ts.URL + "/api/v1/public/subtitles/search?title=Test+Movie&language=zh")
	if err != nil || searchResp.StatusCode != http.StatusOK {
		t.Fatalf("search failed: resp=%v err=%v", searchResp, err)
	}
	var searchBody struct {
		Code       int `json:"code"`
		Candidates []struct {
			Provider      string `json:"provider"`
			DownloadToken string `json:"download_token"`
		} `json:"candidates"`
	}
	_ = json.NewDecoder(searchResp.Body).Decode(&searchBody)
	_ = searchResp.Body.Close()
	if len(searchBody.Candidates) != 1 || searchBody.Candidates[0].DownloadToken == "" {
		t.Fatalf("unexpected search body: %+v", searchBody)
	}

	// 4. Tampered token fails (400)
	badDLBody, _ := json.Marshal(map[string]any{
		"provider": "xunlei",
		"token":    searchBody.Candidates[0].DownloadToken + "x",
	})
	badDLResp, err := http.Post(ts.URL+"/api/v1/public/subtitles/download", "application/json", bytes.NewReader(badDLBody))
	if err != nil || badDLResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for tampered token, got %v err=%v", badDLResp, err)
	}
	_ = badDLResp.Body.Close()

	// 5. Authenticated endpoint requires token
	unauthResp, err := http.Get(ts.URL + "/api/v1/subtitles/config")
	if err != nil || unauthResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauthenticated /api/v1/subtitles/config, got %v err=%v", unauthResp, err)
	}
	_ = unauthResp.Body.Close()
}
