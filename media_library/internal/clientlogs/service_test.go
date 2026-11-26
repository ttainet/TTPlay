package clientlogs

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"

	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/vault"
)

func openTestService(t *testing.T) (*Service, *db.Store, func(time.Duration)) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	now := time.Date(2026, 11, 26, 16, 30, 0, 0, time.UTC) // 2026-11-27 00:30 in UTC+8
	svc := NewService(store)
	svc.SetClock(func() time.Time { return now })
	return svc, store, func(d time.Duration) { now = now.Add(d) }
}

func TestParseDiagnosticMetadataAndHeaders(t *testing.T) {
	svc, _, _ := openTestService(t)

	androidTVLog := `TTPlay v2.26.15 (175) bf10e2b
Android 11 (API 30)
Xiaomi MiBox4
TV mode: yes (android.software.leanback)
Renderer: skia
Background: Restricted
Effects: reduced
Display: 1920x1080
Video decoders: MediaCodec
---
[12:00:00.000] [INFO] Starting playback
[12:00:01.000] [ERROR] Quark buffer stalled`

	rec, err := svc.Create(UploadInput{
		Content:  androidTVLog,
		ClientIP: "203.0.113.5",
	})
	if err != nil {
		t.Fatalf("Create android TV log: %v", err)
	}
	if len(rec.ID) != shortIDLen {
		t.Fatalf("expected %d-char ID, got %q", shortIDLen, rec.ID)
	}
	if rec.Platform != "android" || !rec.IsTV || rec.DeviceName != "Xiaomi MiBox4" || rec.AppVersion != "2.26.15 (175) bf10e2b" {
		t.Fatalf("unexpected parsed android TV metadata: %+v", rec)
	}
	if !strings.Contains(rec.Preview, "Quark buffer stalled") {
		t.Fatalf("expected error preview to be prioritized, got %q", rec.Preview)
	}

	startupLog := `Plezy startup failure
Version: 2.26.15+175
Platform: windows 11
When: 2026-11-26T16:30:00.000Z
Phase: database
Error: StateError
Repair offered: no
Message: sqlite could not open`
	recStartup, err := svc.Create(UploadInput{
		Content:    startupLog,
		DeviceName: url.PathEscape("客厅主控电脑"),
	})
	if err != nil {
		t.Fatalf("Create startup log: %v", err)
	}
	if recStartup.Source != "startup_failure" || recStartup.Platform != "windows" || recStartup.AppVersion != "2.26.15+175" || recStartup.DeviceName != "客厅主控电脑" {
		t.Fatalf("unexpected startup metadata: %+v", recStartup)
	}
}

func TestListFiltersTimezoneAndRetention(t *testing.T) {
	svc, _, advance := openTestService(t)

	// Log 1: 2026-11-26 16:30 UTC == 2026-11-27 00:30 UTC+8
	r1, err := svc.Create(UploadInput{
		Content:    "TTPlay v2.26.15 (175)\nWindows 11\nWorkPC\n---\n[00:30:00.000] [INFO] win log",
		DeviceName: "WorkPC",
		Platform:   "windows",
	})
	if err != nil {
		t.Fatal(err)
	}

	// Advance 25 hours -> 2026-11-27 17:30 UTC == 2026-11-28 01:30 UTC+8
	advance(25 * time.Hour)
	r2, err := svc.Create(UploadInput{
		Content:    "TTPlay v2.26.15 (175)\nAndroid 13 (API 33)\nSony Bravia\nTV mode: yes\n---\n[01:30:00.000] [WARN] tv log",
		DeviceName: "Sony Bravia",
		Platform:   "android",
	})
	if err != nil {
		t.Fatal(err)
	}

	// UTC+8 offset from JS getTimezoneOffset() is -480.
	// On UTC+8: r1 is 2026-11-27, r2 is 2026-11-28.
	tzAsia := -480
	resNov27, err := svc.List(ListFilter{
		DateFrom:    "2026-11-27",
		DateTo:      "2026-11-27",
		TZOffsetMin: &tzAsia,
	})
	if err != nil {
		t.Fatal(err)
	}
	if resNov27.Total != 1 || resNov27.Items[0].ID != r1.ID {
		t.Fatalf("expected only r1 for 2026-11-27 UTC+8, got total=%d items=%+v", resNov27.Total, resNov27.Items)
	}

	// On UTC (tzOffset = 0), 2026-11-26 16:30 UTC falls on 2026-11-26.
	tzUTC := 0
	resUTC26, err := svc.List(ListFilter{
		DateFrom:    "2026-11-26",
		DateTo:      "2026-11-26",
		TZOffsetMin: &tzUTC,
	})
	if err != nil || resUTC26.Total != 1 || resUTC26.Items[0].ID != r1.ID {
		t.Fatalf("expected r1 for 2026-11-26 UTC, got err=%v total=%d", err, resUTC26.Total)
	}

	// Device & TV filters
	isTV := true
	resTV, err := svc.List(ListFilter{Device: "Sony Bravia", IsTV: &isTV})
	if err != nil || resTV.Total != 1 || resTV.Items[0].ID != r2.ID {
		t.Fatalf("expected Sony Bravia TV log, got err=%v total=%d", err, resTV.Total)
	}
	if len(resTV.Devices) != 2 || len(resTV.Platforms) != 2 {
		t.Fatalf("expected facet lists for all stored logs, devices=%v platforms=%v", resTV.Devices, resTV.Platforms)
	}

	// Case-insensitive Get
	detail, err := svc.Get(strings.ToUpper(r2.ID))
	if err != nil || !strings.Contains(detail.Content, "tv log") {
		t.Fatalf("case-insensitive Get failed: err=%v detail=%+v", err, detail)
	}

	// Advance 32 days -> inserting new log prunes expired logs (> 30 days)
	advance(32 * 24 * time.Hour)
	r3, err := svc.Create(UploadInput{
		Content: "TTPlay v2.26.15\niOS 18.0\niPhone16,2\n---\n[10:00:00.000] [INFO] fresh",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Get(r1.ID); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("expected expired r1 to be pruned, got err=%v", err)
	}
	if _, err := svc.Get(r3.ID); err != nil {
		t.Fatalf("expected r3 to exist: %v", err)
	}

	// Prune by remaining device/days
	if _, err := svc.Prune(0, "", false); !errors.Is(err, db.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput on empty prune args, got %v", err)
	}
	deleted, err := svc.Prune(0, "", true)
	if err != nil || deleted != 1 {
		t.Fatalf("expected prune all=true to delete 1 row, got deleted=%d err=%v", deleted, err)
	}

	// Invalid date filter
	if _, err := svc.List(ListFilter{DateFrom: fmt.Sprintf("2026/11/26")}); !errors.Is(err, db.ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput on malformed date_from, got %v", err)
	}
}
