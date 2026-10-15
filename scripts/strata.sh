#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# OpenMono.ai — Strata inference backend manager (Linux only)
#
# Strata (https://github.com/Niko1221/Strata, MIT License) runs the
# Qwen3.8-Flash-Next model on a regular gaming PC (NVIDIA/AMD GPU, 12GB+ VRAM)
# and serves an OpenAI-compatible API at http://127.0.0.1:8080/v1
# (plus /v1/messages for Anthropic-style clients and /v1/responses).
#
# OpenMono does NOT vendor Strata. This script clones upstream Strata next to
# the install (default ~/strata), drives its documented Linux flow
# (./setup.sh --check / --yes ...), and manages the server process it writes
# (run-<model>.sh). The .NET agent then talks to Strata exactly like any other
# OpenAI-compatible provider — any API key and any model name work.
#
# State: ~/.openmono/strata.env  (STRATA_DIR, STRATA_PORT, STRATA_MODEL, ...)
#
# Usage:
#   strata.sh check            # hardware preflight (no changes besides Strata's own python venv probe)
#   strata.sh install [--yes] [--family qwen --model IQ2_XS ...]  # clone + auto-install CUDA 13.x if needed + ./setup.sh --no-start
#   strata.sh start            # launch run-<model>.sh detached, wait for /health
#   strata.sh stop             # stop the server process
#   strata.sh status           # /health + /v1/models summary (for `openmono status`)
#   strata.sh logs [--tail N]  # tail the server log
#   strata.sh update           # git pull + ./update.sh (no start)
#   strata.sh update-cuda      # install/refresh the CUDA 13.x toolkit (sudo)
#
# Env overrides:
#   STRATA_DIR     where Strata lives            (default ~/strata)
#   STRATA_PORT    server port                   (default 8080)
#   STRATA_FAMILY  qwen|swift|coder|unsloth      (default qwen)
#   STRATA_MODEL   Q2_0|IQ2_XS|IQ3_XXS|IQ3_S|... (default: setup picks for the RAM)
#   STRATA_CONTEXT context tokens                (default: setup picks for the VRAM)
#   STRATA_VISION  yes|no|cpu                    (default no)
#   STRATA_DATA_DIR model-file dir               (default <STRATA_DIR>-data next to Strata)
# ──────────────────────────────────────────────────────────────────────────────

STRATA_REPO="https://github.com/Niko1221/Strata.git"
STRATA_DIR="${STRATA_DIR:-$HOME/strata}"
STRATA_PORT="${STRATA_PORT:-8080}"
STRATA_FAMILY="${STRATA_FAMILY:-qwen}"
STRATA_MODEL="${STRATA_MODEL:-}"
STRATA_CONTEXT="${STRATA_CONTEXT:-}"
STRATA_VISION="${STRATA_VISION:-no}"
STRATA_DATA_DIR="${STRATA_DATA_DIR:-}"
OPENMONO_STATE_DIR="${OPENMONO_STATE_DIR:-$HOME/.openmono}"
STRATA_ENV_FILE="$OPENMONO_STATE_DIR/strata.env"
STRATA_PID_FILE="$OPENMONO_STATE_DIR/strata.pid"
STRATA_LOG="$OPENMONO_STATE_DIR/strata-server.log"

