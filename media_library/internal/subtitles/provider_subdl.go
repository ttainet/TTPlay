package subtitles

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"ttplay/media_library/internal/db"
)

const defaultSubDLDownloadBase = "https://dl.subdl.com"

type subdlSearchResp struct {
	Status    bool `json:"status"`
	Subtitles []struct {
		ReleaseName string `json:"release_name"`
		Name        string `json:"name"`
		Lang        string `json:"lang"`
		Author      string `json:"author"`
		URL         string `json:"url"`
		HI          bool   `json:"hi"`
		Season      int    `json:"season"`
		Episode     int    `json:"episode"`
	} `json:"subtitles"`
	Error string `json:"error,omitempty"`
}

type subdlDownloadPayload struct {
	URL      string `json:"u"`
	Filename string `json:"f"`
	Language string `json:"l"`
}

func mapLanguageToSubDL(lang string) string {
	switch NormalizeLanguageCode(lang) {
	case "":
		return ""
	case "zh":
		return "ZH,ZH_BG"
	default:
		return strings.ToUpper(NormalizeLanguageCode(lang))
	}
}

func mapSubDLLangToISO(raw string) string {
	upper := strings.ToUpper(strings.TrimSpace(raw))
	if strings.HasPrefix(upper, "ZH") || strings.Contains(upper, "CHINESE") {
		return "zh"
	}
	return NormalizeLanguageCode(raw)
}

func (s *Service) searchSubDL(ctx context.Context, cfg db.ServerSettings, req SearchRequest) ([]Candidate, error) {
	if strings.TrimSpace(cfg.SubDLAPIKey) == "" {
		return nil, ErrNotConfigured
	}

	u, err := url.Parse(strings.TrimRight(cfg.SubDLAPIBase, "/") + "/subtitles")
	if err != nil {
		return nil, fmt.Errorf("%w: invalid subdl url", ErrUpstream)
	}
	q := u.Query()
	q.Set("api_key", cfg.SubDLAPIKey)
	q.Set("subs_per_page", "20")

	if langParam := mapLanguageToSubDL(req.Language); langParam != "" {
		q.Set("languages", langParam)
	}
	if req.Kind == "episode" {
		q.Set("type", "tv")
	} else if req.Kind == "movie" {
		q.Set("type", "movie")
	}

	hasID := false
	if imdb := strings.TrimSpace(req.ImdbID); imdb != "" {
		if !strings.HasPrefix(strings.ToLower(imdb), "tt") {
			imdb = "tt" + imdb
		}
		q.Set("imdb_id", imdb)
		hasID = true
	} else if tmdb := strings.TrimSpace(req.TmdbID); tmdb != "" {
		q.Set("tmdb_id", tmdb)
		hasID = true
	}

	manual := strings.TrimSpace(req.Query)
	if manual != "" {
		q.Set("film_name", manual)
	} else if !hasID {
		film := firstNonEmpty(strings.TrimSpace(req.OriginalTitle), strings.TrimSpace(req.Title))
		if film == "" {
			return nil, nil
		}
		q.Set("film_name", film)
		if req.Year > 0 {
			q.Set("year", strconv.Itoa(req.Year))
		}
	}

	if req.Season > 0 {
		q.Set("season_number", strconv.Itoa(req.Season))
	}
	if req.Episode > 0 {
		q.Set("episode_number", strconv.Itoa(req.Episode))
	}

	u.RawQuery = q.Encode()
	body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, nil, nil)
	if err != nil {
		return nil, err
	}
	if status == http.StatusTooManyRequests {
		return nil, ErrRateLimited
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return nil, fmt.Errorf("%w: subdl authentication failed (HTTP %d)", ErrUpstream, status)
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("%w: subdl returned HTTP %d", ErrUpstream, status)
	}

	var parsed subdlSearchResp
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("%w: invalid subdl JSON: %v", ErrUpstream, err)
	}
	if !parsed.Status {
		if parsed.Error != "" {
			return nil, fmt.Errorf("%w: subdl: %s", ErrUpstream, parsed.Error)
		}
		return nil, nil
	}

	dlBase := s.subdlDownloadBase
	if dlBase == "" {
		dlBase = defaultSubDLDownloadBase
	}
	dlBase = strings.TrimRight(dlBase, "/")

	out := make([]Candidate, 0, len(parsed.Subtitles))
	for i, item := range parsed.Subtitles {
		rawPath := strings.TrimSpace(item.URL)
		if rawPath == "" {
			continue
		}
		fullURL := rawPath
		if !strings.HasPrefix(strings.ToLower(rawPath), "http://") && !strings.HasPrefix(strings.ToLower(rawPath), "https://") {
			if !strings.HasPrefix(rawPath, "/") {
				rawPath = "/" + rawPath
			}
			fullURL = dlBase + rawPath
		}

		title := firstNonEmpty(strings.TrimSpace(item.ReleaseName), strings.TrimSpace(item.Name), fmt.Sprintf("SubDL #%d", i+1))
		format := FormatFromFilename(item.Name)
		if format == "" {
			format = FormatFromFilename(item.ReleaseName)
		}
		if format == "" {
			format = "srt"
		}
		lang := firstNonEmpty(mapSubDLLangToISO(item.Lang), NormalizeLanguageCode(req.Language), "en")

		tok, tokErr := s.sealToken(ProviderSubDL, subdlDownloadPayload{
			URL:      fullURL,
			Filename: title,
			Language: lang,
		})
		if tokErr != nil {
			continue
		}

		score := float64(75)
		if hasID {
			score += 10
		}
		if strings.EqualFold(item.Lang, "ZH_BG") {
			score += 8
		}

		out = append(out, Candidate{
			ID:              fmt.Sprintf("subdl-%d-%s", i, rawPath),
			Provider:        ProviderSubDL,
			Title:           title,
			ReleaseName:     firstNonEmpty(strings.TrimSpace(item.Name), strings.TrimSpace(item.Author)),
			Language:        lang,
			Format:          format,
			HearingImpaired: item.HI,
			PerfectMatch:    hasID && (req.Episode <= 0 || item.Episode == req.Episode),
			Score:           score,
			DownloadToken:   tok,
		})
	}
	return out, nil
}

