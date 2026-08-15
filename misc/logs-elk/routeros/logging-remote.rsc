# =============================================================================
# logging-remote.rsc
# Ship RouterOS logs to the central ELK stack (logs VPS, 10.99.0.101:514) over
# the WireGuard overlay. Apply on site_a AND site_b.
#
# BEFORE APPLYING (per router):
#   - set REMOTE_SRC below to the router's overlay IP (site_a 10.99.0.11,
#     site_b 10.99.0.12) so the syslog packets source from the overlay and the
#     hub ACL (@site_nets) admits them;
#   - make sure /system identity is a stable name (site-a / site-b) — RouterOS
#     uses it as the BSD-syslog hostname, which becomes the `host` field in ELK.
#
# No firewall rule is needed on the router: it initiates the outbound flow and
# established/related is already accepted. The hub permits @site_nets ->
# 10.99.0.101 udp/514 via the "logs" service ingress in group_vars/all/network.yml.
# Idempotent: re-running leaves existing action/rules in place (updates target).
# =============================================================================

# --- per-router source address (overlay IP): EDIT before applying ------------
:global REMOTE_SRC "10.99.0.11"

# --- 1. Remote logging action -------------------------------------------------
:if ([:len [/system logging action find name=remote-elk]] = 0) do={
    /system logging action add name=remote-elk target=remote remote=10.99.0.101 \
        remote-port=514 src-address=$REMOTE_SRC bsd-syslog=yes \
        comment="IaC: ship logs to central ELK (logs VPS)"
} else={
    /system logging action set [find name=remote-elk] remote=10.99.0.101 \
        remote-port=514 src-address=$REMOTE_SRC bsd-syslog=yes
}

# --- 2. Which topics to ship --------------------------------------------------
# Keep volume sane: severities + the operationally useful facilities. Add or
# drop topics to taste (e.g. firewall,dhcp,wireless can be chatty).
:local addtopic do={
    :if ([:len [/system logging find where action="remote-elk" and topics=$1]] = 0) do={
        /system logging add topics=$1 action=remote-elk
    }
}
$addtopic "info"
$addtopic "warning"
$addtopic "error"
$addtopic "critical"

# --- Verification (run manually) ---------------------------------------------
# /system logging action print where name=remote-elk
# /system logging print where action=remote-elk
# /system identity print
# On the VPS: curl -s -u elastic:*** \
#   '10.99.0.101:9200/logs-*/_search?q=host:site-a&size=1&pretty'