# Strata's engine is built with CUDA 13.0 and refuses to compile against
# anything older (setup.py: need_cuda = (13, 0)).
CUDA_MIN="13.0"
# NVIDIA publishes one CUDA apt repo per Ubuntu codename; newer releases
# (e.g. 26.04 "resolute") appear there only after NVIDIA ships packages for
# them, so we fall back to the newest codename that has one, newest first.
# NOTE: these are the codenames as NVIDIA names their repo dirs (release
# numbers, not lsb-release codenames) — the dir for 24.04 "noble" is
# "ubuntu2404", NOT "ubuntunoble" (that path 404s).
CUDA_REPO_FALLBACKS=(2404 2204 2004)
CUDA_KEYRING_DEB="cuda-keyring_1.1-1_all.deb"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[38;2;163;255;102m'; NC=$'\033[0m'
info() { echo -e "${BLUE}[strata]${NC} $*"; }
ok()   { echo -e "${GREEN}[strata]${NC} $*"; }
warn() { echo -e "${YELLOW}[strata]${NC} $*" >&2; }
err()  { echo -e "${RED}[strata]${NC} $*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
    err "Strata backend is Linux-only in OpenMono (macOS keeps its native inference path)."
    exit 1
fi

save_env() {
    mkdir -p "$OPENMONO_STATE_DIR"
    cat > "$STRATA_ENV_FILE" <<EOF
STRATA_DIR="$STRATA_DIR"
STRATA_PORT="$STRATA_PORT"
STRATA_FAMILY="$STRATA_FAMILY"
STRATA_MODEL="$STRATA_MODEL"
STRATA_CONTEXT="$STRATA_CONTEXT"
STRATA_VISION="$STRATA_VISION"
STRATA_DATA_DIR="$STRATA_DATA_DIR"
EOF
}

load_env() {
    # shellcheck source=/dev/null
    [[ -f "$STRATA_ENV_FILE" ]] && source "$STRATA_ENV_FILE"
    STRATA_DIR="${STRATA_DIR:-$HOME/strata}"
    STRATA_PORT="${STRATA_PORT:-8080}"
}

strata_base_url() { echo "http://127.0.0.1:${STRATA_PORT}"; }

ensure_clone() {
    if [[ -f "$STRATA_DIR/setup.sh" ]]; then
        return 0
    fi
    if [[ -e "$STRATA_DIR" && ! -d "$STRATA_DIR" ]]; then
        err "$STRATA_DIR exists and is not a directory."
        exit 1
    fi
    info "Cloning Strata ($STRATA_REPO) into $STRATA_DIR ..."
    info "Upstream project is MIT-licensed; see $STRATA_DIR/LICENSE after clone."
    git clone "$STRATA_REPO" "$STRATA_DIR" \
        || { err "git clone failed — check network access to github.com"; exit 1; }
    ok "Strata cloned."
}

# Resolve the run script Strata's setup wrote (run-<family-tag>_<size>.sh, lower case).
find_run_script() {
    local s
    s="$(ls -t "$STRATA_DIR"/run-*.sh 2>/dev/null | head -1 || true)"
    echo "$s"
}

# ── CUDA toolkit detection ─────────────────────────────────────────────────────
# Strata's ready-made Linux engine is built with CUDA 13.0; when it must compile
# the engine itself it hard-requires nvcc >= 13.0 (setup.py: need_cuda = (13, 0)).
# Strata's own find_nvcc() looks, in order: $STRATA_NVCC, `nvcc` on PATH,
# $CUDA_HOME/bin/nvcc, $CUDA_PATH/bin/nvcc, /usr/local/cuda*/bin/nvcc,
# /opt/cuda*/bin/nvcc — and rejects anything older than 13.0.
#
# We mirror that search here so `check` / `update` can tell the user exactly what
# is missing before Strata's 40- minute auto-installer (which only knows
# Ubuntu 22.04/24.04 and Debian 12/13) gives up on any other distro.
cuda_toolkit_root() {
    local cand
    if [[ -n "${STRATA_NVCC:-}" && -x "$STRATA_NVCC" ]]; then
        echo "$STRATA_NVCC"; return
    fi
    # If a nvcc on PATH is already 13.x, it wins (matches Strata's own order).
    if command -v nvcc >/dev/null 2>&1; then
        local pv
        pv="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
        if [[ "$pv" =~ ^13\. ]]; then
            command -v nvcc; return
        fi
        # Stale distro toolkit (e.g. Ubuntu's 12.x nvidia-cuda-toolkit) on PATH:
        # keep looking for a proper 13.x install below, and only fall back to
        # the PATH one if nothing better is found.
        _stale_nvcc="$(command -v nvcc)"
    fi
    # NOTE: this script is bash-only (#!/usr/bin/env bash). In bash, an
    # unmatched glob stays a literal string, so the -x test below is false
    # and the loop simply moves on — no special handling needed.
    for cand in \
        "${CUDA_HOME:-/usr/local/cuda}/bin/nvcc" \
        "${CUDA_PATH:-/usr/local/cuda}/bin/nvcc" \
        /usr/local/cuda*/bin/nvcc \
        /opt/cuda*/bin/nvcc; do
        [[ -x "$cand" ]] && { echo "$cand"; return; }
    done
    if [[ -n "${_stale_nvcc:-}" ]]; then
        echo "$_stale_nvcc"; return
    fi
    return 1
}

cuda_toolkit_version() {
    local nvcc
    nvcc="$(cuda_toolkit_root || true)"
    [[ -z "$nvcc" ]] && { echo ""; return; }
    "$nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
}

cuda_driver_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1
}

# Print a one-screen summary of the CUDA toolchain state. Used by `check` and
# `update` so a failing install says what is wrong instead of "install from
# nvidia.com".
print_cuda_status() {
    local distro_id distro_ver nvcc_path cuda_v drv
    distro_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)"
    distro_ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)"
    nvcc_path="$(cuda_toolkit_root || true)"
    cuda_v="$(cuda_toolkit_version)"
    drv="$(cuda_driver_version)"
    echo "  distro:        ${distro_id:-?} ${distro_ver:-?}"
    echo "  nvcc path:     ${nvcc_path:-<not found>}"
    echo "  CUDA toolkit:  ${cuda_v:-<none>}"
    echo "  GPU driver:    ${drv:-<nvidia-smi not available>}"
    if [[ -z "$cuda_v" ]]; then
        warn "No CUDA toolkit found. Strata needs CUDA >= ${CUDA_MIN} to compile its engine on Linux."
        warn "Run 'bash scripts/strata.sh update-cuda' to install it automatically (sudo required)."
    elif [[ ! "$cuda_v" =~ ^13\. ]]; then
        warn "CUDA $cuda_v is older than Strata's minimum (${CUDA_MIN})."
        warn "Run 'bash scripts/strata.sh update-cuda' to install CUDA 13.x automatically (sudo required)."
    else
        ok "CUDA $cuda_v is OK for Strata."
    fi
    if [[ -n "$drv" ]]; then
        local drv_major="${drv%%.*}"
        if [[ "$drv_major" =~ ^[0-9]+$ ]] && (( drv_major < 580 )); then
            warn "GPU driver $drv is older than Strata's minimum (580 for CUDA 13). Update the driver and reboot."
        fi
    fi
}

