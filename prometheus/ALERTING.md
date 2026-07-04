# Алерты в Telegram (Prometheus + Alertmanager)

Правила и конфиги живут в репозитории (`prometheus/`), на metrics VPS
копируются вручную — Prometheus/Grafana там управляются руками by design.

```
хаб (textfile-коллекторы) ──scrape──> Prometheus ──rules──> Alertmanager ──> Telegram
```

## Установка (один раз, на metrics VPS)

### 0. Предусловие: метрики хаба

Алертам нужны `wireguard_exit_priority` и `hub_cert_expiry_timestamp_seconds` —
они появляются после прогона `ansible-playbook playbooks/hub.yml` (роль
metrics_hub). Проверка: `curl -s 10.99.0.1:9100/metrics | grep exit_priority`.

### 1. chat_id бота

Напиши боту любое сообщение, затем:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool | grep -A2 '"chat"'
```

Нужное значение — `message.chat.id` (число).

### 2. Alertmanager

```bash
sudo apt install prometheus-alertmanager
```

### 3. Токен бота (секрет — отдельным файлом, не в конфиге и не в git)

```bash
echo '<TOKEN>' | sudo tee /etc/prometheus/telegram_bot_token
sudo chown prometheus:prometheus /etc/prometheus/telegram_bot_token
sudo chmod 600 /etc/prometheus/telegram_bot_token
```

### 4. Конфиги из репозитория

С машины с репозиторием:

```bash
scp -P 5860 prometheus/alertmanager.yml prometheus/telegram.tmpl ops@10.99.0.100:/tmp/
scp -P 5860 prometheus/rules/wg-hub-alerts.yml ops@10.99.0.100:/tmp/
```

На metrics VPS:

```bash
sudo mkdir -p /etc/prometheus/rules
sudo mv /tmp/alertmanager.yml /tmp/telegram.tmpl /etc/prometheus/
sudo mv /tmp/wg-hub-alerts.yml /etc/prometheus/rules/
# chat_id стоит в ДВУХ receivers (telegram и telegram-events) — sed правит оба:
sudo sed -i 's/chat_id: 0.*/chat_id: <ТВОЙ_CHAT_ID>/' /etc/prometheus/alertmanager.yml
```

### 5. Правки /etc/prometheus/prometheus.yml

Секция `alerting:` со стоковым `targets: ['localhost:9093']` уже есть.

```yaml
rule_files:
  - "/etc/prometheus/rules/*.yml"
```

Job хаба должен скрейпиться каждые 5 секунд (иначе задержка алертов
вырастает на глобальные 15 с):

```yaml
  - job_name: wg-hub
    scrape_interval: 5s
    static_configs:
      - targets: ['10.99.0.1:9100']
```

### 5a. Часовой пояс и кликабельные ссылки

Таймстампы в сообщениях (`.Local.Format` в шаблоне) берут TZ системы:

```bash
sudo timedatectl set-timezone Asia/Bishkek   # подставь свой
```

Чтобы ссылка «Prometheus» из сообщений открывалась с устройств оверлея,
задай external-url (в `/etc/default/prometheus` добавить в ARGS):

```
ARGS="--web.enable-admin-api --web.external-url=http://metrics.in.threadnull.dev:9090"
```

### 6. Валидация и запуск

```bash
promtool check rules /etc/prometheus/rules/wg-hub-alerts.yml
amtool check-config /etc/prometheus/alertmanager.yml
sudo systemctl enable --now prometheus-alertmanager
sudo systemctl restart prometheus prometheus-alertmanager
```

(`restart` Prometheus, а не `reload` — изменения ARGS/external-url
применяются только рестартом; правки одних лишь правил достаточно
перечитывать через `reload`.)

### 7. Тест доставки

```bash
# Значения меток с пробелами требуют двойных кавычек ВНУТРИ аргумента
# (UTF-8-парсер Alertmanager >= 0.28), а summary — это аннотация,
# именно её печатает telegram-шаблон.
amtool alert add TestAlert severity=critical \
  --annotation='summary="delivery test"' \
  --alertmanager.url=http://localhost:9093
```

Сообщение 🔴 должно прийти в Telegram в течение ~15 секунд, а через
~5 минут — ✅ resolved (алерт истекает сам).

## Список алертов (prometheus/rules/wg-hub-alerts.yml)

**События** (лейбл `event="true"`): одно сообщение «📟 EVENT» на событие,
без resolved-хвостов, отдельное сообщение на каждого пира/сайт:

| Событие | Смысл | Доставка |
|---|---|---|
| ClientConnected | клиент подключился (антифлап: ≤1 сообщения в 10 мин на пира) | ~25 с |
| ClientDisconnected | клиент отключился (детект по возрасту handshake — сессия реально закончилась ~5 мин назад) | ~5–6 мин после отключения |
| ExitSwitched | exit переключился **на** конкретный сайт (failover/preempt) | ~25 с |
| InstanceRebooted | нода перезагрузилась | ~1 мин |

**Stateful-алерты** (FIRING + ✅ RESOLVED):

| Алерт | Условие | for | Уровень |
|---|---|---|---|
| HubDown | хаб не скрейпится | 45s | 🔴 critical |
| NodeDown | любая другая нода не скрейпится | 1m | 🔴 critical |
| CollectorsStale | .prom-файлы хаба не обновляются > 60 с | 2m | 🟡 warning |
| SiteTunnelDown | нет handshake сайта > 4 мин (здоровый ≤ ~2 мин) | 30s | 🔴 critical |
| ServiceTunnelDown | нет handshake сервиса > 5 мин | 2m | 🟡 warning |
| ExitOnBackup | exit не на приоритетном сайте | 30s | 🟡 warning |
| FailClosed | ни один exit не анонсирует дефолт — home без интернета | 30s | 🔴 critical |
| BGPSessionDown | BGP-сессия упала (самый быстрый детектор смерти сайта: hold 15 с) | 30s | 🔴 critical |
| BGPPrefixesMissing | сайт отдаёт < 2 префиксов (умер WAN / пропал LAN-анонс) | 2m | 🟡 warning |
| HighCPU / HighMemory | CPU / RAM > 90% | 15m | 🟡 warning |
| DiskLow / DiskCritical | < 15% / < 5% корневой ФС | 10m / 5m | 🟡 / 🔴 |
| CertExpirySoon | wildcard-серту < 14 дней (продление сломано) | 1h | 🟡 warning |

Маршрутизация: события — group_wait 5 с, без resolved; critical —
group_wait 5 с, повтор каждые 4 ч; warning — раз в сутки.
Бюджет задержки: коллектор 5 с + scrape 5 с + eval 10 с + `for` +
group_wait. Смерть сайта: ~70 с (BGPSessionDown), fail-closed: ~55 с.
Надоели клиентские события — заглуши маршрут:
`amtool silence add event=true --duration=30d --comment="mute events"`.

## Обновление правил

Правки — в репозитории, затем: скопировать файл (шаг 4), `promtool check
rules`, `sudo systemctl reload prometheus`. Конфиг Alertmanager —
`sudo systemctl reload prometheus-alertmanager`.

## Ограничение (deadman)

Если умирает сам metrics VPS — алертить некому: Prometheus и Alertmanager
живут на нём. При желании закрыть эту дыру: правило-Watchdog (`vector(1)`,
always-firing) + внешний heartbeat-сервис (например, healthchecks.io),
который поднимает тревогу, когда пинги от Watchdog перестают приходить.
Сознательно не реализовано — внешняя зависимость.
