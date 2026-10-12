#!/usr/bin/env bash
# =============================================================================
#  port_arch64.sh - donor 64-bit-only (aarch64) di atas vendor marble 64-32 (di-source port.sh)
#
#  Mengikuti panduan "Port HyperOS aarch64 (64-bit) dengan vendor bawaan device (64-32)"
#  (Reguit n fix by Project_MINT, original by @jopvan1). Dipakai kalau ROM donor tidak membawa
#  lib 32-bit (K90/annibale, dll). Donor yang masih 64-32 TIDAK diubah sama sekali.
#
#  Memakai helper/variabel port.sh: log ok warn is_true get_prop set_prop extract_img
#                                   P_FS B_FS B_IMG WORK
#
#  ARCH64_FIX=auto|true|false   auto = jalan hanya kalau donor terdeteksi 64-bit-only
#  ARCH64_COPY_LIB=auto         auto  = ikut ARCH64_FIX: salin system/lib + system_ext/lib dari base, tapi
#                                       hanya file yang BELUM ada di donor (tidak menimpa lib donor)
#                               true  = salin semua dan timpa (persis panduan)
#                               false = jangan salin (panduan: opsional, internal tetap aman tanpa ini)
#
#  Langkah (nomor = nomor di panduan):
#    1+2  /system/bin/{linker,linker_asan} dan /system/bin/bootstrap/{linker,linker_asan}
#         diganti symlink dari base (linker_asan64 & linker_hwasan64 tetap milik donor)
#    2    /system/bin/vold dan vold_prepare_subdirs dari base
#    3    (opsional) system/lib dan system_ext/lib dari base
#    4    odm build.prop   : abilist=arm64-v8a, abilist32=, abilist64=arm64-v8a, ro.zygote=zygote64, dex2oat64
#    5    vendor build.prop: sama seperti odm
#    6    vendor/etc/init  : file rc media omx dihapus
#    7    vendor/etc/vintf : HAL android.hardware.media.omx dihapus dari manifest
#    BONUS system/etc/init/mediaserver_dynamic_QCOM.rc: import mediaserver.64bit_true.rc
#
#  Tambahan di luar panduan:
#    - baris fs_config + file_contexts (label SELinux) tiap file yang diambil dari base disalin dari config
#      base. Tanpa ini toolkit menebak label dari kemiripan nama folder, jadi linker/vold bisa salah label.
#    - cek linker diulang setelah patch (kalau LINKER_CHECK=true) supaya kelihatan 32-bit sudah terpenuhi
# =============================================================================

ARCH64_FIX=${ARCH64_FIX:-auto}
ARCH64_COPY_LIB=${ARCH64_COPY_LIB:-auto}

# donor tidak punya lib 32-bit? (dua sinyal: folder system/lib kosong/tidak ada, abilist tanpa armeabi-v7a)
a64_donor_is_64only() {
    local sys="$P_FS/system/system" list no_lib=0 no_abi=0
    list=$(get_prop "$sys/build.prop" ro.system.product.cpu.abilist)
    if [[ -z $(find "$sys/lib" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true) ]]; then no_lib=1; fi
    if [[ -n $list && $list != *armeabi-v7a* ]]; then no_abi=1; fi
    log "arch64: donor abilist='${list:-?}' | system/lib $([[ $no_lib == 1 ]] && echo kosong/tidak ada || echo ada)"
    [[ $no_lib == 1 || $no_abi == 1 ]]
}

# a64_take <rel di system/system>: ganti milik donor dengan milik base (symlink ikut disalin apa adanya)
a64_take() {
    local rel=$1 s="$A64_BASE_SYS/$1" d="$P_FS/system/system/$1"
    if [[ ! -e $s && ! -L $s ]]; then warn "arch64: $rel tidak ada di base, dilewati"; return 1; fi
    rm -rf "$d"
    mkdir -p "$(dirname "$d")"
    cp -a "$s" "$d"
    printf 'system/system/%s\n' "$1" >> "$A64_LIST_SYS"
    if [[ -L $s ]]; then ok "arch64: system/$rel <- base (symlink -> $(readlink "$s"))"
    else ok "arch64: system/$rel <- base"; fi
}

