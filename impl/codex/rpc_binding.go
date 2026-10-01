package main

// The external binding is exact seven fields; the store projection's separate
// three-field binding must never replace it.
func validateRPCBindingV2(raw any) error {
	v, e := normalizedStoreValue(raw)
	if e != nil {
		return e
	}
	b := obj(v)
	version, vok := integer(b["contractVersion"])
	generation, gok := integer(b["generation"])
	if !exact(b, "contractVersion", "requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest", "operation") || !vok || version != 2 || !gok || generation < 1 || text(b["requestNonce"]) == "" || text(b["processNonce"]) == "" || text(b["snapshotId"]) == "" || !hashRE.MatchString(text(b["projectionDigest"])) {
		return fail("prestart_binding", "v2 exact7 외부 binding 오류")
	}
	switch b["operation"] {
	case "plan", "bootstrap", "import", "cold", "reference", "rollback", "rollback-check":
		return nil
	default:
		return fail("prestart_binding", "v2 binding operation 오류")
	}
}
