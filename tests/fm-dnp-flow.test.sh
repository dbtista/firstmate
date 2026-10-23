#!/usr/bin/env bash
# Behavior tests for bin/fm-dnp-flow.sh, the dnp-flow chain record helper:
# role catalog and titles, chain creation and numbering, handoffs and the
# return-round cap, status, per-project profiles, skill scope files, pane
# titles through fake herdr and tmux clients, and the cycle report scaffold.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dnp-flow)
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_CONFIG_DIR

DNP="$ROOT/bin/fm-dnp-flow.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
for tool in herdr tmux; do
  cat >"$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/$tool.log"
printf '{}\n'
SH
  chmod +x "$FAKEBIN/$tool"
done

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

dnp() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" HOME="$TMP_ROOT/user-home" PATH="$FAKEBIN:$PATH" bash "$DNP" "$@"
}

test_roles_catalog_and_title() {
  local home out chain
  home=$(new_home titles)
  out=$(dnp "$home" roles)
  assert_equals architect "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" "catalog starts with architect"
  assert_equals qa "$(printf '%s\n' "$out" | tail -1 | cut -d' ' -f1)" "catalog ends with qa"
  chain=$(dnp "$home" new aiuse architect dev devsecops qa)
  assert_equals '[DevSecOps] 🔴 🛡️ [aiuse]' "$(dnp "$home" title "$chain" devsecops)" "devsecops title"
  assert_equals '[Architect] 🔵 📐 [aiuse]' "$(dnp "$home" title "$chain" architect)" "architect title"
  pass "the catalog orders roles and titles read [Role] color icon [project]"
}

