#!/usr/bin/env python3
"""rom_branding.py - cari teks branding (mis. "by xiaomi.eu") di resource APK ROM, lalu buat
sumber overlay RRO (format apktool) yang menggantinya. APK asli tidak diubah (tanda tangan aman).

  rom_branding.py --root P_FS --needle xiaomi.eu --match '(?i)\\bby\\s+xiaomi\\.eu\\b'
                  --author Yudharn --out DIR

Stdout:
  HIT  <apk> <target-pkg> string/<nama> [<qualifier>] '<nilai>'   resource string yang mengandung needle
  SKIP ...                                                        cocok tapi config tidak didukung
  DEX  <apk/jar>                                                   needle ada di kode (tidak bisa lewat overlay)
  OVERLAY <target-pkg> <dir> <jumlah>                              sumber overlay siap dibangun apktool
  PATCH <apk>                                                      APK overlay yang memuat teks: dipatch langsung

  rom_branding.py --patch-decoded DIR --author Yudharn [--needle/--match]  -> "PATCHED <n>"
"""
import argparse
import os
import re
import struct
import zipfile
from xml.sax.saxutils import escape

DIRS = ("system/system", "system_ext", "product", "mi_ext")
NONE = 0xFFFFFFFF


# ---------------------------------------------------------------- string pool
def string_pool(buf, off):
    _t, hsize, _size, count, _style, flags, str_start, _ = struct.unpack_from("<HHIIIIII", buf, off)
    offs = struct.unpack_from("<%dI" % count, buf, off + hsize)
    base, utf8, out = off + str_start, bool(flags & 0x100), []
    for o in offs:
        p = base + o
        if utf8:
            p += 2 if buf[p] & 0x80 else 1
            ln = buf[p]; p += 1
            if ln & 0x80:
                ln = ((ln & 0x7F) << 8) | buf[p]; p += 1
            out.append(buf[p:p + ln].decode("utf-8", "replace"))
        else:
            ln = struct.unpack_from("<H", buf, p)[0]; p += 2
            if ln & 0x8000:
                ln = ((ln & 0x7FFF) << 16) | struct.unpack_from("<H", buf, p)[0]; p += 2
            out.append(buf[p:p + ln * 2].decode("utf-16-le", "replace"))
    return out


# ---------------------------------------------------------------- AXML (manifest)
def manifest_info(data):
    """-> (package, overlay targetPackage atau None)"""
    pkg = target = None
    strings = []
    pos = struct.unpack_from("<HHI", data, 0)[1]
    while pos + 8 <= len(data):
        ctype, _h, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == 0x0001:
            strings = string_pool(data, pos)
        elif ctype == 0x0102:
            name = strings[struct.unpack_from("<I", data, pos + 20)[0]]
            a_start, a_size, a_count = struct.unpack_from("<HHH", data, pos + 24)
            for i in range(a_count):
                b = pos + 16 + a_start + i * a_size
                _ns, an, raw = struct.unpack_from("<III", data, b)
                if raw == NONE:
                    continue
                key = strings[an] if an < len(strings) else ""
                if name == "manifest" and key == "package":
                    pkg = strings[raw]
                elif name == "overlay" and key == "targetPackage":
                    target = strings[raw]
        pos += csize
    return pkg, target


# ---------------------------------------------------------------- resources.arsc
def qualifier(cfg):
    """ResTable_config -> qualifier apktool ('' = default). None = dimensi yang tidak didukung."""
    c = cfg + bytes(64)
    mcc, mnc = struct.unpack_from("<HH", c, 4)
    lang, country = c[8:10], c[10:12]
    orient, touch, density = struct.unpack_from("<BBH", c, 12)
    kbd, nav, inflags = c[16], c[17], c[18]
    sw, sh, sdk = struct.unpack_from("<HHH", c, 20)
    layout, ui, swdp, wdp, hdp = struct.unpack_from("<BBHHH", c, 28)
    script, variant, layout2, color = c[36:40], c[40:48], c[48], c[49]
    if any((mcc, mnc, orient, touch, density, kbd, nav, inflags, sw, sh, layout, ui & 0x0F,
            swdp, wdp, hdp, any(script), any(variant), layout2, color)):
        return None
    q = []
    if any(lang):
        if lang[0] & 0x80:
            return None
        q.append(lang.decode())
        if any(country):
            if country[0] & 0x80:
                return None
            q.append("r" + country.decode())
    if ui & 0x30 == 0x20:
        q.append("night")
    elif ui & 0x30 == 0x10:
        q.append("notnight")
    if sdk:
        q.append("v%d" % sdk)
    return "-".join(q)


