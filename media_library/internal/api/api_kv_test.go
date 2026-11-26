package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"ttplay/media_library/internal/db"
)

func TestKVEndpointsChangesAndListsIncludeEntries(t *testing.T) {
	srv, _, _ := newTestAPIServer(t, "")

	tok1, _, _, _ := mustRegisterAndLoginDevice(t, srv, "kv_user1", db.DeviceClassDesktop, "10.10.0.1:1000", true)
	tok2, _, _, _ := mustRegisterAndLoginDevice(t, srv, "kv_user2", db.DeviceClassDesktop, "10.10.0.2:1000", true)

	snapRes := doJSONReq(srv, http.MethodGet, "/api/v1/library/snapshot?kind=movie", tok1, "", nil, nil)
	if snapRes.Code != http.StatusOK {
		t.Fatalf("snapshot: %d %s", snapRes.Code, snapRes.Body.String())
	}
	var snapBody struct {
		SnapshotSeq int64 `json:"snapshot_seq"`
	}
	_ = json.Unmarshal(snapRes.Body.Bytes(), &snapBody)

	// PUT household + member KV with URL-escaped colon keys
	showWK := "tmdb:show:999"
	encKey := url.PathEscape(showWK)
	putSkip := doJSONReq(srv, http.MethodPut, "/api/v1/kv/household/work.skip/"+encKey, tok1, "", nil, map[string]any{
		"work_key": showWK,
		"value": map[string]any{
			"introEnabled": true,
			"introStartMs": 1000,
			"introEndMs":   88000,
		},
	})
	if putSkip.Code != http.StatusOK {
		t.Fatalf("put household kv: %d %s", putSkip.Code, putSkip.Body.String())
	}

	putSpeed := doJSONReq(srv, http.MethodPut, "/api/v1/kv/member/work.speed/"+encKey, tok1, "", nil, map[string]any{
		"work_key": showWK,
		"value":    map[string]any{"speed": 1.5},
	})
	if putSpeed.Code != http.StatusOK {
		t.Fatalf("put member kv: %d %s", putSpeed.Code, putSpeed.Body.String())
	}

	// GET /api/v1/kv with namespace filter and cross-tenant isolation
	getAll := doJSONReq(srv, http.MethodGet, "/api/v1/kv", tok1, "", nil, nil)
	if getAll.Code != http.StatusOK || !strings.Contains(getAll.Body.String(), "88000") || !strings.Contains(getAll.Body.String(), "1.5") {
		t.Fatalf("get kv: %d %s", getAll.Code, getAll.Body.String())
	}
	getFiltered := doJSONReq(srv, http.MethodGet, "/api/v1/kv?namespace=work.speed", tok1, "", nil, nil)
	if getFiltered.Code != http.StatusOK || !strings.Contains(getFiltered.Body.String(), "1.5") || strings.Contains(getFiltered.Body.String(), "work.skip") {
		t.Fatalf("get filtered kv: %d %s", getFiltered.Code, getFiltered.Body.String())
	}
	getCross := doJSONReq(srv, http.MethodGet, "/api/v1/kv", tok2, "", nil, nil)
	if getCross.Code != http.StatusOK || strings.Contains(getCross.Body.String(), showWK) {
		t.Fatalf("cross-tenant kv leaked: %d %s", getCross.Code, getCross.Body.String())
	}

	// DELETE /api/v1/kv creates tombstone and emits delete in /library/changes
	delSpeed := doJSONReq(srv, http.MethodDelete, "/api/v1/kv/member/work.speed/"+encKey, tok1, "", nil, nil)
	if delSpeed.Code != http.StatusOK {
		t.Fatalf("delete kv: %d %s", delSpeed.Code, delSpeed.Body.String())
	}
	withDel := doJSONReq(srv, http.MethodGet, "/api/v1/kv?namespace=work.speed&include_deleted=1", tok1, "", nil, nil)
	if withDel.Code != http.StatusOK || !strings.Contains(withDel.Body.String(), `"deleted":true`) {
		t.Fatalf("include_deleted kv missing tombstone: %d %s", withDel.Code, withDel.Body.String())
	}

	chgRes := doJSONReq(srv, http.MethodGet, "/api/v1/library/changes?since_seq="+strconv.FormatInt(snapBody.SnapshotSeq, 10), tok1, "", nil, nil)
	if chgRes.Code != http.StatusOK {
		t.Fatalf("changes: %d %s", chgRes.Code, chgRes.Body.String())
	}
	var chgData struct {
		Changes []struct {
			Entity string         `json:"entity"`
			Op     string         `json:"op"`
			Data   map[string]any `json:"data"`
		} `json:"changes"`
	}
	_ = json.Unmarshal(chgRes.Body.Bytes(), &chgData)

	var sawUpsert, sawDelete bool
	for _, c := range chgData.Changes {
		if c.Entity != "kv" {
			continue
		}
		if c.Op == "upsert" && c.Data["namespace"] == "work.skip" && c.Data["work_key"] == showWK {
			sawUpsert = true
		}
		if c.Op == "delete" && c.Data["scope"] == "member" && c.Data["namespace"] == "work.speed" && c.Data["item_key"] == showWK && c.Data["deleted"] == true {
			sawDelete = true
		}
	}
	if !sawUpsert || !sawDelete {
		t.Fatalf("expected hydrated kv upsert & delete in /library/changes, got sawUpsert=%v sawDelete=%v changes=%+v", sawUpsert, sawDelete, chgData.Changes)
	}

	// Lists CRUD + /api/v1/lists?include_entries=1
	createList := doJSONReq(srv, http.MethodPost, "/api/v1/lists", tok1, "", nil, map[string]any{
		"kind": "collection", "title": "Studio Classics", "shared": true,
	})
	if createList.Code != http.StatusOK {
		t.Fatalf("create list: %d %s", createList.Code, createList.Body.String())
	}
	var listResp struct {
		List struct {
			ID string `json:"id"`
		} `json:"list"`
	}
	_ = json.Unmarshal(createList.Body.Bytes(), &listResp)
	addEntry := doJSONReq(srv, http.MethodPost, "/api/v1/lists/"+listResp.List.ID+"/entries", tok1, "", nil, map[string]any{
		"work_key": "tmdb:movie:27205",
	})
	if addEntry.Code != http.StatusOK {
		t.Fatalf("add entry: %d %s", addEntry.Code, addEntry.Body.String())
	}
	listsInc := doJSONReq(srv, http.MethodGet, "/api/v1/lists?include_entries=1", tok1, "", nil, nil)
	if listsInc.Code != http.StatusOK || !strings.Contains(listsInc.Body.String(), "Studio Classics") || !strings.Contains(listsInc.Body.String(), "tmdb:movie:27205") {
		t.Fatalf("lists include_entries=1 missing entries: %d %s", listsInc.Code, listsInc.Body.String())
	}
}
