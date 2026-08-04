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
  - Restores the ICM memory database from the `icm-backup` branch, then installs the launch agent that keeps it backed up (see ICM Memory Backups).

Environment
-----------

- Required: `STRAP_GIT_NAME`, `STRAP_GIT_EMAIL`, `STRAP_GITHUB_USER`.
- Optional: `STRAP_GITHUB_TOKEN` (for private taps/repos during Homebrew operations).
- Overrides: create `~/.dotfiles/.strap.env` to override/env‑inject before running Strap.

Scripts
-------

- `.macos`: Minimal, safe defaults (Finder, Dock, keyboard, trackpad, screenshots, no deprecated keys).
- `scripts/strap-after-setup.sh`: Runs `.macos`, stows configs, git ssh keys setup, ICM restore and backup agent.
- `scripts/icm-db-backup.sh`: Snapshots the ICM memory database to the `icm-backup` branch. `--no-push` commits locally only.
- `scripts/icm-db-restore.sh`: Restores that snapshot. `--list` shows available ones, `--commit <sha>` picks an older one, `--force` replaces an existing database.

Structure
---------

- `setup.sh`: Orchestrates download → Strap → post‑strap.
- `strap.sh`: Vendored Strap script to configure macOS, install Homebrew, apply updates, install from `Brewfile`, and run post‑install hooks.
- `.macos`: Modern minimal defaults (Sonoma/Sequoia).
- `scripts/`: Post‑strap hook and tools (`strap-after-setup.sh`).
- `.stow-local-ignore`: Excludes non-configs (scripts, reports, setup, strap, README, etc.).
- `.stowrc`: Stow configuration.

ICM Memory Backups
------------------

The ICM memory database (`~/.config/icm/memories.db`) is deliberately **not** tracked on `main` — it is gitignored. It is snapshotted to a separate `icm-backup` branch instead, because each snapshot is encrypted and therefore never delta-compresses, so committing it to `main` would grow the repo by a full copy every time.

How a snapshot is made:

- `sqlite3 VACUUM INTO` takes a consistent copy including WAL content, without locking or mutating the live database.
- The copy must pass `PRAGMA integrity_check`, so a corrupt database is never backed up over a good snapshot.
- It is dumped to SQL, compressed with `gzip -9n` (`-n` keeps output byte-identical for identical input, so an unchanged database is detected and skipped), then encrypted with `gpg` to the YubiKey's key **before** git sees it. The blob is ciphertext independent of branch or `.gitattributes`; the script refuses to push anything that is not.
- The commit is built with plumbing against a scratch index, so the working tree, the checked-out branch and `main`'s index are never touched.
- Only the newest 20 snapshots are kept. Pruning rewrites the branch, so the push is a `--force-with-lease` — on `icm-backup` only, never `main`.

Schedule: `~/Library/LaunchAgents/eu.ricardoferreira.icm-db-backup.plist`, daily at 13:00. It uses `StartCalendarInterval` rather than `StartInterval` so a slot missed while the laptop is asleep or off fires once on wake, instead of the countdown restarting on every load and starving across reboots. Log: `~/Library/Logs/icm-db-backup.log`.

Requires the YubiKey: pushing uses an SSH key on the card, and restoring needs the encryption subkey, which is a card stub. Encrypting does not — it only needs the public key. A run without the card fails and is retried in the next slot.

Restore on a fresh machine happens automatically during post-strap. To do it by hand: `scripts/icm-db-restore.sh --list`, then `scripts/icm-db-restore.sh [--commit <sha>]`.

Notes
-----

- `~/.dotfiles` must not exist; `setup.sh` exits early if it does.
- GNU Stow is included in the `Brewfile` and will be installed by Strap.
- Place your actual dotfiles/dirs at the repo root. Stow will symlink them into `$HOME`.
