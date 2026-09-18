#
# Copyright (C) 2020-2021 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Evolution's BuildFingerprint override (vendor/lineage/config/evolution.mk)
# stays ON. It replaces the fingerprint with google/mustang_beta/mustang:CANARY/
# on every device that is not a currently-supported Pixel, "to fix RCS/Wallet".
#
# It was disabled here for a while, on the theory that a CANARY build is a beta
# and therefore never Play-certified, so the device could not sign in. That was
# wrong: Play sign-in does not depend on certification at all. Setting up with
# wifi off and then signing in from inside the Play Store works on an
# explicitly uncertified device -- verified on lopro's build, which carries this
# same CANARY fingerprint, was never registered, reports "device is not
# certified", and signs in fine. The certified A13 sunfish fingerprint bought
# nothing, while RCS and Wallet stopped working.
#
# If this ever needs revisiting, the fix is a certified STABLE Pixel fingerprint
# in evolution.mk, not a device-tree one: TARGET_ENABLE_FP_OVERRIDE would have
# to be set BEFORE the inherit below, since evolution.mk reads it with ?= and
# evaluates its ifeq immediately.
# See ~/playstore-certified-scope.md.

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Inherit device configuration
$(call inherit-product, device/google/sunfish/aosp_sunfish.mk)

include device/google/sunfish/device-lineage.mk

# Device identifier. This must come after all inclusions
PRODUCT_BRAND := google
PRODUCT_MODEL := Pixel 4a
PRODUCT_NAME := lineage_sunfish

# adb root: vendor/lineage/config/common.mk sets
# PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG := true, which makes userdebug builds
# ro.debuggable=0 and builds user sepolicy (no su domain), so adbd refuses root.
# This product makefile is the top of the inheritance graph, so its value wins.
PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG := false
PRODUCT_COPY_FILES += \
    device/google/sunfish/init.adb-root.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/init.adb-root.rc

# Boot animation
TARGET_SCREEN_HEIGHT := 2340
TARGET_SCREEN_WIDTH := 1080

PRODUCT_BUILD_PROP_OVERRIDES += \
    BuildDesc="sunfish-user 13 TQ3A.230805.001.S1 10786265 release-keys" \
    BuildFingerprint=google/sunfish/sunfish:13/TQ3A.230805.001.S1/10786265:user/release-keys \
    DeviceProduct=sunfish

ifeq ($(WITH_GMS),false)
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/apex/com.google.android.permission.apex
else
# Flags, stated explicitly rather than left to defaults, so a file-level diff
# against another sunfish tree shows what this build actually chose. Each of
# these matches the default it would otherwise take, except the GApps variant:
#   EVO_BUILD_TYPE          vendor/lineage/config/version.mk defaults Unofficial
#   WITH_GMS                common_full_phone.mk defaults true
#   TARGET_USES_PICO_GAPPS  unset means false; stated so the mini/pico/full
#                           selection in common_full_phone.mk reads unambiguously
#   TARGET_DISABLE_EPPE     false keeps enforce-product-packages-exist, i.e. a
#                           missing requested package stays a build error
# (lopro's tree also sets BUILD_BCR, TARGET_HAS_UDFPS and TARGET_INCLUDE_ACCORD,
# which nothing in this vendor tree reads -- omitted rather than carried as
# no-ops.)
EVO_BUILD_TYPE := Unofficial
WITH_GMS := true
TARGET_USES_PICO_GAPPS := false
TARGET_DISABLE_EPPE := false

# Gapps: full, not mini. lopro's build signs in to Play on a freshly formatted,
# unregistered, explicitly uncertified device, and ours does not; after diffing
# the two device trees file by file, the GApps variant is the only difference
# left that could plausibly matter. Full adds 34 packages over mini (Photos,
# Recorder, SafetyHub, Tycho, GooglePackageInstaller, DevicePolicy, Gemini...).
# It does NOT add Gmail/Maps/Messages, so the prebuilts in extra-apps for those
# are not duplicated by it.
TARGET_USES_MINI_GAPPS := false

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/app/GoogleExtShared/GoogleExtShared.apk \
    system/app/GooglePrintRecommendationService/GooglePrintRecommendationService.apk \
    system/apex/com.google.android.permission.apex \
    system/etc/permissions/privapp-permissions-google.xml \
    system/etc/permissions/privapp_allowlist_com.google.android.ext.services.xml \
    system/priv-app/GoogleExtServices/GoogleExtServices.apk \
    system/priv-app/DocumentsUIGoogle/DocumentsUIGoogle.apk \
    system/priv-app/TagGoogle/TagGoogle.apk
endif

$(call inherit-product, vendor/google/sunfish/sunfish-vendor.mk)
