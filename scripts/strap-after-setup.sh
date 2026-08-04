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

  echo "--> Setting GPG key trust to ultimate (required for git-crypt)"
  for key in "${yubikey_pubkeys[@]}"; do
    gpg --batch --no-tty --command-fd 0 --expert --edit-key "${key}" <<'TRUST'
trust
5
y
quit
TRUST
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

echo "--> Decrypting git-crypt files in dotfiles"
cd "${DOTFILES_DIR}"
if command -v git-crypt &>/dev/null; then
  git-crypt unlock
  echo "--> Re-stowing dotfiles after git-crypt unlock"
  stow .
else
  echo "    ! git-crypt not found; encrypted files will remain locked."
fi

echo "--> Initializing RTK (token-saving CLI proxy for AI coding agents)"
if command -v rtk &>/dev/null; then
  # RTK on macOS reads from ~/Library/Application Support/rtk/ — symlink to ~/.config/rtk/
  mkdir -p "${HOME}/Library/Application Support/rtk"
  ln -sf "${HOME}/.config/rtk/config.toml" "${HOME}/Library/Application Support/rtk/config.toml"
  rtk init --global --auto-patch
  rtk init --global --codex
else
  echo "    ! rtk not found; skipping RTK init."
fi

echo "--> Restoring ICM memory database from the icm-backup branch"
# Runs before `icm init` so the restore lands on an absent target rather than
# an empty database that icm would have just created.
if ! bash "${DOTFILES_DIR}/scripts/icm-db-restore.sh"; then
  echo "    ! Restore skipped; no backup on origin yet, or the YubiKey is absent."
fi

echo "--> Initializing ICM (persistent memory for AI coding agents)"
if command -v icm &>/dev/null; then
  # ICM on macOS reads from ~/Library/Application Support/dev.icm.icm/ — symlink entire dir to ~/.config/icm/
  ln -sfn "${HOME}/.config/icm" "${HOME}/Library/Application Support/dev.icm.icm"
  icm init --mode hook
else
  echo "    ! icm not found; skipping ICM init."
fi

echo "--> Installing the ICM backup launch agent (daily, catches up after sleep)"
ICM_AGENT="eu.ricardoferreira.icm-db-backup"
mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
sed "s|__HOME__|${HOME}|g" \
  "${DOTFILES_DIR}/scripts/${ICM_AGENT}.plist.template" \
  >"${HOME}/Library/LaunchAgents/${ICM_AGENT}.plist"
launchctl bootout "gui/$(id -u)/${ICM_AGENT}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${HOME}/Library/LaunchAgents/${ICM_AGENT}.plist"
launchctl enable "gui/$(id -u)/${ICM_AGENT}"

echo "--> Installing Glance (Quick Look extension)"
GLANCE_DMG_URL=$(curl -sL https://api.github.com/repos/chamburr/glance/releases/latest | jq -r '.assets[] | select(.name | endswith(".dmg")) | .browser_download_url')
if [[ -n "${GLANCE_DMG_URL}" ]]; then
  curl -fsSL "${GLANCE_DMG_URL}" -o /tmp/Glance.dmg
  hdiutil attach /tmp/Glance.dmg -nobrowse -quiet
  GLANCE_VOL=$(find /Volumes -maxdepth 1 -name "Glance*" -print -quit)
  cp -R "${GLANCE_VOL}/Glance.app" /Applications/
  hdiutil detach "${GLANCE_VOL}" -quiet
  xattr -rd com.apple.quarantine /Applications/Glance.app
  rm -f /tmp/Glance.dmg
else
  echo "    ! Could not fetch Glance release URL; install manually from https://github.com/chamburr/glance/releases"
fi

# Enable USB LAN adapter drivers
sudo kextload -b com.apple.driver.usb.realtek8153patcher
