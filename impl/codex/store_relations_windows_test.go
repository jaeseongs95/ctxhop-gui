//go:build windows

package main

import (
	"context"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const proofRolloutID = "11111111-1111-1111-1111-111111111111"
const proofChildRolloutID = "22222222-2222-2222-2222-222222222222"
const proofOutsideID = "33333333-3333-3333-3333-333333333333"

func relationTargets(t *testing.T) *storeProofKeys {
	t.Helper()
	keys, e := newStoreProofKeys([]storeApprovedMember{{rootID, rootID, []string{proofRolloutID}}, {childID, rootID, []string{proofChildRolloutID}}}, []storeRolloutKey{{"root-rollout", rootID, proofRolloutID}, {"child-rollout", childID, proofChildRolloutID}})
	if e != nil {
		t.Fatal(e)
	}
	return keys
}

func mockStoreScan(rows map[string][][]any) func(string, []storeKeyColumn) ([][]any, error) {
	return func(table string, cols []storeKeyColumn) ([][]any, error) { return rows[table], nil }
}

func TestStoreTypedEightReadersAndEndpointDomains(t *testing.T) {
	keys := relationTargets(t)
	spawn := string(encoded(object{"subagent": object{"thread_spawn": object{"parent_thread_id": rootID, "depth": int64(1)}}}))
	rows := map[string][][]any{
		"projects": {{proofOutsideID}}, "thread_sections": {{proofOutsideID}},
		"threads":            {{rootID, "cli", nil, nil, "root-rollout"}, {childID, spawn, proofOutsideID, proofOutsideID, "child-rollout"}},
		"thread_spawn_edges": {{proofOutsideID, rootID, "open"}},
		"thread_attachments": {{rootID, proofOutsideID}}, "thread_dynamic_tools": {{childID, int64(0)}},
		"rollout_migration_state":            {{"legacy_to_paginated_v1", int64(1), rootID, int64(2)}},
		"rollout_migration_skipped_rollouts": {{"legacy_to_paginated_v1", "root-rollout", int64(1), int64(2)}},
		"logs":                               {{rootID}, {nil}, {proofOutsideID}}, "thread_goals": {{childID, "complete"}}, "thread_goal_continuation_deferrals": {{rootID}},
		"stage1_outputs": {{rootID}},
		"jobs":           {{"memory_stage1", childID, proofOutsideID, "done"}, {"memory_stage1", proofOutsideID, rootID, "pending"}, {"memory_consolidate_global", "global", childID, "running"}, {"memory_consolidate_global", "global", proofOutsideID, "done"}},
		"queued_items":   {{rootID}}, "queued_thread_revisions": {{childID, int64(1)}},
		"thread_turns": {{proofRolloutID}}, "thread_items": {{childID}}, "thread_realtime_items": {{proofChildRolloutID}}, "thread_history_projection_state": {{rootID}, {proofOutsideID}},
		"channels":              {{rootID, "/root/reviewer"}},
		"posts":                 {{rootID, childID + ":request:suffix", proofOutsideID, proofOutsideID, "/root/reviewer"}, {proofOutsideID, proofOutsideID + ":other", rootID, childID, "/root"}},
		"subscriptions":         {{rootID, proofOutsideID, `{"Channel":"general"}`}, {proofOutsideID, childID, `{"Thread":"` + rootID + `"}`}},
		"subscription_opt_outs": {{rootID, childID, `{"Channel":"general"}`}}, "deleted_boards": {{rootID}},
	}
	catalog, e := storeProofCatalog()
	if e != nil {
		t.Fatal(e)
	}
	facts := []storeKeyEvidence{}
	for _, raw := range array(catalog["stores"]) {
		spec := obj(raw)
		kind := text(spec["kind"])
		t.Run(kind, func(t *testing.T) {
			proof, e := readStoreKeyRelations(kind, keys, mockStoreScan(rows))
			if e != nil {
				t.Fatal(e)
			}
			facts = append(facts, proof)
			classes := map[string]bool{}
			scopes := map[string]int{}
			for _, r := range proof.Relations {
				classes[r.Class] = true
				scopes[r.Scope]++
			}
			for _, class := range array(spec["relationClasses"]) {
				if !classes[text(class)] {
					t.Fatal("missing observed class", class)
				}
			}
			if kind == "memories" || kind == "memoriesV2" {
				if scopes["externalIncoming"] != 1 || scopes["externalOutgoing"] != 1 || scopes["sharedGlobal"] != 1 {
					t.Fatal("worker direction/global classification", proof)
				}
			}
			if kind == "agentMessageBoard" {
				if scopes["externalIncoming"] != 1 || scopes["externalOutgoing"] != 1 || scopes["internal"] != 2 || scopes["passive"] != 1 || len(proof.Relations) != 6 {
					t.Fatal("post UUID confused with ThreadId, or endpoint direction", proof)
				}
			}
			if kind == "threadHistory" {
				if len(proof.Relations) != 4 || proof.Relations[0].Owner.Domain != "rollout" || proof.Relations[0].Owner.ID != proofRolloutID {
					t.Fatal("history M/R domain mapping", proof)
				}
			}
		})
	}
	proof, e := projectStoreKeyProof(facts, keys, []bool{true, true, true, true, true, true, true, true}, strings.Repeat("a", 64))
	if e != nil {
		t.Fatal(e)
	}
	counts := func(memberIndex int, kind, class, scope string) int64 {
		for _, raw := range array(obj(array(proof["members"])[memberIndex])["relations"]) {
			r := obj(raw)
			if r["kind"] == kind && r["relationClass"] == class {
				return obj(r["counts"])[scope].(int64)
			}
		}
		t.Fatal("missing class")
		return -1
	}
	if counts(0, "state", "sessionSource", "internal") != 1 || counts(1, "state", "sessionSource", "internal") != 1 || counts(0, "memories", "globalJob", "sharedGlobal") != 1 || counts(1, "memories", "globalJob", "sharedGlobal") != 1 || counts(0, "threadHistory", "turn", "active") != 1 || counts(1, "threadHistory", "turn", "active") != 0 || counts(0, "agentMessageBoard", "post", "internal") != 1 || counts(1, "agentMessageBoard", "post", "internal") != 1 {
		t.Fatal("endpoint union/R owner/sharedGlobal attribution", proof)
	}
	if _, e := projectStoreKeyProof(facts, keys, []bool{true, true, true, true, true, true, true, false}, strings.Repeat("a", 64)); e == nil {
		t.Fatal("absent nonzero facts accepted")
	}
	self := make([]storeKeyEvidence, len(storeSpecs))
	for i, spec := range storeSpecs {
		self[i].Kind = spec.Kind
	}
	key := threadStoreKey(rootID)
	self[0].Relations = []storeRelation{{"sessionSource", "internal", key, &key}}
	selfProof, e := projectStoreKeyProof(self, keys, []bool{true, false, false, false, false, false, false, false}, strings.Repeat("a", 64))
	if e != nil {
		t.Fatal(e)
	}
	proof = selfProof
	if counts(0, "state", "sessionSource", "internal") != 1 {
		t.Fatal("same endpoint counted twice")
	}
}

func TestStoreTypedKeysUnknownAndBounds(t *testing.T) {
	keys := relationTargets(t)
	for _, tc := range []struct {
		name, kind, table string
		row               []any
	}{
		{"job-kind", "memories", "jobs", []any{"future", rootID, nil, "done"}},
		{"reverse-malformed-worker", "memoriesV2", "jobs", []any{"memory_stage1", proofOutsideID, "notUUID", "pending"}},
		{"job-status", "memories", "jobs", []any{"memory_stage1", rootID, nil, "finished"}},
		{"global-key", "memories", "jobs", []any{"memory_consolidate_global", rootID, childID, "done"}},
		{"revision-zero", "queue", "queued_thread_revisions", []any{rootID, int64(0)}},
		{"revision-float", "queue", "queued_thread_revisions", []any{rootID, float64(1)}},
		{"revision-null", "queue", "queued_thread_revisions", []any{rootID, nil}},
		{"goal-status", "goals", "thread_goals", []any{rootID, "future"}},
		{"malformed-unrelated", "logs", "logs", []any{"notUUID"}},
		{"source-unknown", "state", "threads", []any{rootID, "unknown", nil, nil, "root-rollout"}},
		{"path-owner", "state", "threads", []any{proofOutsideID, "cli", nil, nil, "root-rollout"}},
		{"orphan-project", "state", "threads", []any{rootID, "cli", proofOutsideID, nil, "root-rollout"}},
		{"cursor-partial", "state", "rollout_migration_state", []any{"legacy_to_paginated_v1", nil, rootID, int64(1)}},
		{"cursor-overflow", "state", "rollout_migration_state", []any{"legacy_to_paginated_v1", int64(math.MaxInt64), rootID, int64(1)}},
		{"cursor-future", "state", "rollout_migration_state", []any{"future", int64(1), rootID, int64(1)}},
		{"skipped-uninventoried", "state", "rollout_migration_skipped_rollouts", []any{"legacy_to_paginated_v1", "unknown", int64(0), int64(0)}},
		{"board-caller", "agentMessageBoard", "posts", []any{rootID, "caller:request", proofOutsideID, proofOutsideID, "/root"}},
		{"board-empty-suffix", "agentMessageBoard", "posts", []any{rootID, rootID + ":", proofOutsideID, proofOutsideID, "/root"}},
		{"board-large-suffix", "agentMessageBoard", "posts", []any{rootID, rootID + ":" + strings.Repeat("x", 513), proofOutsideID, proofOutsideID, "/root"}},
		{"board-author", "agentMessageBoard", "channels", []any{rootID, rootID}},
		{"board-agent", "agentMessageBoard", "subscriptions", []any{rootID, "/root", `{"Channel":"general"}`}},
		{"board-target-domain", "agentMessageBoard", "subscriptions", []any{rootID, childID, `{"thread":"` + rootID + `"}`}},
		{"board-target-extra", "agentMessageBoard", "subscriptions", []any{rootID, childID, `{"Thread":"` + rootID + `","extra":true}`}},
		{"key-NUL", "logs", "logs", []any{rootID + "\x00"}},
		{"key-large", "logs", "logs", []any{strings.Repeat("x", 257)}},
		{"wrong-shape", "logs", "logs", []any{rootID, childID}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, e := readStoreKeyRelations(tc.kind, keys, mockStoreScan(map[string][][]any{tc.table: {tc.row}})); e == nil {
				t.Fatal("unknown accepted")
			}
		})
	}
	rows := make([][]any, storeKeyRowLimit+1)
	for i := range rows {
		rows[i] = []any{rootID}
	}
	if _, e := readStoreKeyRelations("logs", keys, mockStoreScan(map[string][][]any{"logs": rows})); e == nil {
		t.Fatal("row limit accepted")
	}
	// Overall budget spans tables; a second table cannot reset it.
	rows = rows[:storeKeyRowLimit]
	if _, e := readStoreKeyRelations("goals", keys, mockStoreScan(map[string][][]any{"thread_goal_continuation_deferrals": rows, "thread_goals": {{rootID, "active"}}})); e == nil {
		t.Fatal("table-local budget reset")
	}
	for i := range rows {
		rows[i] = []any{rootID, "{\"custom\":\"" + strings.Repeat("x", 7000) + "\"}", nil, nil, "root-rollout"}
	}
	if _, e := readStoreKeyRelations("state", keys, mockStoreScan(map[string][][]any{"threads": rows})); e == nil {
		t.Fatal("buffer limit accepted")
	}
	if _, e := readStoreKeyRelations("future", keys, mockStoreScan(nil)); e == nil {
		t.Fatal("unknown store accepted")
	}
	sentinel := errors.New("reader failed")
	if _, e := readStoreKeyRelations("logs", keys, func(string, []storeKeyColumn) ([][]any, error) { return nil, sentinel }); !errors.Is(e, sentinel) {
		t.Fatal("reader error lost")
	}
}