func (s *Service) downloadSubDL(ctx context.Context, cfg db.ServerSettings, rawPayload json.RawMessage, req DownloadRequest) (DownloadedSubtitle, error) {
	var p subdlDownloadPayload
	if err := json.Unmarshal(rawPayload, &p); err != nil || strings.TrimSpace(p.URL) == "" {
		return DownloadedSubtitle{}, ErrInvalidToken
	}
	if err := validateExternalHTTPURL(p.URL, s.allowLoopbackDownloads); err != nil {
		return DownloadedSubtitle{}, err
	}

	rawArchive, _, status, err := s.doRequestBytes(ctx, http.MethodGet, p.URL, cfg.MetadataProxy, nil, nil)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	if status == http.StatusNotFound {
		return DownloadedSubtitle{}, ErrNotFound
	}
	if status == http.StatusTooManyRequests {
		return DownloadedSubtitle{}, ErrRateLimited
	}
	if status < 200 || status >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: subdl download HTTP %d", ErrUpstream, status)
	}

	normLang := firstNonEmpty(NormalizeLanguageCode(req.Language), p.Language, "en")
	filename := strings.TrimSpace(p.Filename)
	format := FormatFromFilename(filename)
	rawData := rawArchive

	if IsZipArchive(rawArchive) {
		name, fmtExt, extracted, zipErr := ExtractSubtitleFromZip(rawArchive, req.Season, req.Episode, normLang)
		if zipErr != nil {
			return DownloadedSubtitle{}, zipErr
		}
		filename = name
		format = fmtExt
		rawData = extracted
	} else if IsUnsupportedArchive(rawArchive) {
		return DownloadedSubtitle{}, ErrUnsupportedArchive
	}

	if format == "" {
		format = "srt"
	}
	if filename == "" {
		filename = "subdl." + format
	}

	utf8Text, err := DecodeSubtitleToUTF8(rawData)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	return DownloadedSubtitle{
		Provider: ProviderSubDL,
		Filename: filename,
		Format:   format,
		Language: normLang,
		Content:  utf8Text,
	}, nil
}
