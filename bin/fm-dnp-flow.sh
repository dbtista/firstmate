#!/usr/bin/env bash
# fm-dnp-flow.sh - durable records and mechanics for a dnp-flow development
# chain, the captain-invoked `.init dev` chain of fixed role agents.
#
# .agents/skills/dnp-flow/SKILL.md owns the procedure that calls this script,
# and docs/dnp-flow.md owns the methodology (roles, handoff loop, blocking
# versus cosmetic findings). This script owns the role catalog, the chain
# record, the return-round cap, agent titles, per-project profiles, and the
# per-role skill scope. It never spawns, steers, stops, or tears down a worker;
# bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-control.sh, and bin/fm-teardown.sh do.
#
# Usage:
#   fm-dnp-flow.sh roles
#   fm-dnp-flow.sh new <project> <role>...
#   fm-dnp-flow.sh latest <project>
#   fm-dnp-flow.sh set-role <chain> <role> [--harness <h>] [--model <m>] [--effort <e>] [--skills <a,b|all>]
#   fm-dnp-flow.sh title <chain> <role> [--apply]
#   fm-dnp-flow.sh handoff <chain> <to-role> [--return] [--note <text>]
#   fm-dnp-flow.sh status [<chain>]
#   fm-dnp-flow.sh state <chain> active|stopped|closed [--pr <url>]
#   fm-dnp-flow.sh profile save <chain>
#   fm-dnp-flow.sh profile show <project>
#   fm-dnp-flow.sh skills <project-dir>
#   fm-dnp-flow.sh scope <chain> <role> <project-dir>
#   fm-dnp-flow.sh report <chain>
#
# `roles` prints the catalog in chain order, one role per line as
# `<role> <Title> <color> <icon>`; color is an emoji because no supported
# terminal backend exposes a pane color.
# `new` validates the roles against the catalog, requires architect, dev, and
# qa, sorts them into catalog order, and creates the next chain record
# `dnp-<project>-<n>` under data/dnp-chains/<chain>/chain.json; it prints the
# chain id. Each role's task id is `<chain>-<role>`.
# `latest` prints the newest chain for <project> that is not closed, exit 1
# when there is none.
# `set-role` records the captain's dispatch and skill choice for one role;
# `--skills all` (the default) leaves every skill available.
# `title` prints `[<Title>] <color> <icon> [<project>]`. With --apply it sets
# that text as the display title of the role's live pane: herdr through
# `pane rename`, tmux through `select-pane -T`. Neither title is an identity
# field (Herdr tab labels and tmux window names, which are, stay unchanged).
# Any other backend prints a note and exits 0 without a title.
# `handoff` records a handoff from the active role to <to-role>, sets the tip
# branch to the outgoing role's task branch (read from its state/<task>.meta),
# and makes <to-role> active. The first handoff of a chain starts it.
# `--return` marks a return for a blocking finding and counts one round; a
# return past DNP_FLOW_MAX_ROUNDS (3) is refused with exit 3 and changes
# nothing, which is the signal to hold the captain decision.
# `status` prints one chain's active role, round, tip, and last handoff, or one
# line per chain with no argument.
# `state` records active, stopped (resumable), or closed, plus an optional PR.
# `profile save` stores the chain's per-role choices as the project's profile
# under data/dnp-chains/profiles/<project>.json; `profile show` prints it,
# exit 1 when absent.
# `skills` lists the skill names a worker in <project-dir> could load: the
# project's .claude/skills and .agents/skills and the user's ~/.claude/skills.
# Plugin and built-in skills are not listed and so are never scoped off.
# `scope` writes data/<task>/skills-off, the listed skills minus the role's
# chosen ones, which bin/fm-spawn.sh enforces on claude workers only (its
# header "Worker skill scope"); with `all` it removes any earlier list.
# `report` writes the cycle report scaffold data/dnp-chains/<chain>/report.md
# from the record when absent, and prints its path.
#
# Records are captain-private: they live under the home's gitignored data/.
# Environment: FM_HOME selects the home; FM_DATA_OVERRIDE and
# FM_STATE_OVERRIDE override its data/ and state/ directories.
# shellcheck disable=SC2016 # jq programs use their own $variables
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHAINS="$DATA/dnp-chains"
DNP_FLOW_MAX_ROUNDS=3

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^# Records are/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

