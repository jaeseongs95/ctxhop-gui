//go:build windows

package main

import (
	"strings"
	"unicode/utf8"
)

// These internal keys are facts, never ownership or deletion authority. File
// inventory and approval must independently establish M -> R -> Q before use.
type storeApprovedMember struct {
	ID, Root string
	Rollouts []string
}
type storeRolloutKey struct{ Path, Thread, Rollout string }
type storeProofKeys struct {
	approved       []storeApprovedMember
	members, roots map[string]bool
	rollouts       map[string]string
	paths          map[string]storeRolloutKey
}
type storeKey struct{ Domain, ID string }
type storeRelation struct {
	Class, Scope string
	Owner        storeKey
	Related      *storeKey
}
type storeKeyEvidence struct {
	Kind      string
	Relations []storeRelation
}
type storeKeyColumn struct {
	Name              string
	Integer, Nullable bool
}

const storeKeyRowLimit = 10000
const storeKeyBufferLimit = 32 << 20

func newStoreProofKeys(approved []storeApprovedMember, paths []storeRolloutKey) (*storeProofKeys, error) {
	bad := func() error { return fail("engine_db_unknown", "승인 M-R-Q/strict rollout inventory key 오류") }
	if len(approved) == 0 || len(approved) > 2000 || len(paths) > 100000 {
		return nil, bad()
	}
	t := &storeProofKeys{members: map[string]bool{}, roots: map[string]bool{}, rollouts: map[string]string{}, paths: map[string]storeRolloutKey{}}
	for _, m := range approved {
		if !uuidRE.MatchString(m.ID) || !uuidRE.MatchString(m.Root) || t.members[m.ID] || len(m.Rollouts) == 0 {
			return nil, bad()
		}
		t.members[m.ID], t.roots[m.Root] = true, true
		copy := storeApprovedMember{ID: m.ID, Root: m.Root, Rollouts: append([]string(nil), m.Rollouts...)}
		t.approved = append(t.approved, copy)
		for _, r := range m.Rollouts {
			if !uuidRE.MatchString(r) || t.rollouts[r] != "" || len(t.rollouts) >= 100000 {
				return nil, bad()
			}
			t.rollouts[r] = m.ID
		}
	}
	for _, m := range t.approved {
		if !t.members[m.Root] {
			return nil, bad()
		} // unverified child-only bundles remain blocked.
		for _, r := range m.Rollouts {
			if t.members[r] && r != m.ID {
				return nil, bad()
			}
		}
	}
	for _, p := range paths {
		if !validStoreKeyText(p.Path, 8192) || p.Path == "" || !uuidRE.MatchString(p.Thread) || !uuidRE.MatchString(p.Rollout) {
			return nil, bad()
		}
		if _, exists := t.paths[p.Path]; exists {
			return nil, bad()
		}
		if owner := t.rollouts[p.Rollout]; owner != "" && owner != p.Thread {
			return nil, bad()
		}
		t.paths[p.Path] = p
	}
	return t, nil
}

func validStoreKeyText(s string, max int) bool {
	return len(s) <= max && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}
func threadStoreKey(s string) storeKey { return storeKey{"thread", s} }
func (t *storeProofKeys) historyKey(id string) *storeKey {
	if t.members[id] {
		key := threadStoreKey(id)
		return &key
	}
	if t.rollouts[id] != "" {
		key := storeKey{"rollout", id}
		return &key
	}
	return nil
}
func (t *storeProofKeys) pairScope(owner string, peer *storeKey) string {
	if peer == nil {
		if t.members[owner] {
			return "active"
		}
		return ""
	}
	a, b := t.members[owner], t.members[peer.ID]
	switch {
	case a && b:
		return "internal"
	case a:
		return "externalOutgoing"
	case b:
		return "externalIncoming"
	}
	return ""
}
func storeTextColumn(name string, nullable bool) storeKeyColumn {
	return storeKeyColumn{Name: name, Nullable: nullable}
}
func storeIntColumn(name string, nullable bool) storeKeyColumn {
	return storeKeyColumn{Name: name, Integer: true, Nullable: nullable}
}
func storeColumnTextLimit(name string) int {
	switch name {
	case "source", "rollout_path", "author":
		return 8192
	case "request_id":
		return 549
	case "target":
		return 1024
	}
	return 256
}

