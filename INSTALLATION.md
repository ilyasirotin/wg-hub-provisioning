# Хаб на Debian 13 (DigitalOcean, Amsterdam)

Ручная установка, без Ansible. Каждый шаг выполняется по SSH на droplet'е.

## 0. Модель сети

Единственный интерфейс `wg0` — приватный оверлей. Клиентского VPN и выхода
в интернет через хаб нет: пиры используют туннель только для доступа к
оверлею, LAN сайтов и сервисным VPS, а в интернет ходят через свои
собственные подключения.

| Параметр | Значение |
|---|---|
| Интерфейс | `wg0`, `10.99.0.0/24`, UDP `51820` |
| Хаб | `10.99.0.1` |
| site_a | `10.99.0.11`, LAN `10.1.0.0/16` |
| site_b | `10.99.0.12`, LAN `10.2.0.0/16` |
| Сервисные VPS | `10.99.0.100–199` |
| Устройства | `10.99.0.20–99` |
| Домен | `in.threadnull.dev` |
| SSH | порт `22`, снаружи закрыт через DO Cloud Firewall |
| Droplet | Debian 13, 1 vCPU / 1 GB RAM, AMS3 |

Без BGP, без FRR, без PBR. Маршруты к LAN сайтов — статические. NAT на
хабе не нужен вообще: транзитного интернет-трафика через него не проходит.

---

## 1. Создание droplet

**Create → Droplets → Debian 13**, регион **AMS3**, размер 1 vCPU / 1 GB
(Basic). Добавить SSH-ключ — на штатном образе Debian cloud-init подхватит
его сразу, веб-консоль не понадобится.

```bash
ssh root@<публичный-IP>
```

Cloud Firewall пока не создаём — понадобится SSH снаружи, пока не поднят
WireGuard.

---

## 2. Служебный пользователь

```bash
adduser ops
usermod -aG sudo ops
mkdir -p /home/ops/.ssh
cp ~/.ssh/authorized_keys /home/ops/.ssh/
chown -R ops:ops /home/ops/.ssh
chmod 700 /home/ops/.ssh
chmod 600 /home/ops/.ssh/authorized_keys
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
chmod 0440 /etc/sudoers.d/ops
```

Переподключиться как `ops` и убедиться, что `sudo` работает, прежде чем
идти дальше.

---

## 3. Пакеты и базовая настройка

```bash
sudo apt update && sudo apt dist-upgrade -y
sudo apt install -y wireguard nftables dnsmasq qrencode curl \
                    prometheus-node-exporter unattended-upgrades

sudo apt purge -y ufw          # конфликтует с прямым управлением nftables
sudo systemctl enable nftables
```

Автообновления безопасности:

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

`sshd` остаётся на порту 22 с ключевой аутентификацией — снаружи его
закроет Cloud Firewall (раздел 10). Стоит явно выключить парольный вход:

```bash
sudo tee /etc/ssh/sshd_config.d/90-hardening.conf << 'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
EOF

sudo systemctl restart ssh
```

`fail2ban` не ставим: SSH недоступен из интернета после раздела 10, а
внутри оверлея бан по неудачным попыткам только мешает.

---

## 4. IP-форвардинг

Критично: при `ip_forward = 0` ядро молча роняет форвардящиеся пакеты
**до** того, как их увидит nftables. SSH к хабу при этом работает (это
цепочка INPUT, не FORWARD), поэтому проблема невидима без явной проверки.
Здесь форвардинг нужен для site-to-site трафика — чтобы пиры одного сайта
видели LAN другого через хаб.

```bash
sudo tee /etc/sysctl.d/99-wg-hub.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
sysctl net.ipv4.ip_forward   # должно вернуть 1
```

Префикс `99-` гарантирует, что файл загрузится после всех дистрибутивных
и выиграет любые конфликты.

---

## 5. Ключи

```bash
sudo mkdir -p /etc/wireguard/peers
sudo chmod 700 /etc/wireguard /etc/wireguard/peers
```

Ключ хаба:

