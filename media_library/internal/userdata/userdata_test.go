package userdata

import (
	"testing"
	"time"

	"ttplay/media_library/internal/account"
	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/events"
	"ttplay/media_library/internal/vault"
)

func TestUserDataProgressFavoritesPrefsListsAndMigration(t *testing.T) {
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	now := store.NowMs()
	_, _ = store.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES ('acc1', 'u1', 's', 'h', ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES ('hh1', 'acc1', 'Home', ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES ('m1', 'hh1', 'User1', 'owner', 63, ?, ?)`, now, now)
	_, _ = store.DB().Exec(`INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at) VALUES ('src1', 'hh1', 'quark', 'Q', 'qk1', 'm1', 'd1', ?, ?)`, now, now)
	res, err := store.DB().Exec(`INSERT INTO media_files(household_id, source_id, path, role, state, match_state, added_at, updated_at, last_seen_at) VALUES ('hh1', 'src1', '/Movies/Unmatched.mkv', 'video', 'active', 'unmatched', ?, ?, ?)`, now, now, now)
	if err != nil {
		t.Fatal(err)
	}
	fileID, _ := res.LastInsertId()

	hub := events.NewHub()
	svc := NewService(store, hub)
	p := &account.Principal{
		HouseholdID: "hh1",
		MemberID:    "m1",
		Role:        account.RoleOwner,
		Permissions: account.PermAll,
	}

	// 1. G3 unmatched file progress
	fp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		FileID:     &fileID,
		PositionMs: 42000,
	})
	if err != nil || fp.ProgressKey != "file:1" || fp.PositionMs != 42000 {
		t.Fatalf("unexpected file progress: %+v err=%v", fp, err)
	}

	// 2. Work progress + continue watching + hide
	s1, e2 := 1, 2
	wp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey:       "douban:show:999",
		SeasonNumber:  &s1,
		EpisodeNumber: &e2,
		PositionMs:    90000,
	})
	if err != nil || wp.ProgressKey != "douban:show:999:s1:e2" {
		t.Fatalf("unexpected episode progress: %+v err=%v", wp, err)
	}
	cw, err := svc.ListContinueWatching(p, 10)
	if err != nil || len(cw) != 2 {
		t.Fatalf("expected 2 continue watching items, got %d err=%v", len(cw), err)
	}
	if err := svc.HideFromContinue(p, fp.ProgressKey); err != nil {
		t.Fatal(err)
	}
	cw2, _ := svc.ListContinueWatching(p, 10)
	if len(cw2) != 1 || cw2[0].ProgressKey != "douban:show:999:s1:e2" {
		t.Fatalf("expected 1 continue watching item after hide, got %+v", cw2)
	}

	// 3. Favorites, work prefs, list & explicit G2 work-data migration
	if _, err := svc.AddFavorite(p, "douban:show:999"); err != nil {
		t.Fatal(err)
	}
	tr := true
	iEnd := int64(85000)
	evCh, unsub := hub.Subscribe("hh1", "m2")
	defer unsub()
	if _, err := svc.UpsertHouseholdWorkPrefs(p, "douban:show:999", HouseholdWorkPrefsInput{
		IntroEnabled: &tr,
		IntroEndMs:   &iEnd,
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-evCh:
		if ev.Type != "userdata.changed" {
			t.Fatalf("unexpected event type: %+v", ev)
		}
		data, _ := ev.Data.(map[string]any)
		if data["entity"] != "work_prefs" || data["work_key"] != "douban:show:999" {
			t.Fatalf("unexpected event data: %+v", ev.Data)
		}
	default:
		t.Fatalf("expected household userdata.changed SSE event for UpsertHouseholdWorkPrefs")
	}
	audio := "ja"
	spd := 1.5
	prefs, err := svc.UpsertMemberWorkPrefs(p, "douban:show:999", MemberWorkPrefsInput{
		PreferredAudioLang: &audio,
		PlaybackSpeed:      &spd,
	})
	if err != nil || !prefs.IntroEnabled || prefs.IntroEndMs != 85000 || prefs.PreferredAudioLang != "ja" || prefs.PlaybackSpeed != 1.5 {
		t.Fatalf("unexpected merged prefs: %+v err=%v", prefs, err)
	}

	list, err := svc.ListWorkPrefs(p)
	if err != nil || len(list) != 1 || list[0].WorkKey != "douban:show:999" || !list[0].IntroEnabled || list[0].IntroEndMs != 85000 || list[0].PreferredAudioLang != "ja" {
		t.Fatalf("unexpected ListWorkPrefs: %+v err=%v", list, err)
	}
	otherHH := &account.Principal{HouseholdID: "hh-other", MemberID: "m-other", Role: account.RoleOwner, Permissions: account.PermAll}
	otherList, err := svc.ListWorkPrefs(otherHH)
	if err != nil || len(otherList) != 0 {
		t.Fatalf("expected empty ListWorkPrefs for other household, got %+v err=%v", otherList, err)
	}

	lst, err := svc.CreateList(p, CreateListRequest{Kind: "watchlist", Title: "My Watchlist"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.AddListEntry(p, lst.ID, AddListEntryRequest{WorkKey: "douban:show:999"}); err != nil {
		t.Fatal(err)
	}

	if err := svc.MigrateWorkData(p, "douban:show:999", "tmdb:show:100"); err != nil {
		t.Fatal(err)
	}
	favs, _ := svc.ListFavorites(p)
	if len(favs) != 1 || favs[0].WorkKey != "tmdb:show:100" {
		t.Fatalf("expected favorite migrated to tmdb:show:100, got %+v", favs)
	}
	det, _ := svc.GetList(p, lst.ID)
	if len(det.Entries) != 1 || det.Entries[0].WorkKey != "tmdb:show:100" {
		t.Fatalf("expected list entry migrated to tmdb:show:100, got %+v", det.Entries)
	}

	// 4. >=90% progress does not auto-mark watched; explicit watched=true marks watched, Next-Up hide upserts and emits SSE, and CW dedups per work_key
	dur := int64(1000000)
	s1e1 := 1
	unwatchedHighEp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey:       "tmdb:show:203483",
		SeasonNumber:  &s1,
		EpisodeNumber: &s1e1,
		PositionMs:    950000,
		DurationMs:    &dur,
	})
	if err != nil || unwatchedHighEp.Watched || unwatchedHighEp.PositionMs != 950000 || unwatchedHighEp.PlayCount != 0 {
		t.Fatalf("expected >=90%% progress without watched flag to stay unwatched, got %+v err=%v", unwatchedHighEp, err)
	}
	watchedTrue := true
	finishedEp, err := svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey:       "tmdb:show:203483",
		SeasonNumber:  &s1,
		EpisodeNumber: &s1e1,
		PositionMs:    0,
		DurationMs:    &dur,
		Watched:       &watchedTrue,
	})
	if err != nil || !finishedEp.Watched || finishedEp.PositionMs != 0 || finishedEp.PlayCount != 1 {
		t.Fatalf("expected explicit watched=true to mark watched, got %+v err=%v", finishedEp, err)
	}

	// Multiple in-progress episodes of the same work_key collapse to 1 CW entry before LIMIT
	e3, e4 := 3, 4
	baseTime := time.UnixMilli(now + 1000)
	svc.SetClock(func() time.Time { return baseTime })
	_, _ = svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey: "tmdb:show:500", SeasonNumber: &s1, EpisodeNumber: &e3, PositionMs: 10000, DurationMs: &dur,
	})
	svc.SetClock(func() time.Time { return baseTime.Add(time.Second) })
	_, _ = svc.UpsertProgress(p, UpsertProgressRequest{
		WorkKey: "tmdb:show:500", SeasonNumber: &s1, EpisodeNumber: &e4, PositionMs: 20000, DurationMs: &dur,
	})
	cwDedup, err := svc.ListContinueWatching(p, 10)
	if err != nil {
		t.Fatal(err)
	}
	show500Count := 0
	for _, item := range cwDedup {
		if item.WorkKey == "tmdb:show:500" {
			show500Count++
			if item.EpisodeNumber != 4 {
				t.Fatalf("expected latest episode 4 for tmdb:show:500, got %+v", item)
			}
		}
		if item.WorkKey == "tmdb:show:203483" {
			t.Fatalf("finished episode must not appear in ListContinueWatching: %+v", item)
		}
	}
	if show500Count != 1 {
		t.Fatalf("expected 1 deduped CW entry for tmdb:show:500, got %d", show500Count)
	}

	// HideFromContinue on a Next Up episode with no prior row succeeds and emits userdata.changed
	m1Ch, m1Unsub := hub.Subscribe("hh1", "m1")
	defer m1Unsub()
	if err := svc.HideFromContinue(p, "tmdb:show:203483:s1:e2"); err != nil {
		t.Fatalf("HideFromContinue for Next Up episode failed: %v", err)
	}
	select {
	case ev := <-m1Ch:
		if ev.Type != "userdata.changed" {
			t.Fatalf("unexpected event type after HideFromContinue: %+v", ev)
		}
	default:
		t.Fatalf("expected userdata.changed SSE event for HideFromContinue")
	}
	nextUpHidden, err := svc.GetProgressByKey(p.HouseholdID, p.MemberID, "tmdb:show:203483:s1:e2")
	if err != nil || !nextUpHidden.HiddenFromContinue || nextUpHidden.WorkKey != "tmdb:show:203483" || nextUpHidden.SeasonNumber != 1 || nextUpHidden.EpisodeNumber != 2 {
		t.Fatalf("unexpected upserted Next Up hide row: %+v err=%v", nextUpHidden, err)
	}
}
