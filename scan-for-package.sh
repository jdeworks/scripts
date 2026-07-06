#!/usr/bin/env bash
# Hunt the filesystem for evidence of specific npm / pip packages.
# Built for chasing reported compromised or vulnerable dependencies.
#
# v2.0.0 - multi-package, advisory paste mode, AND-ranges, per-hit
#          verdicts (VULN/OK/UNKNOWN), npm/PyPI fix lookup, exports.
# v2.1.0 - requirements.txt transitive resolution via uv pip compile /
#          pip-compile (top-level-only files hide vulnerable transitive
#          deps), interactive ecosystem choice, --no-pip-compile.
set -uEo pipefail
IFS=$'\n\t'
shopt -s nullglob

VERSION="2.1.0"
SCAN_PWD="$(pwd)"

############################
# state / cleanup
############################

FOUND_FILE="$(mktemp)"
HITS_FILE="$(mktemp)"      # TSV: pkg_idx \t verdict \t category \t detail \t versions
WALK_FILE="$(mktemp)"
RESOLVE_TMP="$(mktemp -d)" # compiled requirements output (never written next to sources)
SPINNER_PID=""
SPINNER_T0=0

NM_SCANNED=0
SP_SCANNED=0
NPM_MAN_SCANNED=0
PY_MAN_SCANNED=0
REQ_RESOLVED=0
REQ_RESOLVE_FAILED=0
REQ_ALREADY_PINNED=0
REQ_SKIPPED_CACHE=0
RESOLVE_FAILED_LIST=()   # entries: "<file>\t<first error line>"

echo 0 > "$FOUND_FILE"

cleanup() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    rm -f "$FOUND_FILE" "$HITS_FILE" "$WALK_FILE"
    rm -rf "$RESOLVE_TMP"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

mark_found() { echo 1 > "$FOUND_FILE"; }

############################
# UI
############################

if [[ -t 1 ]]; then
    TTY=1
    BOLD=$'\033[1m'; DIM=$'\033[2m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m';  CYAN=$'\033[36m'; MAGENTA=$'\033[35m'
    RESET=$'\033[0m'
    CLR=$'\r\033[K'
else
    TTY=0
    BOLD=''; DIM=''; GREEN=''; YELLOW=''
    RED='';  CYAN=''; MAGENTA=''; RESET=''
    CLR=''
fi

log()  { printf '%s[%s]%s %s\n' "$DIM" "$(date '+%H:%M:%S')" "$RESET" "$*"; }
ok()   { printf '%s[OK]%s   %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s[ERR]%s  %s\n' "$RED"    "$RESET" "$*" >&2; }

hr() { printf '%s%s%s\n' "$DIM" "============================================================" "$RESET"; }
title() {
    echo
    hr
    printf ' %s%s%s\n' "$BOLD" "$*" "$RESET"
    hr
}

clear_line() { printf '%s' "$CLR"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

############################
# spinner / progress
############################

spinner_start() {
    local label="$1"
    if (( TTY == 0 )); then
        log "$label..."
        return
    fi
    SPINNER_T0=$(date +%s)
    (
        trap - EXIT INT TERM
        local frames='|/-\'
        local i=0
        while :; do
            local elapsed=$(( $(date +%s) - SPINNER_T0 ))
            local ch="${frames:i++%4:1}"
            printf '\r\033[K  %s%s%s %s %s[%ds]%s' \
                "$CYAN" "$ch" "$RESET" "$label" "$DIM" "$elapsed" "$RESET"
            sleep 0.15
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    (( TTY == 1 )) && clear_line
}

PROG_LAST_HITS=0
progress() {
    (( TTY == 0 )) && return
    local i=$1 n=$2 label=$3
    [[ "$n" -le 0 ]] && return
    if (( i == 1 || i % 64 == 0 || i == n )); then
        PROG_LAST_HITS=$(wc -l < "$HITS_FILE" 2>/dev/null | tr -d ' ')
        [[ -z "$PROG_LAST_HITS" ]] && PROG_LAST_HITS=0
    fi
    local w=28
    local p=$(( i * 100 / n ))
    local f=$(( i * w / n ))
    local bar="" k
    for ((k=0; k<f; k++)); do bar+="#"; done
    for ((k=f; k<w; k++)); do bar+="-"; done
    local hits_color="$DIM"
    (( PROG_LAST_HITS > 0 )) && hits_color="$YELLOW"
    printf '\r\033[K  %-16s [%s%s%s] %3d%% (%d/%d) %s%d hits%s' \
        "$label" "$CYAN" "$bar" "$RESET" "$p" "$i" "$n" "$hits_color" "$PROG_LAST_HITS" "$RESET"
}

############################
# usage / args
############################

usage() {
    cat <<EOF
Usage:
  $0 [options] 'NAME[:VERSION_EXPR]' ['NAME[:VERSION_EXPR]' ...] [SEARCH_ROOT]
  $0 [options] --paste            # paste advisory text (also default w/o specs)
  printf '...\n' | $0 --paste     # paste mode via stdin pipe

Package specs:
  'protobufjs:<=7.5.5, >=8.0.0 <=8.0.1'   name + version filter (exact match,
                                          incl. common name variants)
  'protobuf'                              bare name without filter = substring
                                          discovery scan (hits become INFO)
  The last positional argument is taken as SEARCH_ROOT if it is an
  existing directory (default: /).

Version expressions - three syntaxes are accepted, detected per line:

  advisory / CLI    'name: <=7.5.5 and >=8.0.0 <=8.0.1'
                    ','  ';'  '||'  and the words 'and' / 'or' / 'und'
                    separate OR-alternatives. Space-separated comparators
                    INSIDE one alternative are AND-combined.
                    NOTE: advisory wording "X and Y" lists alternative
                    vulnerable ranges -> treated as OR (a version is
                    flagged if it falls in ANY range); the boundaries of
                    one range (>=8.0.0 <=8.0.1) are AND-combined.

  pip / PEP 440     'protobuf>=4.21.0,!=4.24.1,<5.0'
                    A requirements.txt line (no colon, name glued to an
                    operator). Commas are AND per PEP 440. Supports
                    ==  !=  ~=  ===  ==1.2.*  ; environment markers
                    (after ';') and #comments are stripped.

  npm semver        'protobufjs@<7.5.6 || >=8.0.0 <8.0.2'
                    '||' = OR, space = AND. ^X ~X 1.2.x 1.x * supported.

  Single clauses:  1.2.3  v1.2.3  =X  ==X  !=X  >X  >=X  <X  <=X  ^X  ~X  ~=X
  Inclusive range: 4.17.15 - 4.17.20   (spaces around the hyphen required)
  An AND-chain that can never match (e.g. comma semantics mixed up) is
  flagged on the confirmation screen before the scan starts.

Paste mode input (one package per line, advisory-style, end with blank line):
  * protobufjs: versions <= 7.5.5 and >= 8.0.0 <= 8.0.1
  * protobufjs-cli: versions <= 1.2.0 and >= 2.0.0 <= 2.0.1
  Leading bullets (*, -, •) and the word "versions" are ignored.

Options:
  -m, --mode npm|python|both   ecosystem to scan           (default: both)
  -r, --root DIR               filesystem root to walk     (default: /)
      --paste                  read advisory lines from stdin
      --contains               force substring matching for all names
      --exact                  force exact matching for all names
  -y, --yes                    skip the pre-scan confirmation (and the
                               guided setup - defaults/flags are used)
      --no-registry            skip the npm/PyPI fixed-version lookup
                               (also disables requirements resolution: network)
      --no-pip-compile         do not resolve requirements files with
                               uv/pip-compile (transitive deps stay unchecked)
      --export-dir DIR         write findings + update script there (no prompt)
  -h, --help                   this help
      --version                print version

Guided setup:
  Any setting NOT fixed by a flag is asked interactively at startup when run
  on a terminal (ecosystems, root, registry lookup, requirements resolution).
  Non-interactive runs (pipes, cron) and -y/--yes take the defaults silently.

Verdicts per hit:
  VULN     extracted version matches the vulnerable expression
  OK       concrete version extracted, outside the vulnerable expression
  UNKNOWN  no version extractable, or only a declared range (e.g. ^7.0.0)
           - check the location manually
  INFO     discovery hit (package given without a version filter)

Optional tools (the scan runs without them, just with less precision):
  python3 / jq   precise package.json + lockfile parsing (section-aware,
                 nested resolution). Missing -> grep fallback (fuzzier).
                 Note: npm/PyPI scanning does NOT require python - it is only
                 used, when present, as a faster/precise JSON parser.
  npm            'npm ls' on the current project + global-root discovery.
  pipx           detect pipx-managed apps.
  curl           online npm/PyPI fix-version lookup (--no-registry skips it).
  uv/pip-compile resolve requirements*.txt/.in to the FULL pinned dependency
                 tree, so vulnerable TRANSITIVE python deps become visible
                 (a plain requirements.txt only lists top-level packages).
                 uv preferred (much faster), pip-compile as fallback; files
                 that fail to resolve are flagged. Missing both -> top-level
                 scan only, with a recommendation to install one of them.
                 Hits found ONLY in the resolved tree are marked "resolved
                 transitive": a fresh install WOULD pull that version - it
                 says nothing about what is currently installed.
  Anything missing is reported once on the confirmation screen, never fatal.

Exit codes:
  0  nothing found, or everything found is OK
  3  VULN or INFO hits present
  4  no VULN, but UNKNOWN hits present (manual review needed)

Notes:
  - Advisories often use display names ("protobuf.js") that differ from the
    real registry name ("protobufjs"). The variant list shown before the
    scan includes a separator-collapsed form to catch this; still, verify
    the names on the confirmation screen.
  - The generated update script is a BEST-EFFORT aid, not a guarantee.
    Review it before running.

Version: $VERSION
EOF
}

# Every setting below is dual: fix it with a flag, or leave it open and get
# asked interactively at startup (TTY only). *_SET tracks "fixed by flag".
MODE="both";     MODE_SET=0
SEARCH_ROOT="/"; ROOT_SET=0
ASSUME_YES=0
FORCE_PASTE=0
MATCH_OVERRIDE=""      # "", exact, contains
NO_REGISTRY=0;   REGISTRY_SET=0
NO_PIPCOMPILE=0; PIPCOMPILE_SET=0
EXPORT_DIR=""
RAW_SPECS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)        MODE="${2:-}"; MODE_SET=1; shift 2 ;;
        -r|--root)        SEARCH_ROOT="${2:-/}"; ROOT_SET=1; shift 2 ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        --paste)          FORCE_PASTE=1; shift ;;
        --contains)       MATCH_OVERRIDE="contains"; shift ;;
        --exact)          MATCH_OVERRIDE="exact"; shift ;;
        --no-registry)    NO_REGISTRY=1; REGISTRY_SET=1; shift ;;
        --no-pip-compile) NO_PIPCOMPILE=1; PIPCOMPILE_SET=1; shift ;;
        --export-dir)     EXPORT_DIR="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        --version)        echo "scan-for-package.sh $VERSION"; exit 0 ;;
        --)               shift; while [[ $# -gt 0 ]]; do RAW_SPECS+=("$1"); shift; done ;;
        -*)               err "unknown flag: $1"; usage; exit 2 ;;
        *)                RAW_SPECS+=("$1"); shift ;;
    esac
done

case "$MODE" in npm|python|py|both|all) : ;; *) err "invalid mode: $MODE"; exit 1 ;; esac
[[ "$MODE" == "py"  ]] && MODE=python
[[ "$MODE" == "all" ]] && MODE=both

