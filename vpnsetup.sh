#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu and Debian.
# Works on any dedicated server or virtual private server (VPS) except OpenVZ.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!
#
# Script Credit to
# https://github.com/hwdsl2/setup-ipsec-vpn
# =====================================================
# THIS SCRIPT CUSTOMADE For GLOBALSSH.NET
# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these special characters within values: \ " '

YOUR_IPSEC_PSK=''
YOUR_USERNAME=''
YOUR_PASSWORD=''

# =====================================================
SYS_DT=$(date +%F-%T | tr ':' '_')

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }
bigecho() { echo; echo "## $1"; echo; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

vpnsetup() {

os_type=$(lsb_release -si 2>/dev/null)
if [ -z "$os_type" ]; then
  [ -f /etc/os-release  ] && os_type=$(. /etc/os-release  && printf '%s' "$ID")
  [ -f /etc/lsb-release ] && os_type=$(. /etc/lsb-release && printf '%s' "$DISTRIB_ID")
fi
if ! printf '%s' "$os_type" | head -n 1 | grep -qiF -e ubuntu -e debian -e raspbian; then
  echo "Error: This script only supports Ubuntu and Debian." >&2
  echo "For CentOS/RHEL, use https://git.io/vpnsetup-centos" >&2
  exit 1
fi

if [ "$(sed 's/\..*//' /etc/debian_version)" = "7" ]; then
  exiterr "Debian 7 is not supported."
fi

if [ -f /proc/user_beancounters ]; then
  exiterr "OpenVZ VPS is not supported. Try OpenVPN: github.com/Nyr/openvpn-install"
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

def_iface=$(route 2>/dev/null | grep -m 1 '^default' | grep -o '[^ ]*$')
[ -z "$def_iface" ] && def_iface=$(ip -4 route list 0/0 2>/dev/null | grep -m 1 -Po '(?<=dev )(\S+)')
def_state=$(cat "/sys/class/net/$def_iface/operstate" 2>/dev/null)
if [ -n "$def_state" ] && [ "$def_state" != "down" ]; then
  if ! uname -m | grep -qi -e '^arm' -e '^aarch64'; then
    case "$def_iface" in
      wl*)
        exiterr "Wireless interface '$def_iface' detected. DO NOT run this script on your PC or Mac!"
        ;;
    esac
  fi
  NET_IFACE="$def_iface"
else
  eth0_state=$(cat "/sys/class/net/eth0/operstate" 2>/dev/null)
  if [ -z "$eth0_state" ] || [ "$eth0_state" = "down" ]; then
    exiterr "Could not detect the default network interface."
  fi
  NET_IFACE=eth0
fi

[ -n "$YOUR_IPSEC_PSK" ] && VPN_IPSEC_PSK="$YOUR_IPSEC_PSK"
[ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
[ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"

if [ -z "$VPN_IPSEC_PSK" ] && [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
  bigecho "VPN credentials not set by user. Generating random PSK and password..."
  VPN_IPSEC_PSK=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 20)
  VPN_USER=vpnuser
  VPN_PASSWORD=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)
fi

if [ -z "$VPN_IPSEC_PSK" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
  exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
fi

if printf '%s' "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" | LC_ALL=C grep -q '[^ -~]\+'; then
  exiterr "VPN credentials must not contain non-ASCII characters."
fi

case "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" in
  *[\\\"\']*)
    exiterr "VPN credentials must not contain these special characters: \\ \" '"
    ;;
esac

if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
  || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; } then
  exiterr "The DNS server specified is invalid."
fi

if [ -x /sbin/iptables ] && ! iptables -nL INPUT >/dev/null 2>&1; then
  exiterr "IPTables check failed. Reboot and re-run this script."
fi

bigecho "VPN setup in progress... Please be patient."

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exit 1

count=0
APT_LK=/var/lib/apt/lists/lock
PKG_LK=/var/lib/dpkg/lock
while fuser "$APT_LK" "$PKG_LK" >/dev/null 2>&1 \
  || lsof "$APT_LK" >/dev/null 2>&1 || lsof "$PKG_LK" >/dev/null 2>&1; do
  [ "$count" = "0" ] && bigecho "Waiting for apt to be available..."
  [ "$count" -ge "60" ] && exiterr "Could not get apt/dpkg lock."
  count=$((count+1))
  printf '%s' '.'
  sleep 3
done

bigecho "Populating apt-get cache..."

export DEBIAN_FRONTEND=noninteractive
apt-get -yq update || exiterr "'apt-get update' failed."

bigecho "Installing packages required for setup..."

apt-get -yq install wget dnsutils \
  iptables iproute2 gawk grep sed net-tools || exiterr2

bigecho "Trying to auto discover IP of this server..."

cat <<'EOF'
In case the script hangs here for more than a few minutes,
press Ctrl-C to abort. Then edit it and manually enter IP.
EOF

# In case auto IP discovery fails, enter server's public IP here.
PUBLIC_IP=${VPN_PUBLIC_IP:-''}

[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)

check_ip "$PUBLIC_IP" || PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
check_ip "$PUBLIC_IP" || exiterr "Cannot detect this server's public IP. Edit the script and manually enter it."

bigecho "Installing packages required for the VPN..."

apt-get -yq install libnss3-dev libnspr4-dev pkg-config \
  libpam0g-dev libcap-ng-dev libcap-ng-utils libselinux1-dev \
  libcurl4-nss-dev flex bison gcc make libnss3-tools \
  libevent-dev libsystemd-dev ppp xl2tpd || exiterr2

bigecho "Installing Fail2Ban to protect SSH..."

apt-get -yq install fail2ban || exiterr2

bigecho "Compiling and installing Libreswan..."

SWAN_VER=4.2
swan_file="libreswan-$SWAN_VER.tar.gz"
swan_url1="https://github.com/libreswan/libreswan/archive/v$SWAN_VER.tar.gz"
swan_url2="https://download.libreswan.org/$swan_file"
if ! { wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url2"; }; then
  exit 1
fi
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
tar xzf "$swan_file" && /bin/rm -f "$swan_file"
cd "libreswan-$SWAN_VER" || exit 1
#sed -i 's/ sysv )/ sysvinit )/' programs/setup/setup.in
cat > Makefile.inc.local <<'EOF'
WERROR_CFLAGS=-w
USE_DNSSEC=false
USE_DH2=true
USE_NSS_KDF=false
FINALNSSDIR=/etc/ipsec.d
EOF
if ! grep -qs 'VERSION_CODENAME=' /etc/os-release; then
cat >> Makefile.inc.local <<'EOF'
USE_DH31=false
USE_NSS_AVA_COPY=true
USE_NSS_IPSEC_PROFILE=false
USE_GLIBC_KERN_FLIP_HEADERS=true
EOF
fi
if ! grep -qs IFLA_XFRM_LINK /usr/include/linux/if_link.h; then
  echo "USE_XFRM_INTERFACE_IFLA_HEADER = true" >> Makefile.inc.local
fi
#if [ "$(packaging/utils/lswan_detect.sh init)" = "systemd" ]; then
#  apt-get -yq install libsystemd-dev || exiterr2
#fi
NPROCS=$(grep -c ^processor /proc/cpuinfo)
[ -z "$NPROCS" ] && NPROCS=1
make "-j$((NPROCS+1))" -s base && make -s install-base

cd /opt/src || exit 1
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
if ! /usr/local/sbin/ipsec --version 2>/dev/null | grep -qF "$SWAN_VER"; then
  exiterr "Libreswan $SWAN_VER failed to build."
fi

bigecho "Creating VPN configuration..."

L2TP_NET=${VPN_L2TP_NET:-'192.168.42.0/24'}
L2TP_LOCAL=${VPN_L2TP_LOCAL:-'192.168.42.1'}
L2TP_POOL=${VPN_L2TP_POOL:-'192.168.42.10-192.168.42.250'}
XAUTH_NET=${VPN_XAUTH_NET:-'192.168.43.0/24'}
XAUTH_POOL=${VPN_XAUTH_POOL:-'192.168.43.10-192.168.43.250'}
DNS_SRV1=${VPN_DNS_SRV1:-'8.8.8.8'}
DNS_SRV2=${VPN_DNS_SRV2:-'8.8.4.4'}
DNS_SRVS="\"$DNS_SRV1 $DNS_SRV2\""
[ -n "$VPN_DNS_SRV1" ] && [ -z "$VPN_DNS_SRV2" ] && DNS_SRVS="$DNS_SRV1"

# Create IPsec config
conf_bk "/etc/ipsec.conf"
cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
  virtual-private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!$L2TP_NET,%v4:!$XAUTH_NET
  protostack=netkey
  interfaces=%defaultroute
  uniqueids=no

conn shared
  left=%defaultroute
  leftid=$PUBLIC_IP
  right=%any
  encapsulation=yes
  authby=secret
  pfs=no
  rekey=no
  keyingtries=5
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  ikev2=never
  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024
  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes256-sha2_512,aes128-sha2,aes256-sha2
  ikelifetime=24h
  salifetime=24h
  sha2-truncbug=no

conn l2tp-psk
  auto=add
  leftprotoport=17/1701
  rightprotoport=17/%any
  type=transport
  phase2=esp
  also=shared

conn xauth-psk
  auto=add
  leftsubnet=0.0.0.0/0
  rightaddresspool=$XAUTH_POOL
  modecfgdns=$DNS_SRVS
  leftxauthserver=yes
  rightxauthclient=yes
  leftmodecfgserver=yes
  rightmodecfgclient=yes
  modecfgpull=yes
  xauthby=file
  fragmentation=yes
  cisco-unity=yes
  also=shared

include /etc/ipsec.d/*.conf
EOF

if uname -m | grep -qi '^arm'; then
  if ! modprobe -q sha512; then
    sed -i '/phase2alg/s/,aes256-sha2_512//' /etc/ipsec.conf
  fi
fi

# Specify IPsec PSK
conf_bk "/etc/ipsec.secrets"
cat > /etc/ipsec.secrets <<EOF
%any  %any  : PSK "$VPN_IPSEC_PSK"
EOF

# Create xl2tpd config
conf_bk "/etc/xl2tpd/xl2tpd.conf"
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = $L2TP_POOL
local ip = $L2TP_LOCAL
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Set xl2tpd options
conf_bk "/etc/ppp/options.xl2tpd"
cat > /etc/ppp/options.xl2tpd <<EOF
+mschap-v2
ipcp-accept-local
ipcp-accept-remote
noccp
auth
mtu 1200
mru 1200
proxyarp
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
ms-dns $DNS_SRV1
EOF

if [ -z "$VPN_DNS_SRV1" ] || [ -n "$VPN_DNS_SRV2" ]; then
cat >> /etc/ppp/options.xl2tpd <<EOF
ms-dns $DNS_SRV2
EOF
fi

# Create VPN credentials
conf_bk "/etc/ppp/chap-secrets"
cat > /etc/ppp/chap-secrets <<EOF
"$VPN_USER" l2tpd "$VPN_PASSWORD" *
EOF

conf_bk "/etc/ipsec.d/passwd"
VPN_PASSWORD_ENC=$(openssl passwd -1 "$VPN_PASSWORD")
cat > /etc/ipsec.d/passwd <<EOF
$VPN_USER:$VPN_PASSWORD_ENC:xauth-psk
EOF

bigecho "Updating sysctl settings..."

if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then
  conf_bk "/etc/sysctl.conf"
  if [ "$(getconf LONG_BIT)" = "64" ]; then
    SHM_MAX=68719476736
    SHM_ALL=4294967296
  else
    SHM_MAX=4294967295
    SHM_ALL=268435456
  fi
cat >> /etc/sysctl.conf <<EOF

# FRR L2TP SYSCTL
kernel.msgmnb = 65536
kernel.msgmax = 65536

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.$NET_IFACE.send_redirects = 0
net.ipv4.conf.$NET_IFACE.rp_filter = 0

EOF
fi

bigecho "Updating IPTables rules..."
  iptables -I INPUT 1 -p udp --dport 1701 -m policy --dir in --pol none -j DROP
  iptables -I INPUT 2 -m conntrack --ctstate INVALID -j DROP
  iptables -I INPUT 3 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I INPUT 4 -p udp -m multiport --dports 500,4500 -j ACCEPT
  iptables -I INPUT 5 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
  iptables -I INPUT 6 -p udp --dport 1701 -j DROP
  iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
  iptables -I FORWARD 2 -i "$NET_IFACE" -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 3 -i ppp+ -o "$NET_IFACE" -j ACCEPT
  iptables -I FORWARD 4 -i ppp+ -o ppp+ -s "$L2TP_NET" -d "$L2TP_NET" -j ACCEPT
  iptables -I FORWARD 5 -i "$NET_IFACE" -d "$XAUTH_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 6 -s "$XAUTH_NET" -o "$NET_IFACE" -j ACCEPT
  # Uncomment to disallow traffic between VPN clients
  # iptables -I FORWARD 2 -i ppp+ -o ppp+ -s "$L2TP_NET" -d "$L2TP_NET" -j DROP
  # iptables -I FORWARD 3 -s "$XAUTH_NET" -d "$XAUTH_NET" -j DROP
  iptables -A FORWARD -j DROP
  iptables -t nat -I POSTROUTING -s "$XAUTH_NET" -o "$NET_IFACE" -m policy --dir out --pol none -j MASQUERADE
  iptables -t nat -I POSTROUTING -s "$L2TP_NET" -o "$NET_IFACE" -j MASQUERADE
  iptables-save > /etc/iptables/rules.v4
  { crontab -l 2>/dev/null; echo "@reboot sleep 15 && service ipsec restart > /dev/null 2>&1" ; } | crontab -
  { crontab -l 2>/dev/null; echo "@reboot sleep 15 && service xl2tpd restart > /dev/null 2>&1" ; } | crontab -
bigecho "Starting services..."
sysctl -e -q -p
chmod 600 /etc/ipsec.secrets* /etc/ppp/chap-secrets* /etc/ipsec.d/passwd*
mkdir -p /run/pluto
service fail2ban restart 2>/dev/null
service ipsec restart 2>/dev/null
service xl2tpd restart 2>/dev/null
systemctl enable ipsec
}
## Defer setup until we have the complete script
vpnsetup "$@"

exit 0
