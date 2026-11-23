#!/bin/sh
# Install our lab agent on this machine, once, as root:
#
#   curl -fsSL https://<platform>/api/simulators/agent/releases/install.sh | sudo sh -s -- --code ABCD-EFGH --platform https://<platform>
#
# A product's own agent API (KijiCyber's cyber computers): add --api /api/plugins/kijicyber/agent/v1.
#
# It makes the unprivileged user wbsim (no password, no sudo; its user services
# keep running without a login), installs the agent (checked against the
# platform's sha256), runs it as wbsim under systemd, and enrols it with the
# one-time code from the Lab machines page. After this, root is never used.
#
# Run again without --code on a machine that already has the agent: it only refreshes the systemd unit and the guard
# from this release (e.g. RestartPreventExitStatus=4) and reloads systemd. No new code, the agent keeps its key.
set -eu
CODE= PLATFORM= API=
while [ $# -gt 0 ]; do
  case "$1" in
    --code) CODE=$2; shift 2 ;;
    --platform) PLATFORM=${2%/}; shift 2 ;;
    --api) API=${2%/}; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
if [ -z "$CODE" ] && [ -f /var/lib/weaverbird-agent/config.json ]; then
  # Already installed and enrolled: refresh the unit and the guard only.
  [ -n "$PLATFORM" ] || { echo "give --platform" >&2; exit 2; }
  case "$PLATFORM" in https://*) ;; *) echo "--platform must be https://" >&2; exit 2 ;; esac
  REL="$PLATFORM/api/simulators/agent/releases"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$REL/weaverbird-agent.service" -o "$TMP/weaverbird-agent.service"
  curl -fsSL "$REL/guard.sh" -o "$TMP/guard.sh"
  grep -q '^ExecStart=' "$TMP/weaverbird-agent.service" || { echo "the unit did not download right: nothing changed" >&2; exit 1; }
  install -d -m 0755 -o root -g root /usr/local/lib/weaverbird-agent
  install -m 0755 -o root -g root "$TMP/guard.sh" /usr/local/lib/weaverbird-agent/guard.sh
  install -m 0644 -o root -g root "$TMP/weaverbird-agent.service" /etc/systemd/system/weaverbird-agent.service
  systemctl daemon-reload
  echo "Refreshed the agent's unit; the agent keeps running with its key."
  exit 0
fi
[ -n "$CODE" ] && [ -n "$PLATFORM" ] || { echo "give --code and --platform" >&2; exit 2; }
case "$PLATFORM" in https://*) ;; *) echo "--platform must be https://" >&2; exit 2 ;; esac
case "$API" in ''|/api/*) ;; *) echo "--api must be a path like /api/plugins/kijicyber/agent/v1" >&2; exit 2 ;; esac
case "$API" in *[!A-Za-z0-9/_.-]*) echo "--api has characters a path does not" >&2; exit 2 ;; esac
command -v systemctl >/dev/null || { echo "systemd is needed" >&2; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

REL="$PLATFORM/api/simulators/agent/releases"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$REL/weaverbird-agent-linux-$ARCH" -o "$TMP/weaverbird-agent"
curl -fsSL "$REL/weaverbird-agent-linux-$ARCH.sha256" -o "$TMP/sum"
( cd "$TMP" && echo "$(cut -d' ' -f1 sum)  weaverbird-agent" | sha256sum -c - >/dev/null ) \
  || { echo "the agent did not match its sha256: not installed" >&2; exit 1; }
curl -fsSL "$REL/weaverbird-agent.service" -o "$TMP/weaverbird-agent.service"
curl -fsSL "$REL/guard.sh" -o "$TMP/guard.sh"
chmod 0755 "$TMP/weaverbird-agent"
VERSION=$("$TMP/weaverbird-agent" --version)
case "$VERSION" in ''|*[!0-9A-Za-z.+-]*) echo "the agent did not say its version" >&2; exit 1 ;; esac

# Option A: the restricted user, set up here, never given sudo.
id wbsim >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin --comment "Weaverbird lab agent" wbsim
passwd -l wbsim >/dev/null 2>&1 || true
loginctl enable-linger wbsim

# The agent updates itself: its builds live in its own directory (bin/<version>,
# bin/current in use, bin/prev the one before); the guard that rolls a failed
# update back stays root-owned. /usr/local/bin/weaverbird-agent is the command
# for people, pointing at the build in use.
install -d -m 0700 -o wbsim -g wbsim /var/lib/weaverbird-agent
install -d -m 0755 -o wbsim -g wbsim /var/lib/weaverbird-agent/bin "/var/lib/weaverbird-agent/bin/$VERSION"
install -m 0755 -o wbsim -g wbsim "$TMP/weaverbird-agent" "/var/lib/weaverbird-agent/bin/$VERSION/weaverbird-agent"
runuser -u wbsim -- ln -sfn "/var/lib/weaverbird-agent/bin/$VERSION/weaverbird-agent" /var/lib/weaverbird-agent/bin/current
ln -sfn /var/lib/weaverbird-agent/bin/current /usr/local/bin/weaverbird-agent
install -d -m 0755 -o root -g root /usr/local/lib/weaverbird-agent
install -m 0755 -o root -g root "$TMP/guard.sh" /usr/local/lib/weaverbird-agent/guard.sh
install -m 0644 -o root -g root "$TMP/weaverbird-agent.service" /etc/systemd/system/weaverbird-agent.service

# Enrol as wbsim: its key is made and kept by that user only.
if ! runuser -u wbsim -- env WEAVERBIRD_AGENT_DIR=/var/lib/weaverbird-agent \
    /usr/local/bin/weaverbird-agent enrol "$CODE" --platform "$PLATFORM" ${API:+--api "$API"}; then
  echo "enrolment failed: get a new code and run this again" >&2
  exit 1
fi
systemctl daemon-reload
systemctl enable --now weaverbird-agent.service
echo "Installed. 'systemctl status weaverbird-agent' shows it; 'journalctl -u weaverbird-agent' its log."
