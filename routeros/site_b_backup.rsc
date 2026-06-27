# 2026-06-27 17:02:43 by RouterOS 7.23.1
# software id = 6155-VEVA
#
# model = C53UiG+5HPaxD2HPaxD
# serial number = HEA08VQ1C1X
/interface bridge
add comment="Main bridge" name=bridge vlan-filtering=yes
/interface wifi
set [ find default-name=wifi2 ] channel.band=2ghz-ax .frequency=2402-2462 \
    .width=20/40mhz configuration.country=Kazakhstan .mode=ap .ssid=MT \
    disabled=no name=wifi_2.4 security.authentication-types=wpa2-psk,wpa3-psk \
    .encryption=ccmp .ft=yes .ft-mobility-domain=0x1234 .ft-over-ds=no \
    .ft-preserve-vlanid=no .group-encryption=ccmp .group-key-update=40m \
    .management-encryption=cmac .management-protection=allowed .wps=disable
add configuration.hide-ssid=yes .mode=ap .ssid=MT-IoT disabled=no \
    mac-address=D2:EA:11:10:2D:F2 master-interface=wifi_2.4 name=wifi_2.4_iot \
    security.authentication-types=wpa2-psk,wpa3-psk .ft=yes \
    .ft-mobility-domain=0x1235 .ft-over-ds=no .ft-preserve-vlanid=no .wps=\
    disable
set [ find default-name=wifi1 ] channel.band=5ghz-ax .frequency=\
    5170-5210,5210-5250,5250-5290,5290-5330,5650-5690,5690-5710 \
    .skip-dfs-channels=10min-cac .width=20/40/80mhz configuration.country=\
    Kazakhstan .mode=ap .ssid=MT disabled=no name=wifi_5 \
    security.authentication-types=wpa2-psk,wpa3-psk .disable-pmkid=yes \
    .encryption=ccmp .ft=yes .ft-mobility-domain=0x1234 .ft-over-ds=no \
    .ft-preserve-vlanid=no .group-encryption=ccmp .group-key-update=5m \
    .management-encryption=cmac .management-protection=required .wps=disable
add configuration.hide-ssid=yes .mode=ap .ssid=MT-Backhaul disabled=no \
    mac-address=4A:A9:8A:97:DF:C7 master-interface=wifi_5 name=\
    wifi_5_backhaul security.authentication-types=wpa2-psk,wpa3-psk \
    .encryption=ccmp .ft=no .wps=disable
/interface pppoe-client
add add-default-route=yes disabled=no interface=ether1 name=pppoe-homeline \
    user=ah3-2-12@unlim
/interface wireguard
add listen-port=23034 mtu=1420 name=wg-client
/interface vlan
add comment="Ethernet Clients" interface=bridge name=vlan10_eth vlan-id=10
add comment="WLAN Clients" interface=bridge name=vlan20_wlan vlan-id=20
add comment="IoT Devices" interface=bridge name=vlan30_iot vlan-id=30
add comment="IPTV Network" interface=bridge name=vlan40_iptv vlan-id=40
add comment="Switch device" interface=bridge name=vlan100_eth vlan-id=100
/interface list
add name=WAN
add name=TRUSTED_LAN
add name=UNTRUSTED_LAN
add name=VPN
add name=LAN
add name=ADMIN_ACCESS
add name=DISCOVER
/ip pool
add name=dhcp_pool1 ranges=10.2.10.2-10.2.10.254
add name=dhcp_pool2 ranges=10.2.20.2-10.2.20.254
add name=dhcp_pool3 ranges=10.2.30.2-10.2.30.254
add name=dhcp_pool4 ranges=10.2.40.2-10.2.40.254
add name=dhcp_pool5 ranges=10.2.100.2-10.2.100.254
add name=pool6-temp ranges=192.168.10.2-192.168.100.254
/ip dhcp-server
add address-pool=dhcp_pool1 interface=vlan10_eth name=dhcp1
add address-pool=dhcp_pool2 interface=vlan20_wlan name=dhcp2
add address-pool=dhcp_pool3 interface=vlan30_iot name=dhcp3
add address-pool=dhcp_pool4 interface=vlan40_iptv name=dhcp4
add address-pool=dhcp_pool5 interface=vlan100_eth name=dhcp5
/queue tree
add comment="Total Download Bandwidth" max-limit=400M name=Total_Download \
    parent=global