```bash
(umask 077; wg genkey | sudo tee /etc/wireguard/wg0.priv | \
   wg pubkey | sudo tee /etc/wireguard/wg0.pub) > /dev/null

sudo cat /etc/wireguard/wg0.pub   # понадобится при настройке пиров
```

Ключи пиров — по набору на пира. Скрипт идемпотентен: существующие ключи
не перезаписываются, поэтому его можно гонять повторно при добавлении
новых пиров.

```bash
for PEER in site_a site_b; do
  PRIV="/etc/wireguard/peers/${PEER}.priv"
  if [ ! -f "$PRIV" ]; then
    (umask 077; wg genkey | sudo tee "$PRIV" | \
       wg pubkey | sudo tee "/etc/wireguard/peers/${PEER}.pub") > /dev/null
    (umask 077; wg genpsk | sudo tee "/etc/wireguard/peers/${PEER}.psk") > /dev/null
    echo "generated: $PEER"
  else
    echo "exists, skipped: $PEER"
  fi
done

sudo chmod 600 /etc/wireguard/wg0.priv /etc/wireguard/peers/*.priv \
               /etc/wireguard/peers/*.psk
```

---

## 6. wg0

```bash
WG0_PRIV=$(sudo cat /etc/wireguard/wg0.priv)
SITE_A_PUB=$(sudo cat /etc/wireguard/peers/site_a.pub)
SITE_A_PSK=$(sudo cat /etc/wireguard/peers/site_a.psk)
SITE_B_PUB=$(sudo cat /etc/wireguard/peers/site_b.pub)
SITE_B_PSK=$(sudo cat /etc/wireguard/peers/site_b.psk)

sudo tee /etc/wireguard/wg0.conf << EOF
# Table = off: routes are managed by wg0-routes.service, not wg-quick.
# This allows peer changes to be applied with 'wg syncconf' without
# restarting the interface and dropping every active session.
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = ${WG0_PRIV}
Table = off

# site_a
[Peer]
PublicKey = ${SITE_A_PUB}
PresharedKey = ${SITE_A_PSK}
AllowedIPs = 10.99.0.11/32, 10.1.0.0/16

# site_b
[Peer]
PublicKey = ${SITE_B_PUB}
PresharedKey = ${SITE_B_PSK}
AllowedIPs = 10.99.0.12/32, 10.2.0.0/16
EOF

sudo chmod 600 /etc/wireguard/wg0.conf
sudo wg-quick strip /etc/wireguard/wg0.conf > /dev/null && echo "syntax ok"
```

Хаб не задаёт `Endpoint` ни для одного пира — он узнаёт адреса динамически
из handshake. На стороне MikroTik нужен `persistent-keepalive = 25s`, чтобы
сессия жила через NAT/CGNAT.

### Маршруты

`Table = off` означает, что wg-quick не создаёт маршруты сам. Отдельный
oneshot-юнит, привязанный к интерфейсу через `BindsTo=` — если WireGuard
упадёт, маршруты снимутся автоматически.

