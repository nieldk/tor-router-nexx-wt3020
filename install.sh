#!/bin/sh
#
# Configure onionwrt
#

[ -z "$SSID" ] && SSID=OnionWRT

LAN_IP=$(uci get network.lan.ipaddr)

opkg update 2>&1 >/dev/null

# Check key:
if [ ! -z "$KEY" ]
then
 	[ $(echo -n $KEY| wc -c) -lt 7 ] && { echo "KEY is too short."; exit; }
 	[ $(echo -n $KEY| wc -c) -gt 62 ] && { echo "KEY is too long."; exit; }
	( opkg list-installed |grep -q wpad-mini ) || opkg install wpad-mini
fi

# Install Tor
( opkg list-installed |grep -q tor ) || opkg install tor
( opkg list-installed |grep -q tor ) || { echo "Error: Tor is not installed."; exit; } 

# Configure Tor
# Create User and Group
( cat /etc/passwd |grep -q ^tor ) || echo "tor:*:52:52:tor:/var/run/tor:/bin/false" >> /etc/passwd
( cat /etc/shadow |grep -q ^tor ) || echo "tor:*:0:0:99999:7:::" >> /etc/shadow
( cat /etc/group |grep -q ^tor ) || echo "tor:x:52:" >> /etc/group

# Netejem directoris
killall -9 tor
rm -rf /etc/tor
rm -rf /var/lib/tor
rm -f /var/run/tor.pid

# Create Tor Configuration
mkdir -p /etc/tor

cat > /etc/tor/torrc << EOF
# Tor configuration
User tor
RunAsDaemon 1
PidFile /var/run/tor.pid
DataDirectory /var/lib/tor
AutomapHostsOnResolve 1
AutomapHostsSuffixes   .onion,.exit
TransPort ${LAN_IP}:9040
DNSPort ${LAN_IP}:9053

EOF
mkdir -p /var/lib/tor
chown tor /var/lib/tor
mkdir -p /var/run
touch /var/run/tor.pid
chown tor /var/run/tor.pid

# Configure transparent proxy
sed -i -e '/# DNT/d' /etc/firewall.user

cat >> /etc/firewall.user << EOF
iptables -t nat -A PREROUTING -i br-lan -s $(uci get network.lan.ipaddr)/$(ipcalc.sh $(uci get network.lan.ipaddr) $(uci get network.lan.netmask)|grep PREFIX|cut -d "=" -f 2) -d $(uci get network.lan.ipaddr) -j RETURN # DNT
iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 9053 # DNT
iptables -t nat -A PREROUTING -i br-lan -p tcp --syn -j REDIRECT --to-ports 9040 # DNT
# Drop ICMP # DNT
iptables -A INPUT -p icmp --icmp-type 8 -j DROP # DNT
# security rules from https://lists.torproject.org/pipermail/tor-talk/2014-March/032507.html # DNT
iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP # DNT
iptables -A OUTPUT -m state --state INVALID -j DROP # DNT
# security rules to prevent kernel leaks from link above # DNT
iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,FIN ACK,FIN -j DROP # DNT
iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,RST ACK,RST -j DROP # DNT
# disable chrome and firefox udp leaks # DNT
iptables -t nat -A PREROUTING -p udp -m multiport --dport 3478,19302 -j REDIRECT --to-ports 9999 # DNT
iptables -t nat -A PREROUTING -p udp -m multiport --sport 3478,19302 -j REDIRECT --to-ports 9999 # DNT
EOF

# Configure wifi.
mv /etc/config/wireless /etc/config/wireless.bak
wifi config |grep -v disabled|grep -v REMOVE > /etc/config/wireless

# Configure all "lan" wifis.
for radio in $(uci show wireless|grep lan|cut -d "." -f 2)
do 
	uci set wireless.${radio}.ssid=${SSID}
	[ ! -z "$KEY" ] && { uci set wireless.${radio}.encryption=psk;uci set wireless.${radio}.key=${KEY}; } || uci set wireless.${radio}.encryption=none
done

uci commit

# Wifi up
wifi

/etc/init.d/tor enable
/etc/init.d/tor start
/etc/init.d/firewall stop
/etc/init.d/firewall start