add comment="Total Upload Bandwidth" max-limit=400M name=Total_Upload parent=\
    global
/queue type
add kind=pcq name=pcq_dl pcq-classifier=dst-address
add kind=pcq name=pcq_ul pcq-classifier=src-address
/queue tree
add comment="High Priority Wired" max-limit=400M name=Queue_Eth_DL \
    packet-mark=pkt_eth_down parent=Total_Download priority=2 queue=pcq_dl
add comment="High Priority WiFi" max-limit=400M name=Queue_WLAN_DL \
    packet-mark=pkt_wlan_down parent=Total_Download priority=2 queue=pcq_dl
add comment="IoT with reservation" limit-at=10M max-limit=50M name=\
    Queue_IoT_DL packet-mark=pkt_iot_down parent=Total_Download priority=4 \
    queue=pcq_dl
add comment="High Priority Wired UL" max-limit=400M name=Queue_Eth_UL \
    packet-mark=pkt_eth_up parent=Total_Upload priority=2 queue=pcq_ul
add comment="High Priority WiFi UL" max-limit=400M name=Queue_WLAN_UL \
    packet-mark=pkt_wlan_up parent=Total_Upload priority=2 queue=pcq_ul
add comment="IoT UL reservation" limit-at=10M max-limit=50M name=Queue_IoT_UL \
    packet-mark=pkt_iot_up parent=Total_Upload priority=4 queue=pcq_ul
add comment="IPTV Download Limit" max-limit=30M name=Queue_IPTV_DL \
    packet-mark=pkt_iptv_down parent=Total_Download priority=4 queue=pcq_dl
add comment="IPTV Upload Limit" max-limit=30M name=Queue_IPTV_UL packet-mark=\
    pkt_iptv_up parent=Total_Upload priority=4 queue=pcq_ul
/system logging action
set 0 memory-lines=9999
set 1 disk-lines-per-file=9999
/system script
add dont-require-permissions=no name=sys_reboot owner=ilya policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source=\
    "/system reboot"
add dont-require-permissions=no name=root_certs_fetch owner=ilya policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="{\
    \n  :local retryCount 0;\
    \n  :local maxRetries 3;\
    \n  :local success false;\
    \n\
    \n  :while (\$retryCount < \$maxRetries and \$success = false) do={\
    \n    :do {\
    \n      :log info \"Fetching cacert.pem (attempt [:tostr (\$retryCount + 1\
    )] of \$maxRetries)\";\
    \n      /tool fetch url=\"https://curl.se/ca/cacert.pem\" check-certificat\
    e=no dst-path=\"cacert.pem\";\
    \n      :delay 5s;\
    \n\
    \n      # Remove previously imported bundle certs to avoid duplicates.\
    \n      # RouterOS names certs by their Subject CN, so we can't filter by \
    filename.\
    \n      # Removing all untrusted/non-device certs is the safest blanket ap\
    proach.\
    \n      :foreach c in=[/certificate find where !private-key and !smart-car\
    d-key] do={\
    \n        /certificate remove \$c;\
    \n      };\
    \n      :delay 2s;\
    \n\
    \n      :local beforeCount [:len [/certificate find]];\
    \n\
    \n      # LDAP CRL URLs in the D-Trust cert are unsupported by RouterOS an\
    d will\
    \n      # cause import to abort mid-bundle. Catch the error and continue \
    \E2\80\94 all\
    \n      # certs processed before the abort are already stored.\
    \n      :do {\
    \n        /certificate import file-name=\"cacert.pem\" passphrase=\"\";\
    \n      } on-error={\
    \n        :log debug \"Import interrupted (unsupported CRL protocol \E2\80\
    \94 expected). Checking imported count...\";\
    \n      };\
    \n      :delay 2s;\
    \n\
    \n      :do {\
    \n        /file remove \"cacert.pem\";\
    \n      } on-error={};\
    \n\
    \n      :local afterCount [:len [/certificate find]];\
    \n      :local newCerts (\$afterCount - \$beforeCount);\
    \n\
    \n      :if (\$newCerts > 40) do={\
    \n        :log info \"DoH trust store updated: \$newCerts certificates imp\
    orted\";\
    \n        :set success true;\
    \n      } else={\
    \n        :error \"Validation failed: only \$newCerts certificates importe\
    d (expected >40)\";\
    \n      };\
    \n\
    \n    } on-error={\
    \n      :set retryCount (\$retryCount + 1);\
    \n      :log warning \"Certificate update attempt \$retryCount failed, ret\
    rying in 10s...\";\
    \n      :delay 10s;\
    \n    };\
    \n  };\
    \n\
    \n  :if (\$success = false) do={\
    \n    :log error \"Failed to update DoH trust store after \$maxRetries att\
    empts\";\
    \n  };\
    \n}"
