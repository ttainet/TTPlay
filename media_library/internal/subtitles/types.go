package subtitles

import (
	"errors"
	"strings"
)

const (
	ProviderXunlei        = "xunlei"
	ProviderAssrt         = "assrt"
	ProviderSubDL         = "subdl"
	ProviderOpenSubtitles = "opensubtitles"
)

var (
	ErrNotConfigured      = errors.New("subtitle provider is not configured")
	ErrInvalidInput       = errors.New("invalid subtitle query parameters")
	ErrInvalidToken       = errors.New("invalid or expired subtitle download token")
	ErrNotFound           = errors.New("subtitle not found")
	ErrUnsupportedArchive = errors.New("subtitle archive format is not supported")
	ErrUpstream           = errors.New("subtitle upstream request failed")
	ErrRateLimited        = errors.New("subtitle upstream rate limit exceeded")
)

type SearchRequest struct {
	Query         string `json:"query"`
	FileName      string `json:"file_name"`
	Title         string `json:"title"`
	OriginalTitle string `json:"original_title"`
	Language      string `json:"language"`
	Kind          string `json:"kind"` // movie | episode
	ImdbID        string `json:"imdb_id"`
	TmdbID        string `json:"tmdb_id"`
	Year          int    `json:"year"`
	Season        int    `json:"season"`
	Episode       int    `json:"episode"`
	Provider      string `json:"provider"` // all | xunlei | assrt | subdl | opensubtitles
}

type Candidate struct {
	ID              string  `json:"id"`
	Provider        string  `json:"provider"`
	Title           string  `json:"title"`
	ReleaseName     string  `json:"release_name,omitempty"`
	Language        string  `json:"language"`
	Format          string  `json:"format"`
	HearingImpaired bool    `json:"hearing_impaired"`
	Forced          bool    `json:"forced"`
	PerfectMatch    bool    `json:"perfect_match"`
	Score           float64 `json:"score,omitempty"`
	Downloads       int     `json:"downloads,omitempty"`
	DownloadToken   string  `json:"download_token"`
}

type ProviderWarning struct {
	Provider string `json:"provider"`
	Message  string `json:"message"`
}

type SearchResult struct {
	Candidates       []Candidate       `json:"candidates"`
	EnabledProviders []string          `json:"enabled_providers"`
	Warnings         []ProviderWarning `json:"warnings,omitempty"`
	Cached           bool              `json:"cached"`
}

type DownloadRequest struct {
	Provider string `json:"provider"`
	Token    string `json:"token"`
	Language string `json:"language"`
	Season   int    `json:"season"`
	Episode  int    `json:"episode"`
}

type DownloadedSubtitle struct {
	Provider string `json:"provider"`
	Filename string `json:"filename"`
	Format   string `json:"format"`
	Language string `json:"language"`
	SHA256   string `json:"sha256"`
	Content  string `json:"content"`
	Cached   bool   `json:"cached"`
}

type ProviderTestOverrides struct {
	APIKey        *string `json:"api_key,omitempty"`
	Token         *string `json:"token,omitempty"`
	APIBase       *string `json:"api_base,omitempty"`
	MetadataProxy *string `json:"metadata_proxy,omitempty"`
}

func NormalizeProviderName(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "all":
		return "all"
	case ProviderXunlei, "thunder":
		return ProviderXunlei
	case ProviderAssrt, "shooter":
		return ProviderAssrt
	case ProviderSubDL:
		return ProviderSubDL
	case ProviderOpenSubtitles, "opensubtitles.com", "os":
		return ProviderOpenSubtitles
	default:
		return strings.ToLower(strings.TrimSpace(raw))
	}
}

func NormalizeLanguageCode(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "_", "-")
	if idx := strings.IndexByte(s, '-'); idx > 0 {
		prefix := s[:idx]
		if prefix == "zh" || len(prefix) == 2 {
			s = prefix
		}
	}
	switch s {
	case "zh", "zho", "chi", "chs", "cht", "cn":
		return "zh"
	case "en", "eng":
		return "en"
	case "ja", "jpn":
		return "ja"
	case "ko", "kor":
		return "ko"
	case "fr", "fra", "fre":
		return "fr"
	case "de", "deu", "ger":
		return "de"
	case "es", "spa":
		return "es"
	case "pt", "por":
		return "pt"
	case "ru", "rus":
		return "ru"
	case "it", "ita":
		return "it"
	default:
		if len(s) >= 2 {
			return s[:2]
		}
		return s
	}
}

func IsChineseLanguage(lang string) bool {
	return NormalizeLanguageCode(lang) == "zh"
}

func NormalizeSubtitleFormat(raw string) string {
	s := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(raw, ".")))
	switch s {
	case "ass":
		return "ass"
	case "ssa":
		return "ssa"
	case "srt":
		return "srt"
	case "vtt", "webvtt":
		return "vtt"
	default:
		return ""
	}
}

func FormatFromFilename(name string) string {
	idx := strings.LastIndexByte(name, '.')
	if idx < 0 || idx == len(name)-1 {
		return ""
	}
	return NormalizeSubtitleFormat(name[idx+1:])
}
