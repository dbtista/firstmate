#!/usr/bin/env bash
# tests/fm-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh (not just adapter primitives), because the requirement
# under test - a --secondmate spawn's tab landing in the secondmate's OWN
# herdr workspace, and a crewmate spawned FROM a secondmate home landing there
# too - only exists at fm-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at fm_backend_herdr_workspace_label's FM_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/fm-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the captain's
# default), scratch FM_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .fm-secondmate-home marker) spawning a
#     crewmate into the "firstmate" workspace
#   - a secondmate-shaped home (with .fm-secondmate-home) getting its own
#     labeled workspace when the PRIMARY spawns it (fm-spawn.sh's FM_HOME
#     shadow for --secondmate)
#   - a crewmate spawned FROM that secondmate-shaped home (the secondmate
#     running its OWN fm-spawn.sh) landing in the secondmate's own workspace -
#     this exact path has never run before this test
#   - teardown closing the right tab (and no other)
#   - list-live recovery seeing only its own home's tabs, for both homes
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/fm-backend-autodetect-smoke.test.sh.
# fm-spawn no longer needs this as a symlink workaround: fm-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-e2e.XXXXXX")
SESSION="fm-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=; WT3=; WT4=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  [ -n "$WT3" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT3" >/dev/null 2>&1
  [ -n "$WT4" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT4" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a secondmate-shaped home, two projects ---

# This test asserts the per-home FLAT workspace shape, so both homes opt out of
# the default-on presentation projection rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
cat > "$PRIMARY_HOME/data/cm1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise primary-home Herdr placement.

## Firstmate spec
Verify the crewmate uses its primary home's workspace.
EOF

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_HOME/.gitignore"
git -C "$SM_HOME" init -q -b main
cat > "$SM_HOME/data/cm2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise secondmate-owned Herdr placement.

## Firstmate spec
Verify the crewmate uses its secondmate home's workspace.
EOF

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a crewmate spawns into the "firstmate" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns a crewmate on the herdr backend"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "firstmate" ] || fail "a primary-shaped home's crewmate should land in the 'firstmate' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate landed in the 'firstmate' workspace"

# --- 2. the PRIMARY spawns a secondmate: its tab lands in the SECONDMATE's own space ---
# (fm-spawn.sh's herdr case arm shadows FM_HOME to the secondmate's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo secondmate-launch-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --secondmate spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"

SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$SM_META")" "kind=secondmate" "e2esm1 meta missing kind=secondmate"
assert_contains_local "$(cat "$SM_META")" "backend=herdr" "e2esm1 meta missing backend=herdr"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "e2esm1 meta does not record its own home"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --secondmate task on the herdr backend"

SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
[ "$SM_WSID" != "$CM1_WSID" ] || fail "the secondmate's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "2ndmate-e2esm1" ] || fail "a --secondmate spawn should land in '2ndmate-<id>', got '$SM_WS_LABEL'"
pass "real herdr E2E: a --secondmate spawn by the PRIMARY lands in the SECONDMATE's own labeled workspace, distinct from the primary's"

# --- 3. a crewmate spawned FROM the secondmate-shaped home lands in the SAME
# secondmate workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawned FROM the secondmate-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the SECONDMATE's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a crewmate spawns successfully FROM a secondmate-shaped home's own fm-spawn.sh process"

sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] || fail "a crewmate spawned FROM the secondmate home should land in the SAME workspace as the secondmate's own task ($SM_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a crewmate spawned FROM the secondmate home must NOT land in the primary's workspace"
pass "real herdr E2E: a crewmate spawned FROM the secondmate-shaped home lands in the secondmate's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "fm-cm1" "the primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-e2esm1" "the primary home's list_live must not see the secondmate's own task"
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm2" "the primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "fm-e2esm1" "the secondmate home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "fm-cm2" "the secondmate home's list_live did not see the crewmate spawned from it"
assert_not_contains_local "$SM_LIVE" "fm-cm1" "the secondmate home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the secondmate's own context sees only tasks in the secondmate's own workspace (both its own tab and its crewmate's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the primary-shaped crewmate cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "fm-teardown.sh did not remove cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm1's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the secondmate's and cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$SM_HOME/state" FM_DATA_OVERRIDE="$SM_HOME/data" \
  FM_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the secondmate-owned crewmate cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "fm-teardown.sh did not remove cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm2's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm2 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down cm2 closes only its own tab - the secondmate's own tab (same workspace) survives untouched"

# --- 6. project grouping: herdr-group=on nests a project under its own ---
# workspace tier; off (unregistered, the default) keeps today's flat shape
# unchanged (docs/herdr-backend.md "Project grouping").

PROJ1_NAME=$(basename "$PROJ1")
mkdir -p "$PRIMARY_HOME/data/cm3" "$PRIMARY_HOME/data/cm4"
cat > "$PRIMARY_HOME/data/cm3/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise herdr-group=on project placement.

## Firstmate spec
Verify the crewmate uses its project's own nested workspace.
EOF
cat > "$PRIMARY_HOME/data/cm4/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise herdr-group off (unregistered) project placement.

## Firstmate spec
Verify the crewmate keeps landing in the flat home workspace.
EOF
cat > "$PRIMARY_HOME/data/projects.md" <<EOF
- $PROJ1_NAME [no-mistakes herdr-group=on] - scratch project with grouping on (added 2026-01-01)
EOF

