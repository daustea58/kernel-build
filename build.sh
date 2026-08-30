#!/usr/bin/env bash
# =============================================================================
#  build.sh - Build kernel Poco X3 NFC (surya) + KernelSU Next + SUSFS
#  Dijalankan oleh GitHub Actions (ubuntu-22.04), tapi bisa juga dijalankan
#  lokal di WSL/Ubuntu 22.04 selama tool-tool apt di bawah sudah terinstall.
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
OUT_DIR="${KERNEL_DIR}/out"

KERNEL_REPO="https://github.com/MiCode/Xiaomi_Kernel_OpenSource"
KERNEL_BRANCH="surya-q-oss"
DEFCONFIG="vendor/atoll_defconfig"
ARCH="arm64"
KSU_NEXT_TAG="v3.3.0"
SUSFS_BRANCH="kernel-4.14"      # cocok dengan kernel 4.14.117

KERNEL_NAME="perf"              # nama samaran, biar tidak terdeteksi

echo "############################################################"
echo "#  Build kernel surya (Poco X3 NFC) - KSU Next + SUSFS      #"
echo "############################################################"

# ------------------------------------------------------------------------- #
# 1. Clone kernel source Xiaomi resmi
# ------------------------------------------------------------------------- #
if [ ! -d "${KERNEL_DIR}" ]; then
    echo "==> Clone kernel source (${KERNEL_BRANCH})"
    git clone --depth=1 -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"
fi
cd "${KERNEL_DIR}"

# ------------------------------------------------------------------------- #
# 2. Toolchain: Proton Clang + GCC arm32/aarch64 pendamping
#    (kernel 4.14 lama masih butuh binutils/gcc GNU untuk sebagian objek,
#    Proton Clang sendirian kadang kurang lengkap untuk kernel se-jadul ini)
# ------------------------------------------------------------------------- #
if [ ! -d "${CLANG_DIR}" ]; then
    echo "==> Clone Proton Clang"
    # Mirror utama kdrag0n sudah diarsipkan; gunakan fork yang masih di-mirror.
    # Kalau link ini mati, ganti dengan mirror Proton Clang lain yang aktif.
    git clone --depth=1 https://github.com/kdrag0n/proton-clang.git "${CLANG_DIR}"
fi

if [ ! -d "${GCC64_DIR}" ]; then
    echo "==> Clone GCC aarch64-linux-android-4.9 (companion GNU toolchain)"
    git clone --depth=1 -b android-9.0.0_r1 \
        https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
        "${GCC64_DIR}"
fi

if [ ! -d "${GCC32_DIR}" ]; then
    echo "==> Clone GCC arm-linux-androideabi-4.9 (companion GNU toolchain)"
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
# SUS_SU / hook lewat kprobe tidak didukung lagi untuk kernel non-GKI (4.14
# non-GKI seperti surya termasuk non-GKI), harus dimatikan manual sesuai
# panduan resmi KernelSU (how-to-integrate-for-non-gki).
grep -rl "ifdef CONFIG_KPROBES" KernelSU-Next/kernel 2>/dev/null | \
    xargs -r sed -i 's/#ifdef CONFIG_KPROBES/#if defined(CONFIG_KPROBES) \&\& 0/g'

# ------------------------------------------------------------------------- #
# 4. Integrasi SUSFS (branch kernel-4.14, paling cocok utk kernel ini)
# ------------------------------------------------------------------------- #
if [ ! -d "${SUSFS_DIR}" ]; then
    echo "==> Clone susfs4ksu (${SUSFS_BRANCH})"
    git clone --depth=1 -b "${SUSFS_BRANCH}" https://gitlab.com/simonpunk/susfs4ksu.git "${SUSFS_DIR}"
fi

