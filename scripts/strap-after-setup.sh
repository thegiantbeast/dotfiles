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

echo "--> Insert your YubiKey now, then press ENTER to continue..."
read -r _

echo "--> Adjusting permissions for ~/.gnupg and ~/.ssh"
chmod 700 "${HOME}/.gnupg"
find "${HOME}/.gnupg" -type d -exec chmod 700 {} +
find "${HOME}/.gnupg" -type f -exec chmod 600 {} +
chmod 700 "${HOME}/.ssh"

GPG_TTY=$(tty)
SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent

echo "--> Syncing GPG public keys from YubiKey"
if gpg --quiet --card-status >/dev/null 2>&1; then
  printf 'fetch\nquit\n' | gpg --quiet --batch --yes --command-fd 0 --status-fd 1 --edit-card >/dev/null 2>&1

  mapfile -t yubikey_pubkeys < <(gpg --list-keys --with-colons | awk -F: '$1 == "pub" { print $5 }' | sort -u)
  for key in "${yubikey_pubkeys[@]}"; do
    echo "    -> Downloading ${key} from keys.openpgp.org"
    gpg --quiet --keyserver hkps://keys.openpgp.org --recv-keys "${key}" >/dev/null 2>&1 || {
      echo "       ! Failed to download ${key}; please import manually."
    }
  done
else
  echo "--> No YubiKey detected; skipping GPG key fetch."
fi

echo "--> Exporting SSH public keys from agent"
ssh-add -L | awk '/^ecdsa-sha2-/{print}' > "${HOME}/.ssh/id_ecdsa.pub"
chmod 644 "${HOME}/.ssh/id_ecdsa.pub"
ssh-add -L | awk '/^ssh-rsa /{print}' > "${HOME}/.ssh/id_rsa.pub"
chmod 644 "${HOME}/.ssh/id_rsa.pub"

echo "--> Setting up ~/.dotfiles Git repository (SSH)"
if [[ -n "${STRAP_GITHUB_USER:-}" ]]; then
  git init
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "git@github.com:${STRAP_GITHUB_USER}/dotfiles.git"
  fi
  git fetch origin main
  git checkout -B main
  git reset --mixed origin/main
  git branch --set-upstream-to=origin/main main
fi