# v1 compatibility: trailing positional that is an existing directory = root.
if (( ${#RAW_SPECS[@]} >= 2 )); then
    last="${RAW_SPECS[${#RAW_SPECS[@]}-1]}"
    if [[ "$last" != *:* && -d "$last" ]]; then
        SEARCH_ROOT="$last"
        ROOT_SET=1
        unset 'RAW_SPECS[${#RAW_SPECS[@]}-1]'
    fi
fi

############################
# capabilities (detected once)
############################
#
# None of these are hard requirements - the scan degrades gracefully:
#   python3 / jq : parse package.json + lockfiles precisely (section-aware,
#                  nested resolution). Without them we fall back to grep,
#                  which is fuzzier (e.g. can't separate devDependencies).
#   npm          : `npm ls` in the current project + global root discovery.
#   pipx         : detect pipx-managed apps.
#   curl         : online npm/PyPI fix-version lookup.
#   uv/pip-compile: resolve requirements files to the full pinned dependency
#                  tree (a plain requirements.txt lists only top-level deps,
#                  so vulnerable TRANSITIVE deps stay invisible without this).
#                  uv is preferred (much faster); pip-compile is the fallback.
# We probe each tool ONCE here instead of forking `command -v` per file.

HAVE_PYTHON3=0;    command -v python3     >/dev/null 2>&1 && HAVE_PYTHON3=1
HAVE_JQ=0;         command -v jq          >/dev/null 2>&1 && HAVE_JQ=1
HAVE_NPM=0;        command -v npm         >/dev/null 2>&1 && HAVE_NPM=1
HAVE_PIPX=0;       command -v pipx        >/dev/null 2>&1 && HAVE_PIPX=1
HAVE_CURL=0;       command -v curl        >/dev/null 2>&1 && HAVE_CURL=1
HAVE_UV=0;         command -v uv          >/dev/null 2>&1 && HAVE_UV=1
HAVE_PIPCOMPILE=0; command -v pip-compile >/dev/null 2>&1 && HAVE_PIPCOMPILE=1

RESOLVER=""
if   (( HAVE_UV ));         then RESOLVER="uv pip compile"
elif (( HAVE_PIPCOMPILE )); then RESOLVER="pip-compile"
fi

############################
# guided setup
############################
#
# Anything not fixed on the command line is asked here, so a bare
# `bash scan-for-package.sh` walks through all settings. Non-TTY runs
# and -y/--yes just take the defaults (or the flags that were given).

guided_setup() {
    (( ASSUME_YES )) && return 0
    [[ -t 0 ]] || return 0
    if (( MODE_SET && ROOT_SET && REGISTRY_SET && PIPCOMPILE_SET )); then
        return 0
    fi
    local ans
    title "Setup  (Enter = default; every question can be fixed via a flag, see --help)"
    if (( ! MODE_SET )); then
        read -rp "  Ecosystems to scan - [n]pm, [p]ython, or [B]oth: " ans
        case "$(trim "$ans")" in
            n|N|npm)                  MODE=npm ;;
            p|P|py|pypi|PyPI|python) MODE=python ;;
            *)                        MODE=both ;;
        esac
    fi
    if (( ! ROOT_SET )); then
        read -rp "  Filesystem root to scan [${SEARCH_ROOT}]: " ans
        ans="$(trim "$ans")"
        if [[ -n "$ans" ]]; then
            if [[ -d "$ans" ]]; then
                SEARCH_ROOT="$ans"
            else
                warn "not a directory: '$ans' - keeping ${SEARCH_ROOT}"
            fi
        fi
    fi
    if (( ! REGISTRY_SET )); then
        read -rp "  Online npm/PyPI fix-version lookup (network)? [Y/n]: " ans
        case "$(trim "$ans")" in n|N|no|NO) NO_REGISTRY=1 ;; esac
    fi
    if [[ "$MODE" != "npm" ]] && (( ! PIPCOMPILE_SET )) && [[ -n "$RESOLVER" ]]; then
        read -rp "  Resolve requirements files with ${RESOLVER} to catch transitive deps (network)? [Y/n]: " ans
        case "$(trim "$ans")" in n|N|no|NO) NO_PIPCOMPILE=1 ;; esac
    fi
}
guided_setup

# absolute root -> hit paths (and the exported update script) work from anywhere
SEARCH_ROOT="$(readlink -f "$SEARCH_ROOT" 2>/dev/null || printf '%s' "$SEARCH_ROOT")"

prereq_notice() {
    local missing=()
    if (( ! HAVE_PYTHON3 && ! HAVE_JQ )); then
        warn "neither python3 nor jq found - manifests/lockfiles parsed with a grep fallback (fuzzier; can't isolate devDependencies)"
        missing+=("python3 or jq")
    fi
    if [[ "$MODE" != "python" ]] && (( ! HAVE_NPM )); then
        warn "npm not found - skipping 'npm ls' and global-root discovery (filesystem scan still runs)"
        missing+=("npm")
    fi
    if (( ! NO_REGISTRY && ! HAVE_CURL )); then
        warn "curl not found - skipping the online npm/PyPI fix-version lookup"
        missing+=("curl")
    fi
    if (( ${#missing[@]} > 0 )); then
        local joined; printf -v joined '%s, ' "${missing[@]}"; joined="${joined%, }"
        printf '  %s(optional tools missing: %s - install them for fuller results)%s\n' \
            "$DIM" "$joined" "$RESET"
    fi
    if [[ "$MODE" != "npm" ]]; then
        echo
        printf '  %sPython requirements note:%s a plain requirements.txt usually pins only\n' "$BOLD" "$RESET"
        printf '  TOP-LEVEL packages - vulnerable transitive dependencies are invisible in\n'
        printf '  it unless it was generated with pip-compile/uv (fully locked).\n'
        if [[ -z "$RESOLVER" ]]; then
            printf '  %s-> neither uv nor pip-compile found: transitive deps declared by\n' "$YELLOW"
            printf '     requirements files will NOT be checked. Recommended: install uv\n'
            printf '     (fast) or pip-tools (pip install pip-tools), then re-run.%s\n' "$RESET"
        elif (( NO_PIPCOMPILE )); then
            printf '  %s-> %s available, but resolution is disabled (--no-pip-compile or setup choice).%s\n' \
                "$YELLOW" "$RESOLVER" "$RESET"
        elif (( NO_REGISTRY )); then
            printf '  %s-> resolution needs the network and --no-registry was given - skipped.%s\n' \
                "$YELLOW" "$RESET"
        else
            printf '  %s-> %s found: each requirements file will additionally be resolved\n' "$GREEN" "$RESOLVER"
            printf '     to its full dependency tree and the pinned result scanned too.%s\n' "$RESET"
            printf '  %s   (resolving fetches package metadata from PyPI - scan trusted files only;\n' "$DIM"
            printf '      hits found only in the resolved tree mean "a fresh install WOULD pull\n'
            printf '      this", not that it is currently installed)%s\n' "$RESET"
        fi
    fi
}

############################
# version expression grammar
############################

re_escape() {
    printf '%s' "$1" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g'
}

ver_normalize() {
    local v parts
    v="$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
    [[ -z "$v" ]] && v="0"
    IFS=. read -ra parts <<<"$v"
    printf '%d.%d.%d' "${parts[0]:-0}" "${parts[1]:-0}" "${parts[2]:-0}"
}

ver_cmp() {
    local a b A B i
    a="$(ver_normalize "$1")"
    b="$(ver_normalize "$2")"
    IFS=. read -ra A <<<"$a"
    IFS=. read -ra B <<<"$b"
    for i in 0 1 2; do
        if (( A[i] < B[i] )); then echo -1; return; fi
        if (( A[i] > B[i] )); then echo 1;  return; fi
    done
    echo 0
}

# One comparator (or hyphen range) against a concrete version.
clause_match() {
    local ver="$1" clause
    clause="$(trim "$2")"
    [[ -z "$clause" ]] && return 1

    if [[ "$clause" == *" - "* ]]; then
        local lo="${clause%% - *}" hi="${clause##* - }" c1 c2
        c1="$(ver_cmp "$ver" "$lo")"
        c2="$(ver_cmp "$ver" "$hi")"
        [[ "$c1" != "-1" && "$c2" != "1" ]] && return 0
        return 1
    fi

    local op="" target="$clause"
    case "$clause" in
        "==="*) op="=";  target="${clause#===}" ;;   # PEP 440 arbitrary equality
        "=="*)  op="=";  target="${clause#==}"  ;;   # PEP 440 / pip exact
        "!="*)  op="!="; target="${clause#!=}"  ;;   # PEP 440 exclusion
        "~="*)  op="~="; target="${clause#~=}"  ;;   # PEP 440 compatible release
        ">="*)  op=">="; target="${clause#>=}" ;;
        "<="*)  op="<="; target="${clause#<=}" ;;
        ">"*)   op=">";  target="${clause#>}"  ;;
        "<"*)   op="<";  target="${clause#<}"  ;;
        "="*)   op="=";  target="${clause#=}"  ;;
        "^"*)   op="^";  target="${clause#^}"  ;;
        "~"*)   op="~";  target="${clause#~}"  ;;
        *)      op="=";  target="$clause"      ;;
    esac
    target="$(trim "$target")"
    target="${target#v}"

    local c norm T_arr hi c1 c2 dots
    case "$op" in
        "=")
            if is_wildcard "$target"; then
                in_wildcard "$ver" "$target" && return 0
            else
                [[ "$(ver_cmp "$ver" "$target")" == "0" ]] && return 0
            fi ;;
        "!=")
            if is_wildcard "$target"; then
                in_wildcard "$ver" "$target" || return 0
            else
                [[ "$(ver_cmp "$ver" "$target")" != "0" ]] && return 0
            fi ;;
        ">")  [[ "$(ver_cmp "$ver" "$target")" == "1"  ]] && return 0 ;;
        ">=") c="$(ver_cmp "$ver" "$target")"; [[ "$c" != "-1" ]] && return 0 ;;
        "<")  [[ "$(ver_cmp "$ver" "$target")" == "-1" ]] && return 0 ;;
        "<=") c="$(ver_cmp "$ver" "$target")"; [[ "$c" != "1"  ]] && return 0 ;;
        "^")
            norm="$(ver_normalize "$target")"
            IFS=. read -ra T_arr <<<"$norm"
            hi="$(( T_arr[0] + 1 )).0.0"
            c1="$(ver_cmp "$ver" "$target")"
            c2="$(ver_cmp "$ver" "$hi")"
            [[ "$c1" != "-1" && "$c2" == "-1" ]] && return 0 ;;
        "~"|"~=")
            norm="$(ver_normalize "$target")"
            IFS=. read -ra T_arr <<<"$norm"
            # PEP 440: ~=X.Y means >=X.Y, <X+1.0 ; ~=X.Y.Z means >=X.Y.Z, <X.Y+1.0
            dots="$(awk -F. '{print NF-1}' <<<"$target")"
            if [[ "$op" == "~=" && "$dots" -le 1 ]]; then
                hi="$(( T_arr[0] + 1 )).0.0"
            else
                hi="${T_arr[0]}.$(( T_arr[1] + 1 )).0"
            fi
            c1="$(ver_cmp "$ver" "$target")"
            c2="$(ver_cmp "$ver" "$hi")"
            [[ "$c1" != "-1" && "$c2" == "-1" ]] && return 0 ;;
    esac
    return 1
}

# npm-style x-ranges and pip-style ==1.2.* wildcards
is_wildcard() {
    [[ "$1" == *"*"* || "$1" == *.x || "$1" == *.X || "$1" == x || "$1" == X ]]
}

wildcard_bounds() {   # target -> "lo hi" (hi exclusive), or "ALL ALL"
    local base parts
    base="$(printf '%s' "$1" | sed -E 's/[.]?[*xX].*$//')"
    if [[ -z "$base" ]]; then printf 'ALL ALL'; return; fi
    local parr=()
    IFS=. read -ra parr <<<"$base"
    case "${#parr[@]}" in
        1) printf '%s.0.0 %s.0.0' "${parr[0]}" "$(( parr[0] + 1 ))" ;;
        2) printf '%s.%s.0 %s.%s.0' "${parr[0]}" "${parr[1]}" "${parr[0]}" "$(( parr[1] + 1 ))" ;;
        *) printf '%s %s' "$base" "$base" ;;
    esac
}

in_wildcard() {       # ver target
    local lo hi
    read -r lo hi <<<"$(wildcard_bounds "$2")"
    [[ "$lo" == "ALL" ]] && return 0
    [[ "$(ver_cmp "$1" "$lo")" != "-1" && "$(ver_cmp "$1" "$hi")" == "-1" ]]
}

# One alternative: '&'-joined comparators, ALL must hold (AND).
alt_match() {
    local ver="$1" alt="$2" part parts
    IFS='&' read -ra parts <<<"$alt"
    for part in "${parts[@]}"; do
        clause_match "$ver" "$part" || return 1
    done
    return 0
}

# Full expression: ','-joined alternatives, ANY may hold (OR).
filter_match() {
    local ver="$1" expr="$2" alts a
    IFS=, read -ra alts <<<"$expr"
    for a in "${alts[@]}"; do
        a="$(trim "$a")"
        [[ -z "$a" ]] && continue
        alt_match "$ver" "$a" && return 0
    done
    return 1
}

# Raw advisory/CLI expression text -> canonical form
# ( ','-separated alternatives, '&'-separated AND comparators ).
normalize_expr() {
    local raw="$1" out="" alt canon
    # the word version(s) is noise; 'and'/'or'/'und'/'||' between
    # alternatives all mean OR here; '&&' is an explicit AND
    raw="$(printf '%s' "$raw" \
        | sed -E 's/[Vv]ersions?//g' \
        | sed -E 's/\|\|/,/g; s/&&/ /g' \
        | sed -E 's/[[:space:]]+([Aa][Nn][Dd]|[Uu][Nn][Dd]|[Oo][Rr])[[:space:]]+/,/g; s/;/,/g')"
    # glue operators to their version: ">= 8.0.0" -> ">=8.0.0"
    raw="$(printf '%s' "$raw" | sed -E 's/(===|==|~=|!=|>=|<=|>|<|=|\^|~)[[:space:]]+/\1/g')"
    local alts=()
    IFS=, read -ra alts <<<"$raw"
    for alt in "${alts[@]+"${alts[@]}"}"; do
        alt="$(trim "$alt")"
        [[ -z "$alt" ]] && continue
        if [[ "$alt" == *" - "* ]]; then
            canon="$alt"                       # hyphen range stays one clause
        else
            canon="$(printf '%s' "$alt" | tr -s '[:space:]' ' ')"
            canon="$(trim "$canon")"
            canon="$(printf '%s' "$canon" | tr ' ' '&')"   # space-separated = AND
        fi
        out="${out:+$out,}$canon"
    done
    printf '%s' "$out"
}

