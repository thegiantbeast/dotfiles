Dotfiles
========

Bootstrap a macOS machine with Strap, apply a minimal set of up‑to‑date macOS defaults, and restore configs using GNU Stow. Configs live at the repo root; `.stow-local-ignore` prevents non-config files from being symlinked. `.stowrc` configures Stow behavior.

Quick Start
-----------

- One‑liner (recommended):
  - `STRAP_GIT_NAME="Your Name" STRAP_GIT_EMAIL="you@example.com" STRAP_GITHUB_USER="your-github" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/your-github/dotfiles/HEAD/setup.sh)"`

- Local run (after cloning):
  - `export STRAP_GIT_NAME="Your Name"`
  - `export STRAP_GIT_EMAIL="you@example.com"`
  - `export STRAP_GITHUB_USER="your-github"`
  - `./setup.sh`

What Happens
------------

- Download ZIP: Builds `https://github.com/${STRAP_GITHUB_USER}/dotfiles/archive/refs/heads/main.zip` and syncs into `~/.dotfiles` (aborts if it already exists).
- Run Strap: Executes local `strap.sh` with your env (`STRAP_GIT_NAME`, `STRAP_GIT_EMAIL`, `STRAP_GITHUB_USER`, optional `STRAP_GITHUB_TOKEN`).
- Post‑strap: Runs `scripts/strap-after-setup.sh` which:
  - Executes `~/.dotfiles/.macos` (modern minimal defaults for Sonoma/Sequoia).
  - Runs `stow .` (uses `.stowrc` and `.stow-local-ignore`).
  - Prompts to insert a YubiKey, fixes perms on `~/.gnupg`/`~/.ssh`, exports agent ECDSA/RSA public keys.
  - Ensures `~/.dotfiles` is a git repo.

Environment
-----------

- Required: `STRAP_GIT_NAME`, `STRAP_GIT_EMAIL`, `STRAP_GITHUB_USER`.
- Optional: `STRAP_GITHUB_TOKEN` (for private taps/repos during Homebrew operations).
- Overrides: create `~/.dotfiles/.strap.env` to override/env‑inject before running Strap.

Scripts
-------

- `.macos`: Minimal, safe defaults (Finder, Dock, keyboard, trackpad, screenshots, no deprecated keys).
- `scripts/strap-after-setup.sh`: Runs `.macos`, stows configs, git ssh keys setup.

Structure
---------

- `setup.sh`: Orchestrates download → Strap → post‑strap.
- `strap.sh`: Vendored Strap script to configure macOS, install Homebrew, apply updates, install from `Brewfile`, and run post‑install hooks.
- `.macos`: Modern minimal defaults (Sonoma/Sequoia).
- `scripts/`: Post‑strap hook and tools (`strap-after-setup.sh`).
- `.stow-local-ignore`: Excludes non-configs (scripts, reports, setup, strap, README, etc.).
- `.stowrc`: Stow configuration.

Notes
-----

- `~/.dotfiles` must not exist; `setup.sh` exits early if it does.
- GNU Stow is included in the `Brewfile` and will be installed by Strap.
- Place your actual dotfiles/dirs at the repo root. Stow will symlink them into `$HOME`.
