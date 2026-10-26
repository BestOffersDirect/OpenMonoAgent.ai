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
# Remember the dotnet that was on PATH before we prepend ~/.dotnet. If the new
# host cannot execute, this keeps detection/reporting honest instead of
# collapsing to "0".
DOTNET_ORIGINAL_BIN="${DOTNET_ORIGINAL_BIN:-$(command -v dotnet 2>/dev/null || true)}"

# dotnet_version_ge <have> [floor] — true when <have> is >= <floor>.
# Pure awk comparison: BSD/GNU sort and pipefail differences cannot break it.
dotnet_version_ge() {
    local have="${1:-}" floor="${2:-$DOTNET_SDK_FLOOR}"
    [[ -n "$have" && "$have" != "0" ]] || return 1
    awk -v have="$have" -v floor="$floor" 'BEGIN {
        nh = split(have, h, ".")
        nf = split(floor, f, ".")
        for (i = 1; i <= 3; i++) {
            hv = (i <= nh) ? h[i] + 0 : 0
            fv = (i <= nf) ? f[i] + 0 : 0
            if (hv > fv) exit 0
            if (hv < fv) exit 1
        }
        exit 0
    }'
}

# Print the highest SDK version exposed by one dotnet binary. Prints nothing
# when the binary produced no SDK list (missing, killed, or otherwise broken).
_dotnet_sdk_of() {
    local bin="${1:-}" best="0" ver
    [[ -n "$bin" && -x "$bin" ]] || return 1
    while IFS= read -r ver; do
        [[ -n "$ver" ]] || continue
        if [[ "$best" == "0" ]] || dotnet_version_ge "$ver" "$best"; then
            best="$ver"
        fi
    done < <("$bin" --list-sdks 2>/dev/null | awk '{print $1}')
    [[ "$best" == "0" ]] || printf '%s' "$best"
}

