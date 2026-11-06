#!/bin/sh
# 本地模拟，不连接网络。
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/cf-rollback-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/rb"
rb="$tmp/rb"; TMP="$tmp"; CF_ZONE_ID=test; DRY=0
log(){ :; }
cf(){
 case "$1" in
 POST) jq -n --arg id "id$created_index" '{success:true,result:{id:$id}}' > "$TMP/cf";;
 DELETE) printf '%s\n' "$2" >> "$TMP/deletes";;
 esac
}
# Extract only the function declarations under test.
eval "$(sed -n '/^rollback(){/p; /^created_index=0$/p; /^deleted_index=0$/p; /^mutate(){/p' "$project/start.sh")"
mutate first POST /zones/test/dns_records '{}' created
mutate second POST /zones/test/dns_records '{}' created
[ -f "$rb/created.1" ] && [ -f "$rb/created.2" ]
rollback
[ "$(wc -l < "$TMP/deletes" | tr -d ' ')" = 2 ]
printf '%s\n' '本地回滚测试通过：两条创建记录均被独立撤销。'
