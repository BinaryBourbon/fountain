#!/usr/bin/env bash
# Rebuild the SDK wire contract from the server.
#
#   scripts/sdk-contract/build.sh          rebuild dist/openapi.json and
#                                          sdk/contract/contract.json
#   scripts/sdk-contract/build.sh --check  rebuild the artifact, then fail if
#                                          the checked-in contract is stale
#
# The export needs the Elixir toolchain and a database URL, because rendering
# the spec boots the app. The four SDK verifiers do not — they read the checked
# in projection, which is the whole point of committing it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

(cd "${root}/apps/fountain" && mix openapi.export >/dev/null)

exec python3 "${root}/scripts/sdk-contract/build.py" "$@"
