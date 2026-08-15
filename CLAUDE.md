# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ansible for a private WireGuard overlay (`10.99.0.0/24`, internal DNS zone
`in.threadnull.dev`). One hub — a DigitalOcean droplet on Debian 13 — relays
between MikroTik site routers, service VPSes, and personal devices. Peers reach
the overlay, each other, and the LANs behind the site routers; nothing else.

The network is described in **`group_vars/all/network.yml`** — the only file
edited to add or remove a peer. Everything else (`wg0.conf`, routes, nftables,
the DNS zone, client `.conf`s, MikroTik `.rsc` snippets) is rendered from it.
`README.md` has the operator workflow; this file covers working on the code.

Four properties constrain the whole design. Violating any of them is a bug, not
a feature request:

1. **No peer reaches the internet through the hub.** No transit traffic, so no
   NAT and no `nat` table. Client configs are split-tunnel — a generated config
   containing `0.0.0.0/0` would black-hole the device.
2. **Routing is static.** One path per site LAN, no failover, no dynamic
   routing protocol. A dead site means an unreachable LAN and timeouts.
3. **SSH stays on port 22.** The DigitalOcean Cloud Firewall closes it from the
   internet and is managed in the DO panel, outside Ansible — so the playbook
   must not assume it exists, and nftables accepts TCP 22 unconditionally.
4. **The hub issues no certificates.** ACME lives on a service VPS.

## Environment & commands

- Python/venv via **mise** (`mise.toml`, Python 3.12, `.venv` created by uv on
  entering the directory).
- Install: `pip install -r requirements.txt`. No Galaxy collections are used.
- `group_vars/all/vault.yml` (ansible-vault) holds `nextdns_profile_id`; every
  run needs `--ask-vault-pass`.

```bash
bash scripts/smoke.sh all                      # ansible-lint + syntax check
ansible-playbook playbooks/hub.yml --syntax-check
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass
ansible-playbook playbooks/hub.yml --ask-vault-pass
```

`ansible-lint` passes at the `production` profile and is the gate — there is no
test suite. Non-Ansible directories are excluded in `.ansible-lint`.

The inventory points at the overlay address (`10.99.0.1`, user `ops`, port 22),
so the control machine must be a connected peer. First run on a fresh droplet:
`-e ansible_host=<public-ip>`. `host_key_checking` is **on**. The `ops` account
is created by hand before the first run (README, "Prerequisites"); Ansible only
maintains its sudoers entry.

## Architecture

One playbook, one role, six task files, executed in this order:

`playbooks/hub.yml` → `roles/hub` → `system.yml`, `keys.yml`, `wireguard.yml`,
`firewall.yml`, `dns.yml`, `metrics.yml`.

The model is a flat list. `peers[]` entries have `name` and `address`, plus
optional `lan_supernet` (presence means "this peer routes a LAN": it extends
`AllowedIPs`, installs a route, and generates a `.rsc`) and `dns_name`
(defaults to `name` with `_` → `-`). Each peer drives four rendered artefacts:
a `[Peer]` block, a route, a `host-record`, and a config file. Keep new fields
consistent with how the templates consume the list.

**Keys (`keys.yml`).** Generated on the hub under `umask 077`, guarded by
`creates:` — an existing key is never regenerated, so a re-run cannot break a
paired peer. Slurped back into `hub_keys` / `hub_peer_keys`; every task that
touches key material uses `no_log: true`. Preserve that.

**Load-bearing details.** These were each debugged against a live failure:

- `Table = off` in `wg0.conf` keeps route management out of `wg-quick`, so peer
  changes apply via the `Sync WireGuard peers` handler (`wg syncconf`) without
  bouncing the interface and dropping every session. Adding a peer must never
  interrupt existing ones.
- No `Endpoint` for any peer — the hub learns them from handshakes.
- `wg0-routes.service` is `BindsTo=wg-quick@wg0.service`, so routes are
  withdrawn if WireGuard goes away.
- `nftables.conf` is validated with `nft -c -f` before deploy; a malformed
  ruleset applied directly locks the operator out. Forward keeps MSS clamping
  (`tcp flags syn tcp option maxseg size set rt mtu`) for PPPoE/VPN paths.
- `/etc/resolv.conf` is pinned to `hub_resolvers` and made immutable
  (`chattr +i`), so a dnsmasq failure does not also break `apt`. Ansible clears
  the flag before writing and restores it after.
- The dnsmasq drop-in (`templates/dnsmasq-wg-ordering.conf.j2`): `Wants=` is
  absent on purpose (stop-dependency cycle), `After=` alone is insufficient
  (dnsmasq with `bind-dynamic` silently binds nothing if the address is not up
  yet — hence the `ExecStartPre` wait loop), `PartOf=` re-binds on wg0 restart.
- `/etc/sysctl.d/99-wg-hub.conf`: the `99-` prefix makes it win over
  distribution defaults, and the runtime value is asserted afterwards — with
  forwarding off the kernel drops forwarded packets before nftables sees them
  while SSH keeps working, so the symptom points away from the cause.

## Conventions when editing

- Changing `network.yml` requires running the playbook; there is no separate
  render step.
- Templates reproduce the hand-built hub's files closely on purpose, so a run
  against the live host produces no surprising diff. Keep it that way.
- Rendered artefacts stay on the hub in `/etc/wireguard/peers/` at mode `0600`;
  `*.priv` and `*.psk` are gitignored and must never be committed.
- Address-plan invariants (site router `10.99.0.1N`, LAN supernet
  `10.N.0.0/16`, VLANs `10.N.<vlan>.0/24`, `99` reserved for the overlay) are
  load-bearing for readability — follow them.
- `grafana/`, `logs-elk/`, `metrics-mikrotik/`, `prometheus/`, `routeros/`
  configure machines this repository does not provision. Do not refactor them
  as part of hub work.
- `debian-hub-guide.md` documents building the same hub by hand and configuring
  the MikroTik side; keep it in sync when the design changes.
