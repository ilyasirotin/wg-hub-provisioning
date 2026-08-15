# wg-hub-provisioning

Ansible for a private WireGuard overlay. One hub (a DigitalOcean droplet
running Debian 13) lets peers reach the overlay, each other, and the LANs
behind the site routers. That is the entire purpose.

The network lives in `group_vars/all/network.yml`. Everything else — the
`[Peer]` blocks, the routes, the internal DNS zone, the client configs,
the MikroTik snippets — is generated from it.

## What this hub is not

- **Not an internet gateway.** No peer reaches the internet through the
  hub. There is no NAT and no `nat` table, and client configs are
  split-tunnel: `AllowedIPs` contains private ranges only. A generated
  config containing `0.0.0.0/0` would be a bug — it would push the
  device's whole internet traffic into a hub that drops it.
- **Not dynamically routed.** Each site LAN has exactly one path, through
  its own site router, so there is nothing to fail over to. When a site
  is down its LAN is unreachable and packets to it time out; when it
  returns, everything resumes without intervention. Site liveness is
  visible in `wg show wg0 latest-handshakes`.
- **Not a certificate authority.** ACME lives on a service VPS. Nothing
  on the hub touches certificate material.

## Address plan

```
Overlay (WireGuard)        10.99.0.0/24, UDP 51820
  10.99.0.1                hub
  10.99.0.11 - .19         site routers
  10.99.0.20 - .99         personal devices
  10.99.0.100 - .199       service VPSes
Site LANs                  10.<site>.0.0/16
  VLAN k of site N         10.N.<k>.0/24
Internal zone              in.threadnull.dev
```

`10.2.30.57` reads as site 2, VLAN 30 at a glance. The ranges are a
readability convention only — every peer has identical, unrestricted
access to the overlay. There are no groups, roles, or egress profiles.

## Layout

```
group_vars/all/network.yml   # the model: peers and addressing
group_vars/all/settings.yml  # operational settings
group_vars/all/vault.yml     # NextDNS profile id (ansible-vault), see *.example
inventory.yml                # one host
playbooks/hub.yml            # the only playbook
roles/hub/                   # the whole hub
  tasks/system.yml           #   packages, sudoers, sshd, sysctl
  tasks/keys.yml             #   key generation (idempotent) and readback
  tasks/wireguard.yml        #   wg0.conf, routes, client/MikroTik artefacts
  tasks/firewall.yml         #   nftables
  tasks/dns.yml              #   resolv.conf, dnsmasq
  tasks/metrics.yml          #   node_exporter
debian-hub-guide.md          # the same hub built by hand, plus MikroTik setup
```

## Prerequisites

On the control machine: Python 3.12 (mise creates `.venv` on `cd`), then
`pip install -r requirements.txt`.

On a fresh droplet, one manual step before the first run — the service
account, as root:

```bash
adduser ops && usermod -aG sudo ops
mkdir -p /home/ops/.ssh && cp ~/.ssh/authorized_keys /home/ops/.ssh/
chown -R ops:ops /home/ops/.ssh && chmod 700 /home/ops/.ssh
chmod 600 /home/ops/.ssh/authorized_keys
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops && chmod 0440 /etc/sudoers.d/ops
```

Ansible maintains that sudoers entry afterwards but never creates the
account: locking yourself out of a host you cannot SSH into is not
something a playbook should be able to do.

Secrets: copy `group_vars/all/vault.yml.example` to `vault.yml`, put the
NextDNS profile id in it, `ansible-vault encrypt` it. Every run needs
`--ask-vault-pass`.

## Running it

```bash
# First run: no overlay yet, so reach the droplet on its public address
ansible-playbook playbooks/hub.yml -e ansible_host=<droplet-public-ip> --ask-vault-pass

# Afterwards: the inventory points at the overlay
ansible-playbook playbooks/hub.yml --ask-vault-pass

# Dry run
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass

# Lint and syntax check (no test suite; ansible-lint is the gate)
bash scripts/smoke.sh all
```

Once the overlay works and `ssh ops@10.99.0.1` succeeds through it, close
public SSH: **DO panel → Networking → Firewalls → Create Firewall**,
attached to the droplet, inbound `UDP 51820` from all IPv4/IPv6 and
**no** rule for TCP 22. The Cloud Firewall is managed there, not by this
playbook — nftables accepts TCP 22 unconditionally. Emergency access is
the DO web console, which no network rule can lock you out of.

## Adding a peer

Append to `peers:` in `group_vars/all/network.yml`:

```yaml
  - name: pixel
    address: 10.99.0.20
```

Add `lan_supernet: 10.3.0.0/16` if the peer routes a LAN — that installs
the route and generates a MikroTik snippet. Add `dns_name:` if the DNS
label should differ from the peer name (`_` becomes `-` by default).

Re-run the playbook. Peer changes are applied with `wg syncconf`, so
**existing sessions are not interrupted** — verify with
`wg show wg0 latest-handshakes` before and after. Then hand the device
its config from the hub:

```bash
sudo cat /etc/wireguard/peers/pixel.conf          # laptops, servers
sudo qrencode -t ansiutf8 < /etc/wireguard/peers/pixel.conf   # phones
sudo cat /etc/wireguard/peers/site_c.rsc          # MikroTik: paste in Safe Mode
```

Every private key stays on the hub; the rendered files are `0600` and
never leave it except as you copy them.

### Rotating a peer's key

```bash
sudo rm /etc/wireguard/peers/<name>.{priv,pub,psk}
```

