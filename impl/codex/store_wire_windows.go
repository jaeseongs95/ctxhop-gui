//go:build windows

package main

import (
	_ "embed"
	"path/filepath"
)

// Frozen structural contract only; it does not attest schema/typed relations or
// authorize provider admission, deletion, runtime activation, or retained cleanup.
//
//go:embed store-proof-v2-catalog.json
var storeProofCatalogBytes []byte

func storeProofCatalog() (object, error) {
	if digest(storeProofCatalogBytes) != "9126662e0d206bf4a15c186dd847fc66905e484568d8f380f74e4c64c9c0d28a" {
		return nil, fail("prestart_schema", "고정 store proof catalog 변경")
	}
	v, e := parseJSON(storeProofCatalogBytes)
	if e != nil {
		return nil, e
	}
	return obj(v), nil // exact bytes are pinned; all consumers use this one catalog.
}

func normalizedStoreValue(raw any) (any, error) {
	b, e := storeCanonicalJSON(raw)
	if e != nil {
		return nil, e
	}
	return parseJSON(b)
}

func validateStoreTargetsV2(raw any, home string) ([]storeTarget, error) {
	bad := func() error { return fail("prestart_targets", "v2 exact8 DB descriptor 오류") }
	if !filepath.IsAbs(home) {
		return nil, bad()
	}
	v, e := normalizedStoreValue(raw)
	if e != nil {
		return nil, e
	}
	targets, ok := v.([]any)
	if !ok || len(targets) != len(storeSpecs) {
		return nil, bad()
	}
	result := make([]storeTarget, 0, len(targets))
	for i, entry := range targets {
		t := obj(entry)
		path := text(t["path"])
		if !exact(t, "kind", "path") || t["kind"] != storeSpecs[i].Kind || !filepath.IsAbs(path) || !samePath(path, filepath.Join(home, storeSpecs[i].Filename)) {
			return nil, bad()
		}
		result = append(result, storeTarget{storeSpecs[i].Kind, path})
	}
	return result, nil // path shape is not canonical Config descriptor authority.
}

func validateStoreObservationV2(raw any, home string, targets []storeTarget) (string, error) {
	bad := func() error { return fail("engine_db_unknown", "v2 store observation 결속/구조 오류") }
	if !filepath.IsAbs(home) || len(targets) != len(storeSpecs) {
		return "", bad()
	}
	for i, target := range targets {
		if target.Kind != storeSpecs[i].Kind || !samePath(target.Path, filepath.Join(home, storeSpecs[i].Filename)) {
			return "", bad()
		}
	}
	b, e := storeCanonicalJSON(raw)
	if e != nil {
		return "", e
	}
	v, e := parseJSON(b)
	if e != nil {
		return "", e
	}
	o := obj(v)
	version, ok := integer(o["schemaVersion"])
	if !exact(o, "schemaVersion", "acquisitionId", "sourceRoot", "privateRoot", "stores") || !ok || version != 2 || !opRE.MatchString(text(o["acquisitionId"])) {
		return "", bad()
	}
	source, private := obj(o["sourceRoot"]), obj(o["privateRoot"])
	privateRoot := text(private["directory"])
	if !exact(source, "directory", "directoryIdentity") || !exact(private, "directory", "directoryIdentity") || !samePath(text(source["directory"]), home) || !filepath.IsAbs(privateRoot) || within(home, privateRoot) || within(privateRoot, home) {
		return "", bad()
	}
	seen := map[string]bool{}
	add := func(value any) bool {
		id, ok := value.(string)
		if !ok || !fileIDRE.MatchString(id) || seen[id] {
			return false
		}
		seen[id] = true
		return true
	}
	if !add(source["directoryIdentity"]) || !add(private["directoryIdentity"]) {
		return "", bad()
	}
	stores, ok := o["stores"].([]any)
	if !ok || len(stores) != len(storeSpecs) {
		return "", bad()
	}
	var total int64
	for i, entry := range stores {
		slot := obj(entry)
		present, pok := slot["present"].(bool)
		if !exact(slot, "kind", "dbPath", "present", "acquisition") || slot["kind"] != targets[i].Kind || !samePath(text(slot["dbPath"]), targets[i].Path) || !pok || i == 0 && !present {
			return "", bad()
		}
		if !present {
			if slot["acquisition"] != nil {
				return "", bad()
			}
			continue
		}
		acq := obj(slot["acquisition"])
		src, copy := obj(acq["source"]), obj(acq["private"])
		if acq["acquisitionId"] != o["acquisitionId"] || src["directoryIdentity"] != source["directoryIdentity"] || !samePath(text(copy["directory"]), filepath.Join(privateRoot, targets[i].Kind)) || !add(copy["directoryIdentity"]) {
			return "", bad()
		}
		// Reuse all v1 nested file/null/hash/size/protected-namespace wire checks.
		outer := object{"stateDb": targets[i].Path, "mainSha256": obj(src["main"])["sha256"], "walSha256": nil, "acquisition": acq}
		if src["wal"] != nil {
			outer["walSha256"] = obj(src["wal"])["sha256"]
		}
		if e := validateObservation(outer, targets[i].Path); e != nil {
			return "", e
		}
		for _, name := range []string{"main", "wal", "shm"} {
			if src[name] == nil {
				continue
			}
			file := obj(src[name])
			n, _ := integer(file["size"])
			if !add(file["identity"]) {
				return "", bad()
			}
			if name == "shm" {
				continue
			}
			if n > limit-total || !add(obj(copy[name])["identity"]) {
				return "", bad()
			}
			total += n
		}
	}
	return digest(b), nil
}

