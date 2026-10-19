#!/usr/bin/env bash
# Shared helpers for the installers: persist the shared inference knobs to
# ~/.openmono/settings.json. settings.json is the single source of truth;
# scripts/apply_settings.sh materializes inference.port / parallel_slots into
# the backend files (docker/.env, strata.env, generated Strata configs, Caddy
# upstream) on every `openmono start`/`restart`.
#
# These helpers only write settings.json. They never touch backend files, so an
# installer can call them before the backend exists.
#
# Usage:
#   n="$(om_choose_parallel_slots 1)"   # prompt (interactive) / env / default,
#                                        # persist, and echo the chosen value
#   om_persist_parallel_slots "$n"
#   om_persist_inference_port 7474

# jq is required to write settings.json. Fall back to echo-only (best effort):
# apply_settings.sh pins the defaults into settings.json on first start anyway.
_om_settings_file() {
    printf '%s' "${OPENMONO_SETTINGS_FILE:-$HOME/.openmono/settings.json}"
}

_om_settings_set() {
    # $1 = jq filter, rest = jq args
    local filter="$1"; shift
    command -v jq &>/dev/null || return 0
    local settings; settings="$(_om_settings_file)"
    mkdir -p "$(dirname "$settings")"
    [[ -f "$settings" ]] || echo '{}' > "$settings"
    if jq "$@" "$filter" "$settings" > "${settings}.tmp" 2>/dev/null; then
        mv "${settings}.tmp" "$settings"
        chmod 0600 "$settings" 2>/dev/null || true
    else
        rm -f "${settings}.tmp"
    fi
}

om_persist_parallel_slots() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) || return 0
    _om_settings_set '.inference = (.inference // {}) | .inference.parallel_slots = $n' \
        --argjson n "$n"
}

om_persist_inference_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || return 0
    _om_settings_set '.inference = (.inference // {}) | .inference.port = $p' \
        --argjson p "$p"
}

# Ask for the number of parallel slots. Non-interactive (or piped) installs use
# $OPENMONO_PARALLEL_SLOTS when set, else the default. Always persists the
# answer to settings.json and echoes it on stdout.
om_choose_parallel_slots() {
    local default="${1:-1}" n="${OPENMONO_PARALLEL_SLOTS:-}"
    if [[ -z "$n" ]]; then
        if [[ -t 0 ]]; then
            echo ""
            echo "  Parallel slots: how many requests may the model serve at once?" >&2
            echo "  Each slot reserves a full context of KV cache, so more slots cost" >&2
            echo "  VRAM/RAM (and Strata caps at 8 per GPU group). Use 1 for a single" >&2
            echo "  interactive agent; raise it only if you run several sessions/agents." >&2
            echo "" >&2
            printf "  Slots [default: %s]: " "$default" >&2
            read -r n || n=""
            n="${n:-$default}"
        else
            n="$default"
        fi
    fi
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) || n="$default"
    om_persist_parallel_slots "$n"
    printf '%s' "$n"
}
