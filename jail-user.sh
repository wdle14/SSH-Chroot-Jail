#!/bin/bash
# Chroot jail SSH per user. Jalankan: sudo bash $0 <username>
set -euo pipefail
U=${1:?Usage: $0 <username>}
# Nama user masuk ke fstab, sshd_config, regex grep: tolak karakter aneh + user harus ada
[[ $U =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Username tidak valid: $U" >&2; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "User tidak ada: $U" >&2; exit 1; }
J=/srv/jail/$U
CMDS="bash ls cat cp mv rm mkdir rmdir touch nano vi less grep id clear python3 git nvidia-smi ping"

# 1. Cabut akses docker (docker = root)
gpasswd -d "$U" docker 2>/dev/null || true

# 2. Struktur jail (root jail wajib milik root, tidak writable user)
mkdir -p "$J"/{dev,etc,home/$U,usr/bin}
chown root:root "$J"; chmod 755 "$J"
# Host pakai merged-/usr (/bin -> usr/bin). Shell user = /bin/bash, jadi jail butuh link yang sama.
[ -e "$J/bin" ] || ln -s usr/bin "$J/bin"

# Satu-satunya folder writable: /home/$U asli, di-bind ke dalam jail
grep -q " $J/home/$U " /etc/fstab || echo "/home/$U $J/home/$U none bind 0 0" >> /etc/fstab
mountpoint -q "$J/home/$U" || mount "$J/home/$U"

# 3. Binary + library
for c in $CMDS; do
  p=$(command -v "$c" || true); [ -n "$p" ] || continue
  cp --remove-destination --parents -L "$p" "$J"
  ldd "$p" | grep -o '/[^ ]*' | while read -r l; do cp --remove-destination --parents -L "$l" "$J"; done
done
for t in /lib/terminfo /usr/share/terminfo; do [ -d "$t" ] && cp -r --parents "$t" "$J"; done

# python3 stdlib + git helper (git-remote-https dll) + libs-nya
PYLIB=$(python3 -c 'import sysconfig;print(sysconfig.get_paths()["stdlib"])')
GITX=$(git --exec-path)
for d in "$PYLIB" "$GITX" /usr/share/git-core /etc/ssl/certs; do
  [ -d "$d" ] && cp -a --remove-destination --parents "$d" "$J"
done
find "$GITX" "$PYLIB" -type f \( -perm -u+x -o -name '*.so' \) -exec ldd {} \; 2>/dev/null \
  | grep -o '/[^ ]*' | sort -u | while read -r l; do [ -e "$l" ] && cp --remove-destination --parents -L "$l" "$J"; done

# DNS untuk git clone/pull via https
cp /etc/{resolv.conf,hosts,nsswitch.conf} "$J/etc/"
for l in /lib/x86_64-linux-gnu/libnss_{dns,files}.so.* /lib/x86_64-linux-gnu/libresolv.so.*; do
  [ -e "$l" ] && cp --remove-destination --parents -L "$l" "$J"
done

# Docker CLI + plugin (compose, buildx). Binary asli disembunyikan, "docker" = wrapper whitelist.
mkdir -p "$J/usr/libexec/docker"
cp -a --remove-destination --parents /usr/libexec/docker/cli-plugins "$J"
cp --remove-destination -L /usr/bin/docker "$J/usr/libexec/docker/docker-real"
for p in /usr/bin/docker /usr/libexec/docker/cli-plugins/*; do
  # docker-buildx binary statis: grep kosong -> exit 1 -> set -e mati. Makanya "|| true".
  { ldd "$p" 2>/dev/null | grep -o '/[^ ]*' || true; } | while read -r l; do [ -e "$l" ] && cp --remove-destination --parents -L "$l" "$J" || true; done
done
cat > "$J/usr/bin/docker" <<EOF
#!/bin/bash
# ponytail: whitelist level CLI saja, bukan batas keamanan (lihat catatan rootless)
export DOCKER_HOST=unix:///home/$U/.docker-run/docker.sock TMPDIR=\$HOME/.tmp
mkdir -p "\$TMPDIR"
case "\$1" in ps|start|stop|compose|build) exec /usr/libexec/docker/docker-real "\$@";; esac
echo "docker \$1: tidak diizinkan (hanya: ps start stop compose build)" >&2; exit 1
EOF
chmod 755 "$J/usr/bin/docker"

# 4. Device minimal
for d in "null c 1 3" "zero c 1 5" "tty c 5 0" "urandom c 1 9"; do
  set -- $d; [ -e "$J/dev/$1" ] || mknod -m 666 "$J/dev/$1" "$2" "$3" "$4"
done

# nvidia-smi: library NVML (di-dlopen, tidak terlihat di ldd) + device GPU.
# ponytail: salinan statis. Upgrade driver / tambah GPU -> jalankan ulang script ini.
cp --remove-destination --parents -L /lib/x86_64-linux-gnu/libnvidia-ml.so.1 "$J"
for d in /dev/nvidiactl /dev/nvidia[0-9]*; do [ -e "$J$d" ] || cp -a "$d" "$J/dev/"; done

# 5. passwd/group minimal (tanpa info user lain)
grep "^$U:" /etc/passwd > "$J/etc/passwd"
grep "^$U:" /etc/group  > "$J/etc/group"

# 6. sshd config (backup dulu)
if ! grep -q "Match User $U" /etc/ssh/sshd_config; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
  cat >> /etc/ssh/sshd_config <<EOF

Match User $U
    ChrootDirectory $J
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
fi
sshd -t && systemctl reload ssh

# 7. Tutup sesi SSH lama user (jangan bunuh daemon docker rootless)
pkill -u "$U" sshd || true

# 8. Docker rootless: daemon jalan sebagai $U (bukan root), di luar jail.
#    Socket ditaruh di home supaya kelihatan dari dalam jail.
UID_U=$(id -u "$U")
command -v newuidmap >/dev/null || apt-get install -y uidmap
loginctl enable-linger "$U"
systemctl start "user@$UID_U"
AS_U="sudo -u $U HOME=/home/$U XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus"
$AS_U bash -c 'cd ~; [ -f ~/.config/systemd/user/docker.service ] || dockerd-rootless-setuptool.sh install'
$AS_U bash -c "mkdir -p ~/.config/docker ~/.docker-run
  echo '{\"hosts\":[\"unix:///home/$U/.docker-run/docker.sock\"]}' > ~/.config/docker/daemon.json
  systemctl --user restart docker"
sleep 3

# 9. Tutup kebocoran baca lewat bind-mount container: home user lain jangan world-readable
for h in /home/*; do [ "$h" = "/home/$U" ] || chmod o-rwx "$h"; done

# Self-check: harus cuma lihat isi jail, docker jalan, perintah lain ditolak
env -i HOME=/home/$U PATH=/usr/bin:/bin /usr/sbin/chroot --userspec="$U:$U" "$J" /bin/bash -c '
  ls / && ls /home && python3 -c "import json,ssl" && git --version &&
  docker ps && docker compose version && ! docker run hello-world 2>/dev/null && echo JAIL_OK'
