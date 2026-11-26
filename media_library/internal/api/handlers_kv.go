package api

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"ttplay/media_library/internal/userdata"
)

func (s *Server) handleListKV(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	q := r.URL.Query()
	sinceUpdatedAt, _ := strconv.ParseInt(strings.TrimSpace(q.Get("since_updated_at")), 10, 64)
	incRaw := strings.ToLower(strings.TrimSpace(q.Get("include_deleted")))
	includeDeleted := incRaw == "1" || incRaw == "true"

	items, err := s.UserData.ListKV(p, q.Get("namespace"), sinceUpdatedAt, includeDeleted)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"items": items,
	})
}

func (s *Server) handleUpsertKV(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	scope, _ := url.PathUnescape(r.PathValue("scope"))
	ns, _ := url.PathUnescape(r.PathValue("namespace"))
	key, _ := url.PathUnescape(r.PathValue("key"))

	var req userdata.UpsertKVRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeErrCode(w, r, http.StatusBadRequest, "invalid_input", "invalid JSON payload")
		return
	}
	entry, err := s.UserData.UpsertKV(p, scope, ns, key, req)
	if err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code":  0,
		"entry": entry,
	})
}

func (s *Server) handleDeleteKV(w http.ResponseWriter, r *http.Request) {
	if s.UserData == nil {
		writeErrCode(w, r, http.StatusServiceUnavailable, "unavailable", "userdata service unavailable")
		return
	}
	p := UserPrincipalFromContext(r.Context())
	scope, _ := url.PathUnescape(r.PathValue("scope"))
	ns, _ := url.PathUnescape(r.PathValue("namespace"))
	key, _ := url.PathUnescape(r.PathValue("key"))

	if err := s.UserData.DeleteKV(p, scope, ns, key); err != nil {
		writeMappedError(w, r, err)
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{
		"code": 0,
	})
}
