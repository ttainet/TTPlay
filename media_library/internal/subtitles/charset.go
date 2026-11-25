package subtitles

import (
	"archive/zip"
	"bytes"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
	"golang.org/x/text/encoding/unicode"
	"golang.org/x/text/transform"
)

const (
	maxZipEntries          = 50
	maxZipEntryUncompBytes = 10 * 1024 * 1024
)

var (
	reSeasonEpisode = regexp.MustCompile(`(?i)\bS0*(\d{1,2})[._ -]?E0*(\d{1,3})\b`)
	reEpisodeOnly   = regexp.MustCompile(`(?i)(?:\bE|EP|第)\s*0*(\d{1,3})\b|\[0*(\d{1,3})\]`)
)

// DecodeSubtitleToUTF8 strips BOMs, converts UTF-16 or GB18030/Big5 payloads to
// clean UTF-8, and rejects binary payloads.
func DecodeSubtitleToUTF8(raw []byte) (string, error) {
	if len(raw) == 0 {
		return "", fmt.Errorf("%w: empty subtitle payload", ErrUpstream)
	}

	// UTF-8 BOM
	if bytes.HasPrefix(raw, []byte{0xEF, 0xBB, 0xBF}) {
		trimmed := bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
		if utf8.Valid(trimmed) {
			return normalizeNewlines(trimmed), nil
		}
	}

	// UTF-16 BOM
	if bytes.HasPrefix(raw, []byte{0xFF, 0xFE}) || bytes.HasPrefix(raw, []byte{0xFE, 0xFF}) {
		dec := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder()
		decoded, _, err := transform.Bytes(dec, raw)
		if err == nil && utf8.Valid(decoded) && bytes.IndexByte(decoded, 0) < 0 {
			return normalizeNewlines(decoded), nil
		}
	}

	if bytes.IndexByte(raw, 0) >= 0 {
		// Unmarked UTF-16 heuristic (many zero bytes in alternating positions).
		if looksLikeUTF16NoBOM(raw) {
			endian := unicode.LittleEndian
			if raw[0] == 0 && raw[1] != 0 {
				endian = unicode.BigEndian
			}
			dec := unicode.UTF16(endian, unicode.IgnoreBOM).NewDecoder()
			if decoded, _, err := transform.Bytes(dec, raw); err == nil && utf8.Valid(decoded) && bytes.IndexByte(decoded, 0) < 0 {
				return normalizeNewlines(decoded), nil
			}
		}
		return "", fmt.Errorf("%w: binary subtitle payload", ErrUpstream)
	}

	if utf8.Valid(raw) {
		return normalizeNewlines(raw), nil
	}

	gbDec := simplifiedchinese.GB18030.NewDecoder()
	gbBytes, _, gbErr := transform.Bytes(gbDec, raw)
	big5Dec := traditionalchinese.Big5.NewDecoder()
	big5Bytes, _, big5Err := transform.Bytes(big5Dec, raw)

	if gbErr == nil && utf8.Valid(gbBytes) && big5Err == nil && utf8.Valid(big5Bytes) {
		if scoreChineseText(big5Bytes) > scoreChineseText(gbBytes)+5 {
			return normalizeNewlines(big5Bytes), nil
		}
		return normalizeNewlines(gbBytes), nil
	}
	if gbErr == nil && utf8.Valid(gbBytes) {
		return normalizeNewlines(gbBytes), nil
	}
	if big5Err == nil && utf8.Valid(big5Bytes) {
		return normalizeNewlines(big5Bytes), nil
	}

	// Last-resort lossless UTF-8 sanitization
	return normalizeNewlines([]byte(strings.ToValidUTF8(string(raw), "\uFFFD"))), nil
}

func looksLikeUTF16NoBOM(raw []byte) bool {
	if len(raw) < 4 || len(raw)%2 != 0 {
		return false
	}
	limit := len(raw)
	if limit > 256 {
		limit = 256
	}
	evenZero, oddZero := 0, 0
	for i := 0; i < limit; i += 2 {
		if raw[i] == 0 {
			evenZero++
		}
		if raw[i+1] == 0 {
			oddZero++
		}
	}
	pairs := limit / 2
	return oddZero > pairs/3 || evenZero > pairs/3
}

func scoreChineseText(b []byte) int {
	score := 0
	for _, r := range string(b) {
		switch {
		case r == utf8.RuneError:
			score -= 5
		case r >= 0x4E00 && r <= 0x9FFF:
			score += 2
		}
	}
	return score
}

