#!/system/bin/sh

# input_suspend semantics: 1 = stop charging, 0 = allow charging
CHARGING_SWITCH="/sys/class/power_supply/smb5/input_suspend"

# Emergency shutdown. svc starts a whole Java runtime (app_process) to ask the
# power service; on 2026-10-05 03:44 sunfish ran it at 19% in deep sleep with
# swap full, it silently did nothing, and the old "svc ...; exit 0" gave up for
# good -- the battery then ran flat (shutdown,battery at 05:53) and the empty
# phone stopped in the bootloader when charged. Now: hold a wake lock, try the
# graceful shutdown, and if the phone is still up a minute later fall back to
# reboot -p (init's own clean shutdown, no Java).
emergency_shutdown() {
    echo low_battery_shutdown > /sys/power/wake_lock 2>/dev/null
    # In the background: svc waits for the device to go off, and a hung svc
    # must not block the fallback.
    svc power shutdown &
    sleep 60
    reboot -p
    sleep 60
    echo low_battery_shutdown > /sys/power/wake_unlock 2>/dev/null
}

while true; do
    # Get current battery level and plugged-in status
    LEVEL=$(dumpsys battery | awk '$1=="level:"{print $2}')
    PLUGGED=$(dumpsys battery | grep -E "AC powered:|USB powered:|Wireless powered:" | grep -c "true")

    # 1. EMERGENCY SHUTDOWN BLOCK (Unplugged & under 20%)
    if [ "$LEVEL" -lt 20 ] && [ "$PLUGGED" -eq 0 ]; then
        emergency_shutdown
        # Still running: both attempts failed. Loop on and try again.
    fi

    # 2. CHARGE LIMITER BLOCK (When charger is plugged in)
    if [ "$PLUGGED" -gt 0 ]; then
        # If battery reaches 80% or more, stop charging
        if [ "$LEVEL" -ge 80 ]; then
            echo 1 > "$CHARGING_SWITCH"

        # If battery drops back down to 70% or lower, resume charging
        elif [ "$LEVEL" -le 70 ]; then
            echo 0 > "$CHARGING_SWITCH"
        fi
    else
        # Force-enable charging when unplugged so it charges normally next time you plug it in
        echo 0 > "$CHARGING_SWITCH"
    fi

    # Check state every 30 seconds
    sleep 30
done
