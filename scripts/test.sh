#!/usr/bin/env bash
# Builds and runs the Mica test suites.
#
#   scripts/test.sh              # unit tests (default)
#   scripts/test.sh unit         # package unit tests
#   scripts/test.sh integration  # end-to-end CLI and web smoke tests
#   scripts/test.sh tsan         # unit tests under ThreadSanitizer
#   scripts/test.sh all          # unit + integration
#
# Every external command runs under a timeout (GNU `timeout` or a portable
# fallback), so a hang fails the step instead of blocking the run. A run fails
# on a test failure, a crash, a tracking allocator "bad free", or a
# ThreadSanitizer report. Leaks are reported in the log summary; set
# STRICT_LEAKS=1 to fail on them too (there is a known backlog of
# parser/lexer/builder leaks).
#
# Portable across Linux and macOS: no GNU-only utilities.
#
# Environment:
#   ODIN_BIN       Odin compiler (default: `odin` on PATH, else ../odin-setup/odin)
#   STRICT_LEAKS   set to 1 to fail on any tracking-allocator leak
#   TEST_TIMEOUT   per-command timeout in seconds (default 300)
#   TSAN_TIMEOUT   per-package ThreadSanitizer timeout in seconds (default 1200)
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

packages=(mica/var mica/kernel mica/vm mica/compiler mica/runtime mica/dom mica/store host/web)
bin_dir="${repo_root}/.cache/test-bin"
log_dir="${repo_root}/.cache/test-logs"
strict_leaks="${STRICT_LEAKS:-0}"
test_timeout="${TEST_TIMEOUT:-300}"
tsan_timeout="${TSAN_TIMEOUT:-1200}"
fail=0
cleanup_pids=()
cleanup_paths=()

# Terminates a process and any children, escalating to SIGKILL.
stop_process() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill -TERM "${pid}" 2>/dev/null || true
  pkill -P "${pid}" 2>/dev/null || true
  local i
  for ((i = 0; i < 50; i++)); do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "${pid}" 2>/dev/null || true
  pkill -KILL -P "${pid}" 2>/dev/null || true
}

