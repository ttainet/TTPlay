package userdata

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"ttplay/media_library/internal/account"
	"ttplay/media_library/internal/db"
)

const (
	KVScopeHousehold = "household"
	KVScopeMember    = "member"

	MaxKVValueBytes     = 16 * 1024
	MaxKVEntriesPerScope = 5000
	MaxKVNamespaceLen   = 64
	MaxKVKeyLen         = 256
)

var validKVNamespaceRe = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)

type KVEntryView struct {
	Scope     string          `json:"scope"`
	Namespace string          `json:"namespace"`
	ItemKey   string          `json:"item_key"`
	WorkKey   string          `json:"work_key,omitempty"`
	Value     json.RawMessage `json:"value"`
	UpdatedAt int64           `json:"updated_at"`
	Deleted   bool            `json:"deleted"`
}

type UpsertKVRequest struct {
	WorkKey string          `json:"work_key,omitempty"`
	Value   json.RawMessage `json:"value"`
}

func normalizeKVTarget(p *account.Principal, scope, namespace, itemKey string, write bool) (normScope, targetMemberID, ns, key string, err error) {
	normScope = strings.ToLower(strings.TrimSpace(scope))
	ns = strings.TrimSpace(namespace)
	key = strings.TrimSpace(itemKey)

	switch normScope {
	case KVScopeHousehold:
		if write && !p.HasPerm(account.PermUploadFacts) && !p.HasPerm(account.PermManageSources) {
			return "", "", "", "", ErrForbidden
		}
		targetMemberID = ""
	case KVScopeMember:
		targetMemberID = strings.TrimSpace(p.MemberID)
		if targetMemberID == "" {
			return "", "", "", "", ErrUnauthorized
		}
	default:
		return "", "", "", "", fmt.Errorf("%w: invalid scope %q", ErrInvalidInput, scope)
	}

	if ns == "" || len(ns) > MaxKVNamespaceLen || !validKVNamespaceRe.MatchString(ns) {
		return "", "", "", "", fmt.Errorf("%w: invalid namespace", ErrInvalidInput)
	}
	if key == "" || len(key) > MaxKVKeyLen {
		return "", "", "", "", fmt.Errorf("%w: invalid key", ErrInvalidInput)
	}
	return normScope, targetMemberID, ns, key, nil
}

