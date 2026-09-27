#!/usr/bin/env python3
"""Turn a kernel build.config.sunfish_<variant> into a kconfig fragment.

The build.config.sunfish_* files in the kernel tree (kasan, debug_hang,
no-cfi, performance, ...) are written for Google's standalone kernel build
(build/build.sh): a POST_DEFCONFIG_CMDS function runs
    scripts/config --file .config -e X -d Y --set-val Z N
after defconfig. The ROM build (vendor/lineage/build/tasks/kernel.mk) never
reads them; it merges *.config fragments instead. This script extracts those
scripts/config options and writes the equivalent fragment.

Used by BoardConfigLineage.mk when SUNFISH_KERNEL_DEBUG=<variant> is set.
By hand:  buildconfig2frag.py <build.config file> <output .config>

Prints "ok <n> options" on success; anything else is an error message.
"""
import re
import sys


def convert(src):
    text = open(src).read()
    # Only the scripts/config invocations; join backslash continuations first.
    text = text.replace("\\\n", " ")
    opts = []
    for line in text.splitlines():
        if "scripts/config" not in line:
            continue
        toks = line.split()
        i = 0
        while i < len(toks):
            t = toks[i]
            if t in ("-e", "--enable", "-d", "--disable") and i + 1 < len(toks):
                sym = toks[i + 1]
                opts.append((sym, "y" if t in ("-e", "--enable") else "n"))
                i += 2
            elif t == "--set-val" and i + 2 < len(toks):
                opts.append((toks[i + 1], toks[i + 2]))
                i += 3
            else:
                i += 1
    out = []
    lto_off = False
    for sym, val in opts:
        name = sym if sym.startswith("CONFIG_") else "CONFIG_" + sym
        if val == "n":
            out.append("# %s is not set" % name)
            if name == "CONFIG_LTO_CLANG":
                lto_off = True
        else:
            out.append("%s=%s" % (name, val))
    # LTO_CLANG sits in a choice; disabling it needs the alternative selected,
    # or olddefconfig picks LTO_CLANG again as the choice default.
    if lto_off:
        out.append("CONFIG_LTO_NONE=y")
    return opts, out


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[0])
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    try:
        opts, lines = convert(src)
    except OSError as e:
        print("cannot read %s: %s" % (src, e.strerror))
        return 1
    if not opts:
        print("no scripts/config options found in %s" % src)
        return 1
    with open(dst, "w") as f:
        f.write("# Generated from %s by buildconfig2frag.py -- do not edit.\n" % src)
        f.write("\n".join(lines) + "\n")
    print("ok %d options" % len(opts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
