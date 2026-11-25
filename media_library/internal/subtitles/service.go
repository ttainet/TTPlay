package subtitles

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"ttplay/media_library/internal/applog"
	"ttplay/media_library/internal/db"
)

const (
	searchCacheTTLMs int64 = 6 * 60 * 60 * 1000
	fileCacheTTLMs   int64 = 30 * 24 * 60 * 60 * 1000
	providerTimeout        = 10 * time.Second
)

type Service struct {
	store                  *db.Store
	flight                 *sfGroup
	httpMu                 sync.Mutex
	httpClients            map[string]*http.Client
	hmacSecret             []byte
	nowFn                  func() int64
	subdlDownloadBase      string
	allowLoopbackDownloads bool
}

func NewService(store *db.Store) *Service {
	secret := loadOrGenerateTokenSecret(store)
	return &Service{
		store:       store,
		flight:      &sfGroup{},
		httpClients: make(map[string]*http.Client),
		hmacSecret:  secret,
		nowFn:       func() int64 { return time.Now().UnixMilli() },
	}
}

func loadOrGenerateTokenSecret(store *db.Store) []byte {
	if store != nil {
		raw := strings.TrimSpace(store.GetSetting("subtitle_token_hmac_secret", ""))
		if raw != "" {
			if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) >= 32 {
				return decoded
			}
		}
		buf := make([]byte, 32)
		if _, err := rand.Read(buf); err == nil {
			_ = store.SetSetting("subtitle_token_hmac_secret", hex.EncodeToString(buf))
			return buf
		}
	}
	buf := make([]byte, 32)
	_, _ = rand.Read(buf)
	return buf
}

func (s *Service) SetNowFunc(fn func() int64) {
	if fn != nil {
		s.nowFn = fn
	}
}

func (s *Service) EnabledProviders() []string {
	cfg := s.store.GetServerSettings()
	var out []string
	if cfg.XunleiSubEnabled {
		out = append(out, ProviderXunlei)
	}
	if cfg.AssrtEnabled && strings.TrimSpace(cfg.AssrtToken) != "" {
		out = append(out, ProviderAssrt)
	}
	if cfg.SubDLEnabled && strings.TrimSpace(cfg.SubDLAPIKey) != "" {
		out = append(out, ProviderSubDL)
	}
	if cfg.OpenSubtitlesEnabled && strings.TrimSpace(cfg.OpenSubtitlesAPIKey) != "" {
		out = append(out, ProviderOpenSubtitles)
	}
	return out
}

type signedTokenEnvelope struct {
	Provider string          `json:"p"`
	Payload  json.RawMessage `json:"d"`
}

func (s *Service) sealToken(provider string, payload any) (string, error) {
	rawPayload, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	envBytes, err := json.Marshal(signedTokenEnvelope{
		Provider: provider,
		Payload:  rawPayload,
	})
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, s.hmacSecret)
	_, _ = mac.Write(envBytes)
	sig := mac.Sum(nil)
	return base64.RawURLEncoding.EncodeToString(envBytes) + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func (s *Service) openToken(token string) (string, json.RawMessage, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 2 {
		return "", nil, ErrInvalidToken
	}
	envBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", nil, ErrInvalidToken
	}
	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", nil, ErrInvalidToken
	}
	mac := hmac.New(sha256.New, s.hmacSecret)
	_, _ = mac.Write(envBytes)
	if !hmac.Equal(sigBytes, mac.Sum(nil)) {
		return "", nil, ErrInvalidToken
	}
	var env signedTokenEnvelope
	if err := json.Unmarshal(envBytes, &env); err != nil || env.Provider == "" {
		return "", nil, ErrInvalidToken
	}
	return env.Provider, env.Payload, nil
}

