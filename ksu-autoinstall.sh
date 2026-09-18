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
#   setprop persist.sunfish.ksu_ai_reboot 1   (persists across boots)
# Name kept under 31 chars: the legacy property getter truncates longer names, so
# `getprop persist.sunfish.ksu_autoinstall.reboot` silently read nothing.
REBOOT=$(getprop persist.sunfish.ksu_ai_reboot 0)

[ -d "$SRC" ] || exit 0

# On a wiped device /data/adb/ksud does not exist: the manager app creates it on
# first launch by copying its own bundled libksud.so. Waiting for that would mean
# nothing installs until the user opens the manager and reboots, which defeats
# the point. Seed it from the same binary the manager would use -- it ships in
# this ROM, so it matches this kernel by construction.
if [ ! -x "$KSUD" ]; then
	SEED=/product/app/KernelSUNext/lib/arm64/libksud.so
	[ -f "$SEED" ] || exit 0
	cp "$SEED" "$KSUD" && chmod 755 "$KSUD" || exit 0
	echo "$(date) seeded ksud from $SEED" >> "$LOG"
fi

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

# Boot scripts shipped alongside the zips. These are not modules: they belong in
# /data/adb/service.d, which KernelSU runs on EVERY boot (late_start), so they
# are copied into place once and then run themselves from there. A wipe takes
# them with it, and this puts them back.
for src in "$SRC"/scripts/*.sh; do
	[ -f "$src" ] || continue
	name=${src##*/}
	[ -f "$STATE/script-$name.done" ] && continue

	mkdir -p /data/adb/service.d || continue
	if cp "$src" "/data/adb/service.d/$name" && chmod 755 "/data/adb/service.d/$name"; then
		: > "$STATE/script-$name.done"
		echo "$(date) installed boot script $name" >> "$LOG"
	else
		echo "$(date) FAILED to install boot script $name" >> "$LOG"
	fi
done

# Some modules only configure themselves when their Action is run -- AlwaysStrong
# fetches and refreshes the keybox and fingerprint that way. A module is only
# active after the reboot following its install, so this runs on a later boot,
# once the module directory exists and carries an action.sh.
for moddir in /data/adb/modules/*/; do
	[ -f "$moddir/action.sh" ] || continue
	[ -f "$moddir/disable" ] && continue
	[ -f "$moddir/remove" ] && continue
	id=${moddir%/}
	id=${id##*/}
	[ -f "$STATE/action-$id.done" ] && continue

	echo "$(date) running action for $id" >> "$LOG"
	if "$KSUD" module action "$id" >> "$LOG" 2>&1; then
		: > "$STATE/action-$id.done"
	else
		# No marker: AlwaysStrong's action needs network, so let it retry.
		echo "$(date) action FAILED for $id" >> "$LOG"
	fi
done

[ "$installed" -gt 0 ] || exit 0
echo "$(date) $installed module(s) installed; reboot needed to activate" >> "$LOG"

[ "$REBOOT" = "1" ] || exit 0
# Never reboot out from under setup wizard: boot_completed fires long before the
# user finishes it. Waiting costs nothing -- this runs again on the next boot.
[ "$(settings get secure user_setup_complete 2>/dev/null)" = "1" ] || exit 0
# Guard against a reboot loop if a module somehow fails to mark itself done.
[ -f "$STATE/.rebooted" ] && exit 0
: > "$STATE/.rebooted"
sleep 5
setprop sys.powerctl reboot,ksu-autoinstall
