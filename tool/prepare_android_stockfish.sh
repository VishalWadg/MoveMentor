#!/usr/bin/env bash
set -euo pipefail

# Downloads and verifies Stockfish 19 (sf_19, GPLv3) source and its official
# NNUE network (nn-1a298aa575a0.nnue) for Android NDK CMake + asset bundling.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF_TAG="sf_19"
SF_SRC_DEST="${ROOT_DIR}/android/app/src/main/cpp/stockfish"
NET_NAME="nn-1a298aa575a0.nnue"
NET_SHA12="1a298aa575a0"
NET_BYTES="98511183"
NET_DEST="${ROOT_DIR}/assets/nnue/${NET_NAME}"

mkdir -p "$(dirname "${SF_SRC_DEST}")" "$(dirname "${NET_DEST}")"

if [ ! -f "${SF_SRC_DEST}/src/engine.cpp" ]; then
  echo "Cloning Stockfish ${SF_TAG} into ${SF_SRC_DEST}..."
  rm -rf "${SF_SRC_DEST}"
  git clone --depth 1 --branch "${SF_TAG}" \
    https://github.com/official-stockfish/Stockfish.git "${SF_SRC_DEST}"
  rm -rf "${SF_SRC_DEST}/.git"
else
  echo "Stockfish ${SF_TAG} source already present at ${SF_SRC_DEST}."
fi

verify_net() {
  local file="$1"
  [ -f "$file" ] || return 1
  local size
  size=$(wc -c < "$file" | tr -d '[:space:]')
  [ "$size" = "$NET_BYTES" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    local sum
    sum=$(sha256sum "$file" | cut -c 1-12)
    [ "$sum" = "$NET_SHA12" ] || return 1
  elif command -v shasum >/dev/null 2>&1; then
    local sum
    sum=$(shasum -a 256 "$file" | cut -c 1-12)
    [ "$sum" = "$NET_SHA12" ] || return 1
  fi
  return 0
}

if verify_net "${NET_DEST}"; then
  echo "Verified existing NNUE net at ${NET_DEST} (${NET_BYTES} bytes)."
else
  rm -f "${NET_DEST}"
  for url in \
    "https://tests.stockfishchess.org/api/nn/${NET_NAME}" \
    "https://github.com/official-stockfish/networks/raw/master/${NET_NAME}"; do
    echo "Downloading ${NET_NAME} from ${url}..."
    if curl -fsSL --max-time 300 "${url}" -o "${NET_DEST}.tmp"; then
      if verify_net "${NET_DEST}.tmp"; then
        mv "${NET_DEST}.tmp" "${NET_DEST}"
        echo "Downloaded and verified ${NET_NAME}."
        break
      fi
    fi
    rm -f "${NET_DEST}.tmp"
  done
fi

if ! verify_net "${NET_DEST}"; then
  echo "ERROR: Failed to obtain verified ${NET_NAME} (${NET_BYTES} bytes)." >&2
  exit 1
fi
