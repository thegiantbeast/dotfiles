alias fish-reload="source ~/.config/fish/config.fish"

alias fish-config="code ~/.config/fish"
alias git-config="code ~/.config/git"
alias zellij-config="code ~/.config/zellij"
alias dotfiles="code ~/.dotfiles"

# AI agents — sandboxed via nono by default
alias claude="SHELL=/opt/homebrew/bin/bash nono run --profile ai --trust-override --allow-cwd -- claude"
alias codex="nono run --profile ai --trust-override --allow-cwd -- codex"

# Raw (unsandboxed) access when needed
alias claude-raw="SHELL=/opt/homebrew/bin/bash command claude"
alias codex-raw="command codex"

alias tequity="zellij --layout tequity"
alias momentus="zellij --layout momentus"
