# Model routing — which model for which task

When picking the model for any delegated / agent work (a subagent, a watchable
worker, a `--model` choice), decide per this rulebook. Default `sonnet`; step up
or down on purpose. Output costs ~5× input on every tier and the quality gap
between tiers is small on easy work but widens as work gets longer/harder — match
the tier to the job rather than over-buying.

- **`haiku`** — mechanical work, no real reasoning: renames, formatting,
  docstrings, extraction, boilerplate; style/lint review; find / list / triage /
  dedup; parse / clean for data. Also the trivial slices when you split a big job.
- **`sonnet`** (default) — implementing from a clear plan/spec, small–medium
  planning, debugging with a clear repro, code review, and research /
  data-analysis / web-gathering synthesis. When unsure, this.
- **`opus`** — reasoning-heavy or ambiguous work: big-project planning &
  architecture, multi-file refactors / migrations, black-box / outage debugging
  (or a clear-repro that turns elusive), dense multi-source synthesis, multi-step
  or financial analysis.
- **`fable`** — only long-horizon or frontier-hard jobs that would strain `opus`:
  very large cross-cutting migrations, true forensic debugging, multi-session
  frontier builds. It's 2× `opus` — make it earn that.
- **Never `fable`** for security / bio / chem / frontier-AI work (its safety
  classifiers refuse or reroute) — use `opus`/`sonnet`.