HOOK_OUT="$TMP_ROOT/hook.out"; HOOK_ERR="$TMP_ROOT/hook.err"
FM_BACKEND=herdr FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_PROJECTS_OVERRIDE="$TMP_ROOT" \
  "$ROOT/bin/fm-herdr-project-register-hook.sh" "$PROJ1_NAME" >"$HOOK_OUT" 2>"$HOOK_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "fm-herdr-project-register-hook.sh failed for a herdr-group=on project"$'\n'"--- stdout ---"$'\n'"$(cat "$HOOK_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$HOOK_ERR")"
HOOK_WSID=$(cat "$HOOK_OUT")
[ -n "$HOOK_WSID" ] || fail "the register hook printed no workspace id"
HOOK_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$HOOK_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$HOOK_WS_LABEL" = "firstmate/$PROJ1_NAME" ] || fail "the register hook should create 'firstmate/$PROJ1_NAME', got '$HOOK_WS_LABEL'"
pass "real herdr E2E: fm-herdr-project-register-hook.sh eagerly creates a project's own workspace when herdr-group=on"

NOOP_OUT="$TMP_ROOT/hook-noop.out"
FM_BACKEND=herdr FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_PROJECTS_OVERRIDE="$TMP_ROOT" \
  "$ROOT/bin/fm-herdr-project-register-hook.sh" "$(basename "$PROJ2")" >"$NOOP_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-herdr-project-register-hook.sh should no-op (exit 0) for an unregistered project"
[ -s "$NOOP_OUT" ] && fail "fm-herdr-project-register-hook.sh should print nothing for a project without herdr-group=on, got: $(cat "$NOOP_OUT")"
pass "real herdr E2E: fm-herdr-project-register-hook.sh no-ops for a project whose herdr-group toggle is off"

CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm3 "$PROJ1" "sh -c 'echo grouped-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawn into a herdr-group=on project failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM3_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM3_ERR")"

CM3_META="$PRIMARY_HOME/state/cm3.meta"
[ -f "$CM3_META" ] || fail "no meta written for cm3"
WT3=$(grep '^worktree=' "$CM3_META" | cut -d= -f2-)
CM3_PANE=$(grep '^herdr_pane_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_PANE" ] || fail "cm3 meta missing herdr_pane_id"
assert_contains_local "$(cat "$CM3_META")" "herdr_project_workspace_id=$HOOK_WSID" "cm3 meta should record the eagerly-created project workspace id"

sleep 1
CM3_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM3_PANE" 30) || fail "capture failed on cm3's pane"
assert_contains_local "$CM3_CAPTURE" "grouped-crew-ok" "cm3's raw launch command did not run in its herdr pane"

CM3_WSID=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM3_WSID" = "$HOOK_WSID" ] || fail "a herdr-group=on project's crewmate should land in the project's own workspace ($HOOK_WSID), got '$CM3_WSID'"
[ "$CM3_WSID" != "$CM1_WSID" ] || fail "a herdr-group=on project's crewmate must NOT land directly in the flat 'firstmate' home workspace"
pass "real herdr E2E: a crewmate spawned into a herdr-group=on project lands in that project's own nested workspace, not the flat home workspace"

CM4_OUT="$TMP_ROOT/cm4.out"; CM4_ERR="$TMP_ROOT/cm4.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm4 "$PROJ2" "sh -c 'echo ungrouped-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM4_OUT" 2>"$CM4_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawn into an unregistered (herdr-group off) project failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM4_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM4_ERR")"

CM4_META="$PRIMARY_HOME/state/cm4.meta"
[ -f "$CM4_META" ] || fail "no meta written for cm4"
WT4=$(grep '^worktree=' "$CM4_META" | cut -d= -f2-)
CM4_PANE=$(grep '^herdr_pane_id=' "$CM4_META" | cut -d= -f2-)
[ -n "$CM4_PANE" ] || fail "cm4 meta missing herdr_pane_id"
assert_not_contains_local "$(cat "$CM4_META")" "herdr_project_workspace_id=" "cm4 (toggle off) meta must not record a project workspace id"

CM4_WSID=$(herdr pane get "$CM4_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM4_WSID" ] || fail "could not read cm4's pane workspace_id"
# Compare by LABEL, not by CM1_WSID: cm1's own "firstmate" workspace was
# closed along with its only tab at teardown (step 5), so by now a fresh
# "firstmate" workspace (a different id, same label) backs the home tier -
# exactly what a project-less spawn should still land in.
CM4_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM4_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM4_WS_LABEL" = "firstmate" ] || fail "a project without herdr-group=on should keep landing flat in the 'firstmate' home workspace, got label '$CM4_WS_LABEL'"
[ "$CM4_WSID" != "$CM3_WSID" ] || fail "a project without herdr-group=on must NOT land in another project's own grouped workspace"
pass "real herdr E2E: a project without herdr-group=on keeps today's flat placement unchanged"

TD3_OUT="$TMP_ROOT/td3.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm3 >"$TD3_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the grouped crewmate cm3"$'\n'"$(cat "$TD3_OUT")"
WT3=
TD4_OUT="$TMP_ROOT/td4.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm4 >"$TD4_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the ungrouped crewmate cm4"$'\n'"$(cat "$TD4_OUT")"
WT4=
pass "real herdr E2E: project-grouping crewmates tear down cleanly"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