# Role catalog, in chain order: <role> <Title> <color> <icon>.
CATALOG='architect Architect 🔵 📐
dev Dev 🟢 💻
ux UX 🟠 🎨
devsecops DevSecOps 🔴 🛡️
devops DevOps 🟣 ⚙️
docs Docs ⚪ 📝
qa QA 🟡 🧪'

catalog_line() {  # <role>
  local line
  while IFS= read -r line; do
    [ "${line%% *}" = "$1" ] && { printf '%s\n' "$line"; return 0; }
  done <<<"$CATALOG"
  return 1
}

catalog_rank() {  # <role>
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [ "${line%% *}" = "$1" ] && { printf '%s\n' "$n"; return 0; }
  done <<<"$CATALOG"
  return 1
}

valid_slug() {  # <value>
  [ -n "$1" ] && [ -z "${1//[a-z0-9-]/}" ] && [ "${1#-}" = "$1" ] && [ "${1%-}" = "$1" ]
}

chain_file() {  # <chain>
  valid_slug "$1" && [ "$1" != profiles ] || die "invalid chain id '$1'"
  [ -f "$CHAINS/$1/chain.json" ] || die "no dnp-flow chain '$1' in $CHAINS"
  printf '%s\n' "$CHAINS/$1/chain.json"
}

# write_json <file> <jq-program> [jq args...]: rewrite <file> through jq
# atomically; a failed program leaves the file untouched.
write_json() {
  local file=$1 tmp
  shift
  tmp="$file.tmp.$$"
  if jq "$@" "$file" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "could not update $file"
  fi
}

require_role() {  # <chain-file> <role>
  jq -e --arg r "$2" 'any(.roles[]; .role == $r)' "$1" >/dev/null \
    || die "role '$2' is not part of this chain"
}

role_task() {  # <chain-file> <role>
  jq -r --arg r "$2" '.roles[] | select(.role == $r) | .task' "$1"
}

cmd_roles() {
  printf '%s\n' "$CATALOG"
}

cmd_new() {
  local project=$1 role n max=0 dir chain task roles_json='[]' line
  shift
  valid_slug "$project" || die "project must be a lowercase slug of letters, digits, and dashes"
  [ "$#" -gt 0 ] || die "name the chain's roles"
  local -a ranked=()
  for role in "$@"; do
    n=$(catalog_rank "$role") || die "unknown role '$role'; see '$0 roles'"
    ranked+=("$n $role")
  done
  for role in architect dev qa; do
    printf '%s\n' "$@" | grep -qx -- "$role" || die "a chain needs the $role role"
  done
  mkdir -p "$CHAINS"
  for dir in "$CHAINS/dnp-$project-"*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    n=${dir##*-}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max=$n
  done
  chain="dnp-$project-$((max + 1))"
  while IFS= read -r line; do
    role=${line#* }
    task="$chain-$role"
    fm_task_id_creation_valid "$task" || die "task id '$task' is too long; use a shorter project slug"
    roles_json=$(jq -c --arg r "$role" --arg t "$task" \
      '. + [{role: $r, task: $t, harness: "", model: "", effort: "", skills: "all"}]' <<<"$roles_json")
  done < <(printf '%s\n' "${ranked[@]}" | sort -n -u)
  mkdir "$CHAINS/$chain" || die "could not create $CHAINS/$chain"
  jq -n --arg c "$chain" --arg p "$project" --argjson roles "$roles_json" --argjson now "$(date +%s)" \
    '{chain: $c, project: $p, state: "active", created_at: $now, roles: $roles,
      active: "", tip: "", round: 0, handoffs: [], pr: ""}' >"$CHAINS/$chain/chain.json"
  printf '%s\n' "$chain"
}

cmd_latest() {
  local project=$1 dir n best=0 chain=''
  valid_slug "$project" || die "invalid project '$project'"
  for dir in "$CHAINS/dnp-$project-"*/; do
    [ -f "$dir/chain.json" ] || continue
    dir=${dir%/}
    n=${dir##*-}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    jq -e '.state != "closed"' "$dir/chain.json" >/dev/null || continue
    if [ "$n" -gt "$best" ]; then
      best=$n
      chain=${dir##*/}
    fi
  done
  [ -n "$chain" ] || return 1
  printf '%s\n' "$chain"
}

cmd_set_role() {
  local file role harness='' model='' effort='' skills='' set_h=0 set_m=0 set_e=0 set_s=0
  file=$(chain_file "$1")
  role=$2
  shift 2
  require_role "$file" "$role"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness) harness=${2-}; set_h=1; shift 2 ;;
      --model) model=${2-}; set_m=1; shift 2 ;;
      --effort) effort=${2-}; set_e=1; shift 2 ;;
      --skills) skills=${2-}; set_s=1; shift 2 ;;
      *) die "unknown set-role option '$1'" ;;
    esac
  done
  if [ "$set_s" = 1 ] && [ "$skills" != all ] && [ -n "${skills//[A-Za-z0-9_.:,-]/}" ]; then
    die "--skills takes 'all' or comma-separated skill names"
  fi
  write_json "$file" --arg r "$role" --arg h "$harness" --arg m "$model" --arg e "$effort" --arg s "$skills" \
    --argjson sh "$set_h" --argjson sm "$set_m" --argjson se "$set_e" --argjson ss "$set_s" '
    .roles |= map(if .role == $r then
      (if $sh == 1 then .harness = $h else . end)
      | (if $sm == 1 then .model = $m else . end)
      | (if $se == 1 then .effort = $e else . end)
      | (if $ss == 1 then .skills = (if $s == "all" or $s == "" then "all" else ($s | split(",") | map(select(. != ""))) end) else . end)
    else . end)'
}

