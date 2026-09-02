#!/bin/bash
#
# Xcode build phase: upload this build's dSYMs to a running crash-server so the
# dashboard can symbolicate uploaded crash reports (matched by binary UUID).
#
# The upload runs DETACHED: Xcode only waits for processes holding the build
# log's pipes, so the build finishes immediately while the upload continues in
# the background (large apps ship dSYMs of hundreds of MB — never make the
# build wait on the network). Progress goes to a log file whose path is printed
# in the build log. Set CRASHCAM_FOREGROUND=1 to upload synchronously instead
# (CI machines may disappear right after the build).
#
# Slices already uploaded (per server, matched by UUID) are recorded in
# ~/Library/Caches/CrashCam/uploaded-dsyms and skipped, so incremental rebuilds
# upload nothing.
#
# Debug builds default to DEBUG_INFORMATION_FORMAT=dwarf (no dSYM bundle), so
# with stock settings this only ever uploads for Release builds. The gate is
# "a dSYM exists", not the configuration name.
#
# This script must never fail the build: no server running is a normal state.
# Override the target with CRASHCAM_SERVER_URL (default http://localhost:4000);
# it may hold SEVERAL space-separated URLs and each one gets every dSYM. If a
# target requires an upload token (its tokens.json has this app), export
# CRASHCAM_UPLOAD_TOKEN too; it is sent as an X-CrashCam-Token header and open
# servers simply ignore it.

set -u

SERVER_URLS="${CRASHCAM_SERVER_URL:-http://localhost:4000}"
TOKEN_HEADER=()
if [ -n "${CRASHCAM_UPLOAD_TOKEN:-}" ]; then
    TOKEN_HEADER=(-H "X-CrashCam-Token: ${CRASHCAM_UPLOAD_TOKEN}")
fi

if [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ] || [ ! -d "$DWARF_DSYM_FOLDER_PATH" ]; then
    echo "CrashCam: no dSYM folder for this build — skipping dSYM upload."
    exit 0
fi

# Xcode's user-script sandbox (ENABLE_USER_SCRIPT_SANDBOXING = YES) silently
# hides the products directory from this script and blocks curl's network
# access — the same reason Crashlytics requires that setting to be NO. Detect
# it instead of misreporting "no dSYM produced".
if ! ls "$DWARF_DSYM_FOLDER_PATH" > /dev/null 2>&1; then
    echo "warning: CrashCam cannot read $DWARF_DSYM_FOLDER_PATH — set ENABLE_USER_SCRIPT_SANDBOXING to NO for this target so the dSYM upload phase can run."
    exit 0
fi

CACHE_FILE="$HOME/Library/Caches/CrashCam/uploaded-dsyms"
mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || CACHE_FILE=""

# UUIDs of one DWARF binary in the server's normal form (lowercase, no dashes).
dwarf_uuids() {
    /usr/bin/xcrun dwarfdump --uuid "$1" 2>/dev/null \
        | /usr/bin/awk '$1 == "UUID:" {print tolower($2)}' | /usr/bin/tr -d '-'
}