echo "==> Copy SUSFS core files ke kernel tree"
cp -r "${SUSFS_DIR}"/kernel_patches/fs/*            fs/            2>/dev/null || true
cp -r "${SUSFS_DIR}"/kernel_patches/include/linux/*  include/linux/ 2>/dev/null || true

echo "==> Patch KernelSU-Next agar support SUSFS"
cp "${SUSFS_DIR}"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch KernelSU-Next/
( cd KernelSU-Next && patch -p1 --fuzz=3 < 10_enable_susfs_for_ksu.patch ) \
    || echo "!! Sebagian hunk gagal - cek KernelSU-Next/*.rej dan tempel manual"

echo "==> Patch kernel utama dengan SUSFS 50_add_susfs_in_kernel-4.14.patch"
PATCH_FILE=$(ls "${SUSFS_DIR}"/kernel_patches/50_add_susfs_in_kernel-*.patch | head -n1)
cp "${PATCH_FILE}" .
patch -p1 --fuzz=3 < "$(basename "${PATCH_FILE}")" \
    || echo "!! Sebagian hunk gagal - cek *.rej di root kernel dan tempel manual"

# ------------------------------------------------------------------------- #
# 5. Rename kernel jadi "perf" - bersihkan penanda dirty/hash/KernelSU
# ------------------------------------------------------------------------- #
echo "==> Samarkan versi kernel jadi '${KERNEL_NAME}'"
# scripts/setlocalversion normalnya nambahin -dirty / git hash / +.
# Kita paksa kosong supaya string final murni dari CONFIG_LOCALVERSION saja.
cat > scripts/setlocalversion <<'EOF'
#!/bin/sh
echo ""
EOF
chmod +x scripts/setlocalversion

# KernelSU-Next biasanya menyisipkan string versinya sendiri ke dalam
# uname/banner lewat file version-nya. Cek dan ganti manual kalau ketemu -
# grep ini WAJIB dicek hasilnya di log Actions, karena lokasi persisnya bisa
# beda tergantung commit KernelSU-Next yang ke-pull.
echo "==> Cek string 'KernelSU' yang mungkin nongol di versi/banner:"
grep -rIn "KernelSU" --include="*.c" --include="*.h" init/ kernel/ 2>/dev/null || true
echo "    (kalau ada match di atas & itu string yang ke-embed ke uname/proc/version,"
echo "     ganti manual jadi string netral sebelum lanjut build)"

# Terapkan config fragment (module opts, KSU, SUSFS, LOCALVERSION=-perf)
CONFIG_FRAGMENT="${WORKSPACE}/configs/perf_extra.config"

# ------------------------------------------------------------------------- #
# 6. FIX known build errors di Ubuntu 22.04 / GCC 11+ / Clang baru
# ------------------------------------------------------------------------- #
# (a) "multiple definition of yylloc" / error linking scripts/dtc & kconfig
#     -> GCC 10+ default ke -fno-common, sedangkan kernel lawas masih
#        mengandalkan tentative definition (implicit -fcommon). Fix resminya
#        ya pass -fcommon ke HOSTCFLAGS saat compile host tools.
#
# (b) Clang melempar error "unknown argument" untuk flag ala-GCC yang di-pass
#     Makefile lama (mis. -fno-var-tracking-assignments) -> tambahkan
#     -Qunused-arguments supaya clang diam soal argumen yang gak dikenal
#     alih-alih hard fail.
#
# (c) Werror storm dari cc-option check yang salah deteksi versi compiler
#     -> matikan werror global lewat KCFLAGS.
#
export HOSTCFLAGS="-fcommon"
export KCFLAGS="-Wno-error -Qunused-arguments"

MAKE_ARGS=(
    ARCH=${ARCH}
    O=out
    CC=clang
    HOSTCC=gcc
    HOSTCXX=g++
    CLANG_TRIPLE=${CLANG_TRIPLE}
    CROSS_COMPILE=${CROSS_COMPILE}
    CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32}
    HOSTCFLAGS="${HOSTCFLAGS}"
    KCFLAGS="${KCFLAGS}"
    -j"$(nproc --all)"
)

# ------------------------------------------------------------------------- #
# 7. Generate defconfig + merge fragment
# ------------------------------------------------------------------------- #
echo "==> make ${DEFCONFIG}"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

echo "==> Merge config fragment (perf_extra.config)"
./scripts/kconfig/merge_config.sh -O out -m out/.config "${CONFIG_FRAGMENT}"
make "${MAKE_ARGS[@]}" olddefconfig

# ------------------------------------------------------------------------- #
# 8. Build
# ------------------------------------------------------------------------- #
echo "==> Build kernel"
make "${MAKE_ARGS[@]}" 2>&1 | tee "${WORKSPACE}/build.log"

# ------------------------------------------------------------------------- #
# 9. Kumpulkan hasil
# ------------------------------------------------------------------------- #
mkdir -p "${WORKSPACE}/artifacts"
find out/arch/${ARCH}/boot -maxdepth 1 -type f \( -name "Image*" -o -name "dtb*" \) \
    -exec cp {} "${WORKSPACE}/artifacts/" \;

echo "==> Selesai. Cek folder artifacts/ dan build.log kalau ada yang gagal."