cmd_check() {
    ensure_clone
    info "CUDA toolchain:"
    print_cuda_status
    echo ""
    info "Running Strata hardware preflight (./setup.sh --check) ..."
    (cd "$STRATA_DIR" && ./setup.sh --check)
}

# Install the CUDA 13.x toolkit via NVIDIA's official apt repo (same keyring
# flow Strata's own installer uses, but with a codename fallback so brand-new
# Ubuntu releases — e.g. 26.04, where NVIDIA has no repo yet — still work by
# using the newest published one). Returns 0 when a usable 13.x nvcc exists.
install_cuda_toolkit() {
    local id ver cn arch repo_url cur
    id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    cn="$(. /etc/os-release 2>/dev/null && echo "${UBUNTU_CODENAME:-}")"
    if [[ -z "$cn" && -f /etc/upstream-release/lsb-release ]]; then
        cn="$(. /etc/upstream-release/lsb-release 2>/dev/null && echo "${DISTRIB_CODENAME:-}")"
    fi
    [[ -z "$cn" ]] && cn="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"

    if [[ "$id" != "ubuntu" ]] && ! printf '%s' "${ID_LIKE:-}" | grep -qw ubuntu; then
        err "Automatic CUDA install supports Ubuntu and Ubuntu derivatives."
        err "On this distro ($id $ver) install it yourself:"
        err "  https://developer.nvidia.com/cuda-downloads   (needs CUDA 13.x)"
        return 1
    fi
    arch="$(dpkg --print-architecture 2>/dev/null || echo x86_64)"
    # NVIDIA's repo dirs are named by release number (ubuntu2404), not by
    # lsb-release codename (noble) — the codename path 404s even on the
    # distros where the repo exists.
    local cn_num="${ver//./}"
    [[ -n "$cn_num" ]] || cn_num="${cn//[^0-9]/}"
    [[ -n "$cn_num" ]] || { err "Cannot determine the Ubuntu release number from /etc/os-release."; return 1; }
    repo_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${cn_num}/${arch}"
    if ! curl -fsSL --max-time 20 "${repo_url}/${CUDA_KEYRING_DEB}" -o /dev/null 2>&1; then
        local t
        for t in "${CUDA_REPO_FALLBACKS[@]}"; do
            if curl -fsSL --max-time 20 "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${t}/${arch}/${CUDA_KEYRING_DEB}" -o /dev/null 2>&1; then
                warn "NVIDIA has no CUDA repo for Ubuntu ${ver} yet — using the ubuntu${t} repo (packages are compatible)."
                repo_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${t}/${arch}"
                break
            fi
        done
    fi
    # If neither the distro's own repo nor any fallback answered, the network
    # (or NVIDIA's) is not reachable.
    if ! curl -fsSL --max-time 20 "${repo_url}/${CUDA_KEYRING_DEB}" -o /dev/null 2>&1; then
        err "Could not reach any NVIDIA CUDA apt repo."
        err "Checked: $(for t in "${CUDA_REPO_FALLBACKS[@]}"; do printf 'ubuntu%s ' "$t"; done)ubuntu${cn_num}"
        return 1
    fi

    info "Adding NVIDIA CUDA apt repo (ubuntu$(basename "$(dirname "$(dirname "$repo_url")")") / ${arch}) ..."
    if ! curl -fsSL "${repo_url}/${CUDA_KEYRING_DEB}" | sudo dpkg -i; then
        err "Failed to install the CUDA keyring package."
        return 1
    fi
    sudo apt-get update
    info "Installing cuda-toolkit-13-0 (about 4 GB; sudo may ask for your password) ..."
    if ! sudo apt-get install -y cuda-toolkit-13-0; then
        err "apt install cuda-toolkit-13-0 failed."
        return 1
    fi

    # Prefer the NVIDIA 13.0 toolkit over any stale distro nvcc (e.g. the
    # 12.x from Ubuntu's own nvidia-cuda-toolkit) by putting it first on PATH
    # for this session and for future shells.
    local c13
    c13="$(ls -d /usr/local/cuda-13.0 /usr/local/cuda-13* 2>/dev/null | head -1 || true)"
    [[ -n "$c13" ]] || c13="$(readlink -f /usr/local/cuda 2>/dev/null || true)"
    if [[ -n "$c13" && -x "$c13/bin/nvcc" ]]; then
        export PATH="$c13/bin:$PATH"
        local rc
        for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
            if [[ -f "$rc" ]] && ! grep -q "local/cuda" "$rc" 2>/dev/null; then
                {
                    echo ""
                    echo "# CUDA toolkit (added by openmono strata.sh)"
                    echo 'export PATH="/usr/local/cuda/bin:$PATH"'
                } >> "$rc"
                info "Added /usr/local/cuda/bin to PATH in $(basename "$rc")"
            fi
        done
    fi

    cur="$(cuda_toolkit_version)"
    if [[ "$cur" =~ ^13\. ]]; then
        ok "CUDA $cur installed at $(cuda_toolkit_root) (Strata minimum: ${CUDA_MIN})."
        return 0
    else
        err "Install finished but the active nvcc reports '${cur:-unknown}', not 13.x."
        err "Run: export PATH=/usr/local/cuda/bin:\$PATH   and check: nvcc --version"
        return 1
    fi
}