func TestStoreApprovedMappingAndNoProductionSchemaFallback(t *testing.T) {
	for _, raw := range []string{`"cli"`, `{"custom":""}`, `{"subagent":{"other":""}}`} {
		if parent, e := storeSourceParent(raw); e != nil || parent != "" {
			t.Fatal("canonical source", raw, parent, e)
		}
	}
	for _, raw := range []string{`"{\"custom\":\"desktop\"}"`, `{"subagent":{"thread_spawn":{"parent_thread_id":"` + rootID + `","depth":1,"agent_path":"not-an-AgentPath"}}}`, `{"subagent":{"thread_spawn":{"parent_thread_id":"` + rootID + `","depth":1,"agent_type":"role"}}}`} {
		if _, e := storeSourceParent(raw); e == nil {
			t.Fatal("noncanonical source accepted", raw)
		}
	}
	for _, tc := range []struct {
		name    string
		members []storeApprovedMember
		paths   []storeRolloutKey
	}{
		{"empty", nil, nil},
		{"no-rollout", []storeApprovedMember{{rootID, rootID, nil}}, nil},
		{"duplicate-M", []storeApprovedMember{{rootID, rootID, []string{proofRolloutID}}, {rootID, rootID, []string{proofChildRolloutID}}}, nil},
		{"duplicate-R", []storeApprovedMember{{rootID, rootID, []string{proofRolloutID}}, {childID, rootID, []string{proofRolloutID}}}, nil},
		{"outside-Q", []storeApprovedMember{{childID, rootID, []string{proofRolloutID}}}, nil},
		{"ambiguous-M-R", []storeApprovedMember{{rootID, rootID, []string{childID}}, {childID, rootID, []string{proofRolloutID}}}, nil},
		{"inventory-owner", []storeApprovedMember{{rootID, rootID, []string{proofRolloutID}}}, []storeRolloutKey{{"rollout", childID, proofRolloutID}}},
		{"inventory-path-duplicate", []storeApprovedMember{{rootID, rootID, []string{proofRolloutID}}}, []storeRolloutKey{{"rollout", rootID, proofRolloutID}, {"rollout", rootID, proofRolloutID}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, e := newStoreProofKeys(tc.members, tc.paths); e == nil {
				t.Fatal("bad mapping accepted")
			}
		})
	}
	approved := []storeApprovedMember{{rootID, rootID, []string{rootID}}}
	keys, e := newStoreProofKeys(approved, nil)
	if e != nil {
		t.Fatal("same UUID keeps M/R domains distinct", e)
	}
	approved[0].Rollouts[0] = childID
	if !reflect.DeepEqual(keys.approved[0].Rollouts, []string{rootID}) {
		t.Fatal("mapping aliased caller memory")
	}
	if !storeCursorTimestamp(time.Date(262142, 12, 31, 23, 59, 59, 0, time.UTC).Unix()) || storeCursorTimestamp(time.Date(262143, 1, 1, 0, 0, 0, 0, time.UTC).Unix()) {
		t.Fatal("chrono timestamp boundary")
	}
	if _, e := inspectPrivateStoreKeys(context.Background(), nil, relationTargets(t)); e == nil {
		t.Fatal("reader before finalized accepted")
	}
}