# canonical -> human readable: "<=7.5.5 OR (>=8.0.0 AND <=8.0.1)"
human_expr() {
    local expr="$1" out="" a alts=()
    IFS=, read -ra alts <<<"$expr"
    for a in "${alts[@]+"${alts[@]}"}"; do
        [[ -z "$a" ]] && continue
        if [[ "$a" == *"&"* ]]; then
            out="${out:+$out OR }(${a//&/ AND })"
        else
            out="${out:+$out OR }$a"
        fi
    done
    printf '%s' "$out"
}

is_concrete() { [[ "$1" =~ ^v?[0-9] ]]; }

ver_list_join() {
    awk 'NF && !seen[$0]++' | paste -sd ',' -
}

############################
# package registry (in-memory)
############################

PKG_NAMES=()      # canonical name as given
PKG_EXPRS=()      # canonical version expression ("" = discovery)
PKG_MODES=()      # exact | contains
PKG_VARIANTS=()   # space-joined name variants (exact mode)
PKG_NEEDLES=()    # lowercase needle (contains mode)
PKG_COLLAPSED=()  # separator-collapsed name (registry fallback)

compute_variants() {
    local name="$1"
    local norm_lower norm_503 norm_under collapsed
    norm_lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    norm_503="$(printf '%s' "$norm_lower" | sed -E 's/[-_.]+/-/g')"
    norm_under="$(printf '%s' "$norm_503" | tr '-' '_')"
    collapsed="${norm_lower//[-_.]/}"
    printf '%s\n' \
        "$name" \
        "$norm_lower" \
        "$norm_503" \
        "$norm_under" \
        "${name//-/_}" \
        "${name//_/-}" \
        "${name//./_}" \
        "$collapsed" \
    | awk 'NF && !seen[$0]++'
}

add_package() {
    local name="$1" expr="$2" mode="$3"
    local lower collapsed
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    collapsed="${lower//[-_.]/}"
    PKG_NAMES+=("$name")
    PKG_EXPRS+=("$expr")
    PKG_MODES+=("$mode")
    PKG_VARIANTS+=("$(compute_variants "$name" | paste -sd ' ' -)")
    PKG_NEEDLES+=("$lower")
    PKG_COLLAPSED+=("$collapsed")
}

# Heuristic guard: an AND-chain whose max lower bound exceeds its min
# upper bound can never match (typical symptom of comma semantics mixed up).
alt_impossible() {
    local alt="$1" p t lo="" hi="" parts=()
    [[ "$alt" != *"&"* ]] && return 1
    IFS='&' read -ra parts <<<"$alt"
    for p in "${parts[@]}"; do
        case "$p" in
            ">="*) t="${p#>=}" ; if [[ -z "$lo" || "$(ver_cmp "$t" "$lo")" == "1"  ]]; then lo="$t"; fi ;;
            ">"*)  t="${p#>}"  ; if [[ -z "$lo" || "$(ver_cmp "$t" "$lo")" == "1"  ]]; then lo="$t"; fi ;;
            "<="*) t="${p#<=}" ; if [[ -z "$hi" || "$(ver_cmp "$t" "$hi")" == "-1" ]]; then hi="$t"; fi ;;
            "<"*)  t="${p#<}"  ; if [[ -z "$hi" || "$(ver_cmp "$t" "$hi")" == "-1" ]]; then hi="$t"; fi ;;
        esac
    done
    [[ -n "$lo" && -n "$hi" && "$(ver_cmp "$lo" "$hi")" == "1" ]]
}

expr_warnings() { # canonical expr -> warning lines (empty if fine)
    local a alts=()
    IFS=, read -ra alts <<<"$1"
    for a in "${alts[@]+"${alts[@]}"}"; do
        [[ -z "$a" ]] && continue
        if alt_impossible "$a"; then
            printf 'alternative "(%s)" can never match - AND/OR or comma semantics mixed up?\n' "${a//&/ AND }"
        fi
    done
}

# One input line -> add_package. Accepted shapes:
#   requirements.txt / PEP 440:  protobuf>=4.21.0,!=4.24.1,<5.0
#                                (no colon, name glued/spaced to an operator;
#                                 commas are AND; ';markers' and #comments dropped)
#   advisory / CLI:              name: <=7.5.5 and >=8.0.0 <=8.0.1
#                                (',' ';' 'and' 'or' 'und' '||' = OR;
#                                 spaces inside an alternative = AND)
#   npm range:                   name@<7.5.6 || >=8.0.0 <8.0.2
#   bare name:                   protobuf        (substring discovery)
parse_spec_line() {
    local line="$1" name="" expr_raw="" expr="" mode rest
    line="$(trim "$line")"
    [[ -z "$line" ]] && return 1
    line="$(printf '%s' "$line" | sed -E 's/^[*•▪—-]+[[:space:]]*//')"
    line="$(trim "$line")"
    [[ -z "$line" ]] && return 1

    local re_pep='^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^]]*\])?[[:space:]]*((===|==|~=|!=|>=|<=|>|<)[^:]*)$'
    local re_op='^(===|==|~=|!=|>=|<=|>|<)'
    local pep_name="" pep_expr=""
    if [[ "$line" =~ $re_pep ]]; then
        pep_name="${BASH_REMATCH[1]}"
        pep_expr="${BASH_REMATCH[3]}"
        [[ "$pep_expr" =~ $re_op ]] || { pep_name=""; pep_expr=""; }
    fi
    if [[ -n "$pep_name" ]]; then
        # PEP 440 requirement line: comma = AND
        name="$pep_name"
        expr_raw="$pep_expr"
        expr_raw="${expr_raw%%;*}"        # strip environment markers
        expr_raw="${expr_raw%%#*}"        # strip inline comments
        expr_raw="${expr_raw//,/ }"       # PEP comma = AND -> space (= AND)
        expr="$(normalize_expr "$expr_raw")"
    elif [[ "$line" == *:* ]]; then
        name="$(trim "${line%%:*}")"
        expr_raw="${line#*:}"
        expr="$(normalize_expr "$expr_raw")"
    elif [[ "$line" == @* && "${line#@}" == *@* ]]; then
        rest="${line#@}"                  # scoped: @scope/pkg@range
        name="@${rest%%@*}"
        expr_raw="${rest#*@}"
        expr="$(normalize_expr "$expr_raw")"
    elif [[ "$line" == ?*@* ]]; then
        name="${line%%@*}"                # npm: pkg@range
        expr_raw="${line#*@}"
        expr="$(normalize_expr "$expr_raw")"
    else
        name="$line"
    fi

    name="$(trim "$name")"
    [[ -z "$name" ]] && return 1
    if [[ -n "$expr_raw" && -z "$expr" ]]; then
        err "could not parse a version expression from: '$expr_raw' (package '$name')"
        return 2
    fi
    case "$MATCH_OVERRIDE" in
        exact)    mode="exact" ;;
        contains) mode="contains" ;;
        *)        if [[ -n "$expr" ]]; then mode="exact"; else mode="contains"; fi ;;
    esac
    add_package "$name" "$expr" "$mode"
    return 0
}

############################
# Phase 0 - collect & confirm
############################

read_paste() {
    if [[ -t 0 ]]; then
        title "Paste advisory lines"
        cat <<EOF
  One package per line, advisory-style, e.g.:

    * protobufjs: versions <= 7.5.5 and >= 8.0.0 <= 8.0.1
    * protobufjs-cli: versions <= 1.2.0 and >= 2.0.0 <= 2.0.1
    lodash                          (bare name = substring discovery)

  Bullets and the word "versions" are ignored. 'and' / ',' separate
  OR-alternatives; space-separated comparators inside one alternative
  are AND-combined. Finish with an empty line.
EOF
        echo
    fi
    local line rc
    while IFS= read -r line; do
        [[ -z "$(trim "$line")" ]] && break
        parse_spec_line "$line"
        rc=$?
        (( rc == 2 )) && exit 2
    done
}