already_uploaded() { # $1 = dwarf path, $2 = server url
    [ -n "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ] || return 1
    local uuids u
    uuids=$(dwarf_uuids "$1")
    [ -n "$uuids" ] || return 1
    for u in $uuids; do
        /usr/bin/grep -q "^$u $2\$" "$CACHE_FILE" 2>/dev/null || return 1
    done
    return 0
}

mark_uploaded() { # $1 = dwarf path, $2 = server url
    [ -n "$CACHE_FILE" ] || return 0
    local u
    for u in $(dwarf_uuids "$1"); do
        echo "$u $2" >> "$CACHE_FILE"
    done
}

# Snapshot a DWARF before uploading. The upload runs detached, so the next
# build (or a dsymutil still finalizing the bundle) can rewrite the file while
# curl reads it — a torn upload fails with "curl: (26) ... EOF". Wait for the
# size to hold still, then clone it (APFS copy-on-write; falls back to a real
# copy) and upload the immutable snapshot.
stable_copy() { # $1 = src, $2 = dst
    local s1 s2 tries=0
    while :; do
        s1=$(/usr/bin/stat -f %z "$1" 2>/dev/null) || return 1
        sleep 2
        s2=$(/usr/bin/stat -f %z "$1" 2>/dev/null) || return 1
        [ "$s1" = "$s2" ] && break
        tries=$((tries + 1))
        [ "$tries" -ge 150 ] && return 1   # give up after ~5 minutes
    done
    /bin/cp -c "$1" "$2" 2>/dev/null || /bin/cp "$1" "$2"
}

upload_all() {
    local found=0 dsym dwarf SERVER_URL response snap
    for dsym in "$DWARF_DSYM_FOLDER_PATH"/*.dSYM; do
        [ -d "$dsym" ] || continue
        # A dSYM bundle is a directory wrapper; the actual DWARF binaries live
        # in Contents/Resources/DWARF/. Upload those directly — the server
        # derives the UUIDs itself.
        for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
            [ -f "$dwarf" ] || continue
            found=1
            snap="${TMPDIR:-/tmp}/crashcam-snap-$$-$(basename "$dwarf")"
            if ! stable_copy "$dwarf" "$snap"; then
                echo "warning: CrashCam could not snapshot $(basename "$dwarf") (kept changing on disk?) — will retry on the next build."
                rm -f "$snap"
                continue
            fi
            for SERVER_URL in $SERVER_URLS; do
                if already_uploaded "$snap" "$SERVER_URL"; then
                    echo "CrashCam: $(basename "$dsym") ($(basename "$dwarf")) already on $SERVER_URL (UUID match) — skipping."
                    continue
                fi
                echo "CrashCam: uploading dSYM $(basename "$dsym") ($(basename "$dwarf")) → $SERVER_URL/api/dsyms"
                response=$(/usr/bin/curl --silent --show-error --max-time 600 \
                    --retry 1 --retry-all-errors \
                    ${TOKEN_HEADER[@]+"${TOKEN_HEADER[@]}"} \
                    -F "dsym=@${snap}" \
                    -F "binaryName=$(basename "$dwarf")" \
                    -F "appName=${PRODUCT_NAME:-}" \
                    -F "bundleId=${PRODUCT_BUNDLE_IDENTIFIER:-}" \
                    -F "appVersion=${MARKETING_VERSION:-}" \
                    -F "buildNumber=${CURRENT_PROJECT_VERSION:-}" \
                    -F "configuration=${CONFIGURATION:-}" \
                    "$SERVER_URL/api/dsyms" 2>&1)
                if [ $? -eq 0 ] && [[ "$response" == *'"uuids"'* ]]; then
                    echo "CrashCam: dSYM upload response: $response"
                    mark_uploaded "$snap" "$SERVER_URL"
                else
                    echo "warning: CrashCam dSYM upload failed (is crash-server running at $SERVER_URL?): $response"
                fi
            done
            rm -f "$snap"
        done
    done

    if [ "$found" -eq 0 ]; then
        echo "CrashCam: no dSYM produced (Debug builds don't generate one by default) — skipping upload."
    fi
    echo "CrashCam: dSYM upload pass finished."
}

if [ "${CRASHCAM_FOREGROUND:-0}" = "1" ]; then
    upload_all
else
    LOG_DIR="$HOME/Library/Logs/CrashCam"
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
    LOG_FILE="$LOG_DIR/dsym-upload-$(date +%Y%m%d-%H%M%S).log"
    echo "CrashCam: uploading dSYMs in the background — log: $LOG_FILE"
    upload_all > "$LOG_FILE" 2>&1 < /dev/null &
    disown 2>/dev/null || true
fi

exit 0
