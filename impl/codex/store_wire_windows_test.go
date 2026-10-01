//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func cloneStoreObject(t *testing.T, value any) object {
	t.Helper()
	v, e := parseJSON(encoded(value))
	if e != nil {
		t.Fatal(e)
	}
	return obj(v)
}

func wireStoreObservation(t *testing.T, all bool) (object, string, []storeTarget) {
	t.Helper()
	home := filepath.Join(t.TempDir(), "source")
	private := filepath.Join(t.TempDir(), "private")
	index := 0
	id := func() string { index++; return fmt.Sprintf("%024x", index) }
	sourceID, privateID := id(), id()
	stores := []any{}
	targets := []storeTarget{}
	for i, spec := range storeSpecs {
		path := filepath.Join(home, spec.Filename)
		targets = append(targets, storeTarget{spec.Kind, path})
		var acquisition any
		if all || i == 0 {
			kindID, sourceFileID, copyFileID := id(), id(), id()
			file := func(identity string) object {
				return object{"identity": identity, "size": int64(4096), "sha256": strings.Repeat("a", 64)}
			}
			acquisition = object{"schemaVersion": 1, "acquisitionId": strings.Repeat("b", 32), "source": object{"directoryIdentity": sourceID, "main": file(sourceFileID), "wal": nil, "shm": nil}, "private": object{"directory": filepath.Join(private, spec.Kind), "directoryIdentity": kindID, "main": file(copyFileID), "wal": nil}, "rollbackJournalAbsent": true}
		}
		stores = append(stores, object{"kind": spec.Kind, "dbPath": path, "present": acquisition != nil, "acquisition": acquisition})
	}
	return object{"schemaVersion": 2, "acquisitionId": strings.Repeat("b", 32), "sourceRoot": object{"directory": home, "directoryIdentity": sourceID}, "privateRoot": object{"directory": private, "directoryIdentity": privateID}, "stores": stores}, home, targets
}

// Zero counts are only synthetic wire data, never a production proof builder.
func wireStoreProof(t *testing.T, d string, members []member) object {
	t.Helper()
	catalog, e := storeProofCatalog()
	if e != nil {
		t.Fatal(e)
	}
	rows := []any{}
	for _, m := range members {
		relations := []any{}
		for _, raw := range array(catalog["stores"]) {
			spec := obj(raw)
			for _, class := range array(spec["relationClasses"]) {
				counts := object{}
				for _, scope := range array(catalog["relationScopes"]) {
					counts[text(scope)] = int64(0)
				}
				relations = append(relations, object{"kind": spec["kind"], "relationClass": class, "counts": counts})
			}
		}
		rows = append(rows, object{"memberId": m.ID, "relations": relations})
	}
	return object{"schemaVersion": 2, "observationDigest": d, "members": rows}
}

