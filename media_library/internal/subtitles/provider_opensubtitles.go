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

type openSubSearchResp struct {
	Data []struct {
		ID         string `json:"id"`
		Attributes struct {
			Language         string  `json:"language"`
			DownloadCount    int     `json:"download_count"`
			HearingImpaired  bool    `json:"hearing_impaired"`
			ForeignPartsOnly bool    `json:"foreign_parts_only"`
			Ratings          float64 `json:"ratings"`
			FromTrusted      bool    `json:"from_trusted"`
			Release          string  `json:"release"`
			Files            []struct {
				FileID   int    `json:"file_id"`
				FileName string `json:"file_name"`
			} `json:"files"`
		} `json:"attributes"`
	} `json:"data"`
}

type openSubDownloadResp struct {
	Link     string `json:"link"`
	FileName string `json:"file_name"`
}

type openSubDownloadPayload struct {
	FileID   int    `json:"fid"`
	Filename string `json:"f"`
	Language string `json:"l"`
}

func mapLanguageToOpenSubtitles(lang string) string {
	switch NormalizeLanguageCode(lang) {
	case "":
		return ""
	case "zh":
		return "zh-cn,zh-tw"
	default:
		return NormalizeLanguageCode(lang)
	}
}

func (s *Service) searchOpenSubtitles(ctx context.Context, cfg db.ServerSettings, req SearchRequest) ([]Candidate, error) {
	if strings.TrimSpace(cfg.OpenSubtitlesAPIKey) == "" {
		return nil, ErrNotConfigured
	}

	u, err := url.Parse(strings.TrimRight(cfg.OpenSubtitlesAPIBase, "/") + "/subtitles")
	if err != nil {
		return nil, fmt.Errorf("%w: invalid opensubtitles url", ErrUpstream)
	}
	q := u.Query()
	if langParam := mapLanguageToOpenSubtitles(req.Language); langParam != "" {
		q.Set("languages", langParam)
	}

	hasID := false
	imdbDigits := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(req.ImdbID)), "tt")
	tmdbStr := strings.TrimSpace(req.TmdbID)

	if req.Kind == "episode" {
		if imdbDigits != "" {
			q.Set("parent_imdb_id", imdbDigits)
			hasID = true
		} else if tmdbStr != "" {
			q.Set("parent_tmdb_id", tmdbStr)
			hasID = true
		}
		if req.Season > 0 {
			q.Set("season_number", strconv.Itoa(req.Season))
		}
		if req.Episode > 0 {
			q.Set("episode_number", strconv.Itoa(req.Episode))
		}
		q.Set("type", "episode")
	} else {
		if imdbDigits != "" {
			q.Set("imdb_id", imdbDigits)
			hasID = true
		} else if tmdbStr != "" {
			q.Set("tmdb_id", tmdbStr)
			hasID = true
		}
		if req.Kind == "movie" {
			q.Set("type", "movie")
		}
	}

	if manual := strings.TrimSpace(req.Query); manual != "" {
		q.Set("query", manual)
	} else if !hasID {
		kw := firstNonEmpty(strings.TrimSpace(req.OriginalTitle), strings.TrimSpace(req.Title), strings.TrimSpace(req.FileName))
		if kw == "" {
			return nil, nil
		}
		q.Set("query", kw)
		if req.Year > 0 {
			q.Set("year", strconv.Itoa(req.Year))
		}
	}

	u.RawQuery = q.Encode()
	headers := map[string]string{
		"Api-Key":    cfg.OpenSubtitlesAPIKey,
		"User-Agent": "TTPlay v1.0",
		"Accept":     "application/json",
	}
	body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, headers, nil)
	if err != nil {
		return nil, err
	}
	if status == http.StatusTooManyRequests {
		return nil, ErrRateLimited
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return nil, fmt.Errorf("%w: opensubtitles authentication failed (HTTP %d)", ErrUpstream, status)
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("%w: opensubtitles returned HTTP %d", ErrUpstream, status)
	}

	var parsed openSubSearchResp
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("%w: invalid opensubtitles JSON: %v", ErrUpstream, err)
	}

	out := make([]Candidate, 0, len(parsed.Data))
	for _, row := range parsed.Data {
		if len(row.Attributes.Files) == 0 || row.Attributes.Files[0].FileID <= 0 {
			continue
		}
		f := row.Attributes.Files[0]
		title := firstNonEmpty(strings.TrimSpace(row.Attributes.Release), strings.TrimSpace(f.FileName), fmt.Sprintf("OpenSubtitles #%s", row.ID))
		format := FormatFromFilename(f.FileName)
		if format == "" {
			format = "srt"
		}
		lang := firstNonEmpty(NormalizeLanguageCode(row.Attributes.Language), NormalizeLanguageCode(req.Language), "en")

		tok, tokErr := s.sealToken(ProviderOpenSubtitles, openSubDownloadPayload{
			FileID:   f.FileID,
			Filename: firstNonEmpty(strings.TrimSpace(f.FileName), title+"."+format),
			Language: lang,
		})
		if tokErr != nil {
			continue
		}

		score := 65.0 + row.Attributes.Ratings*2
		if row.Attributes.FromTrusted {
			score += 10
		}
		if hasID {
			score += 10
		}

		out = append(out, Candidate{
			ID:              strconv.Itoa(f.FileID),
			Provider:        ProviderOpenSubtitles,
			Title:           title,
			ReleaseName:     strings.TrimSpace(f.FileName),
			Language:        lang,
			Format:          format,
			HearingImpaired: row.Attributes.HearingImpaired,
			Forced:          row.Attributes.ForeignPartsOnly,
			PerfectMatch:    hasID && row.Attributes.FromTrusted,
			Score:           score,
			Downloads:       row.Attributes.DownloadCount,
			DownloadToken:   tok,
		})
		if len(out) >= 20 {
			break
		}
	}
	return out, nil
}

