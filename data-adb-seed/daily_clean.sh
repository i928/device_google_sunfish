#!/system/bin/sh

# Initialize the process timer register natively
START_TIME=$SECONDS
# =====================================================================
# F2FS User-Mode Compression & Automated Cache Maintenance Script
# Target: Android 16 (Evolution X 11) - Pixel 4a (sunfish)
# =====================================================================

CURRENT_DAY=$(date +%u)
CURRENT_HOUR=$(date +%H)

# Restrict the heavy optimization workload to run only during off-peak hours (04:00 AM)
# if [ "$CURRENT_DAY" != "7" ] || [ "$CURRENT_HOUR" != "04" ]; then
if [ "$CURRENT_HOUR" != "04" ]; then
    exit 0
fi

# 1. Enforce strict absolute paths for background/headless reliability
PATH="/system/bin:/system/xbin:/product/bin:/apex/com.android.runtime/bin"
export PATH

# Lowest CPU priority and idle I/O class: f2fs compression runs in this
# process's context, so the foreground app always wins.
renice -n 19 -p $$ >/dev/null 2>&1
ionice -c 3 -p $$ >/dev/null 2>&1

# Configuration Paths
# NOTE: /storage/emulated/0 is a FUSE mount isolated from the init namespace.
# Writing directly to the absolute path under /data guarantees availability to root.
LOG_DIR="/data/media/0/Download/F2FSCompressed"
LOG_FILE="$LOG_DIR/f2fs-compress.log"
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chmod 775 "$LOG_DIR"
    echo "[INFO] Creating directory topology at $LOG_DIR..." >> "$LOG_FILE"
fi
F2FS_IO="/product/bin/f2fs_io"


echo "=== F2FS optimization cycle initiated: $(date) ===" >> "$LOG_FILE"

# ---------------------------------------------------------------------
# Phase 1: Storage Pressure Assessment & Dynamic Cache Trimming
# ---------------------------------------------------------------------
DATA_USED_PERCENT="$(df -P /data 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"

case "$DATA_USED_PERCENT" in
  ''|*[!0-9]*)
      echo "[WARN] Unable to determine /data partition utilization; bypassing cache trim." >> "$LOG_FILE"
      ;;
  *)
      echo "[INFO] Current /data utilization status: ${DATA_USED_PERCENT}%." >> "$LOG_FILE"
      # If disk consumption crosses the critical threshold (90%), invoke app cache eviction
      if [ "$DATA_USED_PERCENT" -ge 90 ]; then
          echo "[CRIT] Storage pressure detected. Executing package manager cache trim (2GB target)." >> "$LOG_FILE"
          # 'pm' binary is restricted for UID 0 (root) on Android 16. Using 'cmd' subsystem instead.
          cmd package trim-caches 2G >> "$LOG_FILE" 2>&1
      fi
      ;;
esac

# ---------------------------------------------------------------------
# Phase 2: F2FS Structural Requirements Verification
# ---------------------------------------------------------------------
DEV_NODE="$(awk '$2 == "/data" { sub(".*/", "", $1); print $1; exit }' /proc/mounts)"
SYSFS_DIR="/sys/fs/f2fs/$DEV_NODE"
FEATURES="$SYSFS_DIR/features"

if [ -z "$DEV_NODE" ] || [ ! -r "$FEATURES" ]; then
    echo "[ERROR] Missing filesystem node. Cannot map F2FS sysfs topology." >> "$LOG_FILE"
    exit 1
fi

if ! grep -qw compression "$FEATURES"; then
    echo "[ERROR] /data partition does not support F2FS compression. Format userdata with vold.has_compress=true." >> "$LOG_FILE"
    exit 1
fi

if [ ! -x "$F2FS_IO" ]; then
    echo "[ERROR] $F2FS_IO binary missing or execution bit not set. Ensure f2fs_io is in PRODUCT_PACKAGES." >> "$LOG_FILE"
    exit 1
fi

