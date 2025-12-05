#!/usr/bin/env bash
set -euo pipefail

# Скрипт для просмотра статистики WireGuard и управления пользователями пиров.
# Требует права root.

WG_IF="wg0"
WG_DIR="/etc/wireguard"
PEER_DIR="${WG_DIR}/peer"
WG_ADD_PEER_SCRIPT=${WG_ADD_PEER_SCRIPT:-}

usage() {
  cat <<USAGE
Использование: $0 <команда> [аргументы]

Команды:
  stats [peer-name]  - показать статистику по всем пирам или конкретному.
  add   <peer-name>  - создать системного пользователя и добавить пира
                      через wg-add-peer.sh (по умолчанию берётся из
                      /usr/local/sbin или рядом с этим скриптом).
USAGE
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт нужно запускать через sudo или под root" >&2
    exit 1
  fi
}

human_bytes() {
  local -n _out=$2
  local bytes=$1
  local units=(B KiB MiB GiB TiB)
  local idx=0
  while (( bytes >= 1024 && idx < ${#units[@]}-1 )); do
    bytes=$((bytes/1024))
    ((idx++))
  done
  _out="${bytes} ${units[$idx]}"
}

load_peer_map() {
  declare -gA PEER_NAME_BY_PUB=()
  [[ -d "${PEER_DIR}" ]] || return

  while IFS= read -r -d '' file; do
    local pubkey name=""
    case "${file}" in
      *.pub)
        pubkey=$(<"${file}")
        name=$(basename "${file}" .pub)
        ;;
      *.conf|*.cfg)
        pubkey=$(grep -E '^\s*PublicKey\s*=\s*' "${file}" | head -n1 | cut -d'=' -f2- | xargs)
        name=$(grep -iE '^\s*#\s*(name|client)\s*:?' "${file}" | head -n1 | sed -E 's/^\s*#\s*(name|client)\s*:?[[:space:]]*//I')
        [[ -z "${name}" ]] && name=$(basename "${file}" .conf)
        name=${name:-$(basename "${file}")}
        ;;
      *)
        continue
        ;;
    esac

    if [[ -n "${pubkey}" ]]; then
      PEER_NAME_BY_PUB["${pubkey}"]="${name}"
    fi
  done < <(find "${PEER_DIR}" -type f -print0)
}

show_stats() {
  require_root
  local filter_name=${1-}
  load_peer_map

  if ! wg show "${WG_IF}" &>/dev/null; then
    echo "Интерфейс ${WG_IF} не найден. Подними его: sudo wg-quick up ${WG_IF}" >&2
    exit 1
  fi

  local dump_output
  dump_output=$(wg show "${WG_IF}" dump)
  if [[ -z "${dump_output}" ]]; then
    echo "Нет данных wg show" >&2
    exit 1
  fi

  printf "%-20s %-18s %-12s %-12s %-20s\n" "Peer" "Allowed IPs" "Received" "Sent" "Last handshake"
  printf '%s\n' "$(printf '%.0s-' {1..82})"

  while IFS=$'\t' read -r pub preshared endpoint allowed last_handshake rx tx keepalive; do
    # пропускаем строку интерфейса
    if [[ "${pub}" == "${WG_IF}" ]]; then
      continue
    fi

    local name=${PEER_NAME_BY_PUB["${pub}"]-"unknown"}
    if [[ -n "${filter_name}" && "${filter_name}" != "${name}" ]]; then
      continue
    fi

    local rx_human tx_human
    human_bytes "${rx}" rx_human
    human_bytes "${tx}" tx_human

    local last_human
    if [[ "${last_handshake}" -eq 0 ]]; then
      last_human="never"
    else
      last_human=$(date -d "@${last_handshake}" '+%Y-%m-%d %H:%M:%S')
    fi

    printf "%-20s %-18s %-12s %-12s %-20s\n" "${name}" "${allowed}" "${rx_human}" "${tx_human}" "${last_human}"
  done <<< "${dump_output}"
}

add_peer() {
  require_root
  if [[ -z "${1-}" ]]; then
    echo "Укажите имя пира" >&2
    usage
    exit 1
  fi
  local peer_name=$1

  if ! command -v wg &>/dev/null; then
    echo "wg не найден. Установи wireguard-tools." >&2
    exit 1
  fi

  if [[ -z "${WG_ADD_PEER_SCRIPT}" ]]; then
    if [[ -x /usr/local/sbin/wg-add-peer.sh ]]; then
      WG_ADD_PEER_SCRIPT="/usr/local/sbin/wg-add-peer.sh"
    elif [[ -x "$(dirname "$0")/wg-add-peer.sh" ]]; then
      WG_ADD_PEER_SCRIPT="$(dirname "$0")/wg-add-peer.sh"
    fi
  fi

  if ! [[ -x "${WG_ADD_PEER_SCRIPT}" ]]; then
    echo "Скрипт добавления пира не найден или не исполняемый."
    echo "Создай /usr/local/sbin/wg-add-peer.sh или положи wg-add-peer.sh рядом со скриптом." >&2
    exit 1
  fi

  if id -u "${peer_name}" &>/dev/null; then
    echo "Пользователь ${peer_name} уже существует" >&2
  else
    useradd -m -s /usr/sbin/nologin "${peer_name}"
    echo "Создан пользователь ${peer_name}"
  fi

  "${WG_ADD_PEER_SCRIPT}" "${peer_name}"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd=$1
  shift

  case "${cmd}" in
    stats)
      show_stats "${1-}"
      ;;
    add)
      add_peer "$@"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
