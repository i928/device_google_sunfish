#
# Copyright (C) 2020-2021 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Kernel
BOARD_KERNEL_IMAGE_NAME := Image.lz4
TARGET_COMPILE_WITH_MSM_KERNEL := true
TARGET_KERNEL_CONFIG := sunfish_defconfig
TARGET_KERNEL_SOURCE := kernel/google/msm-4.14

# Kernel Clang. Clang 20 (r547379) is the toolchain the official Evolution X
# sunfish OTA was built with ("Android (13290119, +pgo, +bolt, +lto, +mlgo,
# based on r547379) clang version 20.0.0"). Other choices, one line active:
#   (unset)  LineageOS default kernel Clang
#   clang 21 r574158, clang 22 r596125, clang 23 r614150
TARGET_KERNEL_CLANG_PATH := $(abspath prebuilts/clang/host/$(HOST_PREBUILT_TAG)/clang-r547379)
#TARGET_KERNEL_CLANG_PATH := $(abspath prebuilts/clang/host/$(HOST_PREBUILT_TAG)/clang-r574158)
#TARGET_KERNEL_CLANG_PATH := $(abspath prebuilts/clang/host/$(HOST_PREBUILT_TAG)/clang-r596125)
#TARGET_KERNEL_CLANG_PATH := $(abspath prebuilts/clang/host/$(HOST_PREBUILT_TAG)/clang-r614150)
TARGET_NEEDS_DTBOIMAGE := true

# Partitions
AB_OTA_PARTITIONS += \
    vendor
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs

# SELinux
BOARD_SEPOLICY_DIRS += device/google/sunfish/sepolicy-lineage/dynamic
BOARD_SEPOLICY_DIRS += device/google/sunfish/sepolicy-lineage/vendor
# prebuilts/extra-apps is untracked local content (see device.mk); skip its
# sepolicy when a freshly synced tree does not have it.
ifneq ($(wildcard device/google/sunfish/prebuilts/extra-apps/sepolicy/file_contexts),)
BOARD_SEPOLICY_DIRS += device/google/sunfish/prebuilts/extra-apps/sepolicy
endif

# Verified Boot
ifneq ($(WITH_AVB),true)
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
else
# Bootloader relocking against our own AVB key (yellow boot state).
# Uncomment the line at the bottom of this block to build a vbmeta the
# bootloader actually verifies.
#
#   --flags 3  hashtree (dm-verity) disabled + verification disabled  <- default, above
#   --flags 1  hashtree (dm-verity) disabled, verification ENABLED    <- what relocking needs
#
# WITH_AVB=true on its own is NOT enough, and is in fact worse than the
# default: with no --flags the vbmeta gets flags 0, meaning dm-verity is
# enabled -- while system/vendor/product are built --no_hashtree
# (BoardConfig-common.mk), so there is no hashtree to verify and the device
# does not boot.
#
# The key side is already wired up: AVB_CUSTOM_KEY_PATH/ALGORITHM come from
# vendor/evolution-priv/keys/keys.mk (avb.pk8, SHA256_RSA4096), and
# avb_custom_key.bin in that same repo is what gets flashed to the bootloader
# (fastboot flash avb_custom_key) before `fastboot flashing lock`.
#
# Trade-off before enabling: a locked bootloader refuses `fastboot boot`,
# which is how every test kernel is booted here -- each KSU kernel would have
# to be signed with this key and flashed to a slot instead. Recovery from a
# bad signed image also needs OEM unlocking to still be toggled on.
#
# Source of the flags value: lopro104/android_device_google_sunfish e4ab622.
#BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 1
endif

include vendor/google/sunfish/BoardConfigVendor.mk

# libksud.so is shipped via PRODUCT_COPY_FILES in device.mk (see comment
# there for why) -- this flag is what actually permits an ELF binary
# through that mechanism; it's board-scoped and silently ignored if set
# from a product .mk like device.mk instead.
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# PRODUCT_COPY_FILES's copy-one-file rule uses plain `cp` (no -p), which
# drops the source file's executable bit regardless of what it was, and the
# app execs this file directly as a subprocess. Force it via a separate
# stamp file (referencing $(PRODUCT_OUT) as a rule prerequisite from
# device.mk hits a "||PRODUCT-PATH-PH||" placeholder-substitution bug --
# PRODUCT_OUT isn't fully resolved yet at product-config-parse time;
# BoardConfigLineage.mk runs later and is fine).
# Same condition as the libksud.so PRODUCT_COPY_FILES in device.mk: without
# the app there is no copied file, so no rule may depend on it. When absent,
# libksud_chmod_stamp stays empty and the droidcore line below is a no-op.
ifneq ($(wildcard device/google/sunfish/prebuilts/extra-apps/prebuilt/KernelSUNext.apk),)
libksud_chmod_stamp := $(OUT_DIR)/libksud_chmod.stamp
$(libksud_chmod_stamp): $(PRODUCT_OUT)/$(TARGET_COPY_OUT_PRODUCT)/app/KernelSUNext/lib/arm64/libksud.so
	chmod 755 $<
	touch $@
endif
droidcore: $(libksud_chmod_stamp)
