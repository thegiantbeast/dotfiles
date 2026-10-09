for file in ~/.config/fish/conf.d/**/*.fish
    source $file
end

if status is-interactive
    # Commands to run in interactive sessions can go here
end

set -gx EDITOR vi

# One shared Terraform provider cache; per-project .terraform dirs hard-link into it.
set -gx TF_PLUGIN_CACHE_DIR $HOME/.terraform.d/plugin-cache
test -d $TF_PLUGIN_CACHE_DIR; or mkdir -p $TF_PLUGIN_CACHE_DIR

# Make non-interactive bash subshells (e.g. `bash -c '...'` from agents)
# load ~/.bashrc so they inherit Homebrew/fnm/etc.
set -gx BASH_ENV $HOME/.bashrc

# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init2.fish 2>/dev/null || :

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.fish.inc' ]; . '/opt/homebrew/share/google-cloud-sdk/path.fish.inc'; end
# scripts/gcloud-shim/gcloud must shadow the SDK binary (re-login on session expiry).
fish_add_path --global --move --prepend ~/.dotfiles/scripts/gcloud-shim
# Inside the Claude Code sandbox, scripts/sandbox-shims/nc gives git's ssh the proxy credentials it lacks.
if string match -q -- '*nc -X 5 -x localhost:*' "$GIT_SSH_COMMAND"
    fish_add_path --global --move --prepend ~/.dotfiles/scripts/sandbox-shims
end
