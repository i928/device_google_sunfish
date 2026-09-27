# KernelSU-Next on sunfish

This ROM can ship KernelSU-Next ready to use: the manager app and `ksud` in
`/product`, plus module zips that install themselves after a wipe. Everything
KernelSU-related here is optional. A tree without it still builds.

## Kernel and manager

The kernel (`kernel/google/msm-4.14`) carries KernelSU-Next as the
`KernelSU-Next` submodule, driver branch `legacy-susfs-v2-3.4` (KernelSU-Next
3.4, UAPI 4). The kernel, `ksud` and the manager must all be 3.4.

| Kernel branch | Manager it trusts |
|---|---|
| `pr-ksu` | the official KernelSU-Next manager (`com.rifsxd.ksunext`), installed normally |
| `pr-ksu-private` | our own build (`dev.i928.mgr`), baked into `/product/app/KernelSUNext` |

The only difference is `drivers/ksu_manager_cert.mk`, which pins the manager's
package name and signing certificate. Without the submodule checked out
(`git submodule update --init KernelSU-Next`), the kernel builds with no
KernelSU at all.

The ROM side:

- `ksud_prebuilt/libksud.so` is `ksud`, taken from the manager APK
  (`lib/arm64-v8a/libksud.so`). `ksud_prebuilt/libadbroot.so` comes from the
  same place. Both are copied to `/product/app/KernelSUNext/lib/arm64/`, because
  Android never extracts native libraries for an app in `/product`.
- The manager APK itself comes from `prebuilts/extra-apps` (see
  `~/extraAPKs/run.sh` and `publish.sh`).
- `SUNFISH_KSU=false` leaves out all of the KernelSU userspace: no manager, no
  `ksud`, no autoinstall. Pair it with a kernel built without KernelSU.

## Module autoinstall

`ksu-autoinstall/` is local content and is ignored by git. Only
`ksu-autoinstall/snapshot/make-snapshot.sh` is tracked. Create the rest
yourself:

```
ksu-autoinstall/
  NN-<name>.zip              module zips, installed once each, in filename order
  installed-in-snapshot/     zips already in the snapshot (not installed again)
  snapshot/
    make-snapshot.sh         tracked
    ksu-snapshot.tar.gz      made by make-snapshot.sh
  scripts/*.sh               boot scripts, run detached on every boot
  *.allowlist                optional: apps granted root on a wiped device
```

The numeric prefix sets the install order. The Zygisk implementation must come
before the modules that load through it, for example `10-ReZygisk-*.zip` before
`20-*.zip`. Renaming a zip installs it again.

KernelSU-Next 3.4 `ksud` does not mount module files itself. That needs a
metamodule (a module with `metamodule=1` in `module.prop`), for example
Hybrid-Mount. Without one, modules that overlay `/system`, `/vendor` or other
partitions do nothing.

Everything found there is copied into `/product/etc/ksu-autoinstall/`. All of it
is picked up with `$(wildcard)`, so adding a module needs no makefile edit.

### What happens on the phone

1. `init.ksu-autoinstall.rc` runs at post-fs-data on every boot. It copies
   `ksud` to `/data/adb/ksud` and runs `ksud install`, which unpacks busybox.
   It also unpacks the snapshot on the first boot after a wipe
   (`ksu-snapshot.sh`) and places `ksu-autoinstall.sh` in
   `/data/adb/service.d/` if it isn't there.
2. `ksu-autoinstall.sh` runs from ksud's `services` stage. It installs any zip
   not yet installed, then waits for setup wizard and reboots once so the
   modules become active.
3. On the next boot it restarts zygote once, then runs the setup Action of
   AlwaysStrong (`tricky_store`) and bindhosts. Both need network.

- **Log:** `/data/adb/ksu-autoinstall.log`
- **Turn the reboot off:** `setprop persist.sunfish.ksu_ai_reboot 0`
- **Rerun it in the same boot:** `rmdir /dev/.ksu-autoinstall.lock`
- **Pick up a newer script after an update:** delete
  `/data/adb/service.d/ksu-autoinstall.sh`. The ROM copy is only placed when
  the file is missing, so edits made on the phone survive.

### Snapshot (faster first boot)

Instead of installing zips on every wipe, the ROM can carry a finished install:

1. Put the zips in `ksu-autoinstall/`, build and flash, and let them install and
   reboot. Or install them with the manager.
2. Run `ksu-autoinstall/snapshot/make-snapshot.sh` with the phone on adb.
   Root is taken through `su`.
3. Move the zips into `ksu-autoinstall/installed-in-snapshot/` and rebuild.

Per-device state is not included: AlwaysStrong's hardware key and its
downloaded keybox are left out, and module Actions recreate them. Regenerate the
snapshot whenever a module is added or updated.

## Release builds

`SUNFISH_RELEASE=1` ships only what `release.txt` lists. Each entry matches as a
substring of a file name in `ksu-autoinstall/` and `prebuilts/extra-apps`.
Personal items are left out this way: `shell-root.allowlist`, which gives root
to anyone with adb, and `ksu_script.sh`.
