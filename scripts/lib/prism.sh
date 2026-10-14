#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# OpenMono.ai — Prism (Ternary Bonsai 2 27B) helpers
#
# Sourced by scripts/install.sh (Linux). Do not execute directly.
#
# The stock ghcr.io/ggml-org/llama.cpp images REJECT the Bonsai ternary
# packings (PQ2_0 / PTQ1_0) as unknown types — and silently produce garbage
# if forced through a Q2_0 path (no Hadamard activation runtime). Bonsai
# requires the PrismML-Eng/llama.cpp fork:
#   https://github.com/PrismML-Eng/llama.cpp
#
# On Linux we ship that fork as a prebuilt Docker image hosted on a CDN.
# NOTE: the CDN image is NVIDIA/CUDA-only (tag :cuda). There is no Vulkan
# (AMD iGPU) or CPU tarball yet, and no macOS story — Bonsai install is
# gated to GPU_MODE=1 until those exist.
# ──────────────────────────────────────────────────────────────────────────────

# Canonical defaults. Override via env:
#   OPENMONO_PRISM_CDN_URL  full URL of the gzipped docker image tarball
#   OPENMONO_PRISM_IMAGE    expected image ref once loaded (tag inside tarball)
PRISM_CDN_URL_DEFAULT="http://cdn.cleanrouter.com/docker/llama-cpp-prism.tar.gz"
PRISM_IMAGE_DEFAULT="llama-cpp-prism:cuda"

# Bonsai model files (verified against the HF repo file list).
PRISM_HF_BASE="https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/main"
PRISM_MODEL_PQ2_NAME="Ternary-Bonsai-2-27B-PQ2_0.gguf"    # 7.21 GB — faster decode on Hopper/Blackwell, faster PP everywhere
PRISM_MODEL_PTQ1_NAME="Ternary-Bonsai-2-27B-PTQ1_0.gguf"  # 5.95 GB — faster decode on Ada/L4, pick when VRAM is tightest
PRISM_MMPROJ_NAME="Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf" # ~0.63 GB vision tower (Q8_0), optional

# Bonsai (Prism) model selection. Arg $1: pq2 (default) or ptq1.
# Sets MODEL_NAME/MODEL_URL/MODEL_ACCURACY/MODEL_MMPROJ/MODEL_MMPROJ_URL/
# MODEL_ALIAS/_MODEL_LABEL and IS_BONSAI=1. Shared by the Linux and macOS
# installers — no OS-specific logic here.
# PQ2_0 (7.21GB): faster decode on Hopper/Blackwell/A100, faster PP everywhere,
#   the pack measured on Apple Silicon — default when memory allows.
# PTQ1_0 (5.95GB): faster decode on Ada/L4, smallest footprint — pick on 8GB cards.
select_bonsai_model() {
    local quant="${1:-pq2}"
    if [ "$quant" = "ptq1" ]; then
        MODEL_NAME="$PRISM_MODEL_PTQ1_NAME"
        MODEL_URL="$PRISM_HF_BASE/$PRISM_MODEL_PTQ1_NAME"
        MODEL_ACCURACY="bonsai-ptq1"
        _MODEL_LABEL="Ternary-Bonsai-2-27B-PTQ1_0 (~5.9GB) [tightest memory]"
    else
        MODEL_NAME="$PRISM_MODEL_PQ2_NAME"
        MODEL_URL="$PRISM_HF_BASE/$PRISM_MODEL_PQ2_NAME"
        MODEL_ACCURACY="bonsai-pq2"
        _MODEL_LABEL="Ternary-Bonsai-2-27B-PQ2_0 (~7.2GB) [recommended]"
    fi
    MODEL_MMPROJ="$PRISM_MMPROJ_NAME"
    MODEL_MMPROJ_URL="$PRISM_HF_BASE/$PRISM_MMPROJ_NAME"
    MODEL_ALIAS="${MODEL_NAME%.gguf}"
    IS_BONSAI=1
}

# Context presets for Bonsai. The backbone supports 262K, but KV cache is what
# eats VRAM — on small cards keep this conservative. Quickstart uses -c 32768.
# Validated: PQ2_0 + q4 KV @ 98304 ctx rests at ~9GB on a 12GB RTX 3060
# (~19KB/token KV) — presets below extrapolate linearly from that datapoint.
CTX_BONSAI_24G=196608
CTX_BONSAI_16G=131072
CTX_BONSAI_12G=98304
CTX_BONSAI_8G=32768

