package danmaku

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"

	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/vault"
)

func openDanmuTestStore(t *testing.T, baseURL, token string, enabled bool) *db.Store {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		DanmuEnabled: &enabled,
		DanmuAPIBase: &baseURL,
		DanmuToken:   &token,
	}); err != nil {
		t.Fatal(err)
	}
	return store
}

func TestBuildUpstreamURL(t *testing.T) {
	cases := []struct {
		name    string
		base    string
		token   string
		path    string
		query   url.Values
		want    string
		wantErr bool
	}{
		{
			name:  "plain base with token",
			base:  "http://127.0.0.1:20016",
			token: "my_tok",
			path:  "/search/anime",
			query: url.Values{"keyword": {"三体"}},
			want:  "http://127.0.0.1:20016/my_tok/api/v2/search/anime?keyword=%E4%B8%89%E4%BD%93",
		},
		{
			name:  "base already includes token and api/v2",
			base:  "http://127.0.0.1:20016/my_tok/api/v2/",
			token: "my_tok",
			path:  "match",
			want:  "http://127.0.0.1:20016/my_tok/api/v2/match",
		},
		{
			name:  "without token",
			base:  "http://127.0.0.1:20016/",
			token: "",
			path:  "/bangumi/12",
			want:  "http://127.0.0.1:20016/api/v2/bangumi/12",
		},
		{
			name:    "empty base",
			base:    "",
			token:   "t",
			path:    "/match",
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := BuildUpstreamURL(tc.base, tc.token, tc.path, tc.query)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %s", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBuildMatchFileNameAndParseCommentP(t *testing.T) {
	if got := BuildMatchFileName(MatchRequest{
		FileName: "Three.Body.S01E01.mkv",
		Platform: "@qq",
	}); got != "Three.Body.S01E01.mkv @qq" {
		t.Fatalf("unexpected filename match: %q", got)
	}
	if got := BuildMatchFileName(MatchRequest{
		ShowTitle: "三体",
		Kind:      "episode",
		Season:    1,
		Episode:   2,
	}); got != "三体 S01E02" {
		t.Fatalf("unexpected episode match: %q", got)
	}
	if got := BuildMatchFileName(MatchRequest{
		Title: "流浪地球",
		Kind:  "movie",
		Year:  2019,
	}); got != "流浪地球 (2019)" {
		t.Fatalf("unexpected movie match: %q", got)
	}

	sec, mode, color, uid := ParseCommentP("12.34,5,16711680,user_1")
	if sec != 12.34 || mode != 5 || color != 16711680 || uid != "user_1" {
		t.Fatalf("unexpected 4-field parse: sec=%v mode=%d color=%d uid=%q", sec, mode, color, uid)
	}

	sec2, mode2, color2, uid2 := ParseCommentP("5.0,1,25,16488046,1751533608,0,u99,13190629936")
	if sec2 != 5.0 || mode2 != 1 || color2 != 16488046 || uid2 != "u99" {
		t.Fatalf("unexpected 8-field parse: sec=%v mode=%d color=%d uid=%q", sec2, mode2, color2, uid2)
	}
}

func TestDanmakuServiceFlowsAndCache(t *testing.T) {
	var hits atomic.Int32
	var forceEmptyComments atomic.Bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		switch r.URL.Path {
		case "/tok123/api/v2/match":
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
		case "/tok123/api/v2/search/anime":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"animes": []map[string]any{
					{
						"animeId":      "101",
						"animeTitle":   "三体",
						"episodeCount": 30,
						"source":       "qq",
					},
				},
			})
		case "/tok123/api/v2/bangumi/101":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"bangumi": map[string]any{
					"animeId":    101,
					"animeTitle": "三体",
					"episodes": []map[string]any{
						{
							"episodeId":     10001,
							"episodeTitle":  "第1集",
							"episodeNumber": 1,
							"url":           "https://v.qq.com/x/cover/101/ep1.html",
						},
					},
				},
			})
		case "/tok123/api/v2/comment/10001":
			if forceEmptyComments.Load() {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"count":    0,
					"comments": []any{},
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"count":         1,
				"videoDuration": 2700,
				"comments": []map[string]any{
					{"cid": 1, "p": "10.5,1,16777215,u1", "m": "前方高能"},
				},
			})
		case "/tok123/api/v2/comment/404":
			w.WriteHeader(http.StatusNotFound)
		case "/tok123/api/v2/comment":
			if r.URL.Query().Get("url") == "https://v.qq.com/x/cover/101/ep2.html" {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"count":         1,
					"videoDuration": 2650,
					"comments": []map[string]any{
						{"cid": 2, "p": "20.0,4,16711680,u2", "m": "URL回退成功"},
					},
				})
				return
			}
			w.WriteHeader(http.StatusNotFound)
		case "/badtok/api/v2/search/anime":
			w.WriteHeader(http.StatusUnauthorized)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	store := openDanmuTestStore(t, srv.URL, "tok123", true)
	svc := NewService(store)

	// 1. Match + cache hit
	m1, err := svc.Match(context.Background(), MatchRequest{Title: "三体", Kind: "episode", Season: 1, Episode: 1}, false)
	if err != nil || !m1.Matched || len(m1.Matches) != 1 || m1.Matches[0].EpisodeID != "10001" {
		t.Fatalf("match failed: res=%+v err=%v", m1, err)
	}
	if m1.Cached {
		t.Fatalf("first match should not be cached")
	}
	m2, err := svc.Match(context.Background(), MatchRequest{Title: "三体", Kind: "episode", Season: 1, Episode: 1}, false)
	if err != nil || !m2.Cached {
		t.Fatalf("second match should hit cache: res=%+v err=%v", m2, err)
	}

	// 2. Search + Bangumi
	sr, err := svc.SearchAnime(context.Background(), "三体", false)
	if err != nil || len(sr.Animes) != 1 || sr.Animes[0].AnimeID != "101" {
		t.Fatalf("search failed: res=%+v err=%v", sr, err)
	}
	bg, err := svc.GetBangumi(context.Background(), "101", false)
	if err != nil || len(bg.Episodes) != 1 || bg.Episodes[0].EpisodeNumber != "1" {
		t.Fatalf("bangumi failed: res=%+v err=%v", bg, err)
	}

	// 3. Empty comments must NOT be cached
	forceEmptyComments.Store(true)
	emptyRes, err := svc.GetComments(context.Background(), "10001", "", 0, false)
	if err != nil || len(emptyRes.Comments) != 0 {
		t.Fatalf("expected empty comments, got res=%+v err=%v", emptyRes, err)
	}
	forceEmptyComments.Store(false)

	c1, err := svc.GetComments(context.Background(), "10001", "", 0, false)
	if err != nil || len(c1.Comments) != 1 || c1.Comments[0].Text != "前方高能" || c1.Cached {
		t.Fatalf("comments fetch failed: res=%+v err=%v", c1, err)
	}
	beforeHits := hits.Load()
	c2, err := svc.GetComments(context.Background(), "10001", "", 0, false)
	if err != nil || !c2.Cached || hits.Load() != beforeHits {
		t.Fatalf("expected cached comments without upstream hit: res=%+v err=%v hits=%d->%d", c2, err, beforeHits, hits.Load())
	}

	// 4. Fallback to source URL when episodeId returns 404
	fb, err := svc.GetComments(context.Background(), "404", "https://v.qq.com/x/cover/101/ep2.html", 0, false)
	if err != nil || len(fb.Comments) != 1 || fb.Comments[0].Text != "URL回退成功" {
		t.Fatalf("fallback failed: res=%+v err=%v", fb, err)
	}

	// 5. TestConnection success & 401 failure
	if _, msg, err := svc.TestConnection(context.Background(), ProviderTestOverrides{}); err != nil || msg == "" {
		t.Fatalf("TestConnection failed: msg=%q err=%v", msg, err)
	}
	badTok := "badtok"
	if _, _, err := svc.TestConnection(context.Background(), ProviderTestOverrides{Token: &badTok}); !errors.Is(err, ErrUpstream) {
		t.Fatalf("expected ErrUpstream on 401, got %v", err)
	}

	// 6. CacheStats & ClearCache
	stats := svc.CacheStats()
	if stats.Searches == 0 || stats.Comments == 0 {
		t.Fatalf("expected non-zero cache stats, got %+v", stats)
	}
	deleted, afterClear, err := svc.ClearCache("all")
	if err != nil || deleted == 0 || afterClear.Searches != 0 || afterClear.Comments != 0 {
		t.Fatalf("ClearCache failed: deleted=%d after=%+v err=%v", deleted, afterClear, err)
	}
}

