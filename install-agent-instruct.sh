#!/usr/bin/env bash
#
# install-agent-instruct.sh — distribute reusable "agent instruction" snippets
# into whatever coding agents are installed on this machine.
#
# The snippets live in ./agents/*.md and are catalogued in ./agents/manifest.tsv.
# This script detects the agents present (Claude Code, Codex, opencode, …) and
# wires a chosen instruction into each one's *global* instructions file using
# that tool's native mechanism:
#
#   * Claude Code — copies the snippet into ~/.claude/ and adds an `@file` import
#                   to ~/.claude/CLAUDE.md.
#   * Codex / opencode — inlines the snippet into the tool's global AGENTS.md.
#
# A manifest row may also list companion files in an `extras` column. Those are
# copied into each agent's config dir as on-demand files — never imported or
# inlined — so a snippet can keep a large "full protocol" out of the always-loaded
# context and Read it only when needed (e.g. PLANNING.md + its PLANNER.md). A
# snippet references a companion via the {{CONFIG_DIR}} token, which the installer
# renders to that agent's absolute config dir at install time (tilde/relative
# refs are unreliable across tools; an absolute path always resolves).
#
# Cursor has no global instructions *file* (its User Rules live in-app); use
# `--cursor-project <dir>` to install into a repo's .cursor/rules/ instead.
#
# Idempotency is a plain string-presence check — no wrapper markers. An
# instruction counts as installed if its addition (a `@NAME.md` import line for
# Claude, or the snippet's rendered content for Codex/opencode) is already in
# the file, so it is never duplicated: not on a re-run, and not when the same
# line is already present by other means (e.g. a CLAUDE.md that already imports
# it). A target that is a symlink (e.g. one your dotfiles manage) is left as-is
# for whole-file copies, never written through.

set -uEo pipefail

VERSION="1.1.0"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
AGENTS_DIR="$SCRIPT_DIR/agents"
MANIFEST="$AGENTS_DIR/manifest.tsv"

XDG="${XDG_CONFIG_HOME:-$HOME/.config}"

# Scratch dir for rendered snippets (token substitution). One per run, cleaned up
# on exit. Rendered files must live here (not captured from a subshell) so the
# trap always sees them.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
  c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'
else
  c_reset=''; c_bold=''; c_dim=''
  c_red=''; c_grn=''; c_ylw=''; c_cyn=''
fi

