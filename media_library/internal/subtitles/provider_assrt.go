package subtitles

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"ttplay/media_library/internal/db"
)

type assrtSearchResp struct {
	Status int `json:"status"`
	Sub    struct {
		Subs []struct {
			ID          int    `json:"id"`
			NativeName  string `json:"native_name"`
			VideoName   string `json:"videoname"`
			Subtype     string `json:"subtype"`
			VoteScore   int    `json:"vote_score"`
			ReleaseSite string `json:"release_site"`
			Lang        struct {
				Desc     string          `json:"desc"`
				LangList map[string]bool `json:"langlist"`
			} `json:"lang"`
		} `json:"subs"`
	} `json:"sub"`
}

type assrtDetailResp struct {
	Status int `json:"status"`
	Sub    struct {
		Subs []struct {
			ID       int    `json:"id"`
			Filename string `json:"filename"`
			URL      string `json:"url"`
			FileList []struct {
				F   string `json:"f"`
				S   string `json:"s"`
				URL string `json:"url"`
			} `json:"filelist"`
		} `json:"subs"`
	} `json:"sub"`
}

type assrtDownloadPayload struct {
	SubID    int    `json:"id"`
	Title    string `json:"t"`
	Language string `json:"l"`
}

func buildAssrtQuery(req SearchRequest) string {
	if q := strings.TrimSpace(req.Query); q != "" {
		return q
	}
	base := strings.TrimSpace(req.Title)
	if base == "" {
		base = strings.TrimSpace(req.OriginalTitle)
	}
	if base == "" {
		base = strings.TrimSpace(req.FileName)
	}
	if base == "" {
		return ""
	}
	if req.Kind == "episode" && req.Season > 0 && req.Episode > 0 {
		return fmt.Sprintf("%s S%02dE%02d", base, req.Season, req.Episode)
	}
	if req.Year > 0 && req.Kind == "movie" {
		return fmt.Sprintf("%s %d", base, req.Year)
	}
	return base
}

func (s *Service) searchAssrt(ctx context.Context, cfg db.ServerSettings, req SearchRequest) ([]Candidate, error) {
	if strings.TrimSpace(cfg.AssrtToken) == "" {
		return nil, ErrNotConfigured
	}
	queryStr := buildAssrtQuery(req)
	if queryStr == "" {
		return nil, nil
	}

	u, err := url.Parse(strings.TrimRight(cfg.AssrtAPIBase, "/") + "/sub/search")
	if err != nil {
		return nil, fmt.Errorf("%w: invalid assrt url", ErrUpstream)
	}
	q := u.Query()
	q.Set("q", queryStr)
	q.Set("cnt", "15")
	q.Set("pos", "0")
	u.RawQuery = q.Encode()

	headers := map[string]string{
		"Authorization": "Bearer " + cfg.AssrtToken,
	}
	body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, headers, nil)
	if err != nil {
		return nil, err
	}
	if status == http.StatusTooManyRequests {
		return nil, ErrRateLimited
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return nil, fmt.Errorf("%w: assrt authentication failed (HTTP %d)", ErrUpstream, status)
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("%w: assrt returned HTTP %d", ErrUpstream, status)
	}

	var parsed assrtSearchResp
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("%w: invalid assrt JSON: %v", ErrUpstream, err)
	}
	if parsed.Status != 0 {
		if parsed.Status == 30900 || parsed.Status == 20900 {
			return nil, ErrRateLimited
		}
		return nil, fmt.Errorf("%w: assrt status %d", ErrUpstream, parsed.Status)
	}

	out := make([]Candidate, 0, len(parsed.Sub.Subs))
	for _, sub := range parsed.Sub.Subs {
		if sub.ID <= 0 {
			continue
		}
		title := firstNonEmpty(strings.TrimSpace(sub.NativeName), strings.TrimSpace(sub.VideoName))
		if title == "" {
			title = fmt.Sprintf("Assrt #%d", sub.ID)
		}
		format := NormalizeSubtitleFormat(sub.Subtype)
		if format == "" {
			// Assrt subtypes can look like "ASS/SSA" or "SRT"
			lowerSub := strings.ToLower(sub.Subtype)
			switch {
			case strings.Contains(lowerSub, "ass"):
				format = "ass"
			case strings.Contains(lowerSub, "ssa"):
				format = "ssa"
			case strings.Contains(lowerSub, "vtt"):
				format = "vtt"
			default:
				format = "srt"
			}
		}

		lang := "zh"
		if sub.Lang.LangList["langeng"] && !sub.Lang.LangList["langchs"] && !sub.Lang.LangList["langcht"] && !sub.Lang.LangList["langdou"] {
			lang = "en"
		}

		tok, tokErr := s.sealToken(ProviderAssrt, assrtDownloadPayload{
			SubID:    sub.ID,
			Title:    title,
			Language: lang,
		})
		if tokErr != nil {
			continue
		}

		score := float64(70 + sub.VoteScore)
		if format == "ass" {
			score += 15
		}
		if sub.Lang.LangList["langdou"] {
			score += 10
		}

		release := firstNonEmpty(strings.TrimSpace(sub.VideoName), strings.TrimSpace(sub.ReleaseSite))
		out = append(out, Candidate{
			ID:            strconv.Itoa(sub.ID),
			Provider:      ProviderAssrt,
			Title:         title,
			ReleaseName:   release,
			Language:      lang,
			Format:        format,
			Score:         score,
			DownloadToken: tok,
		})
	}
	return out, nil
}