if (( FORCE_PASTE )) || (( ${#RAW_SPECS[@]} == 0 )); then
    read_paste
else
    for s in "${RAW_SPECS[@]}"; do
        parse_spec_line "$s" || { err "invalid package spec: '$s'"; exit 2; }
    done
fi

if (( ${#PKG_NAMES[@]} == 0 )); then
    err "no packages to scan"
    usage
    exit 1
fi

title "Dependency Security Scanner v$VERSION"
log "Mode:  ${BOLD}${MODE}${RESET}"
log "Root:  ${BOLD}${SEARCH_ROOT}${RESET}"
echo
printf '  %sLooking for:%s\n' "$BOLD" "$RESET"
for i in "${!PKG_NAMES[@]}"; do
    if [[ -n "${PKG_EXPRS[$i]}" ]]; then
        printf '   %s%-22s%s vulnerable if: %s%s%s\n' \
            "$MAGENTA" "${PKG_NAMES[$i]}" "$RESET" \
            "$YELLOW" "$(human_expr "${PKG_EXPRS[$i]}")" "$RESET"
    else
        printf '   %s%-22s%s %s(discovery - no version filter)%s\n' \
            "$MAGENTA" "${PKG_NAMES[$i]}" "$RESET" "$DIM" "$RESET"
    fi
    if [[ "${PKG_MODES[$i]}" == "exact" ]]; then
        printf '   %s%-22s name variants: %s%s\n' "$DIM" "" "${PKG_VARIANTS[$i]}" "$RESET"
    else
        printf '   %s%-22s substring match: *%s*%s\n' "$DIM" "" "${PKG_NEEDLES[$i]}" "$RESET"
    fi
    if [[ -n "${PKG_EXPRS[$i]}" ]]; then
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            printf '   %s%-22s %s(!) %s%s\n' "$RED" "" "$BOLD" "$w" "$RESET"
        done < <(expr_warnings "${PKG_EXPRS[$i]}")
    fi
done
echo
printf '  %sNote:%s advisory display names can differ from registry names\n' "$BOLD" "$RESET"
printf '  (e.g. article says "protobuf.js", npm package is "protobufjs").\n'
printf '  Check the variant lists above before confirming.\n'

echo
prereq_notice

if (( ! ASSUME_YES )); then
    if [[ -t 0 ]]; then
        echo
        read -rp "  Proceed with the scan? [y/N] " go
        case "$go" in y|Y|yes|YES) : ;; *) log "aborted by user"; exit 0 ;; esac
    else
        log "stdin not a TTY and --yes not given: proceeding (read-only scan)"
    fi
fi

############################
# filesystem walk helpers
############################

FIND_PRUNE=( '('
    -path /proc -o -path /sys -o -path /dev -o -path /run
    -o -path /var/lib/docker -o -path /var/lib/containers
    -o -path /snap -o -path /mnt -o -path /media
    -o -path /.snapshots
')' )

do_walk() {
    find "$SEARCH_ROOT" \
        "${FIND_PRUNE[@]}" -prune -o \
        '(' -path '*/.git' ')' -prune -o \
        '(' -type d -name node_modules -prune -print ')' -o \
        '(' -type d '(' -name site-packages -o -name dist-packages ')' -prune -print ')' -o \
        '(' -type f '(' \
            -name package-lock.json -o \
            -name npm-shrinkwrap.json -o \
            -name pnpm-lock.yaml -o \
            -name yarn.lock -o \
            -name package.json -o \
            -name 'requirements*.txt' -o \
            -name 'requirements*.in' -o \
            -name pyproject.toml -o \
            -name Pipfile -o \
            -name Pipfile.lock -o \
            -name poetry.lock -o \
            -name setup.py -o \
            -name setup.cfg \
        ')' -print ')' \
        2>/dev/null
}

npm_global_roots() {
    (( HAVE_NPM )) && npm root -g 2>/dev/null
    [[ -d /usr/lib/node_modules ]]          && echo /usr/lib/node_modules
    [[ -d /usr/local/lib/node_modules ]]    && echo /usr/local/lib/node_modules
    [[ -d /opt/homebrew/lib/node_modules ]] && echo /opt/homebrew/lib/node_modules
    if [[ -d "$HOME/.nvm/versions/node" ]]; then
        find "$HOME/.nvm/versions/node" -mindepth 2 -maxdepth 3 \
            -type d -name node_modules 2>/dev/null
    fi
}

python_interpreters() {
    local p resolved
    declare -A seen=()
    _emit() {
        local raw="$1" r
        [[ -x "$raw" ]] || return 0
        [[ "$raw" == *-config ]] && return 0
        r="$(readlink -f "$raw" 2>/dev/null || printf '%s' "$raw")"
        [[ -n "${seen[$r]:-}" ]] && return 0
        seen[$r]=1
        printf '%s\n' "$r"
    }
    for p in python3 python2 python; do
        if command -v "$p" >/dev/null 2>&1; then
            _emit "$(command -v "$p")"
        fi
    done
    for p in /usr/bin/python3.[0-9]* /usr/local/bin/python3.[0-9]* /opt/homebrew/bin/python3.[0-9]*; do
        _emit "$p"
    done
}

python_interp_site_dirs() {
    local p
    while read -r p; do
        [[ -z "$p" ]] && continue
        "$p" - <<'PY' 2>/dev/null
import os, site, sysconfig
paths = set()
for fn in getattr(site, "getsitepackages", lambda: [])():
    if os.path.isdir(fn):
        paths.add(fn)
u = site.getusersitepackages()
if u and os.path.isdir(u):
    paths.add(u)
for k in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(k)
    if p and os.path.isdir(p):
        paths.add(p)
for p in sorted(paths):
    print(p)
PY
    done < <(python_interpreters | awk 'NF && !seen[$0]++')
}

############################
# version extractors
############################

pkgjson_own_version() {
    grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/'
}

# Is this package.json the package itself? ("name": "<pkg>")
pkgjson_is_pkg() {
    local f="$1" pkg_re
    pkg_re="$(re_escape "$2")"
    grep -Eiq "\"name\"[[:space:]]*:[[:space:]]*\"${pkg_re}\"" "$f" 2>/dev/null
}

# Dependency refs of $pkg in a package.json.
# With python3: exact, section-aware; prints "version<TAB>sections".
# Sections: dependencies, devDependencies, peerDependencies, ...
pkgjson_dep_info() {
    local f="$1" pkg="$2"
    if (( HAVE_PYTHON3 )); then
        python3 - "$f" "$pkg" <<'PY' 2>/dev/null
import json, sys
f, pkg = sys.argv[1], sys.argv[2]
try:
    with open(f) as fp:
        data = json.load(fp)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
hits = {}
for sec in ("dependencies", "devDependencies", "peerDependencies",
            "optionalDependencies", "bundleDependencies", "resolutions",
            "overrides"):
    d = data.get(sec)
    if isinstance(d, dict) and pkg in d and isinstance(d[pkg], str):
        hits.setdefault(d[pkg], set()).add(sec)
for ver, secs in hits.items():
    print(f"{ver}\t{'+'.join(sorted(secs))}")
PY
    else
        local pkg_re
        pkg_re="$(re_escape "$pkg")"
        grep -oE "\"${pkg_re}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$f" 2>/dev/null \
            | sed -E 's/.*"([^"]+)"$/\1/' \
            | awk 'NF && !seen[$0]++ {print $0 "\t?"}'
    fi
}

pkgjson_dep_versions() {
    pkgjson_dep_info "$1" "$2" | cut -f1 | awk 'NF && !seen[$0]++'
}

nlock_versions() {
    local f="$1" pkg="$2"
    if (( HAVE_PYTHON3 )); then
        python3 - "$f" "$pkg" <<'PY' 2>/dev/null
import json, sys
f, pkg = sys.argv[1], sys.argv[2]
try:
    with open(f) as fp:
        data = json.load(fp)
except Exception:
    sys.exit(0)
versions = set()
for k, v in (data.get("packages") or {}).items():
    if not k or not isinstance(v, dict):
        continue
    parts = k.split("/")
    name = None
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "node_modules" and i + 1 < len(parts):
            name = "/".join(parts[i+1:])
            break
    if name == pkg and "version" in v:
        versions.add(v["version"])
def walk(d):
    if not isinstance(d, dict):
        return
    for k, v in d.items():
        if isinstance(v, dict):
            if k == pkg and "version" in v:
                versions.add(v["version"])
            walk(v.get("dependencies"))
walk(data.get("dependencies"))
for v in sorted(versions):
    print(v)
PY
    else
        local pkg_re
        pkg_re="$(re_escape "$pkg")"
        grep -A4 -E "\"(node_modules/)?${pkg_re}\"[[:space:]]*:" "$f" 2>/dev/null \
            | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | sed -E 's/.*"([^"]+)"$/\1/'
    fi
}

ylock_versions() {
    local f="$1" pkg="$2"
    awk -v pkg="$pkg" '
        function header_has_pkg(line,    s) {
            gsub(/[",]/, " ", line)
            s = " " line " "
            return index(s, " " pkg "@") > 0
        }
        /^[^[:space:]]/ { in_block = header_has_pkg($0) }
        in_block && $1 == "version" {
            v = $2; gsub(/"/, "", v); print v
        }
    ' "$f" 2>/dev/null
}

plock_versions() {
    local f="$1" pkg="$2" pkg_re
    pkg_re="$(re_escape "$pkg")"
    grep -oE "(/${pkg_re}/|^[[:space:]]+'?${pkg_re}@|^${pkg_re}@)[0-9][^:'\"[:space:]]*" "$f" 2>/dev/null \
        | sed -E "s|.*/${pkg_re}/||; s|.*${pkg_re}@||; s|_.*||"
}

npm_manifest_versions() {
    local f="$1" pkg="$2"
    case "${f##*/}" in
        package-lock.json|npm-shrinkwrap.json)
            nlock_versions "$f" "$pkg" | ver_list_join ;;
        yarn.lock)
            ylock_versions "$f" "$pkg" | ver_list_join ;;
        pnpm-lock.yaml)
            plock_versions "$f" "$pkg" | ver_list_join ;;
        package.json)
            pkgjson_dep_versions "$f" "$pkg" | ver_list_join ;;
        *) : ;;
    esac
}

py_meta_version() {
    local d="$1" v="$2"
    local base="${d##*/}"
    base="${base%.dist-info}"
    base="${base%.egg-info}"
    base="${base#${v}-}"
    base="${base#${v}}"
    base="${base%%-py[0-9]*}"
    printf '%s' "$base"
}

# version from a dist-info/egg-info dir name without knowing the pkg name
py_meta_version_any() {
    local base="${1##*/}"
    base="${base%.dist-info}"
    base="${base%.egg-info}"
    base="${base%%-py[0-9]*}"
    if [[ "$base" =~ ^(.+)-([0-9].*)$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

py_pkg_dir_version() {
    local d="$1" v="$2"
    local parent="${d%/*}" m
    for m in "$parent/${v}-"*.dist-info "$parent/${v}-"*.egg-info "$parent/${v}.egg-info"; do
        if [[ -d "$m" ]]; then
            py_meta_version "$m" "$v"
            return
        fi
    done
}

req_versions() {
    local f="$1" pkg_re
    pkg_re="$(re_escape "$2")"
    grep -iE "^[[:space:]]*${pkg_re}[[:space:]]*(==|>=|<=|~=|>|<|!=)" "$f" 2>/dev/null \
        | sed -E "s/^[[:space:]]*${pkg_re}[[:space:]]*(==|>=|<=|~=|>|<|!=)[[:space:]]*//I" \
        | sed -E 's/[[:space:];,#].*$//'
}

pyproject_versions() {
    local f="$1" pkg_re
    pkg_re="$(re_escape "$2")"
    {
        grep -iE "^[[:space:]]*${pkg_re}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$f" 2>/dev/null \
            | sed -E 's/.*"([^"]+)"$/\1/'
        grep -oE "[\"']${pkg_re}[[:space:]]*(==|>=|<=|~=|>|<|!=)[^,\"']+" "$f" 2>/dev/null \
            | sed -E "s/.*${pkg_re}[[:space:]]*(==|>=|<=|~=|>|<|!=)[[:space:]]*//"
    }
}

py_manifest_versions() {
    local f="$1" pkg="$2"
    case "${f##*/}" in
        pyproject.toml) pyproject_versions "$f" "$pkg" | ver_list_join ;;
        *)              req_versions       "$f" "$pkg" | ver_list_join ;;
    esac
}

############################
# verdicts / hit recording
############################

verdict_for() {
    local idx="$1" vers="$2"
    local expr="${PKG_EXPRS[$idx]}"
    if [[ -z "$expr" ]]; then echo "INFO"; return; fi
    if [[ -z "$vers" ]]; then echo "UNKNOWN"; return; fi
    local v vs=() any_concrete=0 matched=0
    IFS=, read -ra vs <<<"$vers"
    for v in "${vs[@]}"; do
        v="$(trim "$v")"
        is_concrete "$v" || continue
        any_concrete=1
        if filter_match "$v" "$expr"; then matched=1; break; fi
    done
    if (( matched )); then echo "VULNERABLE"
    elif (( any_concrete )); then echo "OK"
    else echo "UNKNOWN"
    fi
}

verdict_tag() {
    case "$1" in
        VULNERABLE) printf '%s[VULN]%s'    "$RED"    "$RESET" ;;
        OK)         printf '%s[ OK ]%s'    "$GREEN"  "$RESET" ;;
        UNKNOWN)    printf '%s[????]%s'    "$YELLOW" "$RESET" ;;
        INFO)       printf '%s[INFO]%s'    "$CYAN"   "$RESET" ;;
    esac
}

# found IDX CATEGORY DETAIL [VERSIONS]
found() {
    mark_found
    local idx="$1" cat="$2" det="$3" ver="${4:-}"
    local det_one="${det//$'\n'/ ; }"
    det_one="${det_one//$'\t'/ }"
    local verdict
    verdict="$(verdict_for "$idx" "$ver")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$verdict" "$cat" "$det_one" "$ver" >> "$HITS_FILE"

    local ver_tag=""
    if [[ -n "$ver" ]]; then
        local v_disp="${ver//,/, v}"
        ver_tag=" ${DIM}(v${v_disp})${RESET}"
    fi
    clear_line
    local tag; tag="$(verdict_tag "$verdict")"
    if [[ "$det" == *$'\n'* ]]; then
        printf '%s %s%s%s %s%-24s%s%s\n' "$tag" "$MAGENTA" "${PKG_NAMES[$idx]}" "$RESET" "$BOLD" "$cat" "$RESET" "$ver_tag"
        printf '%s\n' "$det" | sed 's/^/        /'
    else
        printf '%s %s%-18s%s %s%-24s%s %s%s\n' \
            "$tag" "$MAGENTA" "${PKG_NAMES[$idx]}" "$RESET" "$BOLD" "$cat" "$RESET" "$det" "$ver_tag"
    fi
}

############################
# Phase 1 - filesystem walk
############################

t_start=$(date +%s)

title "Phase 1  -  Filesystem walk"
log "Walking ${SEARCH_ROOT} (single pass, shared by all ${#PKG_NAMES[@]} package(s))..."
spinner_start "scanning filesystem"
do_walk > "$WALK_FILE"
spinner_stop

NM_DIRS=()
SP_DIRS=()
NPM_MANIFESTS=()
PY_MANIFESTS=()

while IFS= read -r p; do
    case "$p" in
        */node_modules)
            NM_DIRS+=("$p") ;;
        */site-packages|*/dist-packages)
            SP_DIRS+=("$p") ;;
        */package-lock.json|*/npm-shrinkwrap.json|*/pnpm-lock.yaml|*/yarn.lock|*/package.json)
            NPM_MANIFESTS+=("$p") ;;
        *)
            PY_MANIFESTS+=("$p") ;;
    esac
done < "$WALK_FILE"

GLOBAL_NMS=()
while read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && { NM_DIRS+=("$d"); GLOBAL_NMS+=("$d"); }
done < <(npm_global_roots)
while read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && SP_DIRS+=("$d")
done < <(python_interp_site_dirs)

mapfile -t NM_DIRS       < <(printf '%s\n' "${NM_DIRS[@]+"${NM_DIRS[@]}"}"             | awk 'NF && !seen[$0]++')
mapfile -t SP_DIRS       < <(printf '%s\n' "${SP_DIRS[@]+"${SP_DIRS[@]}"}"             | awk 'NF && !seen[$0]++')
mapfile -t NPM_MANIFESTS < <(printf '%s\n' "${NPM_MANIFESTS[@]+"${NPM_MANIFESTS[@]}"}" | awk 'NF && !seen[$0]++')
mapfile -t PY_MANIFESTS  < <(printf '%s\n' "${PY_MANIFESTS[@]+"${PY_MANIFESTS[@]}"}"   | awk 'NF && !seen[$0]++')

t_walk=$(date +%s)
log "Walk complete in $(( t_walk - t_start ))s"
printf '       %s%-22s%s %d\n' "$DIM" "node_modules dirs:"  "$RESET" "${#NM_DIRS[@]}"
printf '       %s%-22s%s %d\n' "$DIM" "site-packages dirs:" "$RESET" "${#SP_DIRS[@]}"
printf '       %s%-22s%s %d\n' "$DIM" "npm manifests:"      "$RESET" "${#NPM_MANIFESTS[@]}"
printf '       %s%-22s%s %d\n' "$DIM" "python manifests:"   "$RESET" "${#PY_MANIFESTS[@]}"

############################
# Phase 2 - NPM
############################

scan_nm_dir_exact() {
    local d="$1" idx="$2" v ver hit
    local variants=()
    IFS=' ' read -ra variants <<<"${PKG_VARIANTS[$idx]}"
    for v in "${variants[@]}"; do
        if [[ -d "$d/$v" ]]; then
            ver=""
            [[ -f "$d/$v/package.json" ]] && ver="$(pkgjson_own_version "$d/$v/package.json")"
            found "$idx" "npm package dir" "$d/$v" "$ver"
        fi
        for hit in "$d"/@*/"$v"; do
            if [[ -d "$hit" ]]; then
                ver=""
                [[ -f "$hit/package.json" ]] && ver="$(pkgjson_own_version "$hit/package.json")"
                found "$idx" "npm scoped package dir" "$hit" "$ver"
            fi
        done
    done
}

scan_nm_dir_contains() {
    local d="$1" idx="$2" hit ver
    local needle="${PKG_NEEDLES[$idx]}"
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        ver=""
        [[ -f "$hit/package.json" ]] && ver="$(pkgjson_own_version "$hit/package.json")"
        found "$idx" "npm package dir" "$hit" "$ver"
    done < <(
        find "$d" -mindepth 1 -maxdepth 1 -type d -iname "*${needle}*" ! -name '.*' ! -name '@*' 2>/dev/null
        find "$d" -mindepth 2 -maxdepth 2 -type d -path "$d/@*/*" -iname "*${needle}*" 2>/dev/null
    )
}