func (s *Service) Search(ctx context.Context, req SearchRequest) (SearchResult, error) {
	req.Language = NormalizeLanguageCode(req.Language)
	req.Provider = NormalizeProviderName(req.Provider)
	req.Kind = strings.ToLower(strings.TrimSpace(req.Kind))

	enabled := s.EnabledProviders()
	if len(enabled) == 0 {
		return SearchResult{
			Candidates:       []Candidate{},
			EnabledProviders: []string{},
		}, nil
	}

	targets := selectTargetProviders(enabled, req)
	if len(targets) == 0 {
		return SearchResult{
			Candidates:       []Candidate{},
			EnabledProviders: enabled,
		}, nil
	}

	cacheKey := buildSearchCacheKey(req, targets)
	if cached, ok := s.loadSearchCache(cacheKey); ok {
		cached.EnabledProviders = enabled
		cached.Cached = true
		return cached, nil
	}

	cfg := s.store.GetServerSettings()

	type provOut struct {
		provider string
		items    []Candidate
		err      error
	}

	ch := make(chan provOut, len(targets))
	var wg sync.WaitGroup
	for _, prov := range targets {
		wg.Add(1)
		go func(p string) {
			defer wg.Done()
			pCtx, cancel := context.WithTimeout(ctx, providerTimeout)
			defer cancel()

			var (
				items []Candidate
				err   error
			)
			switch p {
			case ProviderXunlei:
				items, err = s.searchXunlei(pCtx, cfg, req)
			case ProviderAssrt:
				items, err = s.searchAssrt(pCtx, cfg, req)
			case ProviderSubDL:
				items, err = s.searchSubDL(pCtx, cfg, req)
			case ProviderOpenSubtitles:
				items, err = s.searchOpenSubtitles(pCtx, cfg, req)
			}
			ch <- provOut{provider: p, items: items, err: err}
		}(prov)
	}
	wg.Wait()
	close(ch)

	var all []Candidate
	var warnings []ProviderWarning
	successCount := 0
	var lastErr error

	for res := range ch {
		if res.err != nil {
			lastErr = res.err
			applog.Warnf("subtitles", "字幕源搜索失败 provider=%s: %v", res.provider, res.err)
			warnings = append(warnings, ProviderWarning{
				Provider: res.provider,
				Message:  res.err.Error(),
			})
			continue
		}
		successCount++
		all = append(all, res.items...)
	}

	if successCount == 0 && lastErr != nil {
		return SearchResult{
			Candidates:       []Candidate{},
			EnabledProviders: enabled,
			Warnings:         warnings,
		}, lastErr
	}

	sortCandidates(all, req)
	if all == nil {
		all = []Candidate{}
	}

	out := SearchResult{
		Candidates:       all,
		EnabledProviders: enabled,
		Warnings:         warnings,
	}
	s.saveSearchCache(cacheKey, out)
	return out, nil
}

func selectTargetProviders(enabled []string, req SearchRequest) []string {
	enabledSet := make(map[string]bool, len(enabled))
	for _, p := range enabled {
		enabledSet[p] = true
	}

	if req.Provider != "" && req.Provider != "all" {
		if enabledSet[req.Provider] {
			return []string{req.Provider}
		}
		return nil
	}

	isZhOrAny := req.Language == "" || IsChineseLanguage(req.Language)
	var out []string
	for _, p := range enabled {
		if (p == ProviderXunlei || p == ProviderAssrt) && !isZhOrAny {
			continue
		}
		out = append(out, p)
	}
	return out
}

func sortCandidates(items []Candidate, req SearchRequest) {
	isZh := IsChineseLanguage(req.Language)
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if a.PerfectMatch != b.PerfectMatch {
			return a.PerfectMatch
		}
		scoreA := a.Score
		scoreB := b.Score
		if isZh {
			scoreA += chineseProviderBoost(a)
			scoreB += chineseProviderBoost(b)
		}
		if scoreA != scoreB {
			return scoreA > scoreB
		}
		return a.Downloads > b.Downloads
	})
}

func chineseProviderBoost(c Candidate) float64 {
	boost := 0.0
	if c.Provider == ProviderAssrt {
		boost += 12
	} else if c.Provider == ProviderXunlei {
		boost += 10
	}
	if c.Format == "ass" || c.Format == "ssa" {
		boost += 6
	}
	lower := strings.ToLower(c.Title + " " + c.ReleaseName)
	if strings.Contains(lower, "双语") || strings.Contains(lower, "简") || strings.Contains(lower, "chs") {
		boost += 8
	}
	return boost
}

