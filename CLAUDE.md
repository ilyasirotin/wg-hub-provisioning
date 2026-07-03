# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ansible automation for a hub-and-spoke WireGuard overlay (`10.99.0.0/24`,
internal DNS zone `in.threadnull.dev`). A single Hetzner VPS "hub" relays
between MikroTik home routers (sites), service VPSes, and personal devices.

The whole network is described declaratively in **`group_vars/all/network.yml`** —
that is the only file edited to add a peer, site, or service. Everything else
(`wg0.conf`, nftables ACLs, routes/PBR, DNS zone, client `.conf`s, MikroTik
`.rsc` snippets) is rendered from it. See `README.md` for the full operator
workflow, address plan, and access model; this file covers what's needed to
work on the code.

## Environment & commands

- Python/venv managed by **mise** (`mise.toml`, Python 3.12, auto-creates
  `.venv` via uv). Entering the dir activates it.
- Install: `pip install -r requirements.txt` and
  `ansible-galaxy collection install -r requirements.yml`
  (collections: `community.crypto`, `ansible.posix`).
- Secrets live in `group_vars/all/vault.yml` (ansible-vault encrypted; copy
  from `vault.yml.example`). Most runs need `--ask-vault-pass`.

```bash
# Lint (no test suite exists; ansible-lint is the gate)
ansible-lint

# Syntax / dry-run before applying
ansible-playbook playbooks/hub.yml --syntax-check
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass

# Apply the hub (relay + firewall + DNS + BGP + certs)
ansible-playbook playbooks/hub.yml --ask-vault-pass

# Apply one service VPS
ansible-playbook playbooks/services.yml --limit <host> --ask-vault-pass
```

Bootstrap nuance: `base_hardening` moves sshd from 22 → 5860 via a handler at the end
of the role; pipelining keeps the session alive through the restart.

- **Hub first run**: override on the CLI: `-e ansible_host=<hub-public-ip> -e ansible_port=22`.
  Subsequent runs use inventory values (control machine must be on the overlay).
- **Service VPS first run**: set `ansible_port: 22` directly in `inventory.yml`. Do **not**
  use `-e ansible_port=22` — that overrides the hub port globally and breaks `delegate_to`.
  After bootstrap, switch `ansible_host` to the overlay IP and `ansible_port` to 5860.

`host_key_checking` is **on**.

## Architecture

Two playbooks, five roles, both playbooks start with `base_hardening`:

- `playbooks/hub.yml` → `base_hardening` → `wg_hub` → `frr_hub` → `certs_hub`
- `playbooks/services.yml` → `base_hardening` → `vpn_member`

**The model → render pipeline (`roles/wg_hub`) is the core.** Read
`roles/wg_hub/tasks/main.yml` top to bottom:

1. `network.yml`'s `sites` (dict), `clients` (list), and `services` (list)
   are flattened into a single `wg_all_peers` fact, each tagged with
   `kind: site|client|service`. Most templates iterate this unified list.
2. Keypairs + PSKs are generated **on the hub** (`creates:` guards make this
   idempotent — keys are never regenerated), slurped back, and assembled into
   `wg_peer_data` / `wg_server_keys` facts (all `no_log: true`). The hub is the
   source of truth for all private material; `vpn_member` fetches a service's
   key from the hub via `delegate_to`.
3. Templates render config. Firewall, routing, and the tunnel are deliberately
   split so peer edits don't restart the tunnel:
   - `wg0.conf.j2` — interface + peers **only** (no PostUp firewall/routes).
     Applied via the `Sync WireGuard peers` handler using `wg syncconf`.
     All sites use `AllowedIPs = <overlay-ip>/32, 10.<N>.0.0/16` (supernet for
     WireGuard peer selection; actual LAN routes come from BGP). The elected
     exit site's `0.0.0.0/0` is **runtime state owned by `wg-exit-sync`**,
     never rendered into the file; syncconf stripping it is expected — the
     `Restart wg-exit-sync` handler (defined right after the sync handler;
     definition order matters) re-adds it.
   - `wg0-routes.sh.j2` + a systemd unit bound to `wg-quick@wg0` — overlay
     subnet (`10.99.0.0/24`), the policy-based routing rules (PBR table 123)
     for `profile: home` clients, and the table's fail-closed
     `unreachable default` floor. **Site LAN routes are NOT here** — they are
     managed by `frr_hub`, and the exit default is elected via BGP (below).
   - `wg-exit-sync.sh.j2` + service — watches table 123 (`ip monitor` + 10s
     reconcile) and hands WireGuard's `0.0.0.0/0` to the peer of the current
     BGP-elected exit nexthop (map rendered to `/etc/wireguard/exit-peers.map`).
   - `nftables.conf.j2` — all access control. Validated with `nft -c` before
     deploy. Forward chain includes MSS clamping (`tcp flags syn tcp option
     maxseg size set rt mtu`). Input chain allows TCP 179 from overlay
     (`iifname "wg0" tcp dport 179 accept`) for BGP peering.

