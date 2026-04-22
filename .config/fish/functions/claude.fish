function claude --description "Run Claude Code sandboxed via nono"
    set -l nono_args --profile claude --trust-override --allow-cwd -s
    set -l git_common (git rev-parse --git-common-dir 2>/dev/null)
    if test -n "$git_common" -a "$git_common" != .git
        set nono_args $nono_args --allow (realpath $git_common)
    end
    SHELL=/opt/homebrew/bin/bash nono run $nono_args -- claude $argv
end
