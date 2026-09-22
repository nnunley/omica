#!/usr/bin/env bash
# Runs the kernel suite and writes kernel-latest.tsv and kernel-latest.json.
#
#   scripts/kernel-bench.sh                 # full suite, keep saved baseline
#   scripts/kernel-bench.sh baseline        # compare against kernel.tsv
#   scripts/kernel-bench.sh filter=10k quick # spot check, keep saved baseline
#   scripts/kernel-bench.sh update-baseline # full suite, replace kernel.tsv
#
# Memory is process high-water growth across warmup, calibration, and samples.
# Previous allocations can mask growth. A filter still builds all suite states.
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
update_baseline=0
partial_run=0
for arg in "$@"; do
  case "${arg}" in
    quick)
      args+=("-quick")
      partial_run=1
      ;;
    filter=*)
      args+=("-filter=${arg#filter=}")
      partial_run=1
      ;;
    update-baseline)
      update_baseline=1
      ;;
    baseline)
      args+=("-baseline=${results}/kernel.tsv")
      ;;
    *)
      echo "unknown argument: ${arg} (use quick, filter=<text>, baseline, update-baseline)" >&2
      exit 2
      ;;
  esac
done

if [[ "${update_baseline}" == "1" && "${partial_run}" == "1" ]]; then
  echo "update-baseline requires a full run without quick or filter" >&2
  exit 2
fi

driver="${repo_root}/.cache/test-bin/kernelbench"
mkdir -p "$(dirname "${driver}")"
"${odin_bin}" build "${repo_root}/benchmarks" -o:speed -out:"${driver}"
"${driver}" -suite=kernel "${args[@]+"${args[@]}"}" \
  -save="${results}/kernel-latest.tsv" -json="${results}/kernel-latest.json" \
  -build-flags=-o:speed -machine="$(uname -sm)" \
  -revision="$(git -C "${repo_root}" describe --always --dirty)"

if [[ "${update_baseline}" == "1" ]]; then
  cp "${results}/kernel-latest.tsv" "${results}/kernel.tsv"
  cp "${results}/kernel-latest.json" "${results}/kernel.json"
  echo "updated ${results}/kernel.tsv and kernel.json"
fi
echo "wrote ${results}/kernel-latest.tsv and kernel-latest.json"
