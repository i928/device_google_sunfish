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

# Earlier builds of this ROM dropped copies of this script into KernelSU's
# script directories. This ksud runs neither of them, and init runs this one as
# a service now, so remove them rather than leave misleading files behind.
rm -f /data/adb/boot-completed.d/ksu-autoinstall.sh /data/adb/service.d/ksu-autoinstall.sh

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

# `ksud module install` refuses with "Android is Booting!" until boot completes.
# KernelSU runs this from boot-completed.d, so the prop is normally already set;
# wait anyway, cheaply, in case the stage ever changes.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 60 ]; do
	sleep 2
	i=$((i + 1))
done

mkdir -p "$STATE" || exit 0

# Optional: pre-grant root to the apps in a snapshot of KernelSU's allowlist,
# so a wiped device does not need the grant tapped in by hand. The file is the
# ROM's own snapshot of /data/adb/ksu/.allowlist (magic "USK", per-uid entries);
# ship it only in builds where that is wanted -- it grants root to whatever is
# in it, com.android.shell included, which means anyone with adb access.
#
# Seeded only when nothing has been granted yet, so a later grant made through
# the manager is never clobbered. ksud reads the allowlist at startup, so this
# takes effect on the next boot -- which is the boot this script triggers
# anyway after installing modules.
SEED_ALLOWLIST="$SRC/shell-root.allowlist"
if [ -f "$SEED_ALLOWLIST" ] && [ ! -f "$STATE/allowlist.done" ]; then
	if ! grep -qa "com.android.shell" /data/adb/ksu/.allowlist 2>/dev/null; then
		mkdir -p /data/adb/ksu
		if cp "$SEED_ALLOWLIST" /data/adb/ksu/.allowlist &&
			chmod 644 /data/adb/ksu/.allowlist; then
			: > "$STATE/allowlist.done"
			echo "$(date) seeded KSU allowlist from $SEED_ALLOWLIST" >> "$LOG"
		else
			echo "$(date) FAILED to seed KSU allowlist" >> "$LOG"
		fi
	else
		# Already granted: leave it alone and stop reconsidering it.
		: > "$STATE/allowlist.done"
	fi
fi

installed=0
# Several passes: installing a metamodule (Hybrid-Mount) resets sys.boot_completed
# to 0, so every install queued behind it fails with "Android is Booting!" until
# the prop comes back. Filename order puts the metamodule last (30-), and these
# passes recover anything that still lost the race.
pass_no=1
while [ "$pass_no" -le 3 ]; do
	pending=0
	for zip in "$SRC"/*.zip; do
		[ -f "$zip" ] || continue
		name=${zip##*/}
		[ -f "$STATE/$name.done" ] && continue

		# The prop may have been reset by a metamodule install in this pass.
		i=0
		while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 30 ]; do
			sleep 2
			i=$((i + 1))
		done

		echo "$(date) installing $name (pass $pass_no)" >> "$LOG"
		if "$KSUD" module install "$zip" >> "$LOG" 2>&1; then
			: > "$STATE/$name.done"
			installed=$((installed + 1))
			echo "$(date) installed $name" >> "$LOG"
		else
			# No marker: retried in the next pass, then on the next boot.
			echo "$(date) FAILED $name (pass $pass_no)" >> "$LOG"
			pending=$((pending + 1))
		fi
	done
	[ "$pending" -eq 0 ] && break
	pass_no=$((pass_no + 1))
done

# Boot scripts shipped alongside the zips. They are not modules and not
# installed anywhere: /data/adb/service.d is never run by this ksud, so they are
# executed from here, detached, on every boot -- which is what they expect
# anyway (ksu_script.sh sleeps, then bind-mounts over /product/app once the
# framework is up).
for src in "$SRC"/scripts/*.sh; do
	[ -f "$src" ] || continue
	echo "$(date) running boot script ${src##*/}" >> "$LOG"
	if command -v setsid >/dev/null 2>&1; then
		setsid sh "$src" </dev/null >>"$LOG" 2>&1 &
	else
		sh "$src" </dev/null >>"$LOG" 2>&1 &
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
