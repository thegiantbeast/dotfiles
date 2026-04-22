function k9s --wraps k9s --description 'Pin k9s to tequity-test by default; skip injection for subcommands (info/help/version/…)'
    # If the first arg is a subcommand (bare word, not a flag), pass through unchanged.
    if set -q argv[1]; and not string match -q -- '-*' $argv[1]
        command k9s $argv
        return
    end
    command k9s --context gke_tequity-test-390410_europe-west4-a_cluster $argv
end
