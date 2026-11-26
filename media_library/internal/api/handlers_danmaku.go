package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"ttplay/media_library/internal/danmaku"
	"ttplay/media_library/internal/security"
)

func parseBoolQuery(r *http.Request, name string) bool {
	v := strings.TrimSpace(strings.ToLower(r.URL.Query().Get(name)))
	return v == "1" || v == "true" || v == "yes"
}

func (s *Server) handleDanmakuConfig(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	cfg := s.Danmu.GetConfig()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                0,
		"enabled":             cfg.Enabled,
		"configured":          cfg.Configured,
		"provider":            cfg.Provider,
		"preferred_platforms": cfg.PreferredPlatforms,
		"timeout_sec":         cfg.TimeoutSec,
		"search_cache_hours":  cfg.SearchCacheHours,
		"comment_cache_hours": cfg.CommentCacheHours,
		"max_comments":        cfg.MaxComments,
	})
}

func (s *Server) handleDanmakuMatch(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	var req danmaku.MatchRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if strings.TrimSpace(req.FileName) == "" &&
		strings.TrimSpace(req.Title) == "" &&
		strings.TrimSpace(req.OriginalTitle) == "" &&
		strings.TrimSpace(req.ShowTitle) == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "file_name or title is required")
		return
	}
	refresh := req.Refresh || parseBoolQuery(r, "refresh")
	res, err := s.Danmu.Match(r.Context(), req, refresh)
	if err != nil {
		writeDanmakuError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"matched":    res.Matched,
		"matches":    res.Matches,
		"query_used": res.QueryUsed,
		"cached":     res.Cached,
	})
}

func (s *Server) handleDanmakuSearch(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	q := r.URL.Query()
	keyword := firstNonEmpty(q.Get("keyword"), q.Get("q"))
	if keyword == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "keyword is required")
		return
	}
	res, err := s.Danmu.SearchAnime(r.Context(), keyword, parseBoolQuery(r, "refresh"))
	if err != nil {
		writeDanmakuError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":   0,
		"animes": res.Animes,
		"cached": res.Cached,
	})
}

func (s *Server) handleDanmakuBangumi(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "anime id is required")
		return
	}
	res, err := s.Danmu.GetBangumi(r.Context(), id, parseBoolQuery(r, "refresh"))
	if err != nil {
		writeDanmakuError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"bangumi": res,
		"cached":  res.Cached,
	})
}

func (s *Server) handleDanmakuComments(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	q := r.URL.Query()
	episodeID := strings.TrimSpace(q.Get("episode_id"))
	sourceURL := strings.TrimSpace(q.Get("url"))
	if episodeID == "" && sourceURL == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "episode_id or url is required")
		return
	}
	limit, _ := strconv.Atoi(strings.TrimSpace(q.Get("limit")))
	if limit < 0 {
		limit = 0
	}
	res, err := s.Danmu.GetComments(r.Context(), episodeID, sourceURL, limit, parseBoolQuery(r, "refresh"))
	if err != nil {
		writeDanmakuError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":           0,
		"episode_id":     res.EpisodeID,
		"source_url":     res.SourceURL,
		"count":          res.Count,
		"total_count":    res.TotalCount,
		"sampled":        res.Sampled,
		"video_duration": res.VideoDuration,
		"comments":       res.Comments,
		"cached":         res.Cached,
	})
}

func (s *Server) handleAdminDanmakuStats(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"stats": s.Danmu.CacheStats(),
	})
}

func (s *Server) handleAdminClearDanmakuCache(w http.ResponseWriter, r *http.Request) {
	if s.Danmu == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "danmu service unavailable")
		return
	}
	p := AdminPrincipalFromContext(r.Context())
	var req struct {
		Scope string `json:"scope"`
	}
	_ = decodeOptionalJSON(w, r, &req)
	deleted, stats, err := s.Danmu.ClearCache(req.Scope)
	if err != nil {
		writeDanmakuError(w, r, err)
		return
	}
	_ = security.WriteAudit(s.Store, security.AuditEntry{
		ActorType:  "admin",
		ActorID:    p.AdminID,
		Action:     "admin.danmaku_cache_cleared",
		TargetType: "danmaku_cache",
		TargetID:   firstNonEmpty(strings.TrimSpace(req.Scope), "all"),
		Detail:     map[string]any{"deleted": deleted},
		IP:         s.clientIP(r),
	})
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"deleted": deleted,
		"stats":   stats,
	})
}

func writeDanmakuError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, danmaku.ErrInvalidInput):
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", err.Error())
	case errors.Is(err, danmaku.ErrNotConfigured):
		writeErrCode(w, r, http.StatusPreconditionFailed, "not_configured", err.Error())
	case errors.Is(err, danmaku.ErrNotFound):
		writeErrCode(w, r, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, danmaku.ErrRateLimited):
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", err.Error())
	case errors.Is(err, danmaku.ErrUpstream):
		writeErrCode(w, r, http.StatusBadGateway, "upstream_error", err.Error())
	default:
		writeErrCode(w, r, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