func (s *Service) ListKV(p *account.Principal, namespace string, sinceUpdatedAt int64, includeDeleted bool) ([]KVEntryView, error) {
	if p == nil {
		return nil, ErrUnauthorized
	}

	conds := []string{
		"household_id = ?",
		"((scope = 'household' AND member_id = '') OR (scope = 'member' AND member_id = ?))",
	}
	args := []any{p.HouseholdID, p.MemberID}

	if ns := strings.TrimSpace(namespace); ns != "" {
		conds = append(conds, "namespace = ?")
		args = append(args, ns)
	}
	if sinceUpdatedAt > 0 {
		conds = append(conds, "updated_at > ?")
		args = append(args, sinceUpdatedAt)
	}
	if !includeDeleted {
		conds = append(conds, "deleted = 0")
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT scope, namespace, item_key, COALESCE(work_key, ''), value_json, updated_at, deleted
		FROM sync_kv
		WHERE `+strings.Join(conds, " AND ")+`
		ORDER BY updated_at ASC, namespace ASC, item_key ASC`,
		args...,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]KVEntryView, 0)
	for rows.Next() {
		var (
			ev      KVEntryView
			valRaw  string
			deleted int
		)
		if err := rows.Scan(&ev.Scope, &ev.Namespace, &ev.ItemKey, &ev.WorkKey, &valRaw, &ev.UpdatedAt, &deleted); err != nil {
			return nil, err
		}
		ev.Deleted = deleted != 0
		if strings.TrimSpace(valRaw) == "" {
			valRaw = "{}"
		}
		ev.Value = json.RawMessage(valRaw)
		out = append(out, ev)
	}
	return out, rows.Err()
}

func (s *Service) LoadKVEntry(householdID, memberID, scope, namespace, itemKey string) (KVEntryView, error) {
	normScope := strings.ToLower(strings.TrimSpace(scope))
	targetMember := ""
	if normScope == KVScopeMember {
		targetMember = strings.TrimSpace(memberID)
	} else if normScope != KVScopeHousehold {
		return KVEntryView{}, fmt.Errorf("%w: invalid scope", ErrInvalidInput)
	}

	var (
		ev      KVEntryView
		valRaw  string
		deleted int
	)
	err := s.store.ReadDB().QueryRow(`
		SELECT scope, namespace, item_key, COALESCE(work_key, ''), value_json, updated_at, deleted
		FROM sync_kv
		WHERE household_id = ? AND scope = ? AND member_id = ? AND namespace = ? AND item_key = ?`,
		householdID, normScope, targetMember, strings.TrimSpace(namespace), strings.TrimSpace(itemKey),
	).Scan(&ev.Scope, &ev.Namespace, &ev.ItemKey, &ev.WorkKey, &valRaw, &ev.UpdatedAt, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return KVEntryView{}, ErrNotFound
	}
	if err != nil {
		return KVEntryView{}, err
	}
	ev.Deleted = deleted != 0
	if strings.TrimSpace(valRaw) == "" {
		valRaw = "{}"
	}
	ev.Value = json.RawMessage(valRaw)
	return ev, nil
}

func (s *Service) UpsertKV(p *account.Principal, scope, namespace, itemKey string, req UpsertKVRequest) (KVEntryView, error) {
	if p == nil {
		return KVEntryView{}, ErrUnauthorized
	}
	normScope, targetMember, ns, key, err := normalizeKVTarget(p, scope, namespace, itemKey, true)
	if err != nil {
		return KVEntryView{}, err
	}

	rawTrimmed := bytes.TrimSpace(req.Value)
	if len(rawTrimmed) == 0 {
		return KVEntryView{}, fmt.Errorf("%w: value is required", ErrInvalidInput)
	}
	if len(rawTrimmed) > MaxKVValueBytes {
		return KVEntryView{}, fmt.Errorf("%w: value exceeds %d bytes", ErrInvalidInput, MaxKVValueBytes)
	}
	var compactBuf bytes.Buffer
	if err := json.Compact(&compactBuf, rawTrimmed); err != nil {
		return KVEntryView{}, fmt.Errorf("%w: value must be valid JSON", ErrInvalidInput)
	}
	valueJSON := compactBuf.String()

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return KVEntryView{}, err
	}
	defer func() { _ = tx.Rollback() }()

	var existing int
	qErr := tx.QueryRow(`
		SELECT 1 FROM sync_kv
		WHERE household_id = ? AND scope = ? AND member_id = ? AND namespace = ? AND item_key = ? AND deleted = 0`,
		p.HouseholdID, normScope, targetMember, ns, key,
	).Scan(&existing)
	if errors.Is(qErr, sql.ErrNoRows) {
		var count int
		if err := tx.QueryRow(`
			SELECT COUNT(*) FROM sync_kv
			WHERE household_id = ? AND scope = ? AND member_id = ? AND deleted = 0`,
			p.HouseholdID, normScope, targetMember,
		).Scan(&count); err != nil {
			return KVEntryView{}, err
		}
		if count >= MaxKVEntriesPerScope {
			return KVEntryView{}, fmt.Errorf("%w: kv quota exceeded (%d)", ErrInvalidInput, MaxKVEntriesPerScope)
		}
	} else if qErr != nil {
		return KVEntryView{}, qErr
	}

	if _, err := tx.Exec(`
		INSERT INTO sync_kv(household_id, scope, member_id, namespace, item_key, work_key, value_json, updated_at, deleted)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
		ON CONFLICT(household_id, scope, member_id, namespace, item_key) DO UPDATE SET
			work_key   = excluded.work_key,
			value_json = excluded.value_json,
			updated_at = excluded.updated_at,
			deleted    = 0`,
		p.HouseholdID, normScope, targetMember, ns, key, nullableStr(req.WorkKey), valueJSON, nowMs,
	); err != nil {
		return KVEntryView{}, err
	}

	var memPtr *string
	if normScope == KVScopeMember {
		mid := targetMember
		memPtr = &mid
	}
	if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "kv", db.EncodeKVChangeID(normScope, ns, key), "upsert", nowMs); err != nil {
		return KVEntryView{}, err
	}
	if err := tx.Commit(); err != nil {
		return KVEntryView{}, err
	}

	if s.hub != nil {
		evData := map[string]any{
			"entity":    "kv",
			"scope":     normScope,
			"namespace": ns,
			"item_key":  key,
		}
		if normScope == KVScopeHousehold {
			s.hub.PublishToHousehold(p.HouseholdID, "userdata.changed", evData)
		} else {
			s.hub.PublishToMember(p.HouseholdID, targetMember, "userdata.changed", evData)
		}
	}
	return s.LoadKVEntry(p.HouseholdID, targetMember, normScope, ns, key)
}

func (s *Service) DeleteKV(p *account.Principal, scope, namespace, itemKey string) error {
	if p == nil {
		return ErrUnauthorized
	}
	normScope, targetMember, ns, key, err := normalizeKVTarget(p, scope, namespace, itemKey, true)
	if err != nil {
		return err
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE sync_kv
		SET value_json = '{}', updated_at = ?, deleted = 1
		WHERE household_id = ? AND scope = ? AND member_id = ? AND namespace = ? AND item_key = ? AND deleted = 0`,
		nowMs, p.HouseholdID, normScope, targetMember, ns, key,
	)
	if err != nil {
		return err
	}
	affected, _ := res.RowsAffected()
	if affected > 0 {
		var memPtr *string
		if normScope == KVScopeMember {
			mid := targetMember
			memPtr = &mid
		}
		if _, err := db.AppendChangeTx(tx, p.HouseholdID, memPtr, "kv", db.EncodeKVChangeID(normScope, ns, key), "delete", nowMs); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	if affected > 0 && s.hub != nil {
		evData := map[string]any{
			"entity":    "kv",
			"scope":     normScope,
			"namespace": ns,
			"item_key":  key,
			"deleted":   true,
		}
		if normScope == KVScopeHousehold {
			s.hub.PublishToHousehold(p.HouseholdID, "userdata.changed", evData)
		} else {
			s.hub.PublishToMember(p.HouseholdID, targetMember, "userdata.changed", evData)
		}
	}
	return nil
}
