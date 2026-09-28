#!/system/bin/sh
#
# Hourly trigger for /data/adb/daily_clean.sh, which itself only does work in
# the 04:00 hour.
#
# Run by ksud's boot-completed stage (as root, u:r:ksu:s0, detached from init).
# It replaces the daily_timer_daemon/daily_clean_job init services: init cannot
# start /system/bin/sh from a vendor rc without a domain transition, so those
# never ran ("File /system/bin/sh (labeled u:object_r:shell_exec:s0) has
# incorrect label or no domain transition from u:r:init:s0").
#
# Wakes one minute past each full hour, so the 04:00 hour is never skipped by
# drift, however long the previous run took.

while true; do
    now=$(date +%s)
    sleep $(( 3600 - now % 3600 + 60 ))
    sh /data/adb/daily_clean.sh
done
