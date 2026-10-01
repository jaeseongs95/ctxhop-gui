//go:build windows && (ctxhop_schema_export || ctxhop_backend_sequence || ctxhop_store_seed)

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"testing"
)

var fixtureMetadataPath = flag.String("ctxhop-fixture-metadata", "", "caller-owned absolute fixture metadata JSON")
var fixtureMetadataSHA = flag.String("ctxhop-fixture-metadata-sha256", "", "caller-reviewed metadata SHA256")
var fixtureWriteName = regexp.MustCompile(`^(helper3-r45-fixture-[A-Za-z0-9_-]+|ctxhop-prestart-[a-f0-9]{32})$`)
var fixtureCommitRE = regexp.MustCompile(`^[a-f0-9]{40}$`)
var fixtureMetadataKeys = []string{"schemaVersion", "writeRoots", "readRoots", "sourceRepository", "stateRepository", "toolchainScript", "toolchainScriptSha256", "schemaOriginReport", "schemaOriginReportSha256", "schemaOriginSource", "backendRustExecutable", "backendRustExecutableSha256", "backendRustArtifact", "backendRustArtifactSha256", "backendRustSourceCommit", "seedNamespaceParent", "backendNamespaceParent"}

func decodeFixtureMetadata(raw []byte, expected string) (object, error) {
	if len(raw) > 64<<10 || !hashRE.MatchString(expected) || digest(raw) != expected {
		return nil, fmt.Errorf("fixture metadata bytes/hash")
	}
	v, e := parseJSON(raw)
	m := obj(v)
	if e != nil || !exact(m, fixtureMetadataKeys...) {
		return nil, fmt.Errorf("fixture metadata exact17/UTF-8/duplicate keys")
	}
	version, ok := integer(m["schemaVersion"])
	if !ok || version != 1 {
		return nil, fmt.Errorf("fixture metadata version")
	}
	for _, key := range []string{"writeRoots", "readRoots"} {
		roots := array(m[key])
		if len(roots) == 0 || len(roots) > 64 {
			return nil, fmt.Errorf("fixture metadata roots")
		}
		for _, value := range roots {
			p, ok := value.(string)
			if !ok || !filepath.IsAbs(p) || filepath.Clean(p) != p || samePath(p, filepath.VolumeName(p)+string(filepath.Separator)) || key == "writeRoots" && !fixtureWriteName.MatchString(filepath.Base(p)) {
				return nil, fmt.Errorf("fixture metadata root containment")
			}
			if e := noReparse(p); e != nil {
				return nil, e
			}
		}
	}
	for _, key := range fixtureMetadataKeys[3:] {
		if m[key] == nil {
			continue
		}
		p, ok := m[key].(string)
		if !ok || p == "" {
			return nil, fmt.Errorf("fixture metadata nullable string %s", key)
		}
		switch key {
		case "toolchainScriptSha256", "schemaOriginReportSha256", "backendRustExecutableSha256", "backendRustArtifactSha256":
			if !hashRE.MatchString(p) {
				return nil, fmt.Errorf("fixture metadata hash %s", key)
			}
		case "backendRustSourceCommit":
			if !fixtureCommitRE.MatchString(p) {
				return nil, fmt.Errorf("fixture metadata source commit")
			}
		default:
			if !filepath.IsAbs(p) || filepath.Clean(p) != p {
				return nil, fmt.Errorf("fixture metadata absolute path %s", key)
			}
			if e := noReparse(p); e != nil {
				return nil, e
			}
		}
	}
	return m, nil
}
func loadFixtureMetadata() (object, error) {
	if !filepath.IsAbs(*fixtureMetadataPath) {
		return nil, fmt.Errorf("explicit absolute fixture metadata required")
	}
	b, e := readBounded(*fixtureMetadataPath, 64<<10)
	if e != nil {
		return nil, e
	}
	return decodeFixtureMetadata(b, *fixtureMetadataSHA)
}
func fixturePath(m object, path string, write bool) error {
	key := "readRoots"
	if write {
		key = "writeRoots"
	}
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return fmt.Errorf("fixture path must be canonical absolute")
	}
	for _, root := range array(m[key]) {
		if samePath(text(root), path) || within(text(root), path) {
			return noReparse(path)
		}
	}
	return fmt.Errorf("fixture path outside declared %s", key)
}
func fixtureSettingPath(m object, key string, write bool) (string, error) {
	p := text(m[key])
	return p, fixturePath(m, p, write)
}
func fixturePinnedFile(m object, pathKey, shaKey string, max int64) (data []byte, retErr error) {
	p, e := fixtureSettingPath(m, pathKey, false)
	if e != nil {
		return nil, e
	}
	entry, e := snapshotOpen(p, false)
	if e != nil {
		return nil, e
	}
	defer func() { retErr = errors.Join(retErr, entry.File.Close()) }()
	b, e := io.ReadAll(io.LimitReader(entry.File, max+1))
	if int64(len(b)) > max {
		return nil, fmt.Errorf("fixture file budget")
	}
	if e != nil || !hashRE.MatchString(text(m[shaKey])) || digest(b) != m[shaKey] {
		return nil, errors.Join(e, fmt.Errorf("fixture pin %s", pathKey))
	}
	return b, nil
}
func TestPortableFixtureMetadataBoundaries(t *testing.T) {
	root := filepath.Join(t.TempDir(), "ctxhop-prestart-"+nonce())
	m := object{"schemaVersion": int64(1), "writeRoots": []any{root}, "readRoots": []any{filepath.Dir(root)}}
	for _, key := range fixtureMetadataKeys[3:] {
		m[key] = nil
	}
	b := encoded(m)
	if _, e := decodeFixtureMetadata(b, digest(b)); e != nil {
		t.Fatal(e)
	}
	if e := fixturePath(m, filepath.Join(root, "case"), true); e != nil {
		t.Fatal(e)
	}
	if e := fixturePath(m, filepath.Join(filepath.Dir(root), "foreign"), true); e == nil {
		t.Fatal("foreign write root accepted")
	}
	for _, change := range []func(object){func(x object) { x["extra"] = true }, func(x object) { delete(x, "schemaOriginSource") }, func(x object) { x["schemaVersion"] = json.Number("1.5") }, func(x object) { x["writeRoots"] = []any{filepath.Dir(root)} }, func(x object) { x["backendRustExecutableSha256"] = "" }} {
		x := obj(clone(m))
		change(x)
		b = encoded(x)
		if _, e := decodeFixtureMetadata(b, digest(b)); e == nil {
			t.Fatal("invalid metadata accepted")
		}
	}
	if _, e := decodeFixtureMetadata(encoded(m), digest([]byte("different"))); e == nil {
		t.Fatal("wrong metadata SHA accepted")
	}
}
func TestPortableFixtureInput(t *testing.T) {
	if *fixtureMetadataPath == "" {
		t.Skip("requires explicit caller metadata; SQLite/process=0")
	}
	if _, e := loadFixtureMetadata(); e != nil {
		t.Fatal(e)
	}
	t.Log("caller metadata hash/absolute roots/nullable fields verified; SQLite/process=0")
}
