//go:build windows

package main

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestStoreBoardRootDomainDoesNotAliasChildMember(t *testing.T) {
	keys := relationTargets(t) // M={root,child}; Q={root}.
	for _, class := range []string{"post", "subscription", "optOut"} {
		t.Run(class, func(t *testing.T) {
			table := map[string]string{"post": "posts", "subscription": "subscriptions", "optOut": "subscription_opt_outs"}[class]
			row := func(board, peer string) []any {
				if class == "post" {
					return []any{board, peer + ":request", proofOutsideID, proofOutsideID, "/root"}
				}
				return []any{board, peer, `{"Channel":"general"}`}
			}
			fact, e := readStoreKeyRelations("agentMessageBoard", keys, mockStoreScan(map[string][][]any{table: {row(childID, rootID), row(childID, proofOutsideID)}}))
			if e != nil || len(fact.Relations) != 1 || fact.Relations[0].Scope != "externalIncoming" || fact.Relations[0].Owner != boardStoreKey(childID) {
				t.Fatal("M\\Q board must be external; unrelated peer must be excluded", fact, e)
			}
			facts := make([]storeKeyEvidence, len(storeSpecs))
			for i, spec := range storeSpecs {
				facts[i].Kind = spec.Kind
			}
			facts[7] = fact
			proof, e := projectStoreKeyProof(facts, keys, []bool{true, false, false, false, false, false, false, true}, strings.Repeat("a", 64))
			if e != nil {
				t.Fatal(e)
			}
			for i, member := range array(proof["members"]) {
				for _, raw := range array(obj(member)["relations"]) {
					r := obj(raw)
					if r["kind"] != "agentMessageBoard" || r["relationClass"] != class {
						continue
					}
					for scope, value := range obj(r["counts"]) {
						want := int64(0)
						if i == 0 && scope == "externalIncoming" {
							want = 1
						}
						if value != want {
							t.Fatal("external board UUID aliased member endpoint", i, scope, value)
						}
					}
				}
			}
			facts[7].Relations[0].Owner = threadStoreKey(childID)
			if _, e := projectStoreKeyProof(facts, keys, []bool{true, false, false, false, false, false, false, true}, strings.Repeat("a", 64)); e == nil {
				t.Fatal("board proof accepted thread-domain owner")
			}
		})
	}
}

// Cancel at a chosen aggregate phase boundary without adding production hooks.
// Err remains monotonic and Done closes before cancellation is returned.
type cancelAtStoreCheck struct {
	context.Context
	mu     sync.Mutex
	checks int
	at     int
	cancel context.CancelFunc
}

func (c *cancelAtStoreCheck) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.checks++
	if c.checks == c.at {
		c.cancel()
	}
	return c.Context.Err()
}

func TestStoreCancellationAfterReaderDrainNeverReturnsProof(t *testing.T) {
	for _, tc := range []struct {
		name string
		at   int
	}{
		{"after-final-verify", 9},
		{"after-key-reader", 10},
		{"after-observation", 11},
		{"after-observation-digest", 12},
		{"final-projection-return", 13},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			closeFixture := sqliteFixture(t, home, false, liveFixtureSQL(t)+liveFixtureThread(rootID))
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
			base, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx := &cancelAtStoreCheck{Context: base, at: tc.at, cancel: cancel}
			observation, proof, e := inspectPrivateStoreProof(ctx, s, relationTargets(t))
			if !errors.Is(e, context.Canceled) || observation != nil || proof != nil || s.ReadersOpen != 0 || ctx.checks < tc.at {
				t.Fatal("cancelled aggregate returned completed proof or undrained reader", e, s.ReadersOpen, ctx.checks)
			}
			if e := s.Close(true); e != nil {
				t.Fatal("cleanup after cancelled proof", e)
			}
			if e := s.VerifyReleasedSources(nil); e != nil {
				t.Fatal("freshness after cancelled reader drain", e)
			}
		})
	}
}
