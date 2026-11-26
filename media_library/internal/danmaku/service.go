package danmaku

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"ttplay/media_library/internal/applog"
	"ttplay/media_library/internal/db"
)

type Service struct {
	store       *db.Store
	flight      *sfGroup
	httpMu      sync.Mutex
	httpClients map[string]*http.Client
	nowFn       func() int64
}

func NewService(store *db.Store) *Service {
	return &Service{
		store:       store,
		flight:      &sfGroup{},
		httpClients: make(map[string]*http.Client),
		nowFn:       func() int64 { return time.Now().UnixMilli() },
	}
}

func (s *Service) SetNowFunc(fn func() int64) {
	if fn != nil {
		s.nowFn = fn
	}
}

func (s *Service) ConfigStatus() (enabled bool, configured bool) {
	cfg := s.GetConfig()
	return cfg.Enabled, cfg.Configured
}

func (s *Service) GetConfig() ConfigView {
	if s.store == nil {
		return ConfigView{
			Provider:           ProviderDanmuAPI,
			PreferredPlatforms: []string{},
			TimeoutSec:         db.DefaultDanmuTimeoutSec,
			SearchCacheHours:   db.DefaultDanmuSearchCacheHours,
			CommentCacheHours:  db.DefaultDanmuCommentCacheHours,
			MaxComments:        db.DefaultDanmuMaxComments,
		}
	}
	cfg := s.store.GetServerSettings()
	return ConfigView{
		Enabled:            cfg.DanmuEnabled,
		Configured:         cfg.DanmuEnabled && strings.TrimSpace(cfg.DanmuAPIBase) != "",
		Provider:           ProviderDanmuAPI,
		PreferredPlatforms: ParsePlatformList(cfg.DanmuPreferredPlatforms),
		TimeoutSec:         cfg.DanmuTimeoutSec,
		SearchCacheHours:   cfg.DanmuSearchCacheHours,
		CommentCacheHours:  cfg.DanmuCommentCacheHours,
		MaxComments:        cfg.DanmuMaxComments,
	}
}

func requireConfigured(cfg db.ServerSettings) error {
	if !cfg.DanmuEnabled || strings.TrimSpace(cfg.DanmuAPIBase) == "" {
		return ErrNotConfigured
	}
	return nil
}

func hoursToTTLMs(hours int) int64 {
	if hours <= 0 {
		return 0
	}
	return int64(hours) * 60 * 60 * 1000
}

func minPositive(a, b int) int {
	if a > 0 && b > 0 {
		if a < b {
			return a
		}
		return b
	}
	if a > 0 {
		return a
	}
	if b > 0 {
		return b
	}
	return 0
}

func (s *Service) Match(ctx context.Context, req MatchRequest, refresh bool) (MatchResult, error) {
	cfg := s.store.GetServerSettings()
	if err := requireConfigured(cfg); err != nil {
		return MatchResult{}, err
	}
	fileName := BuildMatchFileName(req)
	if fileName == "" {
		return MatchResult{}, fmt.Errorf("%w: file_name or title is required", ErrInvalidInput)
	}

	ttlMs := hoursToTTLMs(cfg.DanmuSearchCacheHours)
	cacheKey := hashKey("match:" + strings.ToLower(fileName))
	if !refresh && ttlMs > 0 {
		if cached, ok := s.loadSearchCache(cacheKey, &MatchResult{}); ok {
			res := *cached.(*MatchResult)
			res.Cached = true
			if strings.TrimSpace(req.Platform) == "" && cfg.DanmuPreferredPlatforms != "" {
				res.Matches = SortMatchesByPreferredPlatforms(res.Matches, cfg.DanmuPreferredPlatforms)
			}
			return res, nil
		}
	}

	val, err := s.flight.Do(cacheKey, func() (any, error) {
		if !refresh && ttlMs > 0 {
			if cached, ok := s.loadSearchCache(cacheKey, &MatchResult{}); ok {
				res := *cached.(*MatchResult)
				res.Cached = true
				return res, nil
			}
		}
		res, err := s.matchUpstream(ctx, cfg, fileName)
		if err != nil {
			return MatchResult{}, err
		}
		if len(res.Matches) > 0 && ttlMs > 0 {
			s.saveSearchCache(cacheKey, res, ttlMs)
		}
		return res, nil
	})
	if err != nil {
		return MatchResult{}, err
	}
	res := val.(MatchResult)
	if strings.TrimSpace(req.Platform) == "" && cfg.DanmuPreferredPlatforms != "" {
		res.Matches = SortMatchesByPreferredPlatforms(res.Matches, cfg.DanmuPreferredPlatforms)
	}
	return res, nil
}

