package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEveryJournalPhaseFailure(t *testing.T) {
	for _, phase := range []string{"created", "staged", "placing", "placed", "engine", "settled", "verified", "archived"} {
		t.Run(phase, func(t *testing.T) {
			o, m := importFixture(t, "paginated", phase == "archived")
			oldAdvance, oldStage := advanceJournal, stageFile
			defer func() { advanceJournal = oldAdvance; stageFile = oldStage }()
			if phase == "created" {
				stageFile = func(path string, b []byte) error { return fail("injected", "stage interruption") }
			} else {
				advanceJournal = func(run string, j *journal, p string) error {
					if e := oldAdvance(run, j, p); e != nil {
						return e
					}
					if p == phase {
						return fail("injected", "journal interruption")
					}
					return nil
				}
			}
			r, e := importArchive(o)
			assertCode(t, e, "injected")
			if m.Deletes != 0 || m.Active {
				t.Fatal("automatic delete/active Job", m.Deletes)
			}
			want := "pending"
			if phase == "created" || phase == "staged" {
				want = "rolled_back"
			}
			if r["status"] != want {
				t.Fatal(r)
			}
			advanceJournal = oldAdvance
			stageFile = oldStage
			r, e = rollback(o)
			if e != nil || r["status"] != "rolled_back" {
				t.Fatalf("manual recovery %v %v", r, e)
			}
			j, e := loadJournal(o.Home, o.Run)
			if e != nil || j.Status != "rolled_back" {
				t.Fatal(e, j)
			}
		})
	}
}
func TestRollbackFileMissingDBRowAndEdgesStops(t *testing.T) {
	o, m := importFixture(t, "legacy", false)
	m.Fail = "thread/resume"
	_, e := importArchive(o)
	assertCode(t, e, "injected")
	m.Fail = ""
	j, _ := loadJournal(o.Home, o.Run)
	os.Remove(j.Members[0].Path)
	_, e = rollback(o)
	assertCode(t, e, "missing_rollout_metadata")
	if m.Deletes != 0 {
		t.Fatal("deleted metadata-only thread")
	}
}
func TestCleanupFailureRemainsPending(t *testing.T) {
	o, m := importFixture(t, "legacy", false)
	oldAdvance := advanceJournal
	defer func() { advanceJournal = oldAdvance }()
	advanceJournal = func(run string, j *journal, p string) error {
		if e := oldAdvance(run, j, p); e != nil {
			return e
		}
		if p == "verified" {
			system, e := systemDirectory()
			if e != nil {
				return e
			}
			target := t.TempDir()
			link := filepath.Join(run, "stage", "outside-link")
			os.MkdirAll(filepath.Dir(link), 0700)
			return makeJunction(system, link, target)
		}
		return nil
	}
	r, e := importArchive(o)
	if e == nil || r["status"] != "pending" || m.Deletes != 0 {
		t.Fatal(r, e)
	}
	j, _ := loadJournal(o.Home, o.Run)
	if j.Status != "pending" {
		t.Fatal("false complete")
	}
}
func TestJSONDepthLimit(t *testing.T) {
	b := []byte{}
	for i := 0; i < 130; i++ {
		b = append(b, '[')
	}
	for i := 0; i < 130; i++ {
		b = append(b, ']')
	}
	_, e := parseJSON(b)
	assertCode(t, e, "invalid_json")
}