// This reconstructs the prior state seal in a new owned test DB. It is a
// reader/drain unit fixture, not the canonical eight-store seed or its evidence.
func TestStoreNativePrivateReaderDrainAndAuxSealGate(t *testing.T) {
	for _, variant := range []string{"success", "decoder-error", "cancelled", "schema-error"} {
		t.Run(variant, func(t *testing.T) {
			home := t.TempDir()
			sql := storeSchemaFixtureSQL(t, "state") + liveFixtureThread(rootID)
			if variant == "decoder-error" {
				sql += `UPDATE threads SET source='unknown';`
			}
			if variant == "schema-error" {
				sql += `CREATE TABLE future_object(id TEXT);`
			}
			closeFixture := sqliteFixture(t, home, false, sql)
			closeFixture()
			targets := []storeTarget{}
			for _, spec := range storeSpecs {
				targets = append(targets, storeTarget{spec.Kind, filepath.Join(home, spec.Filename)})
			}
			s, e := acquireStoreSet(home, filepath.Join(t.TempDir(), "private"), targets, limit, nil, nil)
			if e != nil {
				t.Fatal(e)
			}
			defer s.Close(false)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if variant == "cancelled" {
				cancel()
			}
			observation, summary, e := inspectPrivateStoreProof(ctx, s, relationTargets(t))
			if variant == "success" {
				if e != nil || len(array(observation["stores"])) != 8 || len(array(summary["members"])) != 2 {
					t.Fatal("private reader", observation, summary, e)
				}
			} else if e == nil || observation != nil || summary != nil {
				t.Fatal("partial proof escaped failed reader", observation, summary, e)
			}
			if e := s.Close(true); e != nil {
				t.Fatal("all reader drains/cleanup", e)
			}
			if e := s.VerifyReleasedSources(nil); e != nil {
				t.Fatal("source-only freshness after drain", e)
			}
			storeWriterAllowed(t, targets[0].Path)
		})
	}
	home, targets := storeFixture(t, true)
	s, e := acquireStoreSet(home, filepath.Join(t.TempDir(), "private"), targets, limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close(false)
	if facts, e := inspectPrivateStoreKeys(context.Background(), s, relationTargets(t)); e == nil || facts != nil || s.ReadersOpen != 0 {
		t.Fatal("aux raw copies treated as schema proof", facts, e)
	}
	if e := s.Close(true); e != nil {
		t.Fatal(e)
	}
	// Inject only the internal unknown-close state; no SQLite handle is left open.
	home, targets = storeFixture(t, false)
	s, e = acquireStoreSet(home, filepath.Join(t.TempDir(), "private"), targets, limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close(false)
	s.ReadersOpen = 1
	if e := s.Verify(); e == nil {
		t.Fatal("proof while reader drain unknown")
	}
	if e := s.CleanupPrivate(); e == nil {
		t.Fatal("cleanup while reader drain unknown")
	}
	if _, e := os.Stat(filepath.Join(s.PrivateRoot, "state", storeSpecs[0].Filename)); e != nil {
		t.Fatal("private removed before whole reader drain", e)
	}
	if e := s.Close(true); e == nil || s.PrivateRemoved {
		t.Fatal("unknown close became success", e)
	}
	if e := s.VerifyReleasedSources(nil); e == nil {
		t.Fatal("freshness accepted failed reader close")
	}
}
