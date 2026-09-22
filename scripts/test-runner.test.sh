#!/usr/bin/env bash
# Exercise the portable timeout wrapper without requiring Odin or network access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/omica-test-runner.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/scripts" "${fixture}/vendor/micromeasure/micromeasure-odin"
cp "${repo_root}/scripts/test.sh" "${fixture}/scripts/test.sh"
touch "${fixture}/vendor/micromeasure/micromeasure-odin/micromeasure.odin"
cat > "${fixture}/fake-odin" <<'COMPILER'
#!/usr/bin/env bash
printf 'stdout: %s\n' "$2"
printf 'stderr: %s\n' "$2" >&2
if [[ "$2" == host/source ]]; then
  printf '[ERROR] synthetic test failure\n' >&2
  exit 1
fi
COMPILER
chmod +x "${fixture}/fake-odin"
export ODIN_BIN="${fixture}/fake-odin" PORTABLE_TIMEOUT=1 TEST_TIMEOUT=10
for stdin_state in open closed; do
  rc=0
  if [[ "${stdin_state}" == open ]]; then
    bash "${fixture}/scripts/test.sh" unit >"${fixture}/run.log" 2>&1 || rc=$?
  else
    bash "${fixture}/scripts/test.sh" unit <&- >"${fixture}/run.log" 2>&1 || rc=$?
  fi
  if [[ "${rc}" != 1 ]]; then
    echo "expected the synthetic failure to exit 1, got ${rc}" >&2
    exit 1
  fi
  for log in "${fixture}"/.cache/test-logs/unit-*.log; do
    grep -q '^stdout: ' "${log}"
    grep -q '^stderr: ' "${log}"
  done
  grep -q '\[ERROR\] synthetic test failure' "${fixture}/run.log"
  echo "ok portable timeout capture (stdin ${stdin_state})"
done
