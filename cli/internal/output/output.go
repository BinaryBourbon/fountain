// Package output: shared CLI rendering helpers (tables, JSON, truncation).
package output

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// PrintJSON pretty-prints v as JSON to stdout.
func PrintJSON(v any) error {
	buf, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(buf))
	return nil
}

// Table prints a column-aligned table. Columns are separated by two
// spaces; a separator row of dashes follows the header.
func Table(headers []string, rows [][]string) {
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = utf8.RuneCountInString(h)
	}
	for _, r := range rows {
		for i, c := range r {
			if i >= len(widths) {
				continue
			}
			if w := utf8.RuneCountInString(c); w > widths[i] {
				widths[i] = w
			}
		}
	}

	cells := make([]string, len(headers))
	for i, h := range headers {
		cells[i] = padRight(h, widths[i])
	}
	fmt.Println(strings.Join(cells, "  "))

	dashes := make([]string, len(widths))
	for i, w := range widths {
		dashes[i] = strings.Repeat("-", w)
	}
	fmt.Println(strings.Join(dashes, "  "))

	for _, r := range rows {
		row := make([]string, len(widths))
		for i := range widths {
			v := ""
			if i < len(r) {
				v = r[i]
			}
			row[i] = padRight(v, widths[i])
		}
		fmt.Println(strings.Join(row, "  "))
	}
}

func padRight(s string, n int) string {
	pad := n - utf8.RuneCountInString(s)
	if pad <= 0 {
		return s
	}
	return s + strings.Repeat(" ", pad)
}

// Truncate returns s truncated to n runes with an ellipsis if needed.
func Truncate(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	runes := []rune(s)
	return string(runes[:n]) + "…"
}

// ShortID returns the first 8 chars of an id (for compact tables).
func ShortID(s string) string {
	if len(s) >= 8 {
		return s[:8]
	}
	return s
}

// ToString renders any JSON-decoded value as a printable string.
func ToString(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		// json.Unmarshal yields float64 for numbers; render integers cleanly.
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return fmt.Sprintf("%g", x)
	default:
		return fmt.Sprintf("%v", x)
	}
}
