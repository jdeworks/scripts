# scripts

A grab-bag of standalone scripts I reach for now and then.

## Contents

### [`scan-for-package.sh`](./scan-for-package.sh)

Hunts the filesystem for evidence of one or more npm / pip packages — installed dirs, manifests, lockfiles, global / site-packages. Built for chasing compromised or typosquatted dependencies: paste in an advisory and it tells you exactly which machines (and which versions) are affected.

**v2 highlights over the old version:**

- **Multi-package** — scan for several packages in one filesystem walk.
- **Advisory paste mode** — paste a raw security advisory and the parser extracts the package names and version ranges automatically.
- **Per-hit verdicts** — every hit is classified as `VULN`, `OK`, `UNKNOWN`, or `INFO` (discovery), not just flagged as "found".
- **AND-range support** — advisories like `>=8.0.0 <=8.0.1` (space-separated = AND) are parsed correctly alongside OR-alternatives.
- **All three spec syntaxes** accepted — advisory-style (`name: <=7.5.5 and >=8.0.0 <=8.0.1`), npm semver (`pkg@<7.5.6 || >=8.0.0 <8.0.2`), and pip/PEP 440 (`pkg>=4.21.0,!=4.24.1,<5.0`).
- **Registry fix-version lookup** — after a VULN hit, queries npm / PyPI for the first safe release so you know what to upgrade to.
- **Export** — `--export-dir` writes a findings report and a best-effort update script without any interactive prompts.
- **False-positive reduction** — structurally-anchored manifest matching avoids mis-hits on repo URLs, maintainer emails, and scoped helper packages.

**v2.1 additions:**

- **Transitive python deps via resolution** — a plain `requirements.txt` only lists top-level packages, so vulnerable transitive deps are invisible in it. When `uv` (preferred, fast) or `pip-compile` is installed, each requirements file is resolved to its full pinned dependency tree and that tree is scanned too. Hits found only there are marked **`resolved transitive`**: a fresh `pip install -r` *would* pull that version (actually-installed state is covered by the site-packages / pip scans). Files that fail to resolve are flagged so nothing is silently skipped; already-`pip-compile`d lockfiles are detected and not re-resolved. If neither tool is installed, the scan warns up front and recommends installing one. Disable with `--no-pip-compile`; `--no-registry` (offline) also skips it.
- **Guided setup** — running the script bare walks you through every setting interactively (ecosystems, search root, registry lookup, requirements resolution). Any flag you pass pins that setting and skips its prompt; `-y` or non-TTY runs take the defaults silently.

**v2.2 additions:**

- **Per-file Python version for uv resolution** — `--resolve-python auto` chooses a best-effort Python version per requirements file from nearby `.python-version`, `runtime.txt`, Dockerfile, pyproject/Pipfile/setup, tox, or CI metadata. Use `--resolve-python ambient` to keep uv's global default or `--resolve-python X.Y` to force a version.

Usage:

```
./scan-for-package.sh [options] 'NAME[:VERSION_EXPR]' [...] [SEARCH_ROOT]
./scan-for-package.sh --paste          # paste advisory lines interactively
printf '...\n' | ./scan-for-package.sh --paste   # pipe advisory from stdin
./scan-for-package.sh                  # interactive prompts
```

Common options: `-m npm|python|both`, `-r ROOT`, `-y` (skip confirmation + guided setup), `--no-registry`, `--no-pip-compile`, `--resolve-python auto|ambient|X.Y`, `--export-dir DIR`.

Exit codes: `0` = nothing found or everything OK · `3` = VULN or INFO hits present · `4` = no VULN but UNKNOWN hits need manual review.

Optional tools (scan degrades gracefully without them): `python3` / `jq` for precise JSON parsing, `npm` for `npm ls` + global-root discovery, `curl` for the registry fix-version lookup, `uv` / `pip-compile` for resolving requirements files to full dependency trees (transitive deps).

### [`auto-issue.sh`](./auto-issue.sh)

Drives Claude Code tasks from GitHub issues, so you can hand off work from anywhere you have GitHub access (e.g. your phone). It polls a repo for issues carrying a trigger label, proposes a work plan with `claude -p`, and — once you approve it via a label — builds the change, opens a PR, merges it into the target branch, and closes the issue.

All workflow state lives in **GitHub labels**, so it survives restarts and works no matter which machine the bot runs on.

#### How it works

1. You open an issue (from anywhere) and give it the **`bot`** label.
2. On its next poll the bot reads the issue and posts a **proposed work plan** as a comment, then labels the issue `plan-proposed`.
3. You review the plan and choose:
   - **Approve** → add the **`approved`** label. The bot builds the change on a branch, pushes, opens a PR, merges it into the target branch (`dev` by default), then comments a summary, labels `done`, and closes the issue.
   - **Request changes** → just comment your feedback. The bot reworks the plan (any comment of yours newer than its last plan counts as instructions) and posts a revised one.
   - **Stop** → add the **`halted`** label. The bot leaves the issue alone.
4. Add the **`opus`** label to an issue to build it with Opus instead of the default Sonnet.

The bot tags every comment it writes with a hidden marker, so it always distinguishes its own messages from your instructions regardless of which account posts them.

#### One-time setup

```bash
./auto-issue.sh setup
```

The guided wizard:

- checks dependencies (`git`, `gh`, `claude`, `jq`, `flock`),
- walks you through creating a **fine-grained GitHub PAT** for the repo owner's account, with **Issues / Contents / Pull requests = Read and write** (Metadata read is automatic), and offers to save it to `~/.auto-issue.env` (`chmod 600`),
- installs the `auto-issue` command into `~/.local/bin` so it runs from any GitHub folder,
- offers to register the current repo in the global registry (`~/.auto-issue/repos`).

> **Token vs. git:** `gh` (issues, labels, PRs) authenticates with `AUTO_ISSUE_GH_TOKEN`; `git push` uses your normal SSH/credentials. The PAT must be scoped to the **repo owner's** account — an outside collaborator token only has read access and the bot's writes will fail. Verify with:
> ```bash
> GH_TOKEN="$AUTO_ISSUE_GH_TOKEN" gh api repos/OWNER/REPO -q '.permissions.push'   # want: true
> ```

#### Running it

A single global daemon monitors all repos you register. Start by registering at least one:

```bash
auto-issue register              # register the current directory's repo
auto-issue register /path/to/repo  # register a specific path
auto-issue unregister            # unregister the current repo
auto-issue repos                 # list registered repos and service state
```

Then run the bot:

```bash
auto-issue            # interactive: shows config, then choose foreground or background
auto-issue info       # show resolved configuration and registered repos (read-only)
auto-issue once       # run a single poll cycle across all registered repos and exit
auto-issue loop       # run the polling loop in the foreground (Ctrl-C to stop)
auto-issue list       # show service state and all registered repos
auto-issue labels     # create/refresh workflow labels in the current repo
```

Running `auto-issue` with no arguments prints the current configuration and asks how to run. If no repos are registered yet and you're inside a GitHub repo, it offers to register it on the spot:

- **Foreground** — runs in your terminal; recommended for the first try.
- **Background** — installs a single global systemd **user service** named `auto-issue` that monitors all registered repos. If the service is already running it's replaced (handy for config changes). Boot autostart needs lingering, which setup enables when possible.

> **Note:** `once`, `loop`, and the interactive no-arg flow all require at least one registered repo. Run `auto-issue register` first.

#### Background service management

```bash
auto-issue start      # start (or replace) the global background service
auto-issue status     # service status
auto-issue logs       # follow the service logs
auto-issue stop       # stop the service
auto-issue disable    # stop and remove the service entirely
```

One service (`auto-issue.service`) covers all registered repos. To enable start-on-boot manually (if the bot couldn't): `loginctl enable-linger "$USER"`.

#### Testing

```bash
DRY_RUN=1 auto-issue once   # log every action without spawning Claude or mutating anything
```

`DRY_RUN=1` lists exactly which plans it would write, which labels it would change, and which builds it would run — safe to run against a live repo. Requires at least one registered repo (`auto-issue register` first).

#### Configuration

Set in `~/.auto-issue.env` or the environment. Defaults in **bold**.

| Variable | Default | Meaning |
|---|---|---|
| `AUTO_ISSUE_GH_TOKEN` | — | **Required.** Write-capable PAT for `gh`. |
| `BOT_LABEL` | **`bot`** | Trigger label. Empty string = process *all* open issues. |
| `INTERVAL_MIN` | **`1`** | Minimum minutes between polls — used after the bot does work. |
| `INTERVAL_MAX` | **`20`** | Maximum backoff ceiling (minutes) during idle periods. |
| `BACKOFF_FACTOR` | **`2`** | Multiply the sleep interval by this factor each idle round. |
| `MAX_PER_CYCLE` | **`10`** | Max Claude actions per cycle (the rest wait for the next poll). |
| `COOLDOWN` | **`20`** | Seconds between Claude invocations (rate-limit friendliness). |
| `MODEL_DEFAULT` | **`sonnet`** | Model for plan/build. |
| `MODEL_OPUS` / `MODEL_OPUS_LABEL` | **`opus`** / **`opus`** | Issues with this label use this model. |
| `TARGET_BRANCH` | repo default (**`dev`** here) | Base branch for PRs. |
| `MERGE_METHOD` | **`squash`** | `squash` \| `merge` \| `rebase`. |
| `WORK_BRANCH_PREFIX` | **`auto-issue/`** | Per-issue build branch prefix. |
| `LABEL_PLAN` / `LABEL_APPROVED` / `LABEL_HALTED` / `LABEL_DONE` | **`plan-proposed`** / **`approved`** / **`halted`** / **`done`** | State labels. |
| `CLAUDE_MAX_TURNS` | **`40`** | Max turns per Claude run. |
| `DRY_RUN` | **`0`** | `1` = simulate, never spawn Claude or mutate. |

The bot uses an **adaptive polling interval**: it first issues a cheap GitHub API probe (`since=<last-check>`) to see if any issues changed. If nothing changed it backs off exponentially (up to `INTERVAL_MAX` minutes); as soon as work is detected or done the sleep resets to `INTERVAL_MIN`. State (last-check timestamp, per-repo action counts) lives in `~/.auto-issue/state/`. Claude runs unattended with `--permission-mode bypassPermissions`; only point it at repos you trust it to modify.

## Archive

Older scripts kept for reference. Not actively maintained.

| Script | Notes |
|---|---|
| [`archive/scan-for-package_v1.sh`](./archive/scan-for-package_v1.sh) | Original single-package scanner (v1.0.0). Superseded by the v2 rewrite above. |