func TestStoreWireObservationTargetsAndGlobalBindings(t *testing.T) {
	for _, all := range []bool{false, true} {
		obs, home, targets := wireStoreObservation(t, all)
		want, e := storeCanonicalJSON(obs)
		if e != nil {
			t.Fatal(e)
		}
		if got, e := validateStoreObservationV2(obs, home, targets); e != nil || got != digest(want) {
			t.Fatal("valid v2 observation", got, e)
		}
		wireTargets := []any{}
		for _, target := range targets {
			wireTargets = append(wireTargets, object{"kind": target.Kind, "path": target.Path})
		}
		if got, e := validateStoreTargetsV2(wireTargets, home); e != nil || len(got) != 8 {
			t.Fatal("exact target vector", e)
		}
		for _, variant := range []string{"outer-extra", "version", "missing-store", "order", "present-type", "absent-state", "absent-acquisition", "nested-id", "source-dir", "private-alias", "file-alias", "root-alias", "root-child", "private-kind", "source-path", "source-extra", "wal-null", "negative", "aggregate-budget", "cross-store-alias"} {
			t.Run(fmt.Sprintf("all=%t/%s", all, variant), func(t *testing.T) {
				bad := cloneStoreObject(t, obs)
				stores := array(bad["stores"])
				state := obj(stores[0])
				acq := obj(state["acquisition"])
				src := obj(acq["source"])
				copy := obj(acq["private"])
				switch variant {
				case "outer-extra":
					bad["hash"] = "caller"
				case "version":
					bad["schemaVersion"] = 1
				case "missing-store":
					bad["stores"] = stores[:7]
				case "order":
					stores[6], stores[7] = stores[7], stores[6]
				case "present-type":
					state["present"] = "true"
				case "absent-state":
					state["present"] = false
					state["acquisition"] = nil
				case "absent-acquisition":
					obj(stores[7])["present"] = false
					obj(stores[7])["acquisition"] = acq
				case "nested-id":
					acq["acquisitionId"] = strings.Repeat("c", 32)
				case "source-dir":
					src["directoryIdentity"] = strings.Repeat("c", 24)
				case "private-alias":
					copy["directoryIdentity"] = obj(bad["privateRoot"])["directoryIdentity"]
				case "file-alias":
					obj(copy["main"])["identity"] = obj(bad["privateRoot"])["directoryIdentity"]
				case "root-alias":
					obj(bad["privateRoot"])["directoryIdentity"] = obj(bad["sourceRoot"])["directoryIdentity"]
				case "root-child":
					obj(bad["privateRoot"])["directory"] = filepath.Join(home, "private")
				case "private-kind":
					copy["directory"] = filepath.Join(text(obj(bad["privateRoot"])["directory"]), "queue")
				case "source-path":
					state["dbPath"] = targets[7].Path
				case "source-extra":
					src["trust"] = true
				case "wal-null":
					copy["wal"] = copy["main"]
				case "negative":
					obj(src["main"])["size"] = -1
					obj(copy["main"])["size"] = -1
				case "cross-store-alias":
					last := obj(stores[7])
					if !all {
						other, _, _ := wireStoreObservation(t, true)
						last["acquisition"] = cloneStoreObject(t, array(other["stores"])[7])["acquisition"]
						last["present"] = true
					}
					lastAcq := obj(last["acquisition"])
					lastSrc, lastCopy := obj(lastAcq["source"]), obj(lastAcq["private"])
					lastSrc["directoryIdentity"] = src["directoryIdentity"]
					lastCopy["directory"] = filepath.Join(text(obj(bad["privateRoot"])["directory"]), storeSpecs[7].Kind)
					obj(lastSrc["main"])["identity"] = obj(src["main"])["identity"]
				case "aggregate-budget":
					obj(src["main"])["size"] = limit
					obj(copy["main"])["size"] = limit
					if !all {
						other, _, _ := wireStoreObservation(t, true)
						otherAcq := cloneStoreObject(t, array(other["stores"])[7])["acquisition"].(object)
						otherSrc, otherCopy := obj(otherAcq["source"]), obj(otherAcq["private"])
						otherSrc["directoryIdentity"] = src["directoryIdentity"]
						otherCopy["directory"] = filepath.Join(text(obj(bad["privateRoot"])["directory"]), storeSpecs[7].Kind)
						obj(stores[7])["present"] = true
						obj(stores[7])["acquisition"] = otherAcq
					}
				}
				if _, e := validateStoreObservationV2(bad, home, targets); e == nil {
					t.Fatal("malformed observation accepted")
				}
			})
		}
		for _, variant := range []string{"unknown", "reorder", "parent", "missing", "duplicate", "null"} {
			var raw any = cloneStoreObject(t, object{"targets": wireTargets})["targets"]
			a := array(raw)
			switch variant {
			case "unknown":
				obj(a[7])["extra"] = true
			case "reorder":
				a[6], a[7] = a[7], a[6]
			case "parent":
				obj(a[7])["path"] = filepath.Join(t.TempDir(), storeSpecs[7].Filename)
			case "missing":
				raw = a[:7]
			case "duplicate":
				a[7] = a[6]
			case "null":
				raw = nil
			}
			if _, e := validateStoreTargetsV2(raw, home); e == nil {
				t.Fatal("invalid descriptor accepted", variant)
			}
		}
	}
}

