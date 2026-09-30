package main

import (
	_ "embed"
	"encoding/json"
	"testing"
)

// Frozen from root catalog/golden commit 8b8ab2598c6d96f6a65b93c7d0567e64b6383c96.
//
//go:embed store-proof-v2-golden.json
var storeDigestGolden []byte

func TestStoreDigestSharedGolden(t *testing.T) {
	if digest(storeDigestGolden) != "dffec31fd3375b2514f9ac96b1b79352c5b4363a31bb268e4725bb9c8b81dbe8" {
		t.Fatal("frozen root golden bytes changed")
	}
	v, e := parseJSON(storeDigestGolden)
	if e != nil {
		t.Fatal(e)
	}
	if !exact(obj(v), "schemaVersion", "cases") || len(array(obj(v)["cases"])) != 5 {
		t.Fatal("golden shape")
	}
	for _, entry := range array(obj(v)["cases"]) {
		item := obj(entry)
		t.Run(text(item["name"]), func(t *testing.T) {
			if !exact(item, "name", "inputJson", "canonicalUtf8", "sha256") {
				t.Fatal("golden unknown/missing fields")
			}
			input, e := parseJSON([]byte(text(item["inputJson"])))
			if e != nil {
				t.Fatal(e)
			}
			b, e := storeCanonicalJSON(input)
			if e != nil || string(b) != text(item["canonicalUtf8"]) || digest(b) != text(item["sha256"]) {
				t.Fatal("canonical bytes/hash differ", string(b), e)
			}
		})
	}
}

func TestStoreDigestPrecisionAndEscapeBoundaries(t *testing.T) {
	v, e := parseJSON([]byte(`{"text":"\\u2028\u2028\\\\u2029\u2029","keys":{"🙂":null,"한글":true,"a":0}}`))
	if e != nil {
		t.Fatal(e)
	}
	b, e := storeCanonicalJSON(v)
	if e != nil {
		t.Fatal(e)
	}
	back, e := parseJSON(b)
	if e != nil || text(obj(back)["text"]) != text(obj(v)["text"]) {
		t.Fatal("literal escape mutated", e)
	}
	if digest(b) == digest(encoded(v)) {
		t.Fatal("digest serializer did not preserve raw U+2028/U+2029")
	}
	for _, value := range []any{json.Number("9223372036854775808"), json.Number("1.0"), json.Number("1e0"), float64(1), "\xff", object{"\xff": nil}} {
		if _, e := storeCanonicalJSON(value); e == nil {
			t.Fatal("invalid precision/UTF-8 accepted", value)
		}
	}
	if _, e := parseJSON([]byte(`{"count":1,"count":2}`)); e == nil {
		t.Fatal("duplicate JSON key accepted before digest")
	}
}