# ---------------------------------------------------------------------
# Phase 3: Explicit Manual Compression Workloop (compress_mode=user)
#
# Only APKs and extracted native libraries under /data/app. They are read-only
# and replaced whole on app updates, so release_cblocks is safe for them. After
# release_cblocks the kernel refuses writes to a file (EPERM; SIGBUS through a
# writable mapping), so files apps write -- anything under Android/data --
# must never be released. chattr -p 0 is not used either: /data/media relies
# on project IDs for per-app storage accounting.
#
# The kernel only sets the compression flag on a file with no data yet
# (fs/f2fs/file.c: EINVAL if F2FS_HAS_BLOCKS). So:
#   - files that inherited the flag (installed after /data/app was flagged)
#     are compressed in place;
#   - older files are copied into a fresh flagged file, compressed, and renamed
#     over the original. Running processes keep the old inode until they close
#     it, so no app has to be stopped. The copy keeps the original mode, owner
#     and mtime (an mtime change makes PackageManager treat the apk as modified).
#
# Requires the kernel fix "f2fs: redirty_blocks: use read_mapping_page() on
# 4.14" -- without it F2FS_IOC_COMPRESS_FILE panics (CFI, NULL filler).
#
# No am force-stop and no drop_caches here: force-stopping each package also
# stopped gms, webview, the keyboard and the launcher, and drop_caches throws
# away every cached code page system-wide -- together they froze the UI for
# seconds and could trip the system_server watchdog (2026-09-30).
# ---------------------------------------------------------------------
# Target Configuration: Scan the actual Android App directory
MANAGED_DIR="/data/app"
TMP_DIR="/data/local/tmp/f2fs_scratch"
TALLY="/data/local/tmp/.f2fs_tally"
# Files released without gain earlier: compress refuses them with EINVAL every
# run and nothing tells them apart from untouched files, so they are listed
# here and skipped. Rewritten each run with only the paths still present (an
# app update gets a new /data/app path and is tried again).
SKIP_LIST="/data/adb/f2fs_compress_skip.list"

# Mark the target directory for future inheritance.
"$F2FS_IO" setflags compression "$MANAGED_DIR" >> "$LOG_FILE" 2>&1

rm -f "$TALLY"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR/einval"
: > "$TMP_DIR/skip.new"
[ -f "$SKIP_LIST" ] || : > "$SKIP_LIST"
echo "[INFO] Scanning for uncompressed targets within $MANAGED_DIR..." >> "$LOG_FILE"

# compress + release one flagged file; prints the released block count
compress_release() {
    "$F2FS_IO" compress "$1" >> "$LOG_FILE" 2>&1 || return 1
    n="$("$F2FS_IO" release_cblocks "$1" 2>> "$LOG_FILE")"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    echo "$n"
}

# Same, but a compress failure is reported through $TMP_DIR/err instead of the
# log, so the caller can tell EINVAL (already released) from a real error.
compress_release_quiet() {
    "$F2FS_IO" compress "$1" > "$TMP_DIR/err" 2>&1 || return 1
    n="$("$F2FS_IO" release_cblocks "$1" 2>> "$LOG_FILE")"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    echo "$n"
}