title_text() {  # <chain-file> <role>
  local line title color icon project
  line=$(catalog_line "$2") || die "unknown role '$2'"
  read -r _ title color icon <<<"$line"
  project=$(jq -r '.project' "$1")
  printf '[%s] %s %s [%s]\n' "$title" "$color" "$icon" "$project"
}

cmd_title() {
  local file role apply=0 title task meta backend session pane target
  file=$(chain_file "$1")
  role=$2
  [ "${3-}" = --apply ] && apply=1
  require_role "$file" "$role"
  title=$(title_text "$file" "$role")
  printf '%s\n' "$title"
  [ "$apply" = 1 ] || return 0
  task=$(role_task "$file" "$role")
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || die "role '$role' has no live task record ($task); spawn it first"
  backend=$(fm_backend_of_meta "$meta")
  case "$backend" in
    herdr)
      session=$(fm_meta_get "$meta" herdr_session)
      pane=$(fm_meta_get "$meta" herdr_pane_id)
      [ -n "$session" ] && [ -n "$pane" ] || die "task $task records no herdr pane"
      fm_backend_source herdr || die "cannot load the herdr backend"
      fm_backend_herdr_cli "$session" pane rename "$pane" "$title" >/dev/null \
        || die "herdr refused to title pane $pane"
      ;;
    tmux)
      target=$(fm_backend_target_of_meta "$meta")
      [ -n "$target" ] || die "task $task records no tmux window"
      tmux select-pane -t "$target" -T "$title" || die "tmux refused to title $target"
      ;;
    *)
      printf 'note: the %s backend has no pane title support; the title was not applied\n' "$backend" >&2
      ;;
  esac
}

