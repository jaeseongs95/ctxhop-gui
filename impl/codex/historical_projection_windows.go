//go:build windows

package main

import (
	"path/filepath"
	"strings"
	"time"
)

// Pure historical validation: no file/source lookup, expiry decision, engine,
// acquisition or current authority. The receipt separately binds its full SHA.
func validateHistoricalProjection(p object, j *journal, target string) error {
	bad := func() error { return fail("finalization_binding", "historical completed projection invalid") }
	if !exact(p, "contractVersion", "requestNonce", "processId", "processNonce", "snapshotId", "generation", "engineVersion", "loaderContractId", "inputComplete", "home", "normalSqliteHome", "operationSqliteHome", "stateDb", "sqliteRedirect", "writeTargets", "proofTargets", "projectConfig", "contexts", "authResolution", "policyResolution", "validity", "projectionDigest", "acquisitionId", "storeObservationDigest", "storeProof", "effects", "mappingProfile", "approvalEvidenceDigest", "approvedMappingDigest", "recoveryEvidenceDigest") {
		return bad()
	}
	v, vok := integer(p["contractVersion"])
	pid, pok := integer(p["processId"])
	gen, gok := integer(p["generation"])
	if !vok || v != 2 || !pok || pid < 1 || pid > 4294967295 || !gok || gen < 1 || gen > 4294967295 || text(p["requestNonce"]) == "" || text(p["processNonce"]) == "" || text(p["snapshotId"]) == "" || !versionAllowed(text(p["engineVersion"])) || j.EngineVersion != "" && p["engineVersion"] != j.EngineVersion || p["loaderContractId"] != j.LoaderContractID || !strings.HasPrefix(j.LoaderContractID, "ctxhop-prestart-v2:") || p["inputComplete"] != true || p["sqliteRedirect"] != false || !opRE.MatchString(text(p["acquisitionId"])) || !hashRE.MatchString(text(p["storeObservationDigest"])) || p["mappingProfile"] != approvalProfile || j.ApprovalEvidence == nil || p["approvalEvidenceDigest"] != j.ApprovalEvidence.ManifestSHA256 || !hashRE.MatchString(text(p["approvedMappingDigest"])) {
		return bad()
	}
	d, e := selfDigest(p, "projectionDigest")
	if len(j.LoaderContractID) == len("ctxhop-prestart-v2:") {
		return bad()
	}
	if e != nil || p["projectionDigest"] != d {
		return bad()
	}
	var recovery any
	if j.RecoveryEvidence != nil {
		recovery = j.RecoveryEvidence.ManifestSHA256
	}
	if p["recoveryEvidenceDigest"] != recovery {
		return bad()
	}
	for _, key := range []string{"home", "normalSqliteHome", "operationSqliteHome"} {
		if !samePath(text(p[key]), j.Home) {
			return bad()
		}
	}
	if !samePath(text(p["stateDb"]), filepath.Join(j.Home, "state_5.sqlite")) {
		return bad()
	}
	if _, e := validateStoreTargetsV2(p["proofTargets"], j.Home); e != nil {
		return bad()
	}
	if _, e := validateStoreTargetsV2(p["writeTargets"], j.Home); e != nil {
		return bad()
	}
	effects := obj(p["effects"])
	writes, wok := integer(effects["applicationWrites"])
	network, nok := integer(effects["networkRequests"])
	if !exact(effects, "applicationWrites", "networkRequests", "sqliteShmMayChange", "privateSqliteSidecarsMayChange") || !wok || !nok || writes != 0 || network != 0 || effects["sqliteShmMayChange"] != false || effects["privateSqliteSidecarsMayChange"] != true || p["authResolution"] != "resolved" || p["policyResolution"] != "resolved" {
		return bad()
	}
	valid := obj(p["validity"])
	if !exact(valid, "kind", "revision", "expiresAt") || valid["kind"] != "normal-loader-semantics" || text(valid["revision"]) == "" {
		return bad()
	}
	if expiry := valid["expiresAt"]; expiry != nil {
		// Match the live completed wire format, without checking current time.
		if _, e := time.Parse(time.RFC3339, text(expiry)); e != nil {
			return bad()
		}
	}
	projects, ok := p["projectConfig"].([]any)
	if !ok {
		return bad()
	}
	for _, v := range projects {
		c := obj(v)
		_, applied := c["applied"].(bool)
		_, warning := c["warning"].(string)
		if !exact(c, "path", "applied", "warning") || !filepath.IsAbs(text(c["path"])) || !applied || c["warning"] != nil && !warning {
			return bad()
		}
	}
	present := make([]bool, len(storeSpecs))
	for i := range present {
		present[i] = true
	}
	if e := validateStoreProofV2(p["storeProof"], text(p["storeObservationDigest"]), j.Members, present); e != nil {
		return bad()
	}
	retained := make([]bool, len(j.Members))
	if target == "rolled_back" {
		store, e := normalizedStoreValue(p["storeProof"])
		if e != nil {
			return bad()
		}
		for i, row := range array(obj(store)["members"]) {
			for _, v := range array(obj(row)["relations"]) {
				r := obj(v)
				key := text(r["kind"]) + "." + text(r["relationClass"])
				for scope, value := range obj(r["counts"]) {
					n, _ := integer(value)
					if n != 0 {
						if scope != "passive" || !passiveFinalizationKind(key) {
							return bad()
						}
						retained[i] = true
					}
				}
			}
		}
	}
	contexts, ok := p["contexts"].([]any)
	if !ok || len(contexts) != len(j.Members)+1 {
		return bad()
	}
	seen := map[string]bool{}
	memberPhase := ""
	for i, v := range contexts {
		c := obj(v)
		id := text(c["contextId"])
		if !exact(c, "memberId", "ownerId", "phase", "cwd", "rolloutSha256", "settingsDigest", "contextId", "sqliteHome") || id == "" || seen[id] || !samePath(text(c["cwd"]), j.Cwd) || !samePath(text(c["sqliteHome"]), j.Home) {
			return bad()
		}
		seen[id] = true
		if i == 0 {
			if c["phase"] != "startup" || c["memberId"] != nil || c["ownerId"] != nil || c["rolloutSha256"] != nil || c["settingsDigest"] != nil {
				return bad()
			}
			continue
		}
		m := j.Members[i-1]
		if c["memberId"] != m.ID {
			return bad()
		}
		phase := text(c["phase"])
		if target == "rolled_back" {
			wantPhase := "rollbackAbsent"
			if retained[i-1] {
				wantPhase = "rollbackRetained"
			}
			if phase != wantPhase || c["ownerId"] != m.ID || c["rolloutSha256"] != nil || c["settingsDigest"] != nil {
				return bad()
			}
		} else if target == "complete" {
			// A validated cold resume can observe appended live bytes. Its full
			// recorded hash is historical; the immutable mapping remains original.
			if phase != "firstResume" && phase != "coldResume" || c["ownerId"] != m.ID && (m.Parent == nil || c["ownerId"] != *m.Parent) || !hashRE.MatchString(text(c["rolloutSha256"])) || phase == "firstResume" && c["rolloutSha256"] != m.SHA256 || !hashRE.MatchString(text(c["settingsDigest"])) {
				return bad()
			}
			if memberPhase != "" && memberPhase != phase {
				return bad()
			}
			memberPhase = phase
		} else {
			return bad()
		}
	}
	return nil
}
