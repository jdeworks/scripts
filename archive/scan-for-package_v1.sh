#!/usr/bin/env bash
# Hunt the filesystem for evidence of a specific npm or pip package.
# Built for chasing reported compromised / typosquatted dependencies.
set -uEo pipefail
IFS=$'\n\t'
shopt -s nullglob

VERSION="1.0.0"

############################
# state / cleanup
############################

FOUND_FILE="$(mktemp)"
HITS_FILE="$(mktemp)"
WALK_FILE="$(mktemp)"
SPINNER_PID=""
SPINNER_T0=0

# Per-phase scanned counts (so the summary can show "hits / scanned").
NM_SCANNED=0
SP_SCANNED=0
NPM_MAN_SCANNED=0
PY_MAN_SCANNED=0

echo 0 > "$FOUND_FILE"

cleanup() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    rm -f "$FOUND_FILE" "$HITS_FILE" "$WALK_FILE"
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

# HITS_FILE stores one TSV record per hit:
#   <category>\t<one-line detail>\t<comma-separated versions or empty>
# Versions are best-effort: empty when not extractable from the source.
found() {
    mark_found
    local cat="$1" det="$2" ver="${3:-}"
    local det_one="${det//$'\n'/ ; }"
    det_one="${det_one//$'\t'/ }"
    printf '%s\t%s\t%s\n' "$cat" "$det_one" "$ver" >> "$HITS_FILE"
    local ver_tag=""
    if [[ -n "$ver" ]]; then
        local v_disp="${ver//,/, v}"
        ver_tag=" ${DIM}(v${v_disp})${RESET}"
    fi
    clear_line
    if [[ "$det" == *$'\n'* ]]; then
        printf '%s[FOUND]%s %s%s%s%s\n' "$RED" "$RESET" "$BOLD" "$cat" "$RESET" "$ver_tag"
        printf '%s\n' "$det" | sed 's/^/        /'
    else
        printf '%s[FOUND]%s %s%-26s%s %s%s\n' "$RED" "$RESET" "$BOLD" "$cat" "$RESET" "$det" "$ver_tag"
    fi
}

############################
# spinner (for unbounded steps)
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

############################
# progress (for bounded steps)
############################

PROG_LAST_HITS=0
progress() {
    (( TTY == 0 )) && return
    local i=$1 n=$2 label=$3
    [[ "$n" -le 0 ]] && return

    # Refresh hit count occasionally (avoids forking wc every iteration)
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
# args
############################

usage() {
    cat <<EOF
Usage:
  $0 [-m npm|python|both] PACKAGE_NAME [SEARCH_ROOT]
  $0                                # interactive

Defaults: mode=both, SEARCH_ROOT=/

Each hit is annotated with the resolved version(s) where extractable
(node_modules/<pkg>/package.json, lockfiles, dist-info/egg-info, etc.).
If anything is found and stdin is a TTY, an interactive prompt at the
end lets you filter hits by version expression — useful when a popular
package shows up many times but only specific releases were compromised.
  Examples: ">=4.17.20"  "4.17.15 - 4.17.20"  "^1.2.3"  "1.2.3, 2.0.0"

Exit codes:
  0  no evidence
  3  evidence found

Version: $VERSION
EOF
}

MODE=""
PACKAGE=""
SEARCH_ROOT="/"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode) MODE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --version) echo "scan-for-package.sh $VERSION"; exit 0 ;;
        --) shift; break ;;
        -*) err "unknown flag: $1"; usage; exit 2 ;;
        *)
            if [[ -z "$PACKAGE" ]]; then PACKAGE="$1"
            else SEARCH_ROOT="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$PACKAGE" ]]; then
    title "Dependency Security Scanner"
    echo "1) npm   2) python   3) both"
    read -rp "Select mode [1-3]: " m
    case "$m" in
        1)    MODE=npm ;;
        2)    MODE=python ;;
        3|"") MODE=both ;;
        *)    err "invalid mode"; exit 1 ;;
    esac
    read -rp "Package name: " PACKAGE
fi

[[ -n "$PACKAGE" ]] || { err "package required"; usage; exit 1; }
MODE="${MODE:-both}"

############################
# name variants (PEP 503-ish)
############################

norm_lower="$(printf '%s' "$PACKAGE" | tr '[:upper:]' '[:lower:]')"
norm_503="$(printf '%s' "$norm_lower" | sed -E 's/[-_.]+/-/g')"
norm_under="$(printf '%s' "$norm_503" | tr '-' '_')"