func (s *Service) SearchAnime(ctx context.Context, keyword string, refresh bool) (SearchResult, error) {
	cfg := s.store.GetServerSettings()
	if err := requireConfigured(cfg); err != nil {
		return SearchResult{}, err
	}
	kw := strings.TrimSpace(keyword)
	if kw == "" {
		return SearchResult{}, fmt.Errorf("%w: keyword is required", ErrInvalidInput)
	}

	ttlMs := hoursToTTLMs(cfg.DanmuSearchCacheHours)
	cacheKey := hashKey("search:" + strings.ToLower(kw))
	if !refresh && ttlMs > 0 {
		if cached, ok := s.loadSearchCache(cacheKey, &SearchResult{}); ok {
			res := cached.(*SearchResult)
			res.Cached = true
			return *res, nil
		}
	}

	val, err := s.flight.Do(cacheKey, func() (any, error) {
		if !refresh && ttlMs > 0 {
			if cached, ok := s.loadSearchCache(cacheKey, &SearchResult{}); ok {
				res := cached.(*SearchResult)
				res.Cached = true
				return *res, nil
			}
		}
		res, err := s.searchAnimeUpstream(ctx, cfg, kw)
		if err != nil {
			return SearchResult{}, err
		}
		if len(res.Animes) > 0 && ttlMs > 0 {
			s.saveSearchCache(cacheKey, res, ttlMs)
		}
		return res, nil
	})
	if err != nil {
		return SearchResult{}, err
	}
	return val.(SearchResult), nil
}

func (s *Service) GetBangumi(ctx context.Context, animeID string, refresh bool) (BangumiDetail, error) {
	cfg := s.store.GetServerSettings()
	if err := requireConfigured(cfg); err != nil {
		return BangumiDetail{}, err
	}
	id := strings.TrimSpace(animeID)
	if id == "" {
		return BangumiDetail{}, fmt.Errorf("%w: anime_id is required", ErrInvalidInput)
	}

	ttlMs := hoursToTTLMs(cfg.DanmuSearchCacheHours)
	cacheKey := hashKey("bangumi:" + id)
	if !refresh && ttlMs > 0 {
		if cached, ok := s.loadSearchCache(cacheKey, &BangumiDetail{}); ok {
			res := cached.(*BangumiDetail)
			res.Cached = true
			return *res, nil
		}
	}

	val, err := s.flight.Do(cacheKey, func() (any, error) {
		if !refresh && ttlMs > 0 {
			if cached, ok := s.loadSearchCache(cacheKey, &BangumiDetail{}); ok {
				res := cached.(*BangumiDetail)
				res.Cached = true
				return *res, nil
			}
		}
		res, err := s.getBangumiUpstream(ctx, cfg, id)
		if err != nil {
			return BangumiDetail{}, err
		}
		if len(res.Episodes) > 0 && ttlMs > 0 {
			s.saveSearchCache(cacheKey, res, ttlMs)
		}
		return res, nil
	})
	if err != nil {
		return BangumiDetail{}, err
	}
	return val.(BangumiDetail), nil
}

func (s *Service) GetComments(ctx context.Context, episodeID, sourceURL string, limit int, refresh bool) (CommentsResult, error) {
	cfg := s.store.GetServerSettings()
	if err := requireConfigured(cfg); err != nil {
		return CommentsResult{}, err
	}
	ep := strings.TrimSpace(episodeID)
	src := strings.TrimSpace(sourceURL)
	if ep == "" && src == "" {
		return CommentsResult{}, fmt.Errorf("%w: episode_id or url is required", ErrInvalidInput)
	}

	var cacheKey string
	if src != "" {
		cacheKey = hashKey("url:" + src)
	} else {
		cacheKey = hashKey("ep:" + ep)
	}

	ttlMs := hoursToTTLMs(cfg.DanmuCommentCacheHours)
	applyLimit := func(res CommentsResult) CommentsResult {
		if res.TotalCount == 0 && len(res.Comments) > 0 {
			res.TotalCount = len(res.Comments)
		}
		effectiveLimit := minPositive(limit, cfg.DanmuMaxComments)
		if effectiveLimit > 0 {
			sampled, didSample := SampleComments(res.Comments, effectiveLimit)
			res.Comments = sampled
			res.Count = len(sampled)
			res.Sampled = didSample
		} else {
			res.Count = len(res.Comments)
			res.Sampled = false
		}
		return res
	}

	if !refresh && ttlMs > 0 {
		if cached, ok := s.loadCommentCache(cacheKey); ok {
			cached.Cached = true
			return applyLimit(cached), nil
		}
	}

	val, err := s.flight.Do(cacheKey, func() (any, error) {
		if !refresh && ttlMs > 0 {
			if cached, ok := s.loadCommentCache(cacheKey); ok {
				cached.Cached = true
				return cached, nil
			}
		}
		res, err := s.getCommentsUpstream(ctx, cfg, ep, src)
		if err != nil {
			return CommentsResult{}, err
		}
		// Never cache empty comment responses so transient upstream failures don't poison cache.
		// Always cache full unsampled comments so per-client/setting limit changes take effect cleanly.
		if len(res.Comments) > 0 && ttlMs > 0 {
			s.saveCommentCache(cacheKey, res, ttlMs)
		}
		return res, nil
	})
	if err != nil {
		return CommentsResult{}, err
	}
	return applyLimit(val.(CommentsResult)), nil
}

