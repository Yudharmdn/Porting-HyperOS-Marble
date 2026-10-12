#!/usr/bin/env bash
# =============================================================================
#  port_extras.sh - tambahan untuk scripts/port.sh (di-source, hanya berisi fungsi)
#
#  Memakai helper dan variabel dari port.sh:
#    log ok warn die is_true get_prop set_prop
#    P_FS B_FS TOOLS_DIR WORK SCRIPT_DIR
#
#  Fungsi:
#    fix_aod_overlay            DevicesAndroidOverlay -> DozeService milik SystemUI (kalau donor tak punya com.miui.aod)
#    millet_fix                 ro.millet.netlink disamakan dengan marble
#    unlock_device_features     nyalakan fitur tambahan di product/etc/device_features/*.xml
#    files_from_base            bootanimation, VoiceTrigger (base A15), props ringan (HyperOS-Port-Python)
#    rom_branding               "by xiaomi.eu" di About phone -> "by $ROM_AUTHOR" (overlay RRO)
# =============================================================================

AOD_FIX=${AOD_FIX:-auto}            # auto | true | false
MILLET_FIX=${MILLET_FIX:-true}
# UNLOCK_FEATURES (default dan format) dideklarasikan di blok konfigurasi port.sh.

# ------------------------------------------------------------------ helper APK
# apk_tool d|b <input> <output>  (apktool dari toolkit, lalu apktool di PATH, lalu APKEditor.jar)
apk_tool() {
    local mode=$1 in=$2 out=$3 at="$TOOLS_DIR/bin/apktool"
    if [[ -f $at/apktool ]]; then
        chmod +x "$at/apktool" 2>/dev/null || true
        "$at/apktool" "$mode" "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    elif command -v apktool >/dev/null; then
        apktool "$mode" "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    elif [[ -f $at/APKEditor.jar ]]; then
        java -jar "$at/APKEditor.jar" "$mode" -i "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    else
        echo "apktool/APKEditor tidak ditemukan di $at maupun PATH" > "$WORK/apktool.log"
        return 127
    fi
}

# apk_sign <apk>: zipalign + tanda tangan kunci uji (in-place). Overlay di /product tidak
# butuh tanda tangan yang sama dengan target, tapi APK tanpa tanda tangan bisa ditolak PackageManager.
apk_sign() {
    local apk=$1 ks="$WORK/port_test.jks"
    if ! command -v apksigner >/dev/null; then
        warn "sign: apksigner tidak ada, $(basename "$apk") tidak ditandatangani (overlay bisa ditolak PackageManager)"
        return 0
    fi
    if command -v zipalign >/dev/null; then
        zipalign -f -p 4 "$apk" "$apk.al" && mv -f "$apk.al" "$apk" || true
    fi
    if [[ ! -f $ks ]]; then
        keytool -genkeypair -keystore "$ks" -storepass android -keypass android -alias port \
            -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=port" >/dev/null 2>&1 \
            || { warn "sign: keytool gagal membuat kunci uji"; return 0; }
    fi
    if apksigner sign --ks "$ks" --ks-pass pass:android --key-pass pass:android "$apk" >/dev/null 2>&1; then
        ok "sign: $(basename "$apk") ditandatangani (kunci uji)"
    else
        warn "sign: apksigner gagal untuk $(basename "$apk")"
    fi
}

