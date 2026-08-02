# Raspberry Pi SIM800C isolated ngrok deployment

This repository configures a Raspberry Pi 2 running 32-bit Raspberry Pi OS to:

* connect a Waveshare SIM800C GSM/GPRS HAT through PPP;
* keep the cellular default route inside the `gprs` network namespace, leaving
  the host's normal networking and default route unchanged; and
* expose the host SSH server through an ngrok TCP endpoint carried over GPRS;
  and
* autonomously health-check and recover both PPP and ngrok once per minute.

> **Security:** The token supplied in the original request is a credential and
> is deliberately not committed here. Revoke/rotate any token that has been
> shared in chat, then pass the replacement only at deployment time.

## Hardware preparation

1. Insert the activated SIM and attach the GSM antenna before powering the HAT.
2. Set the HAT to use the Raspberry Pi UART (not its USB serial connection), and
   verify that `/dev/serial0` exists.
3. Make sure the local Vodacom network still provides 2G/GPRS coverage. The
   SIM800C cannot use 3G, LTE, or 5G.

The default APN is `internet`, commonly used by Vodacom South Africa. Override
it if the SIM's provider or private APN requires another value.

## Deploy

```bash
chmod +x deploy.sh
sudo NGROK_AUTHTOKEN='REPLACEMENT_TOKEN' APN='internet' ./deploy.sh
```

Optional variables are `SERIAL_DEVICE` (default `/dev/serial0`), `NETNS`
(default `gprs`), and `NGROK_REGION`. The script installs dependencies and the
appropriate 32-bit ARM ngrok binary, disables the serial console, writes
root-only ngrok configuration, and enables all services at boot.

## Build a ready-to-flash image

On a Debian/Ubuntu Linux workstation, the image builder downloads the current
official Raspberry Pi OS Lite 32-bit image, injects these scripts, enables SSH,
and schedules an unattended deployment on first boot:

```bash
sudo apt install curl file util-linux unzip xz-utils
sudo NGROK_AUTHTOKEN='REPLACEMENT_TOKEN' APN='internet' \
  ./build-image.sh raspios-sim800c-ngrok.img
```

Flash `raspios-sim800c-ngrok.img` with Raspberry Pi Imager's **Use custom**
option, Balena Etcher, or `dd`. On its first boot, connect the Pi temporarily by
Ethernet so it can install Debian packages and ngrok; no terminal interaction
on the Pi is required. The first-boot unit disables itself only after a
successful deployment, so loss of connectivity causes another attempt on the
next boot.

This is a provisioned image rather than a fully offline package cache: the
initial Ethernet/Wi-Fi connection is required because Raspberry Pi OS package
versions change and are installed from its configured repositories.

The ngrok credential is stored root-only inside the customized image. Treat the
image as sensitive, do not publish it, and rotate the credential if the image
is lost or shared. Raspberry Pi Imager can also be used before flashing to set
the hostname, user password, Wi-Fi, locale, and SSH public key.

Reboot after the first installation so UART configuration is guaranteed to be
active:

```bash
sudo reboot
```

## Verify and troubleshoot

```bash
sudo systemctl status gprs-netns gprs-ppp ngrok-gprs
sudo systemctl status gprs-connection-manager.timer
sudo journalctl -u gprs-ppp -u ngrok-gprs -f
sudo journalctl -u gprs-connection-manager
sudo ip netns exec gprs ip address show ppp0
sudo ip netns exec gprs ping -c 3 1.1.1.1
sudo gprs-connection-manager status
```

The ngrok public TCP address appears in the `ngrok-gprs` journal and in the
ngrok dashboard. Connect with `ssh -p PORT user@NGROK_HOST`. Free ngrok plans
may assign a new host or port whenever the service reconnects.

The veth address `169.254.200.1:22` lets ngrok inside the namespace reach SSH
on the host. It does not NAT the host's ordinary traffic through cellular, so
normal networking remains independent.

## Autonomous connection manager

The systemd timer runs a health check every minute. It checks that the PPP
service is active, `ppp0` has a default route in the namespace, an Internet
address responds through `ppp0`, and ngrok's local API reports a published
tunnel.

To avoid restart loops during brief GPRS packet loss, recovery occurs after
three consecutive failures. A cellular failure restarts PPP and ngrok; an
ngrok-only failure restarts only ngrok. systemd also restarts either daemon if
its process exits between health checks. Manual controls are:

```bash
sudo gprs-connection-manager status
sudo gprs-connection-manager check
sudo gprs-connection-manager restart
```

If PPP repeatedly reports `NO CARRIER`, confirm signal and 2G availability,
SIM PIN state, antenna attachment, UART jumpers, and the APN. A PIN-locked SIM
must be unlocked in a phone first (or the chat script must be adapted to enter
its PIN).
