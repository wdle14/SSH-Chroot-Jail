# SSH Chroot Jail per User

Mengurung user SSH di chroot `/srv/jail/<username>`. User hanya bisa memakai perintah dasar, python3, git, nvidia-smi, dan docker terbatas.

## Pemakaian

```bash
sudo bash jail-user.sh <username>   # buat/perbarui jail
sudo bash test-jail.sh <username>         # tes, harus keluar JAIL_OK
```

User harus sudah ada di sistem. Script aman dijalankan ulang (setelah upgrade driver NVIDIA, tambah GPU, atau update paket).

## Yang dilakukan `jail-user.sh`

1. Mengeluarkan user dari grup `docker` (akses grup docker setara root).
2. Membuat jail di `/srv/jail/<username>`, milik root. Satu-satunya folder yang bisa ditulisi user adalah `/home/<username>` asli, di-bind lewat `/etc/fstab`.
3. Menyalin binary dan library: `bash ls cat cp mv rm mkdir rmdir touch nano vi less grep id clear python3 git nvidia-smi ping`, stdlib python3, helper git, sertifikat SSL, dan file DNS.
4. Membuat wrapper `docker` yang hanya mengizinkan `ps start stop compose build`.
5. Membuat device minimal (`null zero tty urandom`) dan device GPU NVIDIA.
6. Membuat `passwd`/`group` yang hanya berisi user itu.
7. Menambah blok `Match User` + `ChrootDirectory` ke `/etc/ssh/sshd_config` (file lama di-backup ke `sshd_config.bak.<timestamp>`), lalu reload ssh.
8. Menutup sesi SSH lama user.
9. Memasang Docker rootless untuk user (daemon jalan sebagai user itu, socket di `~/.docker-run/docker.sock`).
10. Mencabut izin baca "others" dari home user lain (`chmod o-rwx`), supaya tidak bisa dibaca lewat bind-mount container.
11. Self-check di dalam jail.

## Catatan keamanan

- Whitelist docker hanya di level CLI, **bukan batas keamanan**. `docker compose` dan `docker build` tetap bisa menjalankan container dengan bind-mount. Yang membatasi adalah Docker rootless: container hanya punya hak sebatas user itu.
- Langkah 10 mengubah izin **semua** home user lain di `/home`.
- Script mengubah `/etc/fstab` dan `/etc/ssh/sshd_config`. Cek kedua file setelah dijalankan.

## Membatalkan jail

1. Hapus blok `Match User <username>` dari `/etc/ssh/sshd_config`, lalu `sudo systemctl reload ssh`.
2. Hapus baris bind `/srv/jail/<username>/home/<username>` dari `/etc/fstab`, lalu `sudo umount /srv/jail/<username>/home/<username>`.
3. Setelah umount berhasil, baru hapus folder jail: `sudo rm -rf /srv/jail/<username>`. Jangan hapus sebelum umount, karena home asli user ikut terhapus.
