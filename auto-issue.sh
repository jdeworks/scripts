#!/usr/bin/env bash
#
# auto-issue.sh — drive Claude Code tasks from GitHub issues.
#
# Poll a GitHub repo for issues carrying a trigger label, propose a work plan
# with `claude -p`, and once you approve it (via a label) build the change,
# open a PR, merge it, and close the issue. State lives in GitHub labels so it
# works from anywhere you have GitHub access.
#
# Run `auto-issue` (no args) inside any GitHub folder for the interactive
# launcher. See README.md for the full guide.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve our own location (used for the systemd unit's ExecStart).
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Configuration (all overridable via env or ~/.auto-issue.env).
# ---------------------------------------------------------------------------
ENV_FILE="${AUTO_ISSUE_ENV_FILE:-$HOME/.auto-issue.env}"

# Load the env file early so the values below can come from it.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Trigger: only issues with this label are processed. Empty => all open issues.
BOT_LABEL="${BOT_LABEL-bot}"

# State labels (the workflow state machine).
LABEL_PLAN="${LABEL_PLAN:-plan-proposed}"
LABEL_APPROVED="${LABEL_APPROVED:-approved}"
LABEL_HALTED="${LABEL_HALTED:-halted}"
LABEL_DONE="${LABEL_DONE:-done}"

# Model selection. Default model for all work; if an issue carries
# MODEL_OPUS_LABEL, that issue uses MODEL_OPUS instead.
MODEL_DEFAULT="${MODEL_DEFAULT:-sonnet}"
MODEL_OPUS="${MODEL_OPUS:-opus}"
MODEL_OPUS_LABEL="${MODEL_OPUS_LABEL:-opus}"

# Loop pacing.
INTERVAL="${INTERVAL:-5}"          # minutes between polls
MAX_PER_CYCLE="${MAX_PER_CYCLE:-10}" # max Claude actions per cycle
COOLDOWN="${COOLDOWN:-20}"         # seconds between Claude invocations
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-40}"

# Git / PR behaviour.
WORK_BRANCH_PREFIX="${WORK_BRANCH_PREFIX:-auto-issue/}"
MERGE_METHOD="${MERGE_METHOD:-squash}" # squash | merge | rebase
TARGET_BRANCH="${TARGET_BRANCH:-}"     # empty => repo default branch

# Behaviour switches.
DRY_RUN="${DRY_RUN:-0}"            # 1 => log actions, never spawn Claude or mutate

# Marker that tags every comment we author, so we can tell our own comments
# apart from human instructions regardless of which account posts them.
BOT_MARKER="<!-- auto-issue-bot -->"

# Populated at runtime.
REPO=""              # owner/name
DEFAULT_BRANCH=""
REPO_ROOT=""
STATE_DIR=""

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------
c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_cyn=$'\e[36m'

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s %s\n' "$(_ts)" "$*"; }
info() { printf '%s %sℹ%s  %s\n' "$(_ts)" "$c_cyn" "$c_reset" "$*"; }
ok()   { printf '%s %s✓%s  %s\n' "$(_ts)" "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s %s!%s  %s\n' "$(_ts)" "$c_ylw" "$c_reset" "$*" >&2; }
err()  { printf '%s %s✗%s  %s\n' "$(_ts)" "$c_red" "$c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Repo detection & GitHub plumbing.
# ---------------------------------------------------------------------------

# Make every gh call use the write-capable token, if provided.
setup_gh_auth() {
  if [[ -n "${AUTO_ISSUE_GH_TOKEN:-}" ]]; then
    export GH_TOKEN="$AUTO_ISSUE_GH_TOKEN"
  fi
}

# Confirm we are inside a git repo that gh recognises as a GitHub repo.
# Sets REPO, DEFAULT_BRANCH, REPO_ROOT. Returns non-zero otherwise.
detect_repo() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  local json
  json="$(gh repo view --json nameWithOwner,defaultBranchRef 2>/dev/null)" || return 1
  REPO="$(jq -r '.nameWithOwner // empty' <<<"$json")"
  DEFAULT_BRANCH="$(jq -r '.defaultBranchRef.name // empty' <<<"$json")"
  [[ -n "$REPO" ]] || return 1
  [[ -n "$TARGET_BRANCH" ]] || TARGET_BRANCH="$DEFAULT_BRANCH"
  STATE_DIR="$REPO_ROOT/.auto-issue"
  return 0
}

require_repo() {
  setup_gh_auth
  detect_repo || die "Not a GitHub repository (gh can't resolve a repo here). Nothing to do."
}

# Confirm the active token can actually write (push/triage).
token_can_write() {
  local perms
  perms="$(gh api "repos/$REPO" -q '.permissions.push' 2>/dev/null)"
  [[ "$perms" == "true" ]]
}

# ---------------------------------------------------------------------------
# State dir + gitignore + labels.
# ---------------------------------------------------------------------------
ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  local gi="$REPO_ROOT/.gitignore"
  if [[ ! -f "$gi" ]] || ! grep -qxF '.auto-issue/' "$gi" 2>/dev/null; then
    printf '%s\n' '.auto-issue/' >>"$gi"
    info "Added .auto-issue/ to .gitignore"
  fi
}

