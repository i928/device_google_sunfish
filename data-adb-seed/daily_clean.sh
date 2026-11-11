#!/system/bin/sh

# Wall-clock start time. $SECONDS stays 0 when daily_clean_timer.sh starts this
# (both timer-started 04:01 runs logged "0m 0s"), so use date.
START_TIME=$(date +%s)
# =====================================================================
# F2FS User-Mode Compression & Automated Cache Maintenance Script
# Shared by sunfish (Pixel 4a, Evolution X 11) and crosshatch (Pixel 3 XL,
# LineageOS 22.2): keep both device trees' copies identical.
#
# Started every 10 minutes by boot-completed.d/daily_clean_timer.sh; runs
# once a day, at the first chance between 04:00 and 08:59. Run it by hand at
# any time with: FORCE=1 sh /data/adb/daily_clean.sh
#
# Before compressing, it moves system apps that Play reinstalled into /data at
# the SAME version back to their ROM copy (Phase 1b).
#
# Compression is a switch: the "F2FS App Compression" KernelSU module
# (id f2fs_compress) enabled = compress with lz4 (lz4hc level 9 with the
# compress_algorithm=lz4:9 fstab); disabled or not installed = keep /data/app
# plain. Apps listed in Download/F2FSCompressed/non-compression.txt are never
# compressed. Files in the wrong state (zstd from older builds, compressed
# while the switch is off or the app is listed) are converted on the next run.
#
# The log keeps one summary per run, then one short line per file compressed
# (package/file, e.g. com.android.vending/base.apk; no /data/app path), plus
# real failures.
# =====================================================================

CURRENT_DAY=$(date +%u)
CURRENT_HOUR=$(date +%H)
TODAY=$(date +%F)
STAMP=/data/adb/.daily_clean.last

# Off-peak window, once per day. Not "only in the 04:00 hour": the timer's
# sleep stops counting while the phone is in deep sleep (crosshatch spent 9 of
# 16.5 h suspended on 2026-10-04/05), so its wake-up can land hours late and a
# one-hour window was simply missed. The stamp makes a late wake-up still run,
# exactly once.
if [ -z "$FORCE" ]; then
    [ "$CURRENT_HOUR" -ge 4 ] && [ "$CURRENT_HOUR" -lt 9 ] || exit 0
    [ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ] && exit 0
fi
echo "$TODAY" > "$STAMP"

# Keep the CPU awake for the whole run; without a wake lock a 12-minute
# compression pass gets stretched across deep sleep.
WAKE_LOCK=daily_clean
echo "$WAKE_LOCK" > /sys/power/wake_lock 2>/dev/null
trap 'echo "$WAKE_LOCK" > /sys/power/wake_unlock 2>/dev/null' EXIT

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
[ -x "$F2FS_IO" ] || F2FS_IO="/system/bin/f2fs_io"


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
# Phase 1b: Move same-version system app updates back to the ROM copy
#
# PackageManager replaces a /data update only with a STRICTLY newer system
# version, so a ROM that bakes in the same version as the phone's /data copy
# never wins it back. Play also reinstalls a system app into /data whenever it
# wants a split the ROM copy lacks (a language split, e.g. split_config.zh on a
# phone with a zh-Hant-TW locale). The /data copy costs space and reads slower
# than EROFS.
#
# An app is moved back (cmd package uninstall-system-updates; data and
# permissions are kept) only when BOTH hold:
#   - /data versionCode == ROM versionCode, so a real update is never undone;
#   - the ROM copy has every split the /data copy has, or Play would just
#     reinstall it again.
# It then gets compiled (speed-profile): an app set in the ROM has no dexpreopt.
# Runs before Phase 3 so a moved-back app is not compressed first.
# ---------------------------------------------------------------------
REVERT_DIR="/data/local/tmp/.daily_revert"
rm -rf "$REVERT_DIR"; mkdir -p "$REVERT_DIR"
reverted_count=0
: > "$REVERT_DIR/moved"

# Split names of one installed copy, one per line, normalized so both naming
# schemes compare: base.apk / <module>.apk -> base; split_config.X.apk,
# split_X.apk, <module>-X.apk -> X. $1 = module name (the ROM directory name).
split_names() {
    while IFS= read -r f; do
        b=${f##*/}; b=${b%.apk}
        case "$b" in
            base|"$1") echo base ;;
            split_config.*) echo "${b#split_config.}" ;;
            split_*) echo "${b#split_}" ;;
            "$1"-*) echo "${b#"$1"-}" ;;
            *) echo "$b" ;;
        esac
    done | sort
}

