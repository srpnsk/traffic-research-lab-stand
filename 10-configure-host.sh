#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Настройка системной части Network Lab для Ubuntu 24.04.
# Запуск: sudo ./10-configure-host.sh
#
# Скрипт не устанавливает Docker, не пересоздаёт контейнеры
# и не удаляет существующие захваты.

readonly DOCKER_USER="dockerroot"
readonly LAB_GROUP="labusers"
readonly LAB_ROOT="/srv/network-lab"
readonly CAPTURES="$LAB_ROOT/captures"
readonly WORKSPACE="$LAB_ROOT/workspace"
readonly INCOMING="$LAB_ROOT/incoming"
readonly METADATA="$LAB_ROOT/metadata"
readonly LOGS="$LAB_ROOT/logs"
readonly SCRIPTS="/usr/local/sbin"
readonly SYSTEMD="/etc/systemd/system"
readonly SUDOERS_FILE="/etc/sudoers.d/network-lab"

readonly TTL_DAYS=14
readonly MAX_TOTAL_BYTES=$((5 * 1024 * 1024 * 1024))

if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт через sudo." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Не удалось определить ОС." >&2
    exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "Ожидалась Ubuntu 24.04; обнаружена ${PRETTY_NAME:-неизвестная ОС}." >&2
    exit 1
fi

if ! id "$DOCKER_USER" >/dev/null 2>&1; then
    echo "Нет пользователя $DOCKER_USER. Сначала настрой Rootless Docker." >&2
    exit 1
fi

DOCKER_UID="$(id -u "$DOCKER_USER")"
DOCKER_HOME="$(getent passwd "$DOCKER_USER" | cut -d: -f6)"
DOCKER_SOCKET="/run/user/$DOCKER_UID/docker.sock"

echo "==> Устанавливаем необходимые утилиты"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y acl tshark sudo python3

echo "==> Проверяем Rootless Docker через machinectl"
if ! machinectl shell "${DOCKER_USER}@.host" /bin/bash -lc \
    'systemctl --user is-active --quiet docker.service'; then
    echo "Пользовательская служба Docker не активна." >&2
    echo "Проверь machinectl, linger и пользовательский systemd." >&2
    exit 1
fi

echo "==> Создаём каталоги лаборатории"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0750 "$LAB_ROOT"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0750 "$CAPTURES"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0770 "$WORKSPACE"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0700 "$INCOMING"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0750 "$METADATA"
install -d -o "$DOCKER_USER" -g "$DOCKER_USER" -m 0750 "$LOGS"

# Не делаем рекурсивный chown: существующие файлы и результаты
# экспериментов могут иметь собственные права и владельцев.

getent group "$LAB_GROUP" >/dev/null || groupadd "$LAB_GROUP"

echo "==> Устанавливаем labctl"
cat >"$SCRIPTS/labctl" <<'LABCTL'
#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/home/dockerroot
export USER=dockerroot
export LOGNAME=dockerroot
export PATH="/home/dockerroot/bin:/usr/local/bin:/usr/bin:/bin"
export DOCKER_HOST="unix:///run/user/$(id -u dockerroot)/docker.sock"

die() {
    echo "Ошибка: $*" >&2
    exit 2
}

[[ "$(id -un)" == "dockerroot" ]] ||
    die "labctl должен запускаться от dockerroot."

command -v docker >/dev/null 2>&1 || die "Не найден docker."
[[ -S "$DOCKER_HOST" ]] || die "Нет сокета $DOCKER_HOST."

case "${1:-}" in
    status)
        [[ $# -eq 1 ]] || die "Использование: labctl status"
        exec docker ps --filter 'name=lab-' \
            --format 'table {{.Names}}\t{{.Status}}'
        ;;
    shell)
        [[ $# -eq 2 ]] || die "Использование: labctl shell client|filter|server"
        case "$2" in
            client) container="lab-client" ;;
            filter) container="lab-filter" ;;
            server) container="lab-server" ;;
            *) die "Неизвестный контейнер." ;;
        esac

        exec docker exec -it --user 0 --workdir /workspace \
            "$container" /bin/bash
        ;;
    *)
        die "Допустимые команды: status, shell client|filter|server"
        ;;