mapfile -t VARIANTS < <(
    printf '%s\n' \
        "$PACKAGE" \
        "$norm_lower" \
        "$norm_503" \
        "$norm_under" \
        "${PACKAGE//-/_}" \
        "${PACKAGE//_/-}" \
        "${PACKAGE//./_}" \
    | awk 'NF && !seen[$0]++'
)

title "Dependency Security Scanner"
log "Package:  ${BOLD}${PACKAGE}${RESET}"
log "Mode:     ${BOLD}${MODE}${RESET}"
log "Root:     ${BOLD}${SEARCH_ROOT}${RESET}"
log "Variants: ${VARIANTS[*]}"

############################
# helpers
############################

# Kernel/transient/cross-mount noise we always skip.
# /mnt + /media excluded so WSL Windows drives don't blow up runtime.
FIND_PRUNE=( '('
    -path /proc -o -path /sys -o -path /dev -o -path /run
    -o -path /var/lib/docker -o -path /var/lib/containers
    -o -path /snap -o -path /mnt -o -path /media
    -o -path /.snapshots
')' )

# Single FS pass that emits node_modules / site-packages / dist-packages dirs
# AND manifest files in one go.  Using -prune -print on the dir names means
# we never descend into them (faster) AND that manifests inside node_modules
# are skipped automatically (which is what we want).
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
    command -v npm >/dev/null 2>&1 && npm root -g 2>/dev/null
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
        # Skip helpers like python3.10-config that aren't interpreters.
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
# version comparison + filter
############################

re_escape() {
    printf '%s' "$1" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g'
}

# Reduce a version-ish string to "MAJOR.MINOR.PATCH".
# Tolerates leading v / ^ / ~ / >= and trailing pre/build (-beta, +sha).
ver_normalize() {
    local v parts
    v="$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
    [[ -z "$v" ]] && v="0"
    IFS=. read -ra parts <<<"$v"
    printf '%d.%d.%d' "${parts[0]:-0}" "${parts[1]:-0}" "${parts[2]:-0}"
}

# Echo -1, 0, or 1 for compare(A, B).
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

# Match $ver against one clause:
#   1.2.3 | v1.2.3 | =1.2.3 | >X | >=X | <X | <=X | ^X | ~X | A - B
clause_match() {
    local ver="$1" clause="$2"
    clause="${clause#"${clause%%[![:space:]]*}"}"
    clause="${clause%"${clause##*[![:space:]]}"}"
    [[ -z "$clause" ]] && return 1

    # Hyphen range — require spaces so we don't trip on "1.2.3-beta".
    if [[ "$clause" == *" - "* ]]; then
        local lo="${clause%% - *}" hi="${clause##* - }" c1 c2
        c1="$(ver_cmp "$ver" "$lo")"
        c2="$(ver_cmp "$ver" "$hi")"
        [[ "$c1" != "-1" && "$c2" != "1" ]] && return 0
        return 1
    fi

    local op="" target="$clause"
    case "$clause" in
        ">="*) op=">="; target="${clause#>=}" ;;
        "<="*) op="<="; target="${clause#<=}" ;;
        ">"*)  op=">";  target="${clause#>}"  ;;
        "<"*)  op="<";  target="${clause#<}"  ;;
        "="*)  op="=";  target="${clause#=}"  ;;
        "^"*)  op="^";  target="${clause#^}"  ;;
        "~"*)  op="~";  target="${clause#~}"  ;;
        *)     op="=";  target="$clause"      ;;
    esac
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target#v}"

    local c norm T_arr hi c1 c2
    case "$op" in
        "=")  [[ "$(ver_cmp "$ver" "$target")" == "0"  ]] && return 0 ;;
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
        "~")
            norm="$(ver_normalize "$target")"
            IFS=. read -ra T_arr <<<"$norm"
            hi="${T_arr[0]}.$(( T_arr[1] + 1 )).0"
            c1="$(ver_cmp "$ver" "$target")"
            c2="$(ver_cmp "$ver" "$hi")"
            [[ "$c1" != "-1" && "$c2" == "-1" ]] && return 0 ;;
    esac
    return 1
}

# Match $ver against a comma-separated expression (OR semantics).
filter_match() {
    local ver="$1" expr="$2" clauses c
    IFS=, read -ra clauses <<<"$expr"
    for c in "${clauses[@]}"; do
        clause_match "$ver" "$c" && return 0
    done
    return 1
}

# Dedup + comma-join one-version-per-line on stdin.
ver_list_join() {
    awk 'NF && !seen[$0]++' | paste -sd ',' -
}

############################
# version extractors
############################

# Top-level "version" of a package.json (for installed package dirs).
pkgjson_own_version() {
    grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/'
}

