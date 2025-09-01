function brewfile-diff --description 'Compare installed Homebrew items vs entries in a Brewfile'
    # Defaults: top-level only (brew leaves). Use --full/--all/-a to include deps (brew list --formula)
    set -l use_full 0
    set -l positional ()

    # Simple flag parsing (no wildcards)
    for a in $argv
        if test "$a" = "-h" -o "$a" = "--help"
            echo "Usage: brewfile-diff [--full|--all|-a] [Brewfile]"
            echo "  Default: compare top-level formulae only (brew leaves)"
            echo "  --full / --all / -a: include all installed formulae (incl. deps)"
            echo "  Brewfile defaults to ~/.dotfiles/Brewfile"
            return 0
        else if test "$a" = "--full" -o "$a" = "--all" -o "$a" = "-a"
            set use_full 1
        else
            set positional $positional $a
        end
    end

    if not type -q brew
        echo "Error: Homebrew (brew) not found in PATH." >&2
        return 1
    end

    # Pick Brewfile path (last positional) or default
    set -l BF ~/.dotfiles/Brewfile
    if test (count $positional) -ge 1
        set BF $positional[-1]
    end

    # Expand leading ~
    if string match -rq '^~' -- "$BF"
        set BF (string replace -r '^~' "$HOME" -- "$BF")
    end

    if not test -f "$BF"
        echo "Error: Brewfile not found: $BF" >&2
        return 1
    end

    # ----- helpers (local; cleaned up at end) -----
    function __bfd_brews; awk -F'"' '/^[[:space:]]*brew[[:space:]]/ {print $2}' "$argv[1]"; end
    function __bfd_casks; awk -F'"' '/^[[:space:]]*cask[[:space:]]/ {print $2}' "$argv[1]"; end
    function __bfd_taps;  awk -F'"' '/^[[:space:]]*tap[[:space:]]/  {print $2}' "$argv[1]"; end
    function __bfd_mas;   awk -F'id: *' '/^[[:space:]]*mas[[:space:]]/ {gsub(/[,"]/, "", $2); print $2}' "$argv[1]" | awk '{print $1}'; end

    echo "Brewfile: $BF"
    echo

    # ========= Formulae =========
    echo "== Formulae installed but NOT in Brewfile =="
    set -l diff (comm -23 \
        (begin; if test $use_full -eq 1; brew list --formula; else; brew leaves; end; end | sort -u | psub) \
        (__bfd_brews "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    echo "== Formulae IN Brewfile but NOT installed =="
    set diff (comm -13 \
        (begin; if test $use_full -eq 1; brew list --formula; else; brew leaves; end; end | sort -u | psub) \
        (__bfd_brews "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    # ========= Casks =========
    echo "== Casks installed but NOT in Brewfile =="
    set diff (comm -23 \
        (brew list --cask | sort -u | psub) \
        (__bfd_casks "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    echo "== Casks IN Brewfile but NOT installed =="
    set diff (comm -13 \
        (brew list --cask | sort -u | psub) \
        (__bfd_casks "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    # ========= Taps =========
    echo "== Taps present but NOT in Brewfile =="
    set diff (comm -23 \
        (brew tap | sort -u | psub) \
        (__bfd_taps "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    echo "== Taps IN Brewfile but NOT tapped =="
    set diff (comm -13 \
        (brew tap | sort -u | psub) \
        (__bfd_taps "$BF" | sort -u | psub))
    test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
    echo

    # ========= MAS apps (optional) =========
    if type -q mas
        echo "== MAS apps installed (by ID) but NOT in Brewfile =="
        set diff (comm -23 \
            (mas list | awk '{print $1}' | sort -u | psub) \
            (__bfd_mas "$BF" | sort -u | psub))
        test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
        echo

        echo "== MAS apps IN Brewfile but NOT installed (by ID) =="
        set diff (comm -13 \
            (mas list | awk '{print $1}' | sort -u | psub) \
            (__bfd_mas "$BF" | sort -u | psub))
        test (count $diff) -gt 0; and printf '%s\n' $diff; or echo "(none)"
        echo
    else
        echo "== MAS apps =="
        echo "(mas not installed; skipping MAS comparison)"
        echo
    end

    # Clean helpers
    functions -e __bfd_brews __bfd_casks __bfd_taps __bfd_mas
end