add dont-require-permissions=no name=ping_dns owner=ilya policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="/\
    tool fetch url=\"https://link-ip.nextdns.io/38c971/bf8a78ee037487fe\" outp\
    ut=none"
add dont-require-permissions=no name=dark_mode owner=ilya policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source=":\
    if ([system leds settings get all-leds-off] = \"never\") do={\r\
    \n    /system leds settings set all-leds-off=immediate \r\
    \n} else={\r\
    \n    /system leds settings set all-leds-off=never \r\
    \n}"
/interface bridge port
add bridge=bridge interface=ether2
add bridge=bridge interface=ether3 pvid=10
add bridge=bridge interface=ether4 pvid=10
add bridge=bridge interface=wifi_2.4 pvid=20
add bridge=bridge interface=wifi_5 pvid=20
add bridge=bridge interface=wifi_2.4_iot pvid=30
add bridge=bridge interface=wifi_5_backhaul pvid=10
/ip neighbor discovery-settings
set discover-interface-list=DISCOVER
/ipv6 settings
set disable-ipv6=yes
/interface bridge vlan
add bridge=bridge tagged=bridge,wifi_5_backhaul vlan-ids=20
add bridge=bridge tagged=bridge,wifi_5_backhaul vlan-ids=30
add bridge=bridge tagged=bridge,ether2 vlan-ids=40
add bridge=bridge tagged=bridge,ether2 vlan-ids=100
/interface list member
add interface=ether1 list=WAN
add interface=vlan10_eth list=TRUSTED_LAN
add interface=vlan20_wlan list=TRUSTED_LAN
add interface=vlan30_iot list=UNTRUSTED_LAN
add interface=pppoe-homeline list=WAN
add interface=bridge list=LAN
add interface=ether5 list=ADMIN_ACCESS
add interface=ether5 list=LAN
add interface=vlan10_eth list=LAN
add interface=vlan20_wlan list=LAN
add interface=wg-client list=VPN
add interface=wg-client list=DISCOVER
add interface=ether5 list=DISCOVER
add interface=vlan10_eth list=DISCOVER
add interface=vlan20_wlan list=DISCOVER
add interface=vlan40_iptv list=UNTRUSTED_LAN
add interface=vlan100_eth list=LAN
add interface=vlan100_eth list=TRUSTED_LAN
add interface=vlan100_eth list=DISCOVER
/interface wireguard peers
add allowed-address=\
    10.99.0.0/24,10.1.10.0/24,10.1.20.0/24,10.1.30.0/24,10.1.40.0/24 \
    client-allowed-address=::/0 endpoint-address=65.21.177.182 endpoint-port=\
    51820 interface=wg-client name=peer1 persistent-keepalive=25s public-key=\
    "WGxjeOkNYGXY2VG/jSCnEUVtNSbgjtpN1/TyzU6jzXI="
/ip address
add address=10.2.10.1/24 comment="Ethernet Gateway" interface=vlan10_eth \
    network=10.2.10.0
add address=10.2.20.1/24 comment="WLAN Gateway" interface=vlan20_wlan \
    network=10.2.20.0
add address=10.2.30.1/24 comment="IoT Gateway" interface=vlan30_iot network=\
    10.2.30.0
add address=192.168.88.1/24 comment="Admin access network" interface=ether5 \
    network=192.168.88.0
add address=10.99.0.12/24 comment="Wireguard overlay" interface=wg-client \
    network=10.99.0.0
