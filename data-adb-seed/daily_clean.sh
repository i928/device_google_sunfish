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
# (fs/f2fs/file.c: EINVAL if F2FS_HAS_BLOCKS), so existing files cannot be
# converted. Flagging /data/app makes files created later -- app installs and
# updates -- inherit it; the loop picks those up and skips the rest.
# ---------------------------------------------------------------------
# Target Configuration: Scan the actual Android App directory
MANAGED_DIR="/data/app"

# Mark the target directory for future inheritance.
"$F2FS_IO" setflags compression "$MANAGED_DIR" >> "$LOG_FILE" 2>&1

# Initialize runtime tally metrics
compressed_count=0
released_blocks_total=0

echo "[INFO] Scanning for uncompressed targets within $MANAGED_DIR..." >> "$LOG_FILE"

TMP_DIR="/data/local/tmp/f2fs_scratch"
# Ensure our working directory exists
mkdir -p "$TMP_DIR"
echo "--- Starting F2FS Optimization Loop ---" > "$LOG_FILE"

# Batch processing throttle threshold counter
loop_count=0

# Find target binaries deep within subdirectories
find /data/app -xdev -type f \( -name '*.so' -o -name '*.apk' \) -size +15k | while IFS= read -r file; do

    # Enforce an explicit exception filter to protect tool runtimes (Magisk / Shizuku)
    case "$file" in
        *moe.shizuku*|*top.johnwu.magisk*) continue ;;
    esac

    # 1. DAILY SKIP CHECK: Verify actual active compression status
    if "$F2FS_IO" getflags "$file" 2>/dev/null | grep -qw compression; then
        c_blocks=$("$F2FS_IO" get_cblocks "$file" 2>/dev/null)
        case "$c_blocks" in
            ''|*[!0-9]*) c_blocks=0 ;;
        esac
        # Already processed files skip instantly in milliseconds
        if [ "$c_blocks" -gt 0 ]; then
            continue
        fi
    fi

    # 2. Extract package name from the /data/app path string
    pkg_name=$(echo "$file" | sed -E 's|^/data/app/~~[^/]+/([^/-]+).*|\1|')

    # Double check extraction accuracy; fallback safely to log tracking if parsing slips
    if [ -z "$pkg_name" ] || [ "$pkg_name" = "data" ]; then
        pkg_name="unknown"
    fi

    echo "Processing target file: $file [Package: $pkg_name]" >> "$LOG_FILE"
    tmp_file="$TMP_DIR/$(basename "$file").tmp"

    # 3. Create a fresh empty file and initialize the compression inode layout
    touch "$tmp_file"
    if ! "$F2FS_IO" setflags compression "$tmp_file" >> "$LOG_FILE" 2>&1; then
        echo "Failed to set compression flag on temp file" >> "$LOG_FILE"
        rm -f "$tmp_file"
        continue
    fi

    # 4. Stream the original payload into the newly flagged structure
    if ! cat "$file" > "$tmp_file" 2>> "$LOG_FILE"; then
        echo "Failed to copy payload for: $file" >> "$LOG_FILE"
        rm -f "$tmp_file"
        continue
    fi

    # 5. Invoke compression clustering sequence
    if "$F2FS_IO" compress "$tmp_file" >> "$LOG_FILE" 2>&1; then
        # Reclaim the unused file allocation block margins
        released_blocks_current="$("$F2FS_IO" release_cblocks "$tmp_file" 2>> "$LOG_FILE")"
        # Sanitize loop inputs
        case "$released_blocks_current" in
            ''|*[!0-9]*) released_blocks_current=0 ;;
        esac

        # 6. FIX: Use standard Android Toybox 'stat' options to read original attributes
        # %a = octal permissions, %u = owner UID, %g = owner GID
        perms=$(stat -c "%a" "$file" 2>/dev/null)
        uid=$(stat -c "%u" "$file" 2>/dev/null)
        gid=$(stat -c "%g" "$file" 2>/dev/null)

        # Apply extracted permissions explicitly
        [ -n "$perms" ] && chmod "$perms" "$tmp_file" 2>> "$LOG_FILE"
        [ -n "$uid" ] && [ -n "$gid" ] && chown "$uid:$gid" "$tmp_file" 2>> "$LOG_FILE"
        
        # 7. Force-stop runtime operations to unlock active files safely
        if [ "$pkg_name" != "unknown" ]; then
            echo "Suspending app runtime: $pkg_name" >> "$LOG_FILE"
            am force-stop "$pkg_name" >/dev/null 2>&1
        fi

        # Swap the optimized file into place
        if mv -f "$tmp_file" "$file" 2>> "$LOG_FILE"; then
            # Fix SELinux context after replacing the file
            restorecon "$file" 2>> "$LOG_FILE"

            # CRITICAL SECURITY FIX: Force immediate block flush right now
            # This pushes the file changes straight to the chip instead of letting them pile up in RAM
            sync -f "$file" 2>/dev/null

            if [ "$released_blocks_current" -gt 0 ]; then
                # Read running variables dynamically to handle pipeline shifts safely
                if [ -f /data/local/tmp/.f2fs_tally ]; then
                    read -r c_count r_total < /data/local/tmp/.f2fs_tally
                else
                    c_count=0; r_total=0
                fi
                
                c_count=$((c_count + 1))
                r_total=$((r_total + released_blocks_current))
                echo "$c_count $r_total" > /data/local/tmp/.f2fs_tally
            fi
            
            # Increment our batch safety throttle tracker
            loop_count=$((loop_count + 1))
            # Rest 0.5s between every single file operation to keep UI responsive
            usleep 500000 2>/dev/null || sleep 1
            # Every 15 active files, force a hard global system cache flush and rest for 3 seconds
            if [ $((loop_count % 15)) -eq 0 ]; then
                echo "Throttling batch... Flushing system caches safely." >> "$LOG_FILE"
                sync
                echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
                sleep 3
            fi
        else
            echo "Failed to swap optimized file into place: $file" >> "$LOG_FILE"
            rm -f "$tmp_file"
        fi
    else
        echo "Compression ioctl failed for structural reasons: $file" >> "$LOG_FILE"
        rm -f "$tmp_file"
    fi
