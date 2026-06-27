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

# Apply the hub (relay + firewall + DNS + certs)
ansible-playbook playbooks/hub.yml --ask-vault-pass

# Apply one service VPS
ansible-playbook playbooks/services.yml --limit <host> --ask-vault-pass
```

Bootstrap nuance: a fresh hub has sshd on port 22; the run moves it to 5860.
First run only: `-e ansible_port=22`. Same pattern for service VPSes (public
IP + port 22 on first contact, then switch `inventory.yml` to the wg address
and `member_public_ssh: false`). `host_key_checking` is **on**.

## Architecture

Two playbooks, four roles, both playbooks start with `base_hardening`:

- `playbooks/hub.yml` → `base_hardening` → `wg_hub` → `certs_hub`
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
   - `wg0-routes.sh.j2` + a systemd unit bound to `wg-quick@wg0` — overlay/site
     routes and the policy-based routing (PBR table 123) that sends
     `profile: home` clients' internet egress out the `exit_node` site router.
   - `nftables.conf.j2` — all access control. Validated with `nft -c` before
     deploy.

**nftables zoning is generated from group membership.** `nftables.conf.j2`
builds named sets (`admin_ips`, `user_ips`, `service_ips`, per-site `*_nets`,
`iot_nets`) from the model and enforces the access matrix in README. A
service's `ingress`/`egress` lists in `network.yml` directly become accept
rules; `egress` with no `port` opens all ports to the target. `from:` accepts
group names (`users`, `sites`, `iot`, `services`), a site id, or another
service name. When changing access rules, edit `network.yml` and re-render —
do not hand-edit rendered output.

**DNS:** `dnsmasq` on the hub binds only the overlay IP and serves the internal
zone, forwarding other queries to `dns_upstreams`. The hub's *own* resolver is
deliberately decoupled — `/etc/resolv.conf` is pinned to `hub_resolvers` and
made immutable (`chattr +i`) so the hub can always resolve ACME/apt even before
any site peer is up.

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
- Address-plan invariants (site N → router `10.99.0.1N`, LAN `10.N.<vlan>.0/24`,
  `99` reserved for the overlay) are load-bearing for readability and for the
  generated sets — follow them.

`routeros/site_a_backup.rsc` / `routeros/site_b_backup.rsc` at the repo root are full MikroTik
router config exports kept for reference, not rendered artifacts.
