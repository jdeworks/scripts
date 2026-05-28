#!/usr/bin/env bash
# Hunt the filesystem for evidence of a specific npm or pip package.
# Built for chasing reported compromised / typosquatted dependencies.
set -uEo pipefail
IFS=$'\n\t'
shopt -s nullglob

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

# Compact single-line hits; multi-line payloads indented under a heading.
found() {
    mark_found
    local cat="$1" det="$2"
    echo "$cat" >> "$HITS_FILE"
    clear_line
    if [[ "$det" == *$'\n'* ]]; then
        printf '%s[FOUND]%s %s%s%s\n' "$RED" "$RESET" "$BOLD" "$cat" "$RESET"
        printf '%s\n' "$det" | sed 's/^/        /'
    else
        printf '%s[FOUND]%s %s%-26s%s %s\n' "$RED" "$RESET" "$BOLD" "$cat" "$RESET" "$det"
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

Exit codes:
  0  no evidence
  3  evidence found
EOF
}

MODE=""
PACKAGE=""
SEARCH_ROOT="/"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode) MODE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
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

    if command -v npm >/dev/null 2>&1; then
        log "npm ls (current working dir)..."
        local out
        if out="$(npm ls "$PACKAGE" --all 2>/dev/null)" \
            && grep -qi -- "$PACKAGE" <<<"$out"; then
            found "npm ls (current project)" "$(head -n 30 <<<"$out")"
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
                [[ -d "$d/$v" ]] && found "npm package dir" "$d/$v"
                for hit in "$d"/@*/"$v"; do
                    [[ -d "$hit" ]] && found "npm scoped package dir" "$hit"
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
                found "npm manifest ref" "$f"
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

    local py out
    while read -r py; do
        [[ -z "$py" ]] && continue
        log "pip show via $py..."
        if out="$("$py" -m pip show "$PACKAGE" 2>/dev/null)" && [[ -n "$out" ]]; then
            found "pip installed ($py)" "$out"
        fi
    done < <(python_interpreters | awk 'NF && !seen[$0]++')

    if command -v pipx >/dev/null 2>&1; then
        log "pipx list..."
        if pipx list --short 2>/dev/null | grep -qi -- "$PACKAGE"; then
            found "pipx installed" "$(pipx list 2>/dev/null | grep -i -- "$PACKAGE" || true)"
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
                [[ -d "$d/$v" ]] && found "python package dir" "$d/$v"
                for hit in "$d/${v}-"*.dist-info "$d/${v}-"*.egg-info "$d/${v}.egg-info"; do
                    [[ -d "$hit" ]] && found "python metadata dir" "$hit"
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
                found "python manifest ref" "$f"
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
    # Tab-separate count and category so `read` can split them even with IFS=$'\n\t'.
    awk '{c[$0]++} END {for (k in c) printf "%d\t%s\n", c[k], k}' "$HITS_FILE" \
        | sort -rn \
        | while IFS=$'\t' read -r n c; do
            printf '    %-32s %s%4d%s\n' "$c" "$YELLOW" "$n" "$RESET"
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
