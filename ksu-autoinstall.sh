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
#
# Install order is filename order, which is why the zips carry numeric prefixes:
# the Zygisk implementation (10-ReZygisk) has to be installed before the Zygisk
# modules that load through it (20-*). Renaming a zip makes it install again,
# since the marker is keyed on the filename.

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
		failed=$((failed + 1))
	fi
done

# ksud may refuse to run from the init domain (SELinux). KernelSU runs anything
# in boot-completed.d itself, in its own root context, so hand the work over
# there and let the next boot do it. /data/adb does not survive a wipe, which is
# why this is a fallback and not the primary path.
if [ "${failed:-0}" -gt 0 ] && [ "$installed" -eq 0 ]; then
	if [ -d /data/adb/boot-completed.d ] &&
		[ ! -f /data/adb/boot-completed.d/ksu-autoinstall.sh ]; then
		cp "$0" /data/adb/boot-completed.d/ksu-autoinstall.sh &&
			chmod 755 /data/adb/boot-completed.d/ksu-autoinstall.sh &&
			echo "$(date) installs failed from init; handed off to boot-completed.d" >> "$LOG"
	fi
fi

[ "$installed" -gt 0 ] || exit 0
echo "$(date) $installed module(s) installed; reboot needed to activate" >> "$LOG"

[ "$REBOOT" = "1" ] || exit 0
# Guard against a reboot loop if a module somehow fails to mark itself done.
[ -f "$STATE/.rebooted" ] && exit 0
: > "$STATE/.rebooted"
sleep 5
setprop sys.powerctl reboot,ksu-autoinstall