find "$MANAGED_DIR" -xdev -type f \( -name '*.so' -o -name '*.apk' \) -size +15k | while IFS= read -r file; do

    # Enforce an explicit exception filter to protect tool runtimes (Magisk / Shizuku)
    case "$file" in
        *moe.shizuku*|*top.johnwu.magisk*) continue ;;
    esac

    if "$F2FS_IO" getflags "$file" 2>/dev/null | grep -qw compression; then
        # Done already when it occupies less disk than its length (compressed
        # and released). get_cblocks cannot tell: release_cblocks resets the
        # file's compressed-block count to 0 (fs/f2fs/file.c).
        [ $(( $(stat -c %b "$file") * 512 )) -lt "$(stat -c %s "$file")" ] && continue
        if grep -qxF "$file" "$SKIP_LIST"; then
            echo "$file" >> "$TMP_DIR/skip.new"; continue
        fi
        # Flagged but not yet compressed: in place. A file released without
        # gain (incompressible) refuses compress with EINVAL every run; that
        # is expected, so it is only counted, not logged.
        if ! released=$(compress_release_quiet "$file"); then
            if grep -q "Invalid argument" "$TMP_DIR/err"; then
                # Released but never compressed (seen on crosshatch: 416
                # files, 3.6 GB, released with nothing saved). Un-release,
                # compress and release again; skip-list it only if that
                # still saves nothing.
                released=0
                if "$F2FS_IO" reserve_cblocks "$file" >/dev/null 2>&1; then
                    released=$(compress_release_quiet "$file") || released=0
                fi
                if [ "$released" -gt 0 ]; then
                    echo "Recompressed: $file" >> "$LOG_FILE"
                    c_count=0; r_total=0
                    [ -f "$TALLY" ] && read -r c_count r_total < "$TALLY"
                    echo "$((c_count + 1)) $((r_total + released))" > "$TALLY"
                    continue
                fi
                echo x >> "$TMP_DIR/einval"
                echo "$file" >> "$TMP_DIR/skip.new"
            else
                # Anything else (EBUSY, EOPNOTSUPP, ...) is logged and retried
                # next run, never skip-listed.
                echo "Compress failed: $file: $(cat "$TMP_DIR/err")" >> "$LOG_FILE"
            fi
            continue
        fi
        echo "In place: $file" >> "$LOG_FILE"
    else
        echo "Copy: $file" >> "$LOG_FILE"
        tmp_file="$TMP_DIR/$(basename "$file").tmp"
        rm -f "$tmp_file"; touch "$tmp_file"
        if ! "$F2FS_IO" setflags compression "$tmp_file" >> "$LOG_FILE" 2>&1 ||
           ! cat "$file" > "$tmp_file" 2>> "$LOG_FILE"; then
            rm -f "$tmp_file"; continue
        fi
        if ! released=$(compress_release "$tmp_file"); then
            rm -f "$tmp_file"; continue
        fi
        # %a = octal permissions, %u = owner UID, %g = owner GID
        chmod "$(stat -c %a "$file")" "$tmp_file" &&
        chown "$(stat -c %u "$file"):$(stat -c %g "$file")" "$tmp_file" &&
        touch -r "$file" "$tmp_file" &&
        mv -f "$tmp_file" "$file" 2>> "$LOG_FILE" || {
            echo "Failed to swap optimized file into place: $file" >> "$LOG_FILE"
            rm -f "$tmp_file"; continue
        }
        restorecon "$file" 2>> "$LOG_FILE"
    fi

    if [ "$released" -gt 0 ]; then
        c_count=0; r_total=0
        [ -f "$TALLY" ] && read -r c_count r_total < "$TALLY"
        echo "$((c_count + 1)) $((r_total + released))" > "$TALLY"
    fi
    # Pace the I/O so the foreground stays responsive
    usleep 200000 2>/dev/null || sleep 1
done

skipped_einval=0
[ -f "$TMP_DIR/einval" ] && skipped_einval=$(wc -l < "$TMP_DIR/einval")
skip_listed=$(wc -l < "$TMP_DIR/skip.new")
mv -f "$TMP_DIR/skip.new" "$SKIP_LIST"
rm -rf "$TMP_DIR"
sync

# Synchronize metrics back from the pipeline subshell
compressed_count=0; released_blocks_total=0
if [ -f "$TALLY" ]; then
    read -r compressed_count released_blocks_total < "$TALLY"
    rm -f "$TALLY"
fi

ELAPSED_TOTAL=$((SECONDS - START_TIME))
{
    echo "[SUCCESS] F2FS optimization cycle finalized."
    echo ">> Files Compressed This Run: $compressed_count"
    echo ">> Released Earlier Without Gain: $skip_listed on the skip list ($skipped_einval new)"
    echo ">> Reclaimed Storage Blocks: $released_blocks_total"
    echo ">> Estimated Space Savings: $((released_blocks_total * 4 / 1024)) MiB"
    echo ">> Execution Time: $((ELAPSED_TOTAL / 60))m $((ELAPSED_TOTAL % 60))s"
    echo "--------------------------------------------------------"
} | tee -a "$LOG_FILE"

# The log is written as root straight to /data/media, past the FUSE layer, so
# MediaStore (USB/MTP, file managers) keeps the old size until it is rescanned.
am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file:///storage/emulated/0/${LOG_FILE#/data/media/0/}" >/dev/null 2>&1