# Print the highest SDK version available from the pre-install PATH dotnet,
# the current PATH dotnet, or ~/.dotnet. "0" means none was readable.
dotnet_best_sdk() {
    local bin ver best="0"
    hash -r 2>/dev/null || true
    for bin in "$DOTNET_ORIGINAL_BIN" "$(command -v dotnet 2>/dev/null || true)" "$DOTNET_INSTALL_DIR/dotnet"; do
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
    # PATH changed; drop bash's cached command locations so `dotnet` resolves
    # to the newly installed host instead of a stale entry.
    hash -r 2>/dev/null || true
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

# Re-create the dotnet host binary so it gets a fresh vnode (same bytes, new
# inode). macOS caches code-signature validation per vnode: if the file was
# rewritten in place, the cache can keep reporting "Invalid Signature" and the
# kernel SIGKILLs every exec (exit 137) even though `codesign --verify` passes
# and the contents are intact. A new inode clears that state. Safe/idempotent
# on Linux too — it is just an atomic copy.
_dotnet_refresh_host() {
    local bin="$DOTNET_INSTALL_DIR/dotnet" tmp
    [[ -x "$bin" ]] || return 1
    tmp="$(mktemp "$DOTNET_INSTALL_DIR/.dotnet.XXXXXX" 2>/dev/null)" || return 1
    if ! cp -p "$bin" "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if ! mv -f "$tmp" "$bin" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    hash -r 2>/dev/null || true
    return 0
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

    # A host that exists but reports no SDKs is broken, not absent. Recover it
    # before prompting/downloading; on macOS this is the stale-vnode case above.
    # Checked directly (not via dotnet_best_sdk) so a healthy dotnet on PATH
    # cannot hide a broken ~/.dotnet host that the shell rc files will use later.
    if [[ -x "$DOTNET_INSTALL_DIR/dotnet" ]] \
        && [[ -z "$(_dotnet_sdk_of "$DOTNET_INSTALL_DIR/dotnet" || true)" ]]; then
        if _dotnet_refresh_host \
            && [[ -n "$(_dotnet_sdk_of "$DOTNET_INSTALL_DIR/dotnet" || true)" ]]; then
            detail "Re-created the .NET host binary to clear a stale code-signature state."
        fi
    fi

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

    # Activate only if the new host can actually report its SDKs. If it cannot,
    # leave the previous PATH intact and let the verification below diagnose it.
    dotnet_activate_best || true

    for rc in ${rc_files[@]+"${rc_files[@]}"}; do
        [[ -f "$rc" ]] || continue
        if grep -q "DOTNET_ROOT" "$rc"; then
            continue
        fi
        {
            echo ""
            echo "# .NET SDK"
            # These must stay literal so the rc file expands them at login.
            # shellcheck disable=SC2016
            echo 'export DOTNET_ROOT="$HOME/.dotnet"'
            # shellcheck disable=SC2016
            echo 'export PATH="$DOTNET_ROOT:$PATH"'
        } >> "$rc"
        detail "Added .NET to PATH in $(basename "$rc")"
    done

    current="$(dotnet_best_sdk)"
    if ! dotnet_version_ge "$current" "$DOTNET_SDK_FLOOR" && [[ -x "$DOTNET_INSTALL_DIR/dotnet" ]]; then
        # Past in-place overwrites can leave macOS denying exec for this vnode.
        # Re-create the host file, then re-check before deciding it failed.
        if _dotnet_refresh_host; then
            dotnet_activate_best || true
            current="$(dotnet_best_sdk)"
            if dotnet_version_ge "$current" "$DOTNET_SDK_FLOOR"; then
                detail "Re-created the .NET host binary to clear a stale code-signature state."
            fi
        fi
    fi
    if ! dotnet_version_ge "$current" "$DOTNET_SDK_FLOOR"; then
        # The SDK files can be present even when the freshly installed host is
        # not runnable from this process (Gatekeeper/quarantine, arch mismatch,
        # sandbox kill). Report the real error instead of a bare "found 0".
        if [[ -d "$DOTNET_INSTALL_DIR/sdk/$DOTNET_SDK_FLOOR" ]]; then
            warn ".NET SDK $DOTNET_SDK_FLOOR is installed under $DOTNET_INSTALL_DIR, but the dotnet CLI did not report it (found ${current:-none})."
            _dotnet_diagnose
            warn "Setup will continue, but repo builds may fail until '$DOTNET_INSTALL_DIR/dotnet --list-sdks' reports $DOTNET_SDK_FLOOR."
            return 0
        fi
        die ".NET SDK $DOTNET_SDK_FLOOR was installed but is not active (found ${current:-none}). Ensure $DOTNET_INSTALL_DIR is on PATH and retry."
    fi
    ok ".NET SDK $current installed"
}

# Print the exact failure from the installed host so the log/user can act on it.
_dotnet_diagnose() {
    local bin="$DOTNET_INSTALL_DIR/dotnet" out="" rc=0
    if [[ ! -x "$bin" ]]; then
        warn "$bin is missing or not executable."
        return 0
    fi
    out="$("$bin" --list-sdks 2>&1)" || rc=$?
    if [[ -n "$out" ]]; then
        warn "'$bin --list-sdks' exited $rc: $out"
    else
        warn "'$bin --list-sdks' exited $rc with no output."
    fi
    if [[ "$rc" == "137" ]]; then
        warn "Exit 137 means the OS killed the host before .NET started (macOS: stale code-signature state for this file). Setup re-created the binary; if this persists, reinstall .NET or reboot."
    fi
    if [[ -d "$DOTNET_INSTALL_DIR/sdk/$DOTNET_SDK_FLOOR" ]]; then
        warn "SDK files present: $DOTNET_INSTALL_DIR/sdk/$DOTNET_SDK_FLOOR"
    else
        warn "SDK files missing: $DOTNET_INSTALL_DIR/sdk/$DOTNET_SDK_FLOOR"
    fi
    return 0
}
