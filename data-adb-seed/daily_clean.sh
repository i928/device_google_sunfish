#!/system/bin/sh

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

# Scan read-only APKs and native binaries (.so), bypassing active root-tool runtimes
find /data/app -xdev -type f \( -name '*.so' -o -name '*.apk' \) -size +15k | while IFS= read -r file; do

    # Enforce an explicit exception filter to protect tool runtimes (Magisk / Shizuku)
    case "$file" in
        *moe.shizuku*|*top.johnwu.magisk*) continue ;;
    esac

    # Only files that inherited the compression flag at creation qualify
    "$F2FS_IO" getflags "$file" 2>/dev/null | grep -qw compression || continue

    # Invoke manual execution block (Natively resolves compress_mode=user passive states)
    if "$F2FS_IO" compress "$file" >> "$LOG_FILE" 2>&1; then
        # Reclaim block allocation margins
        released_blocks_current="$("$F2FS_IO" release_cblocks "$file" 2>> "$LOG_FILE")"

        # Sanitize loop inputs
        case "$released_blocks_current" in
            ''|*[!0-9]*) released_blocks_current=0 ;;
        esac

        if [ "$released_blocks_current" -gt 0 ]; then
            compressed_count=$((compressed_count + 1))
            released_blocks_total=$((released_blocks_total + released_blocks_current))
            
            # Commit running state to a temp register to completely bypass mksh subshell pipe isolation
            echo "$compressed_count $released_blocks_total" > /data/local/tmp/.f2fs_tally
        fi
    fi
done

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
