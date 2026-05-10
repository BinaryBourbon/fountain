// Package sse is a minimal RFC 6202 Server-Sent Events parser.
package sse

import (
	"encoding/json"
	"strconv"
	"strings"
)

// Event is one SSE message. Data is JSON-decoded if it parses, or the raw
// concatenated string otherwise.
type Event struct {
	ID    int
	Event string
	Data  any
	// rawData is preserved for callers that need the original string form.
	rawData string
}

// RawData returns the concatenated raw string form of the event's data field.
func (e *Event) RawData() string { return e.rawData }

// Feed parses complete events out of buffer. Returns events and any
// trailing partial event left in the buffer (the caller must prepend it
// to the next read before calling Feed again).
func Feed(buffer string) (events []Event, leftover string) {
	parts := strings.Split(buffer, "\n\n")
	if len(parts) == 0 {
		return nil, ""
	}
	leftover = parts[len(parts)-1]
	for _, block := range parts[:len(parts)-1] {
		if ev, ok := parse(block); ok {
			events = append(events, ev)
		}
	}
	return events, leftover
}

func parse(block string) (Event, bool) {
	if block == "" || strings.HasPrefix(block, ":") {
		return Event{}, false
	}
	var ev Event
	var dataLines []string
	for _, line := range strings.Split(block, "\n") {
		if line == "" {
			continue
		}
		key, val, ok := splitField(line)
		if !ok {
			continue
		}
		switch key {
		case "id":
			n, _ := strconv.Atoi(val)
			ev.ID = n
		case "event":
			ev.Event = val
		case "data":
			dataLines = append(dataLines, val)
		}
	}
	if ev.Event == "" && len(dataLines) == 0 && ev.ID == 0 {
		return Event{}, false
	}
	if len(dataLines) > 0 {
		raw := strings.Join(dataLines, "\n")
		ev.rawData = raw
		var decoded any
		if json.Unmarshal([]byte(raw), &decoded) == nil {
			ev.Data = decoded
		} else {
			ev.Data = raw
		}
	}
	return ev, true
}

// splitField parses an SSE field line. The Elixir parser used `": "` as
// separator (value-with-leading-space form); the spec also allows `:`
// alone. We accept either.
func splitField(line string) (key, val string, ok bool) {
	idx := strings.Index(line, ":")
	if idx < 0 {
		return "", "", false
	}
	key = line[:idx]
	val = strings.TrimPrefix(line[idx+1:], " ")
	return key, val, true
}
