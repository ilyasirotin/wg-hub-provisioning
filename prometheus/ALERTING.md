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
sudo sed -i 's/chat_id: 0.*/chat_id: <ТВОЙ_CHAT_ID>/' /etc/prometheus/alertmanager.yml
```

### 5. Подключить правила в /etc/prometheus/prometheus.yml

Секция `alerting:` со стоковым `targets: ['localhost:9093']` уже есть.
Заменить пустую секцию `rule_files:` на:

```yaml
rule_files:
  - "/etc/prometheus/rules/*.yml"
```

### 6. Валидация и запуск

```bash
promtool check rules /etc/prometheus/rules/wg-hub-alerts.yml
amtool check-config /etc/prometheus/alertmanager.yml
sudo systemctl enable --now prometheus-alertmanager
sudo systemctl restart prometheus-alertmanager   # если уже был запущен
sudo systemctl reload prometheus
```

### 7. Тест доставки

```bash
amtool alert add TestAlert severity=critical summary="тест доставки" --alertmanager.url=http://localhost:9093
```

Сообщение 🔴 должно прийти в Telegram в течение ~15 секунд, а через
~5 минут — ✅ resolved (алерт истекает сам).

## Список алертов (prometheus/rules/wg-hub-alerts.yml)

| Алерт | Условие | for | Уровень |
|---|---|---|---|
| HubDown | хаб не скрейпится | 2m | 🔴 critical |
| NodeDown | любая другая нода не скрейпится | 3m | 🔴 critical |
| CollectorsStale | .prom-файлы хаба не обновляются | 5m | 🟡 warning |
| SiteTunnelDown | нет handshake сайта > 5 мин | 1m | 🔴 critical |
| ServiceTunnelDown | нет handshake сервиса > 5 мин | 5m | 🟡 warning |
| ClientSession | клиент подключился (FIRING) / отключился (RESOLVED) | 45s | ℹ️ info |
| ExitSwitched | exit-сайт переключался (failover/preempt) | — | 🟡 warning |
| ExitOnBackup | exit не на приоритетном сайте | 2m | 🟡 warning |
| FailClosed | ни один exit не анонсирует дефолт — home без интернета | 1m | 🔴 critical |
| BGPSessionDown | BGP-сессия с сайтом упала | 1m | 🔴 critical |
| BGPPrefixesMissing | сайт отдаёт < 2 префиксов (умер WAN / пропал LAN-анонс) | 5m | 🟡 warning |
| HighCPU | CPU > 90% | 15m | 🟡 warning |
| HighMemory | RAM > 90% | 15m | 🟡 warning |
| DiskLow / DiskCritical | < 15% / < 5% корневой ФС | 10m / 5m | 🟡 / 🔴 |
| InstanceRebooted | нода загрузилась < 5 мин назад | — | ℹ️ info |
| CertExpirySoon | wildcard-серту < 14 дней (продление сломано) | 1h | 🟡 warning |

Маршрутизация: critical — повтор каждые 4 ч; warning — раз в сутки;
info — тихий маршрут (доставка за ~15 с, повторов практически нет).
Надоели клиентские события — заглуши весь маршрут:
`amtool silence add severity=info --duration=30d --comment="mute client events"`.

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