func (s *Service) downloadAssrt(ctx context.Context, cfg db.ServerSettings, rawPayload json.RawMessage, req DownloadRequest) (DownloadedSubtitle, error) {
	if strings.TrimSpace(cfg.AssrtToken) == "" {
		return DownloadedSubtitle{}, ErrNotConfigured
	}
	var p assrtDownloadPayload
	if err := json.Unmarshal(rawPayload, &p); err != nil || p.SubID <= 0 {
		return DownloadedSubtitle{}, ErrInvalidToken
	}

	u, err := url.Parse(strings.TrimRight(cfg.AssrtAPIBase, "/") + "/sub/detail")
	if err != nil {
		return DownloadedSubtitle{}, fmt.Errorf("%w: invalid assrt url", ErrUpstream)
	}
	q := u.Query()
	q.Set("id", strconv.Itoa(p.SubID))
	u.RawQuery = q.Encode()

	headers := map[string]string{
		"Authorization": "Bearer " + cfg.AssrtToken,
	}
	detailBody, _, status, err := s.doRequestBytes(ctx, http.MethodGet, u.String(), cfg.MetadataProxy, headers, nil)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	if status == http.StatusTooManyRequests {
		return DownloadedSubtitle{}, ErrRateLimited
	}
	if status < 200 || status >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: assrt detail HTTP %d", ErrUpstream, status)
	}

	var parsed assrtDetailResp
	if err := json.Unmarshal(detailBody, &parsed); err != nil {
		return DownloadedSubtitle{}, fmt.Errorf("%w: invalid assrt detail JSON: %v", ErrUpstream, err)
	}
	if parsed.Status != 0 || len(parsed.Sub.Subs) == 0 {
		return DownloadedSubtitle{}, ErrNotFound
	}
	sub := parsed.Sub.Subs[0]

	normLang := firstNonEmpty(NormalizeLanguageCode(req.Language), p.Language, "zh")

	// Prefer direct single-file URLs from filelist so .rar/.7z archives need no external unpacker.
	type fileOption struct {
		name   string
		format string
		url    string
		score  int
	}
	var options []fileOption
	for _, f := range sub.FileList {
		fu := strings.TrimSpace(f.URL)
		if fu == "" {
			continue
		}
		fn := strings.TrimSpace(f.F)
		fmtExt := FormatFromFilename(fn)
		if fmtExt == "" {
			continue
		}
		options = append(options, fileOption{
			name:   fn,
			format: fmtExt,
			url:    fu,
			score:  scoreSubtitleFilename(fn, fmtExt, req.Season, req.Episode, normLang),
		})
	}
	sort.SliceStable(options, func(i, j int) bool {
		return options[i].score > options[j].score
	})

	for _, opt := range options {
		if err := validateExternalHTTPURL(opt.url, s.allowLoopbackDownloads); err != nil {
			continue
		}
		raw, _, dlStatus, dlErr := s.doRequestBytes(ctx, http.MethodGet, opt.url, cfg.MetadataProxy, nil, nil)
		if dlErr != nil || dlStatus < 200 || dlStatus >= 300 || len(raw) == 0 {
			continue
		}
		utf8Text, decErr := DecodeSubtitleToUTF8(raw)
		if decErr != nil {
			continue
		}
		return DownloadedSubtitle{
			Provider: ProviderAssrt,
			Filename: opt.name,
			Format:   opt.format,
			Language: normLang,
			Content:  utf8Text,
		}, nil
	}

	// Fallback to the main archive URL if filelist gave no usable direct download.
	archiveURL := strings.TrimSpace(sub.URL)
	if archiveURL == "" {
		return DownloadedSubtitle{}, ErrNotFound
	}
	if err := validateExternalHTTPURL(archiveURL, s.allowLoopbackDownloads); err != nil {
		return DownloadedSubtitle{}, err
	}
	rawArchive, _, dlStatus, dlErr := s.doRequestBytes(ctx, http.MethodGet, archiveURL, cfg.MetadataProxy, nil, nil)
	if dlErr != nil {
		return DownloadedSubtitle{}, dlErr
	}
	if dlStatus < 200 || dlStatus >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: assrt download HTTP %d", ErrUpstream, dlStatus)
	}

	filename := strings.TrimSpace(sub.Filename)
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
		filename = fmt.Sprintf("assrt_%d.%s", p.SubID, format)
	}
	utf8Text, err := DecodeSubtitleToUTF8(rawData)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	return DownloadedSubtitle{
		Provider: ProviderAssrt,
		Filename: filename,
		Format:   format,
		Language: normLang,
		Content:  utf8Text,
	}, nil
}
