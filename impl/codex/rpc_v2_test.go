package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestRPCV2ExactExternalBinding(t *testing.T) {
	s := &session{Projection: projection(options{Home: t.TempDir(), Cwd: t.TempDir()}, "import", nil, false), Operation: "import"}
	s.bind()
	if e := validateRPCBindingV2(s.Binding); e != nil || len(s.Binding) != 7 {
		t.Fatal("external exact7 binding", e)
	}
	for _, value := range []any{nil, "2", true, num(1), num(0), json.Number("2.0"), json.Number("2e0")} {
		q := obj(clone(s.Binding))
		q["contractVersion"] = value
		if e := validateRPCBindingV2(q); e == nil {
			t.Fatalf("version type accepted: %v", value)
		}
	}
	for _, key := range []string{"contractVersion", "requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest", "operation"} {
		q := obj(clone(s.Binding))
		delete(q, key)
		if e := validateRPCBindingV2(q); e == nil {
			t.Fatal("missing binding field", key)
		}
	}
	for _, mutation := range []func(object){
		func(q object) { q["storeProof"] = nil },
		func(q object) { q["generation"] = json.Number("9223372036854775808") },
		func(q object) { q["generation"] = num(0) },
		func(q object) { q["operation"] = "delete" },
		func(q object) { q["snapshotId"] = true },
	} {
		q := obj(clone(s.Binding))
		mutation(q)
		if e := validateRPCBindingV2(q); e == nil {
			t.Fatal("malformed binding accepted")
		}
	}
	if e := validateRPCBindingV2(object{"acquisitionId": nil, "storeObservationDigest": nil, "storeProof": nil}); e == nil {
		t.Fatal("projection subobject replaced external binding")
	}
	for _, raw := range []string{
		`{"contractVersion":2,"contractVersion":2}`,
		`{"contractVersion":2,"requestNonce":"x","requestNonce":"x"}`,
	} {
		if _, e := parseJSON([]byte(raw)); e == nil {
			t.Fatal("duplicate wire key accepted")
		}
	}
}

func TestRPCV2ProjectionObservationAndTargets(t *testing.T) {
	old := loaderContractID
	loaderContractID = "ctxhop-prestart-v2:fixture"
	defer func() { loaderContractID = old }()
	o := options{Home: t.TempDir(), Cwd: t.TempDir()}
	f := fixtureFamily("legacy")
	if e := support(f, o.Home); e != nil {
		t.Fatal(e)
	}
	partial := projection(o, "import", nil, false)
	o = fixtureApproval(t, o, f)
	if e := validateProjection(partial, "nonce", "import", o, nil, 123, nil); e != nil {
		t.Fatal("partial with explicit nulls", e)
	}
	for _, op := range []string{"plan", "bootstrap"} {
		p := projection(o, op, nil, true)
		if e := validateProjection(p, "nonce", op, o, nil, 123, nil); e != nil {
			t.Fatal("read-free projection", op, e)
		}
	}
	obs := mockStoreObservation(text(partial["stateDb"]), strings.Repeat("a", 64), nil)
	complete := projection(o, "import", f.Members, true)
	mockStoreCompleted(t, complete, obs, f.Members)
	if e := validateProjection(complete, "nonce", "import", o, f.Members, 123, obs); e != nil {
		t.Fatal(e)
	}
	if e := validateProjection(complete, "nonce", "import", o, f.Members, 123, nil); e == nil {
		t.Fatal("completed proof without actual observation accepted")
	}
	for _, mutation := range []struct {
		name string
		f    func(object)
	}{
		{"v1", func(q object) { q["contractVersion"] = num(1) }},
		{"no-version", func(q object) { delete(q, "contractVersion") }},
		{"no-proofTargets", func(q object) { delete(q, "proofTargets") }},
		{"no-proof", func(q object) { delete(q, "storeProof") }},
		{"no-digest", func(q object) { delete(q, "storeObservationDigest") }},
		{"write7", func(q object) { q["writeTargets"] = array(q["writeTargets"])[:7] }},
		{"proof7", func(q object) { q["proofTargets"] = array(q["proofTargets"])[:7] }},
		{"write-order", func(q object) { a := array(q["writeTargets"]); a[6], a[7] = a[7], a[6] }},
		{"proof-order", func(q object) { a := array(q["proofTargets"]); a[6], a[7] = a[7], a[6] }},
		{"board-path", func(q object) { obj(array(q["proofTargets"])[7])["path"] = text(q["stateDb"]) }},
		{"v1-loader", func(q object) { q["loaderContractId"] = "ctxhop-prestart-v1:fixture" }},
		{"acquisition", func(q object) { q["acquisitionId"] = strings.Repeat("b", 32) }},
		{"digest", func(q object) { q["storeObservationDigest"] = strings.Repeat("b", 64) }},
		{"proof-digest", func(q object) { obj(q["storeProof"])["observationDigest"] = strings.Repeat("b", 64) }},
		{"absent-nonzero", func(q object) {
			obj(obj(array(obj(array(obj(q["storeProof"])["members"])[0])["relations"])[9])["counts"])["active"] = num(1)
		}},
	} {
		t.Run(mutation.name, func(t *testing.T) {
			q := obj(clone(complete))
			mutation.f(q)
			if e := validateProjection(q, "nonce", "import", o, f.Members, 123, obs); e == nil {
				t.Fatal("invalid v2 projection accepted")
			}
		})
	}
	for _, key := range []string{"acquisitionId", "storeObservationDigest", "storeProof"} {
		q := obj(clone(partial))
		q[key] = complete[key]
		if e := validateProjection(q, "nonce", "import", o, nil, 123, nil); e == nil {
			t.Fatal("non-null partial proof", key)
		}
	}
	loaderContractID = "ctxhop-prestart-v1:fixture"
	partial["loaderContractId"] = loaderContractID
	if e := validateProjection(partial, "nonce", "import", o, nil, 123, nil); e == nil {
		t.Fatal("compiled legacy loader pin accepted")
	}
}

