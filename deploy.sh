#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy a SIM800C PPP connection and an ngrok SSH tunnel in an isolated netns.
# Run as: sudo NGROK_AUTHTOKEN='...' ./deploy.sh

NETNS="${NETNS:-gprs}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/serial0}"
APN="${APN:-internet}"
NGROK_REGION="${NGROK_REGION:-}"
HOST_ADDR="169.254.200.1/30"
NS_ADDR="169.254.200.2/30"

[[ ${EUID} -eq 0 ]] || { echo "Run this script as root (sudo)." >&2; exit 1; }
[[ -n ${NGROK_AUTHTOKEN:-} ]] || {
  echo "NGROK_AUTHTOKEN must be supplied in the environment." >&2
  echo "Example: sudo NGROK_AUTHTOKEN='token' ./deploy.sh" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl iproute2 iputils-ping ppp openssh-server tar

# The Pi 2 is normally armv7/armhf. Keep detection explicit so failures are safe.
case "$(dpkg --print-architecture)" in
  armhf) NGROK_ARCH=arm ;;
  arm64) NGROK_ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl --fail --silent --show-error --location \
  "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz" \
  -o "$tmpdir/ngrok.tgz"
tar -xzf "$tmpdir/ngrok.tgz" -C "$tmpdir" ngrok
install -o root -g root -m 0755 "$tmpdir/ngrok" /usr/local/bin/ngrok

# Serial console must not own the HAT UART. Enabling UART is harmless when the
# setting is already present; disabling the console takes effect after reboot.
if command -v raspi-config >/dev/null; then
  raspi-config nonint do_serial_cons 1 || true
  raspi-config nonint do_serial 0 || true
fi
if ! grep -q '^enable_uart=1' /boot/config.txt 2>/dev/null; then
  printf '\nenable_uart=1\n' >>/boot/config.txt
fi
systemctl disable --now serial-getty@serial0.service 2>/dev/null || true

install -d -m 0755 /etc/chatscripts /etc/ppp/peers /etc/ngrok /etc/netns/"$NETNS"
cat >/etc/chatscripts/sim800c <<EOF
ABORT 'BUSY'
ABORT 'NO CARRIER'
ABORT 'ERROR'
TIMEOUT 20
'' AT
OK ATE0
OK AT+CPIN?
OK AT+CGDCONT=1,"IP","${APN}"
OK ATD*99***1#
CONNECT ''
EOF

cat >/etc/ppp/peers/sim800c <<EOF
${SERIAL_DEVICE} 115200
connect "/usr/sbin/chat -v -f /etc/chatscripts/sim800c"
noauth
defaultroute
usepeerdns
persist
holdoff 10
maxfail 0
hide-password
novj
novjccomp
noipdefault
ipcp-accept-local
ipcp-accept-remote
EOF

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"/etc/netns/${NETNS}/resolv.conf"

# Store the supplied secret root-only; never place it in this repository.
umask 077
region_line=""
[[ -n "$NGROK_REGION" ]] && region_line="  region: ${NGROK_REGION}"
cat >/etc/ngrok/ngrok.yml <<EOF
version: "3"
agent:
  authtoken: ${NGROK_AUTHTOKEN}
${region_line}
tunnels:
  ssh:
    proto: tcp
    addr: 169.254.200.1:22
EOF
chmod 0600 /etc/ngrok/ngrok.yml

cat >/usr/local/sbin/gprs-netns-up <<EOF
#!/bin/sh
set -eu
ip netns add ${NETNS} 2>/dev/null || true
ip link del gprs-host 2>/dev/null || true
ip link add gprs-host type veth peer name gprs-ns
ip link set gprs-ns netns ${NETNS}
ip addr add ${HOST_ADDR} dev gprs-host
ip link set gprs-host up
ip netns exec ${NETNS} ip addr add ${NS_ADDR} dev gprs-ns
ip netns exec ${NETNS} ip link set lo up
ip netns exec ${NETNS} ip link set gprs-ns up
EOF
chmod 0755 /usr/local/sbin/gprs-netns-up

# Install the autonomous health checker shipped beside this deployment script.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/connection-manager.sh" ]] || {
  echo "Missing $SCRIPT_DIR/connection-manager.sh; extract the complete package." >&2
  exit 1
}
install -o root -g root -m 0755 "$SCRIPT_DIR/connection-manager.sh" \
  /usr/local/sbin/gprs-connection-manager

cat >/etc/systemd/system/gprs-netns.service <<EOF
[Unit]
Description=Network namespace for SIM800C data
Before=gprs-ppp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gprs-netns-up
ExecStop=-/usr/sbin/ip netns delete ${NETNS}

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gprs-ppp.service <<EOF
[Unit]
Description=SIM800C PPP connection in isolated namespace
Requires=gprs-netns.service
After=gprs-netns.service dev-serial0.device

[Service]
Type=simple
ExecStart=/usr/sbin/ip netns exec ${NETNS} /usr/sbin/pppd nodetach call sim800c
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/ngrok-gprs.service <<EOF
[Unit]
Description=ngrok SSH tunnel over SIM800C
Requires=gprs-ppp.service
After=gprs-ppp.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'until /usr/sbin/ip netns exec ${NETNS} ip link show ppp0 >/dev/null 2>&1; do sleep 2; done'
ExecStart=/usr/sbin/ip netns exec ${NETNS} /usr/local/bin/ngrok start ssh --config /etc/ngrok/ngrok.yml --log stdout
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gprs-connection-manager.service <<EOF
[Unit]
Description=Check and recover SIM800C PPP and ngrok
After=gprs-ppp.service ngrok-gprs.service

[Service]
Type=oneshot
Environment=NETNS=${NETNS}
ExecStart=/usr/local/sbin/gprs-connection-manager check
EOF

cat >/etc/systemd/system/gprs-connection-manager.timer <<EOF
[Unit]
Description=Periodically monitor SIM800C PPP and ngrok

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
RandomizedDelaySec=10
Persistent=true
Unit=gprs-connection-manager.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ssh gprs-netns.service gprs-ppp.service ngrok-gprs.service \
  gprs-connection-manager.timer
systemctl restart ssh gprs-netns.service
# Do not block deployment while a modem is registering or UART awaits a reboot.
systemctl restart --no-block gprs-ppp.service ngrok-gprs.service
systemctl restart gprs-connection-manager.timer

echo "Deployment complete. A reboot is recommended if UART settings changed."
echo "Inspect with: systemctl status gprs-ppp ngrok-gprs"
