#!/usr/bin/env bash
set -euo pipefail

### Настройки под тебя ###

WG_IF="wg0"
WG_DIR="/etc/wireguard"
PEER_DIR="${WG_DIR}/peers"
VPN_NET="10.7.0"              # сеть WireGuard (10.7.0.X)
WG_PORT="51820"               # порт WireGuard
ENDPOINT_HOST="endpoint.host" # <<< сюда впиши внешний IP или домен сервера
DNS_SERVER="8.8.8.8"          # DNS, который будет у клиентов

############################

if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать через sudo или под root" >&2
  exit 1
fi

if [[ -z "${1-}" ]]; then
  echo "Использование: $0 <peer-name>" >&2
  exit 1
fi

PEER_NAME="$1"

# Проверка, что интерфейс поднят
if ! wg show "${WG_IF}" &>/dev/null; then
  echo "Интерфейс ${WG_IF} не найден. Подними его:  sudo wg-quick up ${WG_IF}" >&2
  exit 1
fi

mkdir -p "${PEER_DIR}"
chmod 700 "${PEER_DIR}"

# Находим следующий свободный IP в VPN_NET.X
existing_octets=$(wg show "${WG_IF}" allowed-ips 2>/dev/null \
  | awk 'NF>=2 && $2 != "(none)" {print $2}' \
  | cut -d'/' -f1 \
  | awk -F. -v net="${VPN_NET}" '$1"."$2"."$3==net {print $4}')

if [[ -z "${existing_octets}" ]]; then
  next_octet=2
else
  max_octet=$(echo "${existing_octets}" | sort -n | tail -n1)
  next_octet=$((max_octet + 1))
fi

if (( next_octet >= 255 )); then
  echo "Нет свободных IP в сети ${VPN_NET}.0/24" >&2
  exit 1
fi

PEER_IP="${VPN_NET}.${next_octet}"


# Генерация ключей пира
umask 077
priv_key_file="${PEER_DIR}/${PEER_NAME}.key"
pub_key_file="${PEER_DIR}/${PEER_NAME}.pub"
conf_file="${PEER_DIR}/${PEER_NAME}.conf"

wg genkey > "${priv_key_file}"
wg pubkey < "${priv_key_file}" > "${pub_key_file}"

PEER_PRIV_KEY=$(cat "${priv_key_file}")
PEER_PUB_KEY=$(cat "${pub_key_file}")
SERVER_PUB_KEY=$(wg show "${WG_IF}" public-key)

# Добавляем peer в wg0
wg set "${WG_IF}" peer "${PEER_PUB_KEY}" allowed-ips "${PEER_IP}/32"

# Сохраняем конфиг wg0.conf
wg-quick save "${WG_IF}"

# Создаём клиентский конфиг
cat > "${conf_file}" <<EOF
[Interface]
PrivateKey = ${PEER_PRIV_KEY}
Address = ${PEER_IP}/32
DNS = ${DNS_SERVER}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ENDPOINT_HOST}:${WG_PORT}
PersistentKeepalive = 25
EOF

chmod 600 "${conf_file}"

echo "Новый peer добавлен:"
echo "  Имя:     ${PEER_NAME}"
echo "  IP:      ${PEER_IP}"
echo "  Файлы:"
echo "    ${priv_key_file}"
echo "    ${pub_key_file}"
echo "    ${conf_file}"
echo
echo "QR-код для сканирования в приложении WireGuard:"
echo

if command -v qrencode &>/dev/null; then
  qrencode -t ansiutf8 < "${conf_file}"
  echo
  echo "Можно также забрать конфиг по SSH и импортировать как файл:"
  echo "  scp ${conf_file} user@your_pc:~/"
else
  echo "qrencode не установлен. Установи: sudo apt install qrencode"
fi