Re-run the playbook — the `creates:` guards only skip keys that exist, so
the missing set is regenerated and everything downstream is re-rendered.
Deliver the new config to the device.

## Verifying the hub

```bash
sysctl net.ipv4.ip_forward                     # 1
systemctl is-active wg-quick@wg0 wg0-routes nftables dnsmasq prometheus-node-exporter
sudo wg show                                   # handshake per peer, under 2 min
ip route show | grep wg0                       # overlay + one route per site LAN
ss -ulnp | grep ':53'                          # 10.99.0.1:53
dig +short @10.99.0.1 hub.in.threadnull.dev    # internal zone
dig +short @10.99.0.1 example.com              # upstream
curl -s 10.99.0.1:9100/metrics | head -3       # node_exporter
sudo nft list ruleset                          # one inet filter table, no nat
```

Site-to-site separately: from a host in site A's LAN, ping a host in site
B's LAN.

## How it is put together

**Keys.** Generated on the hub, guarded by `creates:` — an existing key
is never regenerated, so a re-run can not break a paired peer. The hub is
the source of truth for all private material; tasks that touch it use
`no_log`.

**`Table = off` in `wg0.conf`.** Route management is deliberately kept
out of `wg-quick` so that peer changes can be applied with
`wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)` instead of
bouncing the interface and dropping every session.

**Routes** live in `/usr/local/sbin/wg0-routes.sh`, driven by
`wg0-routes.service`, which is `BindsTo=wg-quick@wg0.service` — if
WireGuard goes away the routes go with it, so nothing points at a dead
interface.

**nftables** is one `inet filter` table with `policy drop` on input and
forward. Forward accepts only `wg0 -> wg0` plus MSS clamping (`tcp flags
syn tcp option maxseg size set rt mtu`), which prevents stalled sessions
over PPPoE and VPN paths. The ruleset is validated with `nft -c -f`
before it is applied: a malformed one applied directly can lock you out
of the host.

**DNS** is split in two on purpose. `dnsmasq` binds the overlay address
and serves `in.threadnull.dev`, forwarding everything else to NextDNS
(profile identified by an EDNS0 option, so no linked source IP is
needed). The hub's own `/etc/resolv.conf` points at public resolvers and
is made immutable with `chattr +i` — otherwise a dnsmasq failure would
also break `apt`.

The `dnsmasq` systemd drop-in is load-bearing and was debugged against a
live failure: `After=` orders units, not kernel state, so dnsmasq could
start in the same second the address was assigned, find nothing to bind
with `bind-dynamic`, and listen nowhere — silently, with a normal-looking
journal. The `ExecStartPre` loop waits for the address itself. `Wants=`
is deliberately absent (it creates a stop-dependency cycle that keeps wg0
from shutting down cleanly); `PartOf=` re-binds dnsmasq when wg0
restarts without adding start ordering. See
`roles/hub/templates/dnsmasq-wg-ordering.conf.j2`.

**Metrics.** `prometheus-node-exporter` bound to `10.99.0.1:9100`, system
metrics only. WireGuard peer state is read from `wg show` by a separate
admin panel, not scraped.

## Troubleshooting

**A peer is unreachable**

```bash
sysctl net.ipv4.ip_forward              # 0 -> forwarded packets are dropped
                                        #      before nftables sees them, while
                                        #      SSH to the hub still works
sudo wg show wg0 latest-handshakes      # no handshake -> keys/config on the
                                        #      peer, or missing keepalive
ip route show | grep wg0                # missing -> systemctl restart wg0-routes
sudo nft list chain inet filter forward
```

**`*.in.threadnull.dev` does not resolve**

```bash
dig @10.99.0.1 <name>.in.threadnull.dev   # NXDOMAIN/timeout -> systemctl status dnsmasq
ss -ulnp | grep :53                       # empty -> dnsmasq bound nothing (drop-in)
```

If `dig` against the hub works but the client fails, the client is not
asking `10.99.0.1`. On MikroTik:
`/ip dns static add type=FWD name="in.threadnull.dev" match-subdomain=yes forward-to=10.99.0.1`.

**Logs**

```bash
journalctl -u wg-quick@wg0 -u wg0-routes -u nftables -u dnsmasq --since "1 hour ago"
journalctl -k | grep "nft_forward_drop\|nft_input_drop"
```

## Reinstalling the hub

`/etc/wireguard` is the source of truth for every peer's private key.
Restore it and all routers and phones reconnect unchanged; lose it and
every peer must be re-paired.

```bash
# While the hub is alive
ssh hub.in.threadnull.dev 'sudo tar czf - /etc/wireguard' > hub-keys.tgz

# After reinstalling the OS: create the ops account (above), then
scp hub-keys.tgz ops@<public-ip>:/tmp/
ssh ops@<public-ip> 'sudo tar xzf /tmp/hub-keys.tgz -C / && rm /tmp/hub-keys.tgz'

# The host key changed and host_key_checking is on
ssh-keygen -R <public-ip>; ssh-keygen -R 10.99.0.1

ansible-playbook playbooks/hub.yml -e ansible_host=<public-ip> --ask-vault-pass
```

## Other directories

`grafana/`, `logs-elk/`, `metrics-mikrotik/`, `prometheus/` and
`routeros/` hold configuration for machines this repository does not
provision — dashboards, alert rules, the ELK stack, exporter configs, and
full MikroTik config exports kept for reference. They are excluded from
`ansible-lint` and untouched by the playbook.