prism_cdn_url()   { echo "${OPENMONO_PRISM_CDN_URL:-$PRISM_CDN_URL_DEFAULT}"; }
prism_image_ref() { echo "${OPENMONO_PRISM_IMAGE:-$PRISM_IMAGE_DEFAULT}"; }

# prism_image_available — true if the image ref is already in the local daemon.
prism_image_available() {
    docker image inspect "$(prism_image_ref)" &>/dev/null 2>&1
}

# pull_img_from_cdn — stream the gzipped image tarball from the CDN straight
# into `docker load` (no intermediate file on disk).
#
#   curl -fsSL <cdn-url> | gunzip -c | docker load
#
# Idempotent: skips when the image ref already exists locally, unless
# OPENMONO_PRISM_FORCE_PULL=1. Returns non-zero on failure.
pull_img_from_cdn() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "pull_img_from_cdn: Linux-only for now (native Metal build needed on macOS — see prism.sh notes)"
        return 1
    fi
    command -v docker &>/dev/null || { err "pull_img_from_cdn: docker not found"; return 1; }
    command -v curl &>/dev/null   || { err "pull_img_from_cdn: curl not found"; return 1; }
    command -v gunzip &>/dev/null || { err "pull_img_from_cdn: gunzip not found"; return 1; }

    if prism_image_available && [[ "${OPENMONO_PRISM_FORCE_PULL:-0}" != "1" ]]; then
        ok "Prism image already present ($(prism_image_ref)) — skipping CDN pull"
        return 0
    fi

    local url; url="$(prism_cdn_url)"
    info "Pulling Prism llama.cpp image from CDN..."
    detail "URL: $url"
    detail "Target ref: $(prism_image_ref)"

    # Probe first so DNS/firewall failures surface fast with a clear message.
    if ! curl -sIL --fail --max-time 15 "$url" >/dev/null 2>&1; then
        err "CDN URL is not reachable: $url"
        err "Check network/firewall, or set a mirror via OPENMONO_PRISM_CDN_URL=<url>"
        return 1
    fi

    # Stream: CDN tarball (gzip) -> gunzip -> docker load. run_live streams to
    # the user AND the setup log (this can be a multi-GB transfer).
    if ! run_live bash -c "curl -fsSL '$url' | gunzip -c | docker load"; then
        err "docker load from CDN failed"
        err "Retry with OPENMONO_VERBOSE=1, or manually: curl -fsSL '$url' | gunzip -c | docker load"
        return 1
    fi

    if ! prism_image_available; then
        warn "docker load succeeded but '$(prism_image_ref)' not found in local images."
        warn "The tarball may tag the image differently. Available prism images:"
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i -E 'prism|llama|bonsai' | sed 's/^/    /' || true
        err "Set the loaded tag explicitly: OPENMONO_PRISM_IMAGE=<repo:tag> openmono setup"
        return 1
    fi

    ok "Prism image ready ($(prism_image_ref))"
}

# ── macOS native (Metal) build ────────────────────────────────────────────────
# No prebuilt macOS image exists (and a curl'd tarball would trip Gatekeeper
# quarantine anyway). Instead we clone the fork and build on-machine: the
# installer already mandates cmake + Xcode CLT on inference-capable Macs,
# inference is arm64-only, and Metal is the default backend — no flags.
#
# Binaries live OUTSIDE the repo at ~/.openmono/prism-llama.cpp so
# `openmono upgrade` (git pull) never touches them. The path is recorded in
# ~/.openmono/settings.json (.inference.binary) and preferred by
# scripts/macos/inference.sh; the brew stock binary stays for the Qwen path.

PRISM_GIT_URL="https://github.com/PrismML-Eng/llama.cpp"
# Pinned fork tag (deterministic builds). Override with OPENMONO_PRISM_REF.
# Known-good tags look like prism-b10772-e8fd209 (prism-<upstream#>-<sha>).
PRISM_GIT_REF_DEFAULT="prism-b10772-e8fd209"

