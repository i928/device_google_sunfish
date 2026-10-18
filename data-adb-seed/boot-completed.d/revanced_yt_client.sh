#!/system/bin/sh
# ReVanced YouTube: move "Spoof video streams" off the visionOS client.
#
# Older ReVanced builds set revanced_spoof_video_streams_client_type to
# VISIONOS_1_02, which no longer plays reliably; ANDROID_VR_1_43_32 does. The
# app keeps an explicit choice across its own updates, so phones set up before
# the change stay on visionOS until this rewrites it. Only that exact old value
# is changed: any other client the user picked is left alone, and once changed
# there is nothing left to do, so running on every boot is harmless.
#
# Seeded into /data/adb/boot-completed.d by init.data-adb-seed.rc; KernelSU runs
# it as root after boot completes.
PKG=app.revanced.android.youtube
PREFS=/data/data/$PKG/shared_prefs/revanced_prefs.xml
KEY=revanced_spoof_video_streams_client_type
OLD=VISIONOS_1_02
NEW=ANDROID_VR_1_43_32
LOG=/data/adb/revanced_yt_client.log

grep -q "<string name=\"$KEY\">$OLD</string>" "$PREFS" 2>/dev/null || exit 0

# YouTube rewrites the whole file from memory on its next commit, so it must
# not be running while the file changes.
am force-stop "$PKG"
tmp=/data/adb/.revanced_prefs.$$
sed "s|<string name=\"$KEY\">$OLD</string>|<string name=\"$KEY\">$NEW</string>|" "$PREFS" > "$tmp" &&
	grep -q "<string name=\"$KEY\">$NEW</string>" "$tmp" &&
	# Write through the existing file: keeps its owner, mode and SELinux label.
	cat "$tmp" > "$PREFS" &&
	rm -f "/data/data/$PKG/shared_prefs/revanced_prefs.xml.bak" &&
	echo "$(date '+%F %T') $KEY $OLD -> $NEW" >> "$LOG"
rm -f "$tmp"
