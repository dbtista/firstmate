#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-bitacora-check.sh through its public interface,
# using a stub bitacorad on PATH and a temporary FM_HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-bitacora-check.sh"
TMP_ROOT=$(fm_test_tmproot bitacora-check)
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

# Stub: `serve` idles (so the daemon probe sees it), `project list` prints
# $STUB_REGISTERED, `hook session-start` prints $STUB_NOTES note lines.
cat > "$STUB_BIN/bitacorad" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  serve) exec sleep 30 ;;
  project) printf '%s\n' ${STUB_REGISTERED:-} ;;
  hook) n=${STUB_NOTES:-0}; i=0; while [ "$i" -lt "$n" ]; do echo "note $i"; i=$((i + 1)); done ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/bitacorad"

PATH_WITH_STUB="$STUB_BIN:$PATH"
DAEMON_PID=""
start_daemon() {
  "$STUB_BIN/bitacorad" serve >/dev/null 2>&1 &
  DAEMON_PID=$!
  sleep 0.3
}
stop_daemon() {
  [ -z "$DAEMON_PID" ] || kill "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
}
trap 'stop_daemon; fm_test_cleanup' EXIT

new_home() {
  local h="$TMP_ROOT/home-$1"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

run_check() {  # <home> [args...]; sets OUT and RC
  local h=$1
  shift
  OUT=$(FM_HOME="$h" PATH="$PATH_WITH_STUB" "$CHECK" "$@" 2>&1)
  RC=$?
}

test_connected_project() {
  local h
  h=$(new_home connected)
  mkdir -p "$h/projects/alpha"
  start_daemon
  STUB_REGISTERED="$h/projects/alpha" STUB_NOTES=3 run_check "$h" alpha
  stop_daemon
  expect_code 0 "$RC" "connected project"
  assert_contains "$OUT" "Bitácora · alpha" "names the project"
  assert_not_contains "$OUT" "No conectado" "no fix hints when connected"
  pass "connected project exits 0"
}

test_not_connected_prints_fix_hints() {
  local h
  h=$(new_home notconn)
  mkdir -p "$h/projects/beta"
  STUB_REGISTERED="" STUB_NOTES=0 run_check "$h" beta
  expect_code 1 "$RC" "not-connected project"
  assert_contains "$OUT" "No conectado" "reports not connected"
  assert_contains "$OUT" "bitacorad project add $h/projects/beta" "register hint"
  pass "not-connected project exits 1 with fix hints"
}

test_no_projects() {
  local h
  h=$(new_home none)
  run_check "$h"
  expect_code 2 "$RC" "no projects"
  assert_contains "$OUT" "pendiente" "pending checklist"
  pass "no projects exits 2"
}

test_all_projects_without_argument() {
  local h
  h=$(new_home multi)
  mkdir -p "$h/projects/one" "$h/projects/two"
  start_daemon
  STUB_REGISTERED="$h/projects/one" STUB_NOTES=1 run_check "$h"
  stop_daemon
  expect_code 1 "$RC" "mixed projects"
  assert_contains "$OUT" "Bitácora · one" "first project listed"
  assert_contains "$OUT" "Bitácora · two" "second project listed"
  assert_contains "$OUT" "bitacorad project add $h/projects/two" "unregistered one gets a hint"
  assert_not_contains "$OUT" "bitacorad project add $h/projects/one" "connected one gets none"
  pass "no-argument run checks every project"
}

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck absent, skipped"; return; }
  shellcheck "$CHECK" || fail "shellcheck"
  pass "shellcheck clean"
}

test_connected_project
test_not_connected_prints_fix_hints
test_no_projects
test_all_projects_without_argument
test_shellcheck_clean