# Versions of $pkg listed as a dependency in a project's package.json.
pkgjson_dep_versions() {
    local f="$1" pkg_re
    pkg_re="$(re_escape "$2")"
    grep -oE "\"${pkg_re}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$f" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        | awk 'NF && !seen[$0]++'
}

# Resolved versions of $pkg from an npm package-lock.json / npm-shrinkwrap.json.
# Uses python3 if available (handles both v1 and v2+ layouts); falls back to a
# coarse "find version: near a key matching pkg" grep otherwise.
nlock_versions() {
    local f="$1" pkg="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$f" "$pkg" <<'PY' 2>/dev/null
import json, sys
f, pkg = sys.argv[1], sys.argv[2]
try:
    with open(f) as fp:
        data = json.load(fp)
except Exception:
    sys.exit(0)
versions = set()
# v2+: "packages": { "node_modules/foo": {...}, "node_modules/a/node_modules/foo": {...} }
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
# v1: nested "dependencies"
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

# Resolved versions of $pkg from a yarn.lock.
# yarn.lock blocks look like:
#   "pkg@^1.2.3", "pkg@^1.4.0":
#     version "1.4.2"
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

# Resolved versions of $pkg from a pnpm-lock.yaml (best-effort).
plock_versions() {
    local f="$1" pkg="$2" pkg_re
    pkg_re="$(re_escape "$pkg")"
    # pnpm v5/v6: "/pkg/X.Y.Z:"     pnpm v9: "pkg@X.Y.Z:"
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

# Version embedded in a python metadata dir name, e.g.
#   lodash-4.17.21.dist-info   ->  4.17.21
#   lodash-4.17.21-py3.10.egg-info  ->  4.17.21
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

# Adjacent dist-info / egg-info for a bare python package dir.
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

# requirements.txt / Pipfile / poetry.lock / setup.* (best-effort).
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
        # poetry-style:   pkg = "^1.2.3"   or   pkg = "1.2.3"
        grep -iE "^[[:space:]]*${pkg_re}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$f" 2>/dev/null \
            | sed -E 's/.*"([^"]+)"$/\1/'
        # PEP 621:         "pkg==1.2.3"   or   "pkg>=1.2.3"
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
# Phase 1 - filesystem walk
############################

t_start=$(date +%s)

title "Phase 1  -  Filesystem walk"
log "Walking ${SEARCH_ROOT} (single pass, this is the slowest step)..."
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

# Add sources that aren't necessarily under SEARCH_ROOT.
while read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && NM_DIRS+=("$d")
done < <(npm_global_roots)
while read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && SP_DIRS+=("$d")
done < <(python_interp_site_dirs)

# Dedup.
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

check_npm() {
    title "Phase 2  -  NPM"
    local out ver pkg_re
    pkg_re="$(re_escape "$PACKAGE")"

    if command -v npm >/dev/null 2>&1; then
        log "npm ls (current working dir)..."
        if out="$(npm ls "$PACKAGE" --all 2>/dev/null)" \
            && grep -qi -- "$PACKAGE" <<<"$out"; then
            ver="$(printf '%s\n' "$out" | grep -oE -- "${pkg_re}@[^[:space:]]+" \
                    | sed -E "s/.*${pkg_re}@//" | ver_list_join)"
            found "npm ls (current project)" "$(head -n 30 <<<"$out")" "$ver"
        else
            ok "npm ls: not present in current project"
        fi
    else
        warn "npm not installed - skipping npm ls"
    fi

    if (( ${#NM_DIRS[@]} > 0 )); then
        log "Scanning ${#NM_DIRS[@]} node_modules directories..."
        NM_SCANNED=${#NM_DIRS[@]}
        local total=${#NM_DIRS[@]} i=0 d v hit
        for d in "${NM_DIRS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "npm dirs"
            for v in "${VARIANTS[@]}"; do
                if [[ -d "$d/$v" ]]; then
                    ver=""
                    [[ -f "$d/$v/package.json" ]] && ver="$(pkgjson_own_version "$d/$v/package.json")"
                    found "npm package dir" "$d/$v" "$ver"
                fi
                for hit in "$d"/@*/"$v"; do
                    if [[ -d "$hit" ]]; then
                        ver=""
                        [[ -f "$hit/package.json" ]] && ver="$(pkgjson_own_version "$hit/package.json")"
                        found "npm scoped package dir" "$hit" "$ver"
                    fi
                done
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
            if grep -Fqi -- "$PACKAGE" "$f" 2>/dev/null; then
                ver="$(npm_manifest_versions "$f" "$PACKAGE")"
                found "npm manifest ref" "$f" "$ver"
            fi
        done
        clear_line
        ok "npm manifest scan complete"
    fi
}

############################
# Phase 3 - Python
############################

check_python() {
    title "Phase 3  -  Python"
    local py out ver detail pkg_re
    pkg_re="$(re_escape "$PACKAGE")"

    while read -r py; do
        [[ -z "$py" ]] && continue
        log "pip show via $py..."
        if out="$("$py" -m pip show "$PACKAGE" 2>/dev/null)" && [[ -n "$out" ]]; then
            ver="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="version"{print $2; exit}')"
            found "pip installed ($py)" "$out" "$ver"
        fi
    done < <(python_interpreters | awk 'NF && !seen[$0]++')

    if command -v pipx >/dev/null 2>&1; then
        log "pipx list..."
        if pipx list --short 2>/dev/null | grep -qi -- "$PACKAGE"; then
            detail="$(pipx list 2>/dev/null | grep -i -- "$PACKAGE" || true)"
            ver="$(printf '%s\n' "$detail" | grep -oiE "${pkg_re}[[:space:]]+[0-9][^[:space:],]*" \
                    | awk '{print $NF}' | ver_list_join)"
            found "pipx installed" "$detail" "$ver"
        fi
    fi

    if (( ${#SP_DIRS[@]} > 0 )); then
        log "Scanning ${#SP_DIRS[@]} site-packages directories..."
        SP_SCANNED=${#SP_DIRS[@]}
        local total=${#SP_DIRS[@]} i=0 d v hit
        for d in "${SP_DIRS[@]}"; do
            ((i++)) || true
            progress "$i" "$total" "python dirs"
            for v in "${VARIANTS[@]}"; do
                if [[ -d "$d/$v" ]]; then
                    ver="$(py_pkg_dir_version "$d/$v" "$v")"
                    found "python package dir" "$d/$v" "$ver"
                fi
                for hit in "$d/${v}-"*.dist-info "$d/${v}-"*.egg-info "$d/${v}.egg-info"; do
                    if [[ -d "$hit" ]]; then
                        ver="$(py_meta_version "$hit" "$v")"
                        found "python metadata dir" "$hit" "$ver"
                    fi
                done
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
            if grep -Fqi -- "$PACKAGE" "$f" 2>/dev/null; then
                ver="$(py_manifest_versions "$f" "$PACKAGE")"
                found "python manifest ref" "$f" "$ver"
            fi
        done
        clear_line
        ok "python manifest scan complete"
    fi
}

############################
# run
############################

case "$MODE" in
    npm|1)         check_npm ;;
    python|py|2)   check_python ;;
    both|all|3|"") check_npm; check_python ;;
    *)             err "invalid mode: $MODE"; exit 1 ;;
esac

############################
# summary
############################

t_end=$(date +%s)
dur=$(( t_end - t_start ))
total_hits=$(wc -l < "$HITS_FILE" 2>/dev/null | tr -d ' ')
[[ -z "$total_hits" ]] && total_hits=0

# Total objects examined (excluding the few one-shot probes like `npm ls`,
# `pip show`, `pipx list` which each count as ~1 and would just muddy the math).
total_scanned=$(( NM_SCANNED + SP_SCANNED + NPM_MAN_SCANNED + PY_MAN_SCANNED ))

# Build a "X node_modules · Y npm manifests · ..." breakdown of what was scanned.
parts=()
(( NM_SCANNED       > 0 )) && parts+=("${NM_SCANNED} node_modules")
(( NPM_MAN_SCANNED  > 0 )) && parts+=("${NPM_MAN_SCANNED} npm manifests")
(( SP_SCANNED       > 0 )) && parts+=("${SP_SCANNED} site-packages")
(( PY_MAN_SCANNED   > 0 )) && parts+=("${PY_MAN_SCANNED} python manifests")
scanned_breakdown=""
if (( ${#parts[@]} > 0 )); then
    scanned_breakdown="$(printf ' · %s' "${parts[@]}")"
    scanned_breakdown="${scanned_breakdown# · }"
fi

# Color the ratio: green when clean, yellow when any hits.
if (( total_hits == 0 )); then
    ratio_color="$GREEN"
    verdict_color="$GREEN"
    verdict_label="CLEAN"
else
    ratio_color="$YELLOW"
    verdict_color="$RED"
    verdict_label="HITS FOUND"
fi

title "Summary"
printf '  %s%-16s%s %s%s%s\n'  "$DIM" "Package:"  "$RESET" "$BOLD"   "$PACKAGE"     "$RESET"
printf '  %s%-16s%s %s\n'      "$DIM" "Mode:"     "$RESET" "$MODE"
printf '  %s%-16s%s %s\n'      "$DIM" "Root:"     "$RESET" "$SEARCH_ROOT"
printf '  %s%-16s%s %ds\n'     "$DIM" "Duration:" "$RESET" "$dur"
printf '  %s%-16s%s %d items'  "$DIM" "Scanned:"  "$RESET" "$total_scanned"
if [[ -n "$scanned_breakdown" ]]; then
    printf '   %s(%s)%s' "$DIM" "$scanned_breakdown" "$RESET"
fi
echo
printf '  %s%-16s%s %s%d / %d hits%s   %s[%s]%s\n' \
    "$DIM" "Result:" "$RESET" \
    "$ratio_color" "$total_hits" "$total_scanned" "$RESET" \
    "$verdict_color" "$verdict_label" "$RESET"

if (( total_hits > 0 )); then
    echo
    printf '  %sBy category:%s\n' "$BOLD" "$RESET"
    # First field is category in our TSV layout.
    awk -F'\t' '{c[$1]++} END {for (k in c) printf "%d\t%s\n", c[k], k}' "$HITS_FILE" \
        | sort -rn \
        | while IFS=$'\t' read -r n c; do
            printf '    %-32s %s%4d%s\n' "$c" "$YELLOW" "$n" "$RESET"
        done
fi

############################
# Interactive version filter
############################

apply_filter() {
    local expr="$1"
    local matched=0 unknown=0 total=0
    local cat det ver vlist v hit hit_ver extra other_list
    title "Filter: ${expr}"
    while IFS=$'\t' read -r cat det ver; do
        ((total++)) || true
        if [[ -z "$ver" ]]; then
            ((unknown++)) || true
            continue
        fi
        hit=0; hit_ver=""
        IFS=, read -ra vlist <<<"$ver"
        for v in "${vlist[@]}"; do
            if filter_match "$v" "$expr"; then
                hit_ver="$v"
                hit=1
                break
            fi
        done
        if (( hit )); then
            ((matched++)) || true
            extra=""
            if (( ${#vlist[@]} > 1 )); then
                other_list=""
                for v in "${vlist[@]}"; do
                    [[ "$v" == "$hit_ver" ]] && continue
                    other_list="${other_list:+$other_list, }v$v"
                done
                extra=" ${DIM}(other versions seen: ${other_list})${RESET}"
            fi
            printf '  %s[MATCH]%s %s(v%s)%s %s%-26s%s %s%s\n' \
                "$RED" "$RESET" "$YELLOW" "$hit_ver" "$RESET" "$BOLD" "$cat" "$RESET" "$det" "$extra"
        fi
    done < "$HITS_FILE"
    echo
    if (( matched == 0 )); then
        ok "No hits match '${expr}'  (${unknown} of ${total} had no extractable version)"
    elif (( unknown > 0 )); then
        warn "${matched} of ${total} hit(s) match '${expr}'  (${unknown} excluded - no extractable version)"
    else
        warn "${matched} of ${total} hit(s) match '${expr}'"
    fi
}

if (( total_hits > 0 )) && [[ -t 0 ]]; then
    title "Version Filter"
    cat <<EOF
  Hits include version numbers where extractable. Narrow them down with
  an expression (takeovers are often scoped to a small release window):

    1.2.3                exact
    v1.2.3               exact (v-prefix tolerated)
    >=4.17.20            operators:  >  >=  <  <=
    4.17.15 - 4.17.20    inclusive range (spaces required around the hyphen)
    ^1.2.3               >=1.2.3, < next major
    ~1.2.3               >=1.2.3, < next minor
    4.17.15, >=5.0.0     comma-separated (OR)

  Hits without an extractable version are excluded from filtered output.
  Press Enter on a blank line to exit.
EOF
    while :; do
        echo
        if ! read -rp "  filter> " filter_expr; then
            echo
            break
        fi
        filter_expr="${filter_expr#"${filter_expr%%[![:space:]]*}"}"
        filter_expr="${filter_expr%"${filter_expr##*[![:space:]]}"}"
        [[ -z "$filter_expr" ]] && break
        apply_filter "$filter_expr"
    done
fi

echo
if (( total_hits == 0 )); then
    ok "No evidence of '${PACKAGE}'  (0 / ${total_scanned})"
    exit 0
else
    warn "Evidence of '${PACKAGE}' found  (${total_hits} / ${total_scanned}) - review hits above"
    exit 3
fi
