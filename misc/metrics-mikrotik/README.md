# MikroTik Monitoring: Prometheus + Grafana via mktxp

Metrics from two MikroTik hAP ax3 routers (RouterOS 7.23.x) in the existing
host-based Grafana + Prometheus + Alertmanager (Telegram) stack on the
metrics VPS. The exporter is [akpw/mktxp](https://github.com/akpw/mktxp)
in Docker; the Grafana dashboard is the de-facto standard
[Mikrotik MKTXP Exporter #13679](https://grafana.com/grafana/dashboards/13679-mikrotik-mktxp-exporter/)
(kept in this repo as `../grafana/mikrotik-mktxp-dashboard.json`).

**History:** the first iteration used swoga/mikrotik-exporter. It worked, but
no ready-made Grafana dashboard exists for its metric names, while mktxp's
13679 provides system/health, per-interface traffic, Wi-Fi clients, DHCP
leases, firewall and connection panels out of the box — so the stack was
migrated to mktxp (2026-07-07). The swoga removal steps are documented below.

## Architecture

```
Site A (hAP ax3)                          Site B (hAP ax3)
LAN 10.1.0.0/16                           LAN 10.2.0.0/16
wg 10.99.0.11, AS 65011                   wg 10.99.0.12, AS 65012
        \                                        /
         \-- WireGuard --> hub 65.21.177.182 <--/
                     (wg 10.99.0.1, AS 65001, relays peer-to-peer)
                              |
                     metrics VPS (WireGuard peer, wg 10.99.0.100)
                     Grafana + Prometheus + Alertmanager (host)
                     + mktxp (Docker, host networking, 127.0.0.1:49090)
```

- mktxp probes both routers over the overlay via the RouterOS API
  (TCP 8728, plain API — traffic never leaves the WireGuard tunnel) and
  serves ALL routers from a single `/metrics` endpoint; per-router series
  carry the `routerboard_name` label (= section names in `mktxp.conf`).
- **Hub**: the forward chain is default-drop; the `metrics` service has an
  `egress: {tcp 8728 -> sites}` rule in `group_vars/all/network.yml`.
  Re-apply `playbooks/hub.yml` after changing it.
- **Routers**: configured by `monitoring-access.rsc` (applied on both) —
  read-only `prometheus` user (policy `api,read`), API service and firewall
  restricted to `10.99.0.100`. mktxp reuses it unchanged.
- **Host networking** for the container: the VPS nftables (vpn_member role)
  drops all forwarding, so bridge-network containers have no outbound
  connectivity; host networking also pins the source IP to `10.99.0.100`
  (wg0), matching the router-side restrictions.
- RouterOS 7 wifi is supported natively — mktxp detects the package and
  reads `/interface/wifi/registration-table` (Wi-Fi client metrics).

## Files

```
monitoring-access.rsc     # RouterOS config - ALREADY APPLIED on both routers
docker-compose.yml        # mktxp + snmp-exporter containers (host networking)
mktxp/_mktxp.conf         # exporter settings (listen 127.0.0.1:49090)
mktxp/mktxp.conf.example  # routers + collector toggles (template)
mktxp/mktxp.conf          # real credentials - GITIGNORED, lives locally/on VPS
scrape-mikrotik.yml       # scrape jobs (mktxp + snmp-swos) for prometheus.yml
alerts-mikrotik.yml       # alert rules -> /etc/prometheus/rules/
../grafana/mikrotik-mktxp-dashboard.json  # dashboard 13679 + custom BGP row
../grafana/mikrotik-swos-dashboard.json   # dashboard 14933, job patched to snmp-swos
```

## CRS-326 switch (SwOS) - SNMP

SwOS has no API; metrics come via `snmp-exporter` (same compose file,
host networking, `127.0.0.1:9116`, bundled `snmp.yml`). Prometheus job
`snmp-swos` probes `10.2.100.254` with modules `if_mib` (port counters),
`mikrotik` (mtxr health/optics) and `system` (sysUpTime), auth `public_v2`
(SwOS v2.18 speaks SNMPv2c, 64-bit counters verified). Path: hub egress
`udp/161 -> sites` in `network.yml`. On the switch: SwOS UI -> System ->
SNMP: Enabled, community `public`. `SwosSwitchDown` alert fires while the
target is down. Debug note: SNMP silently drops requests with a wrong
community - from the exporter it looks exactly like a timeout.

## Telegram: dedicated MikroTik bot

All rules here carry `component: mikrotik`; Alertmanager (canonical copy
`../prometheus/alertmanager.yml`) routes them to the `telegram-mikrotik`
receiver - same chat, separate bot. The token lives ONLY on the VPS in
`/etc/prometheus/telegram_bot_token_mikrotik` (600, prometheus:prometheus);
after changing it: `sudo systemctl reload prometheus-alertmanager`.

## hAP ax2 extender

L2 extender behind site_b, `10.2.10.249` (vlan10, DHCP reservation).
Reached directly over the overlay: hub allows `8728 -> @site_nets`, site_b
forwards VPN -> TRUSTED_LAN. Onboarded 2026-07-08:
`monitoring-access-extender.rsc` applied on the device (user + API binding;
the device has no firewall), `[extender]` section in `mktxp.conf` with the
L2 collector subset (interface/monitor/wireless/health; no dhcp/route/
firewall/bgp), `max_worker_threads = 3`. Appears on the mktxp dashboard as
`extender` and has its own `MikrotikRouterDown` absent-rule.

## Deployment (already done on the VPS; for reference / redeploy)

1. Copy `docker-compose.yml` and `mktxp/` to `/opt/mikrotik-monitoring/`
   on the VPS. In `mktxp/mktxp.conf` set the real password of the RouterOS
   `prometheus` user; `chmod 600 mktxp/mktxp.conf` (must stay readable by
   the container user — check `docker logs mktxp` after start).
2. `docker compose up -d`, then verify:

   ```bash
   curl -s 127.0.0.1:49090/metrics | grep -c 'routerboard_name="site-a"'
   curl -s 127.0.0.1:49090/metrics | grep -c 'routerboard_name="site-b"'
   curl -s 127.0.0.1:49090/metrics | grep '^mktxp_' | cut -d'{' -f1 | sort -u
   ```

   Both routers must appear; the last command lists real metric names
   (used by the alert rules).
3. Merge `scrape-mikrotik.yml` into `/etc/prometheus/prometheus.yml`, copy
   `alerts-mikrotik.yml` to `/etc/prometheus/rules/`, then:

   ```bash
   promtool check config /etc/prometheus/prometheus.yml
   sudo systemctl reload prometheus
   ```

4. Grafana → Dashboards → Import → upload
   `grafana/mikrotik-mktxp-dashboard.json` (or import by ID `13679`),
   pick the Prometheus datasource.

Alerting semantics (differs from multi-target exporters): mktxp has **no
per-router up metric** — when a router is unreachable its series disappear.
`alerts-mikrotik.yml` therefore uses `absent(...)` per router
(`MikrotikRouterDown`) plus `up{job="mktxp"} == 0` for the exporter itself
(`MktxpExporterDown`).

Heads-up: both routers reboot on a schedule (`4w2d` interval, 05:00
Asia/Bishkek) — consider an Alertmanager mute window for that slot.

## Migration from swoga/mikrotik-exporter (performed 2026-07-07)

Removal of the old stack, in order:

```bash
# on the VPS
cd /opt/mikrotik-monitoring
docker compose down                # stops/removes the mikrotik-exporter container
docker rmi ghcr.io/swoga/mikrotik-exporter:latest
rm compose.yml config.yml          # old swoga files

# Prometheus: remove the old "mikrotik" job (multi-target /probe relabeling
# block) from /etc/prometheus/prometheus.yml, add the "mktxp" job instead;
# replace /etc/prometheus/rules/alerts-mikrotik.yml with the mktxp version.
promtool check config /etc/prometheus/prometheus.yml
sudo systemctl reload prometheus
```

Checklist of swoga leftovers:

- [x] container `mikrotik-exporter` and image `ghcr.io/swoga/mikrotik-exporter`
- [x] `/opt/mikrotik-monitoring/{compose.yml,config.yml}`
- [x] Prometheus job `mikrotik` (port 9436, `/probe` relabeling)
- [x] rules referencing `probe_success` / `mikrotik_*` metrics
- [x] repo: swoga configs replaced by mktxp set (this directory)
- Old `mikrotik_*` / `probe_*` series in the TSDB are not deleted — they
  age out with the retention window (admin API is disabled).
- **Routers**: nothing to remove — `monitoring-access.rsc` (user, API,
  firewall rule) is exporter-agnostic and reused by mktxp as-is.
- **Hub**: nothing to remove — same port 8728, same egress rule.

## Verification

- `curl -s 127.0.0.1:49090/metrics | grep routerboard_name` — both routers
- Prometheus targets: `mktxp` job UP; `MikrotikRouterDown` expr empty
- Grafana 13679: panels populated for both `routerboard_name` values
- Negative test: `docker stop mktxp` → `MktxpExporterDown` goes pending;
  `docker start mktxp` clears it