# Install (or refresh) the CUDA 13.x toolkit. Safe to run from `openmono setup`
# — it is a no-op when a 13.x toolkit is already active.
cmd_update_cuda() {
    local cur
    cur="$(cuda_toolkit_version)"
    info "Current CUDA toolkit: ${cur:-<none>}"
    if [[ "$cur" =~ ^13\. ]]; then
        info "Refreshing CUDA 13.x packages (sudo may ask for your password) ..."
        sudo apt-get update
        sudo apt-get install --only-upgrade -y cuda-toolkit-13-0 || true
        ok "CUDA toolkit refreshed to $(cuda_toolkit_version)."
        return 0
    fi
    info "Installing CUDA 13.x toolkit (Strata needs >= ${CUDA_MIN}) ..."
    install_cuda_toolkit
}

cmd_install() {
    # `--yes` is consumed here (added to setup args); everything else after
    # `install` is forwarded to Strata's setup.sh verbatim,
    # e.g.: strata.sh install --yes --family coder
    ensure_clone
    local extra=()
    local setup_args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) setup_args+=(--yes) ;;
            *) extra+=("$arg") ;;
        esac
    done
    [[ "${STRATA_YES:-0}" == "1" ]] && setup_args+=(--yes)
    [[ -n "$STRATA_FAMILY" ]] && setup_args+=(--family "$STRATA_FAMILY")
    [[ -n "$STRATA_MODEL" ]] && setup_args+=(--model "$STRATA_MODEL")
    [[ -n "$STRATA_CONTEXT" ]] && setup_args+=(--context "$STRATA_CONTEXT")
    [[ -n "$STRATA_VISION" ]] && setup_args+=(--vision "$STRATA_VISION")
    [[ "$STRATA_PORT" != "8080" ]] && setup_args+=(--port "$STRATA_PORT")
    [[ -n "$STRATA_DATA_DIR" ]] && setup_args+=(--data-dir "$STRATA_DATA_DIR")
    setup_args+=(--no-start)
    info "CUDA toolchain (Strata needs >= ${CUDA_MIN} to compile the engine on Linux):"
    print_cuda_status
    # Auto-fix: if there is no usable 13.x toolkit, install one NOW instead of
    # letting Strata's build burn ~40 minutes only to fail at the end.
    # (Strata's own auto-installer only knows ubuntu2204/2404 + debian12/13;
    # on any other Ubuntu this is the only working path.)
    local cuda_v_now
    cuda_v_now="$(cuda_toolkit_version)"
    if [[ ! "$cuda_v_now" =~ ^13\. ]]; then
        echo ""
        if [[ "${STRATA_YES:-0}" == "1" || "${setup_args[*]:-}" == *--yes* || "${OPENMONO_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
            info "CUDA ${cuda_v_now:-none} does not satisfy the ${CUDA_MIN} requirement — installing it automatically (non-interactive mode) ..."
        else
            printf "  CUDA ${cuda_v_now:-none} does not satisfy the ${CUDA_MIN} requirement. Install CUDA 13.x now? [Y/n] "
            local _cuda_answer
            read -r _cuda_answer || _cuda_answer=""
            case "${_cuda_answer:-Y}" in
                [Nn]*) err "Aborted — run 'bash scripts/strata.sh update-cuda' later, then retry the install."; exit 1 ;;
            esac
        fi
        if ! install_cuda_toolkit; then
            err "Automatic CUDA install failed. Manual fallback: https://developer.nvidia.com/cuda-downloads (CUDA 13.x), then retry."
            exit 1
        fi
        echo ""
        info "CUDA toolchain after install:"
        print_cuda_status
        echo ""
    fi
    info "Installing Strata model (this downloads ~70 GB on first run; resumable) ..."
    info "  setup args: ${setup_args[*]} ${extra[*]}"
    info "  Strata will prompt unless --yes was passed (non-interactive installs add it)."
    # Stream Strata's output live AND capture it in its own log file. A bare
    # `./setup.sh` call would let its error output vanish into the terminal
    # (interleaved with prompts) or the OpenMono log (stderr only) — neither
    # is easy to find later. On failure we tail the capture so the real error
    # is always on screen and in the OpenMono log.
    local strata_out
    mkdir -p "$OPENMONO_STATE_DIR"
    strata_out="$OPENMONO_STATE_DIR/strata-setup.log"
    (cd "$STRATA_DIR" && ./setup.sh "${setup_args[@]}" "${extra[@]}") 2>&1 | tee -a "$strata_out"
    local setup_rc=${PIPESTATUS[0]}
    if [ "$setup_rc" -ne 0 ]; then
        echo ""
        err "Strata ./setup.sh failed (exit $setup_rc) — last 30 lines:"
        tail -n 30 "$strata_out" | sed 's/^/    /'
        echo ""
        err "Full Strata setup output: $strata_out"
        exit "$setup_rc"
    fi
    save_env
    ok "Strata installed. Start it with: openmono start   (or scripts/strata.sh start)"
    ok "Browse the model UI at: $(strata_base_url)  (after start)"
}

