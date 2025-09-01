#!/usr/bin/env bash
set -euo pipefail

# User-configurable Strap environment (required)
: "${STRAP_GIT_NAME:?Variable not set}"
: "${STRAP_GIT_EMAIL:?Variable not set}"
: "${STRAP_GITHUB_USER:?Variable not set}"

# Bootstrap installer for dotfiles + Strap provisioning
# - Downloads this repo zip into ~/.dotfiles
# - Runs local Strap with predefined env (if provided)
# - Triggers post-strap script to apply macOS defaults and stow configs

DOTFILES_DIR="${HOME}/.dotfiles"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

# Build ZIP URL directly from STRAP_GITHUB_USER
REPO_ZIP_URL="https://github.com/${STRAP_GITHUB_USER}/dotfiles/archive/refs/heads/main.zip"

# Ensure target directory does not exist before making any changes
if [[ -e "${DOTFILES_DIR}" ]]; then
  echo "ERROR: ${DOTFILES_DIR} already exists. Move or remove it before running setup." >&2
  exit 1
fi

echo "Downloading dotfiles zip to temporary directory..."
curl -fsSL "${REPO_ZIP_URL}" -o "${TMP_DIR}/repo.zip"

echo "Extracting..."
unzip -q -o "${TMP_DIR}/repo.zip" -d "${TMP_DIR}"
# Determine top-level directory inside the zip
TOP_DIR=$(unzip -Z -1 "${TMP_DIR}/repo.zip" | head -1 | cut -f1 -d'/')
if [[ -z "${TOP_DIR}" || ! -d "${TMP_DIR}/${TOP_DIR}" ]]; then
  echo "ERROR: Could not determine extracted directory from zip." >&2
  exit 1
fi

mkdir -p "${DOTFILES_DIR}"
echo "Syncing to ${DOTFILES_DIR}..."
rsync -a --delete "${TMP_DIR}/${TOP_DIR}/" "${DOTFILES_DIR}/"

# Ensure core scripts are executable if present
[[ -f "${DOTFILES_DIR}/strap.sh" ]] && chmod +x "${DOTFILES_DIR}/strap.sh"
[[ -f "${DOTFILES_DIR}/.macos" ]] && chmod +x "${DOTFILES_DIR}/.macos"
[[ -f "${DOTFILES_DIR}/scripts/strap-after-setup.sh" ]] && chmod +x "${DOTFILES_DIR}/scripts/strap-after-setup.sh"

echo "Preparing Strap environment variables..."

# Optionally load repo-provided env overrides (after syncing to ~/.dotfiles)
if [[ -f "${DOTFILES_DIR}/.strap.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${DOTFILES_DIR}/.strap.env"
  set +a
fi

export STRAP_DOTFILES="${DOTFILES_DIR}"
export STRAP_GIT_NAME STRAP_GIT_EMAIL STRAP_GITHUB_USER STRAP_GITHUB_TOKEN

echo "Running Strap from ${DOTFILES_DIR}/strap.sh ..."

if [[ ! -x "${DOTFILES_DIR}/strap.sh" ]]; then
  echo "ERROR: ${DOTFILES_DIR}/strap.sh not found or not executable." >&2
  exit 1
fi

# Run Strap (it may ask for sudo and handle Homebrew setup)
bash "${DOTFILES_DIR}/strap.sh"

echo "All done."
