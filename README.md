# Build Kernel Poco X3 NFC (surya) - KernelSU Next + SUSFS

## Struktur

```
.
├── .github/workflows/build-kernel.yml   # workflow GitHub Actions
├── build.sh                             # script build utama (dipanggil workflow)
├── configs/perf_extra.config            # config fragment (KSU/SUSFS/modules/rename)
└── README.md
```

## Cara pakai

1. Push 3 file ini (`build.sh`, `configs/perf_extra.config`,
   `.github/workflows/build-kernel.yml`) ke repo GitHub baru (tidak perlu
   berisi source kernel — `build.sh` yang akan clone semuanya saat runtime).
2. Buka tab **Actions** → pilih workflow **"Build Kernel Surya"** →
   **Run workflow**.
3. Setelah selesai, unduh artifact `kernel-surya-perf-<run_number>` (berisi
   `Image`/`Image.gz` + dtb) dan `build-log` (log lengkap, penting kalau
   ada yang gagal).
4. `Image`/`Image.gz` + dtb itu masih perlu di-pack jadi `boot.img` pakai
   `mkbootimg` + boot image header device kamu (ambil dari stock
   boot.img via `unpack_bootimg`) — script ini sengaja tidak melakukan
   packing karena butuh base header/cmdline device kamu sendiri.

## Kenapa hasilnya belum pasti 100% mulus

Kernel Xiaomi/Poco itu sangat spesifik per-commit, dan KernelSU Next serta
SUSFS terus di-update oleh maintainernya masing-masing (nama config,
struktur patch, dsb bisa berubah). Saya sudah masukkan fix-fix yang **paling
umum** terjadi untuk kombinasi *kernel lawas (4.14) + Ubuntu 22.04 + Clang
baru*, tapi kalau muncul error lain, tinggal copy potongan `build.log` yang
relevan (bagian error, bukan seluruh log) dan saya bantu iterasi.

## Penjelasan fix-fix yang sudah dimasukkan

### 1. `yylloc` / "multiple definition" saat compile host tools (scripts/dtc, kconfig)
Ini bug klasik kernel lawas di toolchain modern: sejak GCC 10, default
berubah dari `-fcommon` ke `-fno-common`. Kode lama di `scripts/dtc` dan
sejenisnya menulis *tentative definition* global (`YYLTYPE yylloc;` tanpa
`extern`) yang di GCC 9 ke bawah dianggap wajar (auto-merge multi-file),
tapi di GCC 10+ dianggap "multiple definition" kalau muncul di lebih dari
satu object file. Fix: pass `-fcommon` lewat `HOSTCFLAGS` saat build host
tools — sudah di-set di `build.sh`.

### 2. Clang menolak flag ala-GCC dari Makefile lama
Sebagian Makefile kernel 4.14 masih menyisipkan flag khusus GCC (misalnya
terkait var-tracking) yang tidak dikenal Clang. Kalau tidak ditangani, Clang
akan `error: unknown argument`. Fix: tambahkan `-Qunused-arguments` supaya
Clang cuma warning, bukan hard error, untuk argumen yang tidak dikenalnya.

### 3. `-Werror` storm dari cc-option check yang salah deteksi compiler
Beberapa Makefile mengetes fitur compiler dengan cara yang asumsinya GCC,
dan hasil deteksinya suka salah kalau compiler-nya Clang → berujung warning
yang di-treat sebagai error. Fix: `KCFLAGS="-Wno-error"`.

### 4. Toolchain: kenapa masih perlu GCC selain Proton Clang
Proton Clang punya `clang` + `lld` + `binutils` sendiri, tapi kernel 4.14
non-GKI sejadul surya kadang masih butuh assembler/linker GNU asli untuk
sebagian objek arm32 (`CROSS_COMPILE_ARM32`). Karena itu `build.sh` juga
clone GCC 4.9 aarch64 & arm32 dari AOSP sebagai companion toolchain,
persis pola yang dipakai kebanyakan build script custom kernel era Android
9/10.

### 5. Integrasi KernelSU Next untuk kernel non-GKI
Sejak versi tertentu, fitur `sus_su` berbasis kprobe **tidak didukung lagi**
untuk kernel non-GKI (surya termasuk non-GKI). `build.sh` otomatis
mengganti semua `#ifdef CONFIG_KPROBES` di source KernelSU-Next jadi
`#if defined(CONFIG_KPROBES) && 0` supaya KSU tidak mencoba pakai kprobe
hook — ini sesuai panduan resmi KernelSU untuk non-GKI.

### 6. SUSFS — pilih branch yang cocok versi kernel
`susfs4ksu` (maintained di GitLab oleh simonpunk, di-mirror ke banyak fork
GitHub) punya branch terpisah per versi kernel: `kernel-4.14`,
`kernel-4.19`, `kernel-5.4`, `kernel-5.10`, dst. Karena target kamu
`4.14.117`, script pakai branch `kernel-4.14`. **Ini titik paling rawan gagal
patch** karena source Xiaomi ini sudah dimodifikasi cukup jauh dari vanilla
4.14 — kalau `patch` gagal sebagian (`.rej` files), itu normal untuk fork
custom dan perlu ditempel manual satu-satu.

### 7. Rename kernel jadi "perf"
Dua bagian:
- `CONFIG_LOCALVERSION="-perf"` di config fragment.
- `scripts/setlocalversion` dipaksa selalu return string kosong, supaya
  tidak ada suffix git-hash/`-dirty` otomatis yang nempel. Hasil akhir
  `uname -r` jadi bersih: `4.14.117-perf`.

Yang **tidak** saya otomatisasi: kalau KernelSU-Next versi yang ke-*pull*
menyisipkan string "KernelSU" langsung ke banner/`/proc/version` di file
sumbernya sendiri (bukan lewat `setlocalversion`), itu perlu dicek manual —
`build.sh` sudah menjalankan `grep -rn "KernelSU"` di `init/` dan `kernel/`
dan mencetak hasilnya di log supaya kamu bisa lihat dan sunting sendiri
kalau memang ketemu.

## Kalau build gagal

1. Buka artifact `build-log`, cari baris yang mengandung `error:` (bukan
   `warning:`).
2. Kalau errornya soal patch SUSFS gagal apply (`.rej` files) — itu paling
   sering karena source Xiaomi sudah beda struktur dari vanilla 4.14, harus
   ditempel manual mengikuti isi file `.rej`.
3. Kalau errornya soal compiler/linker baru yang belum ke-cover fix di atas
   — tempel potongan error-nya, saya bantu cari fix spesifiknya.
   