func (s *Service) Download(ctx context.Context, req DownloadRequest) (DownloadedSubtitle, error) {
	provider, rawPayload, err := s.openToken(req.Token)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	if req.Provider != "" && NormalizeProviderName(req.Provider) != provider {
		return DownloadedSubtitle{}, ErrInvalidToken
	}

	req.Language = NormalizeLanguageCode(req.Language)
	cacheKey := buildFileCacheKey(provider, req.Token, req.Season, req.Episode, req.Language)
	if cached, ok := s.loadFileCache(cacheKey); ok {
		cached.Cached = true
		return cached, nil
	}

	val, err := s.flight.Do(cacheKey, func() (any, error) {
		if cached, ok := s.loadFileCache(cacheKey); ok {
			cached.Cached = true
			return cached, nil
		}
		cfg := s.store.GetServerSettings()
		var (
			res DownloadedSubtitle
			err error
		)
		switch provider {
		case ProviderXunlei:
			res, err = s.downloadXunlei(ctx, cfg, rawPayload, req)
		case ProviderAssrt:
			res, err = s.downloadAssrt(ctx, cfg, rawPayload, req)
		case ProviderSubDL:
			res, err = s.downloadSubDL(ctx, cfg, rawPayload, req)
		case ProviderOpenSubtitles:
			res, err = s.downloadOpenSubtitles(ctx, cfg, rawPayload, req)
		default:
			return DownloadedSubtitle{}, ErrInvalidToken
		}
		if err != nil {
			return DownloadedSubtitle{}, err
		}
		sum := sha256.Sum256([]byte(res.Content))
		res.SHA256 = hex.EncodeToString(sum[:])
		s.saveFileCache(cacheKey, res)
		return res, nil
	})
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	return val.(DownloadedSubtitle), nil
}

func (s *Service) TestProviderConnection(ctx context.Context, provider string, ov ProviderTestOverrides) (int64, string, error) {
	prov := NormalizeProviderName(provider)
	cfg := s.store.GetServerSettings()
	if ov.MetadataProxy != nil {
		cfg.MetadataProxy = strings.TrimSpace(*ov.MetadataProxy)
	}
	start := time.Now()

	switch prov {
	case ProviderXunlei:
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.XunleiSubAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultXunleiSubAPIBase)
		}
		cands, err := s.searchXunlei(ctx, cfg, SearchRequest{Query: "Inception", Language: "zh"})
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("迅雷字幕连通正常，返回 %d 条测试结果", len(cands)), nil

	case ProviderAssrt:
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.AssrtAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultAssrtAPIBase)
		}
		if ov.Token != nil && strings.TrimSpace(*ov.Token) != "" {
			cfg.AssrtToken = strings.TrimSpace(*ov.Token)
		}
		if strings.TrimSpace(cfg.AssrtToken) == "" {
			return 0, "", fmt.Errorf("%w: assrt token is not configured", ErrNotConfigured)
		}
		quotaURL := strings.TrimRight(cfg.AssrtAPIBase, "/") + "/user/quota"
		body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, quotaURL, cfg.MetadataProxy, map[string]string{
			"Authorization": "Bearer " + cfg.AssrtToken,
		}, nil)
		if err != nil {
			return 0, "", err
		}
		if status == http.StatusUnauthorized || status == http.StatusForbidden {
			return 0, "", fmt.Errorf("%w: assrt token invalid (HTTP %d)", ErrUpstream, status)
		}
		if status < 200 || status >= 300 {
			return 0, "", fmt.Errorf("%w: assrt returned HTTP %d", ErrUpstream, status)
		}
		var qr struct {
			Status int `json:"status"`
			User   struct {
				Quota int `json:"quota"`
			} `json:"user"`
		}
		if err := json.Unmarshal(body, &qr); err != nil || qr.Status != 0 {
			return 0, "", fmt.Errorf("%w: assrt quota check failed", ErrUpstream)
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("射手(伪) Assrt 连通正常（配额 %d/分钟）", qr.User.Quota), nil

	case ProviderSubDL:
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.SubDLAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultSubDLAPIBase)
		}
		if ov.APIKey != nil && strings.TrimSpace(*ov.APIKey) != "" {
			cfg.SubDLAPIKey = strings.TrimSpace(*ov.APIKey)
		}
		if strings.TrimSpace(cfg.SubDLAPIKey) == "" {
			return 0, "", fmt.Errorf("%w: subdl api key is not configured", ErrNotConfigured)
		}
		cands, err := s.searchSubDL(ctx, cfg, SearchRequest{Title: "Inception", Kind: "movie", Language: "en"})
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("SubDL 连通正常，返回 %d 条测试结果", len(cands)), nil

	case ProviderOpenSubtitles:
		if ov.APIBase != nil && strings.TrimSpace(*ov.APIBase) != "" {
			cfg.OpenSubtitlesAPIBase = db.NormalizeBaseURL(*ov.APIBase, db.DefaultOpenSubtitlesAPIBase)
		}
		if ov.APIKey != nil && strings.TrimSpace(*ov.APIKey) != "" {
			cfg.OpenSubtitlesAPIKey = strings.TrimSpace(*ov.APIKey)
		}
		if strings.TrimSpace(cfg.OpenSubtitlesAPIKey) == "" {
			return 0, "", fmt.Errorf("%w: opensubtitles api key is not configured", ErrNotConfigured)
		}
		cands, err := s.searchOpenSubtitles(ctx, cfg, SearchRequest{TmdbID: "27205", Kind: "movie", Language: "en"})
		if err != nil {
			return 0, "", err
		}
		return time.Since(start).Milliseconds(), fmt.Sprintf("OpenSubtitles 连通正常，返回 %d 条测试结果", len(cands)), nil

	default:
		return 0, "", fmt.Errorf("%w: unsupported subtitle provider %q", ErrInvalidInput, provider)
	}
}

