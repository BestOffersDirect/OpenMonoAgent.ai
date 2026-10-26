#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# OpenMono.ai — shared .NET SDK helpers
#
# The Oct 2026 out-of-band security release is .NET 10 runtime 10.0.14 /
# SDK 10.0.403. `global.json` enforces that SDK floor for builds; these helpers
# make the installers enforce it too, instead of only printing a warning.
#
# Sourced by install_prereqs.sh, install_prereqs_macos.sh, install.sh,
# install_macos.sh, and install-host-bridge.sh. When the ensure/update helpers
# are used, scripts/lib/log.sh must be sourced first for info/ok/warn/die/run.
# ──────────────────────────────────────────────────────────────────────────────

# Bump this in the same change that bumps global.json on a future .NET servicing
# release. Installations are pinned to this exact SDK (not a floating channel).
DOTNET_SDK_FLOOR="${DOTNET_SDK_FLOOR:-10.0.403}"
DOTNET_INSTALL_DIR="${DOTNET_INSTALL_DIR:-$HOME/.dotnet}"

# dotnet_version_ge <have> [floor] — true when <have> is >= <floor>.
dotnet_version_ge() {
    local have="${1:-}" floor="${2:-$DOTNET_SDK_FLOOR}"
    [[ -n "$have" && "$have" != "0" ]] || return 1
    # sed (not head) keeps the upstream `sort` from getting SIGPIPE under pipefail.
    [[ "$(printf '%s\n%s\n' "$floor" "$have" | sort -V | sed -n '1p')" == "$floor" ]]
}

# Print the highest SDK version exposed by one dotnet binary.
_dotnet_sdk_of() {
    local bin="${1:-}"
    [[ -n "$bin" && -x "$bin" ]] || return 1
    "$bin" --list-sdks 2>/dev/null | awk '{print $1}' | sort -V | tail -n1
}

# Print the highest SDK version available from PATH or ~/.dotnet. "0" means none.
dotnet_best_sdk() {
    local bin ver best="0"
    for bin in "$(command -v dotnet 2>/dev/null || true)" "$DOTNET_INSTALL_DIR/dotnet"; do
        [[ -n "$bin" ]] || continue
        ver="$(_dotnet_sdk_of "$bin" || true)"
        [[ -n "$ver" ]] || continue
        if [[ "$best" == "0" ]] || dotnet_version_ge "$ver" "$best"; then
            best="$ver"
        fi
    done
    printf '%s' "$best"
}

# Put the ~/.dotnet install first on PATH for this process. Safe to call when
# it does not exist (returns 1).
dotnet_activate_local() {
    [[ -x "$DOTNET_INSTALL_DIR/dotnet" ]] || return 1
    export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
    case ":$PATH:" in
        *":$DOTNET_INSTALL_DIR:"*) ;;
        *) export PATH="$DOTNET_INSTALL_DIR:$PATH" ;;
    esac
}

# Prefer ~/.dotnet when it has an SDK at least as new as the one on PATH. This
# matters when a distro/Homebrew dotnet shadows the side-by-side install.
dotnet_activate_best() {
    local path_bin local_bin path_ver local_ver
    path_bin="$(command -v dotnet 2>/dev/null || true)"
    local_bin="$DOTNET_INSTALL_DIR/dotnet"
    [[ -x "$local_bin" ]] || return 0

    path_ver="$(_dotnet_sdk_of "$path_bin" || true)"
    local_ver="$(_dotnet_sdk_of "$local_bin" || true)"
    [[ -n "$local_ver" ]] || return 0
    if [[ -z "$path_ver" ]] || dotnet_version_ge "$local_ver" "$path_ver"; then
        dotnet_activate_local
    fi
}

# Decide whether an older SDK should be replaced. Returns 1 when the user or
# OPENMONO_DOTNET_UPDATE opts out.
dotnet_should_update() {
    case "${OPENMONO_DOTNET_UPDATE:-}" in
        0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee])
            info "OPENMONO_DOTNET_UPDATE=0 — skipping the .NET SDK update."
            return 1
            ;;
        1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
            info "OPENMONO_DOTNET_UPDATE=1 — updating the .NET SDK without prompting."
            return 0
            ;;
    esac

    # Security update: unattended installs get the patched SDK automatically.
    # The install is side-by-side, so other projects keep their existing SDK.
    if [[ ! -t 0 ]]; then
        info "Non-interactive shell — installing the patched .NET SDK automatically (set OPENMONO_DOTNET_UPDATE=0 to opt out)."
        return 0
    fi

    local reply=""
    flush_stdin
    printf "  Install .NET SDK %s (side-by-side under %s) now? [Y/n]: " \
        "$DOTNET_SDK_FLOOR" "$DOTNET_INSTALL_DIR"
    read -r reply || reply="Y"
    case "${reply:-Y}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# dotnet_ensure_sdk [rc-file ...]
# Installs the pinned patched SDK when missing/older, then verifies the floor.
# A declined prompt leaves the old SDK in place (with a loud warning) so a
# later `global.json` build failure is predictable rather than silent.
dotnet_ensure_sdk() {
    local -a rc_files=("$@")
    local current rc

    dotnet_activate_best || true
    current="$(dotnet_best_sdk)"

    if dotnet_version_ge "$current" "$DOTNET_SDK_FLOOR"; then
        ok ".NET SDK $current already installed"
        return 0
    fi

    if [[ "$current" != "0" ]]; then
        warn ".NET SDK $current is older than $DOTNET_SDK_FLOOR (Oct 2026 security update)."
        if ! dotnet_should_update; then
            warn "Keeping .NET SDK $current. Repo builds require $DOTNET_SDK_FLOOR+ (global.json) and may fail until it is updated."
            return 0
        fi
    fi

    info "Downloading Microsoft dotnet-install script..."
    run curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    info "Installing .NET SDK $DOTNET_SDK_FLOOR to $DOTNET_INSTALL_DIR..."
    run /tmp/dotnet-install.sh --version "$DOTNET_SDK_FLOOR" --install-dir "$DOTNET_INSTALL_DIR" \
        || die ".NET install failed"
    rm -f /tmp/dotnet-install.sh

    dotnet_activate_local || true

    for rc in ${rc_files[@]+"${rc_files[@]}"}; do
        [[ -f "$rc" ]] || continue
        if grep -q "DOTNET_ROOT" "$rc"; then
            continue
        fi
        {
            echo ""
            echo "# .NET SDK"
            echo 'export DOTNET_ROOT="$HOME/.dotnet"'
            echo 'export PATH="$DOTNET_ROOT:$PATH"'
        } >> "$rc"
        detail "Added .NET to PATH in $(basename "$rc")"
    done

    current="$(dotnet_best_sdk)"
    if ! dotnet_version_ge "$current" "$DOTNET_SDK_FLOOR"; then
        die ".NET SDK $DOTNET_SDK_FLOOR was installed but is not active (found ${current:-none}). Ensure $DOTNET_INSTALL_DIR is on PATH and retry."
    fi
    ok ".NET SDK $current installed"
}