for pkg in $(cmd package list packages -s 2>/dev/null | sed 's/^package://'); do
    dpath=$(cmd package path "$pkg" 2>/dev/null | sed -n '1s/^package://p')
    case "$dpath" in /data/app/*) ;; *) continue ;; esac

    # dumpsys lists the /data copy first, then the hidden system copy.
    info=$(dumpsys package "$pkg" | awk '
        /^ *codePath=/ { cp = substr($1, 10) }
        /^ *versionCode=/ && cp != "" { split($1, a, "="); print cp, a[2]; cp = "" }')
    dvc=$(echo "$info" | awk '$1 ~ "^/data/" { print $2; exit }')
    sline=$(echo "$info" | awk '$1 !~ "^/data/" { print; exit }')
    scp=${sline% *}; svc=${sline#* }
    [ -n "$sline" ] && [ -d "$scp" ] || continue
    [ "$dvc" = "$svc" ] || continue

    mod=${scp##*/}
    cmd package path "$pkg" | sed 's/^package://' | split_names "$mod" > "$REVERT_DIR/d"
    ls "$scp"/*.apk 2>/dev/null | split_names "$mod" > "$REVERT_DIR/s"
    missing=$(comm -23 "$REVERT_DIR/d" "$REVERT_DIR/s" | tr '\n' ' ')
    if [ -n "$missing" ]; then
        echo "[INFO] Keeping $pkg in /data: ROM copy lacks split(s): $missing" >> "$LOG_FILE"
        continue
    fi

    r=$(cmd package uninstall-system-updates "$pkg" 2>&1)
    case "$(cmd package path "$pkg" | sed -n '1s/^package://p')" in
        /data/*) echo "[WARN] Could not move $pkg back to $scp: $r" >> "$LOG_FILE" ;;
        *)
            reverted_count=$((reverted_count + 1))
            echo "  moved back $pkg (version $svc) to $scp" >> "$REVERT_DIR/moved"
            cmd package compile -m speed-profile -f "$pkg" > /dev/null 2>&1
            ;;
    esac
done

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
# Phase 3: Compression switch and the per-app exception list
#
# The switch is the KernelSU module f2fs_compress: compression is on only
# while it is installed and enabled (no disable/remove marker). Without it,
# /data/app stays plain: compressed data reads 1.6-5x slower than plain on
# this hardware (2026-11-10, 16 KB clusters: plain 493, lz4 311, zstd 198
# MiB/s on a big core), and the space saved is about 0.6-0.9 GB.
# ---------------------------------------------------------------------
COMPRESS_MODULE="/data/adb/modules/f2fs_compress"
if [ -d "$COMPRESS_MODULE" ] && [ ! -f "$COMPRESS_MODULE/disable" ] &&
   [ ! -f "$COMPRESS_MODULE/remove" ]; then
    COMPRESS=on
else
    COMPRESS=off
fi

# Packages never compressed. In Download/ so it can be edited with a file
# manager; seeded once with the old built-in exceptions (Shizuku, Magisk).
NOCOMP_LIST="$LOG_DIR/non-compression.txt"
if [ ! -f "$NOCOMP_LIST" ]; then
    cat > "$NOCOMP_LIST" <<'EOF'
# Apps whose files in /data/app are never compressed by daily_clean.sh.
# Files of an app listed here that are already compressed are converted back
# to plain on the next daily run.
# One package name per line, e.g. com.google.android.gm; # starts a comment.
moe.shizuku.privileged.api
com.topjohnwu.magisk
EOF
    chown "$(stat -c %u:%g "$LOG_DIR")" "$NOCOMP_LIST" 2>/dev/null
    chmod 664 "$NOCOMP_LIST"
fi
NOCOMP=" $(sed 's/#.*//' "$NOCOMP_LIST" | tr -s ' \t\r' '\n' | grep -v '^$' | tr '\n' ' ') "