func TestPreferredPlatformSortAndCommentSampling(t *testing.T) {
	items := []MatchItem{
		{EpisodeID: "1", AnimeTitle: "测试 from migu", EpisodeTitle: "【migu】 第1集"},
		{EpisodeID: "2", AnimeTitle: "测试 from iqiyi", EpisodeTitle: "【qiyi】 第1集"},
		{EpisodeID: "3", AnimeTitle: "测试 from tencent", EpisodeTitle: "【qq】 第1集"},
	}
	sorted := SortMatchesByPreferredPlatforms(items, "tencent,iqiyi")
	if sorted[0].EpisodeID != "3" || sorted[1].EpisodeID != "2" || sorted[2].EpisodeID != "1" {
		t.Fatalf("unexpected platform sort order: %+v", sorted)
	}
	// Original slice must remain unmutated.
	if items[0].EpisodeID != "1" {
		t.Fatalf("input slice was mutated")
	}

	comments := []DanmakuComment{
		{CID: 1, Time: 30, Text: "t30"},
		{CID: 2, Time: 10, Text: "t10"},
		{CID: 3, Time: 20, Text: "t20"},
		{CID: 4, Time: 40, Text: "t40"},
		{CID: 5, Time: 50, Text: "t50"},
	}
	sampled, didSample := SampleComments(comments, 3)
	if !didSample || len(sampled) != 3 {
		t.Fatalf("expected 3 sampled comments, got len=%d didSample=%v", len(sampled), didSample)
	}
	if sampled[0].Time != 10 || sampled[1].Time != 30 || sampled[2].Time != 50 {
		t.Fatalf("unexpected sampled timeline points: %+v", sampled)
	}
}

