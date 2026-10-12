#!/bin/bash
#
# Xcode build phase: upload this build's dSYMs to a running crash-server so the
# dashboard can symbolicate uploaded crash reports (matched by binary UUID).
#
# What is sent, per DWARF file inside each .dSYM bundle:
#   1. The file is snapshotted (see stable_copy) and split into one file per
#      architecture (`lipo -thin`). The server keys its store by slice UUID, so
#      every slice is its own upload and slices already on the server are
#      skipped individually.
#   2. Sections crash symbolication never reads are zeroed in the copy: the
#      embedded Swift module ASTs (__swift_ast, used only by LLDB) and the
#      variable location lists (__debug_loc). Layout, LC_UUID, symbol table,
#      function and line info stay untouched, so atos and llvm-symbolizer
#      resolve frames exactly as before. Zeroing instead of removing keeps the
#      Mach-O valid without rewriting offsets.
#   3. The slice is gzipped; the zeroed bytes vanish. A ~290 MB slice of a
#      large Swift app ships as ~40 MB, well under typical proxy body limits.
#   crash-server inflates gzipped uploads since 2026-09-03. For an older server
#   set CRASHCAM_RAW_UPLOAD=1 (no trimming, no gzip — one upload per slice).
#
# The upload runs DETACHED: Xcode only waits for processes holding the build
# log's pipes, so the build finishes immediately while the upload continues in
# the background. Progress goes to a log file whose path is printed in the
# build log. Set CRASHCAM_FOREGROUND=1 to upload synchronously instead (CI
# machines may disappear right after the build).
#
# Slices already uploaded (per server, matched by UUID) are recorded in
# ~/Library/Caches/CrashCam/uploaded-dsyms and skipped, so incremental rebuilds
# upload nothing.
#
# Debug builds default to DEBUG_INFORMATION_FORMAT=dwarf (no dSYM bundle), so
# with stock settings this only ever uploads for Release builds. The gate is
# "a dSYM exists", not the configuration name. A project that makes Debug
# dSYMs too can keep Debug builds out with a first line of
#     [ "$CONFIGURATION" = Release ] || exit 0
# in its Run Script phase.
#
# This script must never fail the build: no server running is a normal state.
# The target is the CrashCam server (CRASHCAM_DEFAULT_SERVER below — the same
# constant the SDK carries); CRASHCAM_SERVER_URL overrides it and may hold
# SEVERAL space-separated URLs, each of which gets every dSYM (development:
# add a local crash-server). The app's upload token is read from the built
# Info.plist (`CrashCamToken`, the key the SDK reads too), or from
# CRASHCAM_UPLOAD_TOKEN when exported; it is sent as X-CrashCam-Token.

set -u

CRASHCAM_DEFAULT_SERVER="https://crashcam.kerimcaglar.com"
SERVER_URLS="${CRASHCAM_SERVER_URL:-$CRASHCAM_DEFAULT_SERVER}"

