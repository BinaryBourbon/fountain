package output

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

// captureStdout runs f with os.Stdout redirected to a pipe and returns what
// it printed. The package prints via fmt.Println, so this is the seam.
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = orig }()

	done := make(chan string)
	go func() {
		var buf bytes.Buffer
		io.Copy(&buf, r)
		done <- buf.String()
	}()

	f()
	w.Close()
	return <-done
}

func TestPrintJSON(t *testing.T) {
	got := captureStdout(t, func() {
		if err := PrintJSON(map[string]any{"name": "demo", "n": 2}); err != nil {
			t.Error(err)
		}
	})
	want := "{\n  \"n\": 2,\n  \"name\": \"demo\"\n}\n"
	if got != want {
		t.Fatalf("PrintJSON printed %q, want %q", got, want)
	}
}

func TestPrintJSONUnmarshalable(t *testing.T) {
	captureStdout(t, func() {
		if err := PrintJSON(func() {}); err == nil {
			t.Error("want error for unmarshalable value")
		}
	})
}

func TestTable(t *testing.T) {
	got := captureStdout(t, func() {
		Table([]string{"ID", "NAME"}, [][]string{
			{"1", "alpha"},
			{"22", "b"},
		})
	})
	want := strings.Join([]string{
		"ID  NAME ",
		"--  -----",
		"1   alpha",
		"22  b    ",
		"",
	}, "\n")
	if got != want {
		t.Fatalf("Table printed:\n%q\nwant:\n%q", got, want)
	}
}

func TestTableRaggedRows(t *testing.T) {
	// Rows shorter or longer than the header must not panic; extra cells
	// are dropped, missing cells render empty.
	got := captureStdout(t, func() {
		Table([]string{"A", "B"}, [][]string{
			{"1"},
			{"2", "3", "ignored"},
		})
	})
	want := strings.Join([]string{
		"A  B",
		"-  -",
		"1   ",
		"2  3",
		"",
	}, "\n")
	if got != want {
		t.Fatalf("Table printed:\n%q\nwant:\n%q", got, want)
	}
}

func TestTableWidthCountsRunes(t *testing.T) {
	// Multibyte cells must align by rune count, not byte count.
	got := captureStdout(t, func() {
		Table([]string{"N"}, [][]string{{"héllo"}, {"x"}})
	})
	want := strings.Join([]string{
		"N    ",
		"-----",
		"héllo",
		"x    ",
		"",
	}, "\n")
	if got != want {
		t.Fatalf("Table printed:\n%q\nwant:\n%q", got, want)
	}
}

func TestTruncate(t *testing.T) {
	cases := []struct {
		s    string
		n    int
		want string
	}{
		{"short", 10, "short"},
		{"exact", 5, "exact"},
		{"truncated", 4, "trun…"},
		{"héllo wörld", 5, "héllo…"}, // rune-aware slicing
		{"héllo", 5, "héllo"},        // rune-aware length check: 6 bytes, 5 runes, no cut
		{"", 3, ""},
	}
	for _, tc := range cases {
		if got := Truncate(tc.s, tc.n); got != tc.want {
			t.Errorf("Truncate(%q, %d) = %q, want %q", tc.s, tc.n, got, tc.want)
		}
	}
}

func TestShortID(t *testing.T) {
	cases := []struct{ in, want string }{
		{"0193bf1d-0000-7000-8000-000000000000", "0193bf1d"},
		{"12345678", "12345678"},
		{"short", "short"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := ShortID(tc.in); got != tc.want {
			t.Errorf("ShortID(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestToString(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want string
	}{
		{"nil", nil, ""},
		{"string", "x", "x"},
		{"true", true, "true"},
		{"false", false, "false"},
		{"integral float renders as int", float64(42), "42"},
		{"fractional float", 1.5, "1.5"},
		{"negative integral float", float64(-3), "-3"},
		{"other types via %v", []any{"a"}, "[a]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ToString(tc.in); got != tc.want {
				t.Fatalf("ToString(%v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
