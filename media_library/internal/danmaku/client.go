package danmaku

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"ttplay/media_library/internal/db"
)

const (
	maxUpstreamBodyBytes = 24 * 1024 * 1024
	httpClientTimeout    = 125 * time.Second
	defaultRequestSecs   = 30
	defaultUserAgent     = "TTPlay/1.0"
)

type sfCall struct {
	wg  sync.WaitGroup
	val any
	err error
}

type sfGroup struct {
	mu sync.Mutex
	m  map[string]*sfCall
}

func (g *sfGroup) Do(key string, fn func() (any, error)) (any, error) {
	g.mu.Lock()
	if g.m == nil {
		g.m = make(map[string]*sfCall)
	}
	if c, ok := g.m[key]; ok {
		g.mu.Unlock()
		c.wg.Wait()
		return c.val, c.err
	}
	c := &sfCall{}
	c.wg.Add(1)
	g.m[key] = c
	g.mu.Unlock()

	defer func() {
		g.mu.Lock()
		delete(g.m, key)
		g.mu.Unlock()
		c.wg.Done()
	}()

	c.val, c.err = fn()
	return c.val, c.err
}

func isLocalOrPrivateHost(rawURL string) bool {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return false
	}
	host := strings.ToLower(strings.TrimSpace(u.Hostname()))
	if host == "" {
		return false
	}
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || host == "127.0.0.1" || host == "::1" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
	}
	return false
}

func (s *Service) httpClientForTarget(rawURL, proxyRaw string) (*http.Client, error) {
	effectiveProxy := strings.TrimSpace(proxyRaw)
	if isLocalOrPrivateHost(rawURL) {
		effectiveProxy = ""
	}
	s.httpMu.Lock()
	defer s.httpMu.Unlock()
	if cli, ok := s.httpClients[effectiveProxy]; ok {
		return cli, nil
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if effectiveProxy == "" {
		tr.Proxy = nil
	} else {
		proxyURL, err := db.ParseProxyURL(effectiveProxy)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrUpstream, err)
		}
		tr.Proxy = http.ProxyURL(proxyURL)
	}
	cli := &http.Client{
		Timeout:   httpClientTimeout,
		Transport: tr,
	}
	s.httpClients[effectiveProxy] = cli
	return cli, nil
}

func (s *Service) doRequestJSON(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	timeoutSec int,
	reqBody any,
	dst any,
) error {
	if timeoutSec <= 0 {
		timeoutSec = defaultRequestSecs
	}
	reqCtx, cancel := context.WithTimeout(ctx, time.Duration(timeoutSec)*time.Second)
	defer cancel()

	cli, err := s.httpClientForTarget(rawURL, proxyRaw)
	if err != nil {
		return err
	}
	var bodyReader io.Reader
	if reqBody != nil {
		b, mErr := json.Marshal(reqBody)
		if mErr != nil {
			return mErr
		}
		bodyReader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(reqCtx, method, rawURL, bodyReader)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", defaultUserAgent)

	resp, err := cli.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxUpstreamBodyBytes+1))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if len(body) > maxUpstreamBodyBytes {
		return fmt.Errorf("%w: upstream payload exceeds limit", ErrUpstream)
	}

	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return fmt.Errorf("%w: danmu_api authentication failed (HTTP %d)", ErrUpstream, resp.StatusCode)
	case resp.StatusCode == http.StatusNotFound:
		return fmt.Errorf("%w: upstream returned HTTP 404", ErrNotFound)
	case resp.StatusCode == http.StatusTooManyRequests:
		return fmt.Errorf("%w: upstream returned HTTP 429", ErrRateLimited)
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return fmt.Errorf("%w: danmu_api returned HTTP %d", ErrUpstream, resp.StatusCode)
	}

	if dst != nil {
		if err := json.Unmarshal(body, dst); err != nil {
			return fmt.Errorf("%w: invalid upstream JSON: %v", ErrUpstream, err)
		}
	}
	return nil
}