```bash
sudo tee /usr/local/sbin/wg0-routes.sh << 'EOF'
#!/usr/bin/env bash
set -eu

IFACE="wg0"
ACTION="${1:-up}"

route() {
  local op="$1"; shift
  if [ "$op" = add ]; then ip route replace "$@"; else ip route del "$@" 2>/dev/null || true; fi
}

if [ "$ACTION" = up ]; then OP=add; else OP=del; fi

# Overlay subnet
route "$OP" 10.99.0.0/24 dev "$IFACE"

# Site LAN supernets (static; no dynamic routing protocol in use)
route "$OP" 10.1.0.0/16 via 10.99.0.11 dev "$IFACE"
route "$OP" 10.2.0.0/16 via 10.99.0.12 dev "$IFACE"

exit 0
EOF

sudo chmod 755 /usr/local/sbin/wg0-routes.sh

sudo tee /etc/systemd/system/wg0-routes.service << 'EOF'
[Unit]
Description=Routing entries for wg0
After=network-online.target
After=wg-quick@wg0.service
BindsTo=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wg0-routes.sh up
ExecStop=/usr/local/sbin/wg0-routes.sh down
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

**О статических маршрутах.** У каждой LAN ровно один путь — через свой
сайт, альтернативного маршрута не существует в принципе, поэтому
переключать нечего и динамический протокол ничего бы не добавил. При
падении сайта его сеть просто недоступна, а пакеты к ней уходят в таймаут
вместо быстрого ICMP unreachable — единственная разница по сравнению с
прежней схемой на BGP. При возвращении сайта всё заработает само, ручного
вмешательства не требуется. Падение сайта видно по возрасту handshake
(`wg show wg0 latest-handshakes`) — в админке или вручную.

**Выхода в интернет через хаб или через сайты в этой схеме нет намеренно.**
Задача «выйти в сеть с IP своей страны в поездках» решена отдельно — на
выделенном VPS с VLESS/XRAY, вне этого хаба.

---

## 7. nftables

Найти публичный интерфейс:

```bash
ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
```

```bash
sudo tee /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
# Overlay-only hub: no transit internet traffic, no NAT.

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp limit rate 20/second accept

        # WireGuard handshakes from anywhere
        udp dport 51820 accept

        # SSH - closed from the internet by the DO Cloud Firewall
        tcp dport 22 accept

        # Internal DNS - overlay only
        iifname "wg0" udp dport 53 accept
        iifname "wg0" tcp dport 53 accept

        # node_exporter - overlay only
        iifname "wg0" tcp dport 9100 accept

        log prefix "nft_input_drop: " counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # MSS clamping - prevents stalled sessions over PPPoE/VPN paths
        tcp flags syn tcp option maxseg size set rt mtu

        # Site-to-site and peer-to-peer traffic within the overlay.
        # Nothing else forwards: no internet egress through this hub.
        iifname "wg0" oifname "wg0" accept

        log prefix "nft_forward_drop: " counter drop
    }
}
EOF

sudo nft -c -f /etc/nftables.conf && echo "ruleset ok"
sudo systemctl reload nftables
```

Проверка `nft -c` перед применением обязательна: битый ruleset при прямом
применении может отрезать доступ к хабу.

Таблицы `nat` нет вообще — маскировать нечего, весь форвардинг замкнут
внутри `wg0`.

---

## 8. DNS

### Резолвер самого хаба

Хаб должен резолвить публичные имена (apt, исходящие запросы) независимо
от dnsmasq. Иначе получается циклическая зависимость: dnsmasq не
поднялся — сломался apt.

```bash
sudo systemctl disable --now systemd-resolved 2>/dev/null || true

sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf

sudo tee /etc/resolv.conf << 'EOF'
# Hub resolves independently of dnsmasq and the overlay.
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

sudo chattr +i /etc/resolv.conf
lsattr /etc/resolv.conf   # ----i---------
```

Иммутабельный флаг не даёт dhclient или пакетам переписать файл.

### dnsmasq — внутренняя зона + апстрим

Слушает только на overlay-IP. Внешние запросы уходят на NextDNS (с
Cloudflare как fallback) прямо с хаба — падение site_a не влияет на резолв
у клиентов оверлея.

Запуск после появления `wg0`:

```bash
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d

sudo tee /etc/systemd/system/dnsmasq.service.d/wg-ordering.conf << 'EOF'
[Unit]
# Clear the packaged Before=nss-lookup.target, then order after wg0.
Before=
After=wg-quick@wg0.service
# Restart dnsmasq whenever wg0 restarts, so it re-binds the overlay address.
# PartOf propagates stop/restart only - it adds no start-ordering dependency
# and therefore no cycle.
PartOf=wg-quick@wg0.service

[Service]
# After= guarantees unit ordering, not kernel state: wg-quick can report
# success a moment before the address is visible, and dnsmasq with
# bind-dynamic then finds nothing to bind and silently listens nowhere.
# Wait for the address itself, with a bounded timeout so a broken wg0
# cannot hang boot.
ExecStartPre=/bin/sh -c 'for i in $(seq 30); do ip -4 addr show dev wg0 2>/dev/null | grep -q "10\.99\.0\.1/" && exit 0; sleep 1; done; echo "wg0 address not ready" >&2; exit 1'
Restart=on-failure
RestartSec=5
EOF

