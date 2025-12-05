# wgstat.sh

Скрипт для вывода статистики WireGuard и создания новых пиров.

## Требования
- Запуск под `root` или через `sudo`.
- Установленные `wireguard-tools` (`wg`).
- Конфиги и ключи пиров лежат в `/etc/wireguard/peer` (имена берутся из комментариев `# Name:`/`# Client:` или из имён файлов `.conf/.pub`).

## Установка
1. Скопируйте `wgstat.sh` и сделайте исполняемым:
   ```bash
   sudo install -m 755 wgstat.sh /usr/local/sbin/wgstat.sh
   ```
2. Подготовьте скрипт добавления пира:
   - Основной ожидаемый путь: `/usr/local/sbin/wg-add-peer.sh`.
   - Альтернатива: положите `wg-add-peer.sh` рядом с `wgstat.sh` (в один каталог).
   - Убедитесь, что он исполняемый:
     ```bash
     sudo chmod +x /usr/local/sbin/wg-add-peer.sh
     ```

`wgstat.sh` сначала ищет исполняемый `/usr/local/sbin/wg-add-peer.sh`. Если его нет, пробует файл `wg-add-peer.sh` рядом с самим `wgstat.sh`. Можно переопределить путь переменной окружения `WG_ADD_PEER_SCRIPT`.

## Использование
Вывод помощи:
```bash
sudo wgstat.sh
```

Показать статистику по всем пирам или по конкретному имени:
```bash
sudo wgstat.sh stats
sudo wgstat.sh stats alice
```

Добавить пира (создаёт системного пользователя и вызывает `wg-add-peer.sh`):
```bash
sudo wgstat.sh add alice
```
