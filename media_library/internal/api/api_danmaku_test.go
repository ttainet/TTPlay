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

func TestDanmakuAPIEndpoints(t *testing.T) {
	mockDanmu := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/test_tok/api/v2/search/anime":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"animes": []map[string]any{
					{"animeId": 101, "animeTitle": "三体", "episodeCount": 30, "source": "qq"},
				},
			})
		case "/test_tok/api/v2/match":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"isMatched": true,
				"matches": []map[string]any{
					{
						"episodeId":    10001,
						"animeId":      101,
						"animeTitle":   "三体",
						"episodeTitle": "第1集",
						"shift":        0,
						"url":          "https://v.qq.com/x/cover/101/ep1.html",
					},
				},
			})
		case "/test_tok/api/v2/bangumi/101":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"bangumi": map[string]any{
					"animeId":    101,
					"animeTitle": "三体",
					"episodes": []map[string]any{
						{"episodeId": 10001, "episodeTitle": "第1集", "episodeNumber": 1},
					},
				},
			})
		case "/test_tok/api/v2/comment/10001":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"count":         3,
				"videoDuration": 2700,
				"comments": []map[string]any{
					{"cid": 1, "p": "5.0,1,16777215,u1", "m": "测试弹幕1"},
					{"cid": 2, "p": "15.0,1,16777215,u2", "m": "测试弹幕2"},
					{"cid": 3, "p": "25.0,1,16777215,u3", "m": "测试弹幕3"},
				},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockDanmu.Close()

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

	falseVal := false
	trueVal := true
	tok := "test_tok"
	base := mockDanmu.URL
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		AllowPublicMetadata: &trueVal,
		DanmuEnabled:        &falseVal,
		DanmuAPIBase:        &base,
		DanmuToken:          &tok,
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
	if _, err := platSvc.EnsureDefaultAdmin("admin", "TestPass123!"); err != nil {
		t.Fatal(err)
	}
	adminRes, err := platSvc.Login("admin", "TestPass123!", "127.0.0.1", "test")
	if err != nil {
		t.Fatal(err)
	}

	accSvc := account.NewService(store, limiter)
	srcSvc := source.NewService(store, hub)
	ingSvc := ingest.NewService(store, hub, limiter)
	srv := NewServer(store, metaSvc, scraper, hub, platSvc, accSvc, srcSvc, ingSvc)
	ts := httptest.NewServer(srv.Mux)
	defer ts.Close()

	// 1. Disabled -> config returns enabled:false + defaults, search returns 412
	cfgResp, err := http.Get(ts.URL + "/api/v1/public/danmaku/config")
	if err != nil || cfgResp.StatusCode != http.StatusOK {
		t.Fatalf("config failed: resp=%v err=%v", cfgResp, err)
	}
	var cfgBody struct {
		Enabled           bool `json:"enabled"`
		TimeoutSec        int  `json:"timeout_sec"`
		SearchCacheHours  int  `json:"search_cache_hours"`
		CommentCacheHours int  `json:"comment_cache_hours"`
	}
	_ = json.NewDecoder(cfgResp.Body).Decode(&cfgBody)
	_ = cfgResp.Body.Close()
	if cfgBody.Enabled || cfgBody.TimeoutSec != 30 || cfgBody.SearchCacheHours != 6 || cfgBody.CommentCacheHours != 168 {
		t.Fatalf("unexpected danmaku config defaults: %+v", cfgBody)
	}

	disabledSearch, err := http.Get(ts.URL + "/api/v1/public/danmaku/search?keyword=%E4%B8%89%E4%BD%93")
	if err != nil || disabledSearch.StatusCode != http.StatusPreconditionFailed {
		t.Fatalf("expected 412 when disabled, got %v err=%v", disabledSearch, err)
	}
	_ = disabledSearch.Body.Close()

	// Enable danmu
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{DanmuEnabled: &trueVal}); err != nil {
		t.Fatal(err)
	}

	// 2. Missing params -> 400
	badMatch, err := http.Post(ts.URL+"/api/v1/public/danmaku/match", "application/json", bytes.NewReader([]byte(`{}`)))
	if err != nil || badMatch.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 on empty match, got %v err=%v", badMatch, err)
	}
	_ = badMatch.Body.Close()

	// 3. Match, Search, Bangumi, Comments + cache hit
	mResp, err := http.Post(ts.URL+"/api/v1/public/danmaku/match", "application/json", bytes.NewReader([]byte(`{"title":"三体","kind":"episode","season":1,"episode":1}`)))
	if err != nil || mResp.StatusCode != http.StatusOK {
		t.Fatalf("match failed: resp=%v err=%v", mResp, err)
	}
	var mBody struct {
		Matched bool `json:"matched"`
		Matches []struct {
			EpisodeID string `json:"episode_id"`
		} `json:"matches"`
	}
	_ = json.NewDecoder(mResp.Body).Decode(&mBody)
	_ = mResp.Body.Close()
	if !mBody.Matched || len(mBody.Matches) != 1 || mBody.Matches[0].EpisodeID != "10001" {
		t.Fatalf("unexpected match response: %+v", mBody)
	}

	sResp, err := http.Get(ts.URL + "/api/v1/public/danmaku/search?keyword=%E4%B8%89%E4%BD%93")
	if err != nil || sResp.StatusCode != http.StatusOK {
		t.Fatalf("search failed: resp=%v err=%v", sResp, err)
	}
	_ = sResp.Body.Close()

	bResp, err := http.Get(ts.URL + "/api/v1/public/danmaku/bangumi/101")
	if err != nil || bResp.StatusCode != http.StatusOK {
		t.Fatalf("bangumi failed: resp=%v err=%v", bResp, err)
	}
	_ = bResp.Body.Close()

	cResp1, err := http.Get(ts.URL + "/api/v1/public/danmaku/comments?episode_id=10001")
	if err != nil || cResp1.StatusCode != http.StatusOK {
		t.Fatalf("comments 1 failed: resp=%v err=%v", cResp1, err)
	}
	var cBody1 struct {
		Count      int  `json:"count"`
		TotalCount int  `json:"total_count"`
		Sampled    bool `json:"sampled"`
		Cached     bool `json:"cached"`
	}
	_ = json.NewDecoder(cResp1.Body).Decode(&cBody1)
	_ = cResp1.Body.Close()
	if cBody1.Count != 3 || cBody1.TotalCount != 3 || cBody1.Sampled || cBody1.Cached {
		t.Fatalf("unexpected comments 1: %+v", cBody1)
	}

	cResp2, err := http.Get(ts.URL + "/api/v1/public/danmaku/comments?episode_id=10001&limit=2")
	if err != nil || cResp2.StatusCode != http.StatusOK {
		t.Fatalf("comments 2 failed: resp=%v err=%v", cResp2, err)
	}
	var cBody2 struct {
		Count      int  `json:"count"`
		TotalCount int  `json:"total_count"`
		Sampled    bool `json:"sampled"`
		Cached     bool `json:"cached"`
	}
	_ = json.NewDecoder(cResp2.Body).Decode(&cBody2)
	_ = cResp2.Body.Close()
	if !cBody2.Cached || cBody2.Count != 2 || cBody2.TotalCount != 3 || !cBody2.Sampled {
		t.Fatalf("expected cached sampled comments 2, got %+v", cBody2)
	}

	// 4. Unauthenticated user route -> 401
	unauthResp, err := http.Get(ts.URL + "/api/v1/danmaku/config")
	if err != nil || unauthResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauth danmaku config, got %v err=%v", unauthResp, err)
	}
	_ = unauthResp.Body.Close()

	// 5. Admin test-provider endpoint & cache stats/clear endpoints
	testReqBody, _ := json.Marshal(map[string]any{
		"provider": "danmu_api",
		"api_base": mockDanmu.URL,
		"token":    "test_tok",
	})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/settings/test-provider", bytes.NewReader(testReqBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+adminRes.AccessToken)
	testResp, err := http.DefaultClient.Do(req)
	if err != nil || testResp.StatusCode != http.StatusOK {
		t.Fatalf("admin test-provider failed: resp=%v err=%v", testResp, err)
	}
	_ = testResp.Body.Close()

	statsReq, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/admin/danmaku/stats", nil)
	statsReq.Header.Set("Authorization", "Bearer "+adminRes.AccessToken)
	statsResp, err := http.DefaultClient.Do(statsReq)
	if err != nil || statsResp.StatusCode != http.StatusOK {
		t.Fatalf("admin danmaku stats failed: resp=%v err=%v", statsResp, err)
	}
	var statsBody struct {
		Stats struct {
			Searches int64 `json:"searches"`
			Comments int64 `json:"comments"`
		} `json:"stats"`
	}
	_ = json.NewDecoder(statsResp.Body).Decode(&statsBody)
	_ = statsResp.Body.Close()
	if statsBody.Stats.Searches == 0 || statsBody.Stats.Comments == 0 {
		t.Fatalf("expected non-zero danmaku stats, got %+v", statsBody)
	}

	clrReq, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/admin/danmaku/clear-cache", bytes.NewReader([]byte(`{"scope":"all"}`)))
	clrReq.Header.Set("Content-Type", "application/json")
	clrReq.Header.Set("Authorization", "Bearer "+adminRes.AccessToken)
	clrResp, err := http.DefaultClient.Do(clrReq)
	if err != nil || clrResp.StatusCode != http.StatusOK {
		t.Fatalf("admin clear danmaku cache failed: resp=%v err=%v", clrResp, err)
	}
	var clrBody struct {
		Deleted int64 `json:"deleted"`
	}
	_ = json.NewDecoder(clrResp.Body).Decode(&clrBody)
	_ = clrResp.Body.Close()
	if clrBody.Deleted == 0 {
		t.Fatalf("expected deleted > 0, got %+v", clrBody)
	}
}