server_wait_healthy() {
    local tries="${1:-36}" url
    url="$(strata_base_url)/health"
    for ((i = 1; i <= tries; i++)); do
        if curl -sf "$url" &>/dev/null; then
            return 0
        fi
        sleep 5
        printf "."
    done
    return 1
}

cmd_start() {
    load_env
    if [[ ! -f "$STRATA_DIR/setup.sh" ]]; then
        err "Strata is not installed at $STRATA_DIR. Run: openmono setup   (or scripts/strata.sh install)"
        exit 1
    fi
    if curl -sf "$(strata_base_url)/health" &>/dev/null; then
        ok "Strata already serving at $(strata_base_url)"
        return 0
    fi
    local run_script
    run_script="$(find_run_script)"
    if [[ -z "$run_script" ]]; then
        err "No run-*.sh found in $STRATA_DIR — install first: scripts/strata.sh install"
        exit 1
    fi
    info "Starting Strata ($run_script) detached ..."
    mkdir -p "$OPENMONO_STATE_DIR"
    # Strata's run script is foreground-oriented; detach so the shell returns.
    nohup bash "$run_script" > "$STRATA_LOG" 2>&1 &
    echo "$!" > "$STRATA_PID_FILE"
    info "Waiting for $(strata_base_url)/health (first boot loads 35-55 GB; PC may feel slow for 1-3 min) ..."
    if server_wait_healthy 36; then
        echo ""
        ok "Strata is healthy at $(strata_base_url)  (OpenAI base: $(strata_base_url)/v1)"
    else
        echo ""
        warn "Not healthy after ~3 min — model may still be loading on first boot."
        warn "Watch: tail -f $STRATA_LOG   (engine detail: $STRATA_DIR/strata-*.log)"
    fi
}

