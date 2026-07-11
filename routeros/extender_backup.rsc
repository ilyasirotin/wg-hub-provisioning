# 2026-07-08 01:10:08 by RouterOS 7.23.2
# software id = RJ2Z-8XDW
#
# model = C52iG-5HaxD2HaxD
# serial number = HFM0983985C
/interface bridge
add name=bridge vlan-filtering=yes
/interface wifi
set [ find default-name=wifi2 ] channel.band=2ghz-ax .frequency=2402-2462 \
    .width=20/40mhz configuration.country=Kazakhstan .mode=ap .ssid=MT \
    disabled=no name=wifi_2.4_local security.authentication-types=\
    wpa2-psk,wpa3-psk .encryption=ccmp .ft=no .ft-mobility-domain=0x1234 \
    .ft-over-ds=no .group-encryption=ccmp .group-key-update=40m \
    .management-encryption=cmac .management-protection=allowed .wps=disable
add configuration.hide-ssid=yes .mode=ap .ssid=MT-TV disabled=no mac-address=\
    7A:9A:18:FD:1F:74 master-interface=wifi_2.4_local name=wifi_2.4_tv \
    security.authentication-types=wpa2-psk,wpa3-psk .ft=no .ft-over-ds=no \
    .wps=disable
set [ find default-name=wifi1 ] channel.band=5ghz-ax .frequency=5170-5250 \
    .skip-dfs-channels=10min-cac .width=20/40/80mhz configuration.country=\
    Kazakhstan .mode=station-bridge .ssid=MT-Backhaul disabled=no name=\
    wifi_station_5ghz security.authentication-types=wpa2-psk,wpa3-psk \
    .disable-pmkid=yes .encryption=ccmp .group-encryption=ccmp \
    .group-key-update=5m .management-encryption=cmac .management-protection=\
    required .wps=disable
/interface vlan
add interface=bridge name=vlan10_mgmt vlan-id=10
/interface wifi
add configuration.hide-ssid=yes .mode=ap .ssid=MT-IoT disabled=no \
    mac-address=7A:9A:18:FD:1F:73 master-interface=wifi_2.4_local name=\
    wifi_2.4_iot security.authentication-types=wpa2-psk,wpa3-psk .ft=no \
    .ft-mobility-domain=0x1235 .ft-over-ds=no .wps=disable
add configuration.mode=ap .ssid=MT disabled=no mac-address=7A:9A:18:FD:1F:72 \
    master-interface=wifi_station_5ghz name=wifi_5_local \
    security.authentication-types=wpa2-psk,wpa3-psk .ft=no \
    .ft-mobility-domain=0x1234 .ft-over-ds=no .wps=disable
/interface bridge port
add bridge=bridge interface=wifi_station_5ghz pvid=10
add bridge=bridge interface=wifi_5_local pvid=20
add bridge=bridge interface=wifi_2.4_local pvid=20
add bridge=bridge interface=wifi_2.4_iot pvid=30
add bridge=bridge interface=wifi_2.4_tv pvid=30
add bridge=bridge interface=ether1 pvid=10
add bridge=bridge interface=ether2 pvid=10
add bridge=bridge interface=ether3 pvid=10
add bridge=bridge interface=ether4 pvid=10
add bridge=bridge interface=ether5 pvid=10
/ipv6 settings
set disable-ipv6=yes
/interface bridge vlan
add bridge=bridge tagged=bridge vlan-ids=10
add bridge=bridge tagged=wifi_station_5ghz vlan-ids=20
add bridge=bridge tagged=wifi_station_5ghz vlan-ids=30
/ip dhcp-client
add interface=vlan10_mgmt name=client1
/system clock
set time-zone-name=Asia/Bishkek
