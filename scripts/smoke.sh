#!/usr/bin/env bash
# Smoke driver for wg-infra Ansible project.
# Usage:
#   scripts/smoke.sh            — syntax-check both playbooks (default)
#   scripts/smoke.sh lint       — ansible-lint (exits 0 only when lint-clean)
#   scripts/smoke.sh all        — lint then syntax-check
#
# Run from repo root.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
source .venv/bin/activate

# Ansible writes temp files to $ANSIBLE_LOCAL_TEMP (default: ~/.ansible/tmp).
# If that path is not writable (e.g. in a sandbox with read-only /home), use mktemp.
if [ -z "${ANSIBLE_LOCAL_TEMP:-}" ]; then
  ANSDIR="${HOME}/.ansible/tmp"
  if ! (mkdir -p "$ANSDIR" && touch "$ANSDIR/.probe" 2>/dev/null && rm "$ANSDIR/.probe"); then
    ANSDIR="$(mktemp -d -t wg-ansible-XXXXXX)"
    export ANSIBLE_LOCAL_TEMP="$ANSDIR"
    trap 'rm -rf "$ANSDIR"' EXIT
  fi
fi

MODE="${1:-syntax}"

run_syntax() {
  echo "==> syntax-check: hub.yml"
  ansible-playbook playbooks/hub.yml --syntax-check
  echo "==> syntax-check: services.yml"
  ansible-playbook playbooks/services.yml --syntax-check
  echo "Syntax OK."
}

run_lint() {
  echo "==> ansible-lint"
  ansible-lint
  echo "Lint OK."
}

case "$MODE" in
  syntax) run_syntax ;;
  lint)   run_lint ;;
  all)    run_lint; run_syntax ;;
  *)      echo "Usage: $0 [syntax|lint|all]" >&2; exit 1 ;;
esac
