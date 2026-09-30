package main

import "testing"

func TestStateSessionSourceUnknownNeverMeansNoParent(t *testing.T) {
	for _, raw := range []string{"cli", "vscode", "exec", "mcp", `{"custom":"desktop"}`, `{"internal":"guardian"}`, `{"subagent":"review"}`} {
		if parent, e := stateSourceParent(raw); e != nil || parent != "" {
			t.Fatal(raw, e, parent)
		}
	}
	parent, e := stateSourceParent(`{"subagent":{"thread_spawn":{"parent_thread_id":"` + rootID + `","depth":1,"agent_path":"/root/child","agent_role":null}}}`)
	if e != nil || parent != rootID {
		t.Fatal(e, parent)
	}
	for _, raw := range []string{"unknown", "future-source", `{"subagent":{"future":{"parent_thread_id":"` + rootID + `"}}}`, `{"subagent":{"thread_spawn":{"parent_thread_id":"bad","depth":1}}}`, `{"subagent":{"thread_spawn":{"parent_thread_id":"` + rootID + `","depth":1,"unexpected":true}}}`} {
		if _, e := stateSourceParent(raw); e == nil {
			t.Fatal("unknown/malformed source accepted", raw)
		}
	}
}
