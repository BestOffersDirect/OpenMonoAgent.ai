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
# answer to settings.json and echoes a VALID positive integer on stdout — it
# can never return empty, so `PARALLEL_SLOTS="$(om_choose_parallel_slots 1)"`
# is always safe even under `set -euo pipefail`.
om_choose_parallel_slots() {
    # Runs inside a $(...) command substitution in the installers, which inherit
    # their `set -euo pipefail`. Two consequences, both handled below:
    #   1. a bare test as its own statement (e.g. `(( n < 1 ))`) aborts the
    #      subshell when false, so every such test here is part of an if/|| list;
    #   2. stdout is the caller's capture pipe, so prompt text and blank lines
    #      must go to stderr or they corrupt the returned value.
    local default="${1:-1}" n="${OPENMONO_PARALLEL_SLOTS:-}"
    # Sanitize the default up front so the fallback path always has a valid int.
    if ! [[ "$default" =~ ^[0-9]+$ ]] || [ "$default" -lt 1 ]; then default=1; fi
    if [[ -z "$n" ]] && [[ -t 0 ]]; then
        # Drain any keystrokes buffered by earlier prompts/long steps (a stray
        # Enter or a leftover char from a prior `read` would otherwise be
        # consumed by the read below and silently answer this prompt).
        flush_stdin 2>/dev/null || true
        # Every byte this function writes to STDOUT is captured by the caller's
        # $(...) — including a bare `echo ""`. That blank separator must go to
        # stderr with the rest of the prompt, or it lands at the front of the
        # captured value ("\n2" instead of "2").
        echo "" >&2
        echo "  Parallel slots: how many requests may the model serve at once?" >&2
        echo "  More slots cost memory and can cost speed, but how depends on the" >&2
        echo "  backend:" >&2
        echo "    llama.cpp / native - each slot gets its OWN full-context KV" >&2
        echo "                         cache, so KV memory grows with the slot count." >&2
        echo "    Strata             - each slot keeps its own K/V for the WHOLE" >&2
        echo "                         context (the context is not divided between" >&2
        echo "                         slots), but that K/V is taken from the expert" >&2
        echo "                         cache, and Strata serves at most 8 slots." >&2
        echo "  Use 1 for a single interactive agent; raise it only if you run" >&2
        echo "  several sessions/agents at once." >&2
        echo "" >&2
        printf "  Slots [default: %s]: " "$default" >&2
        read -r n || n=""
    fi
    # Coerce to a valid positive integer; anything else (empty, junk, a stray
    # char, EOF) falls back to the default. This guarantees the function always
    # echoes a real number and never leaves the caller's variable empty.
    if ! [[ "${n:-}" =~ ^[0-9]+$ ]] || [ "${n:-0}" -lt 1 ]; then
        n="$default"
    fi
    om_persist_parallel_slots "$n"
    # Belt and braces: the value is already a validated integer here, so the
    # strip is a no-op today. It stays only so a future stray write to stdout
    # upstream of this point cannot corrupt the caller's variable.
    n="${n//[[:space:]]/}"
    printf '%s' "$n"
}

# Warn (never clamp) about what the chosen slot count costs on THIS backend.
# Called after om_choose_parallel_slots, where the backend is known.
#   $1 = backend (strata | llama | native-metal)
#   $2 = slots
#   $3 = context tokens, optional — only used to make the llama.cpp note concrete
#
# The two engines behave differently enough that one generic sentence misleads:
#
#   llama.cpp / native: --parallel N allocates N independent KV buffers, each
#   sized for the full --ctx-size. KV memory really is ~N x single-slot.
#
#   Strata: "parallel" is the engine's --batch/--slots. The configured context is
#   NOT divided between slots — every slot owns a full-context K/V session. But
#   that K/V is carved out of the VRAM that would otherwise hold the model's
#   expert cache, so the cost is per-request speed, not a smaller context.
#   Upstream docs/BATCHING.md: 2..8 slots normally (8 per group with a layer
#   split), ~0.56 GiB per slot at a 32K context with 8-bit KV, and the engine
#   "never refuses a count it cannot run" — it logs the real number and serves
#   what fits. So asking for 24 is not an error, it is silently reduced.
om_warn_parallel_slots() {
    local backend="$1" n="${2:-1}" ctx="${3:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 0

    if [ "$backend" = "strata" ]; then
        if [ "$n" -gt 8 ]; then
            warn "Strata serves at most 8 batch slots (8 per group with a layer split)."
            warn "  $n will be reduced by the engine at start — it logs 'batch_slots=N'"
            warn "  and GET /v1/status reports the real count under concurrency.serving."
            warn "  Lower it to avoid surprises: openmono config set inference.parallel_slots 8"
        fi
        if [ "$n" -gt 1 ]; then
            info "Strata: the context is NOT split between slots — each slot keeps its own"
            info "  full-context K/V, taken from the expert cache. On a 12/16 GB card that"
            info "  costs roughly 10-25% speed per request; it only pays off for concurrent sessions."
        fi
        return 0
    fi

    # llama.cpp / native-metal
    if [ "$n" -gt 1 ]; then
        if [ -n "$ctx" ] && [[ "$ctx" =~ ^[0-9]+$ ]]; then
            info "llama.cpp: each of the $n slots reserves its own $ctx-token KV cache."
            info "  KV memory is ~${n}x the single-slot cost — lower inference.ctx_size if it will not fit."
        else
            info "llama.cpp: each slot reserves its own full-context KV cache, so KV memory"
            info "  grows with the slot count — watch VRAM/RAM headroom."
        fi
    fi
    return 0
}
