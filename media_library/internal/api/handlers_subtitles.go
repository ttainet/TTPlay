package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"ttplay/media_library/internal/subtitles"
)

func (s *Server) handleSubtitlesConfig(w http.ResponseWriter, r *http.Request) {
	if s.Sub == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "subtitle service unavailable")
		return
	}
	cfg := s.Store.GetServerSettings()
	enabled := s.Sub.EnabledProviders()
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":                   0,
		"enabled_providers":      enabled,
		"xunlei_enabled":         cfg.XunleiSubEnabled,
		"assrt_configured":       cfg.AssrtEnabled && cfg.AssrtTokenSet,
		"subdl_configured":       cfg.SubDLEnabled && cfg.SubDLAPIKeySet,
		"opensubtitles_configured": cfg.OpenSubtitlesEnabled && cfg.OpenSubtitlesAPIKeySet,
	})
}

func (s *Server) handleSubtitlesSearch(w http.ResponseWriter, r *http.Request) {
	if s.Sub == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "subtitle service unavailable")
		return
	}
	q := r.URL.Query()
	year, _ := strconv.Atoi(strings.TrimSpace(q.Get("year")))
	season, _ := strconv.Atoi(strings.TrimSpace(q.Get("season")))
	episode, _ := strconv.Atoi(strings.TrimSpace(q.Get("episode")))

	req := subtitles.SearchRequest{
		Query:         strings.TrimSpace(q.Get("q")),
		FileName:      strings.TrimSpace(q.Get("file_name")),
		Title:         strings.TrimSpace(q.Get("title")),
		OriginalTitle: strings.TrimSpace(q.Get("original_title")),
		Language:      strings.TrimSpace(q.Get("language")),
		Kind:          strings.TrimSpace(q.Get("kind")),
		ImdbID:        strings.TrimSpace(q.Get("imdb_id")),
		TmdbID:        strings.TrimSpace(q.Get("tmdb_id")),
		Year:          year,
		Season:        season,
		Episode:       episode,
		Provider:      strings.TrimSpace(q.Get("provider")),
	}
	if req.Query == "" && req.FileName == "" && req.Title == "" && req.OriginalTitle == "" && req.ImdbID == "" && req.TmdbID == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "at least one subtitle search parameter is required")
		return
	}

	res, err := s.Sub.Search(r.Context(), req)
	if err != nil {
		writeSubtitleError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":              0,
		"candidates":        res.Candidates,
		"enabled_providers": res.EnabledProviders,
		"warnings":          res.Warnings,
		"cached":            res.Cached,
	})
}

func (s *Server) handleSubtitlesDownload(w http.ResponseWriter, r *http.Request) {
	if s.Sub == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "subtitle service unavailable")
		return
	}
	var req subtitles.DownloadRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	if strings.TrimSpace(req.Token) == "" {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "token is required")
		return
	}

	res, err := s.Sub.Download(r.Context(), req)
	if err != nil {
		writeSubtitleError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":     0,
		"provider": res.Provider,
		"filename": res.Filename,
		"format":   res.Format,
		"language": res.Language,
		"sha256":   res.SHA256,
		"content":  res.Content,
		"cached":   res.Cached,
	})
}

func writeSubtitleError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, subtitles.ErrInvalidInput), errors.Is(err, subtitles.ErrInvalidToken):
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", err.Error())
	case errors.Is(err, subtitles.ErrNotConfigured):
		writeErrCode(w, r, http.StatusPreconditionFailed, "not_configured", err.Error())
	case errors.Is(err, subtitles.ErrNotFound):
		writeErrCode(w, r, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, subtitles.ErrUnsupportedArchive):
		writeErrCode(w, r, http.StatusUnprocessableEntity, "unsupported_archive", err.Error())
	case errors.Is(err, subtitles.ErrRateLimited):
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", err.Error())
	case errors.Is(err, subtitles.ErrUpstream):
		writeErrCode(w, r, http.StatusBadGateway, "upstream_error", err.Error())
	default:
		writeErrCode(w, r, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
