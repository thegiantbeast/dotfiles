function codex --description "Run Codex CLI sandboxed via nono"
    set -l nono_args --profile codex --trust-override --allow-cwd -s
    set -l git_common (git rev-parse --git-common-dir 2>/dev/null)
    if test -n "$git_common" -a "$git_common" != .git
        set nono_args $nono_args --allow (realpath $git_common)
    end
    nono run $nono_args -- codex $argv
end
