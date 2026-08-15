# =============================================================================
# logging-remote-extender.rsc
# Remote logging for the hAP ax2 L2 extender (10.2.10.249, vlan10 of site_b).
#
# The extender has no overlay interface of its own; it reaches the logs VPS via
# its default gateway (site_b), which routes 10.99.0.0/24 into the tunnel. The
# packets therefore source from 10.2.10.249, which is inside site_b's LAN and
# thus part of @site_nets on the hub — so the udp/514 ingress rule admits them
# without any extra change. No src-address is set (uses the LAN IP).
#
# BEFORE APPLYING: set /system identity to a stable name (e.g. extender) — it
# becomes the `host` field in ELK. The extender has NO firewall (pure L2), so
# nothing else is required on the device.
# =============================================================================

# --- 1. Remote logging action (no src-address; sources from 10.2.10.249) ------
:if ([:len [/system logging action find name=remote-elk]] = 0) do={
    /system logging action add name=remote-elk target=remote remote=10.99.0.101 \
        remote-port=514 bsd-syslog=yes \
        comment="IaC: ship logs to central ELK (logs VPS)"
} else={
    /system logging action set [find name=remote-elk] remote=10.99.0.101 \
        remote-port=514 bsd-syslog=yes
}

# --- 2. Topics ----------------------------------------------------------------
:local addtopic do={
    :if ([:len [/system logging find where action="remote-elk" and topics=$1]] = 0) do={
        /system logging add topics=$1 action=remote-elk
    }
}
$addtopic "info"
$addtopic "warning"
$addtopic "error"
$addtopic "critical"

# --- Verification -------------------------------------------------------------
# /system logging action print where name=remote-elk
# From site_b, confirm the extender can reach the VPS gateway path; on the VPS:
#   curl -s -u elastic:*** '10.99.0.101:9200/logs-*/_search?q=host:extender&size=1&pretty'