func TestStoreWireFrozenProofAndPartialBindings(t *testing.T) {
	obs, home, targets := wireStoreObservation(t, false)
	d, e := validateStoreObservationV2(obs, home, targets)
	if e != nil {
		t.Fatal(e)
	}
	members := []member{{ID: rootID}, {ID: childID}}
	proof := wireStoreProof(t, d, members)
	present := []bool{true, false, false, false, false, false, false, false}
	if e := validateStoreProofV2(proof, d, members, present); e != nil {
		t.Fatal(e)
	}
	rows := array(proof["members"])
	if len(array(obj(rows[0])["relations"])) != 29 {
		t.Fatal("catalog must include 29 classes and explicit six scope zeros")
	}
	for _, variant := range []string{"extra", "digest", "version", "member-count", "member-order", "relation-count", "relation-order", "class", "relation-extra", "scope-missing", "scope-extra", "negative", "fraction", "exponent", "overflow", "absent-nonzero", "duplicate-plan", "unknown-id", "wrong-presence"} {
		t.Run(variant, func(t *testing.T) {
			bad := cloneStoreObject(t, proof)
			rows := array(bad["members"])
			relations := array(obj(rows[0])["relations"])
			counts := obj(obj(relations[0])["counts"])
			planned := members
			presence := present
			switch variant {
			case "extra":
				bad["own"] = true
			case "digest":
				bad["observationDigest"] = strings.Repeat("d", 64)
			case "version":
				bad["schemaVersion"] = 1
			case "member-count":
				bad["members"] = rows[:1]
			case "member-order":
				rows[0], rows[1] = rows[1], rows[0]
			case "relation-count":
				obj(rows[0])["relations"] = relations[:28]
			case "relation-order":
				relations[0], relations[1] = relations[1], relations[0]
			case "class":
				obj(relations[0])["relationClass"] = "unknown"
			case "relation-extra":
				obj(relations[0])["owner"] = true
			case "scope-missing":
				delete(counts, "passive")
			case "scope-extra":
				counts["unknown"] = 0
			case "negative":
				counts["active"] = -1
			case "fraction":
				counts["active"] = json.Number("1.0")
			case "exponent":
				counts["active"] = json.Number("1e0")
			case "overflow":
				counts["active"] = json.Number("9223372036854775808")
			case "absent-nonzero":
				obj(obj(relations[9])["counts"])["active"] = 1
			case "duplicate-plan":
				planned = []member{{ID: rootID}, {ID: rootID}}
			case "unknown-id":
				obj(rows[0])["memberId"] = "caller-id"
			case "wrong-presence":
				presence = present[:7]
			}
			if e := validateStoreProofV2(bad, d, planned, presence); e == nil {
				t.Fatal("invalid proof accepted")
			}
		})
	}
	// i64 maximum is preserved exactly; count validation does not pass via float64.
	maxProof := cloneStoreObject(t, proof)
	obj(obj(array(obj(array(maxProof["members"])[0])["relations"])[0])["counts"])["internal"] = json.Number("9223372036854775807")
	if e := validateStoreProofV2(maxProof, d, members, present); e != nil {
		t.Fatal("exact i64 max", e)
	}
	partial := object{"acquisitionId": nil, "storeObservationDigest": nil, "storeProof": nil}
	if e := validateStoreBindingsV2(partial, nil, home, targets, nil, false); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"acquisitionId", "storeObservationDigest", "storeProof"} {
		bad := cloneStoreObject(t, partial)
		delete(bad, key)
		if e := validateStoreBindingsV2(bad, nil, home, targets, nil, false); e == nil {
			t.Fatal("missing explicit null accepted", key)
		}
	}
	if e := validateStoreBindingsV2(partial, obs, home, targets, nil, false); e == nil {
		t.Fatal("partial supplied observation accepted")
	}
	binding := object{"acquisitionId": obs["acquisitionId"], "storeObservationDigest": d, "storeProof": proof}
	if e := validateStoreBindingsV2(binding, obs, home, targets, members, true); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"acquisitionId", "storeObservationDigest", "storeProof"} {
		bad := cloneStoreObject(t, binding)
		bad[key] = nil
		if e := validateStoreBindingsV2(bad, obs, home, targets, members, true); e == nil {
			t.Fatal("complete null accepted", key)
		}
	}
	bad := cloneStoreObject(t, binding)
	bad["storeObservationDigest"] = strings.Repeat("d", 64)
	if e := validateStoreBindingsV2(bad, obs, home, targets, members, true); e == nil {
		t.Fatal("observation digest mismatch accepted")
	}
}