func validateStoreProofV2(raw any, observationDigest string, members []member, present []bool) error {
	bad := func() error { return fail("prestart_schema", "v2 store proof catalog/count/member 결속 오류") }
	catalog, e := storeProofCatalog()
	if e != nil {
		return e
	}
	if !hashRE.MatchString(observationDigest) || len(members) < 1 || len(members) > 2000 || len(present) != len(storeSpecs) || !present[0] {
		return bad()
	}
	v, e := normalizedStoreValue(raw)
	if e != nil {
		return e
	}
	proof := obj(v)
	version, ok := integer(proof["schemaVersion"])
	if !exact(proof, "schemaVersion", "observationDigest", "members") || !ok || version != 2 || proof["observationDigest"] != observationDigest {
		return bad()
	}
	rows, ok := proof["members"].([]any)
	if !ok || len(rows) != len(members) {
		return bad()
	}
	seen := map[string]bool{}
	for i, entry := range rows {
		row := obj(entry)
		id := members[i].ID
		if !uuidRE.MatchString(id) || seen[id] || !exact(row, "memberId", "relations") || row["memberId"] != id {
			return bad()
		}
		seen[id] = true
		relations, ok := row["relations"].([]any)
		if !ok {
			return bad()
		}
		index := 0
		for storeIndex, entry := range array(catalog["stores"]) {
			spec := obj(entry)
			for _, class := range array(spec["relationClasses"]) {
				if index >= len(relations) {
					return bad()
				}
				relation := obj(relations[index])
				index++
				counts := obj(relation["counts"])
				if !exact(relation, "kind", "relationClass", "counts") || relation["kind"] != spec["kind"] || relation["relationClass"] != class || !exact(counts, "active", "internal", "externalIncoming", "externalOutgoing", "sharedGlobal", "passive") {
					return bad()
				}
				for _, scope := range array(catalog["relationScopes"]) {
					n, ok := integer(counts[text(scope)])
					if !ok || n < 0 || !present[storeIndex] && n != 0 {
						return bad()
					}
				}
			}
		}
		if index != len(relations) {
			return bad()
		}
	}
	return nil
}

// Pure binding checks for future v2 caller integration. This is not the full
// prepare projection validator and is never an admission/activation fallback.
func validateStoreBindingsV2(raw any, observation any, home string, targets []storeTarget, members []member, complete bool) error {
	bad := func() error { return fail("prestart_binding", "v2 store proof binding 오류") }
	v, e := normalizedStoreValue(raw)
	if e != nil {
		return e
	}
	binding := obj(v)
	if !exact(binding, "acquisitionId", "storeObservationDigest", "storeProof") {
		return bad()
	}
	if !complete {
		if binding["acquisitionId"] != nil || binding["storeObservationDigest"] != nil || binding["storeProof"] != nil || observation != nil {
			return bad()
		}
		return nil
	}
	d, e := validateStoreObservationV2(observation, home, targets)
	if e != nil {
		return e
	}
	v, e = normalizedStoreValue(observation)
	if e != nil {
		return e
	}
	obs := obj(v)
	if binding["acquisitionId"] != obs["acquisitionId"] || binding["storeObservationDigest"] != d {
		return bad()
	}
	present := make([]bool, len(storeSpecs))
	for i, slot := range array(obs["stores"]) {
		present[i] = obj(slot)["present"] == true
	}
	return validateStoreProofV2(binding["storeProof"], d, members, present)
}