info() { printf '%sℹ%s  %s\n' "$c_cyn" "$c_reset" "$*"; }
ok()   { printf '%s✓%s  %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s!%s  %s\n' "$c_ylw" "$c_reset" "$*" >&2; }
err()  { printf '%s✗%s  %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Render a path with $HOME collapsed to ~ for tidy output.
prettypath() { printf '%s' "${1/#$HOME/\~}"; }

# ---------------------------------------------------------------------------
# Agent registry — the single place to add or adjust a supported tool.
#   AG_CMD:       command probed with `command -v`
#   AG_DIR:       config dir whose existence also counts as "present"
#   AG_ROOT:      global instructions file to wire the import/inline block into
#   AG_STYLE:     import | inline | none
#   AG_IMPORTDIR: where to copy the snippet file (import style only)
#   AG_NOTE:      reason shown when style is none
#   AG_LABEL:     human-friendly name
# ---------------------------------------------------------------------------
AGENT_ORDER=(claude codex opencode cursor)
declare -A AG_CMD AG_DIR AG_ROOT AG_STYLE AG_IMPORTDIR AG_NOTE AG_LABEL

AG_LABEL[claude]="Claude Code"
AG_CMD[claude]="claude";   AG_DIR[claude]="$HOME/.claude"
AG_ROOT[claude]="$HOME/.claude/CLAUDE.md"
AG_STYLE[claude]="import";  AG_IMPORTDIR[claude]="$HOME/.claude"

AG_LABEL[codex]="Codex"
AG_CMD[codex]="codex";     AG_DIR[codex]="$HOME/.codex"
AG_ROOT[codex]="$HOME/.codex/AGENTS.md"
AG_STYLE[codex]="inline"

AG_LABEL[opencode]="opencode"
AG_CMD[opencode]="opencode"; AG_DIR[opencode]="$XDG/opencode"
AG_ROOT[opencode]="$XDG/opencode/AGENTS.md"
AG_STYLE[opencode]="inline"

AG_LABEL[cursor]="Cursor"
AG_CMD[cursor]="cursor";   AG_DIR[cursor]="$HOME/.cursor"
AG_STYLE[cursor]="none"
AG_NOTE[cursor]="User Rules live in-app; use --cursor-project for a repo's .cursor/rules"

agent_known() { [[ -n "${AG_STYLE[$1]:-}" ]]; }

# Present = command on PATH OR its config dir exists.
agent_present() {
  local a="$1"
  [[ -n "${AG_CMD[$a]:-}" ]] && command -v "${AG_CMD[$a]}" >/dev/null 2>&1 && return 0
  [[ -n "${AG_DIR[$a]:-}" && -d "${AG_DIR[$a]}" ]] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Manifest parsing. Emits valid rows as: slug<TAB>basename<TAB>title<TAB>desc
# ---------------------------------------------------------------------------
manifest_rows() {
  [[ -f "$MANIFEST" ]] || die "manifest not found: $(prettypath "$MANIFEST")"
  # strip comments/blank lines; require at least a slug field
  awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF >= 1 && $1 != "" { print }
  ' "$MANIFEST"
}

# Canonical filename for an instruction: always UPPERCASE_WITH_UNDERSCORES.md.
# This is what gets copied/imported into an agent, so a re-run always targets the
# same file (e.g. MODEL_ROUTING.md) and never spawns a divergent lowercase copy.
enforce_caps() { # <name[.md]> -> UPPER_UNDERSCORE.md
  local n="${1%.md}"
  n="${n//-/_}"; n="${n// /_}"
  printf '%s.md' "${n^^}"
}

# Look up a slug; on success sets M_SLUG/M_BASENAME/M_TITLE/M_DESC/M_EXTRAS and
# returns 0. M_BASENAME is normalized to the canonical uppercase form; M_EXTRAS is
# the raw comma-separated companion list (may be empty). Read vars are local so
# they never clobber a caller's loop variables.
manifest_lookup() {
  local want="$1" _slug _base _title _desc _extras
  while IFS=$'\t' read -r _slug _base _title _desc _extras; do
    if [[ "$_slug" == "$want" ]]; then
      M_SLUG="$_slug"; M_TITLE="$_title"; M_DESC="$_desc"; M_EXTRAS="$_extras"
      M_BASENAME="$(enforce_caps "${_base:-$_slug.md}")"
      return 0
    fi
  done < <(manifest_rows)
  return 1
}

snippet_path() { printf '%s/%s' "$AGENTS_DIR" "${1:-}"; }

# Render a snippet into $workdir, substituting the {{CONFIG_DIR}} token with the
# given config dir (absolute for a real agent, "." for a rule-relative install).
# Uses bash string replacement rather than sed, so no path metacharacter can
# corrupt the output; substitution is per line, so a snippet with no token renders
# byte-identical (line-for-line) to its source.
render_snippet() { # <src> <cfgdir>  -> prints path to the rendered file
  local src="$1" cfgdir="$2" out line
  out="$(mktemp -p "$workdir")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//'{{CONFIG_DIR}}'/$cfgdir}"
  done < "$src" > "$out"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Plain string-presence plumbing. No wrapper markers: an instruction is
# "installed" iff its addition is already present in the target file, so a
# re-run (or content someone added by hand / via another tool) is never
# duplicated. Two shapes of addition:
#   import  — a single `@NAME.md` import line (Claude). Self-identifying.
#   inline  — the snippet's verbatim content (Codex/opencode). Identified by
#             its first non-blank line (the heading) and removed by exact match.
# ---------------------------------------------------------------------------

# True if <file> contains <needle> as a whole line (fixed-string, exact).
has_line() { # <file> <needle>
  [[ -f "$1" ]] && grep -qxF -- "$2" "$1"
}

# Append a single line, ensuring it lands on its own line.
append_line() { # <file> <line>
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" && -s "$file" && -n "$(tail -c1 "$file")" ]]; then printf '\n' >> "$file"; fi
  printf '%s\n' "$line" >> "$file"
}

# Remove every line exactly equal to <needle>. Returns 1 if there was none.
remove_line() { # <file> <needle>
  local file="$1" needle="$2" tmp
  has_line "$file" "$needle" || return 1
  tmp="$(mktemp)"; grep -vxF -- "$needle" "$file" > "$tmp"; mv "$tmp" "$file"; return 0
}

# First non-blank line of a snippet — its identifying signature.
snippet_signature() { awk 'NF{print; exit}' "$1"; }

# Append a snippet's verbatim content, separated by a blank line.
append_snippet() { # <file> <snippet-file>
  local file="$1" sf="$2"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" && -s "$file" ]]; then
    [[ -n "$(tail -c1 "$file")" ]] && printf '\n' >> "$file"
    printf '\n' >> "$file"
  fi
  cat "$sf" >> "$file"
  [[ -n "$(tail -c1 "$file")" ]] && printf '\n' >> "$file"
}

# True if <file> contains the snippet's lines as one contiguous run.
contains_snippet() { # <file> <snippet-file>
  [[ -f "$1" ]] || return 1
  awk -v sf="$2" '
    BEGIN { n=0; while ((getline l < sf) > 0) s[++n]=l }
    { ln[NR]=$0 }
    END {
      for (i=1; i+n-1 <= NR; i++) {
        ok=1; for (j=1; j<=n; j++) if (ln[i+j-1] != s[j]) { ok=0; break }
        if (ok) exit 0
      }
      exit 1
    }' "$1"
}

# Remove the snippet's contiguous run (plus one leading blank line). Returns 1
# if no exact match was found (e.g. the copy was edited after install).
remove_snippet() { # <file> <snippet-file>
  local file="$1" sf="$2" tmp rc
  [[ -f "$file" ]] || return 1
  tmp="$(mktemp)"
  awk -v sf="$sf" '
    BEGIN { n=0; while ((getline l < sf) > 0) s[++n]=l }
    { ln[NR]=$0 }
    END {
      start=0
      for (i=1; i+n-1 <= NR && start==0; i++) {
        ok=1; for (j=1; j<=n; j++) if (ln[i+j-1] != s[j]) { ok=0; break }
        if (ok) start=i
      }
      if (start==0) { for (i=1;i<=NR;i++) print ln[i]; exit 3 }
      lo=start; hi=start+n-1
      if (lo>1 && ln[lo-1] ~ /^[[:space:]]*$/) lo=lo-1
      for (i=1;i<=NR;i++) if (i<lo || i>hi) print ln[i]
    }' "$file" > "$tmp"
  rc=$?
  if [[ $rc -eq 3 ]]; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$file"; return 0
}

# ---------------------------------------------------------------------------
# Backups — one timestamped copy per file per run, only for files that exist.
# ---------------------------------------------------------------------------
RUN_TS="$(date +%Y%m%d%H%M%S)"
declare -A BACKED_UP   # original path -> backup path (also the revert source)
backup_file() { # <file>
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -n "${BACKED_UP[$f]:-}" ]] && return 0
  local bak="$f.agent-instruct.bak-$RUN_TS"
  cp -p "$f" "$bak"
  BACKED_UP["$f"]="$bak"
  info "backed up $(prettypath "$f") → $(basename "$bak")"
}

# Count of backups taken this run. Reads keys into an indexed array first: under
# `set -u`, ${#assoc[@]} on an empty associative array errors, but ${!assoc[@]} is
# safe, so this stays correct when nothing has been backed up.
backup_count() { local -a k=( "${!BACKED_UP[@]}" ); printf '%s' "${#k[@]}"; }

# ---------------------------------------------------------------------------
# Install / uninstall one (agent, slug) pair. Honors DRY_RUN.
# ---------------------------------------------------------------------------
DRY_RUN=0

# Install/uninstall the companion files in M_EXTRAS into <cfgdir>. Companions are
# copied as-is (rendered for the same {{CONFIG_DIR}}) and never imported/inlined.
# A companion that is a symlink is left as-is.
install_extras() { # <label> <cfgdir>
  local label="$1" cfgdir="$2" name canon esrc dest ren
  [[ -n "${M_EXTRAS:-}" ]] || return 0
  local -a names; IFS=',' read -r -a names <<< "$M_EXTRAS"
  for name in "${names[@]}"; do
    name="${name// /}"; [[ -z "$name" ]] && continue
    canon="$(enforce_caps "$name")"; esrc="$(snippet_path "$canon")"
    dest="$cfgdir/$canon"; ren="$(render_snippet "$esrc" "$cfgdir")"
    if [[ -L "$dest" ]]; then
      info "$label: companion $(prettypath "$dest") is a symlink → left as-is (managed elsewhere)"
    elif (( DRY_RUN )); then
      { [[ ! -f "$dest" ]] || ! cmp -s "$ren" "$dest"; } \
        && info "[dry-run] $label: copy companion $canon → $(prettypath "$dest") (read on demand)" \
        || info "[dry-run] $label: companion $canon up to date at $(prettypath "$dest")"
    elif [[ ! -f "$dest" ]] || ! cmp -s "$ren" "$dest"; then
      [[ -f "$dest" ]] && backup_file "$dest"
      mkdir -p "$cfgdir"; cp "$ren" "$dest"
      ok "$label: installed companion $canon → $(prettypath "$dest") (read on demand)"
    else
      ok "$label: companion $canon up to date ($(prettypath "$dest"))"
    fi
  done
}

uninstall_extras() { # <label> <cfgdir>
  local label="$1" cfgdir="$2" name canon dest
  [[ -n "${M_EXTRAS:-}" ]] || return 0
  local -a names; IFS=',' read -r -a names <<< "$M_EXTRAS"
  for name in "${names[@]}"; do
    name="${name// /}"; [[ -z "$name" ]] && continue
    canon="$(enforce_caps "$name")"; dest="$cfgdir/$canon"
    if [[ -L "$dest" ]]; then
      info "$label: companion $(prettypath "$dest") is a symlink → left as-is"
    elif (( DRY_RUN )); then
      [[ -f "$dest" ]] && info "[dry-run] $label: remove companion $(prettypath "$dest")"
    elif [[ -f "$dest" ]]; then
      backup_file "$dest"; rm -f "$dest"; ok "$label: removed companion $(prettypath "$dest")"
    fi
  done
}

install_pair() { # <agent> <slug>  (assumes manifest_lookup already run for slug)
  local a="$1" slug="$2" style="${AG_STYLE[$a]}" root="${AG_ROOT[$a]:-}"
  local label="${AG_LABEL[$a]}"

  if [[ "$style" == "none" ]]; then
    warn "$label: no global instructions file — skipped (${AG_NOTE[$a]})"
    return 2
  fi

  local pretty cfgdir src rendered
  pretty="$(prettypath "$root")"; cfgdir="$(dirname "$root")"
  src="$(snippet_path "$M_BASENAME")"; rendered="$(render_snippet "$src" "$cfgdir")"
  [[ -L "$root" ]] && info "$label: $pretty is a symlink → its link target will be edited"

  if [[ "$style" == "import" ]]; then
    local dest="$cfgdir/$M_BASENAME" imp="@$M_BASENAME"
    if (( DRY_RUN )); then
      if [[ -L "$dest" ]]; then
        info "[dry-run] $label: $(prettypath "$dest") is a symlink → skip copy (managed elsewhere)"
      elif [[ ! -f "$dest" ]] || ! cmp -s "$rendered" "$dest"; then
        info "[dry-run] $label: copy $M_BASENAME → $(prettypath "$dest")"
      else
        info "[dry-run] $label: $M_BASENAME up to date at $(prettypath "$dest")"
      fi
      has_line "$root" "$imp" \
        && info "[dry-run] $label: $pretty already imports $imp — leave as-is" \
        || info "[dry-run] $label: append \`$imp\` to $pretty"
    else
      if [[ -L "$dest" ]]; then
        info "$label: $(prettypath "$dest") is a symlink → left as-is (managed elsewhere)"
      elif [[ ! -f "$dest" ]] || ! cmp -s "$rendered" "$dest"; then
        [[ -f "$dest" ]] && backup_file "$dest"
        mkdir -p "$cfgdir"; cp "$rendered" "$dest"
      fi
      if has_line "$root" "$imp"; then
        ok "$label: '$slug' already imported ($imp in $pretty); snippet up to date"
      else
        backup_file "$root"; append_line "$root" "$imp"
        ok "$label: installed '$slug' (imports $imp in $pretty)"
      fi
    fi
  else # inline
    local sig; sig="$(snippet_signature "$rendered")"
    if (( DRY_RUN )); then
      has_line "$root" "$sig" \
        && info "[dry-run] $label: '$slug' already present in $pretty — leave as-is" \
        || info "[dry-run] $label: append '$slug' content to $pretty"
    else
      if has_line "$root" "$sig"; then
        ok "$label: '$slug' already present in $pretty — left as-is"
      else
        backup_file "$root"; append_snippet "$root" "$rendered"
        ok "$label: installed '$slug' (appended to $pretty)"
      fi
    fi
  fi

  install_extras "$label" "$cfgdir"
  return 0
}

uninstall_pair() { # <agent> <slug>
  local a="$1" slug="$2" style="${AG_STYLE[$a]}" root="${AG_ROOT[$a]:-}"
  local label="${AG_LABEL[$a]}" did=1

  [[ "$style" == "none" ]] && return 2

  local pretty cfgdir src rendered
  pretty="$(prettypath "$root")"; cfgdir="$(dirname "$root")"
  src="$(snippet_path "$M_BASENAME")"; rendered="$(render_snippet "$src" "$cfgdir")"

  if [[ "$style" == "import" ]]; then
    local dest="$cfgdir/$M_BASENAME" imp="@$M_BASENAME"
    if (( DRY_RUN )); then
      has_line "$root" "$imp" && { info "[dry-run] $label: remove \`$imp\` from $pretty"; did=0; }
      if [[ -L "$dest" ]]; then
        info "[dry-run] $label: $(prettypath "$dest") is a symlink → leave as-is"
      elif [[ -f "$dest" ]]; then
        info "[dry-run] $label: remove $(prettypath "$dest")"; did=0
      fi
    else
      if has_line "$root" "$imp"; then backup_file "$root"; remove_line "$root" "$imp"; did=0; fi
      if [[ -L "$dest" ]]; then
        info "$label: $(prettypath "$dest") is a symlink → left as-is"
      elif [[ -f "$dest" ]]; then backup_file "$dest"; rm -f "$dest"; did=0; fi
      (( did == 0 )) && ok "$label: removed '$slug' from $pretty"
    fi
  else # inline
    if (( DRY_RUN )); then
      contains_snippet "$root" "$rendered" && { info "[dry-run] $label: remove '$slug' content from $pretty"; did=0; }
    elif contains_snippet "$root" "$rendered"; then
      backup_file "$root"; remove_snippet "$root" "$rendered"; did=0
      ok "$label: removed '$slug' from $pretty"
    elif has_line "$root" "$(snippet_signature "$rendered")"; then
      warn "$label: a modified copy of '$slug' is in $pretty — not an exact match; remove it by hand"
    fi
  fi

  uninstall_extras "$label" "$cfgdir"

  (( did != 0 && ! DRY_RUN )) && [[ "$style" != none ]] && info "$label: '$slug' not present in $pretty — nothing to remove"
  return 0
}

# ---------------------------------------------------------------------------
# Cursor project-level install. Cursor has no global instructions file, so the
# instruction goes into a repo's .cursor/rules/ as an always-applied .mdc rule
# plus its companion files. The trigger is rendered rule-relative ({{CONFIG_DIR}}
# -> "."), so a companion reference reads ./PLANNER.md next to the rule.
# ---------------------------------------------------------------------------
cursor_project_install() { # <slug> <project-dir>  (assumes manifest_lookup run)
  local slug="$1" dir="$2"
  local rulesdir="$dir/.cursor/rules" mdc="$dir/.cursor/rules/$slug.mdc"
  local src rendered tmp
  src="$(snippet_path "$M_BASENAME")"; rendered="$(render_snippet "$src" ".")"
  tmp="$(mktemp -p "$workdir")"
  { printf -- '---\n'
    printf 'description: %s\n' "${M_DESC:-$M_TITLE}"
    printf 'alwaysApply: true\n'
    printf -- '---\n\n'
    cat "$rendered"
  } > "$tmp"
  if [[ -L "$mdc" ]]; then
    info "Cursor: $(prettypath "$mdc") is a symlink → left as-is"
  elif (( DRY_RUN )); then
    { [[ ! -f "$mdc" ]] || ! cmp -s "$tmp" "$mdc"; } \
      && info "[dry-run] Cursor: write $(prettypath "$mdc")" \
      || info "[dry-run] Cursor: $(prettypath "$mdc") up to date"
  elif [[ ! -f "$mdc" ]] || ! cmp -s "$tmp" "$mdc"; then
    [[ -f "$mdc" ]] && backup_file "$mdc"
    mkdir -p "$rulesdir"; cp "$tmp" "$mdc"
    ok "Cursor: installed '$slug' → $(prettypath "$mdc")"
  else
    ok "Cursor: '$slug' up to date ($(prettypath "$mdc"))"
  fi
  install_extras "Cursor" "$rulesdir"
}

cursor_project_uninstall() { # <slug> <project-dir>
  local slug="$1" dir="$2"
  local rulesdir="$dir/.cursor/rules" mdc="$dir/.cursor/rules/$slug.mdc"
  if [[ -L "$mdc" ]]; then
    info "Cursor: $(prettypath "$mdc") is a symlink → left as-is"
  elif (( DRY_RUN )); then
    [[ -f "$mdc" ]] && info "[dry-run] Cursor: remove $(prettypath "$mdc")"
  elif [[ -f "$mdc" ]]; then
    backup_file "$mdc"; rm -f "$mdc"; ok "Cursor: removed '$slug' ($(prettypath "$mdc"))"
  else
    info "Cursor: '$slug' not present in $(prettypath "$rulesdir")"
  fi
  uninstall_extras "Cursor" "$rulesdir"
}

# ---------------------------------------------------------------------------
# Reporting.
# ---------------------------------------------------------------------------
print_instructions() {
  printf '%sAvailable instructions%s (from %s):\n' "$c_bold" "$c_reset" "$(prettypath "$MANIFEST")"
  local any=0 slug base title desc extras mark note ename ecanon
  while IFS=$'\t' read -r slug base title desc extras; do
    any=1
    mark=" "
    [[ -f "$(snippet_path "$(enforce_caps "${base:-$slug.md}")")" ]] || mark="!"
    note=""
    if [[ -n "$extras" ]]; then
      note="  (+ $extras)"
      local -a _ex; IFS=',' read -r -a _ex <<< "$extras"
      for ename in "${_ex[@]}"; do
        ename="${ename// /}"; [[ -z "$ename" ]] && continue
        ecanon="$(enforce_caps "$ename")"
        [[ -f "$(snippet_path "$ecanon")" ]] || mark="!"
      done
    fi
    printf '  %s %-16s %s%s\n' "$mark" "$slug" "${desc:-$title}" "$note"
  done < <(manifest_rows)
  (( any )) || printf '  (none)\n'
  printf '  %s(a %s!%s marks a manifest row whose .md file is missing)%s\n' "$c_dim" "$c_ylw" "$c_dim" "$c_reset"
}

print_agents() {
  printf '%sDetected agents on this machine:%s\n' "$c_bold" "$c_reset"
  local a
  for a in "${AGENT_ORDER[@]}"; do
    local label="${AG_LABEL[$a]}" state
    if agent_present "$a"; then
      case "${AG_STYLE[$a]}" in
        import) state="→ import into $(prettypath "${AG_ROOT[$a]}")" ;;
        inline) state="→ inline into $(prettypath "${AG_ROOT[$a]}")" ;;
        none)   state="${c_ylw}no global instructions file — will skip${c_reset} (${AG_NOTE[$a]})" ;;
      esac
      printf '  %s%-13s%s installed   %s\n' "$c_grn" "$label" "$c_reset" "$state"
    else
      printf '  %s%-13s not installed%s\n' "$c_dim" "$label" "$c_reset"
    fi
  done
}