# ---------------------------------------------------------------------
# Phase 4: Per-file workloop (compress_mode=user)
#
# Only APKs and extracted native libraries under /data/app. They are read-only
# and replaced whole on app updates, so release_cblocks is safe for them. After
# release_cblocks the kernel refuses writes to a file (EPERM; SIGBUS through a
# writable mapping), so files apps write -- anything under Android/data --
# must never be released. chattr -p 0 is not used either: /data/media relies
# on project IDs for per-app storage accounting.
#
# Each file is brought to its wanted state:
#   - plain (switch off, or the app is in non-compression.txt): a file with
#     the compression flag is re-created without it;
#   - lz4 (switch on): a flagged lz4 file is compressed in place; a file that
#     is unflagged, or flagged with another algorithm (zstd from older
#     builds), is re-created as lz4 and compressed.
# The kernel only sets or clears the compression flag on a file with no data
# (fs/f2fs/file.c: EINVAL if F2FS_HAS_BLOCKS), and a file keeps the algorithm
# it was flagged with, so changing either means re-creating the file: copy
# into a fresh file, then rename it over the original. Running processes keep
# the old inode until they close it, so no app has to be stopped. The copy
# keeps the original mode, owner and mtime (an mtime change makes
# PackageManager treat the apk as modified) and gets its label back.
# A flagged file takes the mount's algorithm and level (lz4:9 = lz4hc 9);
# set_coption makes it lz4 even while /data is still mounted with zstd.
#
# Requires the kernel fix "f2fs: redirty_blocks: use read_mapping_page() on
# 4.14" (sunfish) or the msm-4.9 compression port "f2fs: port data
# compression (compress_mode=user) to 4.9" (crosshatch) -- with a NULL
# read_cache_page() filler F2FS_IOC_COMPRESS_FILE panics under CFI.
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
# Per-file lines for the log, written by the pipeline subshell below
NAMES="/data/local/tmp/.f2fs_names"
# Files released without gain earlier: compress refuses them with EINVAL every
# run and nothing tells them apart from untouched files, so they are listed
# here and skipped. Rewritten each run with only the paths still present (an
# app update gets a new /data/app path and is tried again).
SKIP_LIST="/data/adb/f2fs_compress_skip.list"

# New files inherit the directory flag: set it while compression is on, clear
# it while off (on /data/app and every app directory, so new installs and
# libraries extracted later are written fully plain).
if [ "$COMPRESS" = on ]; then
    "$F2FS_IO" setflags compression "$MANAGED_DIR" > /dev/null 2>> "$LOG_FILE"
else
    find "$MANAGED_DIR" -xdev -type d | while IFS= read -r d; do
        "$F2FS_IO" getflags "$d" 2>/dev/null | grep -qw compression &&
            "$F2FS_IO" clearflags compression "$d" > /dev/null 2>> "$LOG_FILE"
    done
fi

rm -f "$TALLY" "$NAMES"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR/einval"
: > "$TMP_DIR/skip.new"
[ -f "$SKIP_LIST" ] || : > "$SKIP_LIST"
echo "[INFO] Compression $COMPRESS; scanning $MANAGED_DIR..." >> "$LOG_FILE"

# /data/app/~~<rand>==/<pkg>-<rand>==/lib/arm64/x.so -> <pkg>/lib/arm64/x.so
# (package names never contain '-'; the random suffix may)
short_name() {
    s=${1#"$MANAGED_DIR"/}
    case "$s" in "~~"*/*) s=${s#*/} ;; esac
    p=${s%%/*}
    echo "${p%%-*}/${s#*/}"
}

# Log line for one compressed file: name and space released ($4: extra text)
note_file() {
    k=$(( $2 * 4 ))
    if [ "$k" -ge 1024 ]; then sz="$((k / 1024)) MiB"; else sz="$k KiB"; fi
    echo "  $3 $(short_name "$1") ($sz${4:+, $4})" >> "$NAMES"
}

# Uptime in milliseconds. Android's date has no %N and sh arithmetic is
# 32-bit, so read /proc/uptime with awk.
now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

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

# Free space a re-create must leave on /data, in KiB (1 GiB). A re-create
# writes the whole file uncompressed before the original goes away, and
# converting back to plain grows /data for good (~0.9 GB for all apps), so on
# a nearly full phone files are skipped -- counted, retried the next run --
# instead of filling /data.
FREE_RESERVE_KB=1048576

