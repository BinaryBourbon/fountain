package substitution

import (
	"errors"
	"reflect"
	"testing"
)

func TestApply_SimpleString(t *testing.T) {
	got, err := Apply("hello ${NAME}", map[string]string{"NAME": "world"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "hello world" {
		t.Fatalf("got %q", got)
	}
}

func TestApply_EscapeDollarBrace(t *testing.T) {
	got, err := Apply("$${PATH}/x", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	if got != "${PATH}/x" {
		t.Fatalf("got %q", got)
	}
}

func TestApply_MissingVarErrors(t *testing.T) {
	_, err := Apply(map[string]any{
		"a": "hello ${NAME}",
		"b": "${OTHER}",
	}, map[string]string{})
	var me *MissingVarsError
	if !errors.As(err, &me) {
		t.Fatalf("expected MissingVarsError, got %v", err)
	}
	want := []string{"NAME", "OTHER"}
	if !reflect.DeepEqual(me.Missing, want) {
		t.Fatalf("got missing %v, want %v", me.Missing, want)
	}
}

func TestApply_MissingDoesNotPartiallySubstitute(t *testing.T) {
	got, err := Apply("${SET}/${UNSET}", map[string]string{"SET": "x"})
	if err == nil {
		t.Fatalf("expected error")
	}
	// On error the original string is returned unchanged.
	if got != "${SET}/${UNSET}" {
		t.Fatalf("got %q", got)
	}
}

func TestApply_NestedMapList(t *testing.T) {
	in := map[string]any{
		"k": "v-${A}",
		"list": []any{
			"${B}",
			map[string]any{"deep": "x-${A}-y"},
		},
	}
	got, err := Apply(in, map[string]string{"A": "1", "B": "2"})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"k": "v-1",
		"list": []any{
			"2",
			map[string]any{"deep": "x-1-y"},
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestApply_DollarDollarEscape(t *testing.T) {
	got, err := Apply("$$5.00", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	if got != "$5.00" {
		t.Fatalf("got %q", got)
	}
}