cmd_handoff() {
  local file to kind=forward note='' from tip='' task branch round
  file=$(chain_file "$1")
  to=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --return) kind='return'; shift ;;
      --note) note=${2-}; shift 2 ;;
      *) die "unknown handoff option '$1'" ;;
    esac
  done
  require_role "$file" "$to"
  jq -e '.state != "closed"' "$file" >/dev/null || die "chain is closed"
  from=$(jq -r '.active' "$file")
  [ "$from" != "$to" ] || die "role '$to' is already active"
  if [ -z "$from" ]; then
    [ "$kind" = forward ] || die "a chain cannot start with a return"
    kind=start
  else
    task=$(role_task "$file" "$from")
    branch=$(fm_meta_get "$STATE/$task.meta" branch)
    tip=${branch:-$(jq -r '.tip' "$file")}
  fi
  round=$(jq -r '.round' "$file")
  if [ "$kind" = return ]; then
    if [ "$round" -ge "$DNP_FLOW_MAX_ROUNDS" ]; then
      printf 'error: return cap reached: %s of %s return rounds already used; hold the captain decision instead\n' \
        "$round" "$DNP_FLOW_MAX_ROUNDS" >&2
      exit 3
    fi
    round=$((round + 1))
  fi
  write_json "$file" --arg from "$from" --arg to "$to" --arg kind "$kind" --arg note "$note" \
    --arg tip "$tip" --argjson round "$round" --argjson now "$(date +%s)" '
    .active = $to | .round = $round | .state = "active"
    | (if $tip != "" then .tip = $tip else . end)
    | .handoffs += [{at: $now, from: $from, to: $to, kind: $kind, round: $round, note: $note}]'
  jq -r --argjson max "$DNP_FLOW_MAX_ROUNDS" \
    '"active: \(.active)\nround: \(.round)/\($max)\ntip: \(if .tip == "" then "(none)" else .tip end)"' "$file"
}

cmd_status() {
  local file dir
  if [ "$#" -gt 0 ]; then
    file=$(chain_file "$1")
    jq -r --argjson max "$DNP_FLOW_MAX_ROUNDS" '
      "chain: \(.chain)", "project: \(.project)", "state: \(.state)",
      "active: \(if .active == "" then "(not started)" else .active end)",
      "round: \(.round)/\($max)",
      "tip: \(if .tip == "" then "(none)" else .tip end)",
      "roles: \([.roles[].role] | join(","))",
      "last_handoff: \(if (.handoffs | length) == 0 then "(none)" else (.handoffs[-1] | "\(if .from == "" then "start" else .from end) -> \(.to) (\(.kind)) at \(.at | todate)\(if .note == "" then "" else ": \(.note)" end)") end)",
      "pr: \(if .pr == "" then "(none)" else .pr end)"' "$file"
    return 0
  fi
  for dir in "$CHAINS"/*/; do
    [ -f "$dir/chain.json" ] || continue
    jq -r --argjson max "$DNP_FLOW_MAX_ROUNDS" \
      '"\(.chain) project=\(.project) state=\(.state) active=\(if .active == "" then "-" else .active end) round=\(.round)/\($max)"' \
      "$dir/chain.json"
  done
}

cmd_state() {
  local file value pr='' set_pr=0
  file=$(chain_file "$1")
  value=$2
  shift 2
  case "$value" in active | stopped | closed) ;; *) die "state must be active, stopped, or closed" ;; esac
  if [ "${1-}" = --pr ]; then
    pr=${2-}
    set_pr=1
    case "$pr" in https://*) ;; *) die "--pr takes the PR's full https URL" ;; esac
  fi
  write_json "$file" --arg s "$value" --arg pr "$pr" --argjson sp "$set_pr" \
    '.state = $s | (if $sp == 1 then .pr = $pr else . end)'
}

cmd_profile() {
  local sub=$1 file project out
  case "$sub" in
    save)
      file=$(chain_file "$2")
      project=$(jq -r '.project' "$file")
      mkdir -p "$CHAINS/profiles"
      out="$CHAINS/profiles/$project.json"
      jq --argjson now "$(date +%s)" \
        '{project, saved_at: $now, from_chain: .chain,
          roles: [.roles[] | {role, harness, model, effort, skills}]}' "$file" >"$out.tmp.$$"
      mv "$out.tmp.$$" "$out"
      printf '%s\n' "$out"
      ;;
    show)
      project=$2
      valid_slug "$project" || die "invalid project '$project'"
      [ -f "$CHAINS/profiles/$project.json" ] || return 1
      cat "$CHAINS/profiles/$project.json"
      ;;
    *) usage ;;
  esac
}

skill_name_of() {  # <SKILL.md>
  local line name=''
  while IFS= read -r line; do
    case "$line" in
      name:*) name=${line#name:}; name=${name//[[:space:]\"\']/}; break ;;
    esac
  done <"$1"
  [ -n "$name" ] || { name=${1%/SKILL.md}; name=${name##*/}; }
  printf '%s\n' "$name"
}

