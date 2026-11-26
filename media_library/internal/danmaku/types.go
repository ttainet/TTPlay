package danmaku

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const ProviderDanmuAPI = "danmu_api"

var (
	ErrNotConfigured = errors.New("danmu service is not configured or disabled")
	ErrInvalidInput  = errors.New("invalid danmu query parameters")
	ErrNotFound      = errors.New("danmu resource not found")
	ErrUpstream      = errors.New("danmu upstream request failed")
	ErrRateLimited   = errors.New("danmu upstream rate limit exceeded")
)

func NormalizeProviderName(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case ProviderDanmuAPI, "danmu", "danmaku":
		return ProviderDanmuAPI
	default:
		return strings.ToLower(strings.TrimSpace(raw))
	}
}

// FlexString decodes JSON values that may be encoded as either string or number.
type FlexString string

func (f *FlexString) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		*f = ""
		return nil
	}
	if trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return err
		}
		*f = FlexString(s)
		return nil
	}
	var num json.Number
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	dec.UseNumber()
	if err := dec.Decode(&num); err == nil {
		*f = FlexString(num.String())
		return nil
	}
	return fmt.Errorf("cannot decode %s into FlexString", string(trimmed))
}

func (f FlexString) String() string {
	return string(f)
}

type MatchRequest struct {
	FileName      string `json:"file_name"`
	Title         string `json:"title"`
	OriginalTitle string `json:"original_title"`
	ShowTitle     string `json:"show_title"`
	Kind          string `json:"kind"` // movie | episode
	Year          int    `json:"year"`
	Season        int    `json:"season"`
	Episode       int    `json:"episode"`
	Platform      string `json:"platform"`
	Refresh       bool   `json:"refresh,omitempty"`
}

type MatchItem struct {
	EpisodeID       string  `json:"episode_id"`
	AnimeID         string  `json:"anime_id"`
	AnimeTitle      string  `json:"anime_title"`
	EpisodeTitle    string  `json:"episode_title"`
	Type            string  `json:"type,omitempty"`
	TypeDescription string  `json:"type_description,omitempty"`
	Shift           float64 `json:"shift"`
	ImageURL        string  `json:"image_url,omitempty"`
	SourceURL       string  `json:"source_url,omitempty"`
}

type MatchResult struct {
	Matched   bool        `json:"matched"`
	Matches   []MatchItem `json:"matches"`
	QueryUsed string      `json:"query_used"`
	Cached    bool        `json:"cached"`
}

type AnimeItem struct {
	AnimeID         string `json:"anime_id"`
	AnimeTitle      string `json:"anime_title"`
	Type            string `json:"type,omitempty"`
	TypeDescription string `json:"type_description,omitempty"`
	ImageURL        string `json:"image_url,omitempty"`
	StartDate       string `json:"start_date,omitempty"`
	EpisodeCount    int    `json:"episode_count,omitempty"`
	Source          string `json:"source,omitempty"`
}

type SearchResult struct {
	Animes []AnimeItem `json:"animes"`
	Cached bool        `json:"cached"`
}

type BangumiEpisode struct {
	EpisodeID     string `json:"episode_id"`
	EpisodeTitle  string `json:"episode_title"`
	EpisodeNumber string `json:"episode_number,omitempty"`
	SourceURL     string `json:"source_url,omitempty"`
}

type BangumiDetail struct {
	AnimeID         string           `json:"anime_id"`
	AnimeTitle      string           `json:"anime_title"`
	Type            string           `json:"type,omitempty"`
	TypeDescription string           `json:"type_description,omitempty"`
	ImageURL        string           `json:"image_url,omitempty"`
	Episodes        []BangumiEpisode `json:"episodes"`
	Cached          bool             `json:"cached"`
}

type DanmakuComment struct {
	CID    int64   `json:"cid"`
	Time   float64 `json:"time"`
	Mode   int     `json:"mode"`
	Color  int     `json:"color"`
	Text   string  `json:"text"`
	UserID string  `json:"user_id,omitempty"`
	P      string  `json:"p,omitempty"`
}

type CommentsResult struct {
	EpisodeID     string           `json:"episode_id"`
	SourceURL     string           `json:"source_url,omitempty"`
	Count         int              `json:"count"`
	TotalCount    int              `json:"total_count"`
	Sampled       bool             `json:"sampled"`
	VideoDuration float64          `json:"video_duration"`
	Comments      []DanmakuComment `json:"comments"`
	Cached        bool             `json:"cached"`
}

type CacheStats struct {
	Searches int64 `json:"searches"`
	Comments int64 `json:"comments"`
}

type ConfigView struct {
	Enabled            bool     `json:"enabled"`
	Configured         bool     `json:"configured"`
	Provider           string   `json:"provider"`
	PreferredPlatforms []string `json:"preferred_platforms"`
	TimeoutSec         int      `json:"timeout_sec"`
	SearchCacheHours   int      `json:"search_cache_hours"`
	CommentCacheHours  int      `json:"comment_cache_hours"`
	MaxComments        int      `json:"max_comments"`
}

type ProviderTestOverrides struct {
	APIBase       *string `json:"api_base,omitempty"`
	Token         *string `json:"token,omitempty"`
	MetadataProxy *string `json:"metadata_proxy,omitempty"`
}
