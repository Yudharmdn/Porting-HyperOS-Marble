#!/usr/bin/env python3
"""apk_bundle.py <src> <outdir> <name>

APK biasa          -> <outdir>/<name>.apk
bundle (.apkm/.apks/.xapk) -> base jadi <outdir>/<name>.apk, split (split_*.apk / config.*.apk) ikut
disalin apa adanya. Split wajib dipasang bersama base: mis. Chrome punya requiredSplitTypes
(split_chrome + split_on_demand), tanpa itu PackageManager menolak paketnya.
Cetak: "apk" | "bundle <jumlah split>" | "invalid"
"""
import os
import shutil
import sys
import zipfile


def main():
    src, out, name = sys.argv[1:4]
    try:
        z = zipfile.ZipFile(src)
    except Exception:
        print("invalid")
        return
    os.makedirs(out, exist_ok=True)
    names = z.namelist()
    if "AndroidManifest.xml" in names:
        shutil.copyfile(src, os.path.join(out, name + ".apk"))
        print("apk")
        return
    apks = [n for n in names if "/" not in n and n.endswith(".apk")]
    base = "base.apk" if "base.apk" in apks else next(
        (n for n in apks if not n.startswith(("split_", "config."))), None)
    if not base:
        print("invalid")
        return
    for n in apks:
        with open(os.path.join(out, name + ".apk" if n == base else n), "wb") as f:
            f.write(z.read(n))
    print("bundle %d" % (len(apks) - 1))


if __name__ == "__main__":
    main()