esac
LABCTL
chmod 0755 "$SCRIPTS/labctl"
chown root:root "$SCRIPTS/labctl"

echo "==> Устанавливаем SSH-шлюз"
cat >"$SCRIPTS/lab-ssh-gateway" <<'GATEWAY'
#!/usr/bin/env bash
set -Eeuo pipefail

run_labctl() {
    exec sudo -n -u dockerroot /usr/local/sbin/labctl "$@"
}

show_menu() {
    echo "Network Lab"
    echo "1) client"
    echo "2) filter"
    echo "3) server"
    echo "4) status"
    echo "q) выход"

    while true; do
        read -r -p "> " choice || exit 0
        case "$choice" in
            1) run_labctl shell client ;;
            2) run_labctl shell filter ;;
            3) run_labctl shell server ;;
            4) run_labctl status ;;
            q|Q) exit 0 ;;
            *) echo "Неизвестный пункт." ;;
        esac
    done
}

case "${SSH_ORIGINAL_COMMAND:-}" in
    "") show_menu ;;
    "status") run_labctl status ;;
    "shell client") run_labctl shell client ;;
    "shell filter") run_labctl shell filter ;;
    "shell server") run_labctl shell server ;;
    *) echo "Команда запрещена." >&2; exit 126 ;;
esac
GATEWAY
chmod 0755 "$SCRIPTS/lab-ssh-gateway"
chown root:root "$SCRIPTS/lab-ssh-gateway"

echo "==> Устанавливаем помощник для добавления пользователей и ключей"
cat >"$SCRIPTS/lab-add-user" <<'ADDUSER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo." >&2
    exit 1
fi

[[ $# -eq 1 ]] || {
    echo "Использование: sudo lab-add-user attacker|defender|ml-searcher" >&2
    exit 2
}

username="$1"
case "$username" in
    attacker|defender|ml-searcher) ;;
    *) echo "Недопустимое имя пользователя." >&2; exit 2 ;;
esac

getent group labusers >/dev/null || groupadd labusers

if ! id "$username" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$username"
    passwd --lock "$username"
fi

usermod -aG labusers "$username"

ssh_dir="/home/$username/.ssh"
keys_file="$ssh_dir/authorized_keys"
install -d -o "$username" -g "$username" -m 0700 "$ssh_dir"
touch "$keys_file"
chown "$username:$username" "$keys_file"
chmod 0600 "$keys_file"

echo "Пользователь $username готов."
read -r -p "Вставь одну строку публичного SSH-ключа или Enter для пропуска: " pubkey

if [[ -z "$pubkey" ]]; then
    echo "Ключ не добавлен. Его можно добавить позже."
    exit 0
fi