func normalizeNewlines(b []byte) string {
	s := string(b)
	s = strings.TrimPrefix(s, "\uFEFF")
	return s
}

func IsZipArchive(b []byte) bool {
	return len(b) >= 4 && b[0] == 'P' && b[1] == 'K' && (b[2] == 0x03 || b[2] == 0x05 || b[2] == 0x07)
}

func IsUnsupportedArchive(b []byte) bool {
	if bytes.HasPrefix(b, []byte("Rar!")) {
		return true
	}
	if len(b) >= 6 && bytes.Equal(b[:6], []byte{0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C}) {
		return true
	}
	return false
}

type zipCandidate struct {
	name   string
	format string
	data   []byte
	score  int
}

// ExtractSubtitleFromZip safely extracts the best matching subtitle file from a ZIP archive.
func ExtractSubtitleFromZip(zipBytes []byte, season, episode int, lang string) (string, string, []byte, error) {
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return "", "", nil, fmt.Errorf("%w: invalid zip archive: %v", ErrUpstream, err)
	}
	if len(zr.File) > maxZipEntries*4 {
		return "", "", nil, fmt.Errorf("%w: zip archive has too many entries", ErrUpstream)
	}

	normLang := NormalizeLanguageCode(lang)
	var candidates []zipCandidate
	inspected := 0

	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		clean := path.Clean("/" + strings.ReplaceAll(f.Name, "\\", "/"))
		base := path.Base(clean)
		if base == "." || base == "/" || strings.HasPrefix(base, "._") || strings.Contains(clean, "__MACOSX") {
			continue
		}
		format := FormatFromFilename(base)
		if format == "" {
			continue
		}
		inspected++
		if inspected > maxZipEntries {
			break
		}
		if f.UncompressedSize64 > maxZipEntryUncompBytes {
			continue
		}
		rc, openErr := f.Open()
		if openErr != nil {
			continue
		}
		data, readErr := io.ReadAll(io.LimitReader(rc, maxZipEntryUncompBytes+1))
		_ = rc.Close()
		if readErr != nil || len(data) == 0 || len(data) > maxZipEntryUncompBytes {
			continue
		}

		sc := scoreSubtitleFilename(base, format, season, episode, normLang) + len(data)/4096
		candidates = append(candidates, zipCandidate{
			name:   base,
			format: format,
			data:   data,
			score:  sc,
		})
	}

	if len(candidates) == 0 {
		return "", "", nil, errors.New("no supported subtitle files found inside archive")
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		return candidates[i].score > candidates[j].score
	})
	best := candidates[0]
	return best.name, best.format, best.data, nil
}

func scoreSubtitleFilename(name, format string, season, episode int, normLang string) int {
	lower := strings.ToLower(name)
	score := 0

	switch format {
	case "ass":
		score += 40
	case "ssa":
		score += 30
	case "srt":
		score += 20
	case "vtt":
		score += 10
	}

	if episode > 0 {
		if m := reSeasonEpisode.FindStringSubmatch(name); len(m) == 3 {
			sNum := parseSimpleInt(m[1])
			eNum := parseSimpleInt(m[2])
			if (season <= 0 || sNum == season) && eNum == episode {
				score += 500
			} else if eNum != episode {
				score -= 300
			}
		} else if m := reEpisodeOnly.FindStringSubmatch(name); len(m) == 3 {
			eNum := parseSimpleInt(m[1])
			if eNum == 0 {
				eNum = parseSimpleInt(m[2])
			}
			if eNum == episode {
				score += 350
			} else if eNum > 0 {
				score -= 200
			}
		}
	}

	if normLang == "zh" {
		if strings.Contains(lower, "双语") || strings.Contains(lower, "chs&eng") || strings.Contains(lower, "chs.eng") || strings.Contains(lower, "sc.eng") {
			score += 120
		}
		if strings.Contains(lower, "chs") || strings.Contains(lower, "简") || strings.Contains(lower, ".sc.") || strings.Contains(lower, "zh-cn") {
			score += 80
		} else if strings.Contains(lower, "cht") || strings.Contains(lower, "繁") || strings.Contains(lower, ".tc.") || strings.Contains(lower, "zh-tw") {
			score += 50
		}
	}

	return score
}

func parseSimpleInt(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