cmd_skills() {
  local project_dir=$1 root skill
  [ -d "$project_dir" ] || die "no project directory '$project_dir'"
  for root in "$project_dir/.claude/skills" "$project_dir/.agents/skills" "$HOME/.claude/skills"; do
    [ -d "$root" ] || continue
    for skill in "$root"/*/SKILL.md; do
      [ -f "$skill" ] || continue
      skill_name_of "$skill"
    done
  done | LC_ALL=C sort -u
}

cmd_scope() {
  local file role project_dir task skills out name
  file=$(chain_file "$1")
  role=$2
  project_dir=$3
  require_role "$file" "$role"
  task=$(role_task "$file" "$role")
  out="$DATA/$task/skills-off"
  skills=$(jq -r --arg r "$role" '.roles[] | select(.role == $r) | .skills | if . == "all" then "all" else join("\n") end' "$file")
  if [ "$skills" = all ]; then
    rm -f "$out"
    printf 'all skills available to %s\n' "$task"
    return 0
  fi
  mkdir -p "$DATA/$task"
  {
    printf '# dnp-flow skill scope for %s; skills outside this list stay available\n' "$task"
    cmd_skills "$project_dir" | while IFS= read -r name; do
      grep -qxF -- "$name" <<<"$skills" || printf '%s\n' "$name"
    done
  } >"$out.tmp.$$"
  mv "$out.tmp.$$" "$out"
  printf '%s\n' "$out"
}

cmd_report() {
  local file chain out
  file=$(chain_file "$1")
  chain=$(jq -r '.chain' "$file")
  out="$CHAINS/$chain/report.md"
  if [ ! -e "$out" ]; then
    jq -r --argjson max "$DNP_FLOW_MAX_ROUNDS" '
      "# dnp-flow cycle report: \(.chain)", "",
      "Project: \(.project)", "",
      "Return rounds used: \(.round) of \($max)", "",
      "PR: \(if .pr == "" then "(none yet)" else .pr end)", "",
      "## Roles", "",
      "| Role | Task | Harness | Model | Effort | Skills |",
      "| --- | --- | --- | --- | --- | --- |",
      (.roles[] | "| \(.role) | \(.task) | \(.harness) | \(.model) | \(.effort) | \(if .skills == "all" then "all" else (.skills | join(", ")) end) |"),
      "", "## Handoffs", "",
      (.handoffs[] | "- \(.at | todate): \(if .from == "" then "start" else .from end) -> \(.to) (\(.kind), round \(.round))\(if .note == "" then "" else ": \(.note)" end)"),
      "", "## Per-role actions", "",
      (.roles[] | "- \(.role):"),
      "", "## Pending cosmetic findings", "",
      "- none recorded"' "$file" >"$out"
  fi
  printf '%s\n' "$out"
}

[ "$#" -gt 0 ] || usage
CMD=$1
shift
case "$CMD" in
  roles) [ "$#" -eq 0 ] || usage; cmd_roles ;;
  new) [ "$#" -ge 2 ] || usage; cmd_new "$@" ;;
  latest) [ "$#" -eq 1 ] || usage; cmd_latest "$1" ;;
  set-role) [ "$#" -ge 2 ] || usage; cmd_set_role "$@" ;;
  title) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_title "$@" ;;
  handoff) [ "$#" -ge 2 ] || usage; cmd_handoff "$@" ;;
  status) [ "$#" -le 1 ] || usage; cmd_status "$@" ;;
  state) [ "$#" -ge 2 ] || usage; cmd_state "$@" ;;
  profile) [ "$#" -eq 2 ] || usage; cmd_profile "$@" ;;
  skills) [ "$#" -eq 1 ] || usage; cmd_skills "$1" ;;
  scope) [ "$#" -eq 3 ] || usage; cmd_scope "$@" ;;
  report) [ "$#" -eq 1 ] || usage; cmd_report "$1" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
