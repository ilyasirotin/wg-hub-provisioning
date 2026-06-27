---
name: run-wg-infra
description: run, lint, syntax-check, test, verify wg-infra Ansible playbooks for WireGuard overlay
---

# run-wg-infra

Ansible IaC project — no GUI, no server to start. The "app" is the playbooks and roles.
The driver is `scripts/smoke.sh` (CLI smoke script). It validates Jinja2/YAML syntax
and runs ansible-lint. A full `--check --diff` dry-run requires SSH to the live hub.

All paths are relative to repo root.

## Prerequisites

Python 3.12 venv already in `.venv/` (mise + uv). No extra OS packages needed.
Collections are pre-installed in `.venv/.ansible/collections`.

## Setup

```bash
cd /home/ilia/Projects/wg-infra
source .venv/bin/activate
ansible-galaxy collection install -r requirements.yml   # idempotent; says "Nothing to do" if current
```

## Run (agent path — primary)

```bash
bash scripts/smoke.sh            # syntax-check both playbooks (default)
bash scripts/smoke.sh lint       # ansible-lint — exits non-zero with violations
bash scripts/smoke.sh all        # lint then syntax-check
```

The script auto-detects whether `~/.ansible/tmp` is writable. If not (e.g. in a
sandbox with a read-only home), it creates a `mktemp -d` directory and sets
`ANSIBLE_LOCAL_TEMP` automatically — no manual intervention needed.

**Expected output for syntax-check (success):**

```
==> syntax-check: hub.yml

playbook: playbooks/hub.yml
==> syntax-check: services.yml

playbook: playbooks/services.yml
Syntax OK.
```

Ansible prints the playbook path and exits 0 — no further output means success.

**Expected pre-refactor state for lint:**

```
Failed: 28 failure(s) …   ← exits 1
```

After fixing all lint violations, `bash scripts/smoke.sh all` should exit 0.

## Dry-run against the live hub (human path)

Requires vault password and SSH reachability (hub at 10.99.0.1:5860 via WireGuard).

```bash
ansible-playbook playbooks/hub.yml --check --diff --ask-vault-pass
ansible-playbook playbooks/services.yml --check --diff --ask-vault-pass --limit <host>
```

First-run bootstrap (fresh server, sshd still on port 22):

```bash
ansible-playbook playbooks/hub.yml -e ansible_port=22 --ask-vault-pass
```

## Gotchas

- **`ANSIBLE_LOCAL_TEMP` not `HOME`** — ansible ignores `HOME` for temp files in some
  versions; the correct override is `ANSIBLE_LOCAL_TEMP`. `scripts/smoke.sh` handles
  this automatically via the probe-and-fallback logic.
- **`mktemp` requires a writable `/tmp`** — in a Claude Code sandbox `/tmp` may also
  be read-only except for a specific scratchpad path. In that case pass the writable
  path explicitly: `ANSIBLE_LOCAL_TEMP=/path/to/writable bash scripts/smoke.sh syntax`
- **ansible-lint warns about vault.yml decryption** — `WARNING: Ignored exception …
  Decryption failed` is normal when running without `--ask-vault-pass`. Not an error.
- **`ansible-galaxy: Nothing to do`** — collections are already installed under
  `.venv/.ansible/collections`; that's correct.
- **"playbook: …" with no error after `--syntax-check`** — that IS the success output.
  Ansible just prints the playbook path and exits 0.

## Troubleshooting

**`[Errno 30] Read-only file system: '/home/ilia/.ansible/tmp/…'`**
→ `export ANSIBLE_LOCAL_TEMP=/tmp/writable-dir` before running, or let `smoke.sh`
  handle it (it probes writability and falls back to `mktemp` automatically).

**`lint: 28 failure(s)` (pre-refactor baseline)**
→ Expected before the lint-fix pass. Run `bash scripts/smoke.sh lint` again after
  fixing to confirm 0 violations.
