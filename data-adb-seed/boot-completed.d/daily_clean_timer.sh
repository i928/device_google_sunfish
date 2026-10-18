#!/system/bin/sh
#
# Starts /data/adb/daily_clean.sh every 10 minutes; the script itself decides
# whether today's run is due (once a day, 04:00-08:59).
#
# Run by ksud's boot-completed stage (as root, u:r:ksu:s0, detached from init).
# It replaces the daily_timer_daemon/daily_clean_job init services: init cannot
# start /system/bin/sh from a vendor rc without a domain transition, so those
# never ran ("File /system/bin/sh (labeled u:object_r:shell_exec:s0) has
# incorrect label or no domain transition from u:r:init:s0").
#
# A short, fixed interval instead of "sleep until HH:01": sleep counts only
# time the CPU is awake, so in deep sleep a long sleep wakes hours late (it
# missed the whole 04:00 hour on crosshatch). With 10-minute steps the run
# starts at the first wake-up after 04:00.

while true; do
    sh /data/adb/daily_clean.sh
    sleep 600
done