// BuildUpstreamURL normalizes a user-configured danmu_api base URL, appends the
// optional path token without duplicating it or `/api/v2`, and attaches query params.
func BuildUpstreamURL(base, token, apiPath string, query url.Values) (string, error) {
	cleaned := strings.TrimSpace(base)
	if cleaned == "" {
		return "", fmt.Errorf("%w: danmu_api_base is empty", ErrNotConfigured)
	}
	cleaned = db.NormalizeBaseURL(cleaned, "")
	if cleaned == "" {
		return "", fmt.Errorf("%w: invalid danmu_api_base", ErrInvalidInput)
	}
	u, err := url.Parse(cleaned)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("%w: invalid danmu_api_base", ErrInvalidInput)
	}

	basePath := strings.TrimRight(u.Path, "/")
	if len(basePath) >= len("/api/v2") && strings.EqualFold(basePath[len(basePath)-len("/api/v2"):], "/api/v2") {
		basePath = strings.TrimRight(basePath[:len(basePath)-len("/api/v2")], "/")
	}

	tok := strings.Trim(strings.TrimSpace(token), "/")
	if tok != "" {
		suffix := "/" + tok
		if !strings.HasSuffix(basePath, suffix) {
			basePath += suffix
		}
	}

	sub := "/" + strings.TrimLeft(strings.TrimSpace(apiPath), "/")
	u.Path = basePath + "/api/v2" + sub
	u.RawPath = ""
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	} else {
		u.RawQuery = ""
	}
	return u.String(), nil
}

// BuildMatchFileName builds a query string suitable for POST /api/v2/match.
func BuildMatchFileName(req MatchRequest) string {
	base := strings.TrimSpace(req.FileName)
	if base == "" {
		title := firstNonEmpty(req.ShowTitle, req.Title, req.OriginalTitle)
		if title == "" {
			return ""
		}
		kind := strings.ToLower(strings.TrimSpace(req.Kind))
		if kind == "episode" || req.Episode > 0 {
			season := req.Season
			if season <= 0 && req.Episode > 0 {
				season = 1
			}
			if season > 0 && req.Episode > 0 {
				base = fmt.Sprintf("%s S%02dE%02d", title, season, req.Episode)
			} else if season > 0 {
				base = fmt.Sprintf("%s S%02d", title, season)
			} else {
				base = title
			}
		} else {
			if req.Year > 0 {
				base = fmt.Sprintf("%s (%d)", title, req.Year)
			} else {
				base = title
			}
		}
	}
	if base == "" {
		return ""
	}
	plat := strings.TrimLeft(strings.TrimSpace(req.Platform), "@")
	if plat != "" {
		base += " @" + plat
	}
	return base
}

// ParseCommentP decodes both 4-field dandanplay ("time,mode,color,uid") and
// 8-field Bilibili XML ("time,mode,fontsize,color,ts,pool,uid,cid") p attributes.
func ParseCommentP(p string) (timeSec float64, mode int, color int, userID string) {
	mode = 1
	color = 16777215

	parts := strings.Split(strings.TrimSpace(p), ",")
	if len(parts) > 0 {
		if v, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64); err == nil && v >= 0 {
			timeSec = v
		}
	}
	if len(parts) > 1 {
		if v, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil && v > 0 {
			mode = v
		}
	}

	// 8-field Bilibili format: [2] is font size (<= 100), [3] is RGB decimal color, [6] is user hash.
	if len(parts) >= 8 {
		p2, err2 := strconv.Atoi(strings.TrimSpace(parts[2]))
		p3, err3 := strconv.Atoi(strings.TrimSpace(parts[3]))
		if err2 == nil && err3 == nil && p2 > 0 && p2 <= 100 && p3 >= 0 {
			color = p3
			userID = strings.TrimSpace(parts[6])
			return timeSec, mode, color, userID
		}
	}

	if len(parts) > 2 {
		if v, err := strconv.Atoi(strings.TrimSpace(parts[2])); err == nil && v >= 0 {
			color = v
		}
	}
	if len(parts) > 3 {
		userID = strings.TrimSpace(parts[3])
	}
	return timeSec, mode, color, userID
}

type upstreamMatchResponse struct {
	IsMatched bool `json:"isMatched"`
	Matches   []struct {
		EpisodeID       FlexString `json:"episodeId"`
		AnimeID         FlexString `json:"animeId"`
		AnimeTitle      string     `json:"animeTitle"`
		EpisodeTitle    string     `json:"episodeTitle"`
		Type            string     `json:"type"`
		TypeDescription string     `json:"typeDescription"`
		Shift           float64    `json:"shift"`
		ImageURL        string     `json:"imageUrl"`
		URL             string     `json:"url"`
	} `json:"matches"`
}

