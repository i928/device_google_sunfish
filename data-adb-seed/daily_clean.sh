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

# Configuration Paths
# NOTE: /storage/emulated/0 is a FUSE mount isolated from the init namespace.
# Writing directly to the absolute path under /data guarantees availability to root.
MANAGED_DIR="/data/media/0/Download/F2FSCompressed"
LOG_FILE="$MANAGED_DIR/f2fs-compress.log"
F2FS_IO="/product/bin/f2fs_io"

# Ensure runtime directories exist
mkdir -p "$MANAGED_DIR"

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
# ---------------------------------------------------------------------
# Mark the target directory for inheritance. New files automatically receive the compression flag.
if ! "$F2FS_IO" setflags compression "$MANAGED_DIR" >> "$LOG_FILE" 2>&1; then
    echo "[ERROR] Failed to bind compression attribute flags to $MANAGED_DIR." >> "$LOG_FILE"
    exit 1
fi

# Initialize runtime tally metrics
compressed_count=0
released_blocks_total=0

echo "[INFO] Scanning for uncompressed targets within $MANAGED_DIR..." >> "$LOG_FILE"

# Process Substitution (< <(find...)) prevents the execution loop from spawning a Subshell,
# guaranteeing that variable state manipulation persists past loop termination.
while IFS= read -r file; do
    # Verify the item has inherited the active cluster configuration compression flag
    "$F2FS_IO" getflags "$file" 2>/dev/null | grep -qw compression || continue

    # Because compress_mode=user is configured in fstab, the kernel requires manual invocation
    if "$F2FS_IO" compress "$file" >> "$LOG_FILE" 2>&1; then
        # Reclaim unused physical disk allocation blocks generated from compression sizing margins
        released_blocks_current="$("$F2FS_IO" release_cblocks "$file" 2>> "$LOG_FILE")"
        
        # Enforce basic numeric integrity sanitization
        case "$released_blocks_current" in
            ''|*[!0-9]*) released_blocks_current=0 ;;
        esac
        
        compressed_count=$((compressed_count + 1))
        released_blocks_total=$((released_blocks_total + released_blocks_current))
    fi
done < <(find "$MANAGED_DIR" -xdev -type f -size +4k -size -100M \( -name '*.txt' -o -name '*.log' -o -name '*.json' -o -name '*.xml' -o -name '*.csv' \))

# Calculate accurate aggregate block footprint reductions (AOSP blocks default to 4KB size metric)
approx_saved_mib=$((released_blocks_total * 4 / 1024))

echo "[SUCCESS] Compression routine completed." >> "$LOG_FILE"
echo ">> Total Files Optimized: $compressed_count" >> "$LOG_FILE"
echo ">> Reclaimed Storage Blocks: $released_blocks_total" >> "$LOG_FILE"
echo ">> Estimated Space Savings: ${approx_saved_mib} MiB" >> "$LOG_FILE"

