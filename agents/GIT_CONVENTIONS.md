# Git conventions

- **Branches.** My repos intentionally have no `main` branch. `dev` is the default
  and primary branch — commit and base PRs on `dev`, never create or merge to `main`.
- **Commit style.** Subject: short, imperative, ≤72 chars. Match the repo's existing
  log style — `type(scope):` conventional prefixes where the repo already uses them,
  version-stamped subjects (`tool vX.Y.Z: …`) in repos that release that way, plain
  imperative otherwise. For non-trivial changes the body states what changed and why.
- **Hooks & local CI.** If the repo has pre-commit hooks, lint, tests, or a local CI
  entry point (`make verify`, `pre-commit`, …), run it before committing. Never
  bypass with `--no-verify` or by disabling hooks — fix the failure instead.
- **Release versions.** From 2026-08-01 onward, preserve coherent release cycles with
  annotated SemVer tags (`vX.Y.Z`). Inspect existing tags and the repo's package or
  manifest version before choosing the next version. Tag only a clean, pushed commit
  after the required local checks and CI pass. Keep the manifest version aligned. Push
  the tag, then verify its remote target. Tags are historical markers unless a repo
  explicitly configures them as deployment triggers. Patch versions mark compatible
  fixes. Minor versions mark feature milestones. Major versions mark incompatible
  releases.
- **History hygiene.** Never force-push `dev` or rewrite pushed history — fix
  forward with new commits; don't amend already-pushed commits. Prefer small,
  focused commits over one megacommit.