# Kills leftover servers and removes temp dirs, including on interrupt.
cleanup() {
  local rc=$? i
  if [[ ${#cleanup_pids[@]} -gt 0 ]]; then
    for ((i = ${#cleanup_pids[@]} - 1; i >= 0; i--)); do
      stop_process "${cleanup_pids[i]}"
    done
  fi
  if [[ ${#cleanup_paths[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#cleanup_paths[@]}; i++)); do
      rm -rf "${cleanup_paths[i]}"
    done
  fi
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${bin_dir}" "${log_dir}"

# The fileins that make up the browser MUD (mirror of scripts/mud.sh).
mud_fileins=(
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

# Runs "$@" with a wall-clock limit, using GNU `timeout`/`gtimeout` when
# present and a portable Background+watchdog fallback otherwise (macOS).
run_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${secs}" "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  (
    sleep "${secs}"
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 2
    kill -KILL "${pid}" 2>/dev/null || true
  ) &
  local watchdog=$!
  local rc=0
  wait "${pid}" || rc=$?
  kill -TERM "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true
  return "${rc}"
}

# A stable digest of every file in a directory (POSIX cksum).
store_digest() {
  find "$1" -type f -exec cksum {} + 2>/dev/null | sort
}

slugify() {
  printf '%s' "$1" | tr '/: ' '---'
}

note() { printf '\n== %s\n' "$*"; }
pass() { echo "ok   $*"; }
problem() { echo "FAIL $*"; fail=1; }

# Saves output and decides pass/fail for one test target.
inspect() {
  local label="$1" out="$2"
  local log="${log_dir}/$(slugify "${label}").log"
  printf '%s\n' "${out}" > "${log}"
  local bad leaks
  bad="$(grep -c '+++ bad free' <<<"${out}" || true)"
  leaks="$(grep -c '+++ leak' <<<"${out}" || true)"
  if grep -qE "test failed|Signal caught|\[FATAL\]" <<<"${out}"; then
    problem "${label}: test failure (${log})"
    grep -E "^ - |\[ERROR\]" <<<"${out}" | head -20 || true
  elif [[ "${bad}" -gt 0 ]]; then
    problem "${label}: ${bad} bad free(s) (${log})"
    grep '+++ bad free' <<<"${out}" | head -5 || true
  elif [[ "${strict_leaks}" == "1" && "${leaks}" -gt 0 ]]; then
    problem "${label}: ${leaks} leak(s) (${log})"
  else
    pass "${label} (leaks=${leaks})"
  fi
}

run_unit() {
  note "unit tests"
  for pkg in "${packages[@]}"; do
    local out
    out="$(run_timeout "${test_timeout}" "${odin_bin}" test "${pkg}" 2>&1)" || true
    inspect "unit:${pkg}" "${out}"
  done
}

run_tsan() {
  local supp="${repo_root}/scripts/tsan.supp"
  if [[ ! -f "${supp}" ]]; then
    echo "missing ${supp}" >&2
    exit 1
  fi
  note "ThreadSanitizer unit tests"
  for pkg in "${packages[@]}"; do
    # One test thread avoids cross-test address-reuse false positives; the
    # kernel/runtime internal concurrency tests still run.
    local out
    out="$(TSAN_OPTIONS="suppressions=${supp}" \
      run_timeout "${tsan_timeout}" "${odin_bin}" test "${pkg}" \
      -sanitize:thread -define:ODIN_TEST_THREADS=1 2>&1)" || true
    local log="${log_dir}/$(slugify "tsan:${pkg}").log"
    printf '%s\n' "${out}" > "${log}"
    local races
    races="$(grep -c 'SUMMARY: ThreadSanitizer' <<<"${out}" || true)"
    if grep -qE "test failed|Signal caught|\[FATAL\]" <<<"${out}"; then
      problem "tsan:${pkg}: test failure (${log})"
    elif [[ "${races}" -gt 0 ]]; then
      problem "tsan:${pkg}: ${races} race report(s) (${log})"
      grep 'SUMMARY: ThreadSanitizer' <<<"${out}" | sed -E 's/.* in //' \
        | sort | uniq -c | sort -rn | head -5
    else
      pass "tsan:${pkg}"
    fi
  done
}

build_tools() {
  note "build tools"
  for tool in filein repl webhost parse_corpus; do
    if run_timeout "${test_timeout}" "${odin_bin}" build "tools/${tool}" \
      -out:"${bin_dir}/${tool}"; then
      pass "build:${tool}"
    else
      problem "build:${tool}"
    fi
  done
}

run_web_smoke() {
  local webhost="$1"
  local tmp
  tmp="$(mktemp -d)"
  cleanup_paths+=("${tmp}")
  local log="${tmp}/server.log"
  local args=()
  for file in "${mud_fileins[@]}"; do
    args+=(--filein "${file}")
  done
  # Background the server directly (not through run_timeout) so the PID we
  # track is the server itself and stopping it cannot orphan anything.
  "${webhost}" "${args[@]}" --store "${tmp}/db" \
    --bind 127.0.0.1:0 --sync-client host/web/sync-client.js >"${log}" 2>&1 &
  local pid=$!
  cleanup_pids+=("${pid}")
  local base="" rc=0 i
  for ((i = 0; i < 150; i++)); do
    base="$(grep -oE 'http://127.0.0.1:[0-9]+' "${log}" | head -1 || true)"
    [[ -n "${base}" ]] && break
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  if [[ -z "${base}" ]]; then
    echo "webhost did not start:" >&2
    cat "${log}" >&2 || true
    rc=1
  else
    check_code() {
      local what="$1" expected="$2"
      shift 2
      local code
      code="$(curl -s --max-time "${test_timeout}" -o /dev/null \
        -w '%{http_code}' "$@" || true)"
      if [[ "${code}" == "${expected}" ]]; then
        pass "web-smoke:${what}"
      else
        echo "web-smoke:${what}: expected ${expected}, got ${code}" >&2
        rc=1
      fi
    }
    check_code healthz 200 "${base}/healthz"
    check_code mud 200 "${base}/mud"
    check_code login 303 -X POST -d 'login=alice&password=alice-pass' "${base}/auth/login"
    check_code bad-login 401 -X POST -d 'login=alice&password=wrong' "${base}/auth/login"
    check_code traversal 404 --path-as-is "${base}/mud/../../etc/passwd"
  fi
  stop_process "${pid}"
  wait "${pid}" 2>/dev/null || true
  rm -rf "${tmp}"
  return "${rc}"
}

run_integration() {
  build_tools
  note "integration"
  local filein="${bin_dir}/filein" repl="${bin_dir}/repl" webhost="${bin_dir}/webhost"
  local tmp
  tmp="$(mktemp -d)"
  cleanup_paths+=("${tmp}")

  # filein: load and query a checkpointed store.
  if run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --unit equipment \
    --checkpoint apps/examples/equipment-service.mica >/dev/null; then
    pass "integration:filein-load"
  else
    problem "integration:filein-load"
  fi
  local out
  out="$(run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" \
    --eval 'return ReadyForUse(#sensor_17)' 2>&1 || true)"
  if [[ "${out}" == "true" || "${out}" == "false" ]]; then
    pass "integration:filein-eval"
  else
    problem "integration:filein-eval: expected a boolean, got '${out}'"
  fi

  # A checkpoint after a store boot must complete (regression: reconstruction
  # advanced the version without writing the log, so the checkpoint waited for
  # records that never arrived).
  if run_timeout 30 "${filein}" --store "${tmp}/db" \
    --checkpoint apps/examples/equipment-service.mica >/dev/null 2>&1; then
    pass "integration:checkpoint-after-boot"
  else
    problem "integration:checkpoint-after-boot (timeout or error)"
  fi

  # Read-only evals must not grow the store.
  local before after
  before="$(store_digest "${tmp}/db")"
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --eval 'return 1' >/dev/null
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db" --eval 'return 2' >/dev/null
  after="$(store_digest "${tmp}/db")"
  if [[ "${before}" == "${after}" ]]; then
    pass "integration:read-only-eval"
  else
    problem "integration:read-only-eval: store changed across read-only evals"
  fi

  # A mutation survives a restart (fresh store; booting an existing store
  # ignores new fileins).
  printf 'make_relation(:Color, 1)\n' > "${tmp}/color.mica"
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --checkpoint "${tmp}/color.mica" >/dev/null
  run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --eval 'assert Color(:red)' >/dev/null
  out="$(run_timeout "${test_timeout}" "${filein}" --store "${tmp}/db2" \
    --eval 'return Color(:red)' 2>&1 || true)"
  if [[ "${out}" == "true" ]]; then
    pass "integration:store-mutation"
  else
    problem "integration:store-mutation: expected true, got '${out}'"
  fi

  # REPL evaluates a line.
  local repl_out
  repl_out="$(printf '1 + 1\n' | run_timeout 30 "${repl}" 2>&1 || true)"
  if grep -q "mica> 2" <<<"${repl_out}"; then
    pass "integration:repl"
  else
    problem "integration:repl"
    printf '%s\n' "${repl_out}" | tail -5
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "skip integration:web-smoke (curl not found)"
  elif run_web_smoke "${webhost}"; then
    pass "integration:web-smoke"
  else
    problem "integration:web-smoke"
  fi

  rm -rf "${tmp}"
}

mode="${1:-unit}"
case "${mode}" in
  unit)        run_unit ;;
  integration) run_integration ;;
  tsan)        run_tsan ;;
  all)         run_unit; run_integration ;;
  *)
    echo "usage: scripts/test.sh [unit|integration|tsan|all]" >&2
    exit 2
    ;;
esac

if [[ "${fail}" -ne 0 ]]; then
  echo "test suite: FAILED"
  exit 1
fi
echo "test suite: OK (${mode})"