test_new_validates_orders_and_numbers() {
  local home out rc chain
  home=$(new_home create)
  out=$(dnp "$home" new aiuse dev qa 2>&1); rc=$?
  expect_code 1 "$rc" "a chain without architect"
  assert_contains "$out" "needs the architect role" "missing architect is named"
  out=$(dnp "$home" new aiuse architect dev qa wizard 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown role"
  assert_contains "$out" "unknown role 'wizard'" "unknown role is named"
  out=$(dnp "$home" new Bad_Name architect dev qa 2>&1); rc=$?
  expect_code 1 "$rc" "a non-slug project"
  chain=$(dnp "$home" new aiuse qa dev architect devsecops)
  assert_equals dnp-aiuse-1 "$chain" "first chain id"
  assert_equals 'architect,dev,devsecops,qa' "$(jq -r '[.roles[].role] | join(",")' "$home/data/dnp-chains/$chain/chain.json")" \
    "roles are stored in catalog order"
  assert_equals dnp-aiuse-1-qa "$(jq -r '.roles[-1].task' "$home/data/dnp-chains/$chain/chain.json")" "role task id"
  assert_equals dnp-aiuse-2 "$(dnp "$home" new aiuse architect dev qa)" "second chain id"
  pass "new refuses incomplete or unknown roles, sorts roles, and numbers chains per project"
}

test_latest_skips_closed_chains() {
  local home rc
  home=$(new_home latest)
  dnp "$home" latest aiuse >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "no chain yet"
  dnp "$home" new aiuse architect dev qa >/dev/null
  dnp "$home" new aiuse architect dev qa >/dev/null
  assert_equals dnp-aiuse-2 "$(dnp "$home" latest aiuse)" "newest open chain"
  dnp "$home" state dnp-aiuse-2 closed
  assert_equals dnp-aiuse-1 "$(dnp "$home" latest aiuse)" "a closed chain is skipped"
  dnp "$home" state dnp-aiuse-1 stopped
  assert_equals dnp-aiuse-1 "$(dnp "$home" latest aiuse)" "a stopped chain stays resumable"
  assert_equals dnp-bitacora-web-1 "$(dnp "$home" new bitacora-web architect dev qa)" "a dash-prefixed project's chain"
  dnp "$home" latest bitacora >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "another project whose slug extends this one"
  assert_equals dnp-bitacora-1 "$(dnp "$home" new bitacora architect dev qa)" "numbering ignores the dash-prefixed project"
  assert_equals dnp-bitacora-1 "$(dnp "$home" latest bitacora)" "latest names only its own project"
  assert_equals dnp-bitacora-web-1 "$(dnp "$home" latest bitacora-web)" "the longer slug keeps its chain"
  pass "latest returns the newest chain of exactly that project that is not closed"
}

test_handoffs_track_tip_and_cap_returns() {
  local home chain file out rc before
  home=$(new_home handoff)
  chain=$(dnp "$home" new aiuse architect dev qa)
  file="$home/data/dnp-chains/$chain/chain.json"
  out=$(dnp "$home" handoff "$chain" dev --return 2>&1); rc=$?
  expect_code 1 "$rc" "a chain cannot start with a return"
  dnp "$home" handoff "$chain" architect >/dev/null
  printf 'branch=fm/%s-architect\n' "$chain" >"$home/state/$chain-architect.meta"
  printf 'branch=fm/%s-dev\n' "$chain" >"$home/state/$chain-dev.meta"
  printf 'branch=fm/%s-qa\n' "$chain" >"$home/state/$chain-qa.meta"
  dnp "$home" handoff "$chain" dev >/dev/null
  out=$(dnp "$home" handoff "$chain" qa)
  assert_contains "$out" "tip: fm/$chain-dev" "the tip is the outgoing role's branch"
  for round in 1 2 3; do
    out=$(dnp "$home" handoff "$chain" dev --return --note "blocking bug $round")
    assert_contains "$out" "round: $round/3" "return $round is counted"
    assert_contains "$out" "tip: fm/$chain-qa" "a return hands over the qa branch"
    dnp "$home" handoff "$chain" qa >/dev/null
  done
  before=$(cat "$file")
  out=$(dnp "$home" handoff "$chain" dev --return 2>&1); rc=$?
  expect_code 3 "$rc" "a fourth return"
  assert_contains "$out" "return cap reached" "the cap refusal is explicit"
  assert_equals "$before" "$(cat "$file")" "a refused return leaves the record unchanged"
  out=$(dnp "$home" status "$chain")
  assert_contains "$out" "active: qa" "status names the active role"
  assert_contains "$out" "round: 3/3" "status names the round"
  assert_contains "$out" "last_handoff: dev -> qa (forward)" "status names the last handoff"
  out=$(dnp "$home" status)
  assert_contains "$out" "$chain project=aiuse state=active active=qa round=3/3" "the fleet listing"
  pass "handoffs track the tip branch and a fourth return is refused with exit 3"
}

test_only_qa_returns_consume_rounds() {
  local home chain file out rc before
  home=$(new_home qa-cap)
  chain=$(dnp "$home" new aiuse architect dev devsecops qa)
  file="$home/data/dnp-chains/$chain/chain.json"
  dnp "$home" handoff "$chain" architect >/dev/null
  dnp "$home" handoff "$chain" dev >/dev/null
  dnp "$home" handoff "$chain" devsecops >/dev/null
  out=$(dnp "$home" handoff "$chain" dev --return --note "devsecops blocking finding")
  assert_contains "$out" "round: 0/3" "a devsecops return consumes no round"
  assert_equals return "$(jq -r '.handoffs[-1].kind' "$file")" "the devsecops return is recorded as a return"
  assert_equals devsecops "$(jq -r '.handoffs[-1].from' "$file")" "the record names who returned the work"
  dnp "$home" handoff "$chain" devsecops >/dev/null
  dnp "$home" handoff "$chain" qa >/dev/null
  for round in 1 2 3; do
    out=$(dnp "$home" handoff "$chain" dev --return --note "qa blocking bug $round")
    assert_contains "$out" "round: $round/3" "qa return $round is counted"
    dnp "$home" handoff "$chain" devsecops >/dev/null
    out=$(dnp "$home" handoff "$chain" dev --return --note "devsecops finding $round")
    assert_contains "$out" "round: $round/3" "a devsecops return after qa return $round consumes nothing"
    dnp "$home" handoff "$chain" qa >/dev/null
  done
  before=$(cat "$file")
  out=$(dnp "$home" handoff "$chain" dev --return 2>&1); rc=$?
  expect_code 3 "$rc" "a fourth qa return"
  assert_contains "$out" "3 of 3 QA return rounds already used" "the cap refusal names the qa rounds"
  assert_equals "$before" "$(cat "$file")" "a refused qa return leaves the record unchanged"
  pass "only returns issued by qa consume one of the three rounds"
}

test_set_role_profile_and_scope() {
  local home chain proj out
  home=$(new_home profile)
  proj="$TMP_ROOT/project"
  mkdir -p "$proj/.claude/skills/bitacora" "$proj/.agents/skills/aiuse-review" "$TMP_ROOT/user-home/.claude/skills/personal"
  printf -- '---\nname: bitacora\n---\n' >"$proj/.claude/skills/bitacora/SKILL.md"
  printf 'no front matter\n' >"$proj/.agents/skills/aiuse-review/SKILL.md"
  printf -- '---\nname: "personal-notes"\n---\n' >"$TMP_ROOT/user-home/.claude/skills/personal/SKILL.md"
  chain=$(dnp "$home" new aiuse architect dev qa)
  assert_equals $'aiuse-review\nbitacora\npersonal-notes' "$(dnp "$home" skills "$proj")" "candidate skills"
  dnp "$home" set-role "$chain" dev --harness claude --model claude-opus-5-5 --effort high --skills bitacora
  dnp "$home" scope "$chain" dev "$proj" >/dev/null
  out=$(grep -v '^#' "$home/data/$chain-dev/skills-off")
  assert_equals $'aiuse-review\npersonal-notes' "$out" "skills-off lists every candidate except the chosen ones"
  dnp "$home" set-role "$chain" dev --skills all
  dnp "$home" scope "$chain" dev "$proj" >/dev/null
  assert_absent "$home/data/$chain-dev/skills-off" "all skills removes the earlier list"
  out=$(dnp "$home" set-role "$chain" dev --skills 'bad name' 2>&1) && fail "a malformed skill list was accepted"
  dnp "$home" profile show aiuse >/dev/null 2>&1 && fail "a profile existed before any save"
  dnp "$home" profile save "$chain" >/dev/null
  out=$(dnp "$home" profile show aiuse)
  assert_equals claude-opus-5-5 "$(printf '%s' "$out" | jq -r '.roles[] | select(.role == "dev") | .model')" "profile keeps the model"
  assert_equals "$chain" "$(printf '%s' "$out" | jq -r '.from_chain')" "profile names its chain"
  pass "role choices persist, scope files follow the chosen skills, and profiles round-trip"
}

test_skills_follow_the_worker_config_root() {
  local home proj alt pinned out chain
  home=$(new_home skills-root)
  proj="$TMP_ROOT/bare-project"
  alt="$TMP_ROOT/alt-config"
  pinned="$TMP_ROOT/pinned-config"
  mkdir -p "$proj" "$alt/skills/alt" "$pinned/skills/pinned" "$TMP_ROOT/user-home/.claude/skills/personal"
  printf -- '---\nname: alt-skill\n---\n' >"$alt/skills/alt/SKILL.md"
  printf -- '---\nname: pinned-skill\n---\n' >"$pinned/skills/pinned/SKILL.md"
  printf -- '---\nname: "personal-notes"\n---\n' >"$TMP_ROOT/user-home/.claude/skills/personal/SKILL.md"
  assert_equals personal-notes "$(dnp "$home" skills "$proj")" "an unset CLAUDE_CONFIG_DIR lists ~/.claude/skills"
  out=$(CLAUDE_CONFIG_DIR="$alt" dnp "$home" skills "$proj")
  assert_equals alt-skill "$out" "CLAUDE_CONFIG_DIR selects the personal skills"
  mkdir -p "$home/config"
  printf '%s\n' "$pinned" >"$home/config/claude-account"
  out=$(CLAUDE_CONFIG_DIR="$alt" dnp "$home" skills "$proj")
  assert_equals pinned-skill "$out" "a pinned account root replaces CLAUDE_CONFIG_DIR"
  printf 'ordinary\n' >"$home/config/claude-account"
  out=$(CLAUDE_CONFIG_DIR="$alt" dnp "$home" skills "$proj")
  assert_equals personal-notes "$out" "an ordinary pin lists ~/.claude/skills"
  printf 'relative/path\n' >"$home/config/claude-account"
  dnp "$home" skills "$proj" >/dev/null 2>&1 && fail "a malformed pin was accepted"
  chain=$(dnp "$home" new aiuse architect dev qa)
  dnp "$home" set-role "$chain" dev --skills none-of-these
  dnp "$home" scope "$chain" dev "$proj" >/dev/null 2>&1 && fail "scope wrote a list despite a malformed pin"
  assert_absent "$home/data/$chain-dev/skills-off" "a malformed pin writes no scope file"
  pass "personal skills come from the config root a worker launches with"
}

test_title_apply_per_backend() {
  local home chain out
  home=$(new_home apply)
  chain=$(dnp "$home" new aiuse architect dev qa)
  out=$(dnp "$home" title "$chain" dev --apply 2>&1) && fail "applying a title without a task record succeeded"
  printf 'backend=herdr\nherdr_session=lab\nherdr_pane_id=w1:p2\nwindow=lab:w1:p2\n' >"$home/state/$chain-dev.meta"
  dnp "$home" title "$chain" dev --apply >/dev/null
  assert_grep 'pane rename w1:p2 [Dev] 🟢 💻 [aiuse] --session lab' "$TMP_ROOT/herdr.log" "herdr renames the pane"
  printf 'window=fm:@7\n' >"$home/state/$chain-qa.meta"
  dnp "$home" title "$chain" qa --apply >/dev/null
  assert_grep 'select-pane -t fm:@7 -T [QA] 🟡 🧪 [aiuse]' "$TMP_ROOT/tmux.log" "tmux titles the pane"
  printf 'backend=zellij\nwindow=z:1\n' >"$home/state/$chain-architect.meta"
  out=$(dnp "$home" title "$chain" architect --apply 2>&1) || fail "an unsupported backend must not fail"
  assert_contains "$out" "has no pane title support" "an unsupported backend says so"
  pass "titles apply through herdr pane rename and tmux select-pane, and other backends say they cannot"
}

test_report_scaffold() {
  local home chain path
  home=$(new_home report)
  chain=$(dnp "$home" new aiuse architect dev qa)
  dnp "$home" handoff "$chain" architect >/dev/null
  dnp "$home" state "$chain" closed --pr https://github.com/o/r/pull/9
  path=$(dnp "$home" report "$chain")
  assert_equals "$home/data/dnp-chains/$chain/report.md" "$path" "report path"
  assert_grep 'PR: https://github.com/o/r/pull/9' "$path" "report names the PR"
  assert_grep '| dev | dnp-aiuse-1-dev |' "$path" "report lists the roles"
  assert_grep 'start -> architect (start, round 0)' "$path" "report lists handoffs"
  printf 'edited\n' >"$path"
  dnp "$home" report "$chain" >/dev/null
  assert_equals edited "$(cat "$path")" "an existing report is never overwritten"
  dnp "$home" state "$chain" active --pr not-a-url >/dev/null 2>&1 && fail "a non-https PR was accepted"
  pass "the report scaffold is written once from the record"
}

test_roles_catalog_and_title
test_new_validates_orders_and_numbers
test_latest_skips_closed_chains
test_handoffs_track_tip_and_cap_returns
test_only_qa_returns_consume_rounds
test_set_role_profile_and_scope
test_skills_follow_the_worker_config_root
test_title_apply_per_backend
test_report_scaffold