func (s *Service) matchUpstream(ctx context.Context, cfg db.ServerSettings, fileName string) (MatchResult, error) {
	u, err := BuildUpstreamURL(cfg.DanmuAPIBase, cfg.DanmuToken, "/match", nil)
	if err != nil {
		return MatchResult{}, err
	}
	var raw upstreamMatchResponse
	if err := s.doRequestJSON(ctx, http.MethodPost, u, cfg.MetadataProxy, cfg.DanmuTimeoutSec, map[string]string{
		"fileName": fileName,
	}, &raw); err != nil {
		return MatchResult{}, err
	}
	matches := make([]MatchItem, 0, len(raw.Matches))
	for _, m := range raw.Matches {
		matches = append(matches, MatchItem{
			EpisodeID:       m.EpisodeID.String(),
			AnimeID:         m.AnimeID.String(),
			AnimeTitle:      strings.TrimSpace(m.AnimeTitle),
			EpisodeTitle:    strings.TrimSpace(m.EpisodeTitle),
			Type:            strings.TrimSpace(m.Type),
			TypeDescription: strings.TrimSpace(m.TypeDescription),
			Shift:           m.Shift,
			ImageURL:        strings.TrimSpace(m.ImageURL),
			SourceURL:       strings.TrimSpace(m.URL),
		})
	}
	return MatchResult{
		Matched:   raw.IsMatched || len(matches) > 0,
		Matches:   matches,
		QueryUsed: fileName,
	}, nil
}

type upstreamSearchResponse struct {
	Animes []struct {
		AnimeID         FlexString `json:"animeId"`
		AnimeTitle      string     `json:"animeTitle"`
		Type            string     `json:"type"`
		TypeDescription string     `json:"typeDescription"`
		ImageURL        string     `json:"imageUrl"`
		StartDate       string     `json:"startDate"`
		EpisodeCount    int        `json:"episodeCount"`
		Source          string     `json:"source"`
	} `json:"animes"`
}

func (s *Service) searchAnimeUpstream(ctx context.Context, cfg db.ServerSettings, keyword string) (SearchResult, error) {
	q := url.Values{}
	q.Set("keyword", keyword)
	u, err := BuildUpstreamURL(cfg.DanmuAPIBase, cfg.DanmuToken, "/search/anime", q)
	if err != nil {
		return SearchResult{}, err
	}
	var raw upstreamSearchResponse
	if err := s.doRequestJSON(ctx, http.MethodGet, u, cfg.MetadataProxy, cfg.DanmuTimeoutSec, nil, &raw); err != nil {
		return SearchResult{}, err
	}
	animes := make([]AnimeItem, 0, len(raw.Animes))
	for _, a := range raw.Animes {
		animes = append(animes, AnimeItem{
			AnimeID:         a.AnimeID.String(),
			AnimeTitle:      strings.TrimSpace(a.AnimeTitle),
			Type:            strings.TrimSpace(a.Type),
			TypeDescription: strings.TrimSpace(a.TypeDescription),
			ImageURL:        strings.TrimSpace(a.ImageURL),
			StartDate:       strings.TrimSpace(a.StartDate),
			EpisodeCount:    a.EpisodeCount,
			Source:          strings.TrimSpace(a.Source),
		})
	}
	return SearchResult{Animes: animes}, nil
}

type upstreamBangumiResponse struct {
	Bangumi *struct {
		AnimeID         FlexString `json:"animeId"`
		AnimeTitle      string     `json:"animeTitle"`
		Type            string     `json:"type"`
		TypeDescription string     `json:"typeDescription"`
		ImageURL        string     `json:"imageUrl"`
		Episodes        []struct {
			EpisodeID     FlexString `json:"episodeId"`
			EpisodeTitle  string     `json:"episodeTitle"`
			EpisodeNumber FlexString `json:"episodeNumber"`
			URL           string     `json:"url"`
		} `json:"episodes"`
	} `json:"bangumi"`
}

