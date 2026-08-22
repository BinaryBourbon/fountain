#!/usr/bin/env bash
# Rebuild the Daytona snapshot from images/daytona/, then smoke-test it live.
#
# Runs in CI (.github/workflows/sandbox-images.yml) and by hand:
#
#     DAYTONA_API_KEY=... scripts/sandbox-image/build-daytona.sh
#
# ## Why this deletes before it builds
#
# Snapshot names are unique per organization and there is no rename, so a
# snapshot cannot be rebuilt in place and cannot be swapped in behind its name
# either. Prod pins DAYTONA_SNAPSHOT=fountain, so refreshing that name means
# deleting it and creating it again, and between those two calls the
# organization has no `fountain` snapshot: a Daytona conversation started in
# that window fails to create its sandbox. Sandboxes that already exist are
# unaffected — they hold their own copy.
#
# The window is why the workflow builds and smokes the very same Dockerfile
# with `docker build` on the runner first. That gate catches what actually
# breaks these images (an apt or npm publisher upstream) before anything on the
# Daytona side is touched. What it cannot catch is a Daytona-side build failure,
# and if that happens the snapshot stays missing until someone re-runs this —
# so the script says so, loudly, rather than exiting quietly.
#
# Environment:
#   DAYTONA_API_KEY   required, and it must be the account prod uses — a
#                     snapshot built under another org is invisible to prod
#   DAYTONA_SNAPSHOT  snapshot name to rebuild (default: fountain)
#   DAYTONA_API_URL   control plane (default: https://app.daytona.io/api)
#   SKIP_SMOKE        set to 1 to build without creating a sandbox

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
snapshot="${DAYTONA_SNAPSHOT:-fountain}"
api_url="${DAYTONA_API_URL:-https://app.daytona.io/api}"
dockerfile="${root}/images/daytona/Dockerfile"

# A snapshot build pulls a base image and installs four agent CLIs.
build_timeout_s="${DAYTONA_BUILD_TIMEOUT_S:-2700}"
start_timeout_s="${DAYTONA_START_TIMEOUT_S:-600}"

if [ -z "${DAYTONA_API_KEY:-}" ]; then
  echo "DAYTONA_API_KEY is not set — cannot talk to daytona.io" >&2
  exit 1
fi

command -v jq > /dev/null || { echo "jq is required" >&2; exit 1; }

resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

# Every call writes its body to $resp and prints the status code, so callers
# read both instead of guessing from a merged blob.
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method"
    -H "Authorization: Bearer ${DAYTONA_API_KEY}"
    -H "Content-Type: application/json"
    -o "$resp" -w '%{http_code}')
  if [ -n "$body" ]; then args+=(--data-binary "$body"); fi
  curl "${args[@]}" "${api_url}${path}"
}

die() {
  echo "$1" >&2
  echo "response: $(cat "$resp")" >&2
  exit 1
}

# ── the snapshot ──────────────────────────────────────────────────────────────

create_body="$(jq -n --arg name "$snapshot" --rawfile df "$dockerfile" \
  '{name: $name, buildInfo: {dockerfileContent: $df}}')"

code="$(api GET "/snapshots/${snapshot}")"
if [ "$code" = "200" ]; then
  existing_id="$(jq -r '.id' < "$resp")"
  echo "==> deleting the current ${snapshot} snapshot (${existing_id})"
  code="$(api DELETE "/snapshots/${existing_id}")"
  case "$code" in
    2*) ;;
    *) die "delete of snapshot ${snapshot} failed with ${code}" ;;
  esac

  # Deletion is a background job; creating the name again before it lands is a
  # 409. Wait for the name to actually go.
  deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(api GET "/snapshots/${snapshot}")"
    [ "$code" = "404" ] && break
    sleep 5
  done
  [ "$code" = "404" ] || die "snapshot ${snapshot} still present after 300s of deleting"
elif [ "$code" != "404" ]; then
  die "looking up snapshot ${snapshot} failed with ${code}"
fi

echo "==> creating ${snapshot} from images/daytona/Dockerfile"
code="$(api POST /snapshots "$create_body")"
case "$code" in
  2*) ;;
  *) die "PROD IS NOW WITHOUT A ${snapshot} SNAPSHOT: create failed with ${code}" ;;
esac
snapshot_id="$(jq -r '.id' < "$resp")"

