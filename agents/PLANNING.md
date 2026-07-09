# Planning — how to produce a plan

Applies to every planning task (a plan, a design, a "how should we do X"). Keep it
cheap here; the full protocol lives in `{{CONFIG_DIR}}/PLANNER.md` — Read it when you
actually plan (it is intentionally not always-loaded so it never bloats context).

- **Extract first**: goal, requirements, constraints, answered questions, assumptions.
- **Align before writing.** If the request redefines how something fundamentally
  works, or has structural ambiguity, run structured question rounds (concrete options
  + worked examples) until the shared picture is confirmed — *then* write. A plan
  written too early anchors on the wrong model.
- **Classify.** Simple = limited scope, few steps, no architecture, low risk.
  Complex = architecture, multiple systems, migrations, production/security impact,
  unclear requirements, or significant tradeoffs.
- **Simple** → draft + self-review → present.
- **Complex** → write the draft to the plan file → hand it to an independent, read-only
  reviewer subagent (or any available read-only reviewer mechanism; pick its model per
  `MODEL_ROUTING.md`) → revise from its findings → present. This review is **mandatory**
  for complex plans.
- **Always write the plan to a file**, never only inline (the UI truncates long
  messages, so an inline-only plan may be invisible to the user).
- **Sign-off gate.** In plan mode, the built-in plan-mode sign-off *is* the gate — don't
  add a second one. Outside plan mode, present the file and wait for an explicit go; a
  design/plan sign-off is **not** an execution greenlight — confirm "execute now, or keep
  planning?" before building.
- **Full rubric, reviewer brief, and plan format** → Read `{{CONFIG_DIR}}/PLANNER.md`.
