#!/usr/bin/env bash
# Backport elixir-lang/elixir#15765 into an isolated code path. Never edit the
# installed toolchain; ERL_AFLAGS also reaches nested `mix` OS processes.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 --install | command [args...]" >&2
  exit 2
fi
if [[ "$1" == --install && ( $# -ne 1 || -z "${GITHUB_ENV:-}" ) ]]; then
  echo '--install requires GITHUB_ENV and no other arguments' >&2
  exit 2
fi

source_path="$(elixir -e '
  unless System.version() == "1.19.2", do: raise("retire or re-audit Mix lock backport for this Elixir version")
  IO.puts(Path.join([:code.lib_dir(:mix), "lib/mix/sync/lock.ex"]))
')"
check_hash() {
  elixir -e '
    [path, expected] = System.argv()
    actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    unless actual == expected, do: raise("unexpected Mix lock source fingerprint: #{path}")
  ' "$1" "$2"
}
check_hash "$source_path" 7bd930d9452e83a7f989a41350a261477b9373f39c2146b24571b6a09841f000

# A fixed /tmp prefix has no spaces, so the Erlang flag parser does not need
# shell-dependent quoting. Each invocation owns a distinct directory.
patch_dir="$(mktemp -d /tmp/fountain-mix-lock.XXXXXXXX)"
keep_patch=false
trap 'if [[ "$keep_patch" == false ]]; then rm -rf "$patch_dir"; fi' EXIT
mkdir -p "$patch_dir/lib/mix/lib/mix/sync" "$patch_dir/ebin"
patched_source="$patch_dir/lib/mix/lib/mix/sync/lock.ex"
cp "$source_path" "$patched_source"
(cd "$patch_dir" && git apply "$script_dir/mix-lock-15765.patch")
check_hash "$patched_source" 532d4926744fcf543f1d0959a81a78d49d4b9ed0ea200541d05f13fcbe56f2e3
# Elixir prepends its own Mix path during boot, after Erlang processes -pa.
# Preload the patched module before Elixir starts; subsequent Mix path changes
# cannot replace an already loaded module. Evaluate the load directly: embedded
# release boot disables autoloading, so a custom -s bootstrap cannot start there.
elixirc --ignore-module-conflict --warnings-as-errors -o "$patch_dir/ebin" "$patched_source"
export ERL_AFLAGS="${ERL_AFLAGS:+$ERL_AFLAGS }-eval '{module,_}=code:load_abs(\"$patch_dir/ebin/Elixir.Mix.Sync.Lock\").'"

# Verify code-path precedence before trusting it for the real command.
elixir -e '
  [expected] = System.argv()
  Code.ensure_loaded!(Mix.Sync.Lock)
  actual = :code.which(Mix.Sync.Lock) |> List.to_string() |> Path.dirname()
  unless actual == expected, do: raise("patched Mix lock was not loaded")
' "$patch_dir/ebin"

if [[ "$1" == --install ]]; then
  printf 'ERL_AFLAGS=%s\n' "$ERL_AFLAGS" >> "$GITHUB_ENV"
  keep_patch=true
  echo 'Installed pinned Mix lock backport in isolated CI code path'
else
  "$@"
fi