def arsc_strings(data, needle):
    """-> [(type, name, qualifier|None, value, ambigu)] untuk resource string yang mengandung needle"""
    res = []
    hsize = struct.unpack_from("<HHI", data, 0)[1]
    pos, gstr = hsize, []
    low = needle.lower()
    while pos + 8 <= len(data):
        ctype, _h, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == 0x0001:
            gstr = string_pool(data, pos)
        elif ctype == 0x0200:
            res += package_strings(data, pos, csize, gstr, low)
        pos += csize
    return res


def package_strings(data, pkg, psize, gstr, low):
    phsize = struct.unpack_from("<H", data, pkg + 2)[0]
    type_off, _lpt, key_off = struct.unpack_from("<III", data, pkg + 268)
    types = string_pool(data, pkg + type_off)
    keys = string_pool(data, pkg + key_off)
    out, ids = [], {}
    pos, end = pkg + phsize, pkg + psize
    while pos + 8 <= end:
        ctype, hs, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == 0x0201:
            tid, flags = data[pos + 8], data[pos + 9]
            count, estart = struct.unpack_from("<II", data, pos + 12)
            csz = struct.unpack_from("<I", data, pos + 20)[0]
            q = qualifier(data[pos + 20:pos + 20 + csz])
            tname = types[tid - 1] if tid - 1 < len(types) else "?"
            if flags & 0x01:      # sparse: (idx u16, offset/4 u16)
                offs = [struct.unpack_from("<HH", data, pos + hs + i * 4) for i in range(count)]
                offs = [(i, o * 4) for i, o in offs]
            elif flags & 0x02:    # offset16
                offs = [(i, o * 4 if o != 0xFFFF else NONE)
                        for i, o in enumerate(struct.unpack_from("<%dH" % count, data, pos + hs))]
            else:
                offs = list(enumerate(struct.unpack_from("<%dI" % count, data, pos + hs)))
            for idx, o in offs:
                if o == NONE:
                    continue
                e = pos + estart + o
                esize, eflags = struct.unpack_from("<HH", data, e)
                if eflags & 0x08:  # compact: key=u16(size), dataType=flags>>8, data u32
                    kidx, dtype, dval = esize, eflags >> 8, struct.unpack_from("<I", data, e + 4)[0]
                elif eflags & 0x01:  # map/complex
                    continue
                else:
                    kidx = struct.unpack_from("<I", data, e + 4)[0]
                    dtype, dval = data[e + 11], struct.unpack_from("<I", data, e + 12)[0]
                kname = keys[kidx] if kidx < len(keys) else "?"
                ids.setdefault((tname, kname), set()).add(idx)
                if dtype != 0x03 or dval >= len(gstr) or low not in gstr[dval].lower():
                    continue
                out.append((tname, kname, q, gstr[dval]))
        pos += csize
    # nama resource disamarkan (aapt2 --collapse-resource-names): satu nama dipakai banyak ID,
    # overlay berbasis nama akan salah sasaran -> tandai
    return [(t, n, q, v, len(ids[(t, n)]) > 1) for t, n, q, v in out]


# ---------------------------------------------------------------- overlay
def aapt_escape(s):
    s = escape(s).replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"')
    return "\\" + s if s[:1] in ("@", "?") else s