func (s *Service) getBangumiUpstream(ctx context.Context, cfg db.ServerSettings, animeID string) (BangumiDetail, error) {
	u, err := BuildUpstreamURL(cfg.DanmuAPIBase, cfg.DanmuToken, "/bangumi/"+url.PathEscape(strings.TrimSpace(animeID)), nil)
	if err != nil {
		return BangumiDetail{}, err
	}
	var raw upstreamBangumiResponse
	if err := s.doRequestJSON(ctx, http.MethodGet, u, cfg.MetadataProxy, cfg.DanmuTimeoutSec, nil, &raw); err != nil {
		return BangumiDetail{}, err
	}
	if raw.Bangumi == nil {
		return BangumiDetail{}, fmt.Errorf("%w: bangumi %s not found", ErrNotFound, animeID)
	}
	eps := make([]BangumiEpisode, 0, len(raw.Bangumi.Episodes))
	for _, ep := range raw.Bangumi.Episodes {
		eps = append(eps, BangumiEpisode{
			EpisodeID:     ep.EpisodeID.String(),
			EpisodeTitle:  strings.TrimSpace(ep.EpisodeTitle),
			EpisodeNumber: ep.EpisodeNumber.String(),
			SourceURL:     strings.TrimSpace(ep.URL),
		})
	}
	return BangumiDetail{
		AnimeID:         firstNonEmpty(raw.Bangumi.AnimeID.String(), animeID),
		AnimeTitle:      strings.TrimSpace(raw.Bangumi.AnimeTitle),
		Type:            strings.TrimSpace(raw.Bangumi.Type),
		TypeDescription: strings.TrimSpace(raw.Bangumi.TypeDescription),
		ImageURL:        strings.TrimSpace(raw.Bangumi.ImageURL),
		Episodes:        eps,
	}, nil
}

type upstreamCommentResponse struct {
	Count         int     `json:"count"`
	VideoDuration float64 `json:"videoDuration"`
	Comments      []struct {
		CID int64  `json:"cid"`
		P   string `json:"p"`
		M   string `json:"m"`
	} `json:"comments"`
}

func (s *Service) fetchCommentsByEpisodeID(ctx context.Context, cfg db.ServerSettings, episodeID string) (CommentsResult, error) {
	q := url.Values{}
	q.Set("format", "json")
	q.Set("duration", "true")
	u, err := BuildUpstreamURL(cfg.DanmuAPIBase, cfg.DanmuToken, "/comment/"+url.PathEscape(episodeID), q)
	if err != nil {
		return CommentsResult{}, err
	}
	var raw upstreamCommentResponse
	if err := s.doRequestJSON(ctx, http.MethodGet, u, cfg.MetadataProxy, cfg.DanmuTimeoutSec, nil, &raw); err != nil {
		return CommentsResult{}, err
	}
	return normalizeCommentResponse(episodeID, "", raw), nil
}

func (s *Service) fetchCommentsByURL(ctx context.Context, cfg db.ServerSettings, sourceURL, episodeID string) (CommentsResult, error) {
	q := url.Values{}
	q.Set("url", sourceURL)
	q.Set("format", "json")
	q.Set("duration", "true")
	u, err := BuildUpstreamURL(cfg.DanmuAPIBase, cfg.DanmuToken, "/comment", q)
	if err != nil {
		return CommentsResult{}, err
	}
	var raw upstreamCommentResponse
	if err := s.doRequestJSON(ctx, http.MethodGet, u, cfg.MetadataProxy, cfg.DanmuTimeoutSec, nil, &raw); err != nil {
		return CommentsResult{}, err
	}
	return normalizeCommentResponse(episodeID, sourceURL, raw), nil
}

func normalizeCommentResponse(episodeID, sourceURL string, raw upstreamCommentResponse) CommentsResult {
	comments := make([]DanmakuComment, 0, len(raw.Comments))
	for _, c := range raw.Comments {
		timeSec, mode, color, uid := ParseCommentP(c.P)
		comments = append(comments, DanmakuComment{
			CID:    c.CID,
			Time:   timeSec,
			Mode:   mode,
			Color:  color,
			Text:   c.M,
			UserID: uid,
			P:      c.P,
		})
	}
	count := len(comments)
	if raw.Count > count {
		count = raw.Count
	}
	return CommentsResult{
		EpisodeID:     episodeID,
		SourceURL:     sourceURL,
		Count:         count,
		TotalCount:    len(comments),
		VideoDuration: raw.VideoDuration,
		Comments:      comments,
	}
}

func normalizePlatformAlias(raw string) string {
	switch strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "@")) {
	case "tencent", "qq":
		return "qq"
	case "iqiyi", "qiyi":
		return "qiyi"
	case "mango", "imgo", "mgtv":
		return "imgo"
	case "bilibili", "bilibili1", "bili":
		return "bilibili"
	case "leshi", "le":
		return "leshi"
	case "dandan", "dandanplay":
		return "dandan"
	default:
		return strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "@"))
	}
}

