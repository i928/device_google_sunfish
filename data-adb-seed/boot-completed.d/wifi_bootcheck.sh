#!/system/bin/sh

# Wi-Fi boot check (capture only, changes nothing).
#
# Sometimes, mostly after a flash, the Wi-Fi toggle is off after boot and one
# tap turns it back on. That is Android's start-failure path: when the primary
# client mode fails to start at boot (CMD_STA_START_FAILURE in ActiveModeWarden),
# WifiController drops to DisabledState without retrying, while the saved
# setting (wifi_on) stays 1. This records every boot in history.txt and, when
# Wi-Fi is disabled although wifi_on=1 and airplane mode is off, saves logcat,
# dmesg and the Wi-Fi state so the reason for the failed start can be read
# (look for "STA disabled, return to DisabledState" and the lines before it).
#
# Output: /data/local/tmp/wifi-bootcheck/ (history.txt + last 5 captures).

OUT=/data/local/tmp/wifi-bootcheck
KEEP=5

check() {
    # Let Wi-Fi finish starting; a slow (debug) kernel can take a while.
    sleep 45

    mkdir -p "$OUT"
    WIFI_ON=$(settings get global wifi_on)
    AIRPLANE=$(settings get global airplane_mode_on)
    STATUS=$(cmd wifi status 2>&1 | head -1)
    KERNEL=$(uname -v | cut -d' ' -f1)
    NOW=$(date +%Y%m%d-%H%M%S)

    if [ "$WIFI_ON" = 1 ] && [ "$AIRPLANE" != 1 ] && echo "$STATUS" | grep -q "disabled"; then
        D="$OUT/$NOW"
        mkdir -p "$D"
        logcat -d -b all > "$D/logcat.txt" 2>&1
        dmesg > "$D/dmesg.txt" 2>&1
        cmd wifi status > "$D/wifi-status.txt" 2>&1
        dumpsys wifi > "$D/dumpsys-wifi.txt" 2>&1
        echo "$NOW kernel=$KERNEL wifi_on=$WIFI_ON status=[$STATUS] -> CAPTURED $D" >> "$OUT/history.txt"
        # keep the newest $KEEP captures
        ls -1d "$OUT"/2* 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
            rm -rf "$old"
        done
    else
        echo "$NOW kernel=$KERNEL wifi_on=$WIFI_ON airplane=$AIRPLANE status=[$STATUS] ok" >> "$OUT/history.txt"
    fi
}

# Detached: never hold up the boot-completed stage.
check </dev/null >/dev/null 2>&1 &