func TestRPCV2CompleteAndActivationBindings(t *testing.T) {
	for _, variant := range []string{"valid", "count-mismatch", "digest-mismatch", "old-generation", "process", "snapshot", "extra", "accept-extra", "activate-version"} {
		t.Run(variant, func(t *testing.T) {
			f := fixtureFamily("legacy")
			m := installMock(t, f)
			o := options{Home: t.TempDir(), Cwd: t.TempDir()}
			if e := support(f, o.Home); e != nil {
				t.Fatal(e)
			}
			for _, member := range f.Members {
				if e := createFile(member.Path, member.Raw); e != nil {
					t.Fatal(e)
				}
			}
			s, e := m.prepare(o, "import", f.Members)
			if e != nil {
				t.Fatal(e)
			}
			o = s.Options
			defer s.Close()
			obs := mockStoreObservation(text(s.Projection["stateDb"]), strings.Repeat("a", 64), nil)
			completed := projection(o, "import", f.Members, true)
			mockStoreCompleted(t, completed, obs, f.Members)
			v := dbView{StoreObservation: obs, StoreProof: completed["storeProof"].(object)}
			before := encoded(s.Projection)
			call := s.Call
			calls := 0
			s.Call = func(method string, p object) (object, error) {
				if method == "ctxhop/complete" {
					calls++
					if !exact(p, "contractVersion", "requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest", "operation", "storeObservation") || !bytes.Equal(encoded(p["storeObservation"]), encoded(obs)) {
						t.Fatal("complete request is not exact8 with the same observation")
					}
				}
				r, e := call(method, p)
				if e != nil {
					return r, e
				}
				if method == "ctxhop/complete" {
					switch variant {
					case "count-mismatch":
						obj(obj(array(obj(array(obj(r["storeProof"])["members"])[0])["relations"])[0])["counts"])["active"] = num(1)
					case "digest-mismatch":
						r["storeObservationDigest"] = strings.Repeat("b", 64)
					case "old-generation":
						r["generation"] = num(1)
					case "process":
						r["processNonce"] = "other"
					case "snapshot":
						r["snapshotId"] = "other"
					case "extra":
						r["unexpected"] = true
					}
				}
				if method == "ctxhop/accept" && variant == "accept-extra" {
					r["unexpected"] = true
				}
				if method == "ctxhop/activate" && variant == "activate-version" {
					r["contractVersion"] = num(1)
				}
				return r, nil
			}
			if e = s.complete(v); variant != "valid" && variant != "accept-extra" && variant != "activate-version" {
				if e == nil || calls != 1 || !bytes.Equal(before, encoded(s.Projection)) {
					t.Fatal("invalid complete replaced retained partial projection", e)
				}
				return
			} else if e != nil || calls != 1 || len(s.Binding) != 7 {
				t.Fatal("valid complete", e)
			}
			if e = s.activate(); variant == "valid" {
				if e != nil {
					t.Fatal(e)
				}
			} else if e == nil {
				t.Fatal("invalid activation response accepted")
			}
		})
	}
}

func TestRPCV2NeverPromotesV1OrUnlocksProduction(t *testing.T) {
	s := &session{Projection: projection(options{Home: t.TempDir()}, "import", nil, false)}
	s.Call = func(string, object) (object, error) { t.Fatal("invalid observation reached provider"); return nil, nil }
	if e := s.complete(dbView{Observation: mockObservation(text(s.Projection["stateDb"]), strings.Repeat("a", 64), nil)}); e == nil {
		t.Fatal("state-only v1 promoted")
	}
	s.P = &process{}
	if e := s.complete(dbView{}); e == nil {
		t.Fatal("production schema/metadata/inventory gate unlocked")
	}
}

func TestEngineEnvironmentPreservesParentTemp(t *testing.T) {
	t.Setenv("TEMP", t.TempDir())
	t.Setenv("TMP", t.TempDir())
	t.Setenv("CODEX_HOME", "unapproved-parent-home")
	// These unsupported overrides are rejected even when inherited.
	for _, key := range []string{"CODEX_SQLITE_HOME", "CODEX_APP_SERVER_TEST_USER_CONFIG_FILE"} {
		if _, ok := os.LookupEnv(key); ok {
			t.Fatal("fixture inherited unsupported DB/config override")
		}
	}
	home := t.TempDir()
	env, e := processEnv(home)
	if e != nil {
		t.Fatal(e)
	}
	got := map[string][]string{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		got[strings.ToUpper(key)] = append(got[strings.ToUpper(key)], value)
	}
	for key, want := range map[string]string{"TEMP": os.Getenv("TEMP"), "TMP": os.Getenv("TMP"), "CODEX_HOME": home} {
		if len(got[key]) != 1 || got[key][0] != want {
			t.Fatal("parent environment replaced or home not bound", key, got[key])
		}
	}
	t.Setenv("CODEX_SQLITE_HOME", home)
	if _, e := processEnv(home); e == nil {
		t.Fatal("DB redirection accepted")
	}
}
