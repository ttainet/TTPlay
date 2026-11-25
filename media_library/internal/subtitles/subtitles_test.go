package subtitles

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
	"golang.org/x/text/transform"

	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/vault"
)

func openTestStore(t *testing.T) *db.Store {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	st, err := db.Open(dir, v)
	if err != nil {
		t.Fatalf("open test store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func makeZipBytes(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range entries {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("create zip entry %s: %v", name, err)
		}
		if _, err := w.Write(content); err != nil {
			t.Fatalf("write zip entry %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return buf.Bytes()
}

func TestDecodeSubtitleToUTF8(t *testing.T) {
	// 1. UTF-8 with BOM
	utf8Bom := append([]byte{0xEF, 0xBB, 0xBF}, []byte("1\n00:00:01,000 --> 00:00:02,000\n你好世界\n")...)
	got, err := DecodeSubtitleToUTF8(utf8Bom)
	if err != nil || got != "1\n00:00:01,000 --> 00:00:02,000\n你好世界\n" {
		t.Fatalf("utf8 bom decode failed: got=%q err=%v", got, err)
	}

	// 2. GB18030
	gbBytes, _, err := transform.Bytes(simplifiedchinese.GB18030.NewEncoder(), []byte("1\n00:00:01,000 --> 00:00:02,000\n中文测试字幕\n"))
	if err != nil {
		t.Fatalf("encode gb18030: %v", err)
	}
	got, err = DecodeSubtitleToUTF8(gbBytes)
	if err != nil || got != "1\n00:00:01,000 --> 00:00:02,000\n中文测试字幕\n" {
		t.Fatalf("gb18030 decode failed: got=%q err=%v", got, err)
	}

	// 3. UTF-16 LE with BOM
	u16Bytes, _, err := transform.Bytes(unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewEncoder(), []byte("1\n00:00:01,000 --> 00:00:02,000\nUTF16字幕\n"))
	if err != nil {
		t.Fatalf("encode utf16: %v", err)
	}
	got, err = DecodeSubtitleToUTF8(u16Bytes)
	if err != nil || got != "1\n00:00:01,000 --> 00:00:02,000\nUTF16字幕\n" {
		t.Fatalf("utf16 decode failed: got=%q err=%v", got, err)
	}
}

func TestExtractSubtitleFromZip_PicksBestEpisodeAndBlocksTraversal(t *testing.T) {
	zb := makeZipBytes(t, map[string][]byte{
		"__MACOSX/._Show.S01E02.srt":      []byte("junk"),
		"../../evil/Show.S01E01.srt":      []byte("wrong ep"),
		"subs/Show.S01E02.ENG.srt":        []byte("english ep2"),
		"subs/Show.S01E02.CHS.ENG.ass":    []byte("[Script Info]\n双语ep2"),
		"subs/Show.S01E03.CHS.srt":        []byte("ep3"),
	})

	name, fmtExt, data, err := ExtractSubtitleFromZip(zb, 1, 2, "zh")
	if err != nil {
		t.Fatalf("extract zip failed: %v", err)
	}
	if name != "Show.S01E02.CHS.ENG.ass" || fmtExt != "ass" || string(data) != "[Script Info]\n双语ep2" {
		t.Fatalf("unexpected extracted entry: name=%q fmt=%q data=%q", name, fmtExt, string(data))
	}
}

func TestAllFourProvidersSearchDownloadAndCache(t *testing.T) {
	st := openTestStore(t)

	var osDownloadCalls atomic.Int32
	var subdlDownloadCalls atomic.Int32
	gbSubtitle, _, _ := transform.Bytes(simplifiedchinese.GB18030.NewEncoder(), []byte("1\n00:00:01,000 --> 00:00:03,000\n迅雷中文字幕\n"))

	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/xunlei":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"code": 0,
				"data": []map[string]any{
					{
						"cid":  "xl1",
						"url":  srv.URL + "/dl/xunlei.srt",
						"ext":  "srt",
						"name": "Inception.2010.简体中文.srt",
					},
				},
			})
		case "/dl/xunlei.srt":
			_, _ = w.Write(gbSubtitle)

		case "/assrt/sub/search":
			if r.Header.Get("Authorization") != "Bearer assrt-tok" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status": 0,
				"sub": map[string]any{
					"subs": []map[string]any{
						{
							"id":          101,
							"native_name": "盗梦空间 双语特效",
							"videoname":   "Inception.2010.BluRay",
							"subtype":     "ASS",
							"vote_score":  95,
							"lang":        map[string]any{"langlist": map[string]bool{"langdou": true}},
						},
					},
				},
			})
		case "/assrt/sub/detail":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status": 0,
				"sub": map[string]any{
					"subs": []map[string]any{
						{
							"id":       101,
							"filename": "Inception.rar",
							"url":      srv.URL + "/dl/Inception.rar",
							"filelist": []map[string]any{
								{"f": "Inception.2010.chs.ass", "s": "1KB", "url": srv.URL + "/dl/assrt.ass"},
							},
						},
					},
				},
			})
		case "/dl/assrt.ass":
			_, _ = w.Write([]byte("[Script Info]\nTitle: Assrt"))

		case "/subdl/subtitles":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status": true,
				"subtitles": []map[string]any{
					{
						"release_name": "Inception.2010.1080p",
						"name":         "Inception.zh.srt",
						"lang":         "ZH_BG",
						"url":          "/subtitle/123.zip",
					},
				},
			})
		case "/subtitle/123.zip":
			subdlDownloadCalls.Add(1)
			_, _ = w.Write(makeZipBytes(t, map[string][]byte{
				"Inception.2010.chs.srt": []byte("1\n00:00:01,000 --> 00:00:02,000\nSubDL双语\n"),
			}))

		case "/os/subtitles":
			if r.Header.Get("Api-Key") != "os-key" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{
						"id": "555",
						"attributes": map[string]any{
							"language":       "zh-cn",
							"download_count": 320,
							"from_trusted":   true,
							"ratings":        9.0,
							"release":        "Inception.2010.OS",
							"files": []map[string]any{
								{"file_id": 9001, "file_name": "Inception.os.srt"},
							},
						},
					},
				},
			})
		case "/os/download":
			osDownloadCalls.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"link":      srv.URL + "/dl/os.srt",
				"file_name": "Inception.os.srt",
			})
		case "/dl/os.srt":
			_, _ = w.Write([]byte("1\n00:00:01,000 --> 00:00:02,000\nOpenSubtitles OK\n"))

		case "/assrt/user/quota":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status": 0,
				"user":   map[string]any{"quota": 20},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	xlBase := srv.URL + "/xunlei"
	assrtBase := srv.URL + "/assrt"
	assrtTok := "assrt-tok"
	subdlBase := srv.URL + "/subdl"
	subdlKey := "subdl-key"
	osBase := srv.URL + "/os"
	osKey := "os-key"
	if _, err := st.UpdateServerSettings(db.ServerSettingsUpdate{
		XunleiSubAPIBase:     &xlBase,
		AssrtAPIBase:         &assrtBase,
		AssrtToken:           &assrtTok,
		SubDLAPIBase:         &subdlBase,
		SubDLAPIKey:          &subdlKey,
		OpenSubtitlesAPIBase: &osBase,
		OpenSubtitlesAPIKey:  &osKey,
	}); err != nil {
		t.Fatalf("update settings: %v", err)
	}

	svc := NewService(st)
	svc.subdlDownloadBase = srv.URL
	svc.allowLoopbackDownloads = true

	ctx := context.Background()
	res, err := svc.Search(ctx, SearchRequest{
		Title:    "Inception",
		Kind:     "movie",
		TmdbID:   "27205",
		Language: "zh",
	})
	if err != nil {
		t.Fatalf("search failed: %v", err)
	}
	if len(res.Candidates) != 4 {
		t.Fatalf("expected 4 candidates from all providers, got %d (warnings=%v)", len(res.Candidates), res.Warnings)
	}

	byProv := map[string]Candidate{}
	for _, c := range res.Candidates {
		byProv[c.Provider] = c
	}

	// Verify HMAC tamper rejection
	if _, err := svc.Download(ctx, DownloadRequest{
		Provider: ProviderXunlei,
		Token:    byProv[ProviderXunlei].DownloadToken + "tamper",
	}); err == nil {
		t.Fatal("expected tampered token to be rejected")
	}

	// Xunlei GB18030 -> UTF-8
	xlSub, err := svc.Download(ctx, DownloadRequest{
		Provider: ProviderXunlei,
		Token:    byProv[ProviderXunlei].DownloadToken,
		Language: "zh",
	})
	if err != nil || xlSub.Format != "srt" || xlSub.Content != "1\n00:00:01,000 --> 00:00:03,000\n迅雷中文字幕\n" {
		t.Fatalf("xunlei download mismatch: sub=%+v err=%v", xlSub, err)
	}

	// Assrt filelist direct file extraction (bypasses .rar)
	assrtSub, err := svc.Download(ctx, DownloadRequest{
		Provider: ProviderAssrt,
		Token:    byProv[ProviderAssrt].DownloadToken,
		Language: "zh",
	})
	if err != nil || assrtSub.Format != "ass" || assrtSub.Content != "[Script Info]\nTitle: Assrt" {
		t.Fatalf("assrt download mismatch: sub=%+v err=%v", assrtSub, err)
	}

	// SubDL zip extraction + cache
	subdlSub, err := svc.Download(ctx, DownloadRequest{
		Provider: ProviderSubDL,
		Token:    byProv[ProviderSubDL].DownloadToken,
		Language: "zh",
	})
	if err != nil || subdlSub.Content != "1\n00:00:01,000 --> 00:00:02,000\nSubDL双语\n" {
		t.Fatalf("subdl download mismatch: sub=%+v err=%v", subdlSub, err)
	}
	subdlSub2, err := svc.Download(ctx, DownloadRequest{
		Provider: ProviderSubDL,
		Token:    byProv[ProviderSubDL].DownloadToken,
		Language: "zh",
	})
	if err != nil || !subdlSub2.Cached || subdlDownloadCalls.Load() != 1 {
		t.Fatalf("expected subdl file cache hit; cached=%v calls=%d err=%v", subdlSub2.Cached, subdlDownloadCalls.Load(), err)
	}

	// OpenSubtitles singleflight + cache
	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, dlErr := svc.Download(ctx, DownloadRequest{
				Provider: ProviderOpenSubtitles,
				Token:    byProv[ProviderOpenSubtitles].DownloadToken,
				Language: "zh",
			})
			if dlErr != nil || got.Content == "" {
				t.Errorf("concurrent os download failed: %v", dlErr)
			}
		}()
	}
	wg.Wait()
	if osDownloadCalls.Load() != 1 {
		t.Fatalf("expected singleflight to hit upstream once, got %d", osDownloadCalls.Load())
	}

	// Search cache hit
	res2, err := svc.Search(ctx, SearchRequest{
		Title:    "Inception",
		Kind:     "movie",
		TmdbID:   "27205",
		Language: "zh",
	})
	if err != nil || !res2.Cached || len(res2.Candidates) != 4 {
		t.Fatalf("expected cached search result, got cached=%v len=%d err=%v", res2.Cached, len(res2.Candidates), err)
	}

	// Connection test for Assrt
	if _, msg, err := svc.TestProviderConnection(ctx, ProviderAssrt, ProviderTestOverrides{}); err != nil || msg == "" {
		t.Fatalf("expected assrt connection test pass, msg=%q err=%v", msg, err)
	}
}
