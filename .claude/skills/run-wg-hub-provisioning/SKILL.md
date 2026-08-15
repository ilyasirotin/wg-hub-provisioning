---
name: run-wg-hub-provisioning
description: run, lint, syntax-check, test, verify wg-hub-provisioning Ansible playbooks for WireGuard overlay
---

# run-wg-hub-provisioning

Ansible IaC project — no GUI, no server to start. The "app" is one playbook
(`playbooks/hub.yml`) and one role (`roles/hub`). The driver is
`scripts/smoke.sh`, which validates YAML/Jinja2 syntax and runs ansible-lint.
Applying anything to the real hub requires SSH to it over the overlay.

All paths are relative to repo root.

## Prerequisites

Python 3.12 venv already in `.venv/` (mise + uv). No Galaxy collections are
used — `pip install -r requirements.txt` is the whole setup.

## Run (agent path — primary)

```bash
cd ~/Projects/wg-hub-provisioning
bash scripts/smoke.sh            # syntax-check the playbook (default)
bash scripts/smoke.sh lint       # ansible-lint — exits non-zero on violations
bash scripts/smoke.sh all        # lint then syntax-check
```

The script auto-detects whether `~/.ansible/tmp` is writable. If not (e.g. in a
sandbox with a read-only home), it creates a `mktemp -d` directory and sets
`ANSIBLE_LOCAL_TEMP` automatically — no manual intervention needed.

**Expected output (success):**

```
==> ansible-lint
Passed: 0 failure(s), 0 warning(s) …
Lint OK.
==> syntax-check: hub.yml

playbook: playbooks/hub.yml
Syntax OK.
```

Ansible prints the playbook path and exits 0 — that IS the success output.
ansible-lint must stay clean at the `production` profile; non-Ansible
directories are excluded in `.ansible-lint`.

## Dry-run against the live hub (human path)

Requires the vault password and overlay reachability (hub at `10.99.0.1:22`,
user `ops`, passwordless sudo).

```bash
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass
```

Expect zero changed tasks against a converged hub. Any diff in `wg0.conf`,
`nftables.conf`, `wg-internal.conf` or `wg0-routes.sh` means a template drifted
from the deployed state — investigate before applying.

First run on a fresh droplet (no overlay yet):

```bash
ansible-playbook playbooks/hub.yml -e ansible_host=<droplet-public-ip> --ask-vault-pass
```

## Verifying the result

```bash
ssh hub.in.threadnull.dev 'systemctl is-active wg-quick@wg0 wg0-routes nftables dnsmasq prometheus-node-exporter'
ssh hub.in.threadnull.dev 'sudo wg show wg0 latest-handshakes'   # before and after a run
```

Applying peer changes must not reset handshakes — they are pushed with
`wg syncconf`, not by restarting the interface.

## Gotchas

- **`ANSIBLE_LOCAL_TEMP`, not `HOME`** — ansible ignores `HOME` for temp files;
  `scripts/smoke.sh` probes writability and falls back automatically.
- **`mktemp` needs a writable `/tmp`** — in a sandbox pass the writable path
  explicitly: `ANSIBLE_LOCAL_TEMP=/path/to/writable bash scripts/smoke.sh`.
- **ansible-lint warns about vault.yml decryption** — `WARNING: Ignored
  exception … Decryption failed` is normal without `--ask-vault-pass`.
- **The playbook needs `nextdns_profile_id`** from `group_vars/all/vault.yml`;
  the role asserts it is set and not `CHANGE_ME`.