add address=10.2.40.1/24 comment="IPTV Gateway" interface=vlan40_iptv \
    network=10.2.40.0
add address=10.2.100.1/24 comment="Switch admin access" interface=vlan100_eth \
    network=10.2.100.0
/ip cloud
set update-time=no
/ip dhcp-server lease
add address=10.2.10.252 client-id=1:78:9a:18:fd:1f:72 mac-address=\
    78:9A:18:FD:1F:72 server=dhcp1
add address=10.2.100.254 client-id=1:d4:1:c3:19:ec:c3 mac-address=\
    D4:01:C3:19:EC:C3 server=dhcp5
add address=10.2.30.3 client-id=1:50:57:9c:91:50:a7 mac-address=\
    50:57:9C:91:50:A7 server=dhcp3
/ip dhcp-server network
add address=10.2.10.0/24 dns-server=10.2.10.1 gateway=10.2.10.1
add address=10.2.20.0/24 dns-server=10.2.20.1 gateway=10.2.20.1
add address=10.2.30.0/24 gateway=10.2.30.1 ntp-server=10.2.30.1
add address=10.2.40.0/24 dns-server=\
    94.143.199.235,94.143.199.236,1.1.1.1,8.8.8.8 gateway=10.2.40.1 \
    ntp-server=10.2.40.1
add address=10.2.100.0/24 gateway=10.2.100.1 ntp-server=10.2.100.1
/ip dns
set allow-remote-requests=yes cache-size=8192KiB doh-max-concurrent-queries=\
    200 doh-max-server-connections=20 doh-timeout=10s max-concurrent-queries=\
    1000 max-concurrent-tcp-sessions=100 mdns-repeat-ifaces=\
    vlan10_eth,vlan20_wlan,vlan30_iot use-doh-server=\
    https://dns.nextdns.io/38c971/MikroTik verify-doh-cert=yes
/ip dns static
add address=192.168.88.1 name=router.lan type=A
add address=45.90.28.0 name=dns.nextdns.io type=A
add address=45.90.30.0 name=dns.nextdns.io type=A
add address=10.2.10.252 name=extender.lan type=A
add address=10.2.100.254 name=crs.lan type=A
add forward-to=10.99.0.1 match-subdomain=yes name=in.threadnull.dev type=FWD
add address=10.2.30.3 name=printer.lan type=A
/ip firewall address-list
add address=0.0.0.0/8 list=Bogons
add address=10.0.0.0/8 list=Bogons
add address=100.64.0.0/10 list=Bogons
add address=127.0.0.0/8 list=Bogons
add address=169.254.0.0/16 list=Bogons
add address=172.16.0.0/12 list=Bogons
add address=192.0.0.0/24 list=Bogons
add address=192.0.2.0/24 list=Bogons
add address=192.168.0.0/16 list=Bogons
add address=198.18.0.0/15 list=Bogons
add address=198.51.100.0/24 list=Bogons
add address=203.0.113.0/24 list=Bogons
add address=224.0.0.0/4 list=Bogons
add address=240.0.0.0/4 comment="Bogon and Martian ranges" list=Bogons
add address=192.168.88.0/24 comment="Admin access range" list=Admin_Access
add address=10.2.10.0/24 comment="Management from Trusted Wired" list=\
    Admin_Access
add address=10.2.20.0/24 comment="Management from Trusted WiFi" list=\
    Admin_Access
/ip firewall filter
add action=add-src-to-address-list address-list=Port_Scanners \
    address-list-timeout=1d chain=input comment="IaC: Detect TCP port scans" \
    protocol=tcp psd=21,3s,3,1
add action=drop chain=input comment="IaC: Drop port scanners on input" \
    src-address-list=Port_Scanners
add action=drop chain=forward comment=\
    "IaC: Drop port scanners passing through" src-address-list=Port_Scanners
add action=accept chain=input comment=\
    "IaC: Accept established, related, untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="IaC: Drop invalid packets" \
    connection-state=invalid log-prefix=Drop_Invalid_Input
