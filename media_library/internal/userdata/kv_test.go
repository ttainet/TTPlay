package userdata

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"ttplay/media_library/internal/account"
	"ttplay/media_library/internal/db"
	"ttplay/media_library/internal/events"
	"ttplay/media_library/internal/vault"
)

func openUserdataTestService(t *testing.T) (*db.Store, *events.Hub, *Service) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	now := store.NowMs()
	_, _ = store.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES ('acc1', 'u1', 's', 'h', ?, ?), ('acc2', 'u2', 's', 'h', ?, ?)`, now, now, now, now)
	_, _ = store.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES ('hh1', 'acc1', 'Home1', ?, ?), ('hh2', 'acc2', 'Home2', ?, ?)`, now, now, now, now)
	_, _ = store.DB().Exec(`INSERT INTO members(id, household_id, nickname, role, permissions, created_at, updated_at) VALUES ('m1', 'hh1', 'Owner', 'owner', 63, ?, ?), ('m2', 'hh1', 'Child', 'member', 0, ?, ?), ('m3', 'hh2', 'Other', 'owner', 63, ?, ?)`, now, now, now, now, now, now)

	hub := events.NewHub()
	svc := NewService(store, hub)
	return store, hub, svc
}

func TestKVCRUDScopeRBACValidationAndSSE(t *testing.T) {
	_, hub, svc := openUserdataTestService(t)

	owner := &account.Principal{HouseholdID: "hh1", MemberID: "m1", Role: account.RoleOwner, Permissions: account.PermAll}
	child := &account.Principal{HouseholdID: "hh1", MemberID: "m2", Role: account.RoleMember, Permissions: 0}
	otherHH := &account.Principal{HouseholdID: "hh2", MemberID: "m3", Role: account.RoleOwner, Permissions: account.PermAll}

	chM2, unsubM2 := hub.Subscribe("hh1", "m2")
	defer unsubM2()
	chM1, unsubM1 := hub.Subscribe("hh1", "m1")
	defer unsubM1()

	// Household write broadcasts to all members in hh1, readable by child.
	var seqTime int64 = 1700000001000
	svc.nowFn = func() time.Time {
		seqTime += 10
		return time.UnixMilli(seqTime)
	}

	e1, err := svc.UpsertKV(owner, KVScopeHousehold, "work.skip", "tmdb:show:555", UpsertKVRequest{
		WorkKey: "tmdb:show:555",
		Value:   json.RawMessage(`{"introEnabled":true,"introStartMs":1000,"introEndMs":90000}`),
	})
	if err != nil {
		t.Fatalf("UpsertKV household: %v", err)
	}
	if e1.Scope != KVScopeHousehold || e1.Namespace != "work.skip" || e1.ItemKey != "tmdb:show:555" || e1.WorkKey != "tmdb:show:555" {
		t.Fatalf("unexpected UpsertKV result: %+v", e1)
	}

	select {
	case ev := <-chM2:
		data, _ := ev.Data.(map[string]any)
		if ev.Type != "userdata.changed" || data["entity"] != "kv" || data["scope"] != "household" || data["namespace"] != "work.skip" {
			t.Fatalf("unexpected household SSE event: %+v", ev)
		}
	default:
		t.Fatalf("expected household SSE event on child subscriber")
	}

	// Drain chM1
	select {
	case <-chM1:
	default:
	}

	// Child without PermUploadFacts/PermManageSources gets ErrForbidden on household write/delete,
	// but succeeds on member scope.
	if _, err := svc.UpsertKV(child, KVScopeHousehold, "work.skip", "tmdb:show:555", UpsertKVRequest{
		Value: json.RawMessage(`{"introEnabled":false}`),
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ErrForbidden for child household UpsertKV, got %v", err)
	}
	if err := svc.DeleteKV(child, KVScopeHousehold, "work.skip", "tmdb:show:555"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ErrForbidden for child household DeleteKV, got %v", err)
	}

	m1Entry, err := svc.UpsertKV(owner, KVScopeMember, "work.tracks", "tmdb:show:555", UpsertKVRequest{
		WorkKey: "tmdb:show:555",
		Value:   json.RawMessage(`{"audioLang":"ja"}`),
	})
	if err != nil {
		t.Fatalf("owner member UpsertKV: %v", err)
	}
	select {
	case ev := <-chM1:
		data, _ := ev.Data.(map[string]any)
		if data["entity"] != "kv" || data["scope"] != "member" {
			t.Fatalf("unexpected owner member SSE event: %+v", ev)
		}
	default:
		t.Fatalf("expected member SSE event on owner")
	}
	select {
	case ev := <-chM2:
		t.Fatalf("child should NOT receive owner's member SSE event, got %+v", ev)
	default:
	}

	if _, err := svc.UpsertKV(child, KVScopeMember, "work.tracks", "tmdb:show:555", UpsertKVRequest{
		WorkKey: "tmdb:show:555",
		Value:   json.RawMessage(`{"audioLang":"zh"}`),
	}); err != nil {
		t.Fatalf("child member UpsertKV: %v", err)
	}
	// Drain child SSE event
	select {
	case <-chM2:
	default:
	}

	// Isolation checks
	ownerList, err := svc.ListKV(owner, "", 0, false)
	if err != nil || len(ownerList) != 2 {
		t.Fatalf("expected 2 entries for owner (household + own member), got %d err=%v", len(ownerList), err)
	}
	childList, err := svc.ListKV(child, "work.tracks", 0, false)
	if err != nil || len(childList) != 1 || !strings.Contains(string(childList[0].Value), `"zh"`) {
		t.Fatalf("expected only child's track pref, got %+v err=%v", childList, err)
	}
	otherList, err := svc.ListKV(otherHH, "", 0, false)
	if err != nil || len(otherList) != 0 {
		t.Fatalf("other household leaked KV entries: %+v err=%v", otherList, err)
	}

	// Validation: invalid scope, namespace, key, malformed JSON, >16KB
	if _, err := svc.UpsertKV(owner, "global", "app.prefs", "k", UpsertKVRequest{Value: json.RawMessage(`{}`)}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected invalid scope error, got %v", err)
	}
	if _, err := svc.UpsertKV(owner, KVScopeMember, "bad/ns!", "k", UpsertKVRequest{Value: json.RawMessage(`{}`)}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected invalid namespace error, got %v", err)
	}
	if _, err := svc.UpsertKV(owner, KVScopeMember, "app.prefs", " ", UpsertKVRequest{Value: json.RawMessage(`{}`)}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected invalid key error, got %v", err)
	}
	if _, err := svc.UpsertKV(owner, KVScopeMember, "app.prefs", "k", UpsertKVRequest{Value: json.RawMessage(`{broken`)}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected invalid JSON error, got %v", err)
	}
	oversized := `{"pad":"` + strings.Repeat("a", MaxKVValueBytes) + `"}`
	if _, err := svc.UpsertKV(owner, KVScopeMember, "app.prefs", "k", UpsertKVRequest{Value: json.RawMessage(oversized)}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected >16KB ErrInvalidInput, got %v", err)
	}

	// sinceUpdatedAt & DeleteKV soft-delete tombstone
	sinceList, err := svc.ListKV(owner, "", m1Entry.UpdatedAt-1, false)
	if err != nil || len(sinceList) != 1 || sinceList[0].Namespace != "work.tracks" {
		t.Fatalf("expected sinceUpdatedAt to filter earlier household row, got %+v err=%v", sinceList, err)
	}

	if err := svc.DeleteKV(owner, KVScopeMember, "work.tracks", "tmdb:show:555"); err != nil {
		t.Fatalf("DeleteKV: %v", err)
	}
	select {
	case ev := <-chM1:
		data, _ := ev.Data.(map[string]any)
		if data["entity"] != "kv" || data["deleted"] != true {
			t.Fatalf("expected delete SSE event, got %+v", ev)
		}
	default:
		t.Fatalf("expected delete SSE event on owner")
	}
	// Repeat delete is idempotent
	if err := svc.DeleteKV(owner, KVScopeMember, "work.tracks", "tmdb:show:555"); err != nil {
		t.Fatalf("idempotent DeleteKV failed: %v", err)
	}

	activeAfterDel, _ := svc.ListKV(owner, "work.tracks", 0, false)
	if len(activeAfterDel) != 0 {
		t.Fatalf("expected 0 active work.tracks after delete, got %+v", activeAfterDel)
	}
	withTombstones, _ := svc.ListKV(owner, "work.tracks", 0, true)
	if len(withTombstones) != 1 || !withTombstones[0].Deleted {
		t.Fatalf("expected 1 tombstone entry with Deleted=true, got %+v", withTombstones)
	}
}

func TestListsWithEntriesSSEAndKVMigration(t *testing.T) {
	store, hub, svc := openUserdataTestService(t)

	owner := &account.Principal{HouseholdID: "hh1", MemberID: "m1", Role: account.RoleOwner, Permissions: account.PermAll}
	chM2, unsubM2 := hub.Subscribe("hh1", "m2")
	defer unsubM2()

	var ts int64 = 1700000005000
	svc.nowFn = func() time.Time {
		ts += 100
		return time.UnixMilli(ts)
	}

	// Shared collection list + sorted entries + SSE
	col, err := svc.CreateList(owner, CreateListRequest{Kind: "collection", Title: "Anime Picks", Shared: true})
	if err != nil {
		t.Fatal(err)
	}
	newTitle := "Anime Favorites"
	if _, err := svc.UpdateList(owner, col.ID, UpdateListRequest{Title: &newTitle}); err != nil {
		t.Fatal(err)
	}
	s2 := 10
	s1 := 2
	if _, err := svc.AddListEntry(owner, col.ID, AddListEntryRequest{WorkKey: "douban:show:111", SortOrder: &s2}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.AddListEntry(owner, col.ID, AddListEntryRequest{WorkKey: "tmdb:movie:222", SortOrder: &s1}); err != nil {
		t.Fatal(err)
	}

	// Drain SSE messages verifying we got list upsert events
	gotListEvent := false
	for {
		select {
		case ev := <-chM2:
			if data, ok := ev.Data.(map[string]any); ok && data["entity"] == "list" {
				gotListEvent = true
			}
		default:
			goto doneDrain
		}
	}
doneDrain:
	if !gotListEvent {
		t.Fatalf("expected list userdata.changed SSE events for shared collection")
	}

	withEntries, err := svc.ListListsWithEntries(owner, "collection")
	if err != nil || len(withEntries) != 1 {
		t.Fatalf("ListListsWithEntries failed: %+v err=%v", withEntries, err)
	}
	if withEntries[0].Title != "Anime Favorites" || len(withEntries[0].Entries) != 2 {
		t.Fatalf("unexpected ListListsWithEntries: %+v", withEntries[0])
	}
	// Sorted by sort_order ASC -> tmdb:movie:222 (2) before douban:show:111 (10)
	if withEntries[0].Entries[0].WorkKey != "tmdb:movie:222" {
		t.Fatalf("expected entries sorted by sort_order, got %+v", withEntries[0].Entries)
	}

	// KV migration by work_key (including LWW conflict merge & soft-delete of old key)
	if _, err := svc.UpsertKV(owner, KVScopeHousehold, "work.skip", "douban:show:111", UpsertKVRequest{
		WorkKey: "douban:show:111",
		Value:   json.RawMessage(`{"introEnabled":true,"introEndMs":77000}`),
	}); err != nil {
		t.Fatal(err)
	}
	// Newer target in work.tracks, older source in work.tracks -> target must win via updated_at LWW
	if _, err := svc.UpsertKV(owner, KVScopeMember, "work.tracks", "douban:show:111", UpsertKVRequest{
		WorkKey: "douban:show:111",
		Value:   json.RawMessage(`{"audioLang":"en"}`),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.UpsertKV(owner, KVScopeMember, "work.tracks", "tmdb:show:999", UpsertKVRequest{
		WorkKey: "tmdb:show:999",
		Value:   json.RawMessage(`{"audioLang":"ja"}`),
	}); err != nil {
		t.Fatal(err)
	}

	if err := svc.MigrateWorkData(owner, "douban:show:111", "tmdb:show:999"); err != nil {
		t.Fatalf("MigrateWorkData: %v", err)
	}

	// Verify household work.skip moved to tmdb:show:999 and old key soft-deleted
	oldSkip, err := svc.LoadKVEntry("hh1", "", KVScopeHousehold, "work.skip", "douban:show:111")
	if err != nil || !oldSkip.Deleted {
		t.Fatalf("expected old work.skip entry to be soft-deleted, got %+v err=%v", oldSkip, err)
	}
	newSkip, err := svc.LoadKVEntry("hh1", "", KVScopeHousehold, "work.skip", "tmdb:show:999")
	if err != nil || newSkip.Deleted || newSkip.WorkKey != "tmdb:show:999" || !strings.Contains(string(newSkip.Value), "77000") {
		t.Fatalf("expected migrated work.skip on tmdb:show:999, got %+v err=%v", newSkip, err)
	}
	// Verify newer target work.tracks kept "ja"
	mergedTracks, err := svc.LoadKVEntry("hh1", "m1", KVScopeMember, "work.tracks", "tmdb:show:999")
	if err != nil || !strings.Contains(string(mergedTracks.Value), `"ja"`) {
		t.Fatalf("expected LWW to keep newer target value \"ja\", got %+v err=%v", mergedTracks, err)
	}

	// Verify change_log contains both delete for old key and upsert for new key
	var delLogs, upLogs int
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE entity='kv' AND op='delete' AND household_id='hh1'`).Scan(&delLogs)
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM change_log WHERE entity='kv' AND op='upsert' AND household_id='hh1'`).Scan(&upLogs)
	if delLogs < 1 || upLogs < 3 {
		t.Fatalf("expected KV change_log entries after migration, got del=%d up=%d", delLogs, upLogs)
	}

	// Drain earlier KV SSE events before testing RemoveListEntry & DeleteList SSE
drainBeforeDel:
	for {
		select {
		case <-chM2:
		default:
			break drainBeforeDel
		}
	}

	// RemoveListEntry & DeleteList emit SSE
	if err := svc.RemoveListEntry(owner, col.ID, "tmdb:movie:222"); err != nil {
		t.Fatal(err)
	}
	if err := svc.DeleteList(owner, col.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-chM2:
		data, _ := ev.Data.(map[string]any)
		if data["entity"] != "list" {
			t.Fatalf("expected list SSE on RemoveListEntry/DeleteList, got %+v", ev)
		}
	default:
		t.Fatalf("expected list SSE event on RemoveListEntry/DeleteList")
	}
}
