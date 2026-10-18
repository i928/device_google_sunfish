#!/system/bin/sh
# ReVanced YouTube and YouTube Music: move "Spoof video streams" off the
# visionOS client.
#
# visionOS (VISIONOS_1_02) no longer plays reliably; ANDROID_VR_1_43_32 does.
# ReVanced stores a setting only while it differs from the patch's default and
# deletes it otherwise; on current YouTube builds visionOS is the default (no
# key at all), YouTube Music stores it explicitly. So, once per app (marker):
#   - key missing (default, visionOS)   -> write ANDROID_VR_1_43_32
#   - key set to VISIONOS_1_02          -> rewrite it to ANDROID_VR_1_43_32
#   - key set to any other client       -> the user's choice, left alone
# Once decided it never runs again for that app, so picking visionOS again
# later sticks. Delete the marker to run it once more.
#
# Seeded into /data/adb/boot-completed.d by init.data-adb-seed.rc; KernelSU runs
# it as root after boot completes.
KEY=revanced_spoof_video_streams_client_type
OLD=VISIONOS_1_02
NEW=ANDROID_VR_1_43_32
LOG=/data/adb/revanced_yt_client.log

# migrate <package> <marker>
migrate() {
	PKG=$1
	MARK=$2
	PREFS=/data/data/$PKG/shared_prefs/revanced_prefs.xml
	[ -f "$MARK" ] && return
	# Not installed, or never opened: nothing to decide yet; try again next boot.
	grep -q '</map>' "$PREFS" 2>/dev/null || return

	if grep -q "<string name=\"$KEY\">$OLD</string>" "$PREFS"; then
		expr="s|<string name=\"$KEY\">$OLD</string>|<string name=\"$KEY\">$NEW</string>|"
		was=$OLD
	elif ! grep -q "<string name=\"$KEY\">" "$PREFS"; then
		expr="s|</map>|    <string name=\"$KEY\">$NEW</string>\n</map>|"
		was="default ($OLD)"
	else
		echo "$(date '+%F %T') $PKG: $KEY is $(sed -n "s|.*<string name=\"$KEY\">\([^<]*\)<.*|\1|p" "$PREFS"): user's choice, kept" >> "$LOG"
		: > "$MARK"
		return
	fi

	# The app rewrites the whole file from memory on its next commit, so it
	# must not be running while the file changes.
	am force-stop "$PKG"
	tmp=/data/adb/.revanced_prefs.$$
	sed "$expr" "$PREFS" > "$tmp" &&
		grep -q "<string name=\"$KEY\">$NEW</string>" "$tmp" &&
		# Write through the existing file: keeps its owner, mode and SELinux label.
		cat "$tmp" > "$PREFS" &&
		rm -f "$PREFS.bak" &&
		echo "$(date '+%F %T') $PKG: $KEY $was -> $NEW" >> "$LOG" &&
		: > "$MARK"
	rm -f "$tmp"
}

[ -f /data/adb/.revanced_yt_client.done ] && [ -f /data/adb/.revanced_ytmusic_client.done ] && exit 0

# boot-completed.d runs as soon as sys.boot_completed=1, while user 0 is still
# RUNNING_LOCKED: app data under /data/data is credential-encrypted until the
# user unlocks (immediately on a phone without a lock screen, later with one).
# So continue detached and wait for the unlock (up to 30 min; else next boot).
(
i=0
until [ "$(getprop sys.user.0.ce_available)" = true ] || [ "$i" -ge 360 ]; do
	sleep 5
	i=$((i + 1))
done
migrate app.revanced.android.youtube /data/adb/.revanced_yt_client.done
migrate app.revanced.android.apps.youtube.music /data/adb/.revanced_ytmusic_client.done
) </dev/null >/dev/null 2>&1 &
