set -x HOMEBREW_BUNDLE_NO_LOCK true
eval "$(/opt/homebrew/bin/brew shellenv)"

set -U fish_user_paths /opt/homebrew/opt/grep/libexec/gnubin $fish_user_paths