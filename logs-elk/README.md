# Central logging: Elasticsearch + Kibana + Fluent Bit (ELK)

Central log aggregation for the overlay, on the dedicated **logs VPS**
(`logs.in.threadnull.dev`, WireGuard peer `10.99.0.101`, Debian 13, Docker-only).
It ingests:

- **Router logs** — MikroTik site_a / site_b / extender via remote **syslog**
  (RFC3164 over `udp/514`) across the overlay.
- **VPS logs** — journald + container logs from the service VPSes (metrics, logs,
  future services) via **Fluent Bit** shippers.
- **App logs** (future) — structured JSON from Go/PHP services, parsed into
  fields for ad-hoc analysis.

Everything lands in **Elasticsearch**; **Kibana** (behind nginx TLS on
`logs.in.threadnull.dev`) is the ad-hoc DQL/Discover UI, and the existing
host-based **Grafana** on the metrics VPS gets Elasticsearch as a second
datasource for curated dashboards and log↔metric correlation.

Installed **manually**, same model as `../metrics-mikrotik/`. No new Ansible
role/playbook — the only Ansible touch is opening firewall ports / repointing
nginx, which is done by editing `group_vars/all/network.yml` and re-running the
existing playbooks (the model→render workflow), exactly as was done for metrics.

## Architecture

```
site_a  10.99.0.11  ┐                          ┌ metrics VPS 10.99.0.100
site_b  10.99.0.12  ┤  remote syslog udp/514   │  Grafana (host) ──ES datasource──┐
extender 10.2.10.249┘  (over the overlay)      │  Fluent Bit (docker, host-net) ──┤
        \                                       │    journald+containers → 9200    │
         \──── WireGuard ────> hub 65001 ───────┤                                  │
                                                └ logs VPS 10.99.0.101 (8 GB) <─────┘
                                                   docker compose (host networking):
                                                     elasticsearch : 9200
                                                     kibana        : 127.0.0.1:5601
                                                     fluent-bit    : udp/514 + journald
                                                   nginx TLS :443 → 127.0.0.1:5601
```

- **Host networking** for every container — the VPS nftables forward chain is
  default-drop with no Docker allowances, so bridge-network containers have no
  connectivity and Ansible re-runs flush the ruleset. Same rationale as
  `../metrics-mikrotik/docker-compose.yml`.
- **HTTP TLS off on Elasticsearch** (basic-auth kept) — all traffic already
  rides inside WireGuard; this skips the internal-CA/cert plumbing. Kibana is
  the only externally reachable UI and is fronted by nginx TLS (wildcard cert).
- **Access control**: overlay + hub ACL + this host's member nftables. See the
  `logs` service in `group_vars/all/network.yml`:
  `udp/514 from sites`, `tcp/9200 from services`, `tcp/443 from admin` (Kibana).

## Files

```
docker-compose.yml                 # elasticsearch + kibana + fluent-bit (host net)
.env.example                       # secrets template -> copy to .env (600, gitignored)
elasticsearch/
  ilm-logs-180d.json               # ILM policy: delete indices after 180 days
  index-template.json              # logs-* template: mappings + attaches ILM
kibana/kibana.yml                  # loopback bind, ES connection (secrets via env)
fluent-bit/
  fluent-bit.conf                  # AGGREGATOR (logs VPS): syslog + journald -> ES
  parsers.conf                     # syslog-rfc3164 + json parsers
  fluent-bit-shipper.conf          # SHIPPER (service VPSes): journald -> ES 10.99.0.101
routeros/
  logging-remote.rsc               # site_a/site_b remote syslog action + topics
  logging-remote-extender.rsc      # extender variant (no src-address)
../grafana/elasticsearch-datasource.yml  # Grafana datasource (metrics VPS)
../grafana/logs-overview-dashboard.json  # starter dashboard (Lucene queries)
```

Retention is **180 days** (ILM). No log-based alerting (out of scope).

---

## Part 0 — Prerequisites on the logs VPS

1. **Resize the VPS to 8 GB RAM** (Hetzner console) and reboot. Elasticsearch
   heap is set to 3 GB (`ES_JAVA_OPTS` in `docker-compose.yml`), leaving room
   for OS page cache + Kibana (~1 GB).

   ```bash
   free -h            # expect ~8 GB total
   ```

2. **Kernel setting required by Elasticsearch** (`vm.max_map_count`):

   ```bash
   echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
   sudo sysctl --system
   sysctl vm.max_map_count      # -> 262144
   ```

3. **Route container logs through journald** so Fluent Bit captures host + all
   containers from a single source, with container metadata:

   ```bash
   echo '{ "log-driver": "journald" }' | sudo tee /etc/docker/daemon.json
   sudo systemctl restart docker
   ```

---

## Part 1 — Firewall / nginx via the network model (Ansible)

The `logs` service is already defined in `group_vars/all/network.yml`; this repo
updates it to:

```yaml
  - name: logs
    ip: 10.99.0.101
    dns_names: [logs, kibana]
    nginx: true
    nginx_upstream: 127.0.0.1:5601        # Kibana
    ingress:
      - { proto: udp, port: 514,  from: [sites] }     # remote syslog (routers + extender)
      - { proto: tcp, port: 9200, from: [services] }  # ES API: Grafana + shippers
      - { proto: tcp, port: 443,  from: [admin] }     # Kibana UI (admins only)
      - { proto: tcp, port: 5860, from: [sites] }     # SSH management (unchanged, as on metrics)
```

`from: [admin]` opens 443 on the member VPS while relying on the hub's implicit
admin-accept — family `users` do not get Kibana. `@site_nets` already covers the
extender's `10.2.10.249`, so all three routers can reach `udp/514`.

Re-apply (from the control machine, which must be an overlay peer):

```bash
# dry-run first — confirm the new forward/input rules render and nft -c passes
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass
ansible-playbook playbooks/services.yml --limit logs --check --diff --ask-vault-pass

# apply
ansible-playbook playbooks/hub.yml --ask-vault-pass            # hub forward-ACL + DNS (kibana.*)
ansible-playbook playbooks/services.yml --limit logs --ask-vault-pass  # member nft (udp/514, 9200) + nginx->5601
```

---

## Part 2 — Deploy the ELK stack on the logs VPS

1. Copy this directory to `/opt/logs-elk/` on the VPS and set secrets:

   ```bash
   cd /opt/logs-elk
   cp .env.example .env && chmod 600 .env
   # ELASTIC_PASSWORD / KIBANA_PASSWORD : openssl rand -base64 24
   # KIBANA_ENCRYPTION_KEY              : openssl rand -hex 32
   $EDITOR .env
   ```

2. Prepare the data directory (Elasticsearch runs as uid 1000):

   ```bash
   mkdir -p esdata && sudo chown -R 1000:0 esdata
   ```

3. Start **Elasticsearch first** and wait until healthy:

   ```bash
   docker compose up -d elasticsearch
   set -a; source .env; set +a
   until curl -s -u elastic:$ELASTIC_PASSWORD localhost:9200/_cluster/health \
     | grep -qE '"status":"(green|yellow)"'; do sleep 3; done
   echo OK
   ```

   > Single-node → cluster status **yellow** is normal (replicas can't be
   > allocated; the index template sets `number_of_replicas: 0`, so new indices
   > go green).

4. **Set the `kibana_system` password** (not set by the bootstrap env) to the
   value you put in `KIBANA_PASSWORD`:

   ```bash
   curl -s -u elastic:$ELASTIC_PASSWORD -X POST \
     localhost:9200/_security/user/kibana_system/_password \
     -H 'Content-Type: application/json' \
     -d "{\"password\":\"$KIBANA_PASSWORD\"}" ; echo
   ```

5. **Apply the ILM policy and index template**:

   ```bash
   curl -s -u elastic:$ELASTIC_PASSWORD -X PUT \
     localhost:9200/_ilm/policy/logs-180d \
     -H 'Content-Type: application/json' -d @elasticsearch/ilm-logs-180d.json ; echo
   curl -s -u elastic:$ELASTIC_PASSWORD -X PUT \
     localhost:9200/_index_template/logs \
     -H 'Content-Type: application/json' -d @elasticsearch/index-template.json ; echo
   ```

6. Start the rest (Kibana + Fluent Bit):

   ```bash
   docker compose up -d
   docker compose ps
   ```

Kibana is now at `https://logs.in.threadnull.dev` (admin devices only). In
Kibana → **Stack Management → Data Views**, create a data view `logs-*` with
time field `@timestamp`. Explore under **Discover** (DQL / KQL).

---

## Part 3 — RouterOS remote logging (site_a, site_b, extender)

On each router, set a stable identity (it becomes the syslog `host` in ELK) and
apply the snippet:

```
/system identity set name=site-a          # site-b / extender respectively
```

- **site_a / site_b** → `routeros/logging-remote.rsc`. Edit `REMOTE_SRC` to the
  router's overlay IP (`10.99.0.11` / `10.99.0.12`) before pasting into the
  terminal (or upload + `/import`).
- **extender** → `routeros/logging-remote-extender.rsc` (no `src-address`;
  sources from `10.2.10.249`, already inside `@site_nets`).

No router firewall change is needed (they initiate outbound; established/related
is accepted). Tune the `topics=` set in the snippet to taste — `firewall`,
`dhcp`, `wireless` can be chatty.

Verify (on the VPS):

```bash
curl -s -u elastic:$ELASTIC_PASSWORD \
  '10.99.0.101:9200/logs-*/_search?q=log_source:router&size=3&pretty'
```

---

## Part 4 — Ship VPS logs (Fluent Bit on service VPSes)

On each service VPS you want covered (start with **metrics**, `10.99.0.100`):

1. Route docker logs to journald (Part 0 step 3) if not already.
2. Copy `fluent-bit/fluent-bit-shipper.conf` and `fluent-bit/parsers.conf` to
   the host; edit `host_name` in the shipper conf to the VPS name.
3. Run the shipper container (host networking, same rationale as mktxp):

   ```bash
   docker run -d --name fluent-bit --network host --restart unless-stopped \
     -e ELASTIC_PASSWORD='<the ELASTIC_PASSWORD from logs VPS .env>' \
     -v /opt/fluent-bit/fluent-bit-shipper.conf:/fluent-bit/etc/fluent-bit.conf:ro \
     -v /opt/fluent-bit/parsers.conf:/fluent-bit/etc/parsers.conf:ro \
     -v /var/log/journal:/var/log/journal:ro \
     -v /etc/machine-id:/etc/machine-id:ro \
     fluent/fluent-bit:3.1.9
   docker logs -f fluent-bit      # watch for ES connection / flush errors
   ```

   The hub permits `10.99.0.100 → 10.99.0.101:9200` via `tcp/9200 from
   services`. (For a future service VPS, repeat with its own `host_name`.)

> If docker-log ingestion misbehaves, this shipper still delivers full host
> **journald** — container logs can be excluded until sorted, as agreed.

### Structured Go/PHP app logs

Have the services log **JSON to stdout** (fields like `level`, `msg`, `status`,
`trace_id`). With the journald driver, the JSON string arrives in `message`;
enable the targeted `parser` filter shown (commented) in the Fluent Bit configs
to explode it into fields. Prefer scoping the parse to your app containers
(by `CONTAINER_NAME`) so non-JSON unit logs are left intact.

---

## Part 5 — Grafana datasource (metrics VPS)

On the **metrics VPS** (host-based Grafana):

1. Provide the ES password to grafana-server without committing it:

   ```bash
   sudo install -d /etc/systemd/system/grafana-server.service.d
   printf '[Service]\nEnvironment=ES_LOGS_PASSWORD=%s\n' '<ELASTIC_PASSWORD>' \
     | sudo tee /etc/systemd/system/grafana-server.service.d/es-logs.conf
   sudo systemctl daemon-reload
   ```

2. Install the datasource provisioning and reload:

   ```bash
   sudo cp grafana/elasticsearch-datasource.yml \
     /etc/grafana/provisioning/datasources/elasticsearch-logs.yml
   sudo systemctl restart grafana-server
   ```

3. Grafana → **Connections → Data sources → Elasticsearch-logs → Save & test**.
4. Import `grafana/logs-overview-dashboard.json`, pick the `Elasticsearch-logs`
   datasource. Grafana queries use **Lucene** syntax (DQL/KQL is Kibana-only).

---

## Operational notes

- **Disk watermark**: at 95% disk usage Elasticsearch flips indices to
  read-only (`cluster.routing.allocation.disk.watermark.flood_stage`) and
  ingestion stalls. The VPS has 38 GB; watch `df -h /` as 180-day app-log
  volume grows. To recover after a fill: free space, then
  `PUT logs-*/_settings {"index.blocks.read_only_allow_delete": null}`.
- **ILM check**: `curl -u elastic:*** localhost:9200/logs-*/_ilm/explain?pretty`
  — every `logs-YYYY.MM.DD` index should be managed by `logs-180d`.
- **Secrets** live only on the VPS in `.env` (600) and the grafana-server
  drop-in; never in git (`logs-elk/.env` is gitignored).
- **Backups**: index data is in `/opt/logs-elk/esdata`. For DR, snapshot to a
  repository or accept re-ingestion (logs are transient by nature).

## Verification (end-to-end)

1. **ES health**: `curl -u elastic:*** localhost:9200/_cluster/health?pretty`
   → status yellow/green.
2. **Routers**: `.../logs-*/_search?q=log_source:router&size=1&pretty` returns
   docs; `host` shows `site-a` / `site-b` / `extender`.
3. **VPS logs**: restart a test container on metrics → the event appears in
   Kibana Discover (`CONTAINER_NAME` set, `log_source:vps`).
4. **Kibana**: `https://logs.in.threadnull.dev` opens on an admin device;
   Discover streams; a DQL query filters.
5. **Grafana**: datasource **Save & test** OK; the overview dashboard shows
   volume + logs; put a logs panel next to a metrics panel to confirm
   correlation.
6. **Firewall (defense-in-depth)**: from a non-admin client the ports are
   closed; from a site, `udp/514` is accepted but `9200` is not (services-only).
7. **ILM**: `_ilm/explain` shows the policy attached to `logs-*`.

## Troubleshooting

- **Kibana "Unable to authenticate"** → the `kibana_system` password in ES
  doesn't match `KIBANA_PASSWORD`; redo Part 2 step 4, then
  `docker compose restart kibana`.
- **No router logs** → check `/system logging action print` on the router,
  `src-address` matches its overlay IP, and `tcpdump -ni wg0 udp port 514` on
  the VPS shows arriving packets; confirm the hub ingress applied
  (`nft list chain inet filter forward` mentions `10.99.0.101 udp dport 514`).
- **Fluent Bit ES errors** (`400`/`mapping`) → usually a field-type clash;
  check `docker logs fluent-bit`. The `logs-*` template maps strings as
  `keyword` and `message` as `text`.
- **Fluent Bit can't reach 9200 from a shipper** → it must use `--network host`
  (bridge egress is dropped by nftables); verify with
  `curl -u elastic:*** 10.99.0.101:9200` from the shipper host.
- **ES won't start / `max_map_count`** → re-check Part 0 step 2.
```
