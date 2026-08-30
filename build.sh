#!/usr/bin/env bash
# =============================================================================
#  build.sh - Build kernel Poco X3 NFC (surya) + KernelSU Next + SUSFS
#  Base   : Xiaomi_Kernel_OpenSource, branch surya-q-oss (Android 10, 4.14.117)
#  Target : GitHub Actions ubuntu-22.04 (bisa juga jalan di WSL/Ubuntu 22.04)
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------------------- #
# 0. Variabel
# ------------------------------------------------------------------------- #
WORKSPACE="$(pwd)"
KERNEL_DIR="${WORKSPACE}/kernel"
CLANG_DIR="${WORKSPACE}/clang"
GCC64_DIR="${WORKSPACE}/gcc64"
GCC32_DIR="${WORKSPACE}/gcc32"
SUSFS_DIR="${WORKSPACE}/susfs4ksu"

KERNEL_REPO="https://github.com/MiCode/Xiaomi_Kernel_OpenSource"
KERNEL_BRANCH="surya-q-oss"
DEFCONFIG="vendor/atoll_defconfig"
ARCH="arm64"
KSU_NEXT_TAG="v3.3.0"
SUSFS_BRANCH="kernel-4.14"
KERNEL_NAME="perf"

echo "############################################################"
echo "#  Build kernel surya (Poco X3 NFC) - KSU Next + SUSFS      #"
echo "############################################################"

# ------------------------------------------------------------------------- #
# 1. Clone kernel source
# ------------------------------------------------------------------------- #
if [ ! -d "${KERNEL_DIR}/.git" ]; then
    echo "==> Clone kernel source (${KERNEL_BRANCH})"
    git clone --depth=1 -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"
else
    echo "==> Kernel source sudah ada (cache), skip clone."
fi
cd "${KERNEL_DIR}"

# ------------------------------------------------------------------------- #
# 2. Toolchain: Proton Clang + GCC 4.9 arm32/aarch64 pendamping
# ------------------------------------------------------------------------- #
if [ ! -d "${CLANG_DIR}" ]; then
    echo "==> Clone Proton Clang"
    git clone --depth=1 https://github.com/kdrag0n/proton-clang.git "${CLANG_DIR}"
fi

if [ ! -d "${GCC64_DIR}" ]; then
    echo "==> Clone GCC aarch64-linux-android-4.9"
    git clone --depth=1 -b android-9.0.0_r1 \
        https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
        "${GCC64_DIR}"
fi

if [ ! -d "${GCC32_DIR}" ]; then
    echo "==> Clone GCC arm-linux-androideabi-4.9"
    git clone --depth=1 -b android-9.0.0_r1 \
        https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
        "${GCC32_DIR}"
fi

export PATH="${CLANG_DIR}/bin:${PATH}"
export CROSS_COMPILE="${GCC64_DIR}/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="${GCC32_DIR}/bin/arm-linux-androideabi-"
export CLANG_TRIPLE="aarch64-linux-gnu-"

# ------------------------------------------------------------------------- #
# 3. Integrasi KernelSU Next
# ------------------------------------------------------------------------- #
if [ ! -d "KernelSU-Next" ]; then
    echo "==> Setup KernelSU Next ${KSU_NEXT_TAG}"
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
        | bash -s "${KSU_NEXT_TAG}"
fi

echo "==> Non-GKI fix: matikan kprobe hook di KernelSU-Next"
grep -rl "ifdef CONFIG_KPROBES" KernelSU-Next/kernel 2>/dev/null | \
    xargs -r sed -i 's/#ifdef CONFIG_KPROBES/#if defined(CONFIG_KPROBES) \&\& 0/g' || true

# ------------------------------------------------------------------------- #
# 4. Integrasi SUSFS (branch kernel-4.14) - versi "latest" di branch itu
# ------------------------------------------------------------------------- #
if [ ! -d "${SUSFS_DIR}" ]; then
    echo "==> Clone susfs4ksu (${SUSFS_BRANCH})"
    git clone --depth=1 -b "${SUSFS_BRANCH}" https://gitlab.com/simonpunk/susfs4ksu.git "${SUSFS_DIR}"
