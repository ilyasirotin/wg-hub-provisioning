# =============================================================================
# monitoring-access.rsc
# Enables RouterOS API access for the Prometheus exporter (swoga/mikrotik-exporter)
# running on the monitoring VPS (WireGuard peer, tunnel IP 10.99.0.100).
#
# STATUS: already applied on BOTH routers (site A 10.99.0.11, site B
# 10.99.0.12) - present in the 2026-07-06 config exports in routeros/.
# Kept for reference and for future sites; the guards below make it safe
# to re-run (existing user/group/rule are left untouched).
#
# BEFORE APPLYING to a new router: replace CHANGE_ME_STRONG_PASSWORD with the
# same password as in the exporter's config.yml.
# =============================================================================

# --- 1. Read-only monitoring user, restricted to the VPS tunnel IP -----------
# Policy "api,read" is the minimum required by the exporter.
:if ([:len [/user group find name=monitoring]] = 0) do={
    /user group add name=monitoring policy=api,read comment="IaC: Read-only group for Prometheus exporter"
}
:if ([:len [/user find name=prometheus]] = 0) do={
    /user add name=prometheus group=monitoring password="CHANGE_ME_STRONG_PASSWORD" address=10.99.0.100/32 comment="IaC: Prometheus exporter (swoga/mikrotik-exporter)"
}

# --- 2. Enable the RouterOS API service, bound to the VPS only ---------------
# API traffic (TCP 8728) is plaintext, but it travels exclusively inside the
# WireGuard tunnel, so api-ssl is not required.
/ip service set api disabled=no address=10.99.0.100/32

# --- 3. Firewall: allow API from the VPS before the input catch-all ----------
# The existing input chain only allows DNS (53) and management (8291,5946)
# from the VPN list; port 8728 would otherwise hit "IaC: Drop all other input".
:if ([:len [/ip firewall filter find where comment="IaC: Allow RouterOS API from monitoring VPS"]] = 0) do={
    /ip firewall filter add chain=input action=accept protocol=tcp dst-port=8728 src-address=10.99.0.100 in-interface-list=VPN comment="IaC: Allow RouterOS API from monitoring VPS" place-before=[find where chain=input and comment="IaC: Drop all other input"]
}

# --- Verification (run manually) ---------------------------------------------
# /ip service print where name=api
# /ip firewall filter print where comment~"monitoring VPS"
# From the VPS: nc -zv 10.99.0.11 8728  (and 10.99.0.12)