prism_git_ref()   { echo "${OPENMONO_PRISM_REF:-$PRISM_GIT_REF_DEFAULT}"; }
prism_macos_src() { echo "${OPENMONO_PRISM_SRC:-$HOME/.openmono/prism-llama.cpp}"; }
prism_macos_bin() { echo "$(prism_macos_src)/build/bin/llama-server"; }
prism_macos_cli() { echo "$(prism_macos_src)/build/bin/llama-cli"; }

prism_binary_available() {
    [[ -x "$(prism_macos_bin)" ]]
}

# build_prism_macos — shallow-clone the pinned fork ref and build
# llama-server + llama-cli with the default (Metal) backend.
# Idempotent: skips when the binary exists and the checkout matches the
# pinned ref, unless OPENMONO_PRISM_FORCE_BUILD=1.
build_prism_macos() {
    if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
        err "build_prism_macos: Apple Silicon (arm64) Macs only"
        return 1
    fi
    command -v git &>/dev/null   || { err "build_prism_macos: git not found"; return 1; }
    command -v cmake &>/dev/null || { err "build_prism_macos: cmake not found (run install_prereqs_macos.sh)"; return 1; }
    xcode-select -p &>/dev/null  || { err "build_prism_macos: Xcode CLT missing (run install_prereqs_macos.sh)"; return 1; }

    local src ref; src="$(prism_macos_src)"; ref="$(prism_git_ref)"
    info "Prism fork pinned to: $ref"
    info "To update the pin: OPENMONO_PRISM_REF=<tag> openmono setup  (tags: git ls-remote --tags $PRISM_GIT_URL)"
    if prism_binary_available && [[ "${OPENMONO_PRISM_FORCE_BUILD:-0}" != "1" ]]; then
        if [[ "$(git -C "$src" describe --tags --exact-match 2>/dev/null || echo '')" == "$ref" ]]; then
            ok "Prism llama-server already built ($ref) — skipping rebuild"
            detail "$(prism_macos_bin)"
            return 0
        fi
        info "Existing Prism build is not $ref — rebuilding..."
        rm -rf "$src"
    fi

    info "Cloning Prism llama.cpp ($ref) — shallow, one-time cost..."
    detail "$PRISM_GIT_URL → $src"
    rm -rf "$src"
    if ! run git clone --depth 1 --branch "$ref" "$PRISM_GIT_URL" "$src"; then
        err "git clone of $PRISM_GIT_URL@$ref failed"
        err "Check network, or pin another ref: OPENMONO_PRISM_REF=<tag> openmono setup"
        return 1
    fi

    info "Building llama-server + llama-cli (Metal default, $(sysctl -n hw.ncpu 2>/dev/null || echo 4) jobs)..."
    info "This takes ~5–10 min on Apple Silicon — same phase as the model download."
    if ! run_live cmake -S "$src" -B "$src/build"; then
        err "cmake configure failed for the Prism fork"
        return 1
    fi
    if ! run_live cmake --build "$src/build" -j --target llama-server llama-cli; then
        err "Prism fork build failed"
        err "Retry with OPENMONO_VERBOSE=1, or force a clean rebuild: OPENMONO_PRISM_FORCE_BUILD=1 openmono setup"
        return 1
    fi

    prism_binary_available || { err "Build finished but $(prism_macos_bin) is missing"; return 1; }
    ok "Prism llama-server ready ($(prism_macos_bin))"
}

# ── macOS native (Metal) notes ────────────────────────────────────────────────
# There is no prebuilt macOS image — Metal cannot run inside a Linux container
# anyway. The documented path is a native build of the Prism fork:
#
#   git clone https://github.com/PrismML-Eng/llama.cpp && cd llama.cpp
#   cmake -B build && cmake --build build -j --target llama-server llama-cli
#   # NOTE: drop -DGGML_CUDA=ON on macOS — Metal is the default backend.
#
# Whether the fork's custom ternary kernels compile/run cleanly under Metal on
# Apple Silicon is UNVERIFIED — the model card claims a Metal backend and shows
# Apple-Silicon throughput rows (M5 Max ~47 tok/s), but until someone builds
# and runs it locally, treat macOS+Bonsai as experimental. Linux+Docker is the
# supported path for now.
