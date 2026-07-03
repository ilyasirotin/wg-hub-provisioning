# Ручная установка хаба

Пошаговое руководство по поднятию хаба без Ansible. Каждый блок соответствует
конкретной задаче из плейбука, поэтому его удобно читать параллельно с кодом
ролей (`roles/base_hardening`, `roles/wg_hub`, `roles/certs_hub`).

**Модель сети** (из `group_vars/all/network.yml`):
- Overlay: `10.99.0.0/24`, интерфейс `wg0`, порт UDP `51820`
- Hub: `10.99.0.1`, публичный IP `65.21.177.182`
- SSH-порт после hardening: `5860`
- Домен: `in.threadnull.dev`

---

## Шаг 0 — Создание служебного пользователя

Выполняется один раз на свежем сервере от root.

```bash
adduser wg
usermod -aG sudo wg
mkdir -p /home/wg/.ssh
cp ~/.ssh/authorized_keys /home/wg/.ssh/
chown -R wg:wg /home/wg/.ssh
chmod 700 /home/wg/.ssh
chmod 600 /home/wg/.ssh/authorized_keys
echo 'wg ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/wg
chmod 0440 /etc/sudoers.d/wg
```

После этого подключаться только как `wg`:
```bash
ssh -p 22 wg@65.21.177.182
```

---

## Шаг 1 — Базовое усиление (роль `base_hardening`)

### 1.1 Обновление и установка пакетов

```bash
sudo apt update && sudo apt dist-upgrade -y
sudo apt install -y nftables fail2ban unattended-upgrades qrencode rsync curl python3-pexpect
```

Удалить ufw — он конфликтует с прямым управлением nftables:

```bash
sudo apt purge -y ufw
```

### 1.2 Настройка sshd

Перед записью убедитесь, что у вас открыта ещё одна SSH-сессия или вы готовы
переподключиться на порт `5860`.

```bash
sudo tee /etc/ssh/sshd_config.d/90-hardening.conf << 'EOF'
Port 5860
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
```

Перезапустить sshd (соединение на 22 оборвётся):

```bash
sudo systemctl restart ssh
```

Переподключиться:
```bash
ssh -p 5860 wg@65.21.177.182
```

### 1.3 Настройка fail2ban

```bash
sudo tee /etc/fail2ban/jail.d/sshd.local << 'EOF'
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port = 5860
maxretry = 5
bantime = 1h
EOF

sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
```

### 1.4 Автоматические обновления безопасности

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

### 1.5 Включить nftables как сервис

```bash
sudo systemctl enable nftables
```

---

## Шаг 2 — WireGuard и маршрутизация (роль `wg_hub`)

### 2.1 Установка пакетов

```bash
sudo apt install -y wireguard dnsmasq
```

### 2.2 IP-форвардинг

```bash
sudo tee /etc/sysctl.d/99-wg-hub.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

Проверить:
```bash
sysctl net.ipv4.ip_forward  # должно вернуть 1
```

### 2.3 Директории для ключей

```bash
sudo mkdir -p /etc/wireguard/clients
sudo chmod 700 /etc/wireguard /etc/wireguard/clients
```

### 2.4 Генерация ключей сервера

```bash
(umask 077; wg genkey | sudo tee /etc/wireguard/server.priv | wg pubkey | sudo tee /etc/wireguard/server.pub)
```

Посмотреть публичный ключ хаба (нужен при настройке роутеров):
```bash
sudo cat /etc/wireguard/server.pub
```

### 2.5 Генерация ключей пиров

Для каждого пира (site_a, site_b, pixel_10_pro_home, pixel_10_pro_cloud) — пара
ключей и PSK. Флаг `creates:` в Ansible делает это идемпотентным; вручную
следует не перезаписывать уже существующие ключи.

```bash
for PEER in site_a site_b pixel_10_pro_home pixel_10_pro_cloud; do
    PRIV="/etc/wireguard/clients/${PEER}.priv"
    PUB="/etc/wireguard/clients/${PEER}.pub"
    PSK="/etc/wireguard/clients/${PEER}.psk"

    if [ ! -f "$PRIV" ]; then
        (umask 077; wg genkey | sudo tee "$PRIV" | wg pubkey | sudo tee "$PUB") > /dev/null
        (umask 077; wg genpsk | sudo tee "$PSK") > /dev/null
        echo "Сгенерированы ключи для $PEER"
    else
        echo "Ключи для $PEER уже существуют — пропускаем"
    fi