else
    echo "==> susfs4ksu sudah ada (cache) -- fetch update supaya tetap 'latest'"
    ( cd "${SUSFS_DIR}" && git fetch origin "${SUSFS_BRANCH}" && git reset --hard "origin/${SUSFS_BRANCH}" ) || true
fi

echo "==> Copy SUSFS core files ke kernel tree"
cp -r "${SUSFS_DIR}"/kernel_patches/fs/*             fs/            2>/dev/null || true
cp -r "${SUSFS_DIR}"/kernel_patches/include/linux/*  include/linux/ 2>/dev/null || true

echo "==> Patch KernelSU-Next agar support SUSFS"
if [ -f "${SUSFS_DIR}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
    cp "${SUSFS_DIR}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" KernelSU-Next/
    ( cd KernelSU-Next && patch -p1 --fuzz=3 --forward < 10_enable_susfs_for_ksu.patch ) \
        || echo "!! Sebagian hunk gagal - cek KernelSU-Next/*.rej dan tempel manual"
else
    echo "!! Patch enable_susfs_for_ksu tidak ditemukan di susfs4ksu, cek versi branch"
fi

echo "==> Patch kernel utama dengan SUSFS 50_add_susfs_in_kernel-4.14.patch"
PATCH_FILE=$(ls "${SUSFS_DIR}"/kernel_patches/50_add_susfs_in_kernel-*.patch 2>/dev/null | head -n1 || true)
if [ -n "${PATCH_FILE}" ]; then
    cp "${PATCH_FILE}" .
    patch -p1 --fuzz=3 --forward < "$(basename "${PATCH_FILE}")" \
        || echo "!! Sebagian hunk gagal - cek *.rej di root kernel dan tempel manual"
else
    echo "!! File patch 50_add_susfs_in_kernel-4.14.patch tidak ditemukan"
fi

# ------------------------------------------------------------------------- #
# 5. Rename kernel jadi "perf"
# ------------------------------------------------------------------------- #
echo "==> Samarkan versi kernel jadi '${KERNEL_NAME}'"
cat > scripts/setlocalversion <<'EOF'
#!/bin/sh
echo ""
EOF
chmod +x scripts/setlocalversion

echo "==> Cek string 'KernelSU' yang mungkin nongol di versi/banner (info saja):"
grep -rIn "KernelSU" --include="*.c" --include="*.h" init/ kernel/ 2>/dev/null || true

CONFIG_FRAGMENT="${WORKSPACE}/configs/perf_extra.config"

# ------------------------------------------------------------------------- #
# 6. Fix bug bawaan source Xiaomi: struct qpnp_qg kurang field
#    profile_judge_done. Pencarian toleran-format + verifikasi + fail-loudly
#    supaya kalau gagal, ketahuan di step ini, bukan menyamar jadi error
#    compile ribuan baris kemudian.
# ------------------------------------------------------------------------- #
echo "==> Fix bug source Xiaomi: struct qpnp_qg kurang field 'profile_judge_done'"

mapfile -t QG_CANDIDATES < <(grep -rlE "struct[[:space:]]+qpnp_qg([[:space:]]*\{)?[[:space:]]*$" \
    --include="*.c" --include="*.h" . 2>/dev/null)

if [ "${#QG_CANDIDATES[@]}" -eq 0 ]; then
    echo "    Tidak ketemu 'struct qpnp_qg' -- kemungkinan device/branch ini tidak"
    echo "    pakai driver qpnp-qg, atau strukturnya sudah beda. Lanjut build;"
    echo "    kalau error ini muncul lagi nanti di compile, kita cek manual."
else
    echo "    Kandidat file (${#QG_CANDIDATES[@]}):"
    printf '      - %s\n' "${QG_CANDIDATES[@]}"

    PATCHED_ANY=0
    for QG_FILE in "${QG_CANDIDATES[@]}"; do
        if grep -q "profile_judge_done" "${QG_FILE}"; then
            echo "    -> ${QG_FILE}: sudah ada, skip."
            PATCHED_ANY=1
            continue
        fi
        if grep -qE "struct[[:space:]]+qpnp_qg[[:space:]]*\{" "${QG_FILE}"; then
            sed -i -E '/struct[[:space:]]+qpnp_qg[[:space:]]*\{/a\	bool			profile_judge_done;' "${QG_FILE}"
        elif grep -qE "struct[[:space:]]+qpnp_qg[[:space:]]*$" "${QG_FILE}"; then
            sed -i -E '/struct[[:space:]]+qpnp_qg[[:space:]]*$/{n; /^[[:space:]]*\{/a\	bool			profile_judge_done;
            }' "${QG_FILE}"
        else
            continue
        fi
        if grep -q "profile_judge_done" "${QG_FILE}"; then
            echo "    -> ${QG_FILE}: berhasil dipatch (terverifikasi)."
            PATCHED_ANY=1
        else
            echo "    -> ${QG_FILE}: !! sed gagal, field masih tidak ada."
        fi
    done

    if [ "${PATCHED_ANY}" -eq 0 ]; then
        echo "    !! Ada kandidat tapi tidak satupun berhasil dipatch -- cek manual."
    fi
fi

# ------------------------------------------------------------------------- #
# 7. Fix known build errors di Ubuntu 22.04 / GCC 11+ / Clang baru
# ------------------------------------------------------------------------- #
# (a) yylloc / -fno-common default GCC 10+  -> -fcommon di HOSTCFLAGS
# (b) Clang menolak flag ala-GCC yang tidak dikenal -> -Qunused-arguments
# (c) Werror storm dari cc-option check salah deteksi -> matikan lewat KCFLAGS
# (d) Mismatch -fstack-protector-strong antara Clang & GCC lawas -> paksa
#     satu varian yang didukung dua-duanya
export HOSTCFLAGS="-fcommon"
export HOSTCXXFLAGS="-fcommon"
export KCFLAGS="-Wno-error -Qunused-arguments -Wno-unused-command-line-argument -fcommon"

MAKE_ARGS=(
    ARCH="${ARCH}"
    O=out
    CC=clang
    HOSTCC=gcc
    HOSTCXX=g++
    CLANG_TRIPLE="${CLANG_TRIPLE}"
    CROSS_COMPILE="${CROSS_COMPILE}"
    CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    HOSTCFLAGS="${HOSTCFLAGS}"
    HOSTCXXFLAGS="${HOSTCXXFLAGS}"
    KCFLAGS="${KCFLAGS}"
    CONFIG_CC_STACKPROTECTOR_STRONG=y
    -j"$(nproc --all)"
)

# ------------------------------------------------------------------------- #
# 8. Generate defconfig + merge fragment
# ------------------------------------------------------------------------- #
echo "==> make ${DEFCONFIG}"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

echo "==> Merge config fragment (perf_extra.config)"
./scripts/kconfig/merge_config.sh -O out -m out/.config "${CONFIG_FRAGMENT}"
make "${MAKE_ARGS[@]}" olddefconfig

# ------------------------------------------------------------------------- #
# 9. Build
# ------------------------------------------------------------------------- #
echo "==> Build kernel"
make "${MAKE_ARGS[@]}" 2>&1 | tee "${WORKSPACE}/build.log"

# ------------------------------------------------------------------------- #
# 10. Kumpulkan hasil
# ------------------------------------------------------------------------- #
mkdir -p "${WORKSPACE}/artifacts"
find out/arch/"${ARCH}"/boot -maxdepth 1 -type f \( -name "Image*" -o -name "dtb*" \) \
    -exec cp {} "${WORKSPACE}/artifacts/" \;

echo "==> Selesai. Cek folder artifacts/ dan build.log kalau ada yang gagal."
