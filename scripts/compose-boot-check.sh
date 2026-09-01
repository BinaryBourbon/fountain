#!/usr/bin/env bash
# Runs the documented self-host quick start verbatim against the image the
# tree pins, then asks the app what the walkthrough asks. Two workflows run
# it, and it is one script so they cannot drift:
#
#   ci.yml       "Compose boots the pinned image" on every PR and main push,
#                skipped when the pinned tag has no image yet (a release
#                bump PR, and main right after it merges).
#   release.yml  the same check on the tag, after image-manifest has
#                published the image the bump pins, before the GitHub
#                Release is created.
#
# The exact commands the quick start documents (cp, the two openssl lines,
# up) rather than a synthetic env: the check exists to run what a fresh user
# runs, so any divergence here would defeat it. The two appended keys are
# the only definition of each: the example file ships them commented out, so
# a followed quick start no longer leaves two copies of every secret in .env,
# shadowing each other and relying on last-value-wins (#1215).
set -euo pipefail

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
docker compose up -d

probe() {
  # Boot runs migrations before the endpoint listens, so tolerate refused
  # connections while waiting. A non-200 answer is a verdict, not a retry.
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4000$1") || code=000
    if [ "$code" = "200" ]; then
      echo "  $1 -> 200"
      return 0
    fi
    if [ "$code" != "000" ]; then
      echo "  $1 -> $code (expected 200)" >&2
      return 1
    fi
    sleep 2
  done
  echo "  $1 never answered" >&2
  return 1
}

probe /health
probe /health/ready
