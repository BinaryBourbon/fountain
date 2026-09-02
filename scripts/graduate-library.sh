#!/usr/bin/env bash
#
# Graduate an umbrella library app (apps/managoat_<name>) to its own
# repository, managoat/managoat_<name>, from which CI publishes it to hex.
# The recipe is written down in CONTRIBUTING.md ("Graduating a library");
# this is the executable half of it. It does not touch Fountain's tree: the
# Fountain-side PR (delete the app, pin the hex release) is a separate step.
#
#   scripts/graduate-library.sh <name>              the whole thing
#   scripts/graduate-library.sh --prepare-only <name>
#       steps 1, 2 and the stand-alone conversion into a scratch clone of the
#       split branch, with the local gates, and nothing on GitHub. Run this
#       first: a package name is claimed by its first publish and never
#       released, so the tree has to be right before main exists.
#
# Run from the umbrella root, on a clean, up-to-date main. Steps:
#
#   1. Refuse unless the tree is clean, main is checked out and matches
#      origin/main, apps/managoat_<name>/mix.exs exists and `mix hex.build`
#      succeeds for it.
#   2. `git subtree split` the app's history onto graduate/<name>.
#   3. Create managoat/managoat_<name> (public, no wiki, topic
#      managoat-library) and push the split branch as main.
#   4. In a fresh clone: copy templates/managoat-library in, edit mix.exs for
#      life outside the umbrella, `mix deps.get` for the repo's own mix.lock,
#      `mix format`, run the local gates, commit "chore: stand alone (...)"
#      and push. That push is what triggers CI and the first publish.
#   5. Create the `no-release` label and protect main behind the two checks
#      (no review requirement). Print the repo URL and the next step.
#
# Idempotent after a failure in 4 or 5: an existing repo is not recreated, a
# main that already carries the stand-alone commit is not pushed again, the
# label and the protection are upserted.
#
# Prerequisite that only the org admin can meet: HEX_API_KEY as an
# organization secret on managoat, visible to all repositories. The script
# cannot check it (listing org secrets needs a scope `gh` may not have); the
# first publish run is the check.
#
# Environment: GRADUATE_WORKDIR (scratch parent; default $TMPDIR),
# GRADUATE_SKIP_LOCAL_GATES=1 to skip compile/credo/test in step 4 (CI still
# runs them, and the publish workflow runs the tests before publishing).

set -euo pipefail

die() { echo "graduate-library: $*" >&2; exit 1; }

mode=full
if [ "${1:-}" = "--prepare-only" ]; then mode=prepare; shift; fi
name="${1:-}"
[ -n "$name" ] || die "usage: scripts/graduate-library.sh [--prepare-only] <name>   (name as in apps/managoat_<name>)"
case "$name" in managoat_*) die "give the short name: '${name#managoat_}', not '$name'";; esac

app="managoat_${name}"
repo="managoat/${app}"
repo_url="https://github.com/${repo}"
push_url="git@github.com:${repo}.git"
app_dir="apps/${app}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
template="${script_dir}/../templates/managoat-library"
root="$PWD"
workdir="${GRADUATE_WORKDIR:-${TMPDIR:-/tmp}}/graduate-${app}"

[ -d "$template" ] || die "template missing at $template"
command -v gh >/dev/null || die "gh is required"
command -v mix >/dev/null || die "mix is required"
command -v perl >/dev/null || die "perl is required"

# ---- 1. preflight ----------------------------------------------------------

[ -f mix.exs ] && grep -q 'apps_path' mix.exs || die "run from the umbrella root (no mix.exs with apps_path here)"
[ -f "$app_dir/mix.exs" ] || die "$app_dir/mix.exs does not exist"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || die "main must be checked out (on $branch)"
git fetch -q origin main
head_sha="$(git rev-parse HEAD)"
[ "$head_sha" = "$(git rev-parse origin/main)" ] || die "main is not up to date with origin/main"
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "== shallow clone: fetching full history for subtree split"
  git fetch --unshallow
fi

echo "== 1. $app_dir builds a hex package"
tarball="$(mktemp -d)/${app}.tar"
(cd "$app_dir" && mix hex.build --output "$tarball" >/dev/null) || die "mix hex.build fails for $app_dir; fix that first"
rm -f "$tarball"

description="$(cd "$app_dir" && mix eval --no-deps-check --no-compile 'IO.puts(Mix.Project.config()[:description])' | tail -1)"
[ -n "$description" ] || die "no :description in $app_dir/mix.exs"
module="$(perl -ne 'print $1 and exit if /^defmodule\s+([\w.]+)\.MixProject/' "$app_dir/mix.exs")"
[ -n "$module" ] || die "could not read the module name from $app_dir/mix.exs"