func (s *Service) CleanupExpiredCache() error {
	if s.store == nil {
		return nil
	}
	now := s.nowFn()
	if _, err := s.store.DB().Exec(`DELETE FROM subtitle_search_cache WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	if _, err := s.store.DB().Exec(`DELETE FROM subtitle_file_cache WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	return nil
}

func buildSearchCacheKey(req SearchRequest, targets []string) string {
	keyObj := map[string]any{
		"targets": targets,
		"q":       strings.ToLower(strings.TrimSpace(req.Query)),
		"fn":      strings.ToLower(strings.TrimSpace(req.FileName)),
		"t":       strings.ToLower(strings.TrimSpace(req.Title)),
		"ot":      strings.ToLower(strings.TrimSpace(req.OriginalTitle)),
		"lang":    req.Language,
		"kind":    req.Kind,
		"imdb":    strings.ToLower(strings.TrimSpace(req.ImdbID)),
		"tmdb":    strings.TrimSpace(req.TmdbID),
		"year":    req.Year,
		"s":       req.Season,
		"e":       req.Episode,
	}
	raw, _ := json.Marshal(keyObj)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func buildFileCacheKey(provider, token string, season, episode int, lang string) string {
	raw := fmt.Sprintf("%s|%s|%d|%d|%s", provider, token, season, episode, lang)
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func (s *Service) loadSearchCache(key string) (SearchResult, bool) {
	if s.store == nil {
		return SearchResult{}, false
	}
	var payload string
	var exp int64
	err := s.store.ReadDB().QueryRow(
		`SELECT payload_json, expires_at FROM subtitle_search_cache WHERE cache_key = ?`,
		key,
	).Scan(&payload, &exp)
	if err != nil || exp <= s.nowFn() {
		return SearchResult{}, false
	}
	var out SearchResult
	if err := json.Unmarshal([]byte(payload), &out); err != nil {
		return SearchResult{}, false
	}
	return out, true
}

func (s *Service) saveSearchCache(key string, res SearchResult) {
	if s.store == nil {
		return
	}
	raw, err := json.Marshal(res)
	if err != nil {
		return
	}
	now := s.nowFn()
	_, _ = s.store.DB().Exec(
		`INSERT OR REPLACE INTO subtitle_search_cache(cache_key, payload_json, fetched_at, expires_at) VALUES (?, ?, ?, ?)`,
		key, string(raw), now, now+searchCacheTTLMs,
	)
}

func (s *Service) loadFileCache(key string) (DownloadedSubtitle, bool) {
	if s.store == nil {
		return DownloadedSubtitle{}, false
	}
	var out DownloadedSubtitle
	var exp int64
	err := s.store.ReadDB().QueryRow(
		`SELECT provider, filename, format, language, sha256, content_utf8, expires_at FROM subtitle_file_cache WHERE cache_key = ?`,
		key,
	).Scan(&out.Provider, &out.Filename, &out.Format, &out.Language, &out.SHA256, &out.Content, &exp)
	if errors.Is(err, sql.ErrNoRows) || err != nil || exp <= s.nowFn() {
		return DownloadedSubtitle{}, false
	}
	return out, true
}

func (s *Service) saveFileCache(key string, sub DownloadedSubtitle) {
	if s.store == nil {
		return
	}
	now := s.nowFn()
	_, _ = s.store.DB().Exec(
		`INSERT OR REPLACE INTO subtitle_file_cache(cache_key, provider, filename, format, language, sha256, content_utf8, fetched_at, expires_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		key, sub.Provider, sub.Filename, sub.Format, sub.Language, sub.SHA256, sub.Content, now, now+fileCacheTTLMs,
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