# ------------------------------------------------------------------ AOD
# DevicesAndroidOverlay dari marble menunjuk ke com.miui.aod/...DozeService. Kalau ROM donor
# tidak membawa com.miui.aod, komponen itu tidak ada -> AOD/doze rusak. Toraidl mengganti
# ke DozeService milik SystemUI. Mode auto: hanya patch bila perlu.
fix_aod_overlay() {
    local apk pkgs dec out n=0 f
    if [[ $AOD_FIX == false ]]; then log "AOD: dimatikan (AOD_FIX=false)"; return 0; fi
    apk=$(find "$P_FS/product" -type f -name DevicesAndroidOverlay.apk 2>/dev/null | head -n1 || true)
    if [[ -z $apk ]]; then log "AOD: DevicesAndroidOverlay.apk tidak ada di port, dilewati"; return 0; fi

    if ! python3 - "$apk" 2>/dev/null <<'PY'
import sys, zipfile
needle = "com.miui.aod.doze.DozeService"
data = zipfile.ZipFile(sys.argv[1]).read("resources.arsc")
sys.exit(0 if needle.encode() in data or needle.encode("utf-16-le") in data else 1)
PY
    then
        log "AOD: overlay tidak merujuk com.miui.aod DozeService, tidak perlu patch"
        return 0
    fi

    if [[ $AOD_FIX == auto ]]; then
        pkgs=$(python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" | cut -f1 || true)
        if grep -qx 'com.miui.aod' <<< "$pkgs"; then
            ok "AOD: donor punya com.miui.aod, overlay marble dipakai apa adanya (AOD_FIX=true untuk memaksa patch)"
            return 0
        fi
        log "AOD: donor tidak punya com.miui.aod -> overlay diarahkan ke DozeService SystemUI"
    fi

    # HyperOS 2/3: doze ada di SystemUI sebagai com.android.keyguard.doze.MiuiDozeService
    # (HyperOS-Port-Python); SystemUI lama: com.android.systemui.doze.DozeService (hyperos_port)
    local target=com.android.systemui/com.android.systemui.doze.DozeService sui
    sui=$(find "$P_FS/system_ext" "$P_FS/product" -type f \( -name 'MiuiSystemUI.apk' -o -name 'SystemUI.apk' \) 2>/dev/null | head -n1 || true)
    if [[ -n $sui ]] && python3 - "$sui" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
sys.exit(0 if any(b"Lcom/android/keyguard/doze/MiuiDozeService;" in z.read(n) for n in z.namelist() if n.endswith(".dex")) else 1)
PY
    then target=com.android.systemui/com.android.keyguard.doze.MiuiDozeService; fi
    log "AOD: target doze = $target"
    dec="$WORK/aod_overlay"; out="$WORK/DevicesAndroidOverlay.patched.apk"
    rm -rf "$dec" "$out"
    if ! apk_tool d "$apk" "$dec"; then
        tail -n 15 "$WORK/apktool.log" >&2
        warn "AOD: decode overlay gagal, overlay marble dipertahankan"; return 0
    fi
    while IFS= read -r f; do
        sed -i "s|com\.miui\.aod/com\.miui\.aod\.doze\.DozeService|$target|g" "$f"
        n=$((n + 1))
    done < <(grep -rlF 'com.miui.aod.doze.DozeService' "$dec" --include='*.xml' 2>/dev/null || true)
    if [[ $n -eq 0 ]]; then
        warn "AOD: string DozeService tidak ditemukan di XML hasil decode, overlay dipertahankan"; return 0
    fi
    if ! apk_tool b "$dec" "$out"; then
        tail -n 15 "$WORK/apktool.log" >&2
        warn "AOD: build ulang overlay gagal, overlay marble dipertahankan"; return 0
    fi
    apk_sign "$out"
    cp -f "$out" "$apk"
    ok "AOD: $(basename "$apk") dipatch ($n file XML), DozeService -> $target"
}

# ------------------------------------------------------------------ Millet
# ro.millet.netlink = nomor netlink yang didaftarkan kernel untuk Millet (pembekuan app).
# Harus sama dengan kernel yang dipakai. Disamakan dengan marble, dan dibuang dari partisi
# donor lain supaya tidak ada yang menimpa (urutan load: system -> system_ext -> vendor -> odm -> product -> mi_ext).
millet_fix() {
    local key=ro.millet.netlink val="" src="" f old
    is_true "$MILLET_FIX" || { log "Millet: dimatikan (MILLET_FIX=false)"; return 0; }
    for f in "$B_FS/product/etc/build.prop" "$B_FS/vendor/build.prop" "$B_FS"/odm/etc/*build.prop; do
        [[ -f $f ]] || continue
        val=$(get_prop "$f" "$key")
        if [[ -n $val ]]; then src=${f#"$B_FS"/}; break; fi
    done
    if [[ -z $val ]]; then
        log "Millet: $key tidak ada di base marble (product/vendor/odm), nilai donor dipertahankan"
        return 0
    fi
    old=$(cat "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" \
              "$P_FS/product/etc/build.prop" "$P_FS/mi_ext/etc/build.prop" 2>/dev/null \
          | sed -n "s/^${key//./\\.}=//p" | tail -n1 || true)
    for f in "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" "$P_FS/mi_ext/etc/build.prop"; do
        if [[ -f $f ]]; then sed -i "/^${key//./\\.}=/d" "$f"; fi
    done
    set_prop "$P_FS/product/etc/build.prop" "$key" "$val"
    ok "Millet: $key = $val (dari base $src; donor: ${old:-kosong})"
    log "Millet: kalau memakai BOOT_IMG kernel custom, nilai ini harus sama dengan netlink yang didaftarkan kernel tersebut"
}

# ------------------------------------------------------------------ device_features
unlock_device_features() {
    local d="$P_FS/product/etc/device_features" out
    local feats=${UNLOCK_FEATURES:-}
    case ${feats,,} in
        ""|none|off|false) log "device_features: UNLOCK_FEATURES=${feats:-kosong}, dilewati"; return 0 ;;
    esac
    if [[ ! -d $d ]]; then warn "device_features: $d tidak ada, dilewati"; return 0; fi
    # shellcheck disable=SC2086  # daftar spec sengaja di-split
    if ! out=$(python3 "$SCRIPT_DIR/device_features_unlock.py" "$d" $feats 2>&1); then
        printf '    %s\n' "$out" >&2
        warn "device_features: unlock gagal, file dibiarkan seperti semula"
        return 0
    fi
    while IFS= read -r f; do printf '    %s\n' "$f"; done <<< "$out"
    ok "device_features: unlock selesai (UNLOCK_FEATURES)"
}

# ------------------------------------------------------------------ dari base (HyperOS-Port-Python)
# replacements.json + props.py toraidl/HyperOS-Port-Python:
# - bootanimation.zip dari base
# - VoiceTrigger dari base kalau base Android < 16 dan donor HyperOS 3+ (VoiceTrigger donor crash di A15)
# - hapus ro.miui.density.primaryscale (skala UI milik layar donor)
# - ro.miui.cust_erofs=0 kalau base tidak mengisinya (cust marble bukan erofs)
files_from_base() {
    local b p d bver pver f n=0
    b="$B_FS/product/media/bootanimation.zip"; p="$P_FS/product/media/bootanimation.zip"
    if [[ -f $b ]]; then mkdir -p "$(dirname "$p")"; cp -f "$b" "$p"; ok "bootanimation.zip dari base"; fi

    bver=$(get_prop "$B_FS/product/etc/build.prop" ro.product.build.version.release); bver=${bver%%.*}
    pver=$(cat "$P_FS/mi_ext/etc/build.prop" "$P_FS/product/etc/build.prop" "$P_FS/system/system/build.prop" 2>/dev/null \
        | sed -n 's/^ro\.mi\.os\.version\.name=//p' | head -n1)
    b=$(find "$B_FS/product" -type d -name VoiceTrigger 2>/dev/null | head -n1 || true)
    if [[ -n $b && ${bver:-0} =~ ^[0-9]+$ && ${bver:-0} -lt 16 && ${pver:-} == OS[3-9]* ]]; then
        while IFS= read -r -d '' d; do rm -rf "$d"; n=$((n + 1)); done < <(find "$P_FS/product" "$P_FS/system_ext" -type d -name VoiceTrigger -print0 2>/dev/null)
        mkdir -p "$P_FS/$(dirname "${b#"$B_FS"/}")"
        cp -a "$b" "$P_FS/${b#"$B_FS"/}"
        ok "VoiceTrigger: dari base ${b#"$B_FS"/} (base Android $bver, donor $pver; $n milik donor dibuang)"
        if [[ ${b#"$B_FS"/} == */priv-app/* ]]; then base_privapp_perms "${b#"$B_FS"/}"; fi
    fi

    for f in "$P_FS/system/system/build.prop" "$P_FS/system_ext/etc/build.prop" "$P_FS/product/etc/build.prop" "$P_FS/mi_ext/etc/build.prop"; do
        [[ -f $f ]] || continue
        if grep -q '^ro\.miui\.density\.primaryscale=' "$f"; then
            sed -i '/^ro\.miui\.density\.primaryscale=/d' "$f"; log "props: ro.miui.density.primaryscale dibuang dari ${f#"$P_FS"/}"
        fi
    done
    if [[ -z $(get_prop "$B_FS/product/etc/build.prop" ro.miui.cust_erofs) ]]; then
        set_prop "$P_FS/product/etc/build.prop" ro.miui.cust_erofs 0
        log "props: ro.miui.cust_erofs=0"
    fi
}

# ------------------------------------------------------------------ Branding
# Teks "by xiaomi.eu" di About phone -> "by $ROM_AUTHOR". APK app (Settings dll) TIDAK diubah
# (tanda tangan platform tetap): string-nya ditimpa overlay RRO baru di product/overlay.
# Kalau teksnya ada di APK overlay, overlay itu dipatch langsung lalu ditandatangani ulang.
ROM_AUTHOR=${ROM_AUTHOR:-}                                    # kosong = mati
BRANDING_FROM=${BRANDING_FROM:-xiaomi.eu}
BRANDING_MATCH=${BRANDING_MATCH:-'(?i)\bby\s+xiaomi\.eu\b'}   # hanya string yang cocok regex ini yang diganti

rom_branding() {
    local lf="$WORK/branding.log" out="$WORK/branding" kind a b c apk d o cnt n=0
    local -a args
    if [[ -z $ROM_AUTHOR ]]; then log "Branding: ROM_AUTHOR kosong, dilewati"; return 0; fi
    args=(--needle "$BRANDING_FROM" --match "$BRANDING_MATCH" --author "$ROM_AUTHOR")
    rm -rf "$out"; mkdir -p "$out"
    if ! python3 "$SCRIPT_DIR/rom_branding.py" --root "$P_FS" --out "$out" "${args[@]}" > "$lf" 2>&1; then
        tail -n 5 "$lf" >&2; warn "Branding: scan gagal, dilewati"; return 0
    fi
    while IFS= read -r a; do log "Branding: $a"; done < <(grep -E '^(HIT|SKIP|ERR)' "$lf" | head -n 40 || true)

    while read -r kind a b c <&3; do
        if [[ $kind == PATCH ]]; then
            apk="$P_FS/$a"; d="$WORK/branding_dec"; o="$WORK/branding_patched.apk"
            rm -rf "$d" "$o"
            if ! apk_tool d "$apk" "$d"; then tail -n 5 "$WORK/apktool.log" >&2; warn "Branding: decode $a gagal"; continue; fi
            cnt=$(python3 "$SCRIPT_DIR/rom_branding.py" --patch-decoded "$d" "${args[@]}" | awk '$1 == "PATCHED" {print $2}')
            if [[ ${cnt:-0} -eq 0 ]]; then warn "Branding: teks tidak ketemu di hasil decode $a"; continue; fi
            if ! apk_tool b "$d" "$o"; then tail -n 5 "$WORK/apktool.log" >&2; warn "Branding: build ulang $a gagal, dibiarkan"; continue; fi
            apk_sign "$o"; cp -f "$o" "$apk"
            ok "Branding: $a dipatch ($cnt string) -> '$ROM_AUTHOR'"; n=$((n + 1))
        else  # OVERLAY <target> <dir> <jumlah>
            o="$WORK/$(basename "$b").apk"; rm -f "$o"
            if ! apk_tool b "$b" "$o"; then tail -n 5 "$WORK/apktool.log" >&2; warn "Branding: build overlay $a gagal"; continue; fi
            apk_sign "$o"
            mkdir -p "$P_FS/product/overlay"
            cp -f "$o" "$P_FS/product/overlay/"; chmod 0644 "$P_FS/product/overlay/${o##*/}"
            ok "Branding: overlay baru product/overlay/${o##*/} -> $a ($c string) -> '$ROM_AUTHOR'"; n=$((n + 1))
        fi
    done 3< <(awk '$1 == "PATCH" || $1 == "OVERLAY"' "$lf")

    if [[ $n -eq 0 ]]; then
        python3 "$SCRIPT_DIR/rom_branding.py" --root "$P_FS" --out "$out" --dex "${args[@]}" > "$lf.dex" 2>&1 || true
        while IFS= read -r a; do log "Branding: $a"; done < <(grep '^DEX' "$lf.dex" | head -n 20 || true)
        warn "Branding: '$BRANDING_FROM' (regex $BRANDING_MATCH) tidak ditemukan di resource APK -> tidak diganti. Baris 'DEX' di atas = teks tertanam di kode, tidak bisa lewat overlay"
    fi
}
