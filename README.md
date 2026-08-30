# Build Kernel Poco X3 NFC (surya) - KernelSU Next + SUSFS

## Isi paket
- `.github/workflows/build-kernel.yml` — workflow GitHub Actions (ubuntu-22.04)
- `build.sh` — script inti build
- `configs/perf_extra.config` — fragment config (modules, KSU, SUSFS, rename `-perf`)

## Cara pakai
1. Buat repo GitHub baru, upload semua file/folder ini (pertahankan struktur foldernya).
2. Buka tab **Actions** di repo → pilih workflow **Build Kernel (surya - perf)** →
   klik **Run workflow**.
3. Tunggu (biasanya 40 menit - 1.5 jam untuk cold build, lebih cepat kalau
   cache toolchain+source sudah kebentuk dari run sebelumnya).
4. Kalau sukses: buka run yang selesai → scroll ke **Artifacts** → download
   `kernel-surya-perf-<nomor>.zip`. Isinya `Image.gz`/`Image` + dtb.
5. Kalau gagal: download artifact `build-log` → cari baris yang mengandung
   `error:` → tempel ke saya, saya bantu iterasi fix-nya.

## Setelah build sukses: pack jadi boot.img

`Image.gz` hasil build **belum bisa langsung diflash** — perlu digabung
dengan header + ramdisk dari `boot.img` stock/TWRP-backup HP kamu.

Karena `boot.img` kamu sudah dicek dan valid (`Android bootimg, kernel
(0x8000), ramdisk (0x1000000), page size: 4096`), tinggal minta script
`pack_termux_aosp.sh` (sudah pernah dibuat sebelumnya) untuk menggabungkan
`Image.gz` baru ke header boot.img ini — hasilnya `new-boot.img` yang siap
di-`fastboot flash boot`.

**Selalu simpan boot.img stock asli sebagai jalur balik** sebelum flash apa pun.

## Catatan jujur
- SUSFS patch (`50_add_susfs_in_kernel-4.14.patch`) dipakai dengan `--fuzz=3`
  untuk memaksimalkan auto-apply, tapi source Xiaomi ini sudah banyak
  dimodifikasi dari vanilla — kemungkinan sebagian hunk gagal dan
  menghasilkan file `.rej` yang perlu ditempel manual. Cek log build untuk
  baris `!! Sebagian hunk gagal`.
- Bug `profile_judge_done` di `qpnp-qg.c` (bug bawaan source Xiaomi, bukan
  dari KSU/SUSFS) sudah dipatch otomatis dengan deteksi format yang lebih
  toleran + verifikasi. Kalau source berubah struktur lagi, script akan
  cetak peringatan, bukan diam-diam gagal.
- Config SUSFS di `perf_extra.config` mengikuti opsi yang umum tersedia di
  branch `kernel-4.14` susfs4ksu. Kalau ada opsi yang tidak dikenali saat
  `make olddefconfig` (biasanya muncul sebagai warning, bukan error), itu
  wajar — tinggal dihapus dari fragment kalau memang tidak ada di branch ini.