// The native scanner and mock scanner pass the same exact typed cells. This
// reader does not seal schemas, open databases or certify canonical metadata.
func readStoreKeyRelations(kind string, t *storeProofKeys, scan func(string, []storeKeyColumn) ([][]any, error)) (storeKeyEvidence, error) {
	proof := storeKeyEvidence{Kind: kind}
	bad := func() error { return fail("engine_db_unknown", "store typed relation/key/variant 불명") }
	if t == nil || scan == nil {
		return proof, bad()
	}
	remaining, buffered := storeKeyRowLimit, 0
	read := func(table string, cols ...storeKeyColumn) ([][]any, error) {
		rows, e := scan(table, cols)
		if e != nil {
			return nil, e
		}
		if len(rows) > remaining {
			return nil, bad()
		}
		remaining -= len(rows)
		for _, row := range rows {
			if len(row) != len(cols) {
				return nil, bad()
			}
			buffered += len(row) * 128
			for i, col := range cols {
				if row[i] == nil {
					if !col.Nullable {
						return nil, bad()
					}
					continue
				}
				if col.Integer {
					if _, ok := row[i].(int64); !ok {
						return nil, bad()
					}
				} else {
					s, ok := row[i].(string)
					if !ok || !validStoreKeyText(s, storeColumnTextLimit(col.Name)) {
						return nil, bad()
					}
					buffered += len(s)
				}
			}
			if buffered > storeKeyBufferLimit {
				return nil, bad()
			}
		}
		return rows, nil
	}
	record := func(class, scope string, owner storeKey, related *storeKey) error {
		if scope == "" {
			return nil
		}
		if len(proof.Relations) >= storeKeyRowLimit {
			return bad()
		}
		proof.Relations = append(proof.Relations, storeRelation{class, scope, owner, related})
		return nil
	}
	owned := func(table, class, scope string, history bool) error {
		rows, e := read(table, storeTextColumn("thread_id", false))
		if e != nil {
			return e
		}
		for _, row := range rows {
			id := row[0].(string)
			if !uuidRE.MatchString(id) {
				return bad()
			}
			key := t.historyKey(id)
			if !history {
				if !t.members[id] {
					continue
				}
				k := threadStoreKey(id)
				key = &k
			}
			if key != nil {
				if e := record(class, scope, *key, nil); e != nil {
					return e
				}
			}
		}
		return nil
	}
	T, I := storeTextColumn, storeIntColumn
	switch kind {
	case "state":
		resources := map[string]map[string]bool{"project": {}, "section": {}}
		for _, spec := range []struct{ table, class string }{{"projects", "project"}, {"thread_sections", "section"}} {
			rows, e := read(spec.table, T("id", false))
			if e != nil {
				return proof, e
			}
			for _, row := range rows {
				id := row[0].(string)
				if !uuidRE.MatchString(id) || resources[spec.class][id] {
					return proof, bad()
				}
				resources[spec.class][id] = true
			}
		}
		rows, e := read("threads", T("id", false), T("source", false), T("project_id", true), T("thread_section_id", true), T("rollout_path", false))
		if e != nil {
			return proof, e
		}
		seen := map[string]bool{}
		for _, row := range rows {
			id := row[0].(string)
			if !uuidRE.MatchString(id) || seen[id] {
				return proof, bad()
			}
			seen[id] = true
			parent, e := storeSourceParent(row[1].(string))
			if e != nil {
				return proof, e
			}
			if parent != "" {
				key := threadStoreKey(parent)
				if e := record("sessionSource", t.pairScope(id, &key), threadStoreKey(id), &key); e != nil {
					return proof, e
				}
			}
			for j, class := range []string{"project", "section"} {
				if row[j+2] == nil {
					continue
				}
				key := row[j+2].(string)
				if !uuidRE.MatchString(key) || !resources[class][key] {
					return proof, bad()
				}
				if t.members[id] {
					resource := storeKey{class, key}
					if e := record(class, "active", threadStoreKey(id), &resource); e != nil {
						return proof, e
					}
				}
			}
			// A known path binds its immutable rollout domain to the logical owner.
			if path, ok := t.paths[row[4].(string)]; ok && path.Thread != id {
				return proof, bad()
			}
			if t.members[id] {
				if e := record("thread", "active", threadStoreKey(id), nil); e != nil {
					return proof, e
				}
			}
		}
		rows, e = read("thread_spawn_edges", T("parent_thread_id", false), T("child_thread_id", false), T("status", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			id, peer := row[0].(string), row[1].(string)
			if !uuidRE.MatchString(id) || !uuidRE.MatchString(peer) || (row[2] != "open" && row[2] != "closed") {
				return proof, bad()
			}
			key := threadStoreKey(peer)
			if e := record("spawnEdge", t.pairScope(id, &key), threadStoreKey(id), &key); e != nil {
				return proof, e
			}
		}
		for _, spec := range []struct {
			table, class string
			extra        storeKeyColumn
		}{{"thread_attachments", "attachment", T("id", false)}, {"thread_dynamic_tools", "dynamicTool", I("position", false)}} {
			rows, e := read(spec.table, T("thread_id", false), spec.extra)
			if e != nil {
				return proof, e
			}
			for _, row := range rows {
				id := row[0].(string)
				if !uuidRE.MatchString(id) {
					return proof, bad()
				}
				if spec.class == "attachment" {
					if !uuidRE.MatchString(row[1].(string)) {
						return proof, bad()
					}
				} else if row[1].(int64) < 0 {
					return proof, bad()
				}
				if t.members[id] {
					if e := record(spec.class, "active", threadStoreKey(id), nil); e != nil {
						return proof, e
					}
				}
			}
		}
		rows, e = read("rollout_migration_state", T("migration_id", false), I("last_checked_thread_created_at", true), T("last_checked_thread_id", true), I("updated_at", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			if row[0] != "legacy_to_paginated_v1" || !storeCursorTimestamp(row[3].(int64)) || (row[1] == nil) != (row[2] == nil) {
				return proof, bad()
			}
			if row[1] != nil {
				id := row[2].(string)
				if !storeCursorTimestamp(row[1].(int64)) || !uuidRE.MatchString(id) {
					return proof, bad()
				}
				if t.members[id] {
					if e := record("migrationCursor", "passive", threadStoreKey(id), nil); e != nil {
						return proof, e
					}
				}
			}
		}
		rows, e = read("rollout_migration_skipped_rollouts", T("migration_id", false), T("rollout_path", false), I("rollout_size_bytes", false), I("rollout_modified_at_ns", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			entry, known := t.paths[row[1].(string)]
			if row[0] != "legacy_to_paginated_v1" || row[2].(int64) < 0 || row[3].(int64) < 0 || !known {
				return proof, bad()
			}
			var key *storeKey
			if t.members[entry.Thread] {
				k := threadStoreKey(entry.Thread)
				key = &k
			} else if t.rollouts[entry.Rollout] != "" {
				k := storeKey{"rollout", entry.Rollout}
				key = &k
			}
			if key != nil {
				if e := record("skippedRollout", "active", *key, nil); e != nil {
					return proof, e
				}
			}
		}
	case "logs":
		rows, e := read("logs", T("thread_id", true))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			if row[0] == nil {
				continue
			}
			id := row[0].(string)
			if !uuidRE.MatchString(id) {
				return proof, bad()
			}
			if t.members[id] {
				if e := record("thread", "active", threadStoreKey(id), nil); e != nil {
					return proof, e
				}
			}
		}
	case "goals":
		rows, e := read("thread_goals", T("thread_id", false), T("status", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			id := row[0].(string)
			if !uuidRE.MatchString(id) {
				return proof, bad()
			}
			switch row[1] {
			case "active", "paused", "blocked", "usage_limited", "budget_limited", "complete":
			default:
				return proof, bad()
			}
			if t.members[id] {
				if e := record("goal", "active", threadStoreKey(id), nil); e != nil {
					return proof, e
				}
			}
		}
		if e := owned("thread_goal_continuation_deferrals", "deferral", "active", false); e != nil {
			return proof, e
		}
	case "memories", "memoriesV2":
		if e := owned("stage1_outputs", "stage1", "active", false); e != nil {
			return proof, e
		}
		rows, e := read("jobs", T("kind", false), T("job_key", false), T("worker_id", true), T("status", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			var worker *storeKey
			if row[2] != nil {
				id := row[2].(string)
				if !uuidRE.MatchString(id) {
					return proof, bad()
				}
				key := threadStoreKey(id)
				worker = &key
			}
			switch row[3] {
			case "pending", "running", "done", "error":
			default:
				return proof, bad()
			}
			switch row[0] {
			case "memory_stage1":
				id := row[1].(string)
				if !uuidRE.MatchString(id) {
					return proof, bad()
				}
				if e := record("stage1Job", t.pairScope(id, worker), threadStoreKey(id), worker); e != nil {
					return proof, e
				}
			case "memory_consolidate_global":
				if row[1] != "global" {
					return proof, bad()
				}
				if worker != nil && t.members[worker.ID] {
					if e := record("globalJob", "sharedGlobal", storeKey{"global", ""}, worker); e != nil {
						return proof, e
					}
				}
			default:
				return proof, bad()
			}
		}
	case "queue":
		if e := owned("queued_items", "item", "active", false); e != nil {
			return proof, e
		}
		rows, e := read("queued_thread_revisions", T("thread_id", false), I("revision", false))
		if e != nil {
			return proof, e
		}
		for _, row := range rows {
			id := row[0].(string)
			if !uuidRE.MatchString(id) || row[1].(int64) <= 0 {
				return proof, bad()
			}
			if t.members[id] {
				if e := record("revision", "passive", threadStoreKey(id), nil); e != nil {
					return proof, e
				}
			}
		}
	case "threadHistory":
		for _, spec := range []struct{ table, class string }{{"thread_turns", "turn"}, {"thread_items", "item"}, {"thread_realtime_items", "realtimeItem"}, {"thread_history_projection_state", "projection"}} {
			if e := owned(spec.table, spec.class, "active", true); e != nil {
				return proof, e
			}
		}
	case "agentMessageBoard":
		for _, spec := range []struct {
			table, class string
			cols         []storeKeyColumn
		}{
			{"channels", "channel", []storeKeyColumn{T("board", false), T("author", false)}},
			{"posts", "post", []storeKeyColumn{T("board", false), T("request_id", false), T("id", false), T("root", false), T("author", false)}},
			{"subscriptions", "subscription", []storeKeyColumn{T("board", false), T("agent", false), T("target", false)}},
			{"subscription_opt_outs", "optOut", []storeKeyColumn{T("board", false), T("agent", false), T("target", false)}},
			{"deleted_boards", "deletedBoard", []storeKeyColumn{T("board", false)}},
		} {
			rows, e := read(spec.table, spec.cols...)
			if e != nil {
				return proof, e
			}
			for _, row := range rows {
				root := row[0].(string)
				if !uuidRE.MatchString(root) {
					return proof, bad()
				}
				var peer *storeKey
				switch spec.class {
				case "post":
					caller, tail, ok := strings.Cut(row[1].(string), ":")
					if !ok || tail == "" || len(tail) > 512 || !uuidRE.MatchString(caller) || !uuidRE.MatchString(row[2].(string)) || !uuidRE.MatchString(row[3].(string)) || !storeAgentPath(row[4].(string)) {
						return proof, bad()
					}
					key := threadStoreKey(caller)
					peer = &key
				case "subscription", "optOut":
					id := row[1].(string)
					if !uuidRE.MatchString(id) || !storeBoardTarget(row[2].(string)) {
						return proof, bad()
					}
					key := threadStoreKey(id)
					peer = &key
				case "channel":
					if !storeAgentPath(row[1].(string)) {
						return proof, bad()
					}
				}
				scope := ""
				if peer != nil {
					scope = t.pairScope(root, peer)
				} else if t.roots[root] {
					scope = "active"
					if spec.class == "deletedBoard" {
						scope = "passive"
					}
				}
				if e := record(spec.class, scope, threadStoreKey(root), peer); e != nil {
					return proof, e
				}
			}
		}
	default:
		return proof, bad()
	}
	return proof, nil
}

// chrono::DateTime::from_timestamp's nonnegative whole-second range.
func storeCursorTimestamp(n int64) bool { return n >= 0 && n <= 8210266876799 }
func storeSourceParent(raw string) (string, error) {
	if strings.HasPrefix(raw, "\"") {
		v, e := parseJSON([]byte(raw))
		if e != nil {
			return "", e
		}
		s, ok := v.(string)
		if !ok {
			return "", fail("engine_db_unknown", "SessionSource string 구조 불명")
		}
		raw = s
	}
	if strings.HasPrefix(raw, "{") {
		v, e := parseJSON([]byte(raw))
		if e != nil {
			return "", e
		}
		source := obj(v)
		if exact(source, "custom") {
			if _, ok := source["custom"].(string); ok {
				return "", nil
			}
		}
		sub := obj(source["subagent"])
		if exact(source, "subagent") && exact(sub, "other") {
			if _, ok := sub["other"].(string); ok {
				return "", nil
			}
		}
		spawn := obj(sub["thread_spawn"])
		if _, alias := spawn["agent_type"]; alias {
			return "", fail("engine_db_unknown", "SessionSource canonical role alias 불명")
		}
		if path := spawn["agent_path"]; path != nil {
			s, ok := path.(string)
			if !ok || !storeAgentPath(s) {
				return "", fail("engine_db_unknown", "SessionSource AgentPath 불명")
			}
		}
	}
	return stateSourceParent(raw)
}
func storeAgentPath(s string) bool {
	if s == "/morpheus" || s == "/root" {
		return true
	}
	if !strings.HasPrefix(s, "/root/") {
		return false
	}
	for _, part := range strings.Split(strings.TrimPrefix(s, "/root/"), "/") {
		if part == "" || part == "root" {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
				return false
			}
		}
	}
	return true
}
func storeBoardTarget(s string) bool {
	v, e := parseJSON([]byte(s))
	if e != nil {
		return false
	}
	o := obj(v)
	if exact(o, "Thread") {
		return uuidRE.MatchString(text(o["Thread"]))
	}
	if exact(o, "Channel") {
		name, ok := o["Channel"].(string)
		return ok && name != "" && validStoreKeyText(name, 128)
	}
	return false
}
