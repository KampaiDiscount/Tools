#!/usr/bin/env bash
set -Eeuo pipefail

# Health monitor/recovery helper installed by deploy.sh.
NETNS="${NETNS:-gprs}"
PPP_SERVICE="${PPP_SERVICE:-gprs-ppp.service}"
NGROK_SERVICE="${NGROK_SERVICE:-ngrok-gprs.service}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
STATE_DIR="${STATE_DIR:-/run/gprs-connection-manager}"
PING_TARGET="${PING_TARGET:-1.1.1.1}"

log() { logger -t gprs-connection-manager -- "$*" 2>/dev/null || true; echo "$*"; }
ns() { ip netns exec "$NETNS" "$@"; }

ppp_healthy() {
  systemctl is-active --quiet "$PPP_SERVICE" &&
    ns ip link show ppp0 >/dev/null 2>&1 &&
    ns ip route show default | grep -q 'dev ppp0' &&
    ns ping -I ppp0 -c 1 -W 10 "$PING_TARGET" >/dev/null 2>&1
}

ngrok_healthy() {
  systemctl is-active --quiet "$NGROK_SERVICE" &&
    ns curl --fail --silent --max-time 5 http://127.0.0.1:4040/api/tunnels \
      | grep -q '"public_url"'
}

counter_get() { [[ -f "$1" ]] && cat "$1" || printf '0'; }
counter_reset() { printf '0\n' >"$1"; }
counter_fail() {
  local file=$1 count
  count="$(counter_get "$file")"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  printf '%s\n' "$count" >"$file"
  printf '%s' "$count"
}

status() {
  if ppp_healthy; then echo 'Cellular PPP: healthy'; else echo 'Cellular PPP: unhealthy'; fi
  if ngrok_healthy; then echo 'ngrok tunnel: healthy'; else echo 'ngrok tunnel: unhealthy'; fi
  echo "PPP failures: $(counter_get "$STATE_DIR/ppp.failures")"
  echo "ngrok failures: $(counter_get "$STATE_DIR/ngrok.failures")"
}

check() {
  local failures
  if ppp_healthy; then
    counter_reset "$STATE_DIR/ppp.failures"
  else
    failures="$(counter_fail "$STATE_DIR/ppp.failures")"
    log "PPP health check failed (${failures}/${FAILURE_THRESHOLD})"
    if (( failures >= FAILURE_THRESHOLD )); then
      log "Restarting ${PPP_SERVICE}; ngrok will wait for ppp0"
      systemctl restart "$PPP_SERVICE"
      systemctl restart "$NGROK_SERVICE"
      counter_reset "$STATE_DIR/ppp.failures"
      counter_reset "$STATE_DIR/ngrok.failures"
    fi
    return
  fi

  if ngrok_healthy; then
    counter_reset "$STATE_DIR/ngrok.failures"
  else
    failures="$(counter_fail "$STATE_DIR/ngrok.failures")"
    log "ngrok health check failed (${failures}/${FAILURE_THRESHOLD})"
    if (( failures >= FAILURE_THRESHOLD )); then
      log "Restarting ${NGROK_SERVICE}"
      systemctl restart "$NGROK_SERVICE"
      counter_reset "$STATE_DIR/ngrok.failures"
    fi
  fi
}

[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
mkdir -p "$STATE_DIR"

case "${1:-check}" in
  check) check ;;
  status) status ;;
  restart)
    log 'Manual full connection restart requested'
    systemctl restart "$PPP_SERVICE"
    systemctl restart "$NGROK_SERVICE"
    ;;
  *) echo "Usage: $0 [check|status|restart]" >&2; exit 2 ;;
esac
