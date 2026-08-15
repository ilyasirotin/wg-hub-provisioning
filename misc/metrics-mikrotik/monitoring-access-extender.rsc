# =============================================================================
# monitoring-access-extender.rsc
# API access for mktxp on the hAP ax2 L2 extender (10.2.10.249, vlan10 of
# site_b). Generated from routeros/extender_backup.rsc (2026-07-08).
#
# The extender has NO firewall (pure L2 bridge + wifi) and no /ip service
# overrides, so the API service is already enabled on 8728 - this script
# only creates the read-only user and pins both the user and the API
# service to the monitoring VPS (10.99.0.100). Safe to re-run.
#
# BEFORE APPLYING: replace CHANGE_ME_STRONG_PASSWORD with the same password
# as in mktxp/mktxp.conf (the shared [default] credentials).
# =============================================================================

:if ([:len [/user group find name=monitoring]] = 0) do={
    /user group add name=monitoring policy=api,read comment="IaC: Read-only group for Prometheus exporter"
}
:if ([:len [/user find name=prometheus]] = 0) do={
    /user add name=prometheus group=monitoring password="CHANGE_ME_STRONG_PASSWORD" address=10.99.0.100/32 comment="IaC: Prometheus exporter (mktxp)"
}

# Bind the (default-enabled) API service to the monitoring VPS only.
/ip service set api disabled=no address=10.99.0.100/32

# --- Verification (run manually) ---------------------------------------------
# /ip service print where name=api
# /user print where name=prometheus
# From the VPS: nc -zv 10.2.10.249 8728
