#!/bin/bash
#
# Xcode build phase: upload this build's dSYMs to a running crash-server so the
# dashboard can symbolicate uploaded crash reports (matched by binary UUID).
#
# Debug builds default to DEBUG_INFORMATION_FORMAT=dwarf (no dSYM bundle), so
# with stock settings this only ever uploads for Release builds. The gate is
# "a dSYM exists", not the configuration name, so enabling dwarf-with-dsym in
# Debug opts that configuration in too.
#
# This script must never fail the build: no server running is a normal state.
# Override the target with CRASHCAM_SERVER_URL (default http://localhost:4000);
# it may hold SEVERAL space-separated URLs and each one gets every dSYM (a dead
# server just logs a warning). If a target requires an upload token (its
# CRASHCAM_UPLOAD_TOKEN env var is set — the hosted deployment), export
# CRASHCAM_UPLOAD_TOKEN here too; it is sent as an X-CrashCam-Token header and
# open servers simply ignore it.

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

found=0
for dsym in "$DWARF_DSYM_FOLDER_PATH"/*.dSYM; do
    [ -d "$dsym" ] || continue
    # A dSYM bundle is a directory wrapper; the actual DWARF binaries live in
    # Contents/Resources/DWARF/. Upload those directly — the server derives the
    # UUIDs itself with dwarfdump, so nothing needs zipping.
    for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
        [ -f "$dwarf" ] || continue
        found=1
        for SERVER_URL in $SERVER_URLS; do
            echo "CrashCam: uploading dSYM $(basename "$dsym") → $SERVER_URL/api/dsyms"
            response=$(/usr/bin/curl --silent --show-error --max-time 120 \
                --retry 2 --retry-all-errors \
                ${TOKEN_HEADER[@]+"${TOKEN_HEADER[@]}"} \
                -F "dsym=@${dwarf}" \
                -F "binaryName=$(basename "$dwarf")" \
                -F "appName=${PRODUCT_NAME:-}" \
                -F "bundleId=${PRODUCT_BUNDLE_IDENTIFIER:-}" \
                -F "appVersion=${MARKETING_VERSION:-}" \
                -F "buildNumber=${CURRENT_PROJECT_VERSION:-}" \
                -F "configuration=${CONFIGURATION:-}" \
                "$SERVER_URL/api/dsyms" 2>&1)
            if [ $? -eq 0 ]; then
                echo "CrashCam: dSYM upload response: $response"
            else
                echo "warning: CrashCam dSYM upload failed (is crash-server running at $SERVER_URL?): $response"
            fi
        done
    done
done

if [ "$found" -eq 0 ]; then
    echo "CrashCam: no dSYM produced (Debug builds don't generate one by default) — skipping upload."
fi

exit 0
