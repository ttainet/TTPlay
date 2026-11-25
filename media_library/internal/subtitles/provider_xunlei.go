package subtitles

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"strings"

	"ttplay/media_library/internal/db"
)

type xunleiSearchResp struct {
	Code int `json:"code"`
	Data []struct {
		CID  string `json:"cid"`
		GCID string `json:"gcid"`
		URL  string `json:"url"`
		Ext  string `json:"ext"`
		Name string `json:"name"`
	} `json:"data"`
}

type xunleiDownloadPayload struct {
	URL      string `json:"u"`
	Filename string `json:"f"`
	Format   string `json:"e"`
}

func buildXunleiKeyword(req SearchRequest) string {
	if q := strings.TrimSpace(req.Query); q != "" {
		return q
	}
	if fn := strings.TrimSpace(req.FileName); fn != "" {
		return fn
	}
	base := strings.TrimSpace(req.Title)
	if base == "" {
		base = strings.TrimSpace(req.OriginalTitle)
	}
	if base == "" {
		return ""
	}
	if req.Kind == "episode" && req.Season > 0 && req.Episode > 0 {
		return fmt.Sprintf("%s S%02dE%02d", base, req.Season, req.Episode)
	}
	return base
}

func (s *Service) searchXunlei(ctx context.Context, cfg db.ServerSettings, req SearchRequest) ([]Candidate, error) {
	keyword := buildXunleiKeyword(req)
	if keyword == "" {
		return nil, nil
	}

	endpoint, err := url.Parse(strings.TrimRight(cfg.XunleiSubAPIBase, "/"))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid xunlei url", ErrUpstream)
	}
	q := endpoint.Query()
	q.Set("name", keyword)
	q.Set("cid", "")
	q.Set("gcid", "")
	endpoint.RawQuery = q.Encode()

	body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, endpoint.String(), cfg.MetadataProxy, nil, nil)
	if err != nil {
		return nil, err
	}
	if status == http.StatusTooManyRequests {
		return nil, ErrRateLimited
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("%w: xunlei returned HTTP %d", ErrUpstream, status)
	}

	var parsed xunleiSearchResp
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("%w: invalid xunlei JSON: %v", ErrUpstream, err)
	}
	if parsed.Code != 0 {
		return nil, fmt.Errorf("%w: xunlei error code %d", ErrUpstream, parsed.Code)
	}

	out := make([]Candidate, 0, len(parsed.Data))
	seen := make(map[string]struct{}, len(parsed.Data))
	for i, item := range parsed.Data {
		rawURL := strings.TrimSpace(item.URL)
		if rawURL == "" {
			continue
		}
		if _, dup := seen[rawURL]; dup {
			continue
		}
		seen[rawURL] = struct{}{}

		format := NormalizeSubtitleFormat(item.Ext)
		if format == "" {
			format = FormatFromFilename(item.Name)
		}
		if format == "" {
			format = FormatFromFilename(rawURL)
		}
		if format == "" {
			continue
		}

		name := strings.TrimSpace(item.Name)
		if name == "" {
			if u, parseErr := url.Parse(rawURL); parseErr == nil {
				name = path.Base(u.Path)
			}
		}
		if name == "" {
			name = fmt.Sprintf("xunlei_%d.%s", i+1, format)
		}

		id := strings.TrimSpace(item.CID)
		if id == "" {
			id = fmt.Sprintf("xl-%d", i+1)
		}

		tok, tokErr := s.sealToken(ProviderXunlei, xunleiDownloadPayload{
			URL:      rawURL,
			Filename: name,
			Format:   format,
		})
		if tokErr != nil {
			continue
		}

		score := float64(60)
		if format == "ass" || format == "ssa" {
			score += 10
		}
		if req.Episode > 0 {
			score += float64(scoreSubtitleFilename(name, format, req.Season, req.Episode, "zh")) / 20.0
		}

		out = append(out, Candidate{
			ID:            id,
			Provider:      ProviderXunlei,
			Title:         name,
			ReleaseName:   name,
			Language:      "zh",
			Format:        format,
			PerfectMatch:  req.FileName != "" && strings.Contains(strings.ToLower(name), strings.ToLower(strings.TrimSuffix(req.FileName, path.Ext(req.FileName)))),
			Score:         score,
			DownloadToken: tok,
		})
		if len(out) >= 20 {
			break
		}
	}
	return out, nil
}

func (s *Service) downloadXunlei(ctx context.Context, cfg db.ServerSettings, rawPayload json.RawMessage, req DownloadRequest) (DownloadedSubtitle, error) {
	var p xunleiDownloadPayload
	if err := json.Unmarshal(rawPayload, &p); err != nil || strings.TrimSpace(p.URL) == "" {
		return DownloadedSubtitle{}, ErrInvalidToken
	}
	if err := validateExternalHTTPURL(p.URL, s.allowLoopbackDownloads); err != nil {
		return DownloadedSubtitle{}, err
	}

	body, _, status, err := s.doRequestBytes(ctx, http.MethodGet, p.URL, cfg.MetadataProxy, nil, nil)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	if status == http.StatusNotFound {
		return DownloadedSubtitle{}, ErrNotFound
	}
	if status < 200 || status >= 300 {
		return DownloadedSubtitle{}, fmt.Errorf("%w: xunlei download HTTP %d", ErrUpstream, status)
	}

	filename := strings.TrimSpace(p.Filename)
	format := NormalizeSubtitleFormat(p.Format)
	rawData := body
	if IsZipArchive(body) {
		name, fmtExt, extracted, zipErr := ExtractSubtitleFromZip(body, req.Season, req.Episode, req.Language)
		if zipErr != nil {
			return DownloadedSubtitle{}, zipErr
		}
		filename = name
		format = fmtExt
		rawData = extracted
	} else if IsUnsupportedArchive(body) {
		return DownloadedSubtitle{}, ErrUnsupportedArchive
	}

	if format == "" {
		format = FormatFromFilename(filename)
	}
	if format == "" {
		format = "srt"
	}
	if filename == "" {
		filename = "subtitle." + format
	}

	utf8Content, err := DecodeSubtitleToUTF8(rawData)
	if err != nil {
		return DownloadedSubtitle{}, err
	}
	return DownloadedSubtitle{
		Provider: ProviderXunlei,
		Filename: filename,
		Format:   format,
		Language: firstNonEmpty(NormalizeLanguageCode(req.Language), "zh"),
		Content:  utf8Content,
	}, nil
}
