for file in ~/.config/fish/conf.d/**/*.fish
    source $file
end

if status is-interactive
    # Commands to run in interactive sessions can go here
end

set -gx EDITOR vi


# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init2.fish 2>/dev/null || :

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.fish.inc' ]; . '/opt/homebrew/share/google-cloud-sdk/path.fish.inc'; end
