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
#
# Run by ksud's boot-completed stage (root, u:r:ksu:s0). Does nothing when
# Shizuku is not installed or only one server runs.

(
    # Shizuku's boot receiver runs a few seconds after BOOT_COMPLETED.
    sleep 90
    n=$(pidof shizuku_server | wc -w)
    [ "$n" -gt 1 ] || exit 0
    apk=$(cmd package path moe.shizuku.privileged.api 2>/dev/null | sed -n '1s/^package://p')
    [ -n "$apk" ] || exit 0
    starter="${apk%/*}/lib/arm64/libshizuku.so"
    [ -x "$starter" ] || exit 0
    "$starter" > /dev/null 2>&1
    sleep 5
    log -t shizuku_dedup "$n shizuku_server processes after boot; restarted, now: $(pidof shizuku_server)"
) < /dev/null > /dev/null 2>&1 &
