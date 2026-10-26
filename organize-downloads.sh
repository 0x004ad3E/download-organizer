#!/usr/bin/env bash
set -Eeuo pipefail

QUEUE="/config/download-queue.json"
LOCK="${QUEUE}.lock"

# -------------------------------------------------------------------
# Timing helpers.
# -------------------------------------------------------------------

start_timer() {
    TIMER_START="$(date +%s%N)"
}

print_elapsed() {
    local label="$1"
    local end_time elapsed_ms seconds milliseconds

    end_time="$(date +%s%N)"
    elapsed_ms=$(( (end_time - TIMER_START) / 1000000 ))

    seconds=$((elapsed_ms / 1000))
    milliseconds=$((elapsed_ms % 1000))

    echo "${label}: ${seconds}.$(printf '%03d' "$milliseconds")s"
}


# -------------------------------------------------------------------
# Check required commands.
# -------------------------------------------------------------------

for cmd in jq flock curl mktemp mv find realpath chmod; do
    command -v "$cmd" >/dev/null || {
        echo "Error: required command not found: $cmd" >&2
        exit 1
    }
done

# -------------------------------------------------------------------
# Validate queue and environment.
# -------------------------------------------------------------------

if [[ ! -f "$QUEUE" ]]; then
    echo "Error: queue does not exist: $QUEUE" >&2
    exit 1
fi

: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL environment variable}"
: "${QBITTORRENT_API_KEY:?Missing QBITTORRENT_API_KEY environment variable}"

QBITTORRENT_URL="${QBITTORRENT_URL%/}"

for DEST in /usb-drive-tsba/toor/movies /usb-drive-tsba/toor/series; do
    if [[ ! -d "$DEST" ]]; then
        echo "Error: destination directory does not exist: $DEST" >&2
        exit 1
    fi
done

for SRC in /usb-drive-tsba/pi-app-data/qbit-data/downloads/movies /usb-drive-tsba/pi-app-data/qbit-data/downloads/series; do
    if [[ ! -d "$SRC" ]]; then
        echo "Error: source directory does not exist: $SRC" >&2
        exit 1
    fi
done

# -------------------------------------------------------------------
# Lock the queue to prevent concurrent processing or updates.
# -------------------------------------------------------------------

exec 9>"$LOCK"
flock -x 9

jq -e 'type == "array"' "$QUEUE" >/dev/null || {
    echo "Error: invalid JSON queue: $QUEUE" >&2
    exit 1
}

# -------------------------------------------------------------------
# Remove the torrent task, preserving downloaded files.
# -------------------------------------------------------------------

delete_torrent() {
    local hash="$1"

    curl --silent --show-error --fail \
        --connect-timeout 10 \
        --max-time 60 \
        --header "Authorization: Bearer $QBITTORRENT_API_KEY" \
        --referer "$QBITTORRENT_URL" \
        --request POST \
        --data-urlencode "hashes=$hash" \
        --data-urlencode "deleteFiles=false" \
        "$QBITTORRENT_URL/api/v2/torrents/delete" >/dev/null
}

# -------------------------------------------------------------------
# Queue management.
# -------------------------------------------------------------------

