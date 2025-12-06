#!/usr/bin/env bash
set -euo pipefail

DEBUG=${WGSTAT_DEBUG:-0}

debug() {
  if [[ "${DEBUG}" != "0" ]]; then
    echo "[debug] $*" >&2
  fi
}

# Скрипт для просмотра статистики WireGuard и управления пользователями пиров.
# Требует права root.

WG_IF="${WG_IF:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
PEER_DIR="${WG_DIR}/peers"
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

sanitize_pubkey() {
  local raw=$1
  # удаляем комментарии в конце строки и любые пробелы/переводы строк
  raw=${raw%%#*}
  raw=$(echo -n "${raw}" | tr -d '[:space:]')
  printf '%s' "${raw}"
}

derive_pubkey() {
  local priv=$1
  if [[ -z "${priv}" ]]; then
    return 1
  fi
  if ! command -v wg &>/dev/null; then
    return 1
  fi
  local derived
  if ! derived=$(printf '%s' "${priv}" | wg pubkey 2>/dev/null); then
    return 1
  fi
  sanitize_pubkey "${derived}"
}

load_peer_map() {
  declare -gA PEER_NAME_BY_PUB=()
  if [[ ! -d "${PEER_DIR}" ]]; then
    debug "Каталог с пирами ${PEER_DIR} не найден"
    return 0
  fi

  # find может возвращать 1 при проблемах чтения отдельных файлов, поэтому
  # игнорируем ненулевой статус, чтобы не падать из-за set -e.
  local total=0
  while IFS= read -r -d '' file; do
    local pubkey name=""
    case "${file}" in
      *.pub)
        pubkey=$(sanitize_pubkey "$(<"${file}")")
        name=$(basename "${file}" .pub)
        ;;
      *.conf|*.cfg)
        pubkey=$(sanitize_pubkey "$(grep -E '^\s*PublicKey\s*=\s*' "${file}" | head -n1 | cut -d'=' -f2- || true)")
        if [[ -z "${pubkey}" ]]; then
          local privkey
          privkey=$(sanitize_pubkey "$(grep -E '^\s*PrivateKey\s*=\s*' "${file}" | head -n1 | cut -d'=' -f2- || true)")
          pubkey=$(derive_pubkey "${privkey}") || pubkey=""
        fi
        name=$(grep -iE '^\s*#\s*(name|client)\s*:?' "${file}" | head -n1 | sed -E 's/^\s*#\s*(name|client)\s*:?[[:space:]]*//I' | xargs || true)
        [[ -z "${name}" ]] && name=$(basename "${file}" .conf)
        name=${name:-$(basename "${file}")}
        ;;
      *.key|*.priv|*.private)
        local priv_content
        priv_content=$(sanitize_pubkey "$(<"${file}")")
        pubkey=$(derive_pubkey "${priv_content}") || pubkey=""
        name=$(basename "${file}" | sed -E 's/\.(key|priv|private)$//')
        ;;
      *)
        continue
        ;;
    esac

    if [[ -n "${pubkey}" ]]; then
      PEER_NAME_BY_PUB["${pubkey}"]="${name}"
      ((total++))
      debug "Загружен пир '${name}' (${pubkey:0:12}...) из ${file}"
    fi
  done < <(find "${PEER_DIR}" -type f -print0 2>/dev/null || true) || true
  debug "Всего найдено имён пиров: ${total}"
}

show_stats() {
  require_root
  if ! command -v wg >/dev/null 2>&1; then
    echo "wg не найден. Установи wireguard-tools." >&2
    exit 1
  fi
  local filter_name=${1-}
  load_peer_map

  if ! wg show "${WG_IF}" &>/dev/null; then
    echo "Интерфейс ${WG_IF} не найден. Подними его: sudo wg-quick up ${WG_IF}" >&2
    exit 1
  fi

  local dump_output
  if ! dump_output=$(wg show "${WG_IF}" dump 2>/dev/null); then
    echo "Не удалось получить статистику wg show ${WG_IF} dump" >&2
    exit 1
  fi
  debug "Строк из wg show: $(echo "${dump_output}" | grep -c . || true)"

  printf "%-20s %-18s %-12s %-12s %-20s\n" "Peer" "Allowed IPs" "Received" "Sent" "Last handshake"
  printf '%s\n' "$(printf '%.0s-' {1..82})"

  local had_peer=false
  while IFS=$'\t' read -r -a cols; do
    # пропускаем строку интерфейса
    if [[ ${#cols[@]} -ge 1 && "${cols[0]}" == "${WG_IF}" ]]; then
      continue
    fi

    # строка может быть битой — пропускаем, если не хватает числовых полей
    if (( ${#cols[@]} < 7 )); then
      continue
    fi

    local pub
    pub=$(sanitize_pubkey "${cols[0]}")
    local allowed="${cols[3]:-}" 
    local last_handshake="${cols[4]:-0}"
    local rx="${cols[5]:-0}"
    local tx="${cols[6]:-0}"

    [[ "${last_handshake}" =~ ^[0-9]+$ ]] || last_handshake=0
    [[ "${rx}" =~ ^[0-9]+$ ]] || rx=0
    [[ "${tx}" =~ ^[0-9]+$ ]] || tx=0

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

    had_peer=true
    printf "%-20s %-18s %-12s %-12s %-20s\n" "${name}" "${allowed}" "${rx_human}" "${tx_human}" "${last_human}"
  done <<< "${dump_output}" || true

  if ! $had_peer; then
    echo "Пиры для ${WG_IF} не найдены" >&2
  fi
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
