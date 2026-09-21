#!/usr/bin/env bash
# Builds and starts the browser editor on the in-process HTTP host.
#
#   scripts/editor.sh
#   MICA_EDITOR_BIND=127.0.0.1:9002 scripts/editor.sh
#
# Open http://<host>:8082/editor and start typing. The editor is programmable
# Mica: keymaps, commands, buffers, windows, and undo all live in the world, and
# the browser only normalizes input and paints the viewport.
#
# What works today: typing (including spaces, capitals, and paste), movement
# (C-f/C-b/C-n/C-p/C-a/C-e, arrows, M-f/M-b, M-</M->), C-v/M-v/C-l,
# C-d/Backspace/Delete, C-j/C-m/Enter, click to place point and shift-click to
# extend the region, mark and region (C-<space>, C-x C-x), undo/redo (C-/, C-_,
# C-x u, C-x C-/), numeric arguments (C-u, M--, M-0..M-9), C-g, window commands
# (C-x 0/1/2/3/o), and M-x by name.
#
# The browser paints plain inserted text immediately, then reconciles it with
# the authoritative Mica snapshot. The Mica editor files live under apps/editor/.
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
bind="${MICA_EDITOR_BIND:-127.0.0.1:8082}"

fileins=(
  apps/shared/sync-host.mica
  apps/shared/buffers.mica
  apps/editor/schema.mica
  apps/editor/windows.mica
  apps/editor/buffers.mica
  apps/editor/keymaps.mica
  apps/editor/undo.mica
  apps/editor/commands.mica
  apps/editor/session.mica
  apps/editor/picker.mica
  apps/editor/minibuffer.mica
  apps/editor/ui.mica
  apps/editor/defaults.mica
  apps/editor/http.mica
)

needs_build="0"
if [[ ! -x "${webhost_bin}" || "${MICA_WEB_REBUILD:-0}" == "1" ]]; then
  needs_build="1"
elif [[ -n "$(find tools/webhost host/web mica -name '*.odin' -newer "${webhost_bin}" -print -quit 2>/dev/null)" ]]; then
  needs_build="1"
fi
if [[ "${needs_build}" == "1" ]]; then
  mkdir -p "$(dirname "${webhost_bin}")"
  "${odin_bin}" build tools/webhost -out:"${webhost_bin}"
fi

args=()
for file in "${fileins[@]}"; do
  args+=(--filein "${file}")
done
args+=(--bind "${bind}" --editor-client host/web/editor-client.js)
if [[ -n "${MICA_STORE:-}" ]]; then
  args+=(--store "${MICA_STORE}")
  args+=(--durability "${MICA_DURABILITY:-group}")
fi

port="${bind##*:}"
host="${bind%:*}"
if [[ "${host}" == "0.0.0.0" || "${host}" == "::" || "${host}" == "" ]]; then
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${lan_ip}" ]]; then
    echo "editor: http://${lan_ip}:${port}/editor"
  else
    echo "editor: http://<this-host>:${port}/editor"
  fi
else
  echo "editor: http://${host}:${port}/editor"
fi
echo "note: each browser tab gets its own actor-bound editor session"
exec "${webhost_bin}" "${args[@]}"