# ---- 2. split --------------------------------------------------------------

echo "== 2. git subtree split -P $app_dir"
split_sha="$(git subtree split -P "$app_dir" 2>/dev/null)"
[ -n "$split_sha" ] || die "git subtree split produced nothing"
git branch -f "graduate/${name}" "$split_sha" >/dev/null
subject="$(git log -1 --format=%s "$split_sha")"
extraction_pr="$(printf '%s' "$subject" | perl -ne 'print $1 if /\(#(\d+)\)\s*$/')"
[ -n "$extraction_pr" ] || die "the split's tip commit does not name its PR: $subject"
echo "   graduate/${name} = ${split_sha:0:12} ($subject)"

# ---- the stand-alone conversion (shared by both modes) ---------------------

# $1: a checkout of the split branch, on main. Leaves it committed.
stand_alone() {
  local dir="$1"
  cd "$dir"
  local today
  today="$(date +%Y-%m-%d)"

  echo "== 4. stand alone in $dir"
  # The template, dotfiles included. .formatter.exs is patched rather than
  # copied: the library's own may carry import_deps (managoat_oauth's does).
  (cd "$template" && find . -type f ! -name .formatter.exs -print0) |
    while IFS= read -r -d '' f; do
      mkdir -p "$(dirname "$f")"
      cp "$template/$f" "$f"
    done
  if [ -f .formatter.exs ]; then
    perl -pi -e 's|"\{lib,test\}/\*\*/\*\.\{ex,exs\}"|"{lib,test,scripts}/**/*.{ex,exs}"|' .formatter.exs
  else
    cp "$template/.formatter.exs" .formatter.exs
  fi

  # Placeholders in NOTICE and CHANGELOG.md.
  perl -pi -e "s/__NAME__/${app}/g; s/__MODULE__/${module}/g; s/__DATE__/${today}/g; s/__EXTRACTION_PR__/${extraction_pr}/g" NOTICE CHANGELOG.md

  # The Postgres service is managoat_oauth's alone.
  if [ "$name" != "oauth" ]; then
    for wf in .github/workflows/ci.yml .github/workflows/publish.yml; do
      perl -ni -e 'if (/^\s*# ---- oauth only/) { $skip = 1 } if (!$skip && !/# oauth only\s*$/) { print } if (/^\s*# ---- end oauth only/) { $skip = 0 }' "$wf"
    done
  fi

  # mix.exs: out of the umbrella.
  #  - the umbrella-first comment block and the three path lines go;
  #  - @source_url becomes this repository, links gain the changelog;
  #  - the package ships CHANGELOG.md and NOTICE too;
  #  - docs (ex_doc, so hex.publish publishes hexdocs), dialyzer config and
  #    the tool deps CI needs.
  perl -0pi -e '
    s/[ \t]*# Umbrella-first \(decisions\/0037\).*?lockfile: "\.\.\/\.\.\/mix\.lock",\n//s
      or die "mix.exs: umbrella block not found\n";
    s|\@source_url "https://github\.com/BinaryBourbon/fountain/tree/main/apps/'"$app"'"|\@source_url "https://github.com/managoat/'"$app"'"|
      or die "mix.exs: \@source_url not found\n";
    s|links: %\{"GitHub" => \@source_url\}|links: %{"GitHub" => \@source_url, "Changelog" => "#{\@source_url}/blob/main/CHANGELOG.md"}|
      or die "mix.exs: links not found\n";
    s|files: ~w\(lib mix\.exs README\.md LICENSE\)|files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE)|
      or die "mix.exs: files not found\n";
    s|(\n[ \t]*package: package\(\),\n)|$1      source_url: \@source_url,\n      docs: docs(),\n      dialyzer: dialyzer(),\n|
      or die "mix.exs: package: line not found\n";
    s|(\n[ \t]*defp deps do\n[ \t]*\[\n)|$1      # Tooling for the repository, not the package: docs for hexdocs.pm (built\n      # by `mix hex.publish`), credo and dialyzer for CI. dialyxir is pinned to\n      # the commit that added OTP 28 support; 1.4.7 crashes on OTP 28 warnings.\n      {:ex_doc, "~> 0.34", only: :dev, runtime: false},\n      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},\n      {:dialyxir,\n       github: "jeremyjh/dialyxir",\n       ref: "3553678f4d69281ac6db61034bcf35bcb30cfd78",\n       only: [:dev, :test],\n       runtime: false},\n|
      or die "mix.exs: defp deps not found\n";
    s|\nend\s*$|\n\n  defp docs do\n    [\n      main: "readme",\n      extras: ["README.md", "CHANGELOG.md"],\n      source_ref: "v#{\@version}",\n      source_url: \@source_url\n    ]\n  end\n\n  defp dialyzer do\n    [\n      ignore_warnings: ".dialyzer_ignore.exs",\n      # A fixed path so CI can cache the PLT across runs.\n      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}\n    ]\n  end\nend\n|
      or die "mix.exs: final end not found\n";
  ' mix.exs

  echo "   mix deps.get (the repository's own mix.lock)"
  mix deps.get >/dev/null
  mix format

  if [ "${GRADUATE_SKIP_LOCAL_GATES:-0}" != "1" ]; then
    echo "   local gates: compile, credo, test, hex.build"
    mix compile --warnings-as-errors >/dev/null
    env MIX_ENV=test mix compile --warnings-as-errors >/dev/null
    mix credo --strict
    mix test
    mix hex.build --output "$(mktemp -d)/${app}.tar" >/dev/null
    mix format --check-formatted
    elixir scripts/release.exs state
  fi

  git add -A
  git commit -q -m "chore: stand alone (from BinaryBourbon/fountain apps/${app} at ${head_sha:0:12})" \
    -m "The graduation of ${app} out of the Fountain umbrella (BinaryBourbon/fountain#1345, decisions/0037): the managoat-library template (CI, the release gate, the publish workflow, scripts/release.exs, NOTICE, CHANGELOG), mix.exs without its umbrella paths, and a mix.lock of its own. Merging a version bump to main publishes to hex."
  echo "   committed $(git rev-parse --short HEAD)"
  cd "$root"
}

# ---- prepare-only ends here -------------------------------------------------

if [ "$mode" = "prepare" ]; then
  rm -rf "$workdir"
  git clone -q --branch "graduate/${name}" "$root" "$workdir"
  (cd "$workdir" && git checkout -q -b main)
  stand_alone "$workdir"
  echo
  echo "Prepared, nothing pushed. Inspect $workdir, then run: scripts/graduate-library.sh $name"
  exit 0
fi

# ---- 3. the repository -------------------------------------------------------

echo "== 3. $repo"
if gh repo view "$repo" >/dev/null 2>&1; then
  echo "   exists, not recreated"
else
  gh repo create "$repo" --public --description "$description" --disable-wiki >/dev/null
  echo "   created"
fi
gh repo edit "$repo" --add-topic managoat-library --delete-branch-on-merge --enable-projects=false >/dev/null

if [ -z "$(git ls-remote --heads "$push_url" main)" ]; then
  git push -q "$push_url" "${split_sha}:refs/heads/main"
  echo "   pushed graduate/${name} as main"
else
  echo "   main already exists on the remote, not pushed"
fi

# ---- 4. stand alone -----------------------------------------------------------

rm -rf "$workdir"
git clone -q "$push_url" "$workdir"
if (cd "$workdir" && git cat-file -e "origin/main:.github/workflows/publish.yml" 2>/dev/null); then
  echo "== 4. main already carries the stand-alone commit, skipped"
else
  stand_alone "$workdir"
  (cd "$workdir" && git push -q origin main)
  echo "   pushed: CI and the first publish are running"
fi

# ---- 5. label, protection ----------------------------------------------------

echo "== 5. label and branch protection"
gh label create no-release --repo "$repo" --force --color d4c5f9 \
  --description "This PR changes the published surface without cutting a release; the release gate is skipped." >/dev/null
echo "   label no-release"

protection="$(mktemp)"
cat > "$protection" <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["ci", "release gate"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
gh api -X PUT "repos/${repo}/branches/main/protection" --input "$protection" >/dev/null
rm -f "$protection"
echo "   main requires the checks: ci, release gate (no review requirement)"

cat <<MSG

Done: ${repo_url}

Next:
  1. Watch ${repo_url}/actions: CI on the stand-alone commit, then Publish,
     which publishes ${app} to hex and tags v<version>. A 401 from hex means
     HEX_API_KEY is not visible to the repository; stop and ask.
  2. Confirm https://hex.pm/packages/${app} and https://hexdocs.pm/${app}.
  3. The Fountain-side PR (CONTRIBUTING.md, "Graduating a library"): delete
     ${app_dir}, pin {:${app}, "~> <version>"} in apps/fountain/mix.exs, drop
     the Dockerfile COPY line, and build the image locally before opening it.
MSG
