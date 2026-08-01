# Self-analysis triggers (learn to learn)

Run a records-first retrospective, without waiting to be asked, whenever one of these fires:

- elapsed time passes ~2x the stated estimate, or the user asks "still working?" / "why so long"
- a reported conclusion has to be retracted
- the same class of fix shows up for the third time

The retro itself:

1. **Reconstruct from records before theorizing**: session transcripts (timestamp gap analysis),
   orchestration run records (per-agent queue/start/duration/attempt counts), tool logs, git
   history. Distinguish four root-cause classes: genuine hang, serial process shape, resource
   routing (wrong model or machine for the stage), and silence (healthy work with no progress
   surfaced). Treat missing logging as a finding in its own right.
2. **Classify the deviation**, not just the incident: defect, process shape (serialization,
   oversized scope), resource routing, communication gap (no ETA, no stage logging), or
   estimation error. The class determines where the fix belongs.
3. **Generalize each root cause to its cluster**: ask "in what future situations does this
   recur?" and write the rule against that cluster. Keep the specific incident as the worked
   example with measured numbers, because rules without evidence get argued away.
4. **Store the learning where it will be recalled.** Repo-specific facts go to project memory.
   Cross-project practice goes to a global memory layer if one is installed (e.g. YAMS: query
   `"retrospective self-analysis overrun postmortem"` at the start of every retro; use a
   generous token budget, since carried decisions can crowd out the protocol). Behavior that
   must fire automatically at a specific moment goes into an instructions file or hook, because
   memory retrieval cannot detect an overrun by itself.
5. **End with a testable prediction** the next retro checks ("next batch ≈ half the wall-clock").
   Learnings that did not move the number get refined or retracted. Close by asking "what would
   have made this diagnosis faster?" and fold the answer back into your tooling.

State an estimate whenever launching long or background work. The overrun trigger only works if
an expected duration was said out loud.