# Token: the environment wins, else the key in the app's built Info.plist.
UPLOAD_TOKEN="${CRASHCAM_UPLOAD_TOKEN:-}"
if [ -z "$UPLOAD_TOKEN" ] && [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${INFOPLIST_PATH:-}" ] \
   && [ -f "$TARGET_BUILD_DIR/$INFOPLIST_PATH" ]; then
    UPLOAD_TOKEN="$(/usr/libexec/PlistBuddy -c 'Print :CrashCamToken' "$TARGET_BUILD_DIR/$INFOPLIST_PATH" 2>/dev/null || true)"
fi
TOKEN_HEADER=()
if [ -n "$UPLOAD_TOKEN" ]; then
    TOKEN_HEADER=(-H "X-CrashCam-Token: ${UPLOAD_TOKEN}")
else
    echo "CrashCam: no upload token (CrashCamToken in Info.plist or CRASHCAM_UPLOAD_TOKEN) — the server will reject the dSYM upload."
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

size_mb() { echo $(( $(/usr/bin/stat -f %z "$1" 2>/dev/null || echo 0) / 1048576 )); }

# Snapshot a DWARF before uploading. The upload runs detached, so the next
# build (or a dsymutil still finalizing the bundle) can rewrite the file while
# curl reads it — a torn upload fails with "curl: (26) ... EOF". Wait for the
# size to hold still, then clone it (APFS copy-on-write; falls back to a real
# copy) and work on the immutable snapshot.
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

# Zero the sections symbolication never reads, in place, in a snapshot. Best
# effort: without python3, or on an unexpected file, the slice goes untrimmed.
slim_dwarf() { # $1 = slice path
    local py
    py=$(/usr/bin/xcrun -f python3 2>/dev/null) || py=/usr/bin/python3
    if [ ! -x "$py" ]; then
        echo "CrashCam: python3 not found — uploading $(basename "$1") untrimmed."
        return 0
    fi
    "$py" - "$1" <<'PY' || echo "CrashCam: trimming $(basename "$1") failed — uploading it untrimmed."
import struct, sys

DEAD = {(b"__DWARF", b"__swift_ast"), (b"__DWARF", b"__debug_loc"),
        (b"__DWARF", b"__debug_loclists")}
CHUNK = 1 << 20

def slice_bases(f):
    f.seek(0)
    magic = f.read(4)
    if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return [0]
    fat64 = magic == b"\xca\xfe\xba\xbf"
    n = struct.unpack(">I", f.read(4))[0]
    bases = []
    for _ in range(n):
        if fat64:
            _, _, off, _, _, _ = struct.unpack(">IIQQII", f.read(32))
        else:
            _, _, off, _, _ = struct.unpack(">IIIII", f.read(20))
        bases.append(off)
    return bases

def dead_ranges(f, base, file_size):
    f.seek(base)
    if f.read(4) != b"\xcf\xfa\xed\xfe":  # MH_MAGIC_64, little-endian only
        return []
    f.seek(base + 16)
    ncmds = struct.unpack("<I", f.read(4))[0]
    p = base + 32
    ranges = []
    for _ in range(ncmds):
        f.seek(p)
        cmd, cmdsize = struct.unpack("<II", f.read(8))
        if cmdsize < 8:
            break
        if cmd == 0x19:  # LC_SEGMENT_64
            f.seek(p + 64)
            nsects = struct.unpack("<I", f.read(4))[0]
            q = p + 72
            for _ in range(nsects):
                f.seek(q)
                sect = f.read(80)
                name = sect[0:16].rstrip(b"\0")
                seg = sect[16:32].rstrip(b"\0")
                size, off = struct.unpack("<QI", sect[40:52])
                if (seg, name) in DEAD and off and size:
                    start = base + off
                    end = min(start + size, file_size)
                    if end > start:
                        ranges.append((name.decode(), start, end))
                q += 80
        p += cmdsize
    return ranges

zeros = bytes(CHUNK)
with open(sys.argv[1], "r+b") as f:
    f.seek(0, 2)
    file_size = f.tell()
    totals = {}
    for base in slice_bases(f):
        for name, start, end in dead_ranges(f, base, file_size):
            f.seek(start)
            left = end - start
            while left > 0:
                n = min(left, CHUNK)
                f.write(zeros[:n])
                left -= n
            totals[name] = totals.get(name, 0) + (end - start)
trimmed = ", ".join("%s %.1f MB" % (k, v / 1048576) for k, v in totals.items())
print("CrashCam: trimmed %s: %s" % (sys.argv[1].rsplit("/", 1)[-1], trimmed or "nothing to trim"))
PY
}

upload_slice() { # $1 = dSYM bundle path, $2 = binary name, $3 = arch, $4 = slice path (a snapshot; modified in place)
    local dsym="$1" name="$2" arch="$3" slice="$4"
    local label targets="" SERVER_URL payload encoding response
    label="$(basename "$dsym") ($name, $arch)"
    for SERVER_URL in $SERVER_URLS; do
        if already_uploaded "$slice" "$SERVER_URL"; then
            echo "CrashCam: $label already on $SERVER_URL (UUID match) — skipping."
        else
            targets="$targets $SERVER_URL"
        fi
    done
    [ -n "$targets" ] || return 0

    payload="$slice"; encoding="raw"
    if [ "${CRASHCAM_RAW_UPLOAD:-0}" != "1" ]; then
        slim_dwarf "$slice"
        if /usr/bin/gzip -6 -c "$slice" > "$slice.gz" 2>/dev/null; then
            payload="$slice.gz"; encoding="gzip"
        else
            rm -f "$slice.gz"
            echo "CrashCam: gzip failed for $(basename "$slice") — uploading it raw."
        fi
    fi
    echo "CrashCam: $label is $(size_mb "$slice") MB on disk, sending $(size_mb "$payload") MB ($encoding)."

    for SERVER_URL in $targets; do
        echo "CrashCam: uploading dSYM $label → $SERVER_URL/api/dsyms"
        response=$(/usr/bin/curl --silent --show-error --max-time 600 \
            --retry 1 --retry-all-errors \
            ${TOKEN_HEADER[@]+"${TOKEN_HEADER[@]}"} \
            -F "dsym=@${payload};filename=${name}.${arch}$([ "$encoding" = gzip ] && echo .gz)" \
            -F "binaryName=$name" \
            -F "arch=$arch" \
            -F "encoding=$encoding" \
            -F "appName=${PRODUCT_NAME:-}" \
            -F "bundleId=${PRODUCT_BUNDLE_IDENTIFIER:-}" \
            -F "appVersion=${MARKETING_VERSION:-}" \
            -F "buildNumber=${CURRENT_PROJECT_VERSION:-}" \
            -F "configuration=${CONFIGURATION:-}" \
            "$SERVER_URL/api/dsyms" 2>&1)
        if [ $? -eq 0 ] && [[ "$response" == *'"uuids"'* ]]; then
            echo "CrashCam: dSYM upload response: $response"
            mark_uploaded "$slice" "$SERVER_URL"
        else
            echo "warning: CrashCam dSYM upload failed (is crash-server running at $SERVER_URL?): $response"
        fi
    done
    [ "$payload" != "$slice" ] && rm -f "$payload"
    return 0
}

upload_all() {
    local found=0 dsym dwarf name snap archs nslices arch slice
    for dsym in "$DWARF_DSYM_FOLDER_PATH"/*.dSYM; do
        [ -d "$dsym" ] || continue
        # A dSYM bundle is a directory wrapper; the actual DWARF binaries live
        # in Contents/Resources/DWARF/. The server derives the UUIDs itself.
        for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
            [ -f "$dwarf" ] || continue
            found=1
            name=$(basename "$dwarf")
            snap="${TMPDIR:-/tmp}/crashcam-snap-$$-$name"
            if ! stable_copy "$dwarf" "$snap"; then
                echo "warning: CrashCam could not snapshot $name (kept changing on disk?) — will retry on the next build."
                rm -f "$snap"
                continue
            fi
            archs=$(/usr/bin/lipo -archs "$snap" 2>/dev/null)
            nslices=$(echo $archs | /usr/bin/wc -w)
            if [ "$nslices" -le 1 ]; then
                upload_slice "$dsym" "$name" "${archs:-unknown}" "$snap"
            else
                for arch in $archs; do
                    slice="$snap.$arch"
                    if /usr/bin/lipo "$snap" -thin "$arch" -output "$slice" 2>/dev/null; then
                        upload_slice "$dsym" "$name" "$arch" "$slice"
                        rm -f "$slice"
                    else
                        echo "warning: CrashCam could not extract the $arch slice of $name — uploading the fat file instead."
                        rm -f "$slice"
                        upload_slice "$dsym" "$name" "fat" "$snap"
                        break
                    fi
                done
            fi
            rm -f "$snap" "$snap.gz"
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
