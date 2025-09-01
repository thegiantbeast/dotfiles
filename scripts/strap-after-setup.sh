#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="${HOME}/.dotfiles"

echo "--> Applying macOS defaults via ${DOTFILES_DIR}/.macos (if present)"
if [[ -x "${DOTFILES_DIR}/.macos" ]]; then
  bash "${DOTFILES_DIR}/.macos"
else
  echo "--> .macos not found or not executable; skipping."
fi

echo "--> Stowing dotfiles from ${DOTFILES_DIR} into ${HOME}"
cd "${DOTFILES_DIR}"
stow .
