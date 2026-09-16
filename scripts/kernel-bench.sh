#!/usr/bin/env bash
# Runs the kernel microbenchmark suite and writes a TSV baseline.
#
#   scripts/kernel-bench.sh             # run the full suite, replace baseline
#   scripts/kernel-bench.sh baseline    # also show delta vs the saved baseline
#   scripts/kernel-bench.sh filter=10k  # only benches whose name contains 10k
#   scripts/kernel-bench.sh quick       # shorter warmup/samples (fast feedback)
#
# The baseline is written to benchmarks/results/kernel.tsv. `quick` and
# `filter` runs still overwrite the file, so use them for spot checks, not
# for updating the committed baseline. `baseline` mode compares against the
# saved file and then overwrites it with the new numbers.
#
# Note on the memory column: the `kernel/mem/growth` benches probe VmHWM
# (peak RSS), which is a lifetime high-water. In a full run, the 1M-row store
# states built during registration lift the peak above what the 10k/100k
# benches can reach, so their deltas clamp to zero and print `-`. For a clean
# per-scale memory reading, run with a filter (e.g. `filter=10k`), which
# still builds all states but the probe is captured after the warmup of the
# filtered bench, so the delta is the bench's own growth.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results="${repo_root}/benchmarks/results"
mkdir -p "${results}"

odin_bin="${ODIN_BIN:-$(command -v odin || true)}"
if [[ -z "${odin_bin}" && -x "${repo_root}/../odin-setup/odin" ]]; then
  odin_bin="${repo_root}/../odin-setup/odin"
fi
if [[ -z "${odin_bin}" || ! -x "${odin_bin}" ]]; then
  echo "cannot find the Odin compiler; set ODIN_BIN" >&2
  exit 1
fi

args=()
for arg in "$@"; do
  case "${arg}" in
    quick)
      args+=("-quick")
      ;;
    filter=*)
      args+=("-filter=${arg#filter=}")
      ;;
    baseline)
      args+=("-baseline=${results}/kernel.tsv")
      ;;
    *)
      echo "unknown argument: ${arg} (use quick, filter=<text>, baseline)" >&2
      exit 2
      ;;
  esac
done

driver="${repo_root}/.cache/test-bin/kernelbench"
mkdir -p "$(dirname "${driver}")"
"${odin_bin}" build "${repo_root}/benchmarks" -o:speed -out:"${driver}"
"${driver}" -suite=kernel "${args[@]+"${args[@]}"}" \
  -save="${results}/kernel.tsv"

echo "wrote ${results}/kernel.tsv"