sudo systemctl daemon-reload
```

`Wants=` намеренно не указывается: он создаёт цикл stop-зависимостей
(`nss-lookup.target` → dnsmasq → `wg-quick@wg0` → network → `nss-lookup.target`)
и мешает корректно останавливать wg0 при перезагрузке.

Проверить, что drop-in подхватился:

```bash
systemctl show dnsmasq -p After | tr ' ' '\n' | grep wg-quick
```

Профиль NextDNS идентифицируется через `add-cpe-id` — идентификатор
передаётся в EDNS0-опции самого запроса, поэтому привязка публичного IP
(Linked IP) не нужна и работает независимо от смены IP droplet'а.

```bash
sudo tee /etc/dnsmasq.d/wg-internal.conf << 'EOF'
listen-address=10.99.0.1
bind-dynamic
no-resolv
strict-order
domain-needed
bogus-priv
cache-size=2000

# NextDNS profile ID - sent as an EDNS0 option, no Linked IP needed.
# Applies to every upstream query, including the Cloudflare fallback below.
add-cpe-id=5a7224

# IPv4 first: with strict-order dnsmasq queries upstreams in this exact
# order, and unreachable IPv6 servers would stall every lookup on a
# droplet without IPv6. Add the v6 entries only if IPv6 is enabled.
server=45.90.28.0
server=45.90.30.0
# server=2a07:a8c0::
# server=2a07:a8c1::

# Last-resort fallback if NextDNS anycast is unreachable
server=1.1.1.1

# Authoritative zone - never forwarded upstream
local=/in.threadnull.dev/

host-record=hub.in.threadnull.dev,10.99.0.1
host-record=router-a.in.threadnull.dev,10.99.0.11
host-record=router-b.in.threadnull.dev,10.99.0.12
EOF

sudo systemctl restart dnsmasq
```

Проверить, что запросы реально доходят до вашего профиля: изнутри оверлея
открыть `test.nextdns.io` — ответ должен содержать ваш ID профиля. Если
показывает `unconfigured` — `add-cpe-id` не применился, проверьте, что
файл не перекрыт другим конфигом в `/etc/dnsmasq.d/`.

---

## 9. Мониторинг

Только системные метрики: CPU, память, диск, сетевые интерфейсы, состояние
systemd-юнитов.

```bash
sudo tee /etc/default/prometheus-node-exporter << 'EOF'
ARGS="--web.listen-address=10.99.0.1:9100"
EOF

sudo systemctl restart prometheus-node-exporter
```

Слушает только на overlay-адресе. Добавить `10.99.0.1:9100` как таргет в
существующий Prometheus.

WireGuard-метрики (возраст handshake, трафик по пирам) через Prometheus не
собираются — их читает PHP-админка напрямую из `wg show`.

---

## 10. Запуск и DO Cloud Firewall

```bash
sudo systemctl enable --now wg-quick@wg0 wg0-routes
sudo systemctl enable --now dnsmasq nftables prometheus-node-exporter

sudo wg show
```

Когда оверлей поднят и `ssh ops@10.99.0.1` работает через туннель —
закрыть публичный SSH.

Панель DO: **Networking → Firewalls → Create Firewall**, привязать к
droplet'у.

Inbound rules:
- `UDP 51820` — Sources: `All IPv4, All IPv6`
- `TCP 22` — **не добавлять**

После этого SSH снаружи недоступен; управление — только через туннель.
Аварийный доступ — веб-консоль DO (Access → Console), она не зависит от
сетевых правил.

---

## 11. Сертификаты

`lego` + Cloudflare DNS-01 живёт на сервисной VPS, не на хабе. Хаб в
выпуске и раздаче сертификатов не участвует: ни портов, ни файлов с его
стороны не требуется. Сервисные VPS забирают готовый сертификат оттуда же,
где он выпускается.

---

## 12. Добавление пира

```bash
PEER=<name>
IP=10.99.0.<N>