add action=accept chain=input comment="IaC: Allow Trusted mDNS" dst-address=\
    224.0.0.251 dst-port=5353 in-interface-list=TRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow IoT mDNS" dst-address=\
    224.0.0.251 dst-port=5353 in-interface-list=UNTRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow PMTUD (Type 3 Code 4)" \
    icmp-options=3:4 protocol=icmp
add action=accept chain=input comment="IaC: Allow limited ICMP" limit=\
    50/5s,2:packet protocol=icmp
add action=accept chain=input comment="IaC: Allow admin access" \
    src-address-list=Admin_Access
add action=accept chain=input comment="IaC: Allow Trusted DHCP" dst-port=67 \
    in-interface-list=TRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow Trusted DNS UDP" dst-port=\
    53 in-interface-list=TRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow Trusted DNS TCP" dst-port=\
    53 in-interface-list=TRUSTED_LAN protocol=tcp
add action=accept chain=input comment="IaC: Allow IoT DHCP" dst-port=67 \
    in-interface-list=UNTRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow IoT DNS UDP" dst-port=53 \
    in-interface-list=UNTRUSTED_LAN protocol=udp
add action=accept chain=input comment="IaC: Allow IoT DNS TCP" dst-port=53 \
    in-interface-list=UNTRUSTED_LAN protocol=tcp
add action=accept chain=input comment="IaC: Allow LAN DNS UDP" dst-port=53 \
    in-interface-list=LAN protocol=udp
add action=accept chain=input comment="IaC: Allow LAN DNS TCP" dst-port=53 \
    in-interface-list=LAN protocol=tcp
add action=accept chain=input comment="IaC: Allow LAN DHCP" dst-port=67 \
    in-interface-list=LAN protocol=udp
add action=accept chain=input comment="IaC: Allow IoT NTP UDP" dst-port=123 \
    in-interface-list=UNTRUSTED_LAN protocol=udp
add action=drop chain=input comment="IaC: Drop IoT to Router" \
    in-interface-list=UNTRUSTED_LAN log-prefix=Drop_IoT_to_Router
add action=accept chain=input comment="IaC: Allow VPN DNS UDP" dst-port=53 \
    in-interface-list=VPN protocol=udp
add action=accept chain=input comment="IaC: Allow VPN DNS TCP" dst-port=53 \
    in-interface-list=VPN protocol=tcp
add action=accept chain=input comment="IaC: Allow Management from VPN" \
    dst-port=8291,5946 in-interface-list=VPN protocol=tcp
add action=accept chain=input comment="IaC: Allow MNDP" dst-port=5678 \
    in-interface-list=DISCOVER protocol=udp
add action=drop chain=input comment="IaC: Drop all other input" log-prefix=\
    Drop_Input_Catchall
add action=accept chain=forward comment=\
    "IaC: Accept established, related, untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="IaC: Drop invalid packets" \
    connection-state=invalid log-prefix=Drop_Invalid_Forward
add action=drop chain=forward comment=\
    "IaC: Drop access to clients behind NAT from WAN" connection-nat-state=\
    !dstnat connection-state=new in-interface-list=WAN
add action=drop chain=forward comment="IaC: Drop bogons from WAN" \
    in-interface-list=WAN log=yes log-prefix=Drop_Spoofed_WAN \
    src-address-list=Bogons
add action=accept chain=forward comment="IaC: Allow Trusted to IoT" \
    in-interface-list=TRUSTED_LAN out-interface-list=UNTRUSTED_LAN
add action=accept chain=forward comment="IaC: Allow VPN to IoT" \
    in-interface-list=VPN out-interface-list=UNTRUSTED_LAN
add action=drop chain=forward comment="IaC: Drop IoT to Trusted LAN" \
    in-interface-list=UNTRUSTED_LAN log=yes log-prefix=Drop_IoT_to_Trusted \
    out-interface-list=TRUSTED_LAN
add action=drop chain=forward comment="IaC: Drop IoT to VPN" \
    in-interface-list=UNTRUSTED_LAN log=yes log-prefix=Drop_IoT_to_VPN \
    out-interface-list=VPN
add action=accept chain=forward comment="IaC: Allow port forwarding" \
    connection-nat-state=dstnat
add action=accept chain=forward comment="IaC: Allow Trusted to WAN" \
    in-interface-list=TRUSTED_LAN out-interface-list=WAN
