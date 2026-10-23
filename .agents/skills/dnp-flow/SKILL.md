---
name: dnp-flow
description: Agent-only procedure for the captain's `.init dev` development chain. Load when a captain prompt starts with `.init dev` (bare, with `status`, `stop`, or a project, as the prompt hook announces), and before acting on any status, steer, or cleanup of a task whose backlog note names a dnp-flow chain.
user-invocable: false
metadata:
  internal: true
---

# dnp-flow chain

[`docs/dnp-flow.md`](../../../docs/dnp-flow.md) owns the methodology: the roles, the handoff loop, blocking versus cosmetic findings, and the limits.
`bin/fm-dnp-flow.sh` owns the role catalog, the chain record, the return-round cap, titles, profiles, and skill scope files, and its header owns exact usage.
This skill owns the procedure firstmate follows.
Only the main firstmate home or a secondmate home runs it, never a worker, and every hard rule in `AGENTS.md` stays in force: roles are ordinary ship workers, never address the captain, and change the project only in their own isolated copies.
A lock-refused session reports the chain state read-only and starts, steers, or stops nothing.

## Entry

The prompt hook `bin/fm-dnp-init-hook.sh` announces the trigger and its arguments; treat any further lines of the prompt as the captain's request.

- `.init dev status [<project>]`: print `bin/fm-dnp-flow.sh status [<chain>]`, reconcile each role's current state with `bin/fm-crew-state.sh`, and reply in outcomes per `AGENTS.md` section 9 (active role, round, what is waiting).
- `.init dev stop [<project>]`: resolve the chain with `latest`, run `bin/fm-control.sh <role-task> interrupt` for each live role, then `state <chain> stopped`.
  Stopping never tears down a role or discards work; say which roles hold uncommitted or unlanded work.
- `.init dev <project>`: when `latest <project>` finds a chain, show its status and ask with AskUserQuestion whether to continue it, start a new chain, or cancel.
  Continuing a stopped chain records `state <chain> active`, relaunches exited roles through `bin/fm-control.sh <task> relaunch`, and re-steers the active role.
- `.init dev` with a request: resolve the project per `AGENTS.md` section 7, ask one concise question when none or several match, then start a chain.
  When an open chain already exists for that project, ask whether to continue it first.

## Starting a chain

1. Resolve the delivery mode, `yolo` posture, branch prefix, and any base branch exactly as `AGENTS.md` section 7 requires; every role uses the same values.
2. Analyze the request and the project (README, project `AGENTS.md`, stack, the surfaces the request touches) and propose roles.
   Architect, Dev, and QA are mandatory.
   Recommend DevSecOps unless the change has no security surface, DevOps when CI, build, deploy, or infrastructure changes, UX for user interface work, and Docs for user-facing documentation.
   Confirm the set with one multi-select AskUserQuestion, then run `bin/fm-dnp-flow.sh new <project> <role>...`.
3. When `profile show <project>` prints a profile, ask first whether to reuse it, showing each role's runtime, model, effort, and skills.
   Reuse applies it with `set-role` for each chain role; a role absent from the profile is asked about below.
4. Otherwise ask one AskUserQuestion per role, titled with `title <chain> <role>`, with up to three questions: model, effort, and skills.
   Offer the dispatch resolution from `AGENTS.md` section 4 as the recommended model; the captain's pick is the explicit per-task override.
   For skills, list `skills <project-dir>` and offer all skills (recommended), a role-relevant subset you name, or none of the listed skills, with free text for a custom list.
   Say in the question that only Claude workers enforce the skill choice.
   Record each answer with `set-role`, then run `profile save <chain>`.
