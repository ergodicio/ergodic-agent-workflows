#!/usr/bin/env bash
# Print the resolved ergodic-claude config — which account, project space, QOS, etc.
# the helpers will actually use, after shell env > user config > repo defaults.
#
# Usage:
#   show-config.sh                # every setting, as KEY=value
#   show-config.sh EC_ACCOUNT     # one value, bare (for `A=$(show-config.sh EC_ACCOUNT)`)
#   show-config.sh --export       # eval-able: eval "$(show-config.sh --export)"
#
# No ssh, no side effects — safe to call before anything else. Use it to fill in the
# account and project paths in commands instead of hardcoding them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

KEYS="EC_CONFIG EC_SSH_HOST EC_ACCOUNT EC_ACCOUNT_GPU EC_SOFTWARE_ROOT EC_QOS EC_CONSTRAINT EC_TIME_LIMIT EC_NODES EC_GPUS_PER_NODE"

case "${1:-}" in
  "")
    for k in $KEYS; do printf '%s=%s\n' "$k" "${!k}"; done
    if [ -z "$EC_ACCOUNT" ]; then
      printf '\n# EC_ACCOUNT is unset — submitting helpers will refuse to run.\n'
      printf '# Your projects: %s/list-accounts.sh\n' "$SCRIPT_DIR"
      printf '# Set it in: %s\n' "$EC_CONFIG"
    fi
    ;;
  --export)
    for k in $KEYS; do printf 'export %s=%q\n' "$k" "${!k}"; done
    ;;
  -h|--help)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  EC_*)
    # Unknown EC_* names print empty rather than erroring, so callers can probe.
    printf '%s\n' "${!1:-}"
    ;;
  *)
    echo "unknown argument: $1 (expected an EC_* key, --export, or nothing)" >&2
    exit 2
    ;;
esac