# Re-create $1 as plain ($2 = plain) or lz4-compressed ($2 = lz4) and rename
# it over the original; prints the released block count (0 for plain).
recreate() {
    # df -P: 1024-byte blocks, available in column 4
    free_kb=$(df -P /data 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
    need_kb=$(( $(stat -c %s "$1") / 1024 + FREE_RESERVE_KB ))
    if [ "$free_kb" -lt "$need_kb" ]; then
        echo x >> "$TMP_DIR/n_lowspace"
        return 1
    fi
    tmp_file="$TMP_DIR/$(basename "$1").tmp"
    rm -f "$tmp_file"; touch "$tmp_file"
    if [ "$2" = lz4 ]; then
        if ! "$F2FS_IO" setflags compression "$tmp_file" > /dev/null 2>> "$LOG_FILE" ||
           ! "$F2FS_IO" set_coption 1 2 "$tmp_file" > /dev/null 2>> "$LOG_FILE"; then
            rm -f "$tmp_file"; return 1
        fi
    fi
    cat "$1" > "$tmp_file" 2>> "$LOG_FILE" || { rm -f "$tmp_file"; return 1; }
    n=0
    if [ "$2" = lz4 ]; then
        n=$(compress_release "$tmp_file") || { rm -f "$tmp_file"; return 1; }
    fi
    # %a = octal permissions, %u = owner UID, %g = owner GID
    chmod "$(stat -c %a "$1")" "$tmp_file" &&
    chown "$(stat -c %u "$1"):$(stat -c %g "$1")" "$tmp_file" &&
    touch -r "$1" "$tmp_file" &&
    mv -f "$tmp_file" "$1" 2>> "$LOG_FILE" || {
        echo "Failed to swap re-created file into place: $(short_name "$1")" >> "$LOG_FILE"
        rm -f "$tmp_file"; return 1
    }
    # restorecon reports the file_contexts it loaded on stderr: keep the log clean
    restorecon "$1" > /dev/null 2>&1 ||
        echo "restorecon failed: $(short_name "$1")" >> "$LOG_FILE"
    echo "$n"
}

find "$MANAGED_DIR" -xdev -type f \( -name '*.so' -o -name '*.apk' \) -size +15k | while IFS= read -r file; do

    name=$(short_name "$file")
    want=lz4
    [ "$COMPRESS" = on ] || want=plain
    case "$NOCOMP" in *" ${name%%/*} "*) want=plain ;; esac

    flagged=no; extra=
    "$F2FS_IO" getflags "$file" 2>/dev/null | grep -qw compression && flagged=yes

    if [ "$want" = plain ]; then
        [ "$flagged" = yes ] || continue
        if recreate "$file" plain > /dev/null; then
            echo x >> "$TMP_DIR/n_plain"
            echo "  to plain $name" >> "$NAMES"
        fi
        usleep 200000 2>/dev/null || sleep 1
        continue
    fi

    if [ "$flagged" = yes ]; then
        alg=$("$F2FS_IO" get_coption "$file" 2>/dev/null | sed -n 's/.*algorithm:\([0-9]*\).*/\1/p')
    fi
    if [ "$flagged" = yes ] && [ "$alg" = 1 ]; then
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
                    echo x >> "$TMP_DIR/n_recompressed"
                    note_file "$file" "$released" recompressed
                    c_count=0; r_total=0
                    [ -f "$TALLY" ] && read -r c_count r_total < "$TALLY"
                    echo "$((c_count + 1)) $((r_total + released))" > "$TALLY"
                    continue
                fi
                echo x >> "$TMP_DIR/einval"
                echo "$file" >> "$TMP_DIR/skip.new"
                echo "  no gain, skip-listed $name" >> "$NAMES"
            else
                # Anything else (EBUSY, EOPNOTSUPP, ...) is logged and retried
                # next run, never skip-listed.
                echo "Compress failed: $name: $(cat "$TMP_DIR/err")" >> "$LOG_FILE"
            fi
            continue
        fi
        echo x >> "$TMP_DIR/n_inplace"
        mode="in place"
    else
        # Unflagged, or flagged with another algorithm (zstd): re-create as lz4.
        # A zstd -> lz4 conversion is timed (copy + compress + release + swap,
        # not the pause between files): per file in its log line, in total in
        # the summary.
        t0=$(now_ms)
        released=$(recreate "$file" lz4) || continue
        if [ "$flagged" = yes ]; then
            ms=$(( $(now_ms) - t0 ))
            echo "$ms $(stat -c %s "$file")" >> "$TMP_DIR/conv_time"
            echo x >> "$TMP_DIR/n_converted"; mode="converted to lz4"
            extra=$(awk -v m="$ms" 'BEGIN { printf "%.1f s", m / 1000 }')
        else
            echo x >> "$TMP_DIR/n_copied"; mode=copied
        fi
    fi

    if [ "$released" -gt 0 ]; then
        note_file "$file" "$released" "$mode" "$extra"
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
n_inplace=0; n_copied=0; n_recompressed=0; n_converted=0; n_plain=0
[ -f "$TMP_DIR/n_inplace" ] && n_inplace=$(wc -l < "$TMP_DIR/n_inplace")
[ -f "$TMP_DIR/n_copied" ] && n_copied=$(wc -l < "$TMP_DIR/n_copied")
[ -f "$TMP_DIR/n_recompressed" ] && n_recompressed=$(wc -l < "$TMP_DIR/n_recompressed")
[ -f "$TMP_DIR/n_converted" ] && n_converted=$(wc -l < "$TMP_DIR/n_converted")
[ -f "$TMP_DIR/n_plain" ] && n_plain=$(wc -l < "$TMP_DIR/n_plain")
n_lowspace=0
[ -f "$TMP_DIR/n_lowspace" ] && n_lowspace=$(wc -l < "$TMP_DIR/n_lowspace")
# zstd -> lz4: total time and size of the files converted this run
conv_time="none"
[ -s "$TMP_DIR/conv_time" ] && conv_time=$(awk '{ ms += $1; b += $2; n++ }
    END { printf "%dm %.1fs for %d files, %d MiB (%.1f MiB/s)", ms / 60000,
        (ms % 60000) / 1000, n, b / 1048576, ms ? b / 1048576 / (ms / 1000) : 0 }' \
    "$TMP_DIR/conv_time")
mv -f "$TMP_DIR/skip.new" "$SKIP_LIST"
rm -rf "$TMP_DIR"
sync

# Synchronize metrics back from the pipeline subshell
compressed_count=0; released_blocks_total=0
if [ -f "$TALLY" ]; then
    read -r compressed_count released_blocks_total < "$TALLY"
    rm -f "$TALLY"
fi

ELAPSED_TOTAL=$(( $(date +%s) - START_TIME ))
{
    echo "[SUCCESS] F2FS optimization cycle finalized."
    echo ">> Compression: $COMPRESS (KernelSU module f2fs_compress); /data mounted with $(grep -o 'compress_algorithm=[^,]*' /proc/mounts | head -n 1)"
    echo ">> Files Compressed This Run: $compressed_count (in place $n_inplace, copied $n_copied, converted to lz4 $n_converted, recompressed $n_recompressed)"
    echo ">> zstd -> lz4 Conversion Time: $conv_time"
    echo ">> Converted Back to Plain: $n_plain"
    [ "$n_lowspace" -gt 0 ] &&
        echo ">> Skipped, Low Free Space: $n_lowspace files (need file size + 1 GiB free on /data; retried next run)"
    echo ">> Released Earlier Without Gain: $skip_listed on the skip list ($skipped_einval new)"
    echo ">> Reclaimed Storage Blocks: $released_blocks_total"
    echo ">> Estimated Space Savings: $((released_blocks_total * 4 / 1024)) MiB"
    echo ">> Moved Back to ROM Copy: $reverted_count"
    cat "$REVERT_DIR/moved"
    echo ">> Execution Time: $((ELAPSED_TOTAL / 60))m $((ELAPSED_TOTAL % 60))s"
    [ -f "$NAMES" ] && cat "$NAMES"
    echo "--------------------------------------------------------"
} | tee -a "$LOG_FILE"
rm -rf "$REVERT_DIR"

# The log is written as root straight to /data/media, past the FUSE layer, so
# MediaStore (USB/MTP, file managers) keeps the old size until it is rescanned.
am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file:///storage/emulated/0/${LOG_FILE#/data/media/0/}" >/dev/null 2>&1