func (s *Service) TestConnection(ctx context.Context, ov ProviderTestOverrides) (int64, string, error) {
	cfg := s.store.GetServerSettings()
	if ov.APIBase != nil {
		cfg.DanmuAPIBase = db.NormalizeBaseURL(*ov.APIBase, "")
	}
	if ov.Token != nil && strings.TrimSpace(*ov.Token) != "" {
		cfg.DanmuToken = strings.TrimSpace(*ov.Token)
	}
	if ov.MetadataProxy != nil {
		cfg.MetadataProxy = strings.TrimSpace(*ov.MetadataProxy)
	}
	if strings.TrimSpace(cfg.DanmuAPIBase) == "" {
		return 0, "", fmt.Errorf("%w: danmu_api_base is not configured", ErrNotConfigured)
	}

	start := time.Now()
	res, err := s.searchAnimeUpstream(ctx, cfg, "三体")
	if err != nil {
		return 0, "", err
	}
	return time.Since(start).Milliseconds(), fmt.Sprintf("danmu_api 连通正常，返回 %d 条测试结果", len(res.Animes)), nil
}

func (s *Service) CacheStats() CacheStats {
	var st CacheStats
	if s.store == nil {
		return st
	}
	rdb := s.store.ReadDB()
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM danmaku_search_cache`).Scan(&st.Searches)
	_ = rdb.QueryRow(`SELECT COUNT(*) FROM danmaku_comment_cache`).Scan(&st.Comments)
	return st
}

func (s *Service) ClearCache(scope string) (int64, CacheStats, error) {
	if s.store == nil {
		return 0, CacheStats{}, nil
	}
	norm := strings.ToLower(strings.TrimSpace(scope))
	if norm == "" {
		norm = "all"
	}
	var tables []string
	switch norm {
	case "all":
		tables = []string{"danmaku_search_cache", "danmaku_comment_cache"}
	case "search":
		tables = []string{"danmaku_search_cache"}
	case "comments", "comment":
		tables = []string{"danmaku_comment_cache"}
	default:
		return 0, CacheStats{}, fmt.Errorf("%w: unknown danmaku cache scope %q", ErrInvalidInput, scope)
	}
	var deleted int64
	for _, tbl := range tables {
		res, err := s.store.DB().Exec(`DELETE FROM ` + tbl)
		if err != nil {
			return deleted, CacheStats{}, err
		}
		n, _ := res.RowsAffected()
		deleted += n
	}
	applog.Infof("danmaku", "已清理弹幕缓存 scope=%s 删除=%d 条", norm, deleted)
	return deleted, s.CacheStats(), nil
}

func (s *Service) CleanupExpiredCache() error {
	if s.store == nil {
		return nil
	}
	now := s.nowFn()
	if _, err := s.store.DB().Exec(`DELETE FROM danmaku_search_cache WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	if _, err := s.store.DB().Exec(`DELETE FROM danmaku_comment_cache WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	return nil
}

func hashKey(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func (s *Service) loadSearchCache(key string, dst any) (any, bool) {
	if s.store == nil {
		return nil, false
	}
	var payload string
	var exp int64
	err := s.store.ReadDB().QueryRow(
		`SELECT payload_json, expires_at FROM danmaku_search_cache WHERE cache_key = ?`,
		key,
	).Scan(&payload, &exp)
	if err != nil || exp <= s.nowFn() {
		return nil, false
	}
	if err := json.Unmarshal([]byte(payload), dst); err != nil {
		return nil, false
	}
	return dst, true
}

func (s *Service) saveSearchCache(key string, payload any, ttlMs int64) {
	if s.store == nil || ttlMs <= 0 {
		return
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	now := s.nowFn()
	_, _ = s.store.DB().Exec(
		`INSERT OR REPLACE INTO danmaku_search_cache(cache_key, payload_json, fetched_at, expires_at) VALUES (?, ?, ?, ?)`,
		key, string(raw), now, now+ttlMs,
	)
}

func (s *Service) loadCommentCache(key string) (CommentsResult, bool) {
	if s.store == nil {
		return CommentsResult{}, false
	}
	var payload string
	var exp int64
	err := s.store.ReadDB().QueryRow(
		`SELECT payload_json, expires_at FROM danmaku_comment_cache WHERE cache_key = ?`,
		key,
	).Scan(&payload, &exp)
	if errors.Is(err, sql.ErrNoRows) || err != nil || exp <= s.nowFn() {
		return CommentsResult{}, false
	}
	var out CommentsResult
	if err := json.Unmarshal([]byte(payload), &out); err != nil {
		return CommentsResult{}, false
	}
	return out, true
}

func (s *Service) saveCommentCache(key string, res CommentsResult, ttlMs int64) {
	if s.store == nil || ttlMs <= 0 {
		return
	}
	raw, err := json.Marshal(res)
	if err != nil {
		return
	}
	now := s.nowFn()
	_, _ = s.store.DB().Exec(
		`INSERT OR REPLACE INTO danmaku_comment_cache(cache_key, episode_id, source_url, video_duration, comment_count, payload_json, fetched_at, expires_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		key, res.EpisodeID, res.SourceURL, res.VideoDuration, res.TotalCount, string(raw), now, now+ttlMs,
	)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return ""
}
