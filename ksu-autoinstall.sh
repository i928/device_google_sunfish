#!/system/bin/sh
#
# Install the KernelSU module zips that ship with the ROM, once each.
#
# The point is a wiped device: `fastboot -w` erases /data and /sdcard, so every
# module and every zip staged there is gone. Zips under /product survive, because
# they are part of the image, so a freshly wiped phone can set itself back up with
# no transfers at all.
#
# Each zip is installed at most once; the marker files live in /data/adb, so a
# later wipe deliberately makes them install again. Adding a new zip to the ROM
# installs only that one, since markers are per-file.

SRC=/product/etc/ksu-autoinstall
STATE=/data/adb/.ksu-autoinstall
KSUD=/data/adb/ksud
LOG=/data/adb/ksu-autoinstall.log

# Reboot once after installing, so the modules are actually active. Off by
# default: boot_completed can fire while the user is still in setup wizard, and a
# surprise reboot there is worse than one manual reboot.
#   setprop persist.sunfish.ksu_autoinstall.reboot 1   (persists across boots)
REBOOT=$(getprop persist.sunfish.ksu_autoinstall.reboot 0)

[ -d "$SRC" ] || exit 0
# KernelSU userspace not set up yet -- nothing we can do this boot; try the next.
[ -x "$KSUD" ] || exit 0

mkdir -p "$STATE" || exit 0

installed=0
for zip in "$SRC"/*.zip; do
	[ -f "$zip" ] || continue
	name=${zip##*/}
	[ -f "$STATE/$name.done" ] && continue

	echo "$(date) installing $name" >> "$LOG"
	if "$KSUD" module install "$zip" >> "$LOG" 2>&1; then
		: > "$STATE/$name.done"
		installed=$((installed + 1))
		echo "$(date) installed $name" >> "$LOG"
	else
		# No marker: a failure retries on the next boot rather than being
		# silently skipped forever.
		echo "$(date) FAILED $name" >> "$LOG"
	fi
done

[ "$installed" -gt 0 ] || exit 0
echo "$(date) $installed module(s) installed; reboot needed to activate" >> "$LOG"

[ "$REBOOT" = "1" ] || exit 0
# Guard against a reboot loop if a module somehow fails to mark itself done.
[ -f "$STATE/.rebooted" ] && exit 0
: > "$STATE/.rebooted"
sleep 5
setprop sys.powerctl reboot,ksu-autoinstall