func detectMatchPlatform(item MatchItem) string {
	if strings.HasPrefix(item.EpisodeTitle, "【") {
		if idx := strings.Index(item.EpisodeTitle, "】"); idx > len("【") {
			return normalizePlatformAlias(item.EpisodeTitle[len("【"):idx])
		}
	}
	lowerAnime := strings.ToLower(item.AnimeTitle)
	if idx := strings.LastIndex(lowerAnime, " from "); idx >= 0 {
		if norm := normalizePlatformAlias(lowerAnime[idx+len(" from "):]); norm != "" {
			return norm
		}
	}
	if item.SourceURL != "" {
		if u, err := url.Parse(item.SourceURL); err == nil {
			h := strings.ToLower(u.Hostname())
			switch {
			case strings.Contains(h, "v.qq.com"):
				return "qq"
			case strings.Contains(h, "iqiyi.com"):
				return "qiyi"
			case strings.Contains(h, "bilibili.com"):
				return "bilibili"
			case strings.Contains(h, "youku.com"):
				return "youku"
			case strings.Contains(h, "mgtv.com"):
				return "imgo"
			case strings.Contains(h, "miguvideo.com"):
				return "migu"
			case strings.Contains(h, "sohu.com"):
				return "sohu"
			case strings.Contains(h, "le.com"):
				return "leshi"
			case strings.Contains(h, "ixigua.com"):
				return "xigua"
			case strings.Contains(h, "gamer.com.tw"):
				return "bahamut"
			}
		}
	}
	return ""
}

// ParsePlatformList splits a comma-separated platform list into normalized tokens.
func ParsePlatformList(csv string) []string {
	parts := strings.Split(csv, ",")
	out := make([]string, 0, len(parts))
	seen := make(map[string]bool, len(parts))
	for _, p := range parts {
		tok := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(p), "@"))
		if tok == "" || seen[tok] {
			continue
		}
		seen[tok] = true
		out = append(out, tok)
	}
	return out
}

// SortMatchesByPreferredPlatforms returns a copy of matches stably ordered
// according to the comma-separated preferred platform list.
func SortMatchesByPreferredPlatforms(matches []MatchItem, preferredCSV string) []MatchItem {
	out := append([]MatchItem(nil), matches...)
	prefs := ParsePlatformList(preferredCSV)
	if len(prefs) == 0 || len(out) <= 1 {
		return out
	}
	rank := make(map[string]int, len(prefs))
	for i, p := range prefs {
		norm := normalizePlatformAlias(p)
		if _, exists := rank[norm]; !exists {
			rank[norm] = i
		}
	}
	fallbackRank := len(prefs)
	sort.SliceStable(out, func(i, j int) bool {
		ri := fallbackRank
		if p := detectMatchPlatform(out[i]); p != "" {
			if r, ok := rank[p]; ok {
				ri = r
			}
		}
		rj := fallbackRank
		if p := detectMatchPlatform(out[j]); p != "" {
			if r, ok := rank[p]; ok {
				rj = r
			}
		}
		return ri < rj
	})
	return out
}

// SampleComments caps a comment list to maxCount by sorting by time and evenly
// sampling across the timeline so dense episodes keep balanced coverage.
func SampleComments(comments []DanmakuComment, maxCount int) ([]DanmakuComment, bool) {
	if maxCount <= 0 || len(comments) <= maxCount {
		return comments, false
	}
	sorted := append([]DanmakuComment(nil), comments...)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Time < sorted[j].Time
	})
	if maxCount == 1 {
		return sorted[:1], true
	}
	out := make([]DanmakuComment, 0, maxCount)
	last := len(sorted) - 1
	denom := maxCount - 1
	for i := 0; i < maxCount; i++ {
		idx := i * last / denom
		out = append(out, sorted[idx])
	}
	return out, true
}

func (s *Service) getCommentsUpstream(ctx context.Context, cfg db.ServerSettings, episodeID, sourceURL string) (CommentsResult, error) {
	ep := strings.TrimSpace(episodeID)
	src := strings.TrimSpace(sourceURL)
	if ep != "" {
		res, err := s.fetchCommentsByEpisodeID(ctx, cfg, ep)
		if err == nil && (len(res.Comments) > 0 || src == "") {
			res.SourceURL = src
			return res, nil
		}
		if src == "" {
			return CommentsResult{}, err
		}
		if err != nil && !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrUpstream) {
			return CommentsResult{}, err
		}
		fallback, fbErr := s.fetchCommentsByURL(ctx, cfg, src, ep)
		if fbErr == nil {
			return fallback, nil
		}
		if err != nil {
			return CommentsResult{}, err
		}
		return res, nil
	}
	return s.fetchCommentsByURL(ctx, cfg, src, "")
}