cmd_stop() {
    load_env
    local stopped=0
    if [[ -f "$STRATA_PID_FILE" ]]; then
        local pid
        pid="$(cat "$STRATA_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            info "Stopping Strata (pid $pid) ..."
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 15); do
                kill -0 "$pid" 2>/dev/null || { stopped=1; break; }
                sleep 1
            done
            kill -9 "$pid" 2>/dev/null || true
            stopped=1
        fi
        rm -f "$STRATA_PID_FILE"
    fi
    # Fallback: anything still listening on the port (covers servers started by hand).
    if curl -sf "$(strata_base_url)/health" &>/dev/null; then
        warn "Server still responding on $(strata_base_url) — it was started outside strata.sh; stop that process to free port $STRATA_PORT."
        return 1
    fi
    [[ "$stopped" == "1" ]] && ok "Strata stopped." || info "Strata is not running."
}

cmd_status() {
    load_env
    local url models
    url="$(strata_base_url)"
    echo -n "strata ($url): "
    if curl -sf "$url/health" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(('HEALTHY model=' + str(d.get('model','?')) + ' ctx=' + str(d.get('max_context','?'))) if d.get('loaded') else 'LOADING')" 2>/dev/null; then
        true
    else
        echo -e "${RED}UNREACHABLE${NC}"
    fi
    echo -n "OpenAI endpoint ($url/v1): "
    models="$(curl -sf "$url/v1/models" 2>/dev/null || true)"
    if [[ -n "$models" ]]; then
        echo "$models" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m.get('id','?') for m in d.get('data',[])) or 'reachable (no models listed)')" 2>/dev/null \
            || echo "reachable"
    else
        echo -e "${RED}unreachable${NC}"
    fi
}

cmd_logs() {
    local tail_n=100
    [[ "${1:-}" == "--tail" && -n "${2:-}" ]] && tail_n="$2"
    if [[ -f "$STRATA_LOG" ]]; then
        tail -n "$tail_n" -f "$STRATA_LOG"
    else
        warn "No wrapper log yet at $STRATA_LOG."
        warn "Strata engine logs live in $STRATA_DIR/strata-*.log (after the first start)."
        ls -t "$STRATA_DIR"/strata-*.log 2>/dev/null | head -5 || true
        exit 1
    fi
}

cmd_update() {
    ensure_clone
    info "Updating Strata (git pull + ./update.sh, server not started) ..."
    (cd "$STRATA_DIR" && git pull --ff-only || warn "git pull failed — continuing with ./update.sh")
    (cd "$STRATA_DIR" && ./update.sh)
    ok "Strata updated."
}

case "${1:-help}" in
    check)         shift; cmd_check "$@" ;;
    install)       shift; cmd_install "$@" ;;
    start)         shift; cmd_start "$@" ;;
    stop)          shift; cmd_stop "$@" ;;
    status)        shift; cmd_status "$@" ;;
    logs)          shift; cmd_logs "$@" ;;
    update)        shift; cmd_update "$@" ;;
    update-cuda)   shift; cmd_update_cuda "$@" ;;
    help|--help|-h|*)
        sed -n '2,/^# ─*$/p' "$0" | sed 's/^# \?//'
        ;;
esac
