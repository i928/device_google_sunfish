#!/system/bin/sh
# ReVanced YouTube: move "Spoof video streams" off the visionOS client.
#
# visionOS (VISIONOS_1_02) no longer plays reliably; ANDROID_VR_1_43_32 does.
# ReVanced stores a setting only while it differs from the patch's default and
# deletes it otherwise, and on the current builds visionOS is the default: a
# phone that never touched the setting has no key at all and plays through
# visionOS. So, once per phone (marker below):
#   - key missing (default, visionOS)   -> write ANDROID_VR_1_43_32
#   - key set to VISIONOS_1_02          -> rewrite it to ANDROID_VR_1_43_32
#   - key set to any other client       -> the user's choice, left alone
# Once decided it never runs again, so picking visionOS again later sticks.
# Delete the marker to run it once more.
#
# Seeded into /data/adb/boot-completed.d by init.data-adb-seed.rc; KernelSU runs
# it as root after boot completes.
PKG=app.revanced.android.youtube
PREFS=/data/data/$PKG/shared_prefs/revanced_prefs.xml
KEY=revanced_spoof_video_streams_client_type
OLD=VISIONOS_1_02
NEW=ANDROID_VR_1_43_32
MARK=/data/adb/.revanced_yt_client.done
LOG=/data/adb/revanced_yt_client.log

[ -f "$MARK" ] && exit 0
# Not installed, or never opened: nothing to decide yet; try again next boot.
grep -q '</map>' "$PREFS" 2>/dev/null || exit 0

if grep -q "<string name=\"$KEY\">$OLD</string>" "$PREFS"; then
	expr="s|<string name=\"$KEY\">$OLD</string>|<string name=\"$KEY\">$NEW</string>|"
	was=$OLD
elif ! grep -q "<string name=\"$KEY\">" "$PREFS"; then
	expr="s|</map>|    <string name=\"$KEY\">$NEW</string>\n</map>|"
	was="default ($OLD)"
else
	echo "$(date '+%F %T') $KEY is $(sed -n "s|.*<string name=\"$KEY\">\([^<]*\)<.*|\1|p" "$PREFS"): user's choice, kept" >> "$LOG"
	: > "$MARK"
	exit 0
fi

# YouTube rewrites the whole file from memory on its next commit, so it must
# not be running while the file changes.
am force-stop "$PKG"
tmp=/data/adb/.revanced_prefs.$$
sed "$expr" "$PREFS" > "$tmp" &&
	grep -q "<string name=\"$KEY\">$NEW</string>" "$tmp" &&
	# Write through the existing file: keeps its owner, mode and SELinux label.
	cat "$tmp" > "$PREFS" &&
	rm -f "/data/data/$PKG/shared_prefs/revanced_prefs.xml.bak" &&
	echo "$(date '+%F %T') $KEY $was -> $NEW" >> "$LOG" &&
	: > "$MARK"
rm -f "$tmp"
