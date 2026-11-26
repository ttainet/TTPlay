package db

import (
	"net/url"
	"strings"
)

// EncodeKVChangeID encodes a (scope, namespace, itemKey) tuple for change_log.entity_id.
func EncodeKVChangeID(scope, namespace, itemKey string) string {
	return url.PathEscape(scope) + "|" + url.PathEscape(namespace) + "|" + url.PathEscape(itemKey)
}

// DecodeKVChangeID decodes a change_log.entity_id produced by EncodeKVChangeID.
func DecodeKVChangeID(entityID string) (scope, namespace, itemKey string, ok bool) {
	parts := strings.Split(entityID, "|")
	if len(parts) != 3 {
		return "", "", "", false
	}
	s, err1 := url.PathUnescape(parts[0])
	ns, err2 := url.PathUnescape(parts[1])
	k, err3 := url.PathUnescape(parts[2])
	if err1 != nil || err2 != nil || err3 != nil || s == "" || ns == "" || k == "" {
		return "", "", "", false
	}
	return s, ns, k, true
}
