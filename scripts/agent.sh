#!/usr/bin/env bash
# Builds and starts the agent web app on the in-process HTTP/SSE host.
#
#   scripts/agent.sh
#   MICA_AGENT_BIND=127.0.0.1:9001 scripts/agent.sh
#
# Model access needs a key: set OPENROUTER_API_KEY (or OPENAI_API_KEY with
# MICA_OPENAI_BASE_URL). MICA_AGENT_MODEL selects the model and
# MICA_AGENT_API selects "responses" (default) or "chat_completions".
#
# MICA_SOURCE_ROOTS defaults to this repository. The web host indexes that
# root into the source relations at startup, so the agent's read/ls/glob tools
# work and grep scans the indexed text. Syntax and VCS relations are not
# ported.
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
bind="${MICA_AGENT_BIND:-127.0.0.1:8081}"
export MICA_SOURCE_ROOTS="${MICA_SOURCE_ROOTS:-${repo_root}}"

fileins=(
  apps/shared/string.mica
  apps/shared/events.mica
  apps/shared/llm.mica
  apps/shared/sync-host.mica
  apps/shared/sync-dom.mica
  apps/agent/core.mica
  apps/agent/workspaces.mica
  apps/agent/tools.mica
  apps/agent/transcript.mica
  apps/agent/ui-session.mica
  apps/agent/ui-compose.mica
  apps/agent/ui-actions.mica
  apps/agent/http.mica
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
args+=(--bind "${bind}" --sync-client host/web/sync-client.js)
if [[ -n "${MICA_STORE:-}" ]]; then
  args+=(--store "${MICA_STORE}")
  args+=(--durability "${MICA_DURABILITY:-group}")
fi

port="${bind##*:}"
host="${bind%:*}"
if [[ "${host}" == "0.0.0.0" || "${host}" == "::" || "${host}" == "" ]]; then
  tailnet_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${tailnet_ip}" ]]; then
    echo "agent: http://${tailnet_ip}:${port}/agent"
  elif [[ -n "${lan_ip}" ]]; then
    echo "agent: http://${lan_ip}:${port}/agent"
  else
    echo "agent: http://<this-host>:${port}/agent"
  fi
else
  echo "agent: http://${host}:${port}/agent"
fi
if [[ "${host}" != "127.0.0.1" && "${host}" != "localhost" && "${host}" != "::1" ]]; then
  echo "note: this app has no login; anyone who can reach ${bind} can use the agent"
fi
if [[ -z "${OPENROUTER_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
  echo "note: set OPENROUTER_API_KEY for model access"
fi
exec "${webhost_bin}" "${args[@]}"