**`roles/frr_hub`** — FRRouting BGP daemon on the hub. Installs `frr`, enables
`bgpd`, deploys `/etc/frr/frr.conf`. The config uses `bgp listen range
10.99.0.0/24 peer-group OVERLAY` so new sites connect automatically (hub ASN
65001, site ASNs 65011/65012/…). Site LAN routes arrive via eBGP and are
installed with `proto bgp`. When a WireGuard session drops, the BGP hold-timer
(`timers 5 15`) expires and routes are withdrawn — no stale routes.
**Exit election:** sites with `exit_priority` announce `0.0.0.0/0`; all inbound
policy lives in the `OVERLAY-IN` route-map (do NOT add a `prefix-list … in` on
the peer-group — FRR applies both filters and it would drop the default before
the route-map). The elected default goes to table 123 via the `BGP-TO-KERNEL`
zebra route-map (`set table`); its terminal `permit` is mandatory, and
`SAFE-OUT` must keep denying `0.0.0.0/0` outbound (loop prevention).

**nftables zoning is generated from group membership.** `nftables.conf.j2`
builds named sets (`admin_ips`, `user_ips`, `service_ips`, per-site `*_nets`,
`iot_nets`) from the model and enforces the access matrix in README. A
service's `ingress`/`egress` lists in `network.yml` directly become accept
rules; `egress` with no `port` opens all ports to the target. `from:` accepts
group names (`users`, `sites`, `iot`, `services`), a site id, or another
service name. When changing access rules, edit `network.yml` and re-render —
do not hand-edit rendered output.

**sysctl:** IPv4 forwarding is set via `ansible.builtin.copy` to
`/etc/sysctl.d/99-wg-hub.conf` (a single `net.ipv4.ip_forward = 1` line).
The `99-` prefix ensures it loads last and wins over distro defaults. A
`Restart systemd-sysctl` handler applies it immediately during the run.

**DNS:** `dnsmasq` on the hub binds only the overlay IP and serves the internal
zone, forwarding other queries to `dns_upstreams`. The hub's *own* resolver is
deliberately decoupled — `/etc/resolv.conf` is pinned to `hub_resolvers` and
made immutable (`chattr +i`) so the hub can always resolve ACME/apt even before
any site peer is up. The dnsmasq systemd drop-in uses only `After=wg-quick@wg0`
(no `Wants=`) to avoid a stop-ordering cycle on shutdown.

**Certificates (`certs_hub`):** `lego` on the hub gets a wildcard
`*.in.threadnull.dev` via Cloudflare DNS-01 (token only on the hub), renewed by
a daily timer. Service VPSes pull a read-only copy from `cert_publish_dir` over
a restricted `rrsync` SSH account (`vpn_member` generates a key and authorizes
it on the hub via `delegate_to`).

## Conventions when editing

- Changing `network.yml` requires running the relevant playbook to take effect;
  there is no separate render step. Templates assume the peer-flattening and
  group conventions above — keep new fields consistent with how `wg_all_peers`
  and the nftables set-building loops consume the model.
- Tasks that touch keys/configs use `no_log: true`; preserve that.
- `*.priv`, `*.psk`, vault plaintext, and `rendered/` are gitignored.
- Address-plan invariants (site N → router `10.99.0.1N`, LAN supernet
  `10.N.0.0/16`, VLANs as `10.N.<vlan>.0/24`, `99` reserved for the overlay)
  are load-bearing for readability and for the generated sets — follow them.
- Site LAN routes live in BGP, not in `wg0-routes.sh`. Add routes by adding
  subnets to the MikroTik `BGP_Export` address list, not by editing the script.
- Exit-node failover is model-driven: give a site `exit_priority` (unique,
  lower = preferred) and re-apply. The site's rendered `.rsc` then exports
  `0.0.0.0/0` (no anchor route on purpose — the ISP default is the anchor, so
  a dead WAN self-withdraws). Never render `0.0.0.0/0` into `wg0.conf` — it is
  runtime state owned by `wg-exit-sync`.

`routeros/site_a_backup.rsc` / `routeros/site_b_backup.rsc` at the repo root are full MikroTik
router config exports kept for reference, not rendered artifacts.