update_entry() {
    local hash="$1"
    local status="$2"
    local destination="$3"
    local error="$4"
    local tmp

    tmp="$(mktemp "${QUEUE}.XXXXXX")" || return 1

    if ! jq \
        --arg hash "$hash" \
        --arg status "$status" \
        --arg destination "$destination" \
        --arg error "$error" '
        map(
            if .hash == $hash then
                .status = $status
                | .destination = (
                    if $destination == "" then .destination
                    else $destination end
                )
                | .error = (
                    if $error == "" then null
                    else $error end
                )
            else . end
        )' "$QUEUE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi

    chmod --reference="$QUEUE" "$tmp" 2>/dev/null || true

    if ! mv -f -- "$tmp" "$QUEUE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

remove_entry() {
    local hash="$1"
    local tmp

    tmp="$(mktemp "${QUEUE}.XXXXXX")" || return 1

    if ! jq --arg hash "$hash" \
        'map(select(.hash != $hash))' "$QUEUE" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi

    chmod --reference="$QUEUE" "$tmp" 2>/dev/null || true

    if ! mv -f -- "$tmp" "$QUEUE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# -------------------------------------------------------------------
# Filename cleaning.
#
# "Some Movie - 1080p.mkv"       -> "1080p.mkv"
# "Some Movie - Extras"          -> "Extras"
# "Part A - Part B - file.mkv"   -> "Part B - file.mkv"
# "Movie.mkv"                    -> "Movie.mkv"
# -------------------------------------------------------------------

clean_name() {
    local name="$1"
    printf '%s' "${name#* - }"
}

# -------------------------------------------------------------------
# Rename all nested files and directories, deepest first.
# Never overwrite an existing file, directory, or symlink.
# -------------------------------------------------------------------

bash
# Rename all nested files and directories, deepest first.
# Never overwrite an existing file, directory, or symlink.
# Log elapsed time and item counts.

clean_tree() {
    local root="$1"
    local path name new_name parent
    local scanned=0
    local renamed=0
    local start_time end_time elapsed

    start_time=$SECONDS

    echo "Starting cleanup: $root"

    while IFS= read -r -d '' path; do
        ((scanned += 1))

        name="${path##*/}"
        new_name="$(clean_name "$name")"

        [[ "$name" == "$new_name" ]] && continue

        if [[ -z "$new_name" ||
              "$new_name" == "." ||
              "$new_name" == ".." ]]; then
            echo "Error: unsafe resulting name: $path" >&2
            return 1
        fi

        parent="${path%/*}"

        if [[ -e "$parent/$new_name" || -L "$parent/$new_name" ]]; then
            echo "Error: rename conflict: $parent/$new_name" >&2
            return 1
        fi

        if ! mv -- "$path" "$parent/$new_name"; then
            echo "Error: failed to rename: $path" >&2
            return 1
        fi

        ((renamed += 1))

    done < <(find "$root" -depth -mindepth 1 -print0)

    end_time=$SECONDS
    elapsed=$((end_time - start_time))

    echo "Cleanup finished: $root"
    echo "Items scanned: $scanned"
    echo "Items renamed: $renamed"
    echo "Cleanup time: ${elapsed}s"
}

# -------------------------------------------------------------------
# Process pending queue entries.
# Use while/read instead of mapfile for shell compatibility.
# -------------------------------------------------------------------

while IFS= read -r HASH; do
    [[ -z "$HASH" ]] && continue

    ENTRY="$(jq -c --arg hash "$HASH" \
        '.[] | select(.hash == $hash)' "$QUEUE")"

    CATEGORY="$(jq -r '.category // ""' <<<"$ENTRY")"
    SOURCE="$(jq -r '.source // ""' <<<"$ENTRY")"

    # Wait until the torrent has been in the queue for at least 6 hours.
    ADDED_AT="$(jq -r '.added_at // ""' <<<"$ENTRY")"

    if [[ -z "$ADDED_AT" ]]; then
        update_entry "$HASH" error "" \
            "Missing added_at timestamp" || true
        echo "Error: missing added_at for torrent: $HASH" >&2
        continue
    fi

    ADDED_EPOCH="$(date -u -d "$ADDED_AT" +%s 2>/dev/null)" || {
        update_entry "$HASH" error "" \
            "Invalid added_at timestamp: $ADDED_AT" || true
        echo "Error: invalid added_at timestamp: $ADDED_AT" >&2
        continue
    }

    CURRENT_EPOCH="$(date -u +%s)"
    AGE_SECONDS=$((CURRENT_EPOCH - ADDED_EPOCH))
    MINIMUM_AGE_SECONDS=$((6 * 60 * 60))

    if (( AGE_SECONDS < MINIMUM_AGE_SECONDS )); then
        REMAINING_SECONDS=$((MINIMUM_AGE_SECONDS - AGE_SECONDS))
        REMAINING_HOURS=$((REMAINING_SECONDS / 3600))
        REMAINING_MINUTES=$(((REMAINING_SECONDS % 3600) / 60))

        echo "Skipping torrent: less than 6 hours since added_at."
        echo "Added at: $ADDED_AT"
        echo "Time remaining: ${REMAINING_HOURS}h ${REMAINING_MINUTES}m"
        continue
    fi

    echo "Age requirement satisfied: at least 6 hours since added_at."

    echo
    echo "Processing torrent: $HASH"
    echo "Source: $SOURCE"

    # Select the allowed source and destination roots.
    case "$CATEGORY" in
        movies)
            DEST_ROOT="/usb-drive-tsba/toor/movies"
            SOURCE_ROOT="/usb-drive-tsba/pi-app-data/qbit-data"
            ;;
        series)
            DEST_ROOT="/usb-drive-tsba/toor/series"
            SOURCE_ROOT="/usb-drive-tsba/pi-app-data/qbit-data"
            ;;
        *)
            update_entry "$HASH" error "" \
                "Invalid category: $CATEGORY" || true
            echo "Error: invalid category: $CATEGORY" >&2
            continue
            ;;
    esac

    SOURCE="${SOURCE_ROOT}/${SOURCE}"
    echo "Source: $SOURCE"
    # Validate source path before removing the torrent task.
    # Accept regular files and directories.
    start_timer
    if [[ -z "$SOURCE" ||
          "$SOURCE" != "$SOURCE_ROOT/"* ||
          ( ! -f "$SOURCE" && ! -d "$SOURCE" ) ]]; then
        update_entry "$HASH" error "" \
            "Invalid or missing source file/directory: $SOURCE" || true
        echo "Error: invalid or missing source file/directory: $SOURCE" >&2
        continue
    fi
    print_elapsed "Validate source path before removing the torrent task."

    start_timer
    SOURCE_REAL="$(realpath "$SOURCE")" || {
        update_entry "$HASH" error "" \
            "Cannot resolve source path" || true
        continue
    }
    print_elapsed "Source path resolved"

    start_timer
    ROOT_REAL="$(realpath "$SOURCE_ROOT")" || {
        update_entry "$HASH" error "" \
            "Cannot resolve source root" || true
        continue
    }
    print_elapsed "Source root resolved"

    start_timer
    if [[ "$SOURCE_REAL" != "$ROOT_REAL/"* ]]; then
        update_entry "$HASH" error "" \
            "Source resolves outside permitted directory" || true
        echo "Error: source path is outside permitted directory" >&2
        continue
    fi
    print_elapsed "Source path is located inside permitted directory"

    start_timer
    # Calculate cleaned destination name for either a file or directory.
    SOURCE_NAME="${SOURCE##*/}"
    CLEANED_NAME="$(clean_name "$SOURCE_NAME")"

    if [[ -z "$CLEANED_NAME" ||
          "$CLEANED_NAME" == "." ||
          "$CLEANED_NAME" == ".." ]]; then
        update_entry "$HASH" error "" \
            "Unsafe destination name" || true
        echo "Error: unsafe destination name: $SOURCE_NAME" >&2
        continue
    fi
    print_elapsed "Calculate cleaned destination name for either a file or directory."

    DESTINATION="$DEST_ROOT/$CLEANED_NAME"

    start_timer
    # Do not delete the torrent if the destination already exists.
    if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
        update_entry "$HASH" error "$DESTINATION" \
            "Destination already exists" || true
        echo "Error: destination already exists: $DESTINATION" >&2
        continue
    fi
    print_elapsed "Do not delete the torrent if the destination already exists."

    start_timer
    # 1. Delete torrent task first, preserving the files.
    if ! delete_torrent "$HASH"; then
        update_entry "$HASH" error "" \
            "Failed to delete torrent task; files were not moved" || true
        echo "Error: failed to delete torrent task: $HASH" >&2
        continue
    fi
    print_elapsed "Delete torrent task first, preserving the files."

    start_timer
    # Record that qBittorrent no longer manages this torrent.
    if ! update_entry "$HASH" torrent_removed "$DESTINATION" ""; then
        echo "Error: torrent removed but queue update failed: $HASH" >&2
        exit 1
    fi
    print_elapsed "Record that qBittorrent no longer manages this torrent."

    start_timer
    # 2. Clean nested names only when the source is a directory.
    if [[ -d "$SOURCE" ]]; then
        if ! clean_tree "$SOURCE"; then
            update_entry "$HASH" error "$DESTINATION" \
                "Torrent removed; nested renaming failed. Inspect source directory." || true
            echo "Error: nested renaming failed; inspect $SOURCE" >&2
            continue
        fi
    fi
    print_elapsed "Clean nested names only when the source is a directory."

    start_timer
    # 3. Move the cleaned source file or directory.
    if ! mv -- "$SOURCE" "$DESTINATION"; then
        update_entry "$HASH" error "$DESTINATION" \
            "Torrent removed and names cleaned, but move failed" || true
        echo "Error: failed to move source to $DESTINATION" >&2
        continue
    fi
    print_elapsed "Move the cleaned source file or directory."

    start_timer
    # 4. Remove queue entry only after successful move.
    if remove_entry "$HASH"; then
        echo "Completed and removed from queue: $DESTINATION"
    else
        echo "Warning: files moved but queue entry removal failed: $HASH" >&2

        update_entry "$HASH" completed "$DESTINATION" \
            "Files moved successfully, but queue entry removal failed" || true
    fi
    print_elapsed "Remove queue entry only after successful move."

done < <(
    jq -r '.[] | select(.status == "pending") | .hash' "$QUEUE"
)

echo
echo "Download queue processing finished."
