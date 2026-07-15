function ccfind --description 'Resume-picker for Claude Code sessions across all projects, styled like claude --resume'
    argparse l/list h/help -- $argv
    or return 1
    if set -q _flag_help
        echo "usage: ccfind [-l|--list] [<regex>] [max]"
        echo
        echo "No args: pick from ALL sessions across every project (newest first)."
        echo "With <regex>: restrict to sessions whose transcript matched it (rg, case-insensitive substring)."
        echo
        echo "  enter  resume the highlighted session      esc  cancel"
        echo "  the preview pane shows that session's opening messages"
        echo "  -l/--list  plain paged list with copy-paste resume commands"
        return 0
    end

    set -l helper (dirname (status filename))/__ccfind.py
    set -l base "$HOME/.claude/projects"
    set -l term ""
    set -l max 300
    test (count $argv) -ge 1; and set term $argv[1]
    test (count $argv) -ge 2; and set max $argv[2]

    if not isatty stdout; or set -q _flag_list
        set -l out
        if test -n "$term"
            set out (rg -l -i --no-messages -- $term $base 2>/dev/null | python3 $helper $max)
        else
            set out (python3 $helper --browse $max)
        end
        if isatty stdout
            printf '%s\n' $out | less -R
        else
            printf '%s\n' $out
        end
        return
    end

    type -q fzf; or begin
        echo "ccfind: fzf not found — use 'ccfind -l' for a plain list" >&2
        return 1
    end

    set -l line
    begin
        if test -n "$term"
            rg -l -i --no-messages -- $term $base 2>/dev/null | python3 $helper --tsv $max
        else
            python3 $helper --tsv --browse $max
        end
    end | fzf --read0 --print0 --ansi --gap=1 --highlight-line --no-sort --no-multi \
        --with-shell='/bin/sh -c' \
        --delimiter=\t --with-nth=3 --no-hscroll --ellipsis='…' \
        --layout=reverse --info=inline --pointer=' ' \
        --color='bg+:237,fg+:-1,gutter:-1,pointer:-1' \
        --prompt="resume ▸ " \
        --footer="enter resume · esc cancel" \
        --preview="python3 '$helper' --preview {4}" \
        --preview-window='right,50%,wrap,border-left,<100(down,45%,border-top)' \
        --preview-label=' opening messages ' \
        | read -lz line
    or return 0
    test -z "$line"; and return 0

    set -l parts (string split \t -- $line)
    echo "▶ resuming in $parts[2]"
    cd $parts[2]; and claude --resume $parts[1]
end
