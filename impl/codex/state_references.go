package main

// Narrow fail-closed interpretation of the frozen vendor SessionSource encoding
// (protocol.rs SessionSource/SubAgentSource; state/extract.rs enum_to_string).
// Unknown variants never become a claim of no parent reference.
func stateSourceParent(raw string) (string, error) {
	switch raw {
	case "cli", "vscode", "exec", "mcp":
		return "", nil
	}
	v, e := parseJSON([]byte(raw))
	if e != nil {
		return "", fail("engine_db_unknown", "SessionSource 구조 불명")
	}
	s := obj(v)
	if exact(s, "custom") && text(s["custom"]) != "" {
		return "", nil
	}
	if exact(s, "internal") && (s["internal"] == "memory_consolidation" || s["internal"] == "guardian") {
		return "", nil
	}
	if !exact(s, "subagent") {
		return "", fail("engine_db_unknown", "SessionSource variant 불명")
	}
	switch s["subagent"] {
	case "review", "compact", "memory_consolidation":
		return "", nil
	}
	sub := obj(s["subagent"])
	if exact(sub, "other") && text(sub["other"]) != "" {
		return "", nil
	}
	if !exact(sub, "thread_spawn") {
		return "", fail("engine_db_unknown", "SubAgentSource variant 불명")
	}
	spawn := obj(sub["thread_spawn"])
	depth, ok := integer(spawn["depth"])
	if !ok || depth < 0 || depth > 2147483647 || !uuidRE.MatchString(text(spawn["parent_thread_id"])) {
		return "", fail("engine_db_unknown", "ThreadSpawn parent/depth 오류")
	}
	for key, value := range spawn {
		switch key {
		case "parent_thread_id", "depth":
		case "agent_nickname", "agent_role", "agent_type", "agent_path":
			if _, valid := value.(string); value != nil && !valid {
				return "", fail("engine_db_unknown", "ThreadSpawn optional input 불명")
			}
		default:
			return "", fail("engine_db_unknown", "ThreadSpawn unknown field")
		}
	}
	if _, role := spawn["agent_role"]; role {
		if _, alias := spawn["agent_type"]; alias {
			return "", fail("engine_db_unknown", "ThreadSpawn role alias 중복")
		}
	}
	return text(spawn["parent_thread_id"]), nil
}
