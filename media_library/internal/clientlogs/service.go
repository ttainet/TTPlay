package clientlogs

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"ttplay/media_library/internal/db"
)

const (
	MaxPayloadBytes = 1*1024*1024 + 64*1024
	MaxRetainedLogs = 500
	RetentionDays   = 30

	shortIDAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"
	shortIDLen      = 8
	maxMetaLen      = 160
)

var (
	ErrPayloadTooLarge = errors.New("client log payload exceeds maximum allowed size")

	reAppHeader = regexp.MustCompile(`(?i)^(?:TTPlay|Plezy)\s+v?(\d.+)$`)
)

// RecordSummary represents a stored client diagnostic log without the full body.
type RecordSummary struct {
	ID          string `json:"id"`
	DeviceName  string `json:"device_name"`
	Platform    string `json:"platform"`
	OSVersion   string `json:"os_version"`
	AppVersion  string `json:"app_version"`
	IsTV        bool   `json:"is_tv"`
	Source      string `json:"source"`
	ClientIP    string `json:"client_ip"`
	SizeBytes   int    `json:"size_bytes"`
	LineCount   int    `json:"line_count"`
	Preview     string `json:"preview"`
	CreatedDate string `json:"created_date"`
	CreatedAt   int64  `json:"created_at"`
}

// RecordDetail includes the full text payload along with summary fields.
type RecordDetail struct {
	RecordSummary
	Content string `json:"content"`
}

// UploadInput holds the raw log content and optional client-supplied metadata headers.
type UploadInput struct {
	Content    string
	DeviceName string
	Platform   string
	OSVersion  string
	AppVersion string
	IsTV       *bool
	Source     string
	ClientIP   string
}

// ListFilter specifies admin filtering and pagination criteria.
type ListFilter struct {
	Device      string
	Platform    string
	IsTV        *bool
	DateFrom    string
	DateTo      string
	TZOffsetMin *int
	Keyword     string
	Limit       int
	Offset      int
}

// ListResult contains paginated client logs and distinct filter facets.
type ListResult struct {
	Items          []RecordSummary `json:"items"`
	Total          int             `json:"total"`
	TotalSizeBytes int64           `json:"total_size_bytes"`
	Devices        []string        `json:"devices"`
	Platforms      []string        `json:"platforms"`
}

// Service manages persistence, parsing, querying and retention of client logs.
type Service struct {
	store *db.Store
	nowFn func() time.Time
}

// NewService constructs a client log service backed by store.
func NewService(store *db.Store) *Service {
	return &Service{
		store: store,
		nowFn: time.Now,
	}
}

// SetClock overrides the wall clock for deterministic testing.
func (s *Service) SetClock(fn func() time.Time) {
	if fn != nil {
		s.nowFn = fn
	}
}

func decodeHeaderValue(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if strings.Contains(trimmed, "%") {
		if decoded, err := url.PathUnescape(trimmed); err == nil {
			trimmed = strings.TrimSpace(decoded)
		}
	}
	return truncateRunes(trimmed, maxMetaLen)
}

func truncateRunes(s string, maxRunes int) string {
	if maxRunes <= 0 || s == "" {
		return ""
	}
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	var b strings.Builder
	b.Grow(maxRunes)
	count := 0
	for _, r := range s {
		if count >= maxRunes {
			break
		}
		b.WriteRune(r)
		count++
	}
	return b.String()
}

func normalizePlatform(raw string) string {
	lower := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case lower == "":
		return ""
	case strings.Contains(lower, "android"):
		return "android"
	case strings.Contains(lower, "ios") || strings.Contains(lower, "ipados") || strings.Contains(lower, "tvos"):
		return "ios"
	case strings.Contains(lower, "macos") || strings.Contains(lower, "darwin"):
		return "macos"
	case strings.Contains(lower, "windows"):
		return "windows"
	case strings.Contains(lower, "linux"):
		return "linux"
	case lower == "unknown":
		return "unknown"
	default:
		return truncateRunes(lower, 32)
	}
}

func isKeyValueHeaderLine(line string) bool {
	if line == "" {
		return false
	}
	idx := strings.Index(line, ":")
	if idx <= 0 {
		return false
	}
	key := strings.TrimSpace(line[:idx])
	switch strings.ToLower(key) {
	case "tv mode", "renderer", "background", "effects", "display", "video decoders",
		"phase", "error", "platform", "app", "version", "timestamp", "time", "device":
		return true
	}
	return false
}