# Structurally anchored presence test - replaces the old raw substring
# grep that false-positived on repo URLs (protobuf.js.git), maintainer
# emails (dcode+protobufjs@...) and scoped helper names (@protobufjs/*).
npm_manifest_presence() {
    local f="$1" v="$2" vre base
    vre="$(re_escape "$v")"
    base="${f##*/}"
    case "$base" in
        package.json)
            # dependency key or own name only
            grep -Eiq "\"${vre}\"[[:space:]]*:" "$f" 2>/dev/null ;;
        package-lock.json|npm-shrinkwrap.json)
            grep -Eiq "\"(node_modules/)?${vre}\"[[:space:]]*:" "$f" 2>/dev/null ;;
        yarn.lock)
            # header entries: pkg@range - '@scope/pkg' must NOT match
            grep -Eiq "(^|[\", ])${vre}@" "$f" 2>/dev/null ;;
        pnpm-lock.yaml)
            # v9: pkg@1.2.3:   v5/6: /pkg/1.2.3:   exclude @scope/ prefixes
            grep -Eiq "(^|[^@/[:alnum:]._-])${vre}@[0-9]|(^|[[:space:]\"'])/${vre}/[0-9]" "$f" 2>/dev/null ;;
        *)  grep -Fqi -- "$v" "$f" 2>/dev/null ;;
    esac
}

