# wg-hub-provisioning

Declarative WireGuard overlay: a hub VPS (Hetzner) ties together MikroTik
home sites, service VPSes, and personal devices. Internal DNS zone
`in.threadnull.dev`, wildcard Let's Encrypt cert.

The only file you edit to change the network is
`group_vars/all/network.yml`. Everything else is generated: the hub
`wg0.conf`, nftables ACLs, routes/PBR, the DNS zone, client configs, and
ready-to-paste MikroTik snippets.

## Address plan

```
Overlay (WireGuard)        10.99.0.0/24
  10.99.0.1                hub
  10.99.0.11 - .19         site routers   (site N -> 10.99.0.1N)
  10.99.0.20 - .99         personal clients
  10.99.0.100 - .199       service VPSes
Site LANs                  10.<site>.0.0/16
  VLAN k of site N         10.N.<k>.0/24
```

`10.2.30.57` reads instantly as site 2 (house B), VLAN 30 (IoT). 99 is
reserved for the overlay, so site numbers 1-9 never collide. Adding a
third/fourth/fifth house is a copy-paste of a site block with a new number.

## Layout

```
group_vars/all/network.yml    # the model: peers, groups, ingress/egress
group_vars/all/settings.yml   # operational settings
group_vars/all/vault.yml      # secrets (ansible-vault), see *.example
playbooks/hub.yml             # hub: bare relay (WG + nftables + dnsmasq + certs + BGP)
playbooks/services.yml        # service VPSes (vpn_member role)
roles/base_hardening          # ssh, fail2ban, unattended-upgrades
roles/wg_hub                  # wg0/nftables/routes/DNS + MikroTik snippets
roles/frr_hub                 # FRRouting (bgpd): dynamic LAN routing via eBGP
roles/certs_hub               # wildcard cert + read-only publication
roles/vpn_member              # service VPS: WG, firewall, cert-sync, nginx
```

## Prerequisites

The hub is a fresh Debian 12/13 server with one thing done by hand: a user
`wg` with passwordless sudo and your SSH key.

```bash
adduser wg && usermod -aG sudo wg
mkdir -p /home/wg/.ssh && cp ~/.ssh/authorized_keys /home/wg/.ssh/
chown -R wg:wg /home/wg/.ssh
echo 'wg ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/wg
```

Control machine:

```bash
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
```

## First run

sshd on a fresh server still listens on 22; the run moves it to 5860.

```bash
ansible-playbook playbooks/hub.yml -e ansible_port=22 --ask-vault-pass
```

Verify:
- `wg show` lists peers and handshakes;
- mobile_cloud reaches the internet with the VPS IP; mobile_home with the
  home IP;
- `dig hub.in.threadnull.dev @10.99.0.1` answers from the zone;
- the wildcard cert exists under `/var/lib/wg-certs`.

Then set `hub_public_ssh: false` in settings.yml and re-run; only UDP/51820
stays open to the internet.

## Adding a site (house)

1. Copy a block under `sites:` in network.yml, pick the next `number` and
   `ip` (`10.99.0.1N`), list its LAN subnets as `10.N.<vlan>.0/24`.
2. `ansible-playbook playbooks/hub.yml` — generates the peer, ACLs, DNS,
   and `/etc/wireguard/clients/<site>.rsc` on the hub.
3. On the new router: paste the rendered `.rsc` in the MikroTik terminal.
   The snippet configures WireGuard **and** eBGP in one pass — the hub
   learns the site's LAN supernet (`10.N.0.0/16`) via BGP automatically.
   Confirm the handshake and check `vtysh -c "show bgp summary"` on the hub.

## Adding a personal client (family)

1. Add to `clients:` - `group: user` for family (internet + only services
   that allow `users`, no LAN, no router access), `group: admin` for you.
2. `ansible-playbook playbooks/hub.yml`.
3. `qrencode -t ansiutf8 < /etc/wireguard/clients/<name>.conf` and scan it
   in the WireGuard app. That is the whole onboarding.

## Adding a service