def write_overlay(out, target, entries, author):
    safe = re.sub(r"[^A-Za-z0-9_]", "_", target)
    d = os.path.join(out, "Branding_" + safe)
    by_q = {}
    for name, q, val in entries:
        by_q.setdefault(q, {})[name] = val
    for q, items in by_q.items():
        vd = os.path.join(d, "res", "values" + ("-" + q if q else ""))
        os.makedirs(vd, exist_ok=True)
        with open(os.path.join(vd, "strings.xml"), "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n')
            for n, v in sorted(items.items()):
                f.write('    <string name="%s">%s</string>\n' % (n, aapt_escape(v)))
            f.write("</resources>\n")
    with open(os.path.join(d, "AndroidManifest.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                'package="com.%s.branding.%s">\n'
                '    <overlay android:targetPackage="%s" android:isStatic="true" android:priority="999"/>\n'
                '    <application android:hasCode="false"/>\n</manifest>\n'
                % (re.sub(r"[^a-z0-9]", "", author.lower()) or "port", safe.lower(), target))
    with open(os.path.join(d, "apktool.yml"), "w") as f:
        f.write("version: 2.9.0\napkFileName: Branding_%s.apk\nisFrameworkApk: false\n"
                "usesFramework:\n  ids:\n  - 1\nsdkInfo:\n  minSdkVersion: 29\n  targetSdkVersion: 29\n"
                "packageInfo:\n  forcedPackageId: 127\nversionInfo:\n  versionCode: 1\n  versionName: 1.0\n"
                "doNotCompress:\n- resources.arsc\n" % safe)
    return d


def patch_decoded(root, match, repl, author):
    el = re.compile(r"(<string\b[^>]*>)(.*?)(</string>)", re.S)
    n = 0
    for dp, _dn, fn in os.walk(os.path.join(root, "res")):
        if not os.path.basename(dp).startswith("values") or "strings.xml" not in fn:
            continue
        f = os.path.join(dp, "strings.xml")
        src = open(f, encoding="utf-8").read()

        def sub(m):
            nonlocal n
            if not match.search(m.group(2)):
                return m.group(0)
            n += 1
            return m.group(1) + repl.sub(author, m.group(2)) + m.group(3)
        new = el.sub(sub, src)
        if new != src:
            open(f, "w", encoding="utf-8").write(new)
    print("PATCHED %d" % n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.add_argument("--needle", default="xiaomi.eu")
    ap.add_argument("--match", default=r"(?i)\bby\s+xiaomi\.eu\b")
    ap.add_argument("--author", required=True)
    ap.add_argument("--out")
    ap.add_argument("--dex", action="store_true", help="juga cari needle di classes*.dex (lambat)")
    ap.add_argument("--patch-decoded", help="folder hasil apktool d: ganti teks di res/values*/strings.xml")
    a = ap.parse_args()
    nb = [a.needle.encode(), a.needle.encode("utf-16-le")]
    match = re.compile(a.match)
    repl = re.compile(re.escape(a.needle), re.I)
    if a.patch_decoded:
        return patch_decoded(a.patch_decoded, match, repl, a.author)
    targets = {}
    for top in DIRS:
        base = os.path.join(a.root, top)
        for dp, _dn, fn in os.walk(base):
            for f in sorted(fn):
                if not f.endswith((".apk", ".jar")):
                    continue
                path = os.path.join(dp, f)
                rel = os.path.relpath(path, a.root)
                try:
                    z = zipfile.ZipFile(path)
                    names = set(z.namelist())
                    for n in (names if a.dex else ()):
                        if re.fullmatch(r"classes\d*\.dex", n) and any(b in z.read(n) for b in nb):
                            print("DEX  %s (%s)" % (rel, n))
                            break
                    if "resources.arsc" not in names:
                        continue
                    arsc = z.read("resources.arsc")
                    if not any(b in arsc for b in nb):
                        continue
                    pkg, tgt = manifest_info(z.read("AndroidManifest.xml"))
                    hits = arsc_strings(arsc, a.needle)
                except zipfile.BadZipFile:
                    continue
                except Exception as e:  # format tak dikenal: lewati, jangan gagalkan build
                    print("ERR  %s: %s" % (rel, e))
                    continue
                target = tgt or pkg
                if tgt:  # APK overlay: dipatch langsung (decode -> ganti teks -> build -> tanda tangan ulang)
                    for t, n, q, v, _amb in hits:
                        if t == "string" and match.search(v):
                            print("HIT  %s %s string/%s [%s] %r" % (rel, target, n, "default" if q == "" else (q or "?"), v))
                    if any(t == "string" and match.search(v) for t, _n, _q, v, _a in hits):
                        print("PATCH %s" % rel)
                    continue
                for t, n, q, v, ambig in hits:
                    if t != "string":
                        continue
                    if ambig:
                        print("SKIP %s %s string/%s nama resource disamarkan (dipakai banyak ID) %r" % (rel, target, n, v))
                        continue
                    qs = "default" if q == "" else (q or "?")
                    if not match.search(v):
                        print("HIT  %s %s string/%s [%s] %r (tidak cocok --match, dibiarkan)" % (rel, target, n, qs, v))
                        continue
                    if q is None:
                        print("SKIP %s %s string/%s config tidak didukung %r" % (rel, target, n, v))
                        continue
                    new = repl.sub(a.author, v)
                    print("HIT  %s %s string/%s [%s] %r -> %r" % (rel, target, n, qs, v, new))
                    targets.setdefault(target, {})[(n, q)] = new
    for target, items in sorted(targets.items()):
        d = write_overlay(a.out, target, [(n, q, v) for (n, q), v in items.items()], a.author)
        print("OVERLAY %s %s %d" % (target, d, len(items)))


if __name__ == "__main__":
    main()
