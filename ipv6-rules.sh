#!/bin/bash
# set -x


function addTor() {
  # ipset for Tor authorities https://metrics.torproject.org/rs.html#search/flag:authority%20
  local authlist=tor-authorities6
  ipset create -exist $authlist hash:ip family inet6
  for i in 2001:638:a000:4140::ffff:189 2001:678:558:1000::244 2001:67c:289c::9 2001:858:2:2:aabb:0:563b:1526 2607:8500:154::3 2610:1c0:0:5::131 2620:13:4000:6000::1000:118
  do
    ipset add -exist $authlist $i
  done

  # ipset for blocked ip addresses
  if [[ -s /var/tmp/ipset.$denylist ]]; then
    ipset restore -exist -f /var/tmp/ipset.$denylist
  else
    ipset create -exist $denylist hash:ip family inet6 timeout 1800
  fi

  # ipset for ip addresses where >1 Tor relay is running
  local multilist=tor-multi-relays6
  ipset create -exist $multilist hash:ip family inet6
  curl -s 'https://onionoo.torproject.org/summary?search=type:relay' -o - |\
  jq -cr '.relays[].a' | tr '\[\]" ,' ' ' | sort | uniq -c | grep -v ' 1 ' |\
  grep -F ':' | awk '{ print $3 }' |\
  while read i
  do
    ipset add -exist $multilist $i
  done

  # iptables
  ip6tables -P INPUT   DROP
  ip6tables -P OUTPUT  ACCEPT
  ip6tables -P FORWARD DROP
  
  # make sure NEW incoming tcp connections are SYN packets
  ip6tables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP -m comment --comment "$(date)"
  
  # allow local traffic
  ip6tables -A INPUT --in-interface lo                                -j ACCEPT
  ip6tables -A INPUT -p udp --source fe80::/10 --destination ff02::1  -j ACCEPT
 
  # the ruleset for an orport
  for orport in ${orports[*]}
  do
    # <= 11 new connection attempts within 5 min
    local name=$denylist-$orport
    ip6tables -A INPUT -p tcp --syn --destination $oraddr --destination-port $orport -m recent --name $name --set
    ip6tables -A INPUT -p tcp --syn --destination $oraddr --destination-port $orport -m recent --name $name --update --seconds 300 --hitcount 11 --rttl -j SET --add-set $denylist src --exist
    # trust Tor authorities
    ip6tables -A INPUT -p tcp       --destination $oraddr --destination-port $orport -m set   --match-set $authlist  src -j ACCEPT
    # 2 connections for a multirelay, 1 otherwise
    ip6tables -A INPUT -p tcp       --destination $oraddr --destination-port $orport -m set   --match-set $multilist src -m connlimit --connlimit-mask 128 --connlimit-above 2 -j SET --add-set $denylist src --exist
    ip6tables -A INPUT -p tcp       --destination $oraddr --destination-port $orport -m set ! --match-set $multilist src -m connlimit --connlimit-mask 128 --connlimit-above 1 -j SET --add-set $denylist src --exist

  done

  # drop any traffic from denylist
  ip6tables -A INPUT -p tcp -m set --match-set $denylist src -j DROP
  
  # allow passing packets to connect to ORport
  for orport in ${orports[*]}
  do
    ip6tables -A INPUT -p tcp --destination $oraddr --destination-port $orport -j ACCEPT
  done
  
  # trust already established connections - this is almost Tor traffic initiated by us
  ip6tables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID             -j DROP
  
  # ssh
  local port=$(grep -m 1 -E "^Port\s+[[:digit:]]+" /etc/ssh/sshd_config | awk '{ print $2 }')
  ip6tables -A INPUT -p tcp --destination-port ${port:-22} -j ACCEPT
 
  ## ratelimit ICMP echo, allow others
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -m limit --limit 6/s -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j DROP
  ip6tables -A INPUT -p ipv6-icmp                            -j ACCEPT
}


function addHetzner() {
  # https://wiki.hetzner.de/index.php/System_Monitor_(SysMon)
  local monlist=hetzner-monlist6
  ipset create -exist $monlist hash:ip family inet6
  getent ahostsv6 pool.sysmon.hetzner.com | awk '{ print $1 }' | sort -u |\
  while read i
  do
    ipset add -exist $monlist $i
  done
  ip6tables -A INPUT -m set --match-set $monlist src -j ACCEPT
}


function clearAll() {
  ip6tables -F
  ip6tables -X
  ip6tables -Z

  ip6tables -P INPUT   ACCEPT
  ip6tables -P OUTPUT  ACCEPT
  ip6tables -P FORWARD ACCEPT

  ipset save $denylist -f /var/tmp/ipset.$denylist.tmp &&\
  mv /var/tmp/ipset.$denylist.tmp /var/tmp/ipset.$denylist &&\
  ipset destroy $denylist
}


#######################################################################
export PATH=/usr/sbin:/usr/bin:/sbin/:/bin

# Tor
oraddr="2a01:4f9:3b:468e::13"
orports=(443 9001)

denylist=tor-ddos6

case $1 in
  start)  addTor
          addHetzner
          ;;
  stop)   clearAll 
          ;;
esac

