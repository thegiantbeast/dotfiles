# === Editor ===
export EDITOR=vi

# === PATH: user installs (rex, uv tools) ===
export PATH="$HOME/.local/bin:$PATH"

# === Terraform ===
# One shared provider cache; per-project .terraform dirs hard-link into it.
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
[ -d "$TF_PLUGIN_CACHE_DIR" ] || mkdir -p "$TF_PLUGIN_CACHE_DIR"

# === gcloud shim (re-login on session expiry); real SDK is the apt one ===
export GCLOUD_SHIM_REAL="${GCLOUD_SHIM_REAL:-/usr/bin/gcloud}"
PATH="$HOME/.dotfiles/scripts/gcloud-shim:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$HOME/.dotfiles/scripts/gcloud-shim" | paste -sd: -)"; export PATH

# === SSH agent ===
# Prefer a forwarded agent (YubiKey card keys) when present; otherwise the
# persistent user agent, which holds the AI-agent key.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
case "$SSH_AUTH_SOCK" in
  /tmp/ssh-*/agent.*) ;;  # forwarded agent (YubiKey) — keep it
  *) export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent" ;;  # local agent with the AI-agent key
esac
if [ -S "$SSH_AUTH_SOCK" ] && ! ssh-add -l >/dev/null 2>&1; then
  ssh-add "$HOME/.ssh/id_ed25519_ai_agent" >/dev/null 2>&1 || :
fi

# Make non-interactive bash subshells (e.g. `bash -c '...'` from agents)
# load ~/.bashrc so they inherit PATH/env.
export BASH_ENV="$HOME/.bashrc"

# === Mistral API key — ccr ONLY ===
# The key file (~/.config/mistral/api-key, 600, never committed) is loaded
# per-invocation by this wrapper, never exported globally: a global
# MISTRAL_API_KEY silently overrides Vibe's subscription key from the OS
# keyring and switches Vibe to metered La Plateforme API billing.
ccr() {
  if [ -f "$HOME/.config/mistral/api-key" ] && [ -s "$HOME/.config/mistral/api-key" ]; then
    MISTRAL_API_KEY="$(tr -d '\r\n' < "$HOME/.config/mistral/api-key")" command ccr "$@"
  else
    echo "ccr: no Mistral key at ~/.config/mistral/api-key (see ~/.config/mistral/README.txt)" >&2
    return 1
  fi
}

# Local homelab route (no API key needed): ccr root config has a "homelab"
# provider -> http://10.10.10.11:8080 (VM 111 llama-router). claude 2.1.289
# needs the modelOverrides mapping in ~/.claude/settings.json to accept the
# "homelab,<model>" id. See homelab repo tools/devbox/README.md.
ccr-local() {
  command ccr code --model homelab,gemma-4-12B-it-QAT-Q4_0 "$@"
}

# Stop here for non-interactive shells — everything below is for humans.
[[ -o interactive ]] || return 0

. "$HOME/.local/bin/env" 2>/dev/null || :
