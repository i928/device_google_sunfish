#!/system/bin/sh
# Release builds in transition (SUNFISH_RELEASE_TRANSITION=1, device.mk) still
# bake extra apps that release.txt leaves out, so phones updated over the air
# keep them with their data. ro.sunfish.release_hidden_apps names them; on the
# first boot after a wipe -- the device not yet provisioned -- uninstall them
# for user 0, so a new install starts without them. The apks stay in /product
# (`pm install-existing <package>` brings one back).
#
# Decided once per /data: a phone that is already set up only records that and
# keeps everything. Personal builds have no such property, so this does nothing.
#
# Seeded into /data/adb/boot-completed.d by init.data-adb-seed.rc; KernelSU runs
# it as root after boot completes, while setup wizard is still showing.
LIST=$(getprop ro.sunfish.release_hidden_apps)
[ -n "$LIST" ] || exit 0
MARK=/data/adb/.release_hide_apps.done
LOG=/data/adb/release_hide_apps.log
log() {
	echo "$(date '+%F %T') $*" >> "$LOG"
}

# Our own baked manager (KernelSUNext, package dev.i928.mgr) cannot manage
# KernelSU in a release build: the kernel trusts only the official manager,
# which install-apps.sh installs as a user app. So once the official one is
# there, hide ours for user 0 on phones that are already set up too (once,
# own marker; only its own settings go, root grants and modules live in
# /data/adb). install-apps.sh runs in the same boot after setup, so wait for it,
# detached, up to 10 minutes; otherwise the next boot tries again.
MGR_MARK=/data/adb/.release_hide_mgr.done
case ",$LIST," in
*,KernelSUNext,*)
	if [ ! -f "$MGR_MARK" ]; then
		(
		i=0
		until pm path com.rifsxd.ksunext >/dev/null 2>&1 || [ "$i" -ge 120 ]; do
			sleep 5
			i=$((i + 1))
		done
		if pm path com.rifsxd.ksunext >/dev/null 2>&1; then
			pm path dev.i928.mgr >/dev/null 2>&1 &&
				log "KernelSUNext (dev.i928.mgr), official manager installed: $(pm uninstall --user 0 dev.i928.mgr 2>&1)"
			: > "$MGR_MARK"
		fi
		) </dev/null >/dev/null 2>&1 &
	fi
	;;
esac

[ -f "$MARK" ] && exit 0

if [ "$(settings get global device_provisioned 2>/dev/null)" = "1" ]; then
	log "device already set up: keeping $LIST"
	: > "$MARK"
	exit 0
fi

# The package of /product/app/<name>: dumpsys lists each package as
# "Package [<package>]" followed by its codePath, and an updated system app's
# /product copy under "Hidden system packages" the same way (pm list -f would
# show only the /data/app update).
DUMP=/data/adb/.release_hide_apps.dump
dumpsys package packages > "$DUMP" 2>/dev/null
for name in $(echo "$LIST" | tr ',' ' '); do
	pkg=$(awk -v cp="codePath=/product/app/$name" '
		/^ *Package \[/ { cur = $0; sub(/.*\[/, "", cur); sub(/\].*/, "", cur) }
		$1 == cp { print cur; exit }' "$DUMP")
	if [ -z "$pkg" ]; then
		log "$name: not installed"
		continue
	fi
	log "$name ($pkg): $(pm uninstall --user 0 "$pkg" 2>&1)"
done
: > "$MARK"
rm -f "$DUMP"