usage() {
  cat <<EOF
${c_bold}install-agent-instruct.sh${c_reset} v$VERSION — install reusable agent instructions
into whatever coding agents are present on this machine.

${c_bold}USAGE${c_reset}
  ./install-agent-instruct.sh [options] [slug ...]

${c_bold}OPTIONS${c_reset}
  -l, --list           List available instructions and exit
  -a, --all            Act on every instruction in the manifest
      --agents a,b,c   Restrict to these agents (default: all detected).
                       Known: ${AGENT_ORDER[*]}
      --cursor-project DIR
                       Install into a repo's .cursor/rules/ instead of a global
                       file (Cursor has no global instructions file)
  -n, --dry-run        Show what would change; write nothing
  -y, --yes            Don't prompt for confirmation
  -u, --uninstall      Remove the chosen instruction(s) instead of installing
  -h, --help           This help (also shown with no arguments)
      --version        Print version and exit

${c_bold}EXAMPLES${c_reset}
  ./install-agent-instruct.sh                     # help + what's available + detected agents
  ./install-agent-instruct.sh model-routing       # install into every detected agent
  ./install-agent-instruct.sh -a -y               # install everything, no prompt
  ./install-agent-instruct.sh --agents claude model-routing
  ./install-agent-instruct.sh --cursor-project ~/repos/foo planning
  ./install-agent-instruct.sh -u model-routing    # uninstall

EOF
  print_instructions
  echo
  print_agents
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
DO_LIST=0 DO_ALL=0 ASSUME_YES=0 UNINSTALL=0
AGENTS_FILTER=""
CURSOR_PROJECT=""
declare -a SLUGS=()

[[ $# -eq 0 ]] && { usage; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage; exit 0 ;;
    --version)       echo "install-agent-instruct.sh $VERSION"; exit 0 ;;
    -l|--list)       DO_LIST=1; shift ;;
    -a|--all)        DO_ALL=1; shift ;;
    --agents)        AGENTS_FILTER="${2:-}"; shift 2 ;;
    --agents=*)      AGENTS_FILTER="${1#*=}"; shift ;;
    --cursor-project)   CURSOR_PROJECT="${2:-}"; shift 2 ;;
    --cursor-project=*) CURSOR_PROJECT="${1#*=}"; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -u|--uninstall)  UNINSTALL=1; shift ;;
    --)              shift; while [[ $# -gt 0 ]]; do SLUGS+=("$1"); shift; done ;;
    -*)              die "unknown flag: $1  (see --help)" ;;
    *)               SLUGS+=("$1"); shift ;;
  esac