This is a two-phase process: bootstrap over the public IP, then lock down
to overlay-only once the tunnel is verified.

> **Invariant:** run `hub.yml` before `services.yml` whenever `network.yml`
> changes. The hub's nftables forward rules are generated from `network.yml`;
> skipping `hub.yml` leaves the hub dropping traffic to the new ports.

### Phase 1 — Bootstrap (public IP)

1. Add the service block under `services:` in `network.yml` (overlay IP,
   `dns_names`, `ingress`/`egress`, `nginx`/`nginx_upstream` if needed).
2. Add the host to `inventory.yml → services.hosts`:
   - `ansible_host`: public IP (from Hetzner panel)
   - `ansible_port: 5860` — base_hardening moves sshd from 22 → 5860
     mid-play via a handler; do **not** use `-e ansible_port=22` (that
     would override the hub port and break `delegate_to` tasks)
   - `service_name`: the `name:` key from step 1
   - Leave `member_public_ssh` absent/commented (defaults to `true`,
     keeping bootstrap SSH open on all interfaces)
3. `ansible-playbook playbooks/hub.yml --ask-vault-pass` — generates the
   WireGuard keypair + PSK on the hub, adds the peer to `wg0.conf` via
   `wg syncconf`, creates nftables forward rules for every declared
   ingress/egress port, adds the DNS A record.
4. `ansible-playbook playbooks/services.yml --limit <host> --ask-vault-pass -K`
   — joins the overlay (WireGuard up), deploys the member nftables (bootstrap
   SSH still open), syncs the wildcard cert from the hub, brings up nginx if
   `nginx: true`. Deploy the backend service listening on `nginx_upstream`.
   Verify `https://<name>.in.threadnull.dev` and SSH from the VPN.

### Phase 2 — Lock down (overlay only)

5. In `inventory.yml`, update the host entry:
   - `ansible_host`: overlay IP (e.g. `10.99.0.100`)
   - Uncomment `member_public_ssh: false`
6. If `network.yml` was also updated (e.g. adding ingress ports while
   verifying in Phase 1), run `hub.yml` first to push those changes to the
   hub's nftables before the service VPS closes its public door:
   `ansible-playbook playbooks/hub.yml --ask-vault-pass`
7. `ansible-playbook playbooks/services.yml --limit <host> --ask-vault-pass -K`
   — redeploys the member nftables with `member_public_ssh: false`, removing
   the bootstrap `tcp dport 22/5860 accept` rules on all interfaces. SSH and
   web traffic are now overlay-only. Mirror with an empty/deny-all Hetzner
   Cloud Firewall on the VPS for belt-and-suspenders public closure.

## Access model (hub nftables)

| Group     | Access |
|-----------|--------|
| admin     | everything: overlay, all LANs, internet via hub/home |
| user      | internet only + services that list `users`; no LANs, no routers |
| sites     | site-to-site between LANs; services only on declared ports |
| services  | declared ingress/egress only; LANs closed by default |
| iot       | only declared ports of specific services |

A service's `egress` with no `port` opens all ports toward the target -
that is what lets Home Assistant reach IoT devices for vacuum control,
3D-printer cameras, ESPHome, etc.

## Certificates

lego on the hub, DNS-01 via Cloudflare, renewed by a daily timer. The
Cloudflare token lives only on the hub. Service VPSes pull a read-only copy from
`/var/lib/wg-certs` over a restricted `certsync` rsync account.

## Notes

- Peer changes apply via `wg syncconf` (no tunnel restart). Changing
  `ListenPort`/`Address` needs `systemctl restart wg-quick@wg0`.
- Site LAN routes (`10.N.0.0/16`) are installed on the hub dynamically
  via eBGP (FRRouting). When a site tunnel drops, BGP withdraws its routes
  automatically — no blackholing. `wg0-routes.sh` only handles the overlay
  subnet and PBR table 123 (home-profile internet egress).
- Single point of failure is the hub by design (NAT/dynamic-IP routers
  cannot peer directly). If the hub dies, sites keep their own WAN; only
  cross-site and service access pause until it returns.