# label name|color|description
managed_labels() {
  cat <<EOF
$LABEL_PLAN|fbca04|auto-issue: work plan proposed, awaiting your review
$LABEL_APPROVED|0e8a16|auto-issue: plan approved, build it
$LABEL_HALTED|b60205|auto-issue: stop — do not act on this issue
$LABEL_DONE|5319e7|auto-issue: completed by the bot
EOF
  if [[ -n "$BOT_LABEL" ]]; then
    echo "$BOT_LABEL|1d76db|auto-issue: trigger label for the bot"
  fi
  echo "$MODEL_OPUS_LABEL|6f42c1|auto-issue: use the Opus model for this issue"
}

ensure_labels() {
  local line name color desc
  while IFS='|' read -r name color desc; do
    [[ -n "$name" ]] || continue
    gh label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1 \
      && info "label ok: $name" || warn "could not ensure label: $name"
  done < <(managed_labels)
}

# ---------------------------------------------------------------------------
# Claude prompts (edit these to tune behaviour).
# ---------------------------------------------------------------------------
plan_prompt() {
  local title="$1" body="$2"
  cat <<EOF
You are an autonomous senior engineer planning work for a GitHub issue in this
repository. Read the issue, explore the codebase as needed, and produce a
CONCRETE work plan. Do NOT write or change any code yet.

The plan must include:
- Goal: one-sentence restatement of what the issue asks for.
- Approach: the implementation strategy.
- Steps: an ordered, specific checklist (files to touch, functions, commands).
- Tests/verification: how correctness will be confirmed.
- Risks / open questions: anything ambiguous or potentially breaking.

Keep it concise and skimmable. Output ONLY the plan in GitHub-flavored markdown.

If this issue is ALREADY RESOLVED, a clear DUPLICATE, genuinely NOT NEEDED,
completely OUT OF SCOPE for this repository, or otherwise not actionable by an
engineer, do NOT produce a work plan. Instead, output a single line:
REJECT: <concise reason (≤ 120 chars)>
Keep the bar HIGH — reject only when clearly warranted.

--- ISSUE: ${title} ---
${body}
EOF
}

rework_prompt() {
  local title="$1" body="$2" prev_plan="$3" instructions="$4"
  cat <<EOF
You are revising a previously proposed work plan for a GitHub issue based on
new reviewer feedback. Do NOT write code; output ONLY the revised plan in
GitHub-flavored markdown, in the same structure as before (Goal, Approach,
Steps, Tests/verification, Risks/open questions). Address every point of the
feedback explicitly.

--- ISSUE: ${title} ---
${body}

--- YOUR PREVIOUS PLAN ---
${prev_plan}

--- REVIEWER FEEDBACK (most recent instructions) ---
${instructions}
EOF
}

build_prompt() {
  local num="$1" title="$2" body="$3" plan="$4"
  cat <<EOF
You are an autonomous senior engineer. Implement the APPROVED plan below in this
repository. You are on a fresh branch created from the target branch.

Rules:
- Implement the change fully and correctly.
- Follow the existing code style and conventions.
- Run any obvious build/lint/test commands that exist and fix what you break.
- Commit your work with a clear message that references the issue, e.g.
  "Title of change (#${num})". You may make multiple commits.
- Do NOT push and do NOT open a pull request — the harness handles that.

--- ISSUE #${num}: ${title} ---
${body}

--- APPROVED PLAN ---
${plan}
EOF
}

