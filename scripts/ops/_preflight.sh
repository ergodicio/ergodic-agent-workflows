# Sourced by every ssh-using ops script, *after* config.sh.
# Verifies ssh to $EC_SSH_HOST works; caches the result for 1 hour via
# a /tmp marker so the BatchMode check doesn't add latency to every call.
# Exits 1 with an actionable error if ssh is broken.

_ec_marker="/tmp/.ec-ssh-ok-${EC_SSH_HOST}-$(id -u)"
if [ -f "$_ec_marker" ]; then
    _ec_mtime=$(stat -c %Y "$_ec_marker" 2>/dev/null \
             || stat -f %m "$_ec_marker" 2>/dev/null \
             || echo 0)
    _ec_age=$(( $(date +%s) - _ec_mtime ))
    if [ "$_ec_age" -lt 3600 ]; then
        unset _ec_marker _ec_mtime _ec_age
        return 0
    fi
    unset _ec_mtime _ec_age
fi

if ssh -o BatchMode=yes -o ConnectTimeout=5 "$EC_SSH_HOST" true 2>/dev/null; then
    touch "$_ec_marker"
    unset _ec_marker
    return 0
fi

cat >&2 <<EOF

[ergodic-claude] ssh to '$EC_SSH_HOST' is not working.

Likely causes:
  1. The '$EC_SSH_HOST' alias is missing from ~/.ssh/config.
  2. Your NERSC sshproxy cert is expired — run sshproxy again.
  3. You haven't set up sshproxy yet.

Docs:    https://docs.nersc.gov/connect/mfa/#sshproxy
Verify:  ssh $EC_SSH_HOST true
EOF
exit 1