type parsedMeta struct {
	deviceName string
	platform   string
	osVersion  string
	appVersion string
	isTV       bool
	source     string
}

func parseDiagnosticMetadata(content string) parsedMeta {
	normalized := strings.ReplaceAll(content, "\r\n", "\n")
	headerPart := normalized
	if idx := strings.Index(normalized, "\n---\n"); idx >= 0 {
		headerPart = normalized[:idx]
	} else if idx := strings.Index(normalized, "\n---"); idx >= 0 {
		headerPart = normalized[:idx]
	}

	lines := strings.Split(headerPart, "\n")
	if len(lines) > 30 {
		lines = lines[:30]
	}

	var meta parsedMeta
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		if meta.appVersion == "" {
			if m := reAppHeader.FindStringSubmatch(line); len(m) == 2 {
				meta.appVersion = truncateRunes(strings.TrimSpace(m[1]), maxMetaLen)
				continue
			}
		}

		lower := strings.ToLower(line)
		switch {
		case strings.HasPrefix(lower, "android "):
			meta.platform = "android"
			meta.osVersion = truncateRunes(line, maxMetaLen)
			meta.deviceName = pickNextDeviceLine(lines, i+1)
		case strings.HasPrefix(lower, "ios "):
			meta.platform = "ios"
			meta.osVersion = truncateRunes(line, maxMetaLen)
			meta.deviceName = pickNextDeviceLine(lines, i+1)
		case strings.HasPrefix(lower, "macos "):
			meta.platform = "macos"
			meta.osVersion = truncateRunes(line, maxMetaLen)
			meta.deviceName = pickNextDeviceLine(lines, i+1)
		case strings.HasPrefix(lower, "windows"):
			meta.platform = "windows"
			meta.osVersion = truncateRunes(line, maxMetaLen)
			meta.deviceName = pickNextDeviceLine(lines, i+1)
		case strings.HasPrefix(lower, "linux"):
			meta.platform = "linux"
			meta.osVersion = truncateRunes(line, maxMetaLen)
			meta.deviceName = pickNextDeviceLine(lines, i+1)
		case strings.HasPrefix(lower, "tv mode:"):
			val := strings.TrimSpace(line[len("tv mode:"):])
			if strings.HasPrefix(strings.ToLower(val), "yes") {
				meta.isTV = true
			}
		case strings.HasPrefix(lower, "phase:"):
			if meta.source == "" {
				meta.source = "startup_failure"
			}
		case strings.HasPrefix(lower, "platform:"):
			val := strings.TrimSpace(line[len("platform:"):])
			if meta.osVersion == "" {
				meta.osVersion = truncateRunes(val, maxMetaLen)
			}
			if meta.platform == "" {
				meta.platform = normalizePlatform(val)
			}
		case strings.HasPrefix(lower, "app:"):
			val := strings.TrimSpace(line[len("app:"):])
			if meta.appVersion == "" {
				meta.appVersion = truncateRunes(val, maxMetaLen)
			}
		case strings.HasPrefix(lower, "version:"):
			val := strings.TrimSpace(line[len("version:"):])
			if meta.appVersion == "" {
				meta.appVersion = truncateRunes(val, maxMetaLen)
			}
		case strings.HasPrefix(lower, "device:"):
			val := strings.TrimSpace(line[len("device:"):])
			if meta.deviceName == "" {
				meta.deviceName = truncateRunes(val, maxMetaLen)
			}
		}
	}
	return meta
}

func pickNextDeviceLine(lines []string, nextIdx int) string {
	if nextIdx >= len(lines) {
		return ""
	}
	nextLine := strings.TrimSpace(lines[nextIdx])
	if nextLine == "" || nextLine == "---" || isKeyValueHeaderLine(nextLine) {
		return ""
	}
	return truncateRunes(nextLine, maxMetaLen)
}

func extractPreview(content string) string {
	normalized := strings.ReplaceAll(content, "\r\n", "\n")
	body := normalized
	if idx := strings.Index(normalized, "\n---\n"); idx >= 0 {
		body = normalized[idx+5:]
	} else if idx := strings.Index(normalized, "\n---"); idx >= 0 {
		rest := strings.TrimPrefix(normalized[idx+4:], "\n")
		body = rest
	}

	var firstNonEmpty string
	for _, rawLine := range strings.Split(body, "\n") {
		line := strings.Join(strings.Fields(strings.TrimSpace(rawLine)), " ")
		if line == "" {
			continue
		}
		if firstNonEmpty == "" {
			firstNonEmpty = line
		}
		upper := strings.ToUpper(line)
		if strings.Contains(upper, "[ERROR]") ||
			strings.Contains(upper, "[FATAL]") ||
			strings.Contains(upper, "[WARNING]") ||
			strings.Contains(upper, "[WARN]") ||
			strings.HasPrefix(upper, "ERROR:") {
			return truncateRunes(line, 200)
		}
	}
	return truncateRunes(firstNonEmpty, 200)
}