if [[ ! "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
    echo "Неверный формат. Нужен публичный ключ из файла .pub." >&2
    exit 1
fi

key_type="$(awk '{print $1}' <<< "$pubkey")"
key_body="$(awk '{print $2}' <<< "$pubkey")"

if awk -v t="$key_type" -v k="$key_body" \
    '$1 !~ /^#/ && $0 ~ /command="\/usr\/local\/sbin\/lab-ssh-gateway"/ && $0 ~ t && $0 ~ k { found=1 }
     END { exit !found }' "$keys_file"; then
    echo "Похоже, этот ключ уже добавлен."
    exit 0
fi

comment="$(awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print}' <<< "$pubkey")"
printf 'restrict,pty,command="/usr/local/sbin/lab-ssh-gateway" %s %s %s\n' \
    "$key_type" "$key_body" "$comment" >> "$keys_file"

chown "$username:$username" "$keys_file"
chmod 0600 "$keys_file"
echo "Ключ добавлен для $username."
ADDUSER
chmod 0755 "$SCRIPTS/lab-add-user"
chown root:root "$SCRIPTS/lab-add-user"

echo "==> Настраиваем sudoers"
tmp_sudoers="$(mktemp)"
trap 'rm -f "$tmp_sudoers"' EXIT

cat >"$tmp_sudoers" <<'SUDOERS'
%labusers ALL=(dockerroot) NOPASSWD: /usr/local/sbin/labctl shell client, /usr/local/sbin/labctl shell filter, /usr/local/sbin/labctl shell server, /usr/local/sbin/labctl status
SUDOERS

chmod 0440 "$tmp_sudoers"
visudo -cf "$tmp_sudoers"

if [[ -e "$SUDOERS_FILE" ]] && cmp -s "$tmp_sudoers" "$SUDOERS_FILE"; then
    echo "sudoers уже настроен."
else
    if [[ -e "$SUDOERS_FILE" ]]; then
        cp -a "$SUDOERS_FILE" "${SUDOERS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    install -o root -g root -m 0440 "$tmp_sudoers" "$SUDOERS_FILE"
    visudo -cf "$SUDOERS_FILE"
fi

echo "==> Устанавливаем очистку захватов"
cat >"$SCRIPTS/lab-prune-captures.py" <<'PRUNE'
#!/usr/bin/env python3
import os
import time
from pathlib import Path

ROOT = Path("/srv/network-lab/captures")
TTL_SECONDS = 14 * 24 * 60 * 60
MAX_TOTAL_BYTES = 5 * 1024**3
ACTIVE_GRACE_SECONDS = 15 * 60

def regular_files():
    for directory, dirs, files in os.walk(ROOT, followlinks=False):
        dirs[:] = [
            name for name in dirs
            if not (Path(directory) / name).is_symlink()
        ]
        for name in files:
            path = Path(directory) / name
            try:
                if path.is_symlink() or not path.is_file():
                    continue
                stat = path.stat()
                yield path, stat.st_mtime, stat.st_size
            except OSError:
                continue

def remove(path):
    try:
        path.unlink()
        print(f"Removed: {path}")
    except OSError as exc:
        print(f"Cannot remove {path}: {exc}")

def main():
    if not ROOT.is_dir():
        return

    now = time.time()
    files = list(regular_files())

    for path, mtime, _ in files:
        if now - mtime > TTL_SECONDS:
            remove(path)

    files = list(regular_files())
    total = sum(size for _, _, size in files)
    if total <= MAX_TOTAL_BYTES:
        return

    # Это логический предел, не файловая квота.
    # Не удаляем файлы, недавно изменявшиеся: они могут быть активными.
    for path, mtime, size in sorted(files, key=lambda item: item[1]):
        if total <= MAX_TOTAL_BYTES:
            break
        if now - mtime < ACTIVE_GRACE_SECONDS:
            continue
        remove(path)
        total -= size

    if total > MAX_TOTAL_BYTES:
        print("WARNING: captures exceed logical quota; recent files were preserved.")

if __name__ == "__main__":
    main()
PRUNE
chmod 0755 "$SCRIPTS/lab-prune-captures.py"
chown root:root "$SCRIPTS/lab-prune-captures.py"

cat >"$SYSTEMD/lab-prune-captures.service" <<EOF
[Unit]
Description=Prune old Network Lab captures

[Service]
Type=oneshot
User=$DOCKER_USER
Group=$DOCKER_USER
ExecStart=/usr/bin/python3 $SCRIPTS/lab-prune-captures.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$CAPTURES
EOF

cat >"$SYSTEMD/lab-prune-captures.timer" <<'EOF'
[Unit]
Description=Periodic cleanup of Network Lab captures

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "==> Устанавливаем генератор метаданных"
cat >"$SCRIPTS/lab-index-captures.sh" <<'INDEX'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="/srv/network-lab/captures"

find "$ROOT" -type f \( -name '*.pcap' -o -name '*.pcapng' \) -print0 |
while IFS= read -r -d '' file; do
    [[ -L "$file" ]] && continue

    metadata="${file}.meta.txt"
    tmp="$(mktemp "${file}.meta.XXXXXX")"

    if capinfos -a -e -c -s -H "$file" > "$tmp"; then
        chmod 0640 "$tmp"
        mv -- "$tmp" "$metadata"
        touch -r "$file" "$metadata"
    else
        rm -f -- "$tmp"
        echo "Не удалось обработать: $file" >&2
    fi
done
INDEX
chmod 0755 "$SCRIPTS/lab-index-captures.sh"
chown root:root "$SCRIPTS/lab-index-captures.sh"

cat >"$SYSTEMD/lab-index-captures.service" <<EOF
[Unit]
Description=Generate Network Lab capture metadata

[Service]
Type=oneshot
User=$DOCKER_USER
Group=$DOCKER_USER
ExecStart=$SCRIPTS/lab-index-captures.sh
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=$CAPTURES
ReadWritePaths=$CAPTURES
EOF

cat >"$SYSTEMD/lab-index-captures.timer" <<'EOF'
[Unit]
Description=Periodic metadata indexing for Network Lab captures

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "==> Настраиваем Caddy, только если служба уже установлена"
if systemctl cat caddy.service >/dev/null 2>&1; then
    # Определяем пользователя службы или фактического процесса.
    CADDY_USER="$(systemctl show caddy -p User --value 2>/dev/null || true)"

    if [[ -z "$CADDY_USER" ]]; then
        CADDY_PID="$(systemctl show caddy -p MainPID --value 2>/dev/null || true)"
        if [[ "$CADDY_PID" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$CADDY_PID/status" ]]; then
            CADDY_UID="$(awk '/^Uid:/ {print $2}' "/proc/$CADDY_PID/status")"
            CADDY_USER="$(getent passwd "$CADDY_UID" | cut -d: -f1)"
        fi
    fi

    if [[ -n "$CADDY_USER" ]] && id "$CADDY_USER" >/dev/null 2>&1; then
        setfacl -m "u:$CADDY_USER:--x" "$LAB_ROOT"
        setfacl -R -m "u:$CADDY_USER:r-X" "$CAPTURES"
        setfacl -m "d:u:$CADDY_USER:r-x,d:m:r-x" "$CAPTURES"
        echo "ACL настроен для Caddy: $CADDY_USER"
    else
        echo "Не удалось определить пользователя Caddy."
        echo "ACL не менял; настройка Caddy пропущена." >&2
    fi

    # Не переписываем существующий Caddyfile и не делаем reload вслепую.
    if command -v caddy >/dev/null 2>&1 &&
        [[ -f /etc/caddy/Caddyfile ]]; then
        caddy validate --config /etc/caddy/Caddyfile
    fi
else
    echo "Служба caddy.service не найдена; Caddy не устанавливался и не менялся."
fi

echo "==> Перезагружаем systemd и включаем таймеры"
systemctl daemon-reload
systemctl enable --now lab-prune-captures.timer
systemctl enable --now lab-index-captures.timer

echo "==> Проверяем установленные файлы"
visudo -c
systemctl --no-pager --full status lab-prune-captures.timer
systemctl --no-pager --full status lab-index-captures.timer

echo
echo "Настройка хоста завершена."
echo "Добавление участников: sudo lab-add-user attacker"
echo "Добавление ключей:     sudo lab-add-user defender"
echo "Проверка Docker:       sudo machinectl shell ${DOCKER_USER}@.host /bin/bash -lc 'docker info'"
echo
echo "ВНИМАНИЕ: лимит 5 GiB для PCAP логический, а не файловая квота."
