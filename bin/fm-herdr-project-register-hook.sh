#!/usr/bin/env bash
# fm-herdr-project-register-hook.sh - eagerly create a project's Herdr
# project-tab workspace (docs/herdr-backend.md "Project grouping") at
# registration/clone time, per the project-management skill's add/create
# intake, so the workspace exists even before any worker is ever spawned
# into the project.
#
# No-ops (prints nothing, exits 0) when:
#   - the project has not opted in: bin/fm-project-mode.sh --herdr-group
#     does not print exactly "on"; or
#   - the active terminal backend (bin/fm-backend.sh's fm_backend_name) is
#     not herdr, since there is no Herdr session to create a workspace in.
#
# Scoped to the primary crew home only, same as the toggle itself
# (docs/herdr-backend.md "Project grouping"): run this only from the main
# firstmate home, never from inside a secondmate home.
#
# Retroactively creating the workspace for an already-registered project
# that later has its toggle turned on is NOT this script's job: that case
# is left to create the workspace lazily on the project's next worker
# spawn, same as it always has. Only run this hook as part of registering
# or creating a project.
#
# On success, prints the created-or-already-existing project workspace id
# and exits 0. Usage: fm-herdr-project-register-hook.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

NAME=${1:?usage: fm-herdr-project-register-hook.sh <project-name>}

GROUP=$("$SCRIPT_DIR/fm-project-mode.sh" --herdr-group "$NAME" 2>/dev/null) || GROUP=off
[ "$GROUP" = on ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
[ "$(fm_backend_name)" = herdr ] || exit 0
fm_backend_source herdr

PROJ_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/$NAME"
if [ ! -d "$PROJ_DIR" ]; then
  echo "error: $PROJ_DIR does not exist" >&2
  exit 2
fi
PROJ_ABS=$(cd "$PROJ_DIR" && pwd)

SESSION=$(fm_backend_herdr_session)
LABEL=$(fm_backend_herdr_project_workspace_label "$PROJ_ABS")
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$PROJ_ABS" launcher-home "$SESSION" "$LABEL")
CONTAINER=${CONTAINER_RAW%%$'\t'*}
printf '%s\n' "${CONTAINER#*:}"