# a64_prop <file> k=v ...  : isi file utama; file *build.prop lain di folder yang sama hanya diubah kalau sudah mendefinisikan key-nya
a64_prop() {
    local f=$1 kv k v g; shift
    [[ -f $f ]] || { warn "arch64: ${f#"$B_FS"/} tidak ada, props dilewati"; return 0; }
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        set_prop "$f" "$k" "$v"
        for g in "$(dirname "$f")"/*build.prop; do
            [[ -f $g && $g != "$f" ]] || continue
            if grep -qE "^${k//./\\.}=" "$g"; then set_prop "$g" "$k" "$v"; fi
        done
    done
    ok "arch64: props ${f#"$B_FS"/} -> $*"
}

# a64_record_new <dir src base> <dir dst port> <prefix key config> <file daftar> <mode>
# catat path yang akan ditambahkan/ditimpa oleh cp (mode auto: hanya yang belum ada di port)
a64_record_new() {
    local src=$1 dst=$2 pre=$3 list=$4 m=$5 rel
    while IFS= read -r -d '' rel; do
        if [[ $m == true || ( ! -e $dst/$rel && ! -L $dst/$rel ) ]]; then printf '%s\n' "$pre/$rel" >> "$list"; fi
    done < <(find "$src" -mindepth 1 -printf '%P\0')
}

# a64_sync_cfg <partisi> <folder config base> <file daftar path>
# salin baris fs_config + file_contexts dari config base ke config port (toolkit hanya menebak label file baru)
a64_sync_cfg() {
    local part=$1 bcfg=$2 list=$3 out kind hit miss
    [[ -s $list ]] || return 0
    out=$(python3 - "$bcfg" "$P_FS/config" "$part" "$list" <<'PY'
import os, re, sys
bdir, pdir, part, listf = sys.argv[1:5]
paths = [l.rstrip("\n") for l in open(listf, encoding="utf-8") if l.strip()]
esc = lambda k: re.sub(r"([^-_/a-zA-Z0-9])", r"\\\1", k)
def load(fn, unesc):
    d = {}
    if os.path.isfile(fn):
        for line in open(fn, encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            if line.strip():
                k, _, rest = line.partition(" ")
                d[k.replace("\\", "") if unesc else k] = rest
    return d
for kind, prefix in (("fs_config", ""), ("file_contexts", "/")):
    bfn = os.path.join(bdir, "%s_%s" % (part, kind))
    pfn = os.path.join(pdir, "%s_%s" % (part, kind))
    base = load(bfn, kind == "file_contexts")
    port = load(pfn, kind == "file_contexts")
    hit = miss = 0
    for p in paths:
        k = prefix + p
        if k in base:
            port[k] = base[k]
            hit += 1
        else:
            miss += 1
    if hit:
        with open(pfn, "w", encoding="utf-8", newline="\n") as f:
            for k in sorted(port):
                f.write("%s %s\n" % (esc(k) if kind == "file_contexts" else k, port[k]))
    print("%s %d %d" % (kind, hit, miss))
PY
) || { warn "arch64: sinkron config $part gagal"; return 0; }
    while read -r kind hit miss; do
        if [[ ${miss:-0} -gt 0 ]]; then
            warn "arch64: $part $kind: $miss path tidak ada di config base (label/izin ditebak toolkit), $hit disalin dari base"
        else
            ok "arch64: $part $kind: $hit entri disalin dari config base"
        fi
    done <<< "$out"
}

# symlink /system/bin/linker (dari base) menunjuk ke /apex/com.android.runtime/bin/linker. APEX runtime donor 64-only
# bisa saja tidak membawa linker 32-bit -> symlink menggantung. Hanya diperiksa + warning, tidak ada yang diubah
# (catatan panduan: system/apex/runtime tetap milik donor kalau donor bisa boot).
a64_check_runtime_linker() {
    local out kind f n=0
    out=$(python3 - "${EXTRACT_EROFS:-${BIN:-}/extract.erofs}" "$P_FS/system/system/apex" "$P_FS/system_ext/apex" <<'PYAPEX'
import io, os, shutil, struct, subprocess, sys, tempfile, zipfile
erofs = sys.argv[1]
def names_in_payload(payload):
    tmpd = tempfile.mkdtemp(prefix="rt_")
    try:
        img = os.path.join(tmpd, "p.img")
        open(img, "wb").write(payload)
        if len(payload) > 1082 and payload[1080:1082] == b"\x53\xef":
            r = subprocess.run(["debugfs", "-R", "ls -p /bin", img], capture_output=True, text=True)
            out = set()
            for line in r.stdout.splitlines():
                parts = line.strip("/").split("/")
                if len(parts) >= 5:
                    out.add(parts[4])
            return out
        if len(payload) > 1028 and struct.unpack("<I", payload[1024:1028])[0] == 0xE0F5E1E2 and erofs and os.path.exists(erofs):
            o = os.path.join(tmpd, "x"); os.makedirs(o)
            subprocess.run([erofs, "-i", img, "-X", "bin", "-o", o], capture_output=True)
            out = set()
            for _r, ds, fs in os.walk(o):
                out.update(ds); out.update(fs)
            return out
        return None
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
for d in sys.argv[2:]:
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.startswith("com.android.runtime"):
            continue
        p = os.path.join(d, fn)
        if os.path.isdir(p):                                   # apex ter-flatten
            print("%s %s" % ("OK" if os.path.lexists(os.path.join(p, "bin", "linker")) else "NO", fn))
            continue
        try:
            with zipfile.ZipFile(p) as z:
                if fn.endswith(".capex"):
                    with zipfile.ZipFile(io.BytesIO(z.read("original_apex"))) as z2:
                        payload = z2.read("apex_payload.img")
                else:
                    payload = z.read("apex_payload.img")
            names = names_in_payload(payload)
        except (KeyError, zipfile.BadZipFile, OSError):
            names = None
        print("%s %s" % ("UNKNOWN" if names is None else ("OK" if "linker" in names else "NO"), fn))
PYAPEX
) || { warn "arch64: cek linker APEX runtime gagal dijalankan"; return 0; }
    while read -r kind f; do
        [[ -n ${kind:-} ]] || continue
        n=$((n + 1))
        case $kind in
            OK) ok "arch64: $f membawa bin/linker (target symlink /system/bin/linker ada)" ;;
            NO) warn "arch64: $f TIDAK punya bin/linker -> symlink /system/bin/linker (dari base) menggantung, binary 32-bit vendor gagal start. Pertimbangkan APEX com.android.runtime dari base" ;;
            *)  log "arch64: $f tidak bisa diperiksa (format payload tidak dikenal), cek manual bin/linker" ;;
        esac
    done <<< "$out"
    [[ $n -gt 0 ]] || log "arch64: APEX com.android.runtime donor tidak ditemukan, cek bin/linker dilewati"
}

# hapus blok <hal>...</hal> android.hardware.media.omx dari file manifest VINTF
a64_strip_omx_hal() { # file...
    local f n
    for f in "$@"; do
        [[ -f $f ]] || continue
        n=$(python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
removed = 0
def drop(m):
    global removed
    if re.search(r"<name>\s*android\.hardware\.media\.omx\s*</name>", m.group(0)):
        removed += 1
        return ""
    return m.group(0)
t = re.sub(r"<hal\b.*?</hal>", drop, s, flags=re.S)
if removed:
    open(p, "w", encoding="utf-8").write(t)
print(removed)
PY
)
        if [[ ${n:-0} -gt 0 ]]; then ok "arch64: HAL media.omx dihapus dari ${f#"$B_FS"/} ($n blok)"; fi
    done
}

arch64_fix() {
    local mode=${ARCH64_FIX,,} root sysdir f n rc
    case $mode in
        false|off|no|0) log "arch64: dimatikan (ARCH64_FIX=$ARCH64_FIX)"; return 0 ;;
        auto)
            if ! a64_donor_is_64only; then
                log "arch64: donor masih membawa lib 32-bit (64-32), langkah panduan 64-bit dilewati"; return 0
            fi ;;
        true|on|yes|1) ;;
        *) warn "arch64: ARCH64_FIX='$ARCH64_FIX' tidak dikenal (auto|true|false), dilewati"; return 0 ;;
    esac
    log "arch64: donor 64-bit-only -> terapkan panduan 64-bit di atas vendor 64-32"

    # --- ambil system base (ROM 64-32)
    root="$WORK/base_arch"; rm -rf "$root"; mkdir -p "$root"
    A64_LIST_SYS="$WORK/arch64_paths_system.txt"; A64_LIST_EXT="$WORK/arch64_paths_system_ext.txt"
    : > "$A64_LIST_SYS"; : > "$A64_LIST_EXT"
    if [[ -n ${A64_BASE_SYS_OVERRIDE:-} ]]; then   # untuk uji: folder system base yang sudah ada
        A64_BASE_SYS=$A64_BASE_SYS_OVERRIDE
        A64_BASE_CFG=${A64_BASE_CFG_OVERRIDE:-$root/config}
    else
        [[ -f $B_IMG/system.img ]] || { warn "arch64: $B_IMG/system.img tidak ada, tidak bisa mengambil file 64-32 dari base"; return 0; }
        extract_img "$B_IMG/system.img" "$root"
        A64_BASE_SYS="$root/system/system"
        [[ -d $A64_BASE_SYS/bin ]] || A64_BASE_SYS="$root/system"
        A64_BASE_CFG="$root/config"
    fi
    sysdir="$P_FS/system/system"

    # --- 1+2: linker & vold dari base
    for f in bin/linker bin/linker_asan bin/bootstrap/linker bin/bootstrap/linker_asan; do a64_take "$f" || true; done
    log "arch64: linker_asan64 & linker_hwasan64 tetap milik donor (sesuai panduan)"
    for f in bin/vold bin/vold_prepare_subdirs; do
        if a64_take "$f"; then chmod 0755 "$sysdir/$f" 2>/dev/null || true; fi
    done

    # --- 3: lib 32-bit dari base. auto = hanya yang belum ada (tanpa menimpa), true = timpa semua
    local cp_mode=${ARCH64_COPY_LIB,,} cpo=(-a)
    case $cp_mode in
        auto) cpo=(-a --update=none) ;;
        true|on|yes|1) cpo=(-a) ;;
        false|off|no|0) cp_mode=false ;;
        *) warn "arch64: ARCH64_COPY_LIB='$ARCH64_COPY_LIB' tidak dikenal (auto|true|false), dianggap auto"; cp_mode=auto; cpo=(-a --update=none) ;;
    esac
    if [[ $cp_mode == false ]]; then
        log "arch64: system/lib & system_ext/lib tidak disalin (ARCH64_COPY_LIB=false)"
    else
        if [[ -d $A64_BASE_SYS/lib ]]; then
            a64_record_new "$A64_BASE_SYS/lib" "$sysdir/lib" system/system/lib "$A64_LIST_SYS" "$cp_mode"
            mkdir -p "$sysdir/lib"; cp "${cpo[@]}" "$A64_BASE_SYS/lib/." "$sysdir/lib/"
            ok "arch64: system/lib <- base (mode $cp_mode, sekarang $(find "$sysdir/lib" -type f | wc -l) file; libc/libm/libdl/libdl-android = symlink ikut disalin)"
        else warn "arch64: system/lib tidak ada di base"; fi
        if [[ -z ${A64_BASE_SYS_OVERRIDE:-} && -f $B_IMG/system_ext.img ]]; then
            if ! ( extract_img "$B_IMG/system_ext.img" "$root" ); then
                warn "arch64: ekstrak system_ext.img base gagal, system_ext/lib tidak disalin (opsional)"
            fi
            if [[ -d $root/system_ext/lib ]]; then
                a64_record_new "$root/system_ext/lib" "$P_FS/system_ext/lib" system_ext/lib "$A64_LIST_EXT" "$cp_mode"
                mkdir -p "$P_FS/system_ext/lib"; cp "${cpo[@]}" "$root/system_ext/lib/." "$P_FS/system_ext/lib/"
                ok "arch64: system_ext/lib <- base (mode $cp_mode)"
            fi
        fi
    fi

    # --- label SELinux + izin file yang diambil dari base
    a64_sync_cfg system "$A64_BASE_CFG" "$A64_LIST_SYS"
    a64_sync_cfg system_ext "$A64_BASE_CFG" "$A64_LIST_EXT"

    a64_check_runtime_linker

    # --- 4+5: props odm & vendor
    a64_prop "$B_FS/odm/etc/build.prop" \
        ro.odm.product.cpu.abilist=arm64-v8a ro.odm.product.cpu.abilist32= ro.odm.product.cpu.abilist64=arm64-v8a \
        ro.zygote=zygote64 dalvik.vm.dex2oat64.enabled=true
    a64_prop "$B_FS/vendor/build.prop" \
        ro.vendor.product.cpu.abilist=arm64-v8a ro.vendor.product.cpu.abilist32= ro.vendor.product.cpu.abilist64=arm64-v8a \
        ro.zygote=zygote64 dalvik.vm.dex2oat64.enabled=true
    if [[ ! -f $sysdir/etc/init/hw/init.zygote64.rc ]]; then
        warn "arch64: system donor tidak punya etc/init/hw/init.zygote64.rc -> ro.zygote=zygote64 tidak akan jalan"
    fi

    # --- 6: rc media omx
    n=0
    while IFS= read -r -d '' rc; do
        rm -f "$rc"; n=$((n + 1)); ok "arch64: vendor/etc/init/$(basename "$rc") dihapus"
    done < <(find "$B_FS/vendor/etc/init" -maxdepth 1 -type f -iname '*omx*' -print0 2>/dev/null || true)
    [[ $n -gt 0 ]] || log "arch64: vendor/etc/init tidak punya file rc omx"
    log "arch64: sisa rc media di vendor/etc/init: $(find "$B_FS/vendor/etc/init" -maxdepth 1 -type f -iname '*media*' -printf '%f ' 2>/dev/null || true)"

    # --- 7: HAL omx di manifest vendor (dan fragmennya)
    a64_strip_omx_hal "$B_FS"/vendor/etc/vintf/manifest*.xml "$B_FS"/vendor/etc/vintf/manifest/*.xml \
                      "$B_FS"/odm/etc/vintf/manifest*.xml "$B_FS"/odm/etc/vintf/manifest/*.xml

    # --- BONUS: mediaserver
    n=0
    for rc in "$sysdir/etc/init/mediaserver_dynamic_QCOM.rc" "$P_FS/system_ext/etc/init/mediaserver_dynamic_QCOM.rc"; do
        [[ -f $rc ]] || continue
        if grep -q 'mediaserver\.64bit_\${ro\.mediaserver\.64b\.enable:-false}\.rc' "$rc"; then
            sed -i 's|^\(import /system/etc/init/hw/mediaserver\.64bit_\)\${ro\.mediaserver\.64b\.enable:-false}\(\.rc\)|\1true\2|' "$rc"
            ok "arch64: ${rc#"$P_FS"/} import -> mediaserver.64bit_true.rc (on property:* tidak disentuh)"
            [[ -f $sysdir/etc/init/hw/mediaserver.64bit_true.rc ]] \
                || warn "arch64: system/etc/init/hw/mediaserver.64bit_true.rc tidak ada di donor -> import /system/etc/init/hw/mediaserver.64bit_true.rc akan gagal"
        else
            log "arch64: ${rc#"$P_FS"/} tidak memakai pola import 64bit_\${...}, dilewati"
        fi
        n=$((n + 1))
    done
    [[ $n -gt 0 ]] || log "arch64: mediaserver_dynamic_QCOM.rc tidak ada di donor, bonus mediaserver dilewati"

    if is_true "${LINKER_CHECK:-false}" && declare -F linker_check >/dev/null; then
        log "arch64: cek ulang linker setelah patch"
        linker_check
    fi
    rm -rf "$root"
    warn "arch64: panduan ini diuji orang lain di device lain (T2PAS) -> kalau bootloop, coba ARCH64_COPY_LIB=true / false dan cek logcat 'linker'/'vold'/'omx'"
}