func countLines(content string) int {
	if content == "" {
		return 0
	}
	trimmed := strings.TrimRight(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	if trimmed == "" {
		return 0
	}
	return strings.Count(trimmed, "\n") + 1
}

func generateShortID() (string, error) {
	buf := make([]byte, shortIDLen)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	var out [shortIDLen]byte
	for i, b := range buf {
		out[i] = shortIDAlphabet[int(b)%len(shortIDAlphabet)]
	}
	return string(out[:]), nil
}

// Create validates, enriches metadata, persists a client diagnostic log, and enforces retention.
func (s *Service) Create(in UploadInput) (*RecordSummary, error) {
	if s == nil || s.store == nil {
		return nil, fmt.Errorf("client logs service unavailable")
	}
	if len(in.Content) > MaxPayloadBytes {
		return nil, ErrPayloadTooLarge
	}
	if strings.TrimSpace(in.Content) == "" {
		return nil, fmt.Errorf("%w: log payload is empty", db.ErrInvalidInput)
	}

	parsed := parseDiagnosticMetadata(in.Content)

	deviceName := decodeHeaderValue(in.DeviceName)
	if deviceName == "" {
		deviceName = parsed.deviceName
	}

	platformName := normalizePlatform(decodeHeaderValue(in.Platform))
	if platformName == "" {
		platformName = parsed.platform
	}
	if platformName == "" {
		platformName = "unknown"
	}

	osVersion := decodeHeaderValue(in.OSVersion)
	if osVersion == "" {
		osVersion = parsed.osVersion
	}

	appVersion := decodeHeaderValue(in.AppVersion)
	if appVersion == "" {
		appVersion = parsed.appVersion
	}

	isTV := parsed.isTV
	if in.IsTV != nil {
		isTV = *in.IsTV
	}

	source := strings.ToLower(decodeHeaderValue(in.Source))
	if source == "" {
		source = parsed.source
	}
	if source == "" {
		source = "logs_screen"
	}

	if deviceName == "" {
		if osVersion != "" {
			deviceName = osVersion
		} else {
			deviceName = "未知设备"
		}
	}

	now := s.nowFn()
	nowMs := now.UnixMilli()
	createdDate := now.Format("2006-01-02")
	sizeBytes := len(in.Content)
	lineCount := countLines(in.Content)
	preview := extractPreview(in.Content)
	isTVInt := 0
	if isTV {
		isTVInt = 1
	}

	var id string
	var insertErr error
	for attempt := 0; attempt < 5; attempt++ {
		id, insertErr = generateShortID()
		if insertErr != nil {
			return nil, fmt.Errorf("generate log id: %w", insertErr)
		}
		_, insertErr = s.store.DB().Exec(`
			INSERT INTO client_logs (
				id, device_name, platform, os_version, app_version, is_tv,
				source, client_ip, size_bytes, line_count, preview, content,
				created_date, created_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			id, deviceName, platformName, osVersion, appVersion, isTVInt,
			source, truncateRunes(strings.TrimSpace(in.ClientIP), 64),
			sizeBytes, lineCount, preview, in.Content,
			createdDate, nowMs,
		)
		if insertErr == nil {
			break
		}
		if !strings.Contains(strings.ToLower(insertErr.Error()), "unique") {
			return nil, fmt.Errorf("insert client log: %w", insertErr)
		}
	}
	if insertErr != nil {
		return nil, fmt.Errorf("insert client log after retries: %w", insertErr)
	}

	_ = s.enforceRetention(nowMs)

	return &RecordSummary{
		ID:          id,
		DeviceName:  deviceName,
		Platform:    platformName,
		OSVersion:   osVersion,
		AppVersion:  appVersion,
		IsTV:        isTV,
		Source:      source,
		ClientIP:    strings.TrimSpace(in.ClientIP),
		SizeBytes:   sizeBytes,
		LineCount:   lineCount,
		Preview:     preview,
		CreatedDate: createdDate,
		CreatedAt:   nowMs,
	}, nil
}

func (s *Service) enforceRetention(nowMs int64) error {
	cutoffMs := nowMs - int64(RetentionDays)*24*60*60*1000
	if _, err := s.store.DB().Exec(`DELETE FROM client_logs WHERE created_at < ?`, cutoffMs); err != nil {
		return err
	}
	if _, err := s.store.DB().Exec(`
		DELETE FROM client_logs
		WHERE id IN (
			SELECT id FROM client_logs ORDER BY created_at DESC LIMIT -1 OFFSET ?
		)`, MaxRetainedLogs); err != nil {
		return err
	}
	return nil
}

func buildDateLocation(tzOffsetMin *int) *time.Location {
	if tzOffsetMin == nil {
		return time.Local
	}
	// JS getTimezoneOffset() is UTC - local in minutes (e.g. -480 for UTC+8).
	offsetMin := *tzOffsetMin
	if offsetMin < -14*60 || offsetMin > 14*60 {
		return time.Local
	}
	return time.FixedZone("client", -offsetMin*60)
}

// List queries client diagnostic logs matching the filter criteria.
func (s *Service) List(f ListFilter) (*ListResult, error) {
	if s == nil || s.store == nil {
		return nil, fmt.Errorf("client logs service unavailable")
	}

	limit := f.Limit
	if limit <= 0 {
		limit = 25
	}
	if limit > 200 {
		limit = 200
	}
	offset := f.Offset
	if offset < 0 {
		offset = 0
	}

	loc := buildDateLocation(f.TZOffsetMin)
	var clauses []string
	var args []any

	if dev := strings.TrimSpace(f.Device); dev != "" {
		clauses = append(clauses, `device_name = ?`)
		args = append(args, dev)
	}
	if plat := normalizePlatform(f.Platform); plat != "" {
		clauses = append(clauses, `platform = ?`)
		args = append(args, plat)
	}
	if f.IsTV != nil {
		if *f.IsTV {
			clauses = append(clauses, `is_tv = 1`)
		} else {
			clauses = append(clauses, `is_tv = 0`)
		}
	}
	if df := strings.TrimSpace(f.DateFrom); df != "" {
		t, err := time.ParseInLocation("2006-01-02", df, loc)
		if err != nil {
			return nil, fmt.Errorf("%w: invalid date_from %q (expected YYYY-MM-DD)", db.ErrInvalidInput, df)
		}
		clauses = append(clauses, `created_at >= ?`)
		args = append(args, t.UnixMilli())
	}
	if dt := strings.TrimSpace(f.DateTo); dt != "" {
		t, err := time.ParseInLocation("2006-01-02", dt, loc)
		if err != nil {
			return nil, fmt.Errorf("%w: invalid date_to %q (expected YYYY-MM-DD)", db.ErrInvalidInput, dt)
		}
		clauses = append(clauses, `created_at < ?`)
		args = append(args, t.AddDate(0, 0, 1).UnixMilli())
	}
	if kw := strings.TrimSpace(f.Keyword); kw != "" {
		like := "%" + strings.ToLower(kw) + "%"
		clauses = append(clauses, `(LOWER(id) LIKE ? OR LOWER(device_name) LIKE ? OR LOWER(os_version) LIKE ? OR LOWER(app_version) LIKE ? OR LOWER(preview) LIKE ? OR LOWER(content) LIKE ?)`)
		args = append(args, like, like, like, like, like, like)
	}

	whereSQL := ""
	if len(clauses) > 0 {
		whereSQL = "WHERE " + strings.Join(clauses, " AND ")
	}

	rdb := s.store.ReadDB()
	var total int
	var totalBytes int64
	countSQL := `SELECT COUNT(*), COALESCE(SUM(size_bytes), 0) FROM client_logs ` + whereSQL
	if err := rdb.QueryRow(countSQL, args...).Scan(&total, &totalBytes); err != nil {
		return nil, fmt.Errorf("count client logs: %w", err)
	}

	listSQL := `
		SELECT id, device_name, platform, os_version, app_version, is_tv,
		       source, client_ip, size_bytes, line_count, preview, created_date, created_at
		FROM client_logs ` + whereSQL + ` ORDER BY created_at DESC LIMIT ? OFFSET ?`
	queryArgs := append(append([]any{}, args...), limit, offset)
	rows, err := rdb.Query(listSQL, queryArgs...)
	if err != nil {
		return nil, fmt.Errorf("query client logs: %w", err)
	}
	defer rows.Close()

	items := make([]RecordSummary, 0)
	for rows.Next() {
		var rec RecordSummary
		var isTVInt int
		if err := rows.Scan(
			&rec.ID, &rec.DeviceName, &rec.Platform, &rec.OSVersion, &rec.AppVersion, &isTVInt,
			&rec.Source, &rec.ClientIP, &rec.SizeBytes, &rec.LineCount, &rec.Preview, &rec.CreatedDate, &rec.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan client log: %w", err)
		}
		rec.IsTV = isTVInt != 0
		items = append(items, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate client logs: %w", err)
	}

	devices, err := s.queryDistinctStrings(`SELECT DISTINCT device_name FROM client_logs WHERE device_name != '' ORDER BY device_name ASC`)
	if err != nil {
		return nil, err
	}
	platforms, err := s.queryDistinctStrings(`SELECT DISTINCT platform FROM client_logs WHERE platform != '' ORDER BY platform ASC`)
	if err != nil {
		return nil, err
	}

	return &ListResult{
		Items:          items,
		Total:          total,
		TotalSizeBytes: totalBytes,
		Devices:        devices,
		Platforms:      platforms,
	}, nil
}

func (s *Service) queryDistinctStrings(query string) ([]string, error) {
	rows, err := s.store.ReadDB().Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]string, 0)
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// Get fetches a single client diagnostic log and its full body by ID (case-insensitive).
func (s *Service) Get(id string) (*RecordDetail, error) {
	if s == nil || s.store == nil {
		return nil, fmt.Errorf("client logs service unavailable")
	}
	trimmed := strings.TrimSpace(id)
	if trimmed == "" {
		return nil, fmt.Errorf("%w: log id is required", db.ErrInvalidInput)
	}

	var rec RecordDetail
	var isTVInt int
	err := s.store.ReadDB().QueryRow(`
		SELECT id, device_name, platform, os_version, app_version, is_tv,
		       source, client_ip, size_bytes, line_count, preview, content, created_date, created_at
		FROM client_logs
		WHERE LOWER(id) = LOWER(?)`, trimmed,
	).Scan(
		&rec.ID, &rec.DeviceName, &rec.Platform, &rec.OSVersion, &rec.AppVersion, &isTVInt,
		&rec.Source, &rec.ClientIP, &rec.SizeBytes, &rec.LineCount, &rec.Preview, &rec.Content, &rec.CreatedDate, &rec.CreatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("%w: client log %s", db.ErrNotFound, trimmed)
	}
	if err != nil {
		return nil, fmt.Errorf("get client log: %w", err)
	}
	rec.IsTV = isTVInt != 0
	return &rec, nil
}

// Delete removes one client log by ID (case-insensitive).
func (s *Service) Delete(id string) error {
	if s == nil || s.store == nil {
		return fmt.Errorf("client logs service unavailable")
	}
	trimmed := strings.TrimSpace(id)
	if trimmed == "" {
		return fmt.Errorf("%w: log id is required", db.ErrInvalidInput)
	}
	res, err := s.store.DB().Exec(`DELETE FROM client_logs WHERE LOWER(id) = LOWER(?)`, trimmed)
	if err != nil {
		return fmt.Errorf("delete client log: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: client log %s", db.ErrNotFound, trimmed)
	}
	return nil
}

// Prune removes logs matching olderThanDays, a specific device, or all logs.
func (s *Service) Prune(olderThanDays int, device string, all bool) (int64, error) {
	if s == nil || s.store == nil {
		return 0, fmt.Errorf("client logs service unavailable")
	}
	dev := strings.TrimSpace(device)
	if !all && olderThanDays <= 0 && dev == "" {
		return 0, fmt.Errorf("%w: specify older_than_days, device, or all=true", db.ErrInvalidInput)
	}

	var res sql.Result
	var err error
	if all {
		res, err = s.store.DB().Exec(`DELETE FROM client_logs`)
	} else {
		var clauses []string
		var args []any
		if olderThanDays > 0 {
			cutoffMs := s.nowFn().UnixMilli() - int64(olderThanDays)*24*60*60*1000
			clauses = append(clauses, `created_at < ?`)
			args = append(args, cutoffMs)
		}
		if dev != "" {
			clauses = append(clauses, `device_name = ?`)
			args = append(args, dev)
		}
		res, err = s.store.DB().Exec(`DELETE FROM client_logs WHERE `+strings.Join(clauses, " AND "), args...)
	}
	if err != nil {
		return 0, fmt.Errorf("prune client logs: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}