(umask 077; wg genkey | sudo tee /etc/wireguard/peers/${PEER}.priv | \
   wg pubkey | sudo tee /etc/wireguard/peers/${PEER}.pub) > /dev/null
(umask 077; wg genpsk | sudo tee /etc/wireguard/peers/${PEER}.psk) > /dev/null
sudo chmod 600 /etc/wireguard/peers/${PEER}.priv /etc/wireguard/peers/${PEER}.psk
```

Добавить блок в `/etc/wireguard/wg0.conf`:

```
[Peer]
PublicKey = <содержимое peers/<name>.pub>
PresharedKey = <содержимое peers/<name>.psk>
AllowedIPs = 10.99.0.<N>/32
```

Для нового **сайта** — плюс его LAN-супернет в `AllowedIPs`, и не забыть
добавить маршрут в `wg0-routes.sh` с последующим
`sudo systemctl restart wg0-routes`.

Применить без разрыва существующих сессий:

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip /etc/wireguard/wg0.conf)
```

DNS-запись — в `/etc/dnsmasq.d/wg-internal.conf`, затем
`sudo systemctl restart dnsmasq`.

Конфиг для клиента:

```bash
cat << EOF
[Interface]
PrivateKey = $(sudo cat /etc/wireguard/peers/${PEER}.priv)
Address = ${IP}/24
DNS = 10.99.0.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/wg0.pub)
PresharedKey = $(sudo cat /etc/wireguard/peers/${PEER}.psk)
Endpoint = <публичный-IP-хаба>:51820
AllowedIPs = 10.99.0.0/24, 10.1.0.0/16, 10.2.0.0/16
PersistentKeepalive = 25
EOF
```

`AllowedIPs` у клиента содержит только приватные диапазоны — split tunnel:
через туннель идёт лишь трафик к оверлею и LAN сайтов, остальное — мимо.
Для MikroTik вместо этого — соответствующие команды `/interface/wireguard`
на роутере, ключи те же.

QR-код для мобильного клиента:

```bash
qrencode -t ansiutf8 < <клиентский-конфиг>
```

### Ротация ключей пира

```bash
sudo rm /etc/wireguard/peers/<name>.{priv,pub,psk}
# перегенерировать по инструкции выше, обновить блок в wg0.conf,
# применить syncconf, доставить новый конфиг на устройство
```

---

## 13. Настройка MikroTik на сайтах

Конфигурация заметно короче прежней: пропадает весь блок BGP (instance,
connection, routing id, address-list, blackhole-якорь) — вместо динамического
анонса LAN-супернетов ставится один статический маршрут к сети соседнего
сайта. Всё, что делал `output.default-originate=if-installed` (анонс
дефолта, пока жив WAN), больше не нужно: выхода в интернет через сайты в
новой схеме нет.

Выполнять **в Safe Mode**, если подключены удалённо: в терминале нажать
`Ctrl+X`, выполнить блок, при успехе снова `Ctrl+X` для фиксации. При
разрыве связи роутер сам откатит изменения.

### Конфигурация (site_a)

Ключи и PSK берутся с хаба: приватный ключ роутера — из
`/etc/wireguard/peers/site_a.priv`, публичный ключ хаба — из
`/etc/wireguard/wg0.pub`, PSK — из `/etc/wireguard/peers/site_a.psk`.

```
# 1. This router's private key (generated on the hub)
/interface wireguard set [find name=wg-client] private-key="<peers/site_a.priv>"

# 2. Hub peer.
#    allowed-address covers the overlay and the OTHER site's LAN supernet —
#    this is the encryption/routing filter, not a routing table entry.
/interface wireguard peers add interface=wg-client \
    public-key="<wg0.pub>" \
    preshared-key="<peers/site_a.psk>" \
    endpoint-address=<публичный-IP-хаба> endpoint-port=51820 \
    persistent-keepalive=25s \
    allowed-address=10.99.0.0/24,10.2.0.0/16

# 3. Overlay address (unchanged)
/ip address set [find interface=wg-client] address=10.99.0.11/24 network=10.99.0.0

# 4. Static route to the other site's LAN.
#    BGP used to install this dynamically; RouterOS does NOT create routes
#    from allowed-address, so it has to be explicit now.
/ip route add dst-address=10.2.0.0/16 gateway=10.99.0.1 comment="site_b LAN via hub"

# 5. Internal zone DNS: forward *.in.threadnull.dev to the hub
/ip dns static remove [find type=FWD name="in.threadnull.dev"]
/ip dns static add type=FWD name="in.threadnull.dev" match-subdomain=yes forward-to=10.99.0.1
```

