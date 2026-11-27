# Sourced by scripts/build-app.sh. The files VibeSwitcher itself installs into a folder the config seal watches
# (today the hooks' binary, which the app copies byte for byte into ~/.vibeswitcher/bin: `HookBinary.sync`) must stay
# within the seal's per-file read limit (`ConfigSeal.readLimit`). Past it the seal tells the file by its metadata and
# holds it for your Accept the first time, so every user would get a held card for VibeSwitcher's own binary after
# the update that grew it. The build fails first, already at WATCHED_SIZE_WARN_PERCENT of the limit.

WATCHED_SIZE_WARN_PERCENT=80

# seal_read_limit [CONFIGSEAL_SWIFT]: ConfigSeal.readLimit in bytes, read from its declaration in the source (default
# Sources/VibeCore/ConfigSeal.swift), never a copied number. Fails, saying so, when the declaration isn't found or isn't
# plain integer arithmetic (`32 << 20`). WatchedSizesTests checks it equals the compiled constant.
seal_read_limit() {
    local source="${1:-Sources/VibeCore/ConfigSeal.swift}" line expression
    line="$(grep -E '^[[:space:]]*(public |internal )?static let readLimit = ' "$source" | head -n 1)" || true
    expression="${line#*readLimit = }"
    expression="${expression%%//*}"
    if [[ -z "$line" || ! "$expression" =~ ^[0-9\ \<\*\+]+$ ]]; then
        echo "Couldn't read ConfigSeal.readLimit from $source (found: ${line:-nothing})." >&2
        return 1
    fi
    echo $(( expression ))
}

# check_watched_sizes LIMIT FILE...: fails, naming the file, its size and the limit, when a FILE is over LIMIT bytes
# (the seal reads a file of exactly LIMIT bytes) or at WATCHED_SIZE_WARN_PERCENT of it or more (raise the limit or
# shrink the binary before a release). A FILE that's missing fails too: nothing measured is nothing checked.
check_watched_sizes() {
    local limit="$1" file size threshold failed=0
    shift
    if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        echo "Watched-folder size check: the limit isn't a number of bytes (${limit:-empty})." >&2
        return 1
    fi
    threshold=$(( limit * WATCHED_SIZE_WARN_PERCENT / 100 ))
    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            echo "Watched-folder size check: $file is missing, so its size against the config seal's limit is unknown." >&2
            failed=1
            continue
        fi
        size="$(stat -f %z "$file")"
        if (( size > limit )); then
            echo "Watched-folder size check: $file is $size bytes, over the config seal's per-file limit" \
                "(ConfigSeal.readLimit, $limit bytes): installed into a watched folder, it would be held for every" \
                "user's Accept after the update. Shrink the binary, or raise ConfigSeal.readLimit, before a release." >&2
            failed=1
        elif (( size >= threshold )); then
            echo "Watched-folder size check: $file is $size bytes, at or past $WATCHED_SIZE_WARN_PERCENT% ($threshold" \
                "bytes) of the config seal's per-file limit (ConfigSeal.readLimit, $limit bytes). Raise the limit or" \
                "shrink the binary before a release: past the limit it would be held for every user's Accept after" \
                "the update." >&2
            failed=1
        else
            echo "Watched-folder size check: $file is $size bytes, under $WATCHED_SIZE_WARN_PERCENT% ($threshold" \
                "bytes) of the config seal's per-file limit ($limit bytes)."
        fi
    done
    return "$failed"
}
