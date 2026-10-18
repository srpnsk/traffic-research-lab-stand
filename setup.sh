#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Проверка rootless Docker"
sudo machinectl shell dockerroot@.host /bin/bash -lc '
    export HOME=/home/dockerroot
    export PATH="/home/dockerroot/bin:/usr/bin:/bin:$PATH"
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
    systemctl --user is-active docker
    docker info
'

echo "==> Настройка системных компонентов"
sudo "$ROOT/10-configure-host.sh"

echo "==> Сборка и настройка лаборатории"
sudo machinectl shell dockerroot@.host /bin/bash -lc \
    'cd /srv/network-lab/project && ./build-lab.sh'

echo "==> Проверка результата"
sudo machinectl shell dockerroot@.host /bin/bash -lc '
    export HOME=/home/dockerroot
    export PATH="/home/dockerroot/bin:/usr/bin:/bin:$PATH"
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
    docker ps --format "table {{.Names}}\t{{.Status}}"
'

echo "==> Настройка завершена"