done

if (( DO_LIST )); then print_instructions; exit 0; fi

# ---------------------------------------------------------------------------
# Resolve which slugs to act on.
# ---------------------------------------------------------------------------
if (( DO_ALL )); then
  SLUGS=()
  while IFS=$'\t' read -r slug _; do SLUGS+=("$slug"); done < <(manifest_rows)
fi
(( ${#SLUGS[@]} )) || { usage; exit 0; }

# Validate every slug against the manifest and its .md file up front.
for slug in "${SLUGS[@]}"; do
  manifest_lookup "$slug" || die "unknown instruction: '$slug'  (see --list)"
  [[ -f "$(snippet_path "$M_BASENAME")" ]] \
    || die "manifest lists '$slug' but its file is missing: $(prettypath "$(snippet_path "$M_BASENAME")")"
  if [[ -n "${M_EXTRAS:-}" ]]; then
    IFS=',' read -r -a _ex <<< "$M_EXTRAS"
    for _e in "${_ex[@]}"; do
      _e="${_e// /}"; [[ -z "$_e" ]] && continue
      _ec="$(enforce_caps "$_e")"
      [[ -f "$(snippet_path "$_ec")" ]] \
        || die "manifest lists companion '$_e' for '$slug' but its file is missing: $(prettypath "$(snippet_path "$_ec")")"
    done
  fi
done

# ---------------------------------------------------------------------------
# Cursor project-level install runs on its own, bypassing agent detection.
# ---------------------------------------------------------------------------
if [[ -n "$CURSOR_PROJECT" ]]; then
  [[ -d "$CURSOR_PROJECT" ]] || die "not a directory: $CURSOR_PROJECT"
  action="install"; (( UNINSTALL )) && action="uninstall"
  printf '%s%s plan%s%s:\n' "$c_bold" "${action^}" "$c_reset" "$( ((DRY_RUN)) && printf ' (dry-run)' )"
  printf '  instructions : %s\n' "${SLUGS[*]}"
  printf '  target       : Cursor project %s\n' "$(prettypath "$CURSOR_PROJECT")"
  echo
  if (( ! ASSUME_YES && ! DRY_RUN )) && [[ -t 0 ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { info "aborted."; exit 0; }
    echo
  fi
  for slug in "${SLUGS[@]}"; do
    manifest_lookup "$slug"
    if (( UNINSTALL )); then cursor_project_uninstall "$slug" "$CURSOR_PROJECT"
    else cursor_project_install "$slug" "$CURSOR_PROJECT"; fi
  done
  echo
  if (( DRY_RUN )); then
    info "dry-run complete — nothing was written."
  elif (( $(backup_count) )); then
    ok "done."
    info "backup saved before each change — to revert, restore:"
    for _f in "${!BACKED_UP[@]}"; do
      info "  cp '$(prettypath "${BACKED_UP[$_f]}")' '$(prettypath "$_f")'"
    done
  else
    ok "done."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve which agents to act on.
# ---------------------------------------------------------------------------
declare -a TARGET_AGENTS=()
if [[ -n "$AGENTS_FILTER" ]]; then
  IFS=',' read -r -a _req <<< "$AGENTS_FILTER"
  for a in "${_req[@]}"; do
    a="${a// /}"; [[ -z "$a" ]] && continue
    agent_known "$a" || die "unknown agent: '$a'  (known: ${AGENT_ORDER[*]})"
    TARGET_AGENTS+=("$a")
    agent_present "$a" || warn "$a not detected — acting anyway because you named it with --agents"
  done
else
  for a in "${AGENT_ORDER[@]}"; do agent_present "$a" && TARGET_AGENTS+=("$a"); done
fi

if (( ${#TARGET_AGENTS[@]} == 0 )); then
  die "no target agents (none detected; try --agents ${AGENT_ORDER[0]})"
fi

# ---------------------------------------------------------------------------
# Show the plan, confirm, execute.
# ---------------------------------------------------------------------------
action="install"; (( UNINSTALL )) && action="uninstall"
printf '%s%s plan%s%s:\n' "$c_bold" "${action^}" "$c_reset" "$( ((DRY_RUN)) && printf ' (dry-run)' )"
printf '  instructions : %s\n' "${SLUGS[*]}"
printf '  agents       : %s\n' "${TARGET_AGENTS[*]}"
echo

if (( ! ASSUME_YES && ! DRY_RUN )) && [[ -t 0 ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { info "aborted."; exit 0; }
  echo
fi

rc=0
for slug in "${SLUGS[@]}"; do
  manifest_lookup "$slug"   # repopulate M_* for this slug
  for a in "${TARGET_AGENTS[@]}"; do
    if (( UNINSTALL )); then
      uninstall_pair "$a" "$slug" || rc=$?
    else
      install_pair "$a" "$slug" || { s=$?; [[ $s -ne 2 ]] && rc=$s; }
    fi
  done
done

echo
if (( DRY_RUN )); then
  info "dry-run complete — nothing was written."
elif (( UNINSTALL )); then
  ok "done."
  if (( $(backup_count) )); then
    info "backup saved before each change — to revert this uninstall, restore:"
    for _f in "${!BACKED_UP[@]}"; do
      info "  cp '$(prettypath "${BACKED_UP[$_f]}")' '$(prettypath "$_f")'"
    done
  fi
  info "note: the addition is self-identifying (no wrapper markers), so uninstall"
  info "      removes it wherever it was found — including an import line or content"
  info "      that predated this tool (e.g. one your dotfiles already added). Re-run"
  info "      without -u to reinstall, or restore the backup above."
else
  ok "done."
fi
exit "$rc"
