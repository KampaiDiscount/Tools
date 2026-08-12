#!/usr/bin/env bash
set -Eeuo pipefail

# Build a flashable Raspberry Pi OS image that deploys this project on first boot.
# This runs on a Linux workstation, not on the Raspberry Pi.

IMAGE_URL="${IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_armhf_latest}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-raspios-sim800c-ngrok.img}"
APN="${APN:-internet}"
NETNS="${NETNS:-gprs}"
WORK_DIR=""
LOOP_DEVICE=""
ROOT_MOUNT=""
BOOT_MOUNT=""

usage() {
  cat <<EOF
Usage: sudo NGROK_AUTHTOKEN='token' $0 [output.img]

Environment overrides:
  IMAGE_URL       Raspberry Pi OS .img, .zip, or .xz URL
  OUTPUT_IMAGE    Output path (the positional argument takes precedence)
  APN             Mobile APN (default: internet)
  NETNS           Network namespace (default: gprs)
  NGROK_REGION    Optional ngrok region
EOF
}

cleanup() {
  set +e
  [[ -n "$BOOT_MOUNT" ]] && mountpoint -q "$BOOT_MOUNT" && umount "$BOOT_MOUNT"
  [[ -n "$ROOT_MOUNT" ]] && mountpoint -q "$ROOT_MOUNT" && umount "$ROOT_MOUNT"
  [[ -n "$LOOP_DEVICE" ]] && losetup -d "$LOOP_DEVICE"
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }
[[ ${EUID} -eq 0 ]] || { echo 'Run this builder with sudo.' >&2; exit 1; }
[[ -n ${NGROK_AUTHTOKEN:-} ]] || {
  echo 'NGROK_AUTHTOKEN must be supplied to provision the tunnel.' >&2
  exit 1
}
for command in curl file findmnt losetup mount mountpoint unzip xz; do
  command -v "$command" >/dev/null || {
    echo "Missing host command: $command" >&2
    echo 'On Debian/Ubuntu: sudo apt install curl file util-linux unzip xz-utils' >&2
    exit 1
  }
done

OUTPUT_IMAGE="${1:-$OUTPUT_IMAGE}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for source_file in deploy.sh connection-manager.sh; do
  [[ -f "$SCRIPT_DIR/$source_file" ]] || { echo "Missing $source_file" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d)"
download="$WORK_DIR/raspios-download"
echo "Downloading Raspberry Pi OS 32-bit Lite..."
curl --fail --location --show-error --progress-bar "$IMAGE_URL" -o "$download"

case "$(file --brief --mime-type "$download")" in
  application/zip)
    unzip -p "$download" >"$WORK_DIR/base.img"
    ;;
  application/x-xz)
    xz --decompress --stdout "$download" >"$WORK_DIR/base.img"
    ;;
  application/octet-stream)
    cp "$download" "$WORK_DIR/base.img"
    ;;
  *) echo "Unsupported image download format: $(file "$download")" >&2; exit 1 ;;
esac

install -m 0644 "$WORK_DIR/base.img" "$OUTPUT_IMAGE"
LOOP_DEVICE="$(losetup --find --show --partscan "$OUTPUT_IMAGE")"
ROOT_MOUNT="$WORK_DIR/root"
BOOT_MOUNT="$WORK_DIR/boot"
mkdir -p "$ROOT_MOUNT" "$BOOT_MOUNT"
mount "${LOOP_DEVICE}p2" "$ROOT_MOUNT"
mount "${LOOP_DEVICE}p1" "$BOOT_MOUNT"

install -d -m 0755 "$ROOT_MOUNT/opt/sim800c-ngrok" \
  "$ROOT_MOUNT/etc/sim800c-ngrok" \
  "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"
install -m 0755 "$SCRIPT_DIR/deploy.sh" "$ROOT_MOUNT/opt/sim800c-ngrok/deploy.sh"
install -m 0755 "$SCRIPT_DIR/connection-manager.sh" \
  "$ROOT_MOUNT/opt/sim800c-ngrok/connection-manager.sh"

# %q produces a safely sourceable Bash value, including for punctuation in tokens.
{
  printf 'NGROK_AUTHTOKEN=%q\n' "$NGROK_AUTHTOKEN"
  printf 'APN=%q\n' "$APN"
  printf 'NETNS=%q\n' "$NETNS"
  printf 'NGROK_REGION=%q\n' "${NGROK_REGION:-}"
} >"$ROOT_MOUNT/etc/sim800c-ngrok/deploy.env"
chmod 0600 "$ROOT_MOUNT/etc/sim800c-ngrok/deploy.env"

cat >"$ROOT_MOUNT/opt/sim800c-ngrok/firstboot.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/sim800c-ngrok/deploy.env
export NGROK_AUTHTOKEN APN NETNS NGROK_REGION
/opt/sim800c-ngrok/deploy.sh
touch /var/lib/sim800c-ngrok-deployed
systemctl disable sim800c-ngrok-firstboot.service
EOF
chmod 0755 "$ROOT_MOUNT/opt/sim800c-ngrok/firstboot.sh"

cat >"$ROOT_MOUNT/etc/systemd/system/sim800c-ngrok-firstboot.service" <<'EOF'
[Unit]
Description=Install SIM800C and ngrok configuration on first boot
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/sim800c-ngrok-deployed

[Service]
Type=oneshot
ExecStart=/opt/sim800c-ngrok/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -s ../sim800c-ngrok-firstboot.service \
  "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/sim800c-ngrok-firstboot.service"

# Raspberry Pi firmware recognizes this empty marker and enables SSH on first boot.
touch "$BOOT_MOUNT/ssh"
sync
echo "Built: $OUTPUT_IMAGE"
echo 'Flash it with Raspberry Pi Imager (Use custom) or dd, then boot with temporary Ethernet.'
echo 'The unattended deployment needs Internet access on first boot to install packages.'
