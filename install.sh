#!/bin/sh
set -eu
DEST=${1:-/root/openwrt-cf-domain-speed-sync}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v apk >/dev/null 2>&1; then
  apk update
  apk add curl jq ca-bundle coreutils-timeout openssl-util netcat
elif command -v opkg >/dev/null 2>&1; then
  opkg update
  opkg install curl jq ca-bundle coreutils-timeout openssl-util netcat
else
  echo '未找到 apk 或 opkg，请在 OpenWrt 上手动安装 curl 和 jq。' >&2
  exit 1
fi
mkdir -p "$DEST"
if [ "$HERE/start.sh" != "$DEST/start.sh" ]; then
  cp "$HERE/start.sh" "$DEST/start.sh"
fi
if [ ! -e "$DEST/config.conf" ]; then
  cp "$HERE/config.conf" "$DEST/config.conf"
else
  echo "保留现有配置：$DEST/config.conf"
fi
chmod 700 "$DEST/start.sh"
chmod 600 "$DEST/config.conf"
echo "安装完成：$DEST"
echo "请编辑 $DEST/config.conf，填写 Cloudflare 凭据，然后运行："
echo "$DEST/start.sh --dry-run"