done
```

Зафиксировать права:
```bash
sudo chmod 600 /etc/wireguard/server.priv \
               /etc/wireguard/clients/*.priv \
               /etc/wireguard/clients/*.psk
```

### 2.6 Конфиг WireGuard (`/etc/wireguard/wg0.conf`)

Читаем все ключи — они понадобятся в конфиге:

```bash
SERVER_PRIV=$(sudo cat /etc/wireguard/server.priv)

SITE_A_PUB=$(sudo cat /etc/wireguard/clients/site_a.pub)
SITE_A_PSK=$(sudo cat /etc/wireguard/clients/site_a.psk)

SITE_B_PUB=$(sudo cat /etc/wireguard/clients/site_b.pub)
SITE_B_PSK=$(sudo cat /etc/wireguard/clients/site_b.psk)

HOME_PUB=$(sudo cat /etc/wireguard/clients/pixel_10_pro_home.pub)
HOME_PSK=$(sudo cat /etc/wireguard/clients/pixel_10_pro_home.psk)

CLOUD_PUB=$(sudo cat /etc/wireguard/clients/pixel_10_pro_cloud.pub)
CLOUD_PSK=$(sudo cat /etc/wireguard/clients/pixel_10_pro_cloud.psk)
```

Записать конфиг:

```bash
sudo tee /etc/wireguard/wg0.conf << EOF
# Table = off: маршруты управляются отдельным скриптом (wg0-routes.sh),
# а не wg-quick, чтобы изменения пиров применялись через wg syncconf
# без рестарта туннеля.
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIV}
Table = off

# site: site_a - House A - primary exit
# AllowedIPs: overlay IP + /16 supernet. 0.0.0.0/0 выбранного exit-сайта —
# это runtime-состояние: его добавляет демон wg-exit-sync по данным BGP
# (см. 2.8a), в конфиге его намеренно НЕТ.
[Peer]
PublicKey = ${SITE_A_PUB}
PresharedKey = ${SITE_A_PSK}
AllowedIPs = 10.99.0.11/32, 10.1.0.0/16

# site: site_b - House B - remote (backup exit)
# AllowedIPs: overlay IP + /16 supernet (WireGuard peer selection only;
# actual LAN routes are installed by bgpd via eBGP, not wg-quick)
[Peer]
PublicKey = ${SITE_B_PUB}
PresharedKey = ${SITE_B_PSK}
AllowedIPs = 10.99.0.12/32, 10.2.0.0/16

# client: pixel_10_pro_home
[Peer]
PublicKey = ${HOME_PUB}
PresharedKey = ${HOME_PSK}
AllowedIPs = 10.99.0.20/32

# client: pixel_10_pro_cloud
[Peer]
PublicKey = ${CLOUD_PUB}
PresharedKey = ${CLOUD_PSK}
AllowedIPs = 10.99.0.21/32
EOF

sudo chmod 600 /etc/wireguard/wg0.conf
```

Проверить синтаксис:
```bash
sudo wg-quick strip /etc/wireguard/wg0.conf
```

### 2.7 Скрипт маршрутов и PBR (`/usr/local/sbin/wg0-routes.sh`)

Маршруты вынесены из PostUp, чтобы изменения пиров можно было применять через
`wg syncconf` без перезапуска интерфейса.

PBR (policy-based routing, таблица 123): трафик от `pixel_10_pro_home`
(profile: home) уходит в интернет через site_a (домашний роутер), а не через VPS.

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
rule() {
  local op="$1"; shift
  ip rule del "$@" 2>/dev/null || true
  if [ "$op" = add ]; then ip rule add "$@"; fi
}

if [ "$ACTION" = up ]; then OP=add; else OP=del; fi

# Overlay-подсеть
route "$OP" 10.99.0.0/24 dev "$IFACE"

# LAN-маршруты сайтов управляются bgpd (frr.service) через eBGP, не здесь.
# При падении WireGuard-сессии сайта BGP автоматически отзывает его маршруты.
# Просмотр: ip route show proto bgp

# Таблица 123: fail-closed пол. FRR устанавливает сюда BGP-выбранный
# exit-дефолт с metric 20 (затеняет пол); если ни один exit-сайт не
# анонсирует 0.0.0.0/0 — побеждает пол, home-клиенты без интернета
# (fail closed), утечки через аплинк хаба нет.
route "$OP" unreachable default table 123 metric 4294967294

# pixel_10_pro_home (profile: home) -> интернет через выбранный exit-сайт
rule "$OP" from 10.99.0.20/32 table 123

exit 0
EOF

sudo chmod 755 /usr/local/sbin/wg0-routes.sh
```

### 2.8 Systemd-юнит для маршрутов (`wg0-routes.service`)

Юнит привязан к `wg-quick@wg0` (`BindsTo`) — маршруты автоматически
поднимаются и убираются вместе с туннелем.

```bash
sudo tee /etc/systemd/system/wg0-routes.service << 'EOF'
[Unit]
Description=Routing rules for wg0 (generated by Ansible)
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

### 2.8a Демон exit-failover (`wg-exit-sync`)

Exit data path — runtime-состояние. Exit-способные сайты анонсируют дефолт по
BGP; FRR (2.15) выбирает лучший, но zebra его в ядро не ставит. Демон
опрашивает результат election у bgpd (каждые 5 с) и программирует обе
половины: дефолт в таблице 123 (`proto static`, metric 20) и `0.0.0.0/0` в
AllowedIPs выбранного пира — при падении текущего exit-сайта хаб
автоматически переключается на следующий, при восстановлении возвращается
(preempt). Если дефолт не анонсирует никто — демон убирает и маршрут, и 0/0,
а unreachable-пол в таблице 123 даёт fail-closed.

Карта соответствия nexthop → пир (по одной строке на exit-сайт, в порядке
приоритета):

```bash
sudo tee /etc/wireguard/exit-peers.map << EOF
# <bgp-nexthop> <wg-pubkey> <base-allowed-ips>
10.99.0.11 ${SITE_A_PUB} 10.99.0.11/32,10.1.0.0/16
10.99.0.12 ${SITE_B_PUB} 10.99.0.12/32,10.2.0.0/16
EOF
sudo chmod 600 /etc/wireguard/exit-peers.map
```

Скрипт демона — см. `roles/wg_hub/templates/wg-exit-sync.sh.j2` (логика:
`vtysh -c 'show bgp ipv4 unicast 0.0.0.0/0 json'` → nexthop лучшего пути →
`ip route replace default via <gw> dev wg0 table 123 metric 20 proto static`
+ `wg set <peer> allowed-ips <base>,0.0.0.0/0`; ядро атомарно забирает
префикс у прежнего владельца). Установить в `/usr/local/sbin/wg-exit-sync.sh`
(chmod 755) и создать юнит:

```bash
sudo tee /etc/systemd/system/wg-exit-sync.service << 'EOF'
[Unit]
Description=WireGuard exit-node failover sync (generated by Ansible)
After=wg-quick@wg0.service frr.service
BindsTo=wg-quick@wg0.service

[Service]
ExecStart=/usr/local/sbin/wg-exit-sync.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

Важно: после каждого `wg syncconf` (который сбрасывает runtime 0/0) демон
надо перезапустить — Ansible-хендлер делает это автоматически.

### 2.9 Файрвол (`/etc/nftables.conf`)

Найти публичный интерфейс сервера:
```bash
ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
# Обычно eth0 или ens3. Подставить ниже вместо <PUB_IFACE>.
```

**Логика зонирования:**
- `admin` (pixel_10_pro_home): полный доступ ко всему
- `user` (pixel_10_pro_cloud): только интернет через VPS
- `site_a_nets`, `site_b_nets`: site-to-site между собой
- NAT: только облачный профиль (pixel_10_pro_cloud) маскируется под IP VPS

Для **bootstrap** (пока нет overlay): временно разрешить SSH на публичном интерфейсе
добавив строку `tcp dport 5860 accept comment "bootstrap"` в цепочку `input`
(удалить после успешного подключения через оверлей).

```bash
# Подставить реальный публичный интерфейс:
PUB_IFACE=eth0   # заменить по результату команды выше

sudo tee /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
# Зонирование overlay-сети хаба.
# admin - всё; user - интернет + объявленные сервисы; sites - site-to-site.

flush ruleset

table inet filter {
    set admin_ips {
        type ipv4_addr
        elements = { 10.99.0.20 }
    }
    set user_ips {
        type ipv4_addr
        elements = { 10.99.0.21 }
    }
    set site_nets {
        type ipv4_addr
        flags interval
        elements = {
            10.99.0.11/32,
            10.1.10.0/24, 10.1.20.0/24, 10.1.30.0/24, 10.1.40.0/24,
            10.99.0.12/32,
            10.2.10.0/24, 10.2.20.0/24, 10.2.30.0/24, 10.2.40.0/24, 10.2.100.0/24
        }
    }
    set site_a_nets {
        type ipv4_addr
        flags interval
        elements = { 10.99.0.11/32, 10.1.10.0/24, 10.1.20.0/24, 10.1.30.0/24, 10.1.40.0/24 }
    }
    set site_b_nets {
        type ipv4_addr
        flags interval
        elements = { 10.99.0.12/32, 10.2.10.0/24, 10.2.20.0/24, 10.2.30.0/24, 10.2.40.0/24, 10.2.100.0/24 }
    }
    set iot_nets {
        type ipv4_addr
        flags interval
        elements = { 10.1.30.0/24, 10.2.30.0/24 }
    }
    set rfc1918 {
        type ipv4_addr
        flags interval
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp limit rate 20/second accept

        # WireGuard handshakes
        udp dport 51820 accept

        # SSH — только через overlay (после bootstrap удалить строку ниже)
        tcp dport 5860 accept comment "bootstrap: удалить после первого подключения через wg0"
        iifname "wg0" tcp dport 5860 accept

        # Внутренний DNS — только через overlay
        iifname "wg0" udp dport 53 accept
        iifname "wg0" tcp dport 53 accept

        # BGP — только через overlay (для eBGP-сессий с роутерами сайтов)
        iifname "wg0" tcp dport 179 accept

        log prefix "nft_input_drop: " counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # MSS clamping — предотвращает зависание сессий через PPPoE/VPN
        tcp flags syn tcp option maxseg size set rt mtu

        # admin: полный доступ
        iifname "wg0" ip saddr @admin_ips accept

        # site-to-site
        iifname "wg0" oifname "wg0" ip saddr @site_a_nets ip daddr @site_b_nets accept
        iifname "wg0" oifname "wg0" ip saddr @site_b_nets ip daddr @site_a_nets accept

        # user: только интернет (не RFC-1918)
        iifname "wg0" ip saddr @user_ips ip daddr != @rfc1918 accept

        log prefix "nft_forward_drop: " counter drop
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # pixel_10_pro_cloud (profile: cloud) выходит с IP VPS
        oifname "${PUB_IFACE}" ip saddr 10.99.0.0/24 masquerade
    }
}
EOF
```

Проверить синтаксис и применить:
```bash
sudo nft -c -f /etc/nftables.conf   # сухая проверка
sudo systemctl reload nftables
```

### 2.10 Resolver хаба (`/etc/resolv.conf`)

Хаб должен всегда резолвить публичные адреса (Let's Encrypt, apt) независимо от
dnsmasq и overlay. Поэтому `/etc/resolv.conf` пинируется к публичным серверам
и делается иммутабельным.

Отключить systemd-resolved, если он присутствует (занимает порт 53 и
перезаписывает resolv.conf):
```bash
sudo systemctl disable --now systemd-resolved 2>/dev/null || true
```

Заменить resolv.conf (убрать атрибут иммутабельности, если он был):
```bash
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf

sudo tee /etc/resolv.conf << 'EOF'
# Хаб резолвит через публичные серверы независимо от dnsmasq.
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

sudo chattr +i /etc/resolv.conf
```

Проверить:
```bash
lsattr /etc/resolv.conf   # должно показать ----i---------
curl -s https://example.com | head -5   # хаб должен резолвить и ходить в интернет
```

### 2.11 dnsmasq — внутренняя зона

**Drop-in**: запускать dnsmasq только после поднятия wg0.

```bash
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d

sudo tee /etc/systemd/system/dnsmasq.service.d/wg-ordering.conf << 'EOF'
[Unit]
Before=
After=wg-quick@wg0.service
EOF
# Примечание: Wants= намеренно не указывается — это создаёт цикл stop-зависимостей
# (nss-lookup.target → dnsmasq → wg-quick@wg0 → network → nss-lookup.target)
# и мешает корректной остановке wg0 при перезагрузке.
```

**Конфиг внутренней зоны:**

dnsmasq слушает только на overlay-IP `10.99.0.1`. Запросы к `in.threadnull.dev`
обрабатывает локально, всё остальное форвардит на роутер A (NextDNS), запасной — `1.1.1.1`.

```bash
sudo tee /etc/dnsmasq.d/wg-internal.conf << 'EOF'
listen-address=10.99.0.1
bind-dynamic
no-resolv
strict-order
server=10.99.0.11
server=1.1.1.1
domain-needed
bogus-priv
cache-size=2000

# Зона in.threadnull.dev не форвардится наружу
local=/in.threadnull.dev/

# A-записи overlay
host-record=hub.in.threadnull.dev,10.99.0.1
host-record=router-a.in.threadnull.dev,10.99.0.11
host-record=router-b.in.threadnull.dev,10.99.0.12
host-record=pixel-10-pro-home.in.threadnull.dev,10.99.0.20
host-record=pixel-10-pro-cloud.in.threadnull.dev,10.99.0.21
EOF
```

### 2.12 Клиентские конфиги

Читаем публичный ключ сервера и ключи клиентов:

```bash
SERVER_PUB=$(sudo cat /etc/wireguard/server.pub)

# pixel_10_pro_home (group: admin, profile: home -> трафик через роутер A)
sudo tee /etc/wireguard/clients/pixel_10_pro_home.conf << EOF
# group: admin, profile: home
[Interface]
Address = 10.99.0.20/32
PrivateKey = $(sudo cat /etc/wireguard/clients/pixel_10_pro_home.priv)
DNS = 10.99.0.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = $(sudo cat /etc/wireguard/clients/pixel_10_pro_home.psk)
Endpoint = 65.21.177.182:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
sudo chmod 600 /etc/wireguard/clients/pixel_10_pro_home.conf

# pixel_10_pro_cloud (group: user, profile: cloud -> трафик через IP VPS)
sudo tee /etc/wireguard/clients/pixel_10_pro_cloud.conf << EOF
# group: user, profile: cloud
[Interface]
Address = 10.99.0.21/32
PrivateKey = $(sudo cat /etc/wireguard/clients/pixel_10_pro_cloud.priv)
DNS = 10.99.0.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = $(sudo cat /etc/wireguard/clients/pixel_10_pro_cloud.psk)
Endpoint = 65.21.177.182:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
sudo chmod 600 /etc/wireguard/clients/pixel_10_pro_cloud.conf
```

QR-код для импорта в WireGuard-приложение:
```bash
sudo qrencode -t ansiutf8 < /etc/wireguard/clients/pixel_10_pro_home.conf
sudo qrencode -t ansiutf8 < /etc/wireguard/clients/pixel_10_pro_cloud.conf
```

### 2.13 MikroTik-сниппет для site_a

Команды вставляются в терминал роутера (Winbox или SSH). Ключи уже содержат
конкретные значения — никаких плейсхолдеров. Сниппет настраивает WireGuard
**и** eBGP за один проход.

Сниппет генерируется автоматически при `ansible-playbook playbooks/hub.yml`
и сохраняется в `/etc/wireguard/clients/site_a.rsc` на хабе.

```
# ── WireGuard ────────────────────────────────────────────────────────────────

# 1. Приватный ключ роутера (сгенерирован хабом)
/interface wireguard set [find name=wg-client] private-key="<KEY>"

# 2. Peer — хаб (allowed-address: оверлей + /16 суперсеть site_b)
/interface wireguard peers remove [find interface=wg-client]
/interface wireguard peers add interface=wg-client \
    public-key="<HUB_PUB>" \
    preshared-key="<PSK>" \
    endpoint-address=65.21.177.182 endpoint-port=51820 \
    persistent-keepalive=25s \
    allowed-address=10.99.0.0/24,10.2.0.0/16

# 3. IP на overlay-интерфейсе
/ip address set [find interface=wg-client] address=10.99.0.11/24 network=10.99.0.0

# 4. Форвардинг *.in.threadnull.dev -> хаб
/ip dns static remove [find type=FWD name="in.threadnull.dev"]
/ip dns static add type=FWD name="in.threadnull.dev" forward-to=10.99.0.1

# ── BGP (eBGP к хабу, анонсирует суперсеть LAN этого сайта) ─────────────────

# 5. Router ID привязан к overlay IP
/routing id add name=wg-bgp-id id=10.99.0.11

# 6. BGP инстанс (ASN 65011 = 65010 + номер сайта 1)
/routing bgp instance add name=wg-bgp-inst as=65011 router-id=wg-bgp-id

# 7. Список подсетей для анонса хабу
/ip firewall address-list add list=BGP-EXPORT address=10.1.0.0/16

# 8. BGP соединение с хабом. output.default-originate=if-installed (только
#    на exit-способных сайтах): анонсирует 0.0.0.0/0 пока в таблице есть
#    установленный дефолт (динамический от ISP) — умер WAN → дефолт отозван,
#    хаб переключается на следующий exit-сайт. output.network для дефолта
#    не годится: он подхватывает только статические маршруты.
/routing bgp connection add name=wg-hub \
    instance=wg-bgp-inst \
    local.address=10.99.0.11 \
    local.role=ebgp \
    remote.address=10.99.0.1 \
    remote.as=65001 \
    output.network=BGP-EXPORT \
    output.default-originate=if-installed \
    connect=yes \
    listen=yes

# 9. Blackhole-анкор — BGP анонсирует только те префиксы, что есть в таблице.
#    Реальный трафик никогда не дропается: /24 VLAN-маршруты более специфичны.
/ip route add dst-address=10.1.0.0/16 blackhole comment="BGP advertisement anchor"
```

Для `site_b` структура идентична: ASN=65012, IP=10.99.0.12, address=10.2.0.0/16,
allowed-address в WireGuard-пире = `10.99.0.0/24,10.1.0.0/16`.
`output.default-originate=if-installed` ставится на каждом exit-способном сайте
(какие сайты принимает хаб и с каким приоритетом — решает route-map `OVERLAY-IN`
на хабе, см. 2.15).

### 2.14 Запуск всех сервисов

```bash
sudo systemctl daemon-reload

# Поднять туннель (wg0-routes запустится автоматически через BindsTo)
sudo systemctl enable --now wg-quick@wg0

# Убедиться, что маршруты применились
sudo systemctl enable --now wg0-routes

# nftables
sudo systemctl enable nftables
sudo systemctl restart nftables

# dnsmasq (стартует после wg0 согласно drop-in)
sudo systemctl enable --now dnsmasq

# frr (BGP — динамические LAN-маршруты сайтов, стартует после wg0)
sudo systemctl enable --now frr

# демон exit-failover (после frr — ему нужен BGP-дефолт в таблице 123)
sudo systemctl enable --now wg-exit-sync
```

### 2.15 FRRouting / BGP (роль `frr_hub`)

Хаб устанавливает eBGP-сессии с роутерами сайтов через WireGuard-оверлей. LAN-маршруты
сайтов (`10.N.0.0/16`) устанавливаются динамически — при падении туннеля маршруты
отзываются автоматически. Кроме того, здесь живёт **выбор exit-дефолта**: сайты с
`exit_priority` анонсируют `0.0.0.0/0`, route-map `OVERLAY-IN` принимает дефолт только
от них и назначает local-pref (= 1000 − priority). Route-map `BGP-TO-KERNEL` не пускает
выбранный дефолт в ядро (иначе при флапе аплинка он мог бы захватить egress самого
хаба; zebra `set table` в FRR 10 молча не загружается) — в таблицу 123 его ставит
демон wg-exit-sync (2.8a).

```bash
sudo apt install -y frr
```

Включить bgpd (все остальные демоны оставить выключенными):

```bash
sudo tee /etc/frr/daemons.conf << 'EOF'
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
EOF
```

Конфигурация BGP (hub ASN 65001, слушать весь оверлей):

```bash
sudo tee /etc/frr/frr.conf << 'EOF'
! Managed by Ansible (roles/frr_hub). Do not edit by hand.
frr defaults traditional
hostname hub
log syslog informational
service integrated-vtysh-config
!
router bgp 65001
 bgp router-id 10.99.0.1
 bgp log-neighbor-changes
 no bgp ebgp-requires-policy
 !
 neighbor OVERLAY peer-group
 neighbor OVERLAY remote-as external
 neighbor OVERLAY description "WireGuard overlay peers (sites)"
 neighbor OVERLAY timers 5 15
 !
 bgp listen range 10.99.0.0/24 peer-group OVERLAY
 !
 address-family ipv4 unicast
  redistribute connected route-map ONLY-OVERLAY
  neighbor OVERLAY activate
  neighbor OVERLAY soft-reconfiguration inbound
  ! ВСЯ входная политика — в route-map OVERLAY-IN. Не добавлять сюда
  ! prefix-list ... in: FRR применяет ОБА фильтра, и prefix-list срежет
  ! 0.0.0.0/0 раньше route-map.
  neighbor OVERLAY route-map OVERLAY-IN in
  ! ИНВАРИАНТ: SAFE-OUT обязан резать 0.0.0.0/0 наружу, иначе сайты
  ! получат дефолт через хаб (петля / неверный egress).
  neighbor OVERLAY prefix-list SAFE-OUT out
 exit-address-family
!
ip prefix-list DEFAULT-ROUTE seq 5 permit 0.0.0.0/0
!
ip prefix-list SITE-LANS seq 5 permit 10.0.0.0/8 le 24
!
ip prefix-list NEXTHOP-SITE-A seq 5 permit 10.99.0.11/32
ip prefix-list NEXTHOP-SITE-B seq 5 permit 10.99.0.12/32
!
ip prefix-list SAFE-OUT seq 5 permit 10.99.0.0/24
ip prefix-list SAFE-OUT seq 10 permit 10.0.0.0/8 le 24
ip prefix-list SAFE-OUT seq 15 deny any
!
ip prefix-list OVERLAY-ONLY seq 5 permit 10.99.0.0/24
ip prefix-list OVERLAY-ONLY seq 10 deny any
!
route-map ONLY-OVERLAY permit 10
 match ip address prefix-list OVERLAY-ONLY
!
! Выбор exit-дефолта: 0.0.0.0/0 принимается только от exit-способных сайтов,
! local-pref = 1000 - exit_priority (site_a: 100 -> 900, site_b: 200 -> 800).
route-map OVERLAY-IN permit 10
 match ip address prefix-list DEFAULT-ROUTE
 match ip next-hop prefix-list NEXTHOP-SITE-A
 set local-preference 900
route-map OVERLAY-IN permit 20
 match ip address prefix-list DEFAULT-ROUTE
 match ip next-hop prefix-list NEXTHOP-SITE-B
 set local-preference 800
route-map OVERLAY-IN deny 500
 match ip address prefix-list DEFAULT-ROUTE
route-map OVERLAY-IN permit 600
 match ip address prefix-list SITE-LANS
!
! BGP-дефолт НЕ устанавливается zebra в ядро — таблицу 123 программирует
! демон wg-exit-sync по данным bgpd. Терминальный permit ОБЯЗАТЕЛЕН — без
! него zebra перестанет ставить в ядро остальные BGP-маршруты.
route-map BGP-TO-KERNEL deny 10
 match ip address prefix-list DEFAULT-ROUTE
route-map BGP-TO-KERNEL permit 20
!
ip protocol bgp route-map BGP-TO-KERNEL
!
EOF
sudo systemctl enable --now frr
```

---

## Шаг 3 — Сертификаты (роль `certs_hub`)

Хаб получает wildcard-сертификат `*.in.threadnull.dev` через DNS-01 challenge
в Cloudflare с помощью утилиты lego. Приватный ключ CF-токена хранится только
на хабе; сервисные VPS забирают готовый сертификат через `rrsync`.

### 3.1 Установка lego

```bash
LEGO_VERSION="5.2.2"
curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin lego
sudo chmod 755 /usr/local/bin/lego
lego --version
```

### 3.2 Директории и credentials

```bash
sudo mkdir -p /etc/lego /var/lib/lego
sudo chmod 700 /etc/lego /var/lib/lego
```

Создать Cloudflare API-токен:
- Cloudflare Dashboard → My Profile → API Tokens → Create Token
- Шаблон "Edit zone DNS", ограничить зоной `threadnull.dev`

```bash
# Вставить реальный токен:
sudo tee /etc/lego/cloudflare.env << 'EOF'
CLOUDFLARE_DNS_API_TOKEN=<ВАШ_ТОКЕН>
EOF
sudo chmod 600 /etc/lego/cloudflare.env
```

### 3.3 Скрипт обновления сертификата

```bash
sudo tee /usr/local/sbin/lego-renew.sh << 'EOF'
#!/usr/bin/env bash
# lego run: получает сертификат если его нет, обновляет когда подходит срок.
set -euo pipefail

LEGO=/usr/local/bin/lego
DATA=/var/lib/lego
PUB=/var/lib/wg-certs

if [ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ] && [ -f /etc/lego/cloudflare.env ]; then
  set -a; . /etc/lego/cloudflare.env; set +a
fi

ARGS=(run --accept-tos --path "$DATA" --email "me@threadnull.dev" --dns cloudflare)
ARGS+=(--domains "*.in.threadnull.dev")

"$LEGO" "${ARGS[@]}"

CRT="$(find "$DATA" -type f -name '*.crt' ! -name '*.issuer.crt' 2>/dev/null | head -1)"
KEY="${CRT%.crt}.key"

if [ -z "$CRT" ] || [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  echo "ERROR: сертификат или ключ не найдены в $DATA" >&2
  exit 1
fi

install -m 0640 -g certsync "$CRT" "$PUB/fullchain.pem"
install -m 0640 -g certsync "$KEY" "$PUB/privkey.pem"
EOF

sudo chmod 755 /usr/local/sbin/lego-renew.sh
```

### 3.4 Пользователь certsync и директория публикации

Сервисные VPS забирают готовый сертификат через ограниченный rsync-аккаунт.

```bash
sudo useradd --system --shell /bin/bash --create-home certsync
sudo mkdir -p /var/lib/wg-certs
sudo chown root:certsync /var/lib/wg-certs
sudo chmod 750 /var/lib/wg-certs

sudo mkdir -p /home/certsync/.ssh
sudo chown certsync:certsync /home/certsync/.ssh
sudo chmod 700 /home/certsync/.ssh
sudo touch /home/certsync/.ssh/authorized_keys
sudo chown certsync:certsync /home/certsync/.ssh/authorized_keys
sudo chmod 600 /home/certsync/.ssh/authorized_keys
```

### 3.5 Первичное получение сертификата

```bash
sudo CLOUDFLARE_DNS_API_TOKEN=$(sudo cat /etc/lego/cloudflare.env | cut -d= -f2-) \
     /usr/local/sbin/lego-renew.sh
```

Если всё прошло успешно:
```bash
ls -la /var/lib/wg-certs/   # fullchain.pem и privkey.pem
```

### 3.6 Systemd-таймер для автопродления

```bash
sudo tee /etc/systemd/system/lego-renew.service << 'EOF'
[Unit]
Description=Obtain/renew wildcard certificate via lego
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/lego/cloudflare.env
ExecStart=/usr/local/sbin/lego-renew.sh
EOF

sudo tee /etc/systemd/system/lego-renew.timer << 'EOF'
[Unit]
Description=Daily certificate renewal check

[Timer]
OnCalendar=*-*-* 04:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lego-renew.timer
```

---

## Шаг 4 — Проверка

### Состояние сервисов

```bash
sudo systemctl status wg-quick@wg0 wg0-routes nftables dnsmasq frr lego-renew.timer
```

### WireGuard

```bash
sudo wg show
# Ожидаем: интерфейс wg0 поднят, видны peer-записи для всех пиров
```

### BGP

```bash
sudo vtysh -c "show bgp summary"
# Ожидаем: State=Established для каждого подключённого сайта, PfxRcvd=1

ip route show proto bgp
# Ожидаем: 10.1.0.0/16 via 10.99.0.11 dev wg0 (и 10.2.0.0/16 при наличии site_b)
```

### Маршруты

```bash
ip route show dev wg0          # overlay + маршруты BGP-суперсетей сайтов
ip route show table 123        # default via 10.99.0.1N proto static metric 20
                               # + unreachable default metric 4294967294 (пол)
ip rule show                   # правило: from 10.99.0.20/32 table 123
sudo wg show wg0 allowed-ips | grep 0.0.0.0/0   # владелец 0/0 = BGP nexthop
journalctl -u wg-exit-sync -n 10                # решения демона failover
```

### nftables

```bash
sudo nft list ruleset
```

### DNS

```bash
# С устройства в overlay:
dig hub.in.threadnull.dev @10.99.0.1
dig router-a.in.threadnull.dev @10.99.0.1
```

### Сертификат

```bash
openssl x509 -in /var/lib/wg-certs/fullchain.pem -noout -subject -dates
# subject: CN=*.in.threadnull.dev
```

### Подключение клиента

После импорта QR-кода в WireGuard-приложение:
- `pixel_10_pro_cloud`: внешний IP должен быть `65.21.177.182` (IP VPS)
- `pixel_10_pro_home`: внешний IP должен быть домашним IP site_a

---

## Шаг 5 — Отключение публичного SSH (после верификации overlay)

Когда `ssh -p 5860 wg@10.99.0.1` работает через overlay, убрать временную
bootstrap-строку из nftables и оставить SSH только через wg0.

В `/etc/nftables.conf` в цепочке `input` удалить строку:
```
tcp dport 5860 accept comment "bootstrap: удалить после первого подключения через wg0"
```

Применить:
```bash
sudo nft -c -f /etc/nftables.conf   # проверка
sudo systemctl reload nftables
```

После этого SSH доступен только через WireGuard-туннель. Аварийный доступ — через
консоль Hetzner.

---

## Добавление нового пира (краткая схема)

**Через Ansible (рекомендуется):**
1. Добавить блок в `group_vars/all/network.yml` (site/client/service).
2. `ansible-playbook playbooks/hub.yml --ask-vault-pass` — генерирует ключи, обновляет `wg0.conf` через `wg syncconf`, ACL, DNS.
3. Для нового **сайта**: скопировать `/etc/wireguard/clients/<name>.rsc` с хаба, вставить в терминал MikroTik. Сниппет настроит WireGuard **и** BGP. Проверить: `vtysh -c "show bgp summary"`.

**Вручную (без Ansible):**
1. Сгенерировать ключи: `wg genkey | tee /etc/wireguard/clients/<name>.priv | wg pubkey > /etc/wireguard/clients/<name>.pub && wg genpsk > /etc/wireguard/clients/<name>.psk`
2. Добавить `[Peer]`-блок в `/etc/wireguard/wg0.conf`
3. Применить без рестарта туннеля: `sudo wg syncconf wg0 <(sudo wg-quick strip /etc/wireguard/wg0.conf)`
4. Обновить nftables (если нужны новые forward-правила): `sudo systemctl reload nftables`
5. Добавить A-запись в `/etc/dnsmasq.d/wg-internal.conf` и `sudo systemctl restart dnsmasq`
6. Если это сайт — добавить маршруты в `wg0-routes.sh` и `sudo systemctl restart wg0-routes`