func (s *Service) downloadOpenSubtitles(ctx context.Context, cfg db.ServerSettings, rawPayload json.RawMessage, req DownloadRequest) (DownloadedSubtitle, error) {
	if strings.TrimSpace(cfg.OpenSubtitlesAPIKey) == "" {
		return DownloadedSubtitle{}, ErrNotConfigured
	}
	var p openSubDownloadPayload
	if err := json.Unmarshal(rawPayload, &p); err != nil || p.FileID <= 0 {
		return DownloadedSubtitle{}, ErrInvalidToken
	}

	dlEndpoint := strings.TrimRight(cfg.OpenSubtitlesAPIBase, "/") + "/download"
	headers := map[string]string{
		"Api-Key":    cfg.OpenSubtitlesAPIKey,
		"User-Agent": "TTPlay v1.0",
		"Accept":     "application/json",
	}
	respBody, _, status, err := s.doRequestBytes(
		ctx,
		http.MethodPost,
		dlEndpoint,
		cfg.MetadataProxy,
		headers,
		map[string]any{"file_id": p.FileID},
	)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	if status == http.StatusTooManyRequests || status == http.StatusNotAcceptable {
		return DownloadedSubtitle{}, ErrRateLimited
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return DownloadedSubtitle{}, fmt.Errorf("%w: opensubtitles download auth failed (HTTP %d)", ErrUpstream, status)
	}
	if status < 200 || status >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: opensubtitles download HTTP %d", ErrUpstream, status)
	}

	var parsed openSubDownloadResp
	if err := json.Unmarshal(respBody, &parsed); err != nil || strings.TrimSpace(parsed.Link) == "" {
		return DownloadedSubtitle{}, fmt.Errorf("%w: missing opensubtitles download link", ErrUpstream)
	}
	if err := validateExternalHTTPURL(parsed.Link, s.allowLoopbackDownloads); err != nil {
		return DownloadedSubtitle{}, err
	}

	fileBytes, _, dlStatus, dlErr := s.doRequestBytes(ctx, http.MethodGet, parsed.Link, cfg.MetadataProxy, nil, nil)
	if dlErr != nil {
		return DownloadedSubtitle{}, dlErr
	}
	if dlStatus < 200 || dlStatus >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: opensubtitles file fetch HTTP %d", ErrUpstream, dlStatus)
	}

	filename := firstNonEmpty(strings.TrimSpace(parsed.FileName), strings.TrimSpace(p.Filename))
	format := FormatFromFilename(filename)
	if format == "" {
		format = "srt"
	}
	if filename == "" {
		filename = fmt.Sprintf("opensubtitles_%d.%s", p.FileID, format)
	}

	utf8Text, err := DecodeSubtitleToUTF8(fileBytes)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	return DownloadedSubtitle{
		Provider: ProviderOpenSubtitles,
		Filename: filename,
		Format:   format,
		Language: firstNonEmpty(NormalizeLanguageCode(req.Language), p.Language, "en"),
		Content:  utf8Text,
	}, nil
}
