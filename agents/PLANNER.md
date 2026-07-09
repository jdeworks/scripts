# Planning Protocol

Full protocol for planning tasks. `PLANNING.md` (always loaded) is the trigger;
this file is the detail — Read it when you actually plan. Model choices are
delegated entirely to `MODEL_ROUTING.md`; no model is named here on purpose.

## Purpose

Produce execution-ready plans that match user intent and are validated before any
execution begins.

## Before planning

Extract and make explicit:

- **Goal** — the outcome the user actually wants.
- **Requirements** — what must be satisfied.
- **Constraints** — limits, non-negotiables, environment.
- **Answered questions** — what has already been decided in the conversation.
- **Assumptions** — what you are taking as true but haven't confirmed.

## Align first (before writing)

When the request redefines how something fundamentally works, or contains
structural ambiguity, do **not** write the plan yet. Iterate with the user using
structured questions — concrete options plus worked examples — until every structural
ambiguity is resolved and the shared picture is confirmed. A plan written too early
anchors everyone on the wrong model. Only polish/UX-level requests skip this.

## Complexity rubric

**Simple** — limited scope, few steps, no architectural decisions, no significant
risk.

**Complex** — any of: architecture decisions, multiple systems, migrations,
production impact, security considerations, unclear requirements, or significant
tradeoffs.

## Simple path

Draft the plan → self-review it against the goal and requirements → present.

## Complex path

1. Write the draft plan to the plan file.
2. Spawn an independent, read-only reviewer subagent (on hosts without a dedicated
   one, any available read-only reviewer-subagent mechanism). Pick its model per
   `MODEL_ROUTING.md` for the task's complexity.
3. It **reads the draft plan file** and returns its critique as text — it never
   writes, so the review is safe even inside plan mode / any read-only guard. Hand
   it in the prompt: the original request, relevant conversation context, and the
   requirements.
4. Revise the plan from its findings. Remove assumptions that turned out
   unnecessary; add missing steps. Ask the user only when information is genuinely
   required to proceed.

### Reviewer brief

The reviewer must **not** assume the plan is correct. It compares the plan against
the original request and reports gaps across:

- **Requirements** — covered / missing / partially addressed.
- **Assumptions** — hidden / risky / needing confirmation.
- **Execution** — missing steps, wrong order, unclear actions, missing validation.
- **Risks** — technical / operational / security / rollback.

## Plan file format

Every complex plan contains, in order:

- **Goal** — the desired outcome.
- **Requirements** — what must be satisfied.
- **Assumptions** — known assumptions.
- **Plan** — ordered execution steps; each step states its *action*, *purpose*, and
  *expected result*.
- **Validation** — how success is verified (run the code, tests, checks).
- **Risks** — potential problems and their mitigations.
- **Open Questions** — blocking questions only.

## Approval & execution gates

- Write the plan to a file; never rely on an inline-only plan (the UI truncates long
  messages, so the user may not see it).
- **In plan mode**, the built-in plan-mode sign-off (e.g. ExitPlanMode) is the approval
  gate. The reviewer step runs *before* it; do not add a second manual gate.
- **Outside plan mode**, present the file and wait for an explicit go. A design/plan
  sign-off is **not** an execution greenlight — confirm "execute now, or keep
  planning?" before implementing.
- The strong model plans; a lighter model implements from the approved plan (per
  `MODEL_ROUTING.md`) to save cost.