echo "==> waiting for ${snapshot} (${snapshot_id}) to reach active"
deadline=$((SECONDS + build_timeout_s))
state=""
while [ "$SECONDS" -lt "$deadline" ]; do
  code="$(api GET "/snapshots/${snapshot_id}")"
  [ "$code" = "200" ] || die "polling snapshot ${snapshot_id} failed with ${code}"
  state="$(jq -r '.state' < "$resp")"

  case "$state" in
    active)
      break
      ;;
    error | build_failed)
      echo "snapshot build ended in ${state}: $(jq -r '.errorReason // "no reason given"' < "$resp")" >&2
      echo "--- build logs ---" >&2
      api GET "/snapshots/${snapshot_id}/build-logs" > /dev/null || true
      cat "$resp" >&2
      echo >&2
      echo "PROD IS NOW WITHOUT A WORKING ${snapshot} SNAPSHOT — fix the" >&2
      echo "Dockerfile and re-run this workflow." >&2
      exit 1
      ;;
    *)
      echo "    ${state}"
      sleep 15
      ;;
  esac
done

[ "$state" = "active" ] || die "snapshot ${snapshot} stuck in ${state} after ${build_timeout_s}s"
echo "==> ${snapshot} is active"

if [ "${SKIP_SMOKE:-}" = "1" ]; then
  echo "==> SKIP_SMOKE=1, leaving the snapshot unverified"
  exit 0
fi

# ── the smoke ─────────────────────────────────────────────────────────────────

sandbox_name="fountain-image-smoke-${GITHUB_RUN_ID:-$$}"

cleanup_sandbox() {
  echo "==> destroying smoke sandbox ${sandbox_name}"
  api DELETE "/sandbox/${sandbox_name}" > /dev/null || true
  rm -f "$resp"
}

echo "==> creating smoke sandbox ${sandbox_name}"
# No `fountain: "1"` label, deliberately: that is what the reaper and the ops
# gauges count as a Fountain sandbox, and a CI sandbox is neither leaked nor
# theirs to reason about. The intervals are the backstop for a run that dies
# before its trap fires — prod sets all three to 0, and a leaked CI sandbox
# billing forever is the one thing this script must not do.
sandbox_body="$(jq -nc --arg snapshot "$snapshot" --arg name "$sandbox_name" \
  '{name: $name,
    snapshot: $snapshot,
    labels: {fountain_image_smoke: "1"},
    autoStopInterval: 10,
    autoDeleteInterval: 5,
    ttlMinutes: 30}')"

code="$(api POST /sandbox "$sandbox_body")"
case "$code" in
  2*) ;;
  *) die "creating the smoke sandbox failed with ${code}" ;;
esac
trap cleanup_sandbox EXIT

sandbox_id="$(jq -r '.id' < "$resp")"

echo "==> waiting for ${sandbox_name} to start"
deadline=$((SECONDS + start_timeout_s))
state=""
while [ "$SECONDS" -lt "$deadline" ]; do
  code="$(api GET "/sandbox/${sandbox_name}")"
  [ "$code" = "200" ] || die "polling sandbox ${sandbox_name} failed with ${code}"
  state="$(jq -r '.state' < "$resp")"
  case "$state" in
    started) break ;;
    error | build_failed) die "smoke sandbox ended in ${state}" ;;
    *)
      echo "    ${state}"
      sleep 5
      ;;
  esac
done
[ "$state" = "started" ] || die "smoke sandbox stuck in ${state} after ${start_timeout_s}s"

# Same shape Fountain.Sandbox.Daytona.Api.toolbox_url/1 builds.
proxy="$(jq -r '.toolboxProxyUrl // empty' < "$resp")"
if [ -z "$proxy" ]; then
  code="$(api GET "/sandbox/${sandbox_id}/toolbox-proxy-url")"
  [ "$code" = "200" ] || die "no toolbox proxy URL for ${sandbox_name} (${code})"
  proxy="$(jq -r 'if type == "string" then . else .url end' < "$resp")"
fi
toolbox="${proxy%/}/${sandbox_id}"

echo "==> smoking ${sandbox_name}"
smoke_b64="$(base64 < "${root}/scripts/sandbox-image/smoke.sh" | tr -d '\n')"
exec_body="$(jq -nc --arg cmd "echo ${smoke_b64} | base64 -d | bash" \
  '{command: $cmd, timeout: 600}')"

exec_code="$(curl -sS -X POST \
  -H "Authorization: Bearer ${DAYTONA_API_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary "$exec_body" \
  -o "$resp" -w '%{http_code}' \
  "${toolbox}/process/execute")"

[ "$exec_code" = "200" ] || die "toolbox execute failed with ${exec_code}"

jq -r '.result // .output // ""' < "$resp"
exit_code="$(jq -r '.exitCode // .code // 0' < "$resp")"

if [ "$exit_code" != "0" ] || ! jq -r '.result // .output // ""' < "$resp" | grep -q FOUNTAIN_IMAGE_SMOKE_OK; then
  echo "==> smoke FAILED for snapshot ${snapshot} (exit ${exit_code})" >&2
  exit 1
fi

echo "==> snapshot ${snapshot} rebuilt and smoked clean"