done

# Perform final system buffer cleanup
sync
echo "--- Optimization Loop Finished ---" >> "$LOG_FILE"

END_TIME=$SECONDS
ELAPSED_TOTAL=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED_TOTAL / 60))
ELAPSED_SEC=$((ELAPSED_TOTAL % 60))

echo "--------------------------------------------------------"
if [ -f /data/local/tmp/.f2fs_tally ]; then
    read -r final_count final_blocks < /data/local/tmp/.f2fs_tally
    saved_mib=$(( (final_blocks * 4) / 1024 ))
    echo "[SUCCESS] F2FS safe optimization cycle complete."
    echo ">> New Files Compressed Today: $final_count"
    echo ">> Reclaimed Space: ~${saved_mib} MiB"
    echo ">> Total Process Execution Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
else
    echo "[SUCCESS] F2FS daily optimization complete. Everything is already up-to-date!"
    echo ">> Process Execution Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
fi
echo "--------------------------------------------------------"

# Clean up working tree
rm -rf "$TMP_DIR"
echo "--- Optimization Loop Finished ---" >> "$LOG_FILE"

# Synchronize metrics back into parent thread scope
if [ -f /data/local/tmp/.f2fs_tally ]; then
    read -r compressed_count released_blocks_total < /data/local/tmp/.f2fs_tally
    rm -f /data/local/tmp/.f2fs_tally
fi

# Calculate storage reduction boundaries (4KB sectors mapped to MiB)
approx_saved_mib=$((released_blocks_total * 4 / 1024))

echo "[SUCCESS] F2FS optimization cycle finalized." >> "$LOG_FILE"
echo ">> Total Files Optimized: $compressed_count" >> "$LOG_FILE"
echo ">> Reclaimed Storage Blocks: $released_blocks_total" >> "$LOG_FILE"
echo ">> Estimated Space Savings: ${approx_saved_mib} MiB" >> "$LOG_FILE"
echo "--------------------------------------------------------" >> "$LOG_FILE"
