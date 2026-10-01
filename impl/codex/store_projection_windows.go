//go:build windows

package main

import (
	"context"
	"errors"
)

// Source-only proof preparation; production RPC continues to reject aggregate
// complete. Schema, file/metadata uncertainty and operation policy are independent
// gates. No context/admission/delete/retained marker is minted by these counts.
func inspectPrivateStoreProof(ctx context.Context, s *storeAcquisition, targets *storeProofKeys) (observation, proof object, retErr error) {
	if ctx == nil {
		return nil, nil, fail("engine_db_unknown", "store proof context 누락")
	}
	defer func() {
		retErr = errors.Join(retErr, ctx.Err())
		if retErr != nil {
			observation, proof = nil, nil
		}
	}()
	facts, e := inspectPrivateStoreKeys(ctx, s, targets)
	if e != nil {
		return nil, nil, e
	}
	if e := ctx.Err(); e != nil {
		return nil, nil, e
	}
	observation, e = s.Observation()
	if e != nil {
		return nil, nil, e
	}
	if e := ctx.Err(); e != nil {
		return nil, nil, e
	}
	d, e := validateStoreObservationV2(observation, s.SourceRoot, s.targets)
	if e != nil {
		return nil, nil, e
	}
	if e := ctx.Err(); e != nil {
		return nil, nil, e
	}
	present := make([]bool, len(s.Stores))
	for i, slot := range s.Stores {
		present[i] = slot.Present
	}
	proof, e = projectStoreKeyProof(facts, targets, present, d)
	if e != nil {
		return nil, nil, e
	}
	return observation, proof, nil
}

// Only internal reader facts reach this projection. Absent slots have already
// passed the aggregate four-name absence checks; present empty facts come from a
// completed sealed reader, never from an omitted/caller-declared proof.
func projectStoreKeyProof(facts []storeKeyEvidence, t *storeProofKeys, present []bool, observationDigest string) (object, error) {
	bad := func() error { return fail("engine_db_unknown", "typed relation catalog/endpoint projection 오류") }
	catalog, e := storeProofCatalog()
	if e != nil {
		return nil, e
	}
	stores, scopes := array(catalog["stores"]), array(catalog["relationScopes"])
	if t == nil || len(facts) != len(stores) || len(present) != len(stores) || !present[0] || !hashRE.MatchString(observationDigest) {
		return nil, bad()
	}
	rows := []any{}
	members := []member{}
	for _, m := range t.approved {
		members = append(members, member{ID: m.ID})
		relations := []any{}
		for _, raw := range stores {
			spec := obj(raw)
			for _, class := range array(spec["relationClasses"]) {
				counts := object{}
				for _, scope := range scopes {
					counts[text(scope)] = int64(0)
				}
				relations = append(relations, object{"kind": spec["kind"], "relationClass": class, "counts": counts})
			}
		}
		rows = append(rows, object{"memberId": m.ID, "relations": relations})
	}
	touches := func(id string, key storeKey) bool {
		switch key.Domain {
		case "thread":
			return key.ID == id
		case "boardRoot":
			return t.roots[key.ID] && key.ID == id
		case "rollout":
			return t.rollouts[key.ID] == id
		case "global":
			return true
		}
		return false
	}
	validKey := func(key storeKey) bool {
		switch key.Domain {
		case "thread", "rollout", "boardRoot", "project", "section":
			return uuidRE.MatchString(key.ID)
		case "global":
			return key.ID == ""
		}
		return false
	}
	base := 0
	for i, fact := range facts {
		spec := obj(stores[i])
		classes := array(spec["relationClasses"])
		if fact.Kind != spec["kind"] || len(fact.Relations) > storeKeyRowLimit || !present[i] && len(fact.Relations) != 0 {
			return nil, bad()
		}
		for _, r := range fact.Relations {
			classIndex, scopeKnown := -1, false
			for j, class := range classes {
				if r.Class == class {
					classIndex = j
				}
			}
			for _, scope := range scopes {
				if r.Scope == scope {
					scopeKnown = true
				}
			}
			if classIndex < 0 || !scopeKnown || !validKey(r.Owner) || r.Related != nil && !validKey(*r.Related) {
				return nil, bad()
			}
			if fact.Kind == "agentMessageBoard" {
				if r.Owner.Domain != "boardRoot" || r.Related != nil && r.Related.Domain != "thread" {
					return nil, bad()
				}
			} else if r.Owner.Domain == "boardRoot" || r.Related != nil && r.Related.Domain == "boardRoot" {
				return nil, bad()
			}
			if r.Owner.Domain == "global" {
				if (fact.Kind != "memories" && fact.Kind != "memoriesV2") || r.Class != "globalJob" || r.Scope != "sharedGlobal" || r.Related == nil || r.Related.Domain != "thread" || !t.members[r.Related.ID] {
					return nil, bad()
				}
			} else if r.Scope == "sharedGlobal" {
				return nil, bad()
			}
			matched := false
			for j, m := range t.approved {
				if !touches(m.ID, r.Owner) && (r.Related == nil || !touches(m.ID, *r.Related)) {
					continue
				}
				matched = true
				counts := obj(obj(array(obj(rows[j])["relations"])[base+classIndex])["counts"])
				n := counts[r.Scope].(int64)
				if n >= storeKeyRowLimit {
					return nil, bad()
				}
				counts[r.Scope] = n + 1
			}
			if !matched {
				return nil, bad()
			}
		}
		base += len(classes)
	}
	proof := object{"schemaVersion": 2, "observationDigest": observationDigest, "members": rows}
	if e := validateStoreProofV2(proof, observationDigest, members, present); e != nil {
		return nil, e
	}
	return proof, nil
}