# ---------------------------------------------------------------------------
# Claude invocation. Echoes the model's final text to stdout.
# ---------------------------------------------------------------------------
run_claude() {
  local model="$1" prompt="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "[dry-run] would run claude (model=$model). Prompt preview:"
    printf '%s\n' "$prompt" | head -n 6 | sed 's/^/    /' >&2
    echo "[dry-run plan placeholder]"
    return 0
  fi
  local out errfile rc
  errfile="$(mktemp)"
  out="$(printf '%s' "$prompt" | claude -p \
        --model "$model" \
        --permission-mode bypassPermissions \
        --max-turns "$CLAUDE_MAX_TURNS" \
        --output-format json 2>"$errfile")"
  rc=$?
  if (( rc != 0 )); then
    err "claude invocation failed (exit $rc): $(tr '\n' ' ' <"$errfile" | head -c 500)"
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  if [[ "$(jq -r '.is_error // false' <<<"$out" 2>/dev/null)" == "true" ]]; then
    err "claude reported an error: $(jq -r '.result // .error // "unknown"' <<<"$out")"
    return 1
  fi
  jq -r '.result // empty' <<<"$out" 2>/dev/null || printf '%s' "$out"
}

# Resolve which model an issue should use, based on its labels.
model_for_labels() {
  local labels_csv="$1"
  if grep -qiw "$MODEL_OPUS_LABEL" <<<"$labels_csv"; then
    echo "$MODEL_OPUS"
  else
    echo "$MODEL_DEFAULT"
  fi
}

# ---------------------------------------------------------------------------
# Issue helpers.
# ---------------------------------------------------------------------------
issue_has_label() { grep -qiw -- "$2" <<<"$1"; }

post_comment() {
  local num="$1" body="$2"
  local full="${BOT_MARKER}
${body}"
  if [[ "$DRY_RUN" == "1" ]]; then warn "[dry-run] would comment on #$num"; return 0; fi
  gh issue comment "$num" --body "$full" >/dev/null
}

add_label()    { [[ "$DRY_RUN" == "1" ]] && { warn "[dry-run] +label $2 on #$1"; return 0; }; gh issue edit "$1" --add-label "$2" >/dev/null; }
remove_label() { [[ "$DRY_RUN" == "1" ]] && { warn "[dry-run] -label $2 on #$1"; return 0; }; gh issue edit "$1" --remove-label "$2" >/dev/null 2>&1; }