func TestCacheZeroTTLBypassAndMaxComments(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"count":         4,
			"videoDuration": 120,
			"comments": []map[string]any{
				{"cid": 1, "p": "1.0,1,16777215,u1", "m": "c1"},
				{"cid": 2, "p": "2.0,1,16777215,u1", "m": "c2"},
				{"cid": 3, "p": "3.0,1,16777215,u1", "m": "c3"},
				{"cid": 4, "p": "4.0,1,16777215,u1", "m": "c4"},
			},
		})
	}))
	defer srv.Close()

	store := openDanmuTestStore(t, srv.URL, "", true)
	zero := 0
	maxTwo := 2
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{
		DanmuCommentCacheHours: &zero,
		DanmuMaxComments:       &maxTwo,
	}); err != nil {
		t.Fatal(err)
	}
	svc := NewService(store)

	r1, err := svc.GetComments(context.Background(), "99", "", 0, false)
	if err != nil || r1.Count != 2 || r1.TotalCount != 4 || !r1.Sampled || r1.Cached {
		t.Fatalf("unexpected r1: %+v err=%v", r1, err)
	}
	r2, err := svc.GetComments(context.Background(), "99", "", 0, false)
	if err != nil || r2.Cached || hits.Load() != 2 {
		t.Fatalf("expected cache bypass when ttl=0, r2=%+v hits=%d err=%v", r2, hits.Load(), err)
	}
}