### site_b

То же самое с зеркальными значениями: `peers/site_b.*` вместо
`peers/site_a.*`, адрес `10.99.0.12/24`, в `allowed-address` —
`10.99.0.0/24,10.1.0.0/16`, статический маршрут на `10.1.0.0/16`.

### Проверка на роутере

```
/interface wireguard peers print detail    # last-handshake должен обновляться
/ping 10.99.0.1 count=4                    # хаб доступен
/ping 10.99.0.12 count=4                   # соседний сайт (с site_a)
/ip route print where dst-address=10.2.0.0/16
:put [:resolve hub.in.threadnull.dev]      # должно вернуть 10.99.0.1
```

Если handshake не появляется — проверьте, что на хабе публичный ключ
именно этого роутера прописан в блоке `[Peer]`, и что UDP 51820 открыт
в DO Cloud Firewall.

---

## 14. Проверка

```bash
echo "=== ip_forward ===" && sysctl net.ipv4.ip_forward && \
echo "=== services ===" && systemctl is-active wg-quick@wg0 wg0-routes \
    nftables dnsmasq prometheus-node-exporter && \
echo "=== peers ===" && sudo wg show && \
echo "=== routes ===" && ip route show | grep wg0 && \
echo "=== dns ===" && dig +short @10.99.0.1 hub.in.threadnull.dev && \
dig +short @10.99.0.1 example.com && \
echo "=== metrics ===" && curl -s 10.99.0.1:9100/metrics | head -3
```

Ожидаем: `ip_forward = 1`, все юниты `active`, у каждого пира handshake
свежее 120 секунд, маршруты на месте, DNS отвечает и на внутреннюю зону,
и на внешнюю.

Site-to-site отдельно: с устройства в LAN site_a пингануть адрес в LAN
site_b — трафик должен пройти через хаб.

---

## 15. Диагностика

**Пир не доступен**

```
1. sysctl net.ipv4.ip_forward        -> 0: sudo sysctl -w net.ipv4.ip_forward=1
2. sudo wg show wg0 latest-handshakes -> нет handshake: битый конфиг/ключи
                                          на стороне пира, или нет keepalive
3. sudo nft list chain inet filter forward -> нет подходящего правила
4. ip route show | grep wg0          -> нет маршрута: systemctl restart wg0-routes
```

**DNS не резолвит `*.in.threadnull.dev`**

```
1. dig @10.99.0.1 <имя>.in.threadnull.dev
   -> NXDOMAIN/таймаут: systemctl status dnsmasq; ss -ulnp | grep :53
2. dig работает, а клиент нет -> клиент не спрашивает 10.99.0.1
   MikroTik:  /ip dns static add type=FWD name="in.threadnull.dev" forward-to=10.99.0.1
   Linux:     resolvectl status / cat /etc/resolv.conf
```

**Логи**

```bash
journalctl -u wg-quick@wg0 -u wg0-routes -u nftables -u dnsmasq \
           --since "1 hour ago" --no-pager

journalctl -k | grep "nft_forward_drop\|nft_input_drop"
```

**Полезные команды**

```bash
sudo wg show wg0 latest-handshakes   # возраст handshake по пирам
sudo wg show wg0 transfer            # трафик; 0 у живого пира = подозрительно
sudo nft list ruleset                # что реально в ядре, не что в файле
sudo nft -c -f /etc/nftables.conf    # проверка без применения
ip route show table all | grep wg
```
