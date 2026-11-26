package api

import (
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"ttplay/media_library/internal/applog"
	"ttplay/media_library/internal/clientlogs"
	"ttplay/media_library/internal/security"
)

const (
	clientLogUploadWindow   = 10 * time.Minute
	clientLogUploadMaxPerIP = 20
)

func (s *Server) checkClientLogUploadRate(ip string) bool {
	if ip == "" {
		ip = "unknown"
	}
	now := time.Now()
	s.logUploadRateMu.Lock()
	defer s.logUploadRateMu.Unlock()
	if s.logUploadRate == nil {
		s.logUploadRate = make(map[string]*ipRateBucket)
	}
	b, ok := s.logUploadRate[ip]
	if !ok || now.Sub(b.windowStart) >= clientLogUploadWindow {
		if len(s.logUploadRate) > 1024 {
			for k, v := range s.logUploadRate {
				if now.Sub(v.windowStart) >= 2*clientLogUploadWindow {
					delete(s.logUploadRate, k)
				}
			}
		}
		s.logUploadRate[ip] = &ipRateBucket{windowStart: now, count: 1}
		return true
	}
	b.count++
	return b.count <= clientLogUploadMaxPerIP
}

func readClientLogBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	limited := http.MaxBytesReader(w, r.Body, clientlogs.MaxPayloadBytes)
	if strings.EqualFold(strings.TrimSpace(r.Header.Get("Content-Encoding")), "gzip") {
		gz, err := gzip.NewReader(limited)
		if err != nil {
			return nil, err
		}
		defer gz.Close()
		raw, err := io.ReadAll(io.LimitReader(gz, clientlogs.MaxPayloadBytes+1))
		if err != nil {
			return nil, err
		}
		if len(raw) > clientlogs.MaxPayloadBytes {
			return nil, clientlogs.ErrPayloadTooLarge
		}
		return raw, nil
	}
	return io.ReadAll(limited)
}

func parseOptionalBoolHeader(raw string) *bool {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil
	}
	b, err := strconv.ParseBool(trimmed)
	if err != nil {
		return nil
	}
	return &b
}

func (s *Server) handleUploadClientLog(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	ip := s.clientIP(r)
	if !s.checkClientLogUploadRate(ip) {
		writeErrCode(w, r, http.StatusTooManyRequests, "rate_limited", "too many log uploads, please try again later")
		return
	}

	raw, err := readClientLogBody(w, r)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.Is(err, clientlogs.ErrPayloadTooLarge) || errors.As(err, &maxErr) {
			writeErrCode(w, r, http.StatusRequestEntityTooLarge, "payload_too_large", "diagnostic log payload exceeds maximum size")
			return
		}
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "failed to read diagnostic log payload")
		return
	}

	rec, err := s.ClientLogs.Create(clientlogs.UploadInput{
		Content:    string(raw),
		DeviceName: r.Header.Get("X-Client-Device"),
		Platform:   r.Header.Get("X-Client-Platform"),
		OSVersion:  r.Header.Get("X-Client-OS"),
		AppVersion: r.Header.Get("X-Client-Version"),
		IsTV:       parseOptionalBoolHeader(r.Header.Get("X-Client-Is-TV")),
		Source:     r.Header.Get("X-Client-Log-Source"),
		ClientIP:   ip,
	})
	if err != nil {
		if errors.Is(err, clientlogs.ErrPayloadTooLarge) {
			writeErrCode(w, r, http.StatusRequestEntityTooLarge, "payload_too_large", err.Error())
			return
		}
		writeMappedError(w, r, err)
		return
	}

	applog.Infof("clientlogs", "uploaded id=%s device=%q platform=%s tv=%v bytes=%d ip=%s", rec.ID, rec.DeviceName, rec.Platform, rec.IsTV, rec.SizeBytes, ip)

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":       0,
		"id":         rec.ID,
		"created_at": rec.CreatedAt,
	})
}

func (s *Server) handleAdminListClientLogs(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(strings.TrimSpace(q.Get("limit")))
	offset, _ := strconv.Atoi(strings.TrimSpace(q.Get("offset")))

	var isTVPtr *bool
	if rawTV := strings.TrimSpace(q.Get("is_tv")); rawTV != "" {
		if b, err := strconv.ParseBool(rawTV); err == nil {
			isTVPtr = &b
		}
	}

	var tzOffsetPtr *int
	if rawTZ := strings.TrimSpace(q.Get("tz_offset")); rawTZ != "" {
		if v, err := strconv.Atoi(rawTZ); err == nil {
			tzOffsetPtr = &v
		}
	}

	res, err := s.ClientLogs.List(clientlogs.ListFilter{
		Device:      q.Get("device"),
		Platform:    q.Get("platform"),
		IsTV:        isTVPtr,
		DateFrom:    q.Get("date_from"),
		DateTo:      q.Get("date_to"),
		TZOffsetMin: tzOffsetPtr,
		Keyword:     q.Get("q"),
		Limit:       limit,
		Offset:      offset,
	})
	if err != nil {
		writeMappedError(w, r, err)
		return
	}

	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":             0,
		"items":            res.Items,
		"total":            res.Total,
		"total_size_bytes": res.TotalSizeBytes,
		"devices":          res.Devices,
		"platforms":        res.Platforms,
	})
}

func (s *Server) handleAdminGetClientLog(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	rec, err := s.ClientLogs.Get(r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
		"log":  rec,
	})
}

func (s *Server) handleAdminDownloadClientLog(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	rec, err := s.ClientLogs.Get(r.PathValue("id"))
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	filename := fmt.Sprintf("ttplay-log-%s-%s.log", rec.ID, rec.CreatedDate)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, rec.Content)
}

func (s *Server) handleAdminDeleteClientLog(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	id := strings.TrimSpace(r.PathValue("id"))
	if err := s.ClientLogs.Delete(id); err != nil {
		writeMappedError(w, r, err)
		return
	}
	if p := AdminPrincipalFromContext(r.Context()); p != nil {
		_ = security.WriteAudit(s.Store, security.AuditEntry{
			ActorType:  "admin",
			ActorID:    p.AdminID,
			Action:     "admin.client_log_deleted",
			TargetType: "client_log",
			TargetID:   id,
			IP:         s.clientIP(r),
		})
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"code": 0, "ok": true})
}

func (s *Server) handleAdminPruneClientLogs(w http.ResponseWriter, r *http.Request) {
	if s.ClientLogs == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "client log service unavailable")
		return
	}
	var req struct {
		OlderThanDays int    `json:"older_than_days"`
		Device        string `json:"device"`
		All           bool   `json:"all"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON request body")
		return
	}
	deleted, err := s.ClientLogs.Prune(req.OlderThanDays, req.Device, req.All)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	if p := AdminPrincipalFromContext(r.Context()); p != nil {
		_ = security.WriteAudit(s.Store, security.AuditEntry{
			ActorType:  "admin",
			ActorID:    p.AdminID,
			Action:     "admin.client_logs_pruned",
			TargetType: "client_log",
			TargetID:   firstNonEmpty(strings.TrimSpace(req.Device), "batch"),
			Detail: map[string]any{
				"older_than_days": req.OlderThanDays,
				"device":          strings.TrimSpace(req.Device),
				"all":             req.All,
				"deleted":         deleted,
			},
			IP: s.clientIP(r),
		})
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":    0,
		"deleted": deleted,
	})
}
