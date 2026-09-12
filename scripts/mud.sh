#!/usr/bin/env bash
# Builds and starts the MUD world over the in-process web host.
#
#   scripts/mud.sh
#   MICA_WEB_BIND=127.0.0.1:9000 scripts/mud.sh
#
# Open http://<bind>/mud and sign in with one of the seeded users:
#   alice / alice-pass
#   bob / bob-pass
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

odin_bin="${ODIN_BIN:-$(command -v odin || true)}"
if [[ -z "${odin_bin}" && -x "${repo_root}/../odin-setup/odin" ]]; then
  odin_bin="${repo_root}/../odin-setup/odin"
fi
if [[ -z "${odin_bin}" || ! -x "${odin_bin}" ]]; then
  echo "cannot find the Odin compiler; set ODIN_BIN" >&2
  exit 1
fi

webhost_bin="${WEBHOST_BIN:-${repo_root}/.cache/bin/webhost}"
bind="${MICA_WEB_BIND:-127.0.0.1:8080}"

fileins=(
  apps/shared/string.mica
  apps/shared/events.mica
  apps/shared/retrieval.mica
  apps/shared/sync-host.mica
  apps/shared/sync-dom.mica
  apps/mud/core.mica
  apps/mud/auth.mica
  apps/mud/command-parser.mica
  apps/mud/event-substitutions.mica
  apps/mud/ui-session.mica
  apps/mud/ui-actions.mica
  apps/mud/ui-compose.mica
  apps/mud/ui-narrative.mica
  apps/mud/ui-mica-inspect.mica
  apps/mud/ui-retrieval.mica
  apps/mud/http.mica
)

if [[ ! -x "${webhost_bin}" || "${MICA_WEB_REBUILD:-0}" == "1" ]]; then
  mkdir -p "$(dirname "${webhost_bin}")"
  "${odin_bin}" build tools/webhost -out:"${webhost_bin}"
fi

args=()
for file in "${fileins[@]}"; do
  args+=(--filein "${file}")
done
args+=(--bind "${bind}" --sync-client host/web/sync-client.js)

echo "MUD: http://${bind}/mud"
echo "users: alice/alice-pass, bob/bob-pass"
exec "${webhost_bin}" "${args[@]}"
