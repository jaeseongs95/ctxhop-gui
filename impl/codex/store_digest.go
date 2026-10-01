package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"unicode/utf8"
)

// Digest-only JSON, separate from ordinary pipe encoding. All numeric values
// in v2 observations/proof summaries are exact i64 integers, never float64.
func storeCanonicalJSON(value any) ([]byte, error) {
	var normalize func(any, int) (any, error)
	normalize = func(value any, depth int) (any, error) {
		if depth > 128 {
			return nil, fmt.Errorf("store digest depth limit")
		}
		switch v := value.(type) {
		case nil, bool, int, int64:
			return v, nil
		case string:
			if !utf8.ValidString(v) {
				return nil, fmt.Errorf("store digest invalid UTF-8")
			}
			return v, nil
		case json.Number:
			n, e := v.Int64()
			if e != nil {
				u, unsignedError := strconv.ParseUint(v.String(), 10, 64)
				if unsignedError != nil { return nil, fmt.Errorf("digest exact integer required: %w", e) }
				return u, nil
			}
			return n, nil
		case object:
			result := object{}
			for key, entry := range v {
				if !utf8.ValidString(key) {
					return nil, fmt.Errorf("store digest invalid key UTF-8")
				}
				n, e := normalize(entry, depth+1)
				if e != nil {
					return nil, e
				}
				result[key] = n
			}
			return result, nil
		case []any:
			result := make([]any, len(v))
			for i, entry := range v {
				n, e := normalize(entry, depth+1)
				if e != nil {
					return nil, e
				}
				result[i] = n
			}
			return result, nil
		default:
			return nil, fmt.Errorf("store digest unsupported type %T", value)
		}
	}
	v, e := normalize(value, 0)
	if e != nil {
		return nil, e
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false) // recursively sorted object keys, compact UTF-8
	if e := encoder.Encode(v); e != nil {
		return nil, e
	}
	raw := bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'})
	if len(raw) > lineLimit {
		return nil, fmt.Errorf("store digest frame limit")
	}
	// encoding/json still escapes U+2028/U+2029. Decode only real JSON escapes;
	// an escaped backslash followed by literal "u2028" must stay literal.
	result := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		if raw[i] == '\\' && i+1 < len(raw) {
			if i+6 <= len(raw) && (string(raw[i:i+6]) == `\u2028` || string(raw[i:i+6]) == `\u2029`) {
				if raw[i+5] == '8' {
					result = append(result, []byte("\u2028")...)
				} else {
					result = append(result, []byte("\u2029")...)
				}
				i += 5
			} else {
				result = append(result, raw[i], raw[i+1])
				i++
			}
		} else {
			result = append(result, raw[i])
		}
	}
	return result, nil
}