5. For each role, scaffold `bin/fm-brief.sh <chain>-<role> <repo> --mode <mode>` with the resolved flags, fill the brief per `AGENTS.md` section 11 and the role spec below, and run `scope <chain> <role> <project-dir>`.
6. Add one backlog item per role with `bin/fm-tasks-axi.sh add <chain>-<role> '<title>' --kind ship --repo <project>` and a `--body` note naming the chain, its mode and `yolo` posture, and that the item is a dnp-flow chain role.
7. Spawn every role through `bin/fm-spawn.sh` with its recorded runtime, model, and effort, following `harness-adapters`, then run `title <chain> <role> --apply`.
8. Run `handoff <chain> architect` and steer the Architect with `bin/fm-send.sh` to begin.

## Role spec

Put this in each role's `## Firstmate spec`, adapted to the role.

- The worker is the named role of chain `<chain>` for `<project>`, its title is the `title` output, and the chain roles follow it in catalog order.
- It waits until a firstmate steer says it is active: until then it appends `paused [at=<epoch>]: waiting for dnp-flow handoff` and does nothing else.
- On each handoff steer it runs `git merge --ff-only <tip>` in its own copy before working, and stops with `blocked` if that cannot fast-forward.
- It commits only while active, on its own branch.
- At the end of each pass it overwrites `data/<task>/handoff.md` (under the firstmate home) with what it did, and a reviewing role adds a `Blocking` list and a `Cosmetic` list, then appends `done [at=<epoch>]: handoff ready - <one line>`.
- Blocking means a bug, a security weakness, or an unmet acceptance criterion; anything else is cosmetic and never blocks.
- The Architect writes the plan with acceptance criteria to `data/<task>/plan.md` and makes no commits; every later role reads it.
- Every role except QA never pushes, opens a PR, or runs /no-mistakes, and its brief's Definition of done section is replaced with this handoff contract while the delivery-mode line stays unchanged.
- QA keeps the generated Definition of done: its `done` is a handoff until firstmate steers it to deliver.

## Handoff loop

On a role's `done`, confirm with `status <chain>` that it is the active role, then read its `handoff.md`.

- No blocking findings: hand off forward with `handoff <chain> <next-role> --note '<summary>'` and steer the next role with the printed tip and a pointer to the plan and the previous `handoff.md`.
- Blocking findings: return with `handoff <chain> <fix-role> --return --note '<findings>'` to the role that owns the fix, Dev by default, and steer it with the blocking list.
  After its fix pass, hand straight back to the role that returned the work, except that a fix touching a security surface goes to DevSecOps first.
- Only a return issued while QA is active counts toward the cap of three rounds; a DevSecOps return to Dev, or a fix DevSecOps makes itself, consumes none.
- Exit 3 from a QA return means the cap of three QA returns is spent: do not steer anyone, file the decision as its own item with `bin/fm-tasks-axi.sh add <chain>-cap '<title>'`, hold it with `bin/fm-captain-hold.sh hold <chain>-cap --reason '<blocking findings after three QA returns>'`, and ask the captain whether QA should deliver with the findings listed in the report, the chain should stop, or a fresh chain should continue from the current tip.
  The cap is never edited or reset inside a chain.
- A role that reports `blocked` or `needs-decision` is handled exactly as for any ship task.
- Append each role's cosmetic findings and one line of its actions to the chain's report sections as they arrive (`report <chain>` creates the scaffold).

## Delivery and close

When QA passes with no blocking findings, steer QA to deliver through its Definition of done; from there `validation-supervision` and `ship-landing` apply to the QA task unchanged, including merge authority and `yolo`.
When QA reports its PR, register that same PR on every earlier role with `bin/fm-pr-check.sh <role-task> <url>`, because each earlier tip is an ancestor of the delivered branch; a refusal is reported, never bypassed.
Clean up each role only through `ship-landing` after landing is confirmed; a cleanup refusal for unlanded work stops for the captain, and a `local-only` chain's earlier roles may need that call.
Then run `state <chain> closed --pr <url>`, finish `report.md` (roles, rounds, per-role actions, pending cosmetic findings, PR), and relay its substance to the captain with the PR's full URL.
