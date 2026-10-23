# dnp-flow development chain

dnp-flow is an opt-in way to run one development request through a fixed chain of role agents before it is delivered.
The captain starts it by typing `.init dev` in a Firstmate session; without that command Firstmate behaves exactly as before.
The [`dnp-flow` skill](../.agents/skills/dnp-flow/SKILL.md) owns the procedure Firstmate follows, and [`bin/fm-dnp-flow.sh`](../bin/fm-dnp-flow.sh) owns the role catalog, records, and mechanics.

## Commands

- `.init dev` followed by the request (on the same line or the next lines) starts a chain for the project the request names or implies.
- `.init dev <project>` opens that project's latest open chain and asks whether to continue it, start a new one, or cancel.
- `.init dev status [<project>]` reports the active role, the return round, and what each role is waiting on.
- `.init dev stop [<project>]` interrupts every role of the chain and marks it stopped; nothing is cleaned up or discarded, and `.init dev <project>` resumes it.

The project's tracked `.claude/settings.json` registers a `UserPromptSubmit` hook, [`bin/fm-dnp-init-hook.sh`](../bin/fm-dnp-init-hook.sh), so any Claude Code session opened in a Firstmate home recognizes the command.
The hook only adds context telling Firstmate to load the skill; every other prompt passes through untouched.
Other primary runtimes have no such hook, so there Firstmate recognizes `.init dev` from the skill's description alone.

## Roles

Each role is a separate worker with its own isolated copy, branch, and terminal pane, titled `[<Role>] <color> <icon> [<project>]`.
Colors are emoji because no supported terminal backend exposes a per-pane color; Herdr and tmux show the title on the pane, and other backends keep their ordinary labels.

| Role | Title | Responsibility |
| --- | --- | --- |
| Architect | 🔵 📐 | Writes the plan with acceptance criteria; makes no commits. |
| Dev | 🟢 💻 | Implements the plan and fixes returned findings. |
| UX | 🟠 🎨 | Optional: user interface and interaction work. |
| DevSecOps | 🔴 🛡️ | Reviews and hardens the security surface; fixes what it finds. |
| DevOps | 🟣 ⚙️ | Optional: CI, build, deploy, and infrastructure changes. |
| Docs | ⚪ 📝 | Optional: user-facing documentation. |
| QA | 🟡 🧪 | Verifies the acceptance criteria and delivers the result. |

Architect, Dev, and QA are always present, and the chain always runs in the table's order.
Firstmate proposes the role set from the request and the project, and the captain confirms it.
For each role the captain then picks the model, the effort, and the skills the role may load.
Those choices are saved as the project's profile and offered first the next time a chain starts for that project.

## Handoff loop

Only one role is active at a time.
Each role starts from the previous role's work by fast-forwarding to its branch, so the chain's history stays linear.
At the end of a pass, the role writes a handoff note, and Firstmate hands the work to the next role.

A reviewing role sends the work back only for a blocking finding: a bug, a security weakness, or an unmet acceptance criterion.
Everything else is cosmetic, never blocks, and is listed in the final report.
The chain should converge, not polish forever.
The work goes back to the role that owns the fix, normally Dev, and returns directly to the reviewer that found the problem; a fix that touches a security surface passes DevSecOps first.

A chain allows at most three returns.
When a fourth would be needed, Firstmate stops the chain and asks the captain whether QA should deliver with the findings listed, the chain should stop, or a fresh chain should continue from the current work.

## Delivery

When QA passes with no blocking findings, QA delivers through the project's ordinary delivery mode, for example the no-mistakes pipeline and a PR.
Merge authority does not change: the captain still approves every merge unless the project's standing posture already lets Firstmate merge green work.
The earlier roles' work is part of the delivered branch, and each role is cleaned up only after the delivered work has landed.

The chain's serial role reviews are the one sanctioned exception to Firstmate's rule against stacking serial manual reviews, and they apply only to a chain the captain started.
They come before delivery and never replace the delivery mode's own review, tests, or CI.

## Report

Every chain ends with a report in the home's private `data/dnp-chains/<chain>/report.md`.
It lists the roles and their models, every handoff and return round, each role's actions, the pending cosmetic findings, and the PR link.
Firstmate relays its substance to the captain together with the PR.

## Limits

- The chain runs only inside Firstmate, one worker per role, under the ordinary supervision and safety rules.
- Skill choices are enforced only for Claude Code workers, through the launch's `skillOverrides` setting written from `data/<task>/skills-off` (see the "Worker skill scope" section of the [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) header).
  Other runtimes receive the choice as instructions only.
- The skill list covers the project's `.claude/skills` and `.agents/skills` and the user's `~/.claude/skills`.
  Plugin and built-in skills are never hidden.
- Pane titles are applied on Herdr and tmux only.
- A `local-only` project may need the captain's call before the earlier roles can be cleaned up, because their branches never reach a remote.
