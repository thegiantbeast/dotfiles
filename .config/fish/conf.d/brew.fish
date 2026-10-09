set -x HOMEBREW_BUNDLE_NO_LOCK true
/opt/homebrew/bin/brew shellenv fish | source

set -U fish_user_paths /opt/homebrew/opt/grep/libexec/gnubin $fish_user_paths