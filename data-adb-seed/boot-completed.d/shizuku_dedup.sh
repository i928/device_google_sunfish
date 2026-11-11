#!/system/bin/sh
#
# Leaves exactly one Shizuku server after boot.
#
# Shizuku's start-on-boot (root mode) handles both LOCKED_BOOT_COMPLETED and
# BOOT_COMPLETED, and the two can run its root starter at the same time: each
# finds no server yet and starts one. Both servers then hand their binder to
# every client, so a client's user service registers with the wrong one and
# times out ("Service record ... is not started in 30000 ms"): DevCheck's
# Shizuku features and File Manager+ fail (crosshatch, 2026-11-10). Running
# the starter once more fixes it: it stops every running server first.
# The same race can also leave NO server (each starter stops the other's), so
# a missing server is started too -- but only when Shizuku's start-on-boot
# is on (its BootCompleteReceiver enabled) and it was last started as root
# (settings "mode" 0); in ADB mode no root server is expected.
#
# Run by ksud's boot-completed stage (root, u:r:ksu:s0). Does nothing when
# Shizuku is not installed or only one server runs.

(
    # Shizuku's boot receiver runs a few seconds after BOOT_COMPLETED.
    sleep 90
    n=$(pidof shizuku_server | wc -w)
    [ "$n" -eq 1 ] && exit 0
    if [ "$n" -eq 0 ]; then
        cmd package query-receivers --components \
            -a android.intent.action.BOOT_COMPLETED 2>/dev/null |
            grep -q 'moe.shizuku.privileged.api/.*BootCompleteReceiver' || exit 0
        grep -q 'name="mode" value="0"' \
            /data/user_de/0/moe.shizuku.privileged.api/shared_prefs/settings.xml \
            2>/dev/null || exit 0
    fi
    apk=$(cmd package path moe.shizuku.privileged.api 2>/dev/null | sed -n '1s/^package://p')
    [ -n "$apk" ] || exit 0
    starter="${apk%/*}/lib/arm64/libshizuku.so"
    [ -x "$starter" ] || exit 0
    "$starter" > /dev/null 2>&1
    sleep 5
    log -t shizuku_dedup "$n shizuku_server processes after boot; started once, now: $(pidof shizuku_server)"
) < /dev/null > /dev/null 2>&1 &
