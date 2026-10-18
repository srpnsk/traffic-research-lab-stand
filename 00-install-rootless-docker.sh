#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт через sudo." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Не удалось определить операционную систему." >&2
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "Этот сценарий рассчитан на Ubuntu 24.04." >&2
    exit 1
fi

DOCKER_USER="dockerroot"
DOCKER_HOME="/home/$DOCKER_USER"
SUBUID_START=100000
SUBUID_END=165535
SUBID_COUNT=$((SUBUID_END - SUBUID_START + 1))

echo "==> Устанавливаем необходимые системные пакеты"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
    systemd-container \
    apparmor \
    curl \
    ca-certificates

echo "==> Создаём пользователя, если его ещё нет"
if ! id "$DOCKER_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$DOCKER_USER"
    passwd --lock "$DOCKER_USER"
else
    echo "Пользователь $DOCKER_USER уже существует."
fi

DOCKER_UID="$(id -u "$DOCKER_USER")"

# Не перезаписываем существующие диапазоны.
# Если записи есть, проверяем, что их суммарно достаточно.
for mapping_file in /etc/subuid /etc/subgid; do
    touch "$mapping_file"
    if ! awk -F: -v u="$DOCKER_USER" \
        '$1 == u { found=1; total += $3 }
         END { exit !(found && total >= 65536) }' "$mapping_file"; then

        if grep -qE '^[^:]+:[0-9]+:[0-9]+$' "$mapping_file" &&
            awk -F: -v s="$SUBUID_START" -v e="$SUBUID_END" \
                '$2 <= e && ($2 + $3 - 1) >= s { conflict=1 }
              END { exit !conflict }' "$mapping_file"; then
            echo "Диапазон $SUBUID_START-$SUBUID_END уже пересекается" \
                "с записью в $mapping_file." >&2
            echo "Не меняю диапазоны автоматически." >&2
            exit 1
        fi

        usermod \
            "$([[ "$mapping_file" == /etc/subuid ]] && echo --add-subuids || echo --add-subgids)" \
            "$SUBUID_START-$SUBUID_END" \
            "$DOCKER_USER"
    fi
done

echo "==> Проверяем диапазоны UID/GID"
grep "^${DOCKER_USER}:" /etc/subuid
grep "^${DOCKER_USER}:" /etc/subgid

if ! awk -F: -v u="$DOCKER_USER" \
    '$1 == u { total += $3 } END { exit !(total >= 65536) }' /etc/subuid ||
    ! awk -F: -v u="$DOCKER_USER" \
        '$1 == u { total += $3 } END { exit !(total >= 65536) }' /etc/subgid; then
    echo "Для Rootless Docker нужно не менее 65536 UID и GID." >&2
    exit 1
fi

echo "==> Включаем пользовательскую службу после перезагрузки"
loginctl enable-linger "$DOCKER_USER"

# Ubuntu 24.04 ограничивает создание непривилегированных user namespaces.
# Добавляем профиль только для rootlesskit в домашнем каталоге dockerroot.
# Это не отключает ограничение глобально для всей системы.
APPARMOR_PROFILE="/etc/apparmor.d/home.dockerroot.bin.rootlesskit"

if [[ ! -e "$APPARMOR_PROFILE" ]]; then
    cat >"$APPARMOR_PROFILE" <<'EOF'
abi <abi/4.0>,
include <tunables/global>

/home/dockerroot/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/home.dockerroot.bin.rootlesskit>
}
EOF

    apparmor_parser -r "$APPARMOR_PROFILE"
else
    echo "Профиль AppArmor уже существует — оставляем его без изменений."
fi

echo "==> Настраиваем systemd delegation"
install -d -m 755 \
    "/etc/systemd/system/user@${DOCKER_UID}.service.d"

DELEGATE_FILE="/etc/systemd/system/user@${DOCKER_UID}.service.d/delegate.conf"

if [[ ! -e "$DELEGATE_FILE" ]]; then
    cat >"$DELEGATE_FILE" <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
fi

systemctl daemon-reload

echo "==> Настраиваем окружение dockerroot"
# Здесь DOCKER_HOST задаётся конкретным UID, а не командной подстановкой
# внутри одинарных кавычек в .bashrc.
BASHRC="$DOCKER_HOME/.bashrc"
touch "$BASHRC"
chown "$DOCKER_USER:$DOCKER_USER" "$BASHRC"

add_bashrc_line() {
    local line="$1"
    grep -Fqx "$line" "$BASHRC" || printf '%s\n' "$line" >>"$BASHRC"
}

add_bashrc_line 'export PATH="/home/dockerroot/bin:/usr/bin:/bin:$PATH"'
add_bashrc_line "export DOCKER_HOST=\"unix:///run/user/${DOCKER_UID}/docker.sock\""

echo "==> Устанавливаем Rootless Docker в сеансе machinectl"
# Запускаем установку именно в пользовательском сеансе systemd.
machinectl shell "${DOCKER_USER}@.host" /bin/bash -lc '
    set -Eeuo pipefail
    export HOME=/home/dockerroot
    export USER=dockerroot
    export LOGNAME=dockerroot
    export PATH="/home/dockerroot/bin:/usr/bin:/bin:$PATH"

    if command -v dockerd-rootless.sh >/dev/null 2>&1 &&
       systemctl --user cat docker.service >/dev/null 2>&1; then
        echo "Rootless Docker уже настроен; повторную установку пропускаем."
    else
        curl -fsSL https://get.docker.com/rootless | sh
    fi
'

echo "==> Запускаем пользовательскую службу Docker"
machinectl shell "${DOCKER_USER}@.host" /bin/bash -lc '
    set -Eeuo pipefail
    export HOME=/home/dockerroot
    export USER=dockerroot
    export LOGNAME=dockerroot
    export PATH="/home/dockerroot/bin:/usr/bin:/bin:$PATH"
    export DOCKER_HOST="unix:///run/user/'"$DOCKER_UID"'/docker.sock"

    systemctl --user enable --now docker.service
    docker info
'

echo
echo "Готово. Проверь, что в docker info указан режим rootless."
echo "UID dockerroot: $DOCKER_UID"
echo "Docker socket: unix:///run/user/$DOCKER_UID/docker.sock"
