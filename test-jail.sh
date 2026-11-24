#!/bin/bash
# Tes jail user. Jalankan: sudo bash test-jail.sh <username>
U=${1:?Usage: $0 <username>}
env -i HOME=/home/$U PATH=/usr/bin:/bin \
  /usr/sbin/chroot --userspec="$U:$U" "/srv/jail/$U" /bin/bash -c '
  ls / && ls /home && python3 -c "import json,ssl" && git --version && nvidia-smi -L && ping -c1 -W2 127.0.0.1 >/dev/null &&
  docker ps && docker compose version && ! docker run hello-world 2>/dev/null && echo JAIL_OK'
