#!/usr/bin/env bash
# Bycycle: load and query the OpenCyc OWL dump in a Mica store.
#
#   scripts/bycycle-load.sh init   STORE [--force]  # ontology + rules, fresh store
#   scripts/bycycle-load.sh load   STORE OWL_GZ     # stream facts (resumable)
#   scripts/bycycle-load.sh query  STORE 'EXPR'     # eval against the store
#   scripts/bycycle-load.sh repl   STORE            # interactive REPL
#   scripts/bycycle-load.sh unlock STORE            # remove a stale LOCK
#
# A store's LOCK file is its exclusive lock (the store creates it with
# O_CREAT|O_EXCL). Commands refuse a locked store; if no process is using the
# store (a killed run left the lock behind), `unlock` removes it.
#
# The OWL dump is opencyc-latest.owl.gz from asanchez75/opencyc (Git LFS —
# fetch via the media.githubusercontent.com URL, not the raw one).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

ODIN_BIN="${ODIN_BIN:-$(command -v odin || true)}"
if [[ -z "${ODIN_BIN}" || ! -x "${ODIN_BIN}" ]]; then
  echo "cannot find the Odin compiler; set ODIN_BIN" >&2
  exit 1
fi
ONTOLOGY=(
  apps/bycycle-owl/00_schema.mica
  apps/bycycle-owl/10_taxonomy.mica
  apps/bycycle-owl/20_constraints.mica
  apps/bycycle-owl/30_graph.mica
  apps/shared/retrieval.mica
)

# Refuses to touch a store another process holds (or a killed run left locked).
require_unlocked() {
  if [[ -e "$1/LOCK" ]]; then
    echo "$1 is locked by another process (or a killed run left its LOCK)." >&2
    echo "If nothing is using it, run: scripts/bycycle-load.sh unlock $1" >&2
    exit 1
  fi
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  init)
    store="${1:?usage: bycycle-load.sh init STORE [--force]}"
    # init starts from an empty store; refuse to discard a (possibly partly
    # loaded, resumable) one unless asked.
    if [[ -e "${store}" ]]; then
      if [[ "${2:-}" != "--force" ]]; then
        echo "${store} exists; pass --force to delete it and start over" >&2
        exit 1
      fi
      rm -rf "${store}"
    fi
    "${ODIN_BIN}" run tools/filein -- \
      --store "${store}" --unit bycycle "${ONTOLOGY[@]}" --checkpoint
    ;;
  load)
    store="${1:?usage: bycycle-load.sh load STORE OWL_GZ}"
    owl="${2:?usage: bycycle-load.sh load STORE OWL_GZ}"
    # Resume position lives in LoaderState inside the store; safe to re-run
    # after a kill (after `unlock` if the killed run left its LOCK).
    # Rules derive once at the end (--defer-derivation), not on every commit,
    # which made the load quadratic in the store's size.
    require_unlocked "${store}"
    "${ODIN_BIN}" run tools/owlstream -o:speed -- \
      --owl "${owl}" --store "${store}" --commit-batch 20000 --checkpoint \
      --defer-derivation --retrieval-actor bycycle_reader
    ;;
  query)
    store="${1:?usage: bycycle-load.sh query STORE 'EXPR'}"
    expr="${2:?usage: bycycle-load.sh query STORE 'EXPR'}"
    require_unlocked "${store}"
    "${ODIN_BIN}" run tools/filein -- --store "${store}" --eval "${expr}"
    ;;
  repl)
    store="${1:?usage: bycycle-load.sh repl STORE}"
    require_unlocked "${store}"
    "${ODIN_BIN}" run tools/repl -- --store "${store}"
    ;;
  unlock)
    store="${1:?usage: bycycle-load.sh unlock STORE}"
    if [[ ! -e "${store}/LOCK" ]]; then
      echo "${store} is not locked"
      exit 0
    fi
    # Refuse while any process still has the store's files open.
    if command -v lsof >/dev/null 2>&1 && lsof +D "${store}" >/dev/null 2>&1; then
      echo "${store} is in use by another process; not removing its LOCK" >&2
      lsof +D "${store}" >&2 || true
      exit 1
    fi
    rm -f "${store}/LOCK"
    echo "removed stale lock ${store}/LOCK"
    ;;
  *)
    echo "usage: bycycle-load.sh {init|load|query|repl|unlock} ..." >&2
    exit 1
    ;;
esac