add action=accept chain=forward comment="IaC: Allow IoT to WAN" \
    in-interface-list=UNTRUSTED_LAN out-interface-list=WAN
add action=accept chain=forward comment="IaC: Allow VPN to WAN" \
    in-interface-list=VPN out-interface-list=WAN
add action=accept chain=forward comment="IaC: Allow VPN to TRUSTED_LAN" \
    in-interface-list=VPN out-interface-list=TRUSTED_LAN
add action=accept chain=forward comment="IaC: Allow Trusted to Trusted" \
    in-interface-list=TRUSTED_LAN out-interface-list=TRUSTED_LAN
add action=accept chain=forward comment="IaC: Allow Trusted to VPN" \
    in-interface-list=TRUSTED_LAN out-interface-list=VPN
add action=drop chain=forward comment="IaC: Drop all other forward" log=yes \
    log-prefix=Drop_Forward_Catchall
/ip firewall mangle
add action=mark-packet chain=forward comment="Mark Ethernet DL" \
    new-packet-mark=pkt_eth_down out-interface=vlan10_eth passthrough=no
add action=mark-packet chain=forward comment="Mark WLAN DL" new-packet-mark=\
    pkt_wlan_down out-interface=vlan20_wlan passthrough=no
add action=mark-packet chain=forward comment="Mark IoT DL" new-packet-mark=\
    pkt_iot_down out-interface=vlan30_iot passthrough=no
add action=mark-packet chain=forward comment="Mark Ethernet UL" in-interface=\
    vlan10_eth new-packet-mark=pkt_eth_up passthrough=no
add action=mark-packet chain=forward comment="Mark WLAN UL" in-interface=\
    vlan20_wlan new-packet-mark=pkt_wlan_up passthrough=no
add action=mark-packet chain=forward comment="Mark IoT UL" in-interface=\
    vlan30_iot new-packet-mark=pkt_iot_up passthrough=no
add action=mark-packet chain=forward comment="Mark IPTV DL" new-packet-mark=\
    pkt_iptv_down out-interface=vlan40_iptv passthrough=no
add action=mark-packet chain=forward comment="Mark IPTV UL" in-interface=\
    vlan40_iptv new-packet-mark=pkt_iptv_up passthrough=no
/ip firewall nat
add action=masquerade chain=srcnat out-interface-list=WAN
/ip route
add comment="IaC overlay route: site_a" dst-address=10.1.10.0/24 gateway=\
    wg-client
add comment="IaC overlay route: site_a" dst-address=10.1.20.0/24 gateway=\
    wg-client
add comment="IaC overlay route: site_a" dst-address=10.1.30.0/24 gateway=\
    wg-client
add comment="IaC overlay route: site_a" dst-address=10.1.40.0/24 gateway=\
    wg-client
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www disabled=yes
set ssh max-sessions=10 port=5946
set api disabled=yes
/ip ssh
set strong-crypto=yes
/ipv6 firewall filter
add action=drop chain=input comment="IaC: Drop all IPv6 in input"
add action=drop chain=forward comment="IaC: Drop all IPv6 in forward"
add action=drop chain=output comment="IaC: Drop all IPv6 in output"
/system clock
set time-zone-name=Asia/Bishkek
/system ntp client
set enabled=yes
/system ntp server
set enabled=yes
/system ntp client servers
add address=1.kg.pool.ntp.org
add address=0.asia.pool.ntp.org
add address=3.asia.pool.ntp.org
add address=2.kg.pool.ntp.org
/system routerboard mode-button
set enabled=yes on-event=dark-mode
/system routerboard wps-button
set enabled=yes on-event=wps-accept
/system scheduler
add interval=4w2d name="System reboot" on-event=sys_reboot policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    start-date=2024-09-30 start-time=05:00:00
add interval=25w5d name="Root certs update" on-event=root_certs_fetch policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    start-date=2024-09-30 start-time=06:00:00
add interval=6h name="Ping DNS" on-event=ping_dns policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    start-date=2024-11-02 start-time=14:15:43
/tool bandwidth-server
set enabled=no
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
/tool mac-server ping
set enabled=no