npm_manifest_check() {
    local f="$1" idx="$2" v ver info secs cat
    if [[ "${PKG_MODES[$idx]}" == "contains" ]]; then
        # discovery mode is intentionally fuzzy
        if grep -Fqi -- "${PKG_NEEDLES[$idx]}" "$f" 2>/dev/null; then
            found "$idx" "npm manifest ref" "$f" ""
        fi
        return
    fi
    local variants=()
    IFS=' ' read -ra variants <<<"${PKG_VARIANTS[$idx]}"
    local base="${f##*/}"

    # 0) cheap coarse gate. If not a single name variant appears anywhere in
    #    the file (substring, case-insensitive), there is nothing to extract -
    #    bail before spawning a JSON parser. This is ONE grep per (file,pkg),
    #    replacing the python-spawn-per-(file,pkg,variant) that made the scan
    #    blow up across thousands of manifests. The structural greps and
    #    extractors below only run on the handful of files that pass here.
    local gate=()
    for v in "${variants[@]}"; do gate+=( -e "$v" ); done
    (( ${#gate[@]} > 0 )) && { grep -Fqi "${gate[@]}" -- "$f" 2>/dev/null || return; }

    # 1) package.json that IS the package (vendored copies, bun/pnpm caches)
    if [[ "$base" == "package.json" ]]; then
        for v in "${variants[@]}"; do
            if pkgjson_is_pkg "$f" "$v"; then
                ver="$(pkgjson_own_version "$f")"
                found "$idx" "npm manifest (pkg itself)" "$f" "$ver"
                return
            fi
        done
    fi

    # 2) precise extraction (lockfiles resolve concrete versions;
    #    package.json gives declared ranges + their sections)
    for v in "${variants[@]}"; do
        if [[ "$base" == "package.json" ]]; then
            info="$(pkgjson_dep_info "$f" "$v")"
            if [[ -n "$info" ]]; then
                ver="$(printf '%s\n' "$info" | cut -f1 | ver_list_join)"
                secs="$(printf '%s\n' "$info" | cut -f2 | tr '+' '\n' | awk 'NF && !seen[$0]++' | paste -sd '+' -)"
                cat="npm manifest ref"
                [[ "$secs" == "devDependencies" ]] && cat="npm manifest ref (devDeps only)"
                found "$idx" "$cat" "$f" "$ver"
                return
            fi
        else
            ver="$(npm_manifest_versions "$f" "$v")"
            if [[ -n "$ver" ]]; then
                found "$idx" "npm manifest ref" "$f" "$ver"
                return
            fi
        fi
    done

    # 3) anchored presence without extractable version -> honest UNKNOWN
    for v in "${variants[@]}"; do
        if npm_manifest_presence "$f" "$v"; then
            found "$idx" "npm manifest ref" "$f" ""
            return
        fi
    done
}

check_npm() {
    title "Phase 2  -  NPM"
    local idx out ver pkg pkg_re

    if (( HAVE_NPM )); then
        for idx in "${!PKG_NAMES[@]}"; do
            pkg="${PKG_NAMES[$idx]}"
            log "npm ls ${pkg} (current working dir)..."
            pkg_re="$(re_escape "$pkg")"
            if out="$(npm ls "$pkg" --all 2>/dev/null)" \
                && grep -qi -- "$pkg" <<<"$out"; then
                ver="$(printf '%s\n' "$out" | grep -oE -- "${pkg_re}@[^[:space:]]+" \
                        | sed -E "s/.*${pkg_re}@//" | ver_list_join)"
                found "$idx" "npm ls (current project)" "$(head -n 30 <<<"$out")" "$ver"
            else
                ok "npm ls: ${pkg} not present in current project"
            fi
            # advisory name might differ from registry name -> retry collapsed
            if [[ "${PKG_COLLAPSED[$idx]}" != "$pkg" && "${PKG_MODES[$idx]}" == "exact" ]]; then
                pkg="${PKG_COLLAPSED[$idx]}"
                pkg_re="$(re_escape "$pkg")"
                if out="$(npm ls "$pkg" --all 2>/dev/null)" \
                    && grep -qi -- "$pkg" <<<"$out"; then
                    ver="$(printf '%s\n' "$out" | grep -oE -- "${pkg_re}@[^[:space:]]+" \
                            | sed -E "s/.*${pkg_re}@//" | ver_list_join)"
                    found "$idx" "npm ls (current project)" "$(head -n 30 <<<"$out")" "$ver"
                fi
            fi
        done
    else
        warn "npm not installed - skipping npm ls"
    fi

    if (( ${#NM_DIRS[@]} > 0 )); then
        log "Scanning ${#NM_DIRS[@]} node_modules directories..."
        NM_SCANNED=${#NM_DIRS[@]}
        local total=${#NM_DIRS[@]} i=0 d
        for d in "${NM_DIRS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "npm dirs"
            for idx in "${!PKG_NAMES[@]}"; do
                if [[ "${PKG_MODES[$idx]}" == "contains" ]]; then
                    scan_nm_dir_contains "$d" "$idx"
                else
                    scan_nm_dir_exact "$d" "$idx"
                fi
            done
        done
        clear_line
        ok "node_modules scan complete"
    fi

    if (( ${#NPM_MANIFESTS[@]} > 0 )); then
        log "Scanning ${#NPM_MANIFESTS[@]} npm manifests..."
        NPM_MAN_SCANNED=${#NPM_MANIFESTS[@]}
        local total=${#NPM_MANIFESTS[@]} i=0 f
        for f in "${NPM_MANIFESTS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "npm manifests"
            for idx in "${!PKG_NAMES[@]}"; do
                npm_manifest_check "$f" "$idx"
            done
        done
        clear_line
        ok "npm manifest scan complete"
    fi
}

############################
# Phase 3 - Python
############################

scan_sp_dir_exact() {
    local d="$1" idx="$2" v ver hit
    local variants=()
    IFS=' ' read -ra variants <<<"${PKG_VARIANTS[$idx]}"
    for v in "${variants[@]}"; do
        if [[ -d "$d/$v" ]]; then
            ver="$(py_pkg_dir_version "$d/$v" "$v")"
            found "$idx" "python package dir" "$d/$v" "$ver"
        fi
        for hit in "$d/${v}-"*.dist-info "$d/${v}-"*.egg-info "$d/${v}.egg-info"; do
            if [[ -d "$hit" ]]; then
                ver="$(py_meta_version "$hit" "$v")"
                found "$idx" "python metadata dir" "$hit" "$ver"
            fi
        done
    done
}

scan_sp_dir_contains() {
    local d="$1" idx="$2" hit ver
    local needle="${PKG_NEEDLES[$idx]}"
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        case "$hit" in
            *.dist-info|*.egg-info)
                ver="$(py_meta_version_any "$hit")"
                found "$idx" "python metadata dir" "$hit" "$ver" ;;
            *)
                found "$idx" "python package dir" "$hit" "" ;;
        esac
    done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -iname "*${needle}*" 2>/dev/null)
}

py_manifest_check() {
    local f="$1" idx="$2" v ver vre
    if [[ "${PKG_MODES[$idx]}" == "contains" ]]; then
        if grep -Fqi -- "${PKG_NEEDLES[$idx]}" "$f" 2>/dev/null; then
            found "$idx" "python manifest ref" "$f" ""
        fi
        return
    fi
    local variants=()
    IFS=' ' read -ra variants <<<"${PKG_VARIANTS[$idx]}"
    # 0) cheap coarse gate (see npm_manifest_check) - skip files that don't
    #    even mention the name before running the per-variant extractors.
    local gate=()
    for v in "${variants[@]}"; do gate+=( -e "$v" ); done
    (( ${#gate[@]} > 0 )) && { grep -Fqi "${gate[@]}" -- "$f" 2>/dev/null || return; }
    # 1) precise extraction
    for v in "${variants[@]}"; do
        ver="$(py_manifest_versions "$f" "$v")"
        if [[ -n "$ver" ]]; then
            found "$idx" "python manifest ref" "$f" "$ver"
            return
        fi
    done
    # 2) anchored presence: name as a requirement token, not inside
    #    URLs/emails/longer names
    for v in "${variants[@]}"; do
        vre="$(re_escape "$v")"
        if grep -Eiq "(^|[\"'[:space:]])${vre}([[:space:]]*([=<>~!;,#[]|$)|[\"'])" "$f" 2>/dev/null; then
            found "$idx" "python manifest ref" "$f" ""
            return
        fi
    done
}

# --- requirements resolution (transitive deps) ---------------------------
# A plain requirements.txt lists only top-level deps. Resolving it with
# `uv pip compile` (fast, preferred) or `pip-compile` yields the FULL pinned
# tree, so vulnerable transitive deps become visible. Output goes to a temp
# dir only - project files are never touched. Resolution reflects what a
# fresh install would fetch TODAY, which may differ from the installed state
# (the installed state is covered by the site-packages / pip-show scans).

resolve_requirements() { # src dst -> 0 on success (dst holds pinned tree;
                         # on failure dst.err holds the resolver's stderr)
    local src="$1" dst="$2"
    local dir="${src%/*}" base="${src##*/}"
    [[ "$dir" == "$src" ]] && dir="."
    # run inside the file's dir so '-r other.txt' / '-c ...' includes resolve
    if (( HAVE_UV )); then
        if ( cd "$dir" 2>/dev/null && \
             timeout 90 uv pip compile -q --no-header --no-annotate "$base" \
           ) > "$dst" 2>"$dst.err" && [[ -s "$dst" ]]; then
            return 0
        fi
    fi
    if (( HAVE_PIPCOMPILE )); then
        if ( cd "$dir" 2>/dev/null && \
             timeout 300 pip-compile -q --no-header --no-annotate -o - "$base" \
           ) > "$dst" 2>>"$dst.err" && [[ -s "$dst" ]]; then
            return 0
        fi
    fi
    return 1
}

resolve_fail_reason() { # errfile -> one short human line on stdout
    local lines l1 l2
    lines="$(grep -vE '^[[:space:]]*$' -- "$1" 2>/dev/null | head -2 \
        | sed -E 's/^[^A-Za-z0-9]+//; s/^(error|ERROR):[[:space:]]*//')"
    l1="$(printf '%s\n' "$lines" | sed -n 1p)"
    l2="$(printf '%s\n' "$lines" | sed -n 2p)"
    # only pull in the continuation line when the first one is a lead-in
    # ("No solution found when resolving dependencies:")
    [[ "$l1" == *: && -n "$l2" ]] && l1="$l1 $l2"
    printf '%s' "${l1:0:160}"
}

# Package-manager caches, vendored test data etc. are not real projects -
# resolving their requirements files is pointless (and often impossible).
# They still get the normal top-level manifest scan, only resolution skips.
is_cache_requirements() {
    case "$1" in
        */miniconda*/pkgs/*|*/anaconda*/pkgs/*|*/conda/pkgs/*|*/mamba*/pkgs/*|\
        */.cache/*|*/.venv/*|*/venv/lib/*|*/virtualenvs/*|*/.tox/*|*/.nox/*|\
        */info/test/*|*/.eggs/*|*/vendor/*|*/vendored/*)
            return 0 ;;
    esac
    return 1
}

scan_resolved_file() { # orig_file compiled_file
    local f="$1" rf="$2" idx v ver
    for idx in "${!PKG_NAMES[@]}"; do
        if [[ "${PKG_MODES[$idx]}" == "contains" ]]; then
            if grep -Fqi -- "${PKG_NEEDLES[$idx]}" "$rf" 2>/dev/null; then
                found "$idx" "python resolved ref" "$f" ""
            fi
            continue
        fi
        local variants=() gate=()
        IFS=' ' read -ra variants <<<"${PKG_VARIANTS[$idx]}"
        for v in "${variants[@]}"; do gate+=( -e "$v" ); done
        grep -Fqi "${gate[@]}" -- "$rf" 2>/dev/null || continue
        for v in "${variants[@]}"; do
            ver="$(req_versions "$rf" "$v" | ver_list_join)"
            [[ -z "$ver" ]] && continue
            if grep -Fqi "${gate[@]}" -- "$f" 2>/dev/null; then
                # also listed top-level - the manifest scan saw it; this
                # adds the concretely resolved pin
                found "$idx" "python resolved pin" "$f" "$ver"
            else
                found "$idx" "python resolved transitive" \
                    "$f"$'\n'"(transitive dep - not listed in ${f##*/} itself; a fresh 'pip install -r' TODAY would pull this version. Whether it is currently installed is covered by the site-packages/pip scan.)" \
                    "$ver"
            fi
            break
        done
    done
}

resolve_and_scan_requirements() {
    local reqs=() f
    for f in "${PY_MANIFESTS[@]+"${PY_MANIFESTS[@]}"}"; do
        case "${f##*/}" in requirements*.txt|requirements*.in) reqs+=("$f") ;; esac
    done
    (( ${#reqs[@]} == 0 )) && return
    if (( NO_PIPCOMPILE )); then
        log "requirements resolution skipped (--no-pip-compile)"
        return
    fi
    if (( NO_REGISTRY )); then
        log "requirements resolution skipped (needs network, --no-registry given)"
        return
    fi
    if [[ -z "$RESOLVER" ]]; then
        warn "neither uv nor pip-compile found - ${#reqs[@]} requirements file(s) scanned as written only; transitive deps NOT checked (install uv or pip-tools)"
        return
    fi
    log "Resolving ${#reqs[@]} requirements file(s) with ${RESOLVER} (full dependency tree)..."
    local total=${#reqs[@]} i=0 out ndeps npinned label
    for f in "${reqs[@]}"; do
        ((i++)) || true
        if is_cache_requirements "$f"; then
            REQ_SKIPPED_CACHE=$(( REQ_SKIPPED_CACHE + 1 ))
            continue
        fi
        # already a pip-compile/uv lockfile -> fully pinned, the normal
        # manifest scan already sees everything; no need to re-resolve
        if head -5 -- "$f" 2>/dev/null | grep -qiE 'autogenerated by (pip-compile|uv)'; then
            REQ_ALREADY_PINNED=$(( REQ_ALREADY_PINNED + 1 ))
            continue
        fi
        # top-level dep count (non-comment/-option lines) -> honest feedback
        # while the resolver works; big trees can take a while and would
        # otherwise look like a hang
        ndeps="$(grep -cvE '^[[:space:]]*(#|-|$)' -- "$f" 2>/dev/null)"
        [[ "$ndeps" =~ ^[0-9]+$ ]] || ndeps=0
        label="[$i/$total] ${f##*/}: ${ndeps} top-level dep(s), resolving full tree"
        (( ndeps >= 15 )) && label+=" - big file, this can take a while"
        spinner_start "$label"
        out="$RESOLVE_TMP/resolved-$i.txt"
        if resolve_requirements "$f" "$out"; then
            spinner_stop
            REQ_RESOLVED=$(( REQ_RESOLVED + 1 ))
            npinned="$(grep -cE '==' -- "$out" 2>/dev/null)"
            printf '  %s[%d/%d] %s: %s top-level dep(s) -> %s package(s) in the full tree%s\n' \
                "$DIM" "$i" "$total" "$f" "$ndeps" "${npinned:-?}" "$RESET"
            scan_resolved_file "$f" "$out"
        else
            spinner_stop
            REQ_RESOLVE_FAILED=$(( REQ_RESOLVE_FAILED + 1 ))
            RESOLVE_FAILED_LIST+=("$f"$'\t'"$(resolve_fail_reason "$out.err")")
        fi
    done
    clear_line
    ok "requirements resolution complete (${REQ_RESOLVED} resolved, ${REQ_RESOLVE_FAILED} failed, ${REQ_ALREADY_PINNED} already pinned, ${REQ_SKIPPED_CACHE} cache/vendored skipped)"
    if (( REQ_RESOLVE_FAILED > 0 )); then
        warn "${REQ_RESOLVE_FAILED} requirements file(s) could NOT be resolved - their transitive deps remain unchecked (top-level deps were still scanned):"
        local entry reason
        for entry in "${RESOLVE_FAILED_LIST[@]}"; do
            f="${entry%%$'\t'*}"
            reason="${entry#*$'\t'}"
            [[ "$reason" == "$entry" ]] && reason=""
            printf '       %s%s%s\n' "$DIM" "$f" "$RESET"
            [[ -n "$reason" ]] && printf '         %s-> %s%s\n' "$YELLOW" "$reason" "$RESET"
        done
        printf '  %s(common causes: old pins that no longer resolve together, missing local\n' "$DIM"
        printf '   path/-e packages, private indexes needing auth - fix or ignore per file)%s\n' "$RESET"
    fi
}

check_python() {
    title "Phase 3  -  Python"
    local idx py out ver detail pkg pkg_re

    while read -r py; do
        [[ -z "$py" ]] && continue
        for idx in "${!PKG_NAMES[@]}"; do
            pkg="${PKG_NAMES[$idx]}"
            log "pip show ${pkg} via $py..."
            if out="$("$py" -m pip show "$pkg" 2>/dev/null)" && [[ -n "$out" ]]; then
                ver="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="version"{print $2; exit}')"
                found "$idx" "pip installed ($py)" "$out" "$ver"
            fi
        done
    done < <(python_interpreters | awk 'NF && !seen[$0]++')

    if (( HAVE_PIPX )); then
        log "pipx list..."
        for idx in "${!PKG_NAMES[@]}"; do
            pkg="${PKG_NAMES[$idx]}"
            pkg_re="$(re_escape "$pkg")"
            if pipx list --short 2>/dev/null | grep -qi -- "$pkg"; then
                detail="$(pipx list 2>/dev/null | grep -i -- "$pkg" || true)"
                ver="$(printf '%s\n' "$detail" | grep -oiE "${pkg_re}[[:space:]]+[0-9][^[:space:],]*" \
                        | awk '{print $NF}' | ver_list_join)"
                found "$idx" "pipx installed" "$detail" "$ver"
            fi
        done
    fi

    if (( ${#SP_DIRS[@]} > 0 )); then
        log "Scanning ${#SP_DIRS[@]} site-packages directories..."
        SP_SCANNED=${#SP_DIRS[@]}
        local total=${#SP_DIRS[@]} i=0 d
        for d in "${SP_DIRS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "python dirs"
            for idx in "${!PKG_NAMES[@]}"; do
                if [[ "${PKG_MODES[$idx]}" == "contains" ]]; then
                    scan_sp_dir_contains "$d" "$idx"
                else
                    scan_sp_dir_exact "$d" "$idx"
                fi
            done
        done
        clear_line
        ok "site-packages scan complete"
    fi

    if (( ${#PY_MANIFESTS[@]} > 0 )); then
        log "Scanning ${#PY_MANIFESTS[@]} python manifests..."
        PY_MAN_SCANNED=${#PY_MANIFESTS[@]}
        local total=${#PY_MANIFESTS[@]} i=0 f
        for f in "${PY_MANIFESTS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "python manifests"
            for idx in "${!PKG_NAMES[@]}"; do
                py_manifest_check "$f" "$idx"
            done
        done
        clear_line
        ok "python manifest scan complete"
    fi

    resolve_and_scan_requirements
}

############################
# run scan
############################

case "$MODE" in
    npm)    check_npm ;;
    python) check_python ;;
    both)   check_npm; check_python ;;
esac

############################
# summary
############################

t_end=$(date +%s)
dur=$(( t_end - t_start ))
total_hits=$(wc -l < "$HITS_FILE" 2>/dev/null | tr -d ' ')
[[ -z "$total_hits" ]] && total_hits=0
total_scanned=$(( NM_SCANNED + SP_SCANNED + NPM_MAN_SCANNED + PY_MAN_SCANNED ))

pkg_count() { # idx verdict -> count
    awk -F'\t' -v i="$1" -v v="$2" '$1==i && $2==v {n++} END {print n+0}' "$HITS_FILE"
}

VULN_TOTAL=$(awk -F'\t' '$2=="VULNERABLE"{n++} END{print n+0}' "$HITS_FILE")
UNK_TOTAL=$(awk  -F'\t' '$2=="UNKNOWN"{n++}    END{print n+0}' "$HITS_FILE")
INFO_TOTAL=$(awk -F'\t' '$2=="INFO"{n++}       END{print n+0}' "$HITS_FILE")

title "Summary"
printf '  %s%-16s%s %s\n'  "$DIM" "Mode:"     "$RESET" "$MODE"
printf '  %s%-16s%s %s\n'  "$DIM" "Root:"     "$RESET" "$SEARCH_ROOT"
printf '  %s%-16s%s %ds\n' "$DIM" "Duration:" "$RESET" "$dur"
printf '  %s%-16s%s %d items (%d node_modules, %d npm manifests, %d site-packages, %d python manifests)\n' \
    "$DIM" "Scanned:" "$RESET" "$total_scanned" \
    "$NM_SCANNED" "$NPM_MAN_SCANNED" "$SP_SCANNED" "$PY_MAN_SCANNED"
if (( REQ_RESOLVED + REQ_RESOLVE_FAILED + REQ_ALREADY_PINNED + REQ_SKIPPED_CACHE > 0 )); then
    res_col="$DIM"
    (( REQ_RESOLVE_FAILED > 0 )) && res_col="$YELLOW"
    printf '  %s%-16s%s %s%d requirements file(s) resolved to full trees (%s), %d already pinned, %d cache/vendored skipped, %d FAILED (transitive deps unchecked)%s\n' \
        "$DIM" "Resolved:" "$RESET" "$res_col" \
        "$REQ_RESOLVED" "${RESOLVER:-n/a}" "$REQ_ALREADY_PINNED" "$REQ_SKIPPED_CACHE" "$REQ_RESOLVE_FAILED" "$RESET"
fi
echo
printf '  %s%-22s %6s %6s %6s %8s %6s%s\n' "$BOLD" "Package" "hits" "VULN" "OK" "UNKNOWN" "INFO" "$RESET"
for idx in "${!PKG_NAMES[@]}"; do
    h=$(awk -F'\t' -v i="$idx" '$1==i {n++} END {print n+0}' "$HITS_FILE")
    nv=$(pkg_count "$idx" VULNERABLE)
    nk=$(pkg_count "$idx" OK)
    nu=$(pkg_count "$idx" UNKNOWN)
    ni=$(pkg_count "$idx" INFO)
    col="$GREEN"
    (( nu > 0 || ni > 0 )) && col="$YELLOW"
    (( nv > 0 )) && col="$RED"
    printf '  %s%-22s %6d %6d %6d %8d %6d%s\n' "$col" "${PKG_NAMES[$idx]}" "$h" "$nv" "$nk" "$nu" "$ni" "$RESET"
done

############################
# registry lookup (fix versions)
############################

declare -A REG_STATUS=()   # key "idx:eco" -> ok|nofix|offline|notfound|skipped
declare -A REG_FIX=()      # key "idx:eco" -> recommended fixed version
declare -A REG_LATEST=()   # key "idx:eco" -> latest safe version
declare -A REG_NAME=()     # key "idx:eco" -> name that resolved on the registry

pkg_has_vuln() {
    awk -F'\t' -v i="$1" '$1==i && $2=="VULNERABLE" {found=1; exit} END {exit !found}' "$HITS_FILE"
}

pkg_vuln_ecos() { # idx -> lines: npm / py
    awk -F'\t' -v i="$1" '$1==i && $2=="VULNERABLE" {
        if ($3 ~ /^npm/) print "npm"; else print "py"
    }' "$HITS_FILE" | sort -u
}

pkg_vuln_max_installed() { # idx eco -> highest concrete vulnerable version
    local idx="$1" eco="$2" line vers v best=""
    while IFS=$'\t' read -r _ verdict cat _ vers; do
        [[ "$verdict" == "VULNERABLE" ]] || continue
        if [[ "$eco" == "npm" ]]; then [[ "$cat" == npm* ]] || continue
        else [[ "$cat" == npm* ]] && continue; fi
        local vs=()
        IFS=, read -ra vs <<<"$vers"
        for v in "${vs[@]}"; do
            v="$(trim "$v")"
            is_concrete "$v" || continue
            filter_match "$v" "${PKG_EXPRS[$idx]}" || continue
            if [[ -z "$best" || "$(ver_cmp "$v" "$best")" == "1" ]]; then best="$v"; fi
        done
    done < <(awk -F'\t' -v i="$idx" '$1==i' "$HITS_FILE")
    printf '%s' "$best"
}

fetch_registry_versions() { # eco name -> version lines (numeric releases only)
    local eco="$1" name="$2" url body
    if [[ "$eco" == "npm" ]]; then
        url="https://registry.npmjs.org/${name//\//%2F}"
    else
        url="https://pypi.org/pypi/${name}/json"
    fi
    body="$(curl -fsSL --max-time 25 "$url" 2>/dev/null)" || return 1
    if (( HAVE_PYTHON3 )); then
        printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
keys = (d.get("versions") or d.get("releases") or {}).keys()
for k in keys:
    print(k)
' 2>/dev/null
    else
        printf '%s' "$body" | grep -oE '"[0-9]+(\.[0-9]+)+[^"]*"[[:space:]]*:' \
            | sed -E 's/^"//; s/"[[:space:]]*:$//'
    fi
}

recommend_fix() { # installed_max ; stdin: safe versions (sorted -V)
    local inst="$1" v best_same="" best_any=""
    local imaj="${inst%%.*}"
    while read -r v; do
        [[ -z "$v" ]] && continue
        [[ "$(ver_cmp "$v" "$inst")" == "1" ]] || continue
        [[ -z "$best_any" ]] && best_any="$v"
        if [[ "${v%%.*}" == "$imaj" && -z "$best_same" ]]; then best_same="$v"; fi
    done
    printf '%s' "${best_same:-$best_any}"
}

pkg_installed_concrete() { # idx -> all distinct concrete versions seen in hits
    local vers v
    while IFS=$'\t' read -r _ _ _ _ vers; do
        local vs=()
        IFS=, read -ra vs <<<"$vers"
        for v in "${vs[@]+"${vs[@]}"}"; do
            v="$(trim "$v")"
            is_concrete "$v" && printf '%s\n' "$(ver_normalize "$v")"
        done
    done < <(awk -F'\t' -v i="$1" '$1==i' "$HITS_FILE") | awk 'NF && !seen[$0]++'
}

# Does the registry version list contain at least one locally seen version?
list_matches_installed() { # versions_list installed_list
    local rv iv
    while read -r iv; do
        [[ -z "$iv" ]] && continue
        while read -r rv; do
            [[ -z "$rv" ]] && continue
            [[ "$(ver_normalize "$rv")" == "$iv" ]] && return 0
        done <<<"$1"
    done <<<"$2"
    return 1
}

do_registry() {
    title "Fix lookup (npm / PyPI)"
    if (( NO_REGISTRY )); then
        log "skipped (--no-registry)"
        return
    fi
    if (( ! HAVE_CURL )); then
        warn "curl not available - skipping registry lookup"
        return
    fi
    local idx eco name cand list installed safe inst fix latest key any=0
    for idx in "${!PKG_NAMES[@]}"; do
        [[ -n "${PKG_EXPRS[$idx]}" ]] || continue
        pkg_has_vuln "$idx" || continue
        any=1
        installed="$(pkg_installed_concrete "$idx")"
        while read -r eco; do
            [[ -z "$eco" ]] && continue
            key="$idx:$eco"
            # candidate names: as given, then separator-collapsed.
            # Cross-check each list against the versions actually found on
            # disk - npm hosts unrelated packages under lookalike names
            # (e.g. 'protobuf.js' is an abandoned 0.0.x package, the real
            # library is 'protobufjs').
            name=""
            list=""
            local tried=()
            for cand in "${PKG_NAMES[$idx]}" "${PKG_COLLAPSED[$idx]}"; do
                local seen_c=0 t
                for t in "${tried[@]+"${tried[@]}"}"; do [[ "$t" == "$cand" ]] && seen_c=1; done
                (( seen_c )) && continue
                tried+=("$cand")
                log "querying $eco registry for ${cand}..."
                local clist
                clist="$(fetch_registry_versions "$eco" "$cand")" || clist=""
                [[ -z "$clist" ]] && continue
                if [[ -z "$name" ]]; then name="$cand"; list="$clist"; fi
                if [[ -n "$installed" ]] && list_matches_installed "$clist" "$installed"; then
                    if [[ "$cand" != "$name" ]]; then
                        warn "  '${name}' exists on the registry but does NOT contain your installed version(s) - using '${cand}' instead (its releases match what is on disk)"
                    fi
                    name="$cand"; list="$clist"
                    break
                fi
            done
            if [[ -z "$list" ]]; then
                REG_STATUS[$key]="offline"
                REG_NAME[$key]="${PKG_NAMES[$idx]}"
                warn "  no registry data for '${PKG_NAMES[$idx]}' ($eco) - offline or name not found"
                continue
            fi
            if [[ -n "$installed" ]] && ! list_matches_installed "$list" "$installed"; then
                warn "  registry package '${name}' does not contain the version(s) found on disk - possible name mismatch, treat the recommendation below with care"
            fi
            REG_NAME[$key]="$name"
            safe="$(printf '%s\n' "$list" \
                | grep -E '^[0-9]+(\.[0-9]+)*$' \
                | while read -r v; do
                      filter_match "$v" "${PKG_EXPRS[$idx]}" || printf '%s\n' "$v"
                  done \
                | sort -V)"
            inst="$(pkg_vuln_max_installed "$idx" "$eco")"
            [[ -z "$inst" ]] && inst="0.0.0"
            fix="$(printf '%s\n' "$safe" | recommend_fix "$inst")"
            latest="$(printf '%s\n' "$safe" | tail -1)"
            REG_LATEST[$key]="$latest"
            if [[ -n "$fix" ]]; then
                REG_STATUS[$key]="ok"
                REG_FIX[$key]="$fix"
                printf '  %s%-22s%s %s (as %s%s%s): installed vulnerable max %sv%s%s -> fixed in %sv%s%s' \
                    "$MAGENTA" "${PKG_NAMES[$idx]}" "$RESET" "$eco" \
                    "$BOLD" "$name" "$RESET" \
                    "$YELLOW" "$inst" "$RESET" "$GREEN" "$fix" "$RESET"
                [[ -n "$latest" && "$latest" != "$fix" ]] && printf '  %s(latest safe: v%s)%s' "$DIM" "$latest" "$RESET"
                echo
            else
                REG_STATUS[$key]="nofix"
                printf '  %s%-22s%s %s (as %s%s%s): %sNO fixed release above v%s found on the registry%s\n' \
                    "$MAGENTA" "${PKG_NAMES[$idx]}" "$RESET" "$eco" \
                    "$BOLD" "$name" "$RESET" "$RED" "$inst" "$RESET"
                if [[ -n "$latest" ]]; then
                    printf '      %s(latest non-vulnerable release overall: v%s - a downgrade)%s\n' "$DIM" "$latest" "$RESET"
                fi
                printf '      %sRecommendation: do not start/deploy the affected project(s) until a fix is available.%s\n' "$BOLD" "$RESET"
            fi
        done < <(pkg_vuln_ecos "$idx")
    done
    (( any )) || log "no VULNERABLE hits - nothing to look up"
}

(( total_hits > 0 )) && do_registry

############################
# exports
############################

json_escape_py() { (( HAVE_PYTHON3 )); }

export_findings() { # dir -> writes findings TSV (+ JSON if python3)
    local dir="$1" ts base tsv
    ts="$(date '+%Y%m%d-%H%M%S')"
    base="$dir/scan-findings-$ts"
    tsv="$base.tsv"
    {
        printf 'package\tverdict\tcategory\tdetail\tversions\tvuln_expr\n'
        while IFS=$'\t' read -r idx verdict cat det ver; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${PKG_NAMES[$idx]}" "$verdict" "$cat" "$det" "$ver" "${PKG_EXPRS[$idx]}"
        done < "$HITS_FILE"
    } > "$tsv"
    ok "findings written: $tsv"
    if json_escape_py; then
        REG_DUMP=""
        for key in "${!REG_STATUS[@]}"; do
            idx="${key%%:*}"; eco="${key##*:}"
            REG_DUMP+="${PKG_NAMES[$idx]}"$'\t'"$eco"$'\t'"${REG_STATUS[$key]}"$'\t'"${REG_FIX[$key]:-}"$'\t'"${REG_LATEST[$key]:-}"$'\n'
        done
        python3 - "$tsv" "$base.json" "$MODE" "$SEARCH_ROOT" "$VERSION" <<PY
import csv, json, sys, datetime
tsv, out, mode, root, ver = sys.argv[1:6]
hits = []
with open(tsv) as f:
    for row in csv.DictReader(f, delimiter="\t"):
        hits.append(row)
reg = []
for line in """$REG_DUMP""".splitlines():
    p = line.split("\t")
    if len(p) >= 5:
        reg.append({"package": p[0], "ecosystem": p[1], "status": p[2],
                    "recommended_fix": p[3] or None, "latest_safe": p[4] or None})
doc = {
    "tool": "scan-for-package.sh",
    "tool_version": ver,
    "generated": datetime.datetime.now().isoformat(timespec="seconds"),
    "mode": mode,
    "search_root": root,
    "hits": hits,
    "registry": reg,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
print(out)
PY
        ok "findings written: $base.json"
    fi
}

export_update_script() { # dir
    local dir="$1" ts out
    ts="$(date '+%Y%m%d-%H%M%S')"
    out="$dir/update-vulnerable-packages-$ts.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by scan-for-package.sh v%s on %s\n' "$VERSION" "$(date)"
        printf '#\n'
        printf '# >>> BEST-EFFORT UPDATE ATTEMPT - NOT A GUARANTEE <<<\n'
        printf '# Review every line before running. Lockfiles, peer deps, pinned\n'
        printf '# ranges, monorepos or container images may need manual handling.\n'
        printf '# Re-run the scanner afterwards to verify.\n'
        cat <<'GEN'
set -uo pipefail

# ---- colors via tput (terminfo) - keeps the script source escape-free ----
# tput emits the right control sequences at runtime from the terminal's
# capabilities; nothing is hard-coded. Auto-disabled when stdout is not a
# terminal (e.g. piped to a file or CI log), so the plain text stays clean.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_CYAN="$(tput setaf 6)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"; C_RESET="$(tput sgr0)"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

RUN_OK=0; RUN_FAIL=0
hr()       { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RESET"; }
announce() { printf '\n'; hr; printf '%s> %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
verdict()  {   # rc  description-of-command
    local rc="$1"; shift
    if (( rc == 0 )); then
        printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
        RUN_OK=$(( RUN_OK + 1 ))
    else
        printf '%s[FAIL]%s %s %s(exit %s)%s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" "$C_RED" "$rc" "$C_RESET"
        RUN_FAIL=$(( RUN_FAIL + 1 ))
    fi
}

run() {   # run a command and color the result red/green
    announce "$*"
    local rc=0; "$@" || rc=$?
    verdict "$rc" "$*"
}

# --- best-effort Node version selection (nvm-aware) ---------------------
# Projects often pin a Node version via .nvmrc or package.json "engines".
# Installing under the wrong major can fail outright or mis-resolve deps,
# so before each project install we switch Node the way the project expects.
# Everything here degrades gracefully if nvm/node is absent (nvm needs
# 'set +u', hence the toggling).
NVM_LOADED=0
load_nvm() {
    (( NVM_LOADED )) && return 0
    local n; set +u
    for n in "${NVM_DIR:-$HOME/.nvm}/nvm.sh" "$HOME/.nvm/nvm.sh" \
             /usr/local/opt/nvm/nvm.sh /opt/homebrew/opt/nvm/nvm.sh; do
        if [[ -s "$n" ]]; then . "$n" >/dev/null 2>&1 && { NVM_LOADED=1; break; }; fi
    done
    set -u
    (( NVM_LOADED ))
}
use_project_node() {   # call from inside the project dir
    set +u
    if load_nvm; then
        local note="" cur_major
        cur_major="$(node -v 2>/dev/null | grep -oE '[0-9]+' | head -1)"
        if [[ -f .nvmrc ]]; then
            # explicit project intent - always honor it
            nvm use >/dev/null 2>&1 || { nvm install >/dev/null 2>&1 && nvm use >/dev/null 2>&1; } || true
            note=".nvmrc"
        elif [[ -f package.json ]]; then
            local eng min_major max_major want="" ok=1
            eng="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' package.json 2>/dev/null \
                   | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"[[:space:]]*$//')"
            if [[ -n "$eng" ]]; then
                # lower/upper bound majors from the range (>=18 / <=22 etc.)
                min_major="$(printf '%s' "$eng" | grep -oE '>=?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -n | head -1)"
                max_major="$(printf '%s' "$eng" | grep -oE '<=?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
                # bare "18"/"20.x" with no comparator -> treat as a minimum
                [[ -z "$min_major" && -z "$max_major" ]] && \
                    min_major="$(printf '%s' "$eng" | grep -oE '[0-9]+' | head -1)"
                if [[ -n "$cur_major" ]]; then
                    # KEEP the current node if it already satisfies the range;
                    # only switch (to a version INSIDE the range) when it doesn't.
                    [[ -n "$min_major" ]] && (( cur_major < min_major )) && { ok=0; want="$min_major"; }
                    [[ -n "$max_major" ]] && (( cur_major > max_major )) && { ok=0; want="$max_major"; }
                else
                    ok=0; want="${max_major:-$min_major}"
                fi
                if (( ok )); then
                    note="engines '$eng' ok with current node"
                elif [[ -n "$want" ]]; then
                    nvm use "$want" >/dev/null 2>&1 || { nvm install "$want" >/dev/null 2>&1 && nvm use "$want" >/dev/null 2>&1; } || true
                    note="engines '$eng' -> node $want"
                fi
            fi
        fi
        echo "    node: $(node -v 2>/dev/null || echo '?')  ($(command -v node 2>/dev/null || echo 'not found'))${note:+  [$note]}"
    else
        echo "    (nvm not found; using current node: $(node -v 2>/dev/null || echo 'none'))"
    fi
    set -u
}
run_in_project() {   # PROJECT_DIR CMD... : select Node for the project, then run
    local dir="$1"; shift
    announce "($dir) $*"
    local rc=0
    ( cd "$dir" 2>/dev/null || exit 127
      use_project_node
      "$@" ) || rc=$?
    (( rc == 127 )) && printf '%s  (could not cd into %s)%s\n' "$C_YELLOW" "$dir" "$C_RESET"
    verdict "$rc" "$*"
}

# --- optional broader "audit fix" pass (off unless a flag is given) ------
# The targeted pkg@fixedversion installs above are the authoritative fix.
# This is the extra "while we're here, clean the rest of the tree" step that
# accounts for the unrelated deprecation/audit noise npm prints. It runs
# AFTER all targeted installs, and only when -uo/-uof is passed.
AUDIT_MODE=none   # none | fix | force
npm_audit_project() {   # ROOT
    local dir="$1"
    if [[ "$AUDIT_MODE" == none ]]; then
        printf '%s  (broader audit skipped for %s - pass --update-outdated[-force] to enable)%s\n' \
            "$C_DIM" "$dir" "$C_RESET"
        return
    fi
    if [[ -f "$dir/pnpm-lock.yaml" ]]; then
        run_in_project "$dir" pnpm audit --fix
    elif [[ -f "$dir/yarn.lock" ]]; then
        printf '%s  (yarn project %s: yarn has no audit-fix force flag - skipping broader pass)%s\n' \
            "$C_DIM" "$dir" "$C_RESET"
    elif [[ "$AUDIT_MODE" == force ]]; then
        run_in_project "$dir" npm audit fix --force
    else
        run_in_project "$dir" npm audit fix
    fi
}

usage() {
    cat <<USAGE
Apply the fixes found by scan-for-package.sh.

By default this only runs the targeted <package>@<fixed-version> installs
(the precise remediation for the advisory you scanned for).

Usage: $0 [options]

Options:
  -uo,  --update-outdated         after the targeted fixes, also run a broader
                                  'npm audit fix' (pnpm: 'pnpm audit --fix') in
                                  each touched project - bumps within declared
                                  semver ranges only.
  -uof, --update-outdated-force   broader pass using 'npm audit fix --force'.
                                  WARNING: --force can bump MAJOR versions and
                                  break builds. Review and re-test afterwards.
  -h,   --help                    show this help and exit.

Tip: review with 'npm outdated' / 'npm audit' before using --update-outdated-force.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -uo|--update-outdated)        AUDIT_MODE=fix;   shift ;;
        -uof|--update-outdated-force) AUDIT_MODE=force; shift ;;
        -h|--help)                    usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage; exit 2 ;;
    esac
done

if [[ "$AUDIT_MODE" == force ]]; then
    printf '%s[!] --update-outdated-force enabled: npm audit fix --force may change MAJOR versions and break builds.%s\n' \
        "$C_YELLOW$C_BOLD" "$C_RESET"
fi
GEN
        printf '\n'

        declare -A emitted=()
        declare -A audit_roots=()     # npm project roots -> get an optional audit pass at the end
        local idx verdict cat det ver pkg eco fixver key root mgr interp reqfile

        is_managed_path() {  # caches / app bundles - npm install there is wrong
            case "$1" in
                */.bun/*|*/.npm/*|*/.cache/*|*/.pnpm-store/*|*/.yarn/*|\
                */.cursor-server/*|*/.vscode-server/*|*/.vscode/extensions/*)
                    return 0 ;;
            esac
            return 1
        }

        while IFS=$'\t' read -r idx verdict cat det ver; do
            [[ "$verdict" == "VULNERABLE" ]] || continue
            pkg="${PKG_NAMES[$idx]}"
            if [[ "$cat" == npm* ]]; then eco="npm"; else eco="py"; fi
            key="$idx:$eco"
            fixver="${REG_FIX[$key]:-}"
            # use the name that actually resolved on the registry if we have it
            local regname="${REG_NAME[$key]:-$pkg}"

            if [[ "${REG_STATUS[$key]:-}" == "nofix" ]]; then
                if [[ -z "${emitted[nofix:$key]:-}" ]]; then
                    emitted[nofix:$key]=1
                    printf '# !!! %s (%s): NO fixed release was found on the registry.\n' "$pkg" "$eco"
                    printf '# !!! Recommendation: do NOT start or deploy the affected projects\n'
                    printf '# !!! until upstream publishes a fix. Consider removing/replacing it.\n\n'
                fi
                continue
            fi
            if [[ -z "$fixver" ]]; then
                fixver="<FIXED_VERSION>"   # registry skipped/offline - fill in manually
            fi

            # caches and app-managed bundles: report, do not auto-modify
            if is_managed_path "$det"; then
                key2="m:$det"
                [[ -n "${emitted[$key2]:-}" ]] && continue
                emitted[$key2]=1
                printf '# MANAGED/CACHE LOCATION - no install command generated:\n'
                printf '#   %s (v%s)\n' "$det" "${ver:-?}"
                case "$det" in
                    */.cursor-server/*|*/.vscode-server/*|*/.vscode/extensions/*)
                        printf '#   This is bundled by the application - update the app itself\n'
                        printf '#   (e.g. Cursor/VS Code server updates ship their own dependency tree).\n\n' ;;
                    *)
                        printf '#   Package-manager cache entry; it is re-resolved from the registry.\n'
                        printf '#   Clearing the cache is optional: bun pm cache rm / npm cache clean --force\n\n' ;;
                esac
                continue
            fi

            case "$cat" in
                "npm package dir"|"npm scoped package dir")
                    root="${det%%/node_modules/*}"
                    local is_global=0 g
                    for g in "${GLOBAL_NMS[@]+"${GLOBAL_NMS[@]}"}"; do
                        [[ "$det" == "$g"/* ]] && { is_global=1; break; }
                    done
                    if (( is_global )); then
                        key2="g:$regname:$fixver"
                        [[ -n "${emitted[$key2]:-}" ]] && continue
                        emitted[$key2]=1
                        printf '# global npm install (found: %s, v%s)\n' "$det" "$ver"
                        printf 'run npm install -g %q@%q\n\n' "$regname" "$fixver"
                    else
                        key2="r:$root:$regname:$fixver"
                        [[ -n "${emitted[$key2]:-}" ]] && continue
                        emitted[$key2]=1
                        mgr="npm install"
                        [[ -f "$root/yarn.lock"      ]] && mgr="yarn add"
                        [[ -f "$root/pnpm-lock.yaml" ]] && mgr="pnpm add"
                        printf '# project %s (found: %s, v%s)\n' "$root" "$det" "$ver"
                        printf 'run_in_project %q %s %q\n\n' "$root" "$mgr" "$regname@$fixver"
                        audit_roots["$root"]=1
                    fi
                    ;;
                "npm manifest (pkg itself)")
                    key2="v:$det"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# vendored/extracted copy of the package itself: %s (v%s)\n' "$det" "${ver:-?}"
                    printf '# no install command generated - replace the vendored copy or update\n'
                    printf '# whatever placed it there.\n\n'
                    ;;
                "npm manifest ref (devDeps only)")
                    printf '# %s pins %s only in devDependencies (declared: %s)\n' "$det" "$pkg" "${ver:-?}"
                    printf '# devDependencies of third-party packages are never installed transitively;\n'
                    printf '# only act on this if it is one of YOUR projects.\n\n'
                    ;;
                "npm manifest ref")
                    root="$(dirname "$det")"
                    [[ "$root" == */node_modules* ]] && continue
                    key2="r:$root:$regname:$fixver"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    mgr="npm install"
                    case "${det##*/}" in
                        yarn.lock)      mgr="yarn add" ;;
                        pnpm-lock.yaml) mgr="pnpm add" ;;
                    esac
                    printf '# manifest %s (declared/locked: %s)\n' "$det" "${ver:-?}"
                    printf 'run_in_project %q %s %q\n\n' "$root" "$mgr" "$regname@$fixver"
                    audit_roots["$root"]=1
                    ;;
                "npm ls (current project)")
                    key2="r:$SCAN_PWD:$regname:$fixver"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# npm ls hit in the directory the scan was started from\n'
                    printf 'run_in_project %q npm install %q\n\n' "$SCAN_PWD" "$regname@$fixver"
                    audit_roots["$SCAN_PWD"]=1
                    ;;
                "pip installed ("*)
                    interp="${cat#pip installed (}"
                    interp="${interp%)}"
                    key2="p:$interp:$regname:$fixver"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# pip environment %s (found v%s)\n' "$interp" "$ver"
                    printf '# system pythons may be externally managed (PEP 668);\n'
                    printf '# add --break-system-packages or use the owning venv if this fails.\n'
                    printf 'run %q -m pip install --upgrade %q==%q\n\n' "$interp" "$regname" "$fixver"
                    ;;
                "pipx installed")
                    key2="x:$regname"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# pipx-managed (found v%s)\n' "$ver"
                    printf 'run pipx upgrade %q\n\n' "$regname"
                    ;;
                "python package dir"|"python metadata dir")
                    key2="d:${det%/*}:$regname:$fixver"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# found in %s (v%s)\n' "$det" "${ver:-?}"
                    printf '# could not determine the owning interpreter/venv automatically -\n'
                    printf '# identify it, then run (uncomment + adjust):\n'
                    printf '# <python-or-venv>/bin/python -m pip install --upgrade %q==%q\n\n' "$regname" "$fixver"
                    ;;
                "python manifest ref")
                    printf '# manifest %s references %s (declared: %s)\n' "$det" "$pkg" "${ver:-?}"
                    printf '# bump the pin to >=%s there, then reinstall the environment.\n\n' "$fixver"
                    ;;
                "python resolved pin"|"python resolved transitive"|"python resolved ref")
                    reqfile="${det%% ; *}"
                    key2="q:$reqfile:$regname:$fixver"
                    [[ -n "${emitted[$key2]:-}" ]] && continue
                    emitted[$key2]=1
                    printf '# resolving %s pins %s at v%s\n' "$reqfile" "$pkg" "${ver:-?}"
                    if [[ "$cat" == "python resolved transitive" ]]; then
                        printf '# (transitive - not listed in the file itself; this is what a FRESH\n'
                        printf '#  install would pull, the currently installed version may differ)\n'
                    fi
                    printf '# fix: add/bump a top-level constraint "%s>=%s" in %s\n' "$regname" "$fixver" "$reqfile"
                    printf '# (or a constraints file), re-resolve with uv pip compile / pip-compile,\n'
                    printf '# then reinstall the environment.\n\n'
                    ;;
            esac
        done < "$HITS_FILE"

        if (( ${#audit_roots[@]} > 0 )); then
            printf '\n# ---- broader audit pass (runs only with -uo/--update-outdated[-force]) ----\n'
            printf '#      targeted fixes above are authoritative; this just cleans the rest.\n'
            local r
            for r in "${!audit_roots[@]}"; do
                printf 'npm_audit_project %q\n' "$r"
            done
        fi

        cat <<'GEN'

echo
hr
if (( RUN_FAIL > 0 )); then
    printf '%s[FAIL] %d command(s) failed%s, %d ok - review the [FAIL] lines above.\n' \
        "$C_RED$C_BOLD" "$RUN_FAIL" "$C_RESET" "$RUN_OK"
elif (( RUN_OK > 0 )); then
    printf '%s[ OK ] all %d command(s) succeeded.%s\n' "$C_GREEN" "$RUN_OK" "$C_RESET"
fi
printf 'Re-run scan-for-package.sh to verify the results.\n'
GEN
    } > "$out"
    chmod +x "$out"
    ok "update script written: $out  (review before running!)"
}

if (( total_hits > 0 )); then
    if [[ -n "$EXPORT_DIR" ]]; then
        mkdir -p "$EXPORT_DIR"
        title "Export"
        export_findings "$EXPORT_DIR"
        (( VULN_TOTAL > 0 )) && export_update_script "$EXPORT_DIR"
    elif [[ -t 0 ]]; then
        title "Export"
        cat <<EOF
  a) export findings (TSV + JSON)
  b) export best-effort update script (folder locations + fix versions)
  c) both
  Enter) skip
EOF
        read -rp "  export> " ex
        case "$ex" in
            a|A) export_findings "." ;;
            b|B) export_update_script "." ;;
            c|C) export_findings "."; export_update_script "." ;;
            *)   : ;;
        esac
    fi
fi

############################
# verdict / exit
############################

echo
if (( VULN_TOTAL > 0 )); then
    warn "VULNERABLE versions present (${VULN_TOTAL} hit(s)) - act on the recommendations above"
    exit 3
elif (( INFO_TOTAL > 0 )); then
    warn "Discovery hits present (${INFO_TOTAL}) - review above"
    exit 3
elif (( UNK_TOTAL > 0 )); then
    warn "No confirmed vulnerable versions, but ${UNK_TOTAL} hit(s) without an extractable version - review manually"
    exit 4
elif (( total_hits > 0 )); then
    ok "Package(s) found, but every extracted version is OUTSIDE the vulnerable ranges (${total_hits} OK hit(s))"
    exit 0
else
    ok "No evidence of the requested package(s) (0 / ${total_scanned})"
    exit 0
fi
