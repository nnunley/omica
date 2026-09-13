#!/usr/bin/env bash
# Runs the shared Mica-source benchmark corpus and writes a TSV per
# implementation, then optionally joins them for comparison.
#
#   scripts/mica-bench.sh odin      # run benchmarks/mica on the Odin port
#   scripts/mica-bench.sh rust      # run them on the Rust build (if present)
#   scripts/mica-bench.sh compare   # join the two result files
#
# The corpus is implementation-neutral: each file declares `verb bench()`
# (and optionally `verb setup()`), and the driver loads once, runs setup,
# then times repeated bench() calls. Keep the counts baked in the files so
# both sides measure identical work.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
corpus="${repo_root}/benchmarks/mica"
results="${repo_root}/benchmarks/results"
mkdir -p "${results}"

odin_bin="${ODIN_BIN:-$(command -v odin || true)}"
samples="${MICA_BENCH_SAMPLES:-15}"
workers="${MICA_BENCH_WORKERS:-8}"

run_odin() {
  local driver="${repo_root}/.cache/test-bin/micabench"
  "${odin_bin}" build "${repo_root}/tools/micabench" -out:"${driver}"
  local out="${results}/odin.tsv"
  : >"${out}"
  local file
  for file in "${corpus}"/*.mica; do
    "${driver}" --samples "${samples}" --workers "${workers}" "${file}" | tee -a "${out}"
  done
  echo "wrote ${out}"
}

run_rust() {
  # The Rust driver is expected to print the same TSV columns:
  #   name<TAB>median_ns<TAB>min_ns<TAB>samples
  local driver="${MICA_RUST_BENCH:-}"
  if [[ -z "${driver}" || ! -x "${driver}" ]]; then
    echo "set MICA_RUST_BENCH to the Rust micabench binary" >&2
    exit 1
  fi
  local out="${results}/rust.tsv"
  : >"${out}"
  local file
  for file in "${corpus}"/*.mica; do
    "${driver}" --samples "${samples}" --workers "${workers}" "${file}" | tee -a "${out}"
  done
  echo "wrote ${out}"
}

compare() {
  python3 - "${results}/odin.tsv" "${results}/rust.tsv" <<'PY'
import sys

def load(path):
    rows = {}
    with open(path) as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                rows[parts[0]] = int(parts[1])
    return rows

odin = load(sys.argv[1])
rust = load(sys.argv[2])
names = sorted(set(odin) | set(rust))
print(f"{'bench':<32}{'odin_ns':>14}{'rust_ns':>14}{'odin/rust':>12}")
for name in names:
    o = odin.get(name)
    r = rust.get(name)
    ratio = f"{o / r:.2f}x" if o and r else "-"
    print(f"{name:<32}{o if o is not None else '-':>14}{r if r is not None else '-':>14}{ratio:>12}")
PY
}

case "${1:-odin}" in
  odin)    run_odin ;;
  rust)    run_rust ;;
  compare) compare ;;
  *) echo "usage: scripts/mica-bench.sh [odin|rust|compare]" >&2; exit 2 ;;
esac
