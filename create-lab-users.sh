#!/usr/bin/env bash
set -Eeuo pipefail

# Запуск:
#   sudo ./create-lab-users.sh attacker
#   sudo ./create-lab-users.sh defender
#   sudo ./create-lab-users.sh ml-searcher
#
# Можно запускать повторно: существующие ключи сохраняются.
# Публичный SSH-ключ передаётся через стандартный ввод.

if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт через sudo." >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Использование: sudo $0 <attacker|defender|ml-searcher|leader>" >&2
    exit 1
fi

USERNAME="$1"

case "$USERNAME" in
attacker | defender | ml-searcher) ;;
*)
    echo "Неизвестный пользователь: $USERNAME" >&2
    echo "Допустимые имена: attacker, defender, ml-searcher, leader" >&2
    exit 1
    ;;
esac

GROUP="labusers"
SSH_DIR="/home/$USERNAME/.ssh"
KEYS_FILE="$SSH_DIR/authorized_keys"

# Группа лаборатории
getent group "$GROUP" >/dev/null || groupadd "$GROUP"

# Создаём пользователя, только если его ещё нет.
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$USERNAME"
    passwd --lock "$USERNAME"
    echo "Создан пользователь $USERNAME."
else
    echo "Пользователь $USERNAME уже существует."
fi

# Добавляем пользователя в группу, не удаляя другие группы.
usermod -aG "$GROUP" "$USERNAME"

# Подготавливаем каталог SSH.
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"

# Создаём файл, если его ещё нет, не затирая существующие ключи.
if [[ ! -e "$KEYS_FILE" ]]; then
    install -m 600 -o "$USERNAME" -g "$USERNAME" /dev/null "$KEYS_FILE"
fi

chown "$USERNAME:$USERNAME" "$KEYS_FILE"
chmod 600 "$KEYS_FILE"

echo
echo "Пользователь: $USERNAME"
echo "Сейчас можно добавить публичный SSH-ключ."
echo "Вставь ОДНУ строку публичного ключа и нажми Enter."
echo "Чтобы пропустить добавление ключа, просто нажми Enter."
echo

read -r -p "Публичный ключ: " PUBKEY

if [[ -z "$PUBKEY" ]]; then
    echo "Ключ не добавлен. Пользователь подготовлен; ключ можно добавить позже."
    exit 0
fi

# Разрешаем распространённые форматы публичных SSH-ключей.
if [[ ! "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
    echo "Похоже, это не поддерживаемый публичный SSH-ключ." >&2
    echo "Нужна строка из файла *.pub, а не приватный ключ." >&2
    exit 1
fi

# Запрещаем дубли, но не трогаем остальные ключи.
KEY_DATA="$(awk '{print $1, $2}' <<<"$PUBKEY")"

if awk -v key="$KEY_DATA" '
    NF >= 2 && ($1 " " $2) == key { found=1 }
    END { exit !found }
' "$KEYS_FILE"; then
    echo "Этот ключ уже добавлен."
    exit 0
fi

# Ограничиваем SSH-сессию шлюзом лаборатории.
KEY_TYPE="$(awk '{print $1}' <<<"$PUBKEY")"
KEY_BODY="$(awk '{print $2}' <<<"$PUBKEY")"
COMMENT="$(awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print}' <<<"$PUBKEY")"

printf 'restrict,pty,command="/usr/local/sbin/lab-ssh-gateway" %s %s %s\n' \
    "$KEY_TYPE" "$KEY_BODY" "$COMMENT" >>"$KEYS_FILE"

chown "$USERNAME:$USERNAME" "$KEYS_FILE"
chmod 600 "$KEYS_FILE"

echo "Публичный ключ добавлен для $USERNAME."
