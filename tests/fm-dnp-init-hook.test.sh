#!/usr/bin/env bash
# Behavior tests for bin/fm-dnp-init-hook.sh, the Claude Code prompt-submit
# hook that routes `.init dev` to the dnp-flow skill, driven through the
# tracked .claude/settings.json registration exactly as Claude runs it.
# shellcheck disable=SC2016 # jq programs use their own $variables
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dnp-init-hook)
trap fm_test_cleanup EXIT

CMD=$(jq -r '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-dnp-init-hook.sh")) | .command' \
  "$ROOT/.claude/settings.json")
[ -n "$CMD" ] || fail "no tracked UserPromptSubmit entry runs fm-dnp-init-hook.sh"
[ "$(printf '%s\n' "$CMD" | wc -l)" -eq 1 ] || fail "expected exactly one tracked dnp-flow hook entry"

# Runs the tracked command on a Claude prompt-submit payload carrying <prompt>.
submit() {  # <prompt>
  jq -cn --arg p "$1" '{hook_event_name: "UserPromptSubmit", session_id: "s", prompt: $p}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$ROOT" bash -c "$CMD"
}

context_of() {  # <hook stdout>
  printf '%s' "$1" | jq -r '.hookSpecificOutput | select(.hookEventName == "UserPromptSubmit") | .additionalContext'
}

test_bare_trigger_loads_skill() {
  local out rc ctx
  out=$(submit '.init dev'); rc=$?
  expect_code 0 "$rc" "bare .init dev"
  ctx=$(context_of "$out")
  assert_contains "$ctx" 'Load the `dnp-flow` skill' "bare trigger names the skill"
  assert_contains "$ctx" 'with no arguments' "bare trigger has no arguments"
  pass "bare .init dev injects the dnp-flow load context"
}

test_subcommands_and_project_pass_through() {
  local arg ctx
  for arg in status stop aiuse; do
    ctx=$(context_of "$(submit "  .init   dev $arg  ")")
    assert_contains "$ctx" "with arguments: $arg." "argument $arg passes through trimmed"
  done
  pass "status, stop, and a project name pass through as arguments"
}

test_first_line_only_is_arguments() {
  local ctx
  ctx=$(context_of "$(submit $'.init dev aiuse\nfix the login redirect\r\n')")
  assert_contains "$ctx" 'with arguments: aiuse.' "only the first line is arguments"
  assert_not_contains "$ctx" 'login redirect' "later lines are not copied into the arguments"
  assert_contains "$ctx" 'further lines of the prompt' "the context points at later lines as the request"
  pass "a multi-line prompt passes only its first line as arguments"
}

test_other_prompts_are_silent() {
  local p out rc
  for p in 'hello' 'please .init dev' '.init devops' '.initdev' '.init' '.Init dev' '' '.init staging'; do
    out=$(submit "$p"); rc=$?
    expect_code 0 "$rc" "prompt '$p'"
    assert_equals '' "$out" "prompt '$p' must produce no output"
  done
  pass "every other prompt is a silent no-op"
}

test_bad_payload_never_blocks() {
  local out rc
  out=$(printf 'not json .init dev' | CLAUDE_PROJECT_DIR="$ROOT" bash -c "$CMD"); rc=$?
  expect_code 0 "$rc" "malformed payload"
  assert_equals '' "$out" "malformed payload stays silent"
  out=$(CLAUDE_PROJECT_DIR="$ROOT" bash -c "$CMD" </dev/null); rc=$?
  expect_code 0 "$rc" "empty stdin"
  assert_equals '' "$out" "empty stdin stays silent"
  pass "a malformed or empty payload exits 0 silently"
}

test_missing_jq_is_silent() {
  local bin out rc tool
  bin="$TMP_ROOT/nojq-bin"
  mkdir -p "$bin"
  for tool in bash cat env; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  out=$(printf '{"prompt":".init dev"}' | PATH="$bin" CLAUDE_PROJECT_DIR="$ROOT" "$bin/bash" -c "$CMD"); rc=$?
  expect_code 0 "$rc" "missing jq"
  assert_equals '' "$out" "missing jq stays silent"
  pass "a host without jq stays silent"
}

test_bare_trigger_loads_skill
test_subcommands_and_project_pass_through
test_first_line_only_is_arguments
test_other_prompts_are_silent
test_bad_payload_never_blocks
test_missing_jq_is_silent