# Most recent human (unmarked) comment newer than our last marked comment.
# Echoes the concatenated instruction text (empty if none).
new_instructions_since_plan() {
  local num="$1" json
  json="$(gh issue view "$num" --json comments 2>/dev/null)" || return 0
  jq -r --arg marker "$BOT_MARKER" '
    (.comments // []) as $c
    | ($c | map(select(.body | contains($marker))) | max_by(.createdAt) | .createdAt) as $lastbot
    | $c
    | map(select((.body | contains($marker)) | not))
    | map(select($lastbot == null or (.createdAt > $lastbot)))
    | map(.body) | join("\n\n---\n\n")
  ' <<<"$json"
}

# Latest plan we proposed (marker stripped).
last_plan_body() {
  local num="$1" json
  json="$(gh issue view "$num" --json comments 2>/dev/null)" || return 0
  jq -r --arg marker "$BOT_MARKER" '
    (.comments // []) | map(select(.body | contains($marker))) | max_by(.createdAt) | .body // ""
  ' <<<"$json" | sed "s|${BOT_MARKER}||"
}

# ---------------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------------
action_propose_plan() {
  local num="$1" title="$2" body="$3" model="$4"
  info "#$num: proposing plan (model=$model)"
  local plan
  plan="$(run_claude "$model" "$(plan_prompt "$title" "$body")")" || { warn "#$num: plan generation failed"; return 1; }
  [[ -n "$plan" ]] || { warn "#$num: empty plan, skipping"; return 1; }

  # Check for rejection sentinel (first line only, for unambiguous matching).
  local firstline
  firstline="$(head -n1 <<<"$plan")"
  if [[ "$firstline" == REJECT:* ]]; then
    local reason="${firstline#REJECT:}"
    reason="${reason#"${reason%%[! ]*}"}"   # ltrim whitespace
    post_comment "$num" "## 🚫 Issue not actioned

**Reason:** ${reason}

Add \`${LABEL_APPROVED}\` to override and force a work plan, or remove \`${BOT_LABEL}\` and \`${LABEL_PLAN}\` labels to fully reset."
    add_label "$num" "$LABEL_HALTED"
    ok "#$num: rejected — '$reason'; labelled '$LABEL_HALTED'"
    return 0
  fi

  post_comment "$num" "## 🤖 Proposed work plan

${plan}

---
**How to proceed:** add the \`${LABEL_APPROVED}\` label to build this, comment with changes to revise it, or add \`${LABEL_HALTED}\` to stop."
  add_label "$num" "$LABEL_PLAN"
  ok "#$num: plan posted, labelled '$LABEL_PLAN'"
}

action_rework_plan() {
  local num="$1" title="$2" body="$3" model="$4" instructions="$5"
  info "#$num: reworking plan from new feedback (model=$model)"
  local prev plan
  prev="$(last_plan_body "$num")"
  plan="$(run_claude "$model" "$(rework_prompt "$title" "$body" "$prev" "$instructions")")" || { warn "#$num: rework failed"; return 1; }
  [[ -n "$plan" ]] || { warn "#$num: empty revised plan"; return 1; }
  post_comment "$num" "## 🤖 Revised work plan

${plan}

---
**How to proceed:** add the \`${LABEL_APPROVED}\` label to build this, comment with more changes to revise again, or add \`${LABEL_HALTED}\` to stop."
  ok "#$num: revised plan posted"
}

action_build() {
  local num="$1" title="$2" body="$3" model="$4"
  info "#$num: building approved plan (model=$model)"
  local plan branch
  plan="$(last_plan_body "$num")"
  [[ -n "$plan" ]] || { warn "#$num: no plan found to build; skipping"; return 1; }
  branch="${WORK_BRANCH_PREFIX}${num}"

  if [[ "$DRY_RUN" == "1" ]]; then
    warn "[dry-run] would: branch $branch from origin/$TARGET_BRANCH, run claude build, push, PR, merge, close #$num"
    return 0
  fi

  # Fresh branch from the latest target, so re-runs never carry stale state.
  git fetch origin "$TARGET_BRANCH" >/dev/null 2>&1 || { err "#$num: git fetch failed"; return 1; }
  git checkout -B "$branch" "origin/$TARGET_BRANCH" >/dev/null 2>&1 || { err "#$num: cannot create branch $branch"; return 1; }

  local base_sha; base_sha="$(git rev-parse HEAD)"
  if ! run_claude "$model" "$(build_prompt "$num" "$title" "$body" "$plan")" >/dev/null; then
    err "#$num: build run failed; leaving branch $branch for inspection"
    git checkout "$TARGET_BRANCH" >/dev/null 2>&1
    return 1
  fi

  if [[ "$(git rev-parse HEAD)" == "$base_sha" ]]; then
    warn "#$num: Claude produced no commits; nothing to push"
    git checkout "$TARGET_BRANCH" >/dev/null 2>&1
    return 1
  fi

  git push -u origin "$branch" --force-with-lease >/dev/null 2>&1 || { err "#$num: push failed"; return 1; }

  # Reuse an existing PR for this branch if present, else create one.
  local pr_url
  pr_url="$(gh pr view "$branch" --json url -q '.url' 2>/dev/null)"
  if [[ -z "$pr_url" ]]; then
    pr_url="$(gh pr create --base "$TARGET_BRANCH" --head "$branch" \
              --title "$title (#$num)" \
              --body "Automated implementation for #$num.

Closes #$num" 2>/dev/null)" || { err "#$num: PR create failed"; return 1; }
  fi

  if gh pr merge "$branch" "--$MERGE_METHOD" --delete-branch >/dev/null 2>&1 \
     || gh pr merge "$branch" "--$MERGE_METHOD" --delete-branch --admin >/dev/null 2>&1; then
    ok "#$num: PR merged ($pr_url)"
  else
    err "#$num: merge failed; PR left open: $pr_url"
    git checkout "$TARGET_BRANCH" >/dev/null 2>&1
    return 1
  fi

  # Return to and refresh the target branch.
  git checkout "$TARGET_BRANCH" >/dev/null 2>&1
  git pull --ff-only origin "$TARGET_BRANCH" >/dev/null 2>&1

  # Finish: done label + summary + close.
  remove_label "$num" "$LABEL_APPROVED"
  remove_label "$num" "$LABEL_PLAN"
  add_label "$num" "$LABEL_DONE"
  local sha; sha="$(git rev-parse --short HEAD)"
  post_comment "$num" "## ✅ Done

Implemented and merged into \`${TARGET_BRANCH}\` (\`${sha}\`).

PR: ${pr_url}"
  gh issue close "$num" --reason completed >/dev/null 2>&1
  ok "#$num: completed and closed"
}

# ---------------------------------------------------------------------------
# One poll cycle.
# ---------------------------------------------------------------------------
run_cycle() {
  local label_args=()
  [[ -n "$BOT_LABEL" ]] && label_args=(--label "$BOT_LABEL")

  local issues
  issues="$(gh issue list --state open --limit 100 "${label_args[@]}" \
            --json number,title,body,labels 2>/dev/null)" || { warn "cycle: gh issue list failed"; return 0; }

  local count; count="$(jq 'length' <<<"$issues")"
  info "cycle: $count candidate issue(s)"

  local actions=0 i num title body labels_csv model instr
  for ((i=0; i<count; i++)); do
    (( actions >= MAX_PER_CYCLE )) && { warn "MAX_PER_CYCLE=$MAX_PER_CYCLE reached; remaining issues wait for next cycle"; break; }

    num="$(jq -r ".[$i].number" <<<"$issues")"
    title="$(jq -r ".[$i].title" <<<"$issues")"
    body="$(jq -r ".[$i].body // \"\"" <<<"$issues")"
    labels_csv="$(jq -r ".[$i].labels | map(.name) | join(\",\")" <<<"$issues")"
    model="$(model_for_labels "$labels_csv")"

    if issue_has_label "$labels_csv" "$LABEL_HALTED"; then
      info "#$num: halted — skipping"; continue
    fi
    if issue_has_label "$labels_csv" "$LABEL_DONE"; then
      continue
    fi

    local did=0
    if issue_has_label "$labels_csv" "$LABEL_APPROVED"; then
      action_build "$num" "$title" "$body" "$model" && did=1 || did=1
    elif issue_has_label "$labels_csv" "$LABEL_PLAN"; then
      instr="$(new_instructions_since_plan "$num")"
      if [[ -n "${instr// /}" ]]; then
        action_rework_plan "$num" "$title" "$body" "$model" "$instr" && did=1 || did=1
      else
        info "#$num: awaiting approval or feedback"
      fi
    else
      action_propose_plan "$num" "$title" "$body" "$model" && did=1 || did=1
    fi

    if (( did )); then
      actions=$((actions+1))
      (( actions < MAX_PER_CYCLE )) && { info "cooldown ${COOLDOWN}s"; sleep "$COOLDOWN"; }
    fi
  done

  date '+%s' >"$STATE_DIR/last-check"
  info "cycle complete: $actions action(s) taken"
}

# ---------------------------------------------------------------------------
# Loop runner (foreground; also the systemd ExecStart target).
# ---------------------------------------------------------------------------
cmd_loop() {
  require_repo
  ensure_state_dir
  ensure_labels
  info "auto-issue loop started for ${c_bold}$REPO${c_reset} — interval ${INTERVAL}m, target '$TARGET_BRANCH'"
  token_can_write || warn "active token cannot push to $REPO — builds/labels will fail. Fix AUTO_ISSUE_GH_TOKEN."
  trap 'echo; warn "stopping auto-issue loop"; exit 0' INT TERM
  while true; do
    # Per-repo lock so two runners never overlap in the same working tree.
    (
      flock -n 9 || { warn "another auto-issue runner holds the lock; skipping cycle"; exit 0; }
      run_cycle
    ) 9>"$STATE_DIR/lock"
    info "sleeping ${INTERVAL}m"
    sleep "$(( INTERVAL * 60 ))"
  done
}

cmd_once() {
  require_repo
  ensure_state_dir
  ensure_labels
  info "auto-issue single cycle for ${c_bold}$REPO${c_reset}${DRY_RUN:+ (DRY_RUN=$DRY_RUN)}"
  token_can_write || warn "active token cannot push to $REPO — builds/labels will fail."
  (
    flock -n 9 || die "another auto-issue runner holds the lock"
    run_cycle
  ) 9>"$STATE_DIR/lock"
}

# ---------------------------------------------------------------------------
# systemd user service management.
# ---------------------------------------------------------------------------
service_name() {
  local base; base="$(basename "$REPO_ROOT")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_.-' '-')"
  echo "auto-issue-${base}"
}
service_unit() { echo "$HOME/.config/systemd/user/$(service_name).service"; }

service_running() { systemctl --user is-active --quiet "$(service_name).service" 2>/dev/null; }

# systemd user services start with a minimal PATH (no ~/.local/bin, no nvm),
# so `claude` and friends aren't found at runtime. Build a PATH from the
# install-time locations of the tools we shell out to, then the system dirs.
service_path() {
  local t d p seen="" out=""
  for p in "$(command -v claude)" "$(command -v gh)" "$(command -v git)" \
           "$(command -v jq)" "$(command -v flock)" "$(command -v node)"; do
    [[ -n "$p" ]] || continue
    d="$(dirname "$p")"
    case ":$seen:" in *":$d:"*) continue ;; esac
    seen="${seen:+$seen:}$d"; out="${out:+$out:}$d"
  done
  out="${out:+$out:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  printf '%s' "$out"
}

write_unit() {
  local unit; unit="$(service_unit)"
  mkdir -p "$(dirname "$unit")"
  cat >"$unit" <<EOF
[Unit]
Description=auto-issue bot for $REPO ($REPO_ROOT)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
ExecStart=$SCRIPT_PATH loop
Restart=always
RestartSec=15
Environment=AUTO_ISSUE_ENV_FILE=$ENV_FILE
Environment=PATH=$(service_path)

[Install]
WantedBy=default.target
EOF
}

cmd_start_service() {
  require_repo
  ensure_state_dir
  local name; name="$(service_name)"
  if service_running; then
    info "replacing the running service '$name' (config refresh)"
    systemctl --user stop "$name.service" >/dev/null 2>&1
  fi
  write_unit
  systemctl --user daemon-reload
  systemctl --user enable "$name.service" >/dev/null 2>&1
  systemctl --user restart "$name.service"
  # Boot autostart needs lingering; try, but don't fail if it's not permitted.
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    loginctl enable-linger "$USER" >/dev/null 2>&1 \
      && info "enabled linger (service will start on boot)" \
      || warn "could not enable linger; service won't auto-start on boot. Run: loginctl enable-linger $USER"
  fi
  ok "service '$name' started. Logs: ${c_bold}auto-issue logs${c_reset}"
}

cmd_stop_service() {
  require_repo
  local name; name="$(service_name)"
  systemctl --user stop "$name.service" >/dev/null 2>&1 && ok "stopped $name" || warn "$name was not running"
}

cmd_disable_service() {
  require_repo
  local name unit; name="$(service_name)"; unit="$(service_unit)"
  systemctl --user stop "$name.service" >/dev/null 2>&1
  systemctl --user disable "$name.service" >/dev/null 2>&1
  rm -f "$unit"
  systemctl --user daemon-reload
  ok "removed service '$name'"
}

cmd_status_service() {
  require_repo
  systemctl --user status "$(service_name).service" --no-pager 2>&1 | head -20 || true
}

cmd_logs() {
  require_repo
  journalctl --user -u "$(service_name).service" -f --no-hostname
}

# List every auto-issue service on this machine (any repo), with its state and
# working directory. Does not require being inside a repo.
cmd_list_services() {
  local units
  units="$(systemctl --user list-unit-files 'auto-issue-*.service' --no-legend 2>/dev/null | awk '{print $1}')"
  if [[ -z "$units" ]]; then
    info "No auto-issue services installed on this machine."
    return 0
  fi
  printf '%-26s %-10s %s\n' "SERVICE" "STATE" "DIRECTORY"
  local u state dir color
  while read -r u; do
    [[ -n "$u" ]] || continue
    state="$(systemctl --user is-active "$u" 2>/dev/null)"
    dir="$(systemctl --user show "$u" -p WorkingDirectory --value 2>/dev/null)"
    case "$state" in
      active)   color="$c_grn" ;;
      failed)   color="$c_red" ;;
      *)        color="$c_dim" ;;
    esac
    printf '%-26s %s%-10s%s %s\n' "${u%.service}" "$color" "$state" "$c_reset" "$dir"
  done <<<"$units"
}

# ---------------------------------------------------------------------------
# setup: guided one-time setup so `auto-issue` works from any GitHub folder.
#   1. check dependencies   2. token + env file   3. install the command
# ---------------------------------------------------------------------------

# Prompt yes/no with a default; auto-answers the default if not interactive.
prompt_yn() {
  local q="$1" def="${2:-y}" ans
  if [[ ! -t 0 ]]; then [[ "$def" == "y" ]]; return; fi
  local hint="[Y/n]"; [[ "$def" == "n" ]] && hint="[y/N]"
  printf '%s %s ' "$q" "$hint"; read -r ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

setup_check_deps() {
  echo "${c_bold}1. Dependencies${c_reset}"
  local missing=0 tool
  for tool in git gh claude jq flock; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool found"
    else
      err "$tool NOT found"; missing=1
    fi
  done
  (( missing == 0 )) || warn "install the missing tools above before running the bot"
  echo
}

setup_token() {
  echo "${c_bold}2. GitHub token${c_reset}"
  setup_gh_auth
  # If we already have a working write token, we're done.
  if [[ -n "${AUTO_ISSUE_GH_TOKEN:-}" ]] && detect_repo && token_can_write; then
    ok "AUTO_ISSUE_GH_TOKEN works and can write to $REPO"
    echo; return
  fi
  if [[ -f "$ENV_FILE" ]] && grep -q '^AUTO_ISSUE_GH_TOKEN=' "$ENV_FILE"; then
    ok "env file already defines AUTO_ISSUE_GH_TOKEN: $ENV_FILE"
    [[ -n "$REPO" ]] && ! token_can_write && \
      warn "but it can't write to $REPO — check the token's repo scope & permissions"
    echo; return
  fi

  cat <<EOF
The bot needs a ${c_bold}fine-grained personal access token${c_reset} for the repo owner's account.

  Create one at: ${c_cyn}https://github.com/settings/personal-access-tokens/new${c_reset}
  • Resource owner : the account that owns the repo(s)
  • Repository     : the repo(s) you'll run the bot in (or "All repositories")
  • Permissions    : ${c_bold}Issues${c_reset} = Read and write
                     ${c_bold}Contents${c_reset} = Read and write
                     ${c_bold}Pull requests${c_reset} = Read and write
                     (Metadata = Read is added automatically)

EOF
  if prompt_yn "Save a token to $ENV_FILE now?" y; then
    local tok
    printf 'Paste token (input hidden): '; read -rs tok; echo
    if [[ -n "$tok" ]]; then
      ( umask 077; printf 'AUTO_ISSUE_GH_TOKEN=%s\n' "$tok" >"$ENV_FILE" )
      chmod 600 "$ENV_FILE"
      export AUTO_ISSUE_GH_TOKEN="$tok" GH_TOKEN="$tok"
      ok "wrote $ENV_FILE (chmod 600)"
      if detect_repo; then
        token_can_write && ok "verified: token can write to $REPO" \
                        || err "token still cannot write to $REPO — check scope/permissions"
      fi
    else
      warn "no token entered; skipping"
    fi
  else
    warn "skipped — create $ENV_FILE later with: AUTO_ISSUE_GH_TOKEN=github_pat_..."
  fi
  echo
}

setup_install_command() {
  echo "${c_bold}3. Install the 'auto-issue' command${c_reset}"
  local bindir="$HOME/.local/bin" link="$HOME/.local/bin/auto-issue"
  if ! prompt_yn "Install 'auto-issue' into $bindir so it runs from anywhere?" y; then
    warn "skipped — invoke it directly via $SCRIPT_PATH"
    echo; return
  fi
  mkdir -p "$bindir"
  ln -sf "$SCRIPT_PATH" "$link"
  ok "installed: $link -> $SCRIPT_PATH"
  if echo ":$PATH:" | grep -q ":$bindir:"; then
    ok "$bindir is on PATH"
  else
    warn "$bindir is not on PATH."
    if prompt_yn "Append 'export PATH=\$HOME/.local/bin:\$PATH' to ~/.bashrc?" y; then
      printf '\n# added by auto-issue setup\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.bashrc"
      ok "added to ~/.bashrc — run 'source ~/.bashrc' or open a new shell"
    fi
  fi
  echo
}

cmd_setup() {
  echo "${c_bold}── auto-issue setup ──${c_reset}"
  echo
  setup_check_deps
  setup_token
  setup_install_command
  ok "Setup complete. cd into a GitHub repo and run: ${c_bold}auto-issue${c_reset}"
}

# ---------------------------------------------------------------------------
# info: show resolved configuration (read-only).
# ---------------------------------------------------------------------------
cmd_info() {
  setup_gh_auth
  if ! detect_repo; then
    err "Not a GitHub repository here."
    return 1
  fi
  local writeable="no"; token_can_write && writeable="yes"
  local svc="not installed"; service_running && svc="running" || { [[ -f "$(service_unit)" ]] && svc="installed (stopped)"; }
  cat <<EOF
${c_bold}auto-issue configuration${c_reset}
  repo            ${c_cyn}$REPO${c_reset}
  repo root       $REPO_ROOT
  target branch   $TARGET_BRANCH  (default: $DEFAULT_BRANCH)
  trigger label   ${BOT_LABEL:-<all open issues>}
  state labels    $LABEL_PLAN → $LABEL_APPROVED / $LABEL_HALTED → $LABEL_DONE
  model           $MODEL_DEFAULT  (label '$MODEL_OPUS_LABEL' ⇒ $MODEL_OPUS)
  interval        ${INTERVAL}m,  max ${MAX_PER_CYCLE}/cycle,  cooldown ${COOLDOWN}s
  merge method    $MERGE_METHOD,  branch prefix '$WORK_BRANCH_PREFIX'
  token write?    $([[ "$writeable" == yes ]] && echo "${c_grn}yes${c_reset}" || echo "${c_red}no — fix AUTO_ISSUE_GH_TOKEN${c_reset}")
  env file        $([[ -f "$ENV_FILE" ]] && echo "$ENV_FILE" || echo "${c_ylw}missing${c_reset}")
  dry run         $DRY_RUN
  service         $svc  ($(service_name))
EOF
}

# ---------------------------------------------------------------------------
# Interactive launcher (default when run with no subcommand).
# ---------------------------------------------------------------------------
cmd_interactive() {
  setup_gh_auth
  if ! detect_repo; then
    die "This folder isn't a GitHub repository. cd into one and try again."
  fi
  echo
  cmd_info
  echo

  if ! token_can_write; then
    die "The active GitHub token cannot write to $REPO. Set AUTO_ISSUE_GH_TOKEN in $ENV_FILE and retry."
  fi

  local running_note=""
  if service_running; then
    running_note=" ${c_ylw}(a background service is already running for this repo)${c_reset}"
  fi

  echo "${c_bold}How do you want to run it?${c_reset}$running_note"
  echo "  ${c_grn}1${c_reset}) Foreground   ${c_dim}— runs here, Ctrl-C to stop. ${c_bold}Recommended for the first try.${c_reset}"
  echo "  ${c_blu}2${c_reset}) Background   ${c_dim}— systemd service, auto-restart$( [[ -n "$running_note" ]] && echo ", replaces the running one" ).${c_reset}"
  echo "  3) Cancel"
  printf 'Choice [1]: '
  local choice; read -r choice
  choice="${choice:-1}"
  case "$choice" in
    1) cmd_loop ;;
    2) cmd_start_service ;;
    *) info "cancelled"; exit 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Usage.
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${c_bold}auto-issue${c_reset} — drive Claude Code tasks from GitHub issues

USAGE
  auto-issue                 Interactive launcher (info + choose foreground/background)
  auto-issue info            Show resolved configuration (read-only)
  auto-issue once            Run a single poll cycle and exit (great for testing)
  auto-issue loop            Run the polling loop in the foreground
  auto-issue labels          Create/refresh the workflow labels in this repo

  auto-issue start           Start (or replace) the background service for this repo
  auto-issue stop            Stop the background service
  auto-issue status          Show this repo's background service status
  auto-issue list            List ALL auto-issue services on this machine (any repo)
  auto-issue logs            Follow background service logs
  auto-issue disable         Stop and remove the background service

  auto-issue setup           Install the 'auto-issue' command into ~/.local/bin

TESTING
  DRY_RUN=1 auto-issue once  Show what it would do without spawning Claude or mutating.

See README.md for configuration and the full workflow.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|run)        cmd_interactive ;;
    info)          cmd_info ;;
    once)          cmd_once ;;
    loop)          cmd_loop ;;
    labels)        require_repo; ensure_state_dir; ensure_labels ;;
    start)         cmd_start_service ;;
    stop)          cmd_stop_service ;;
    status)        cmd_status_service ;;
    list|ls|ps)    cmd_list_services ;;
    logs)          cmd_logs ;;
    disable|destroy) cmd_disable_service ;;
    setup)         cmd_setup ;;
    -h|--help|help) usage ;;
    *)             err "unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

main "$@"
