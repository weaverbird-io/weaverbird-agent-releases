#!/bin/sh
# Install our lab agent on this machine, once, as root:
#
#   curl -fsSL https://<platform>/api/simulators/agent/releases/install.sh | sudo sh -s -- --code ABCD-EFGH --platform https://<platform>
#
# It makes the unprivileged user wbsim (no password, no sudo; its user services
# keep running without a login), installs the agent (checked against the
# platform's sha256), runs it as wbsim under systemd, and enrols it with the
# one-time code from the Lab machines page. After this, root is never used.
set -eu
CODE= PLATFORM=
while [ $# -gt 0 ]; do
  case "$1" in
    --code) CODE=$2; shift 2 ;;
    --platform) PLATFORM=${2%/}; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -n "$CODE" ] && [ -n "$PLATFORM" ] || { echo "give --code and --platform" >&2; exit 2; }
case "$PLATFORM" in https://*) ;; *) echo "--platform must be https://" >&2; exit 2 ;; esac
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
    /usr/local/bin/weaverbird-agent enrol "$CODE" --platform "$PLATFORM"; then
  echo "enrolment failed: get a new code on the Lab machines page and run this again" >&2
  exit 1
fi
systemctl daemon-reload
systemctl enable --now weaverbird-agent.service
echo "Installed. 'systemctl status weaverbird-agent' shows it; 'journalctl -u weaverbird-agent' its log."
