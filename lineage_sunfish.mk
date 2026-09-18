#
# Copyright (C) 2020-2021 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Keep our own certified BuildFingerprint (set below) instead of the beta one.
# vendor/lineage/config/evolution.mk overrides BuildFingerprint with
# google/mustang_beta/mustang:CANARY/... for every device that is not a
# currently-supported Pixel, to fix RCS/Wallet. A CANARY build is a beta and is
# not in Google's certified set, so GMS registers the device as uncertified at
# first boot and refuses the Google sign-in during setup.
#
# This MUST be set before the inherit below: evolution.mk reads it with ?= and
# immediately evaluates the ifeq, so a later assignment has no effect.
#
# If RCS or Wallet regress because of this, do not revert -- instead give
# evolution.mk a certified STABLE Pixel fingerprint rather than a beta one.
# See ~/playstore-certified-scope.md.
TARGET_ENABLE_FP_OVERRIDE := false

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
# Gapps
TARGET_USES_MINI_GAPPS := true

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
