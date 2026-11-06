#!/bin/sh
# OpenWrt BusyBox ash-compatible Cloudflare A-record synchronizer.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF="$HERE/config.conf"; DRY=0
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) DRY=1;; --config) shift; CONF=${1:?缺少配置文件路径};; -h|--help) echo "用法：$0 [--dry-run] [--config 配置文件]"; exit;; *) echo "未知参数：$1" >&2; exit 2;; esac; shift; done
[ -r "$CONF" ] || { echo "无法读取配置文件：$CONF" >&2; exit 2; }
. "$CONF"
: "${SOURCE_URL:?SOURCE_URL is required}" "${HTTP_TIMEOUT:=20}" "${CONNECT_TIMEOUT:=4}" "${LOG_FILE:=/tmp/openwrt-cf-domain-speed-sync.log}" "${LOCK_DIR:=/tmp/openwrt-cf-domain-speed-sync.lock}" "${MANAGED_COMMENT:=managed-by-openwrt-cf-domain-speed-sync}" "${CF_PROXIED:=false}"
SELECT_COUNT=${SELECT_COUNT:-${IP_COUNT:-3}}
case "$SELECT_COUNT" in ''|*[!0-9]*|0) echo '错误：SELECT_COUNT 必须是正整数' >&2; exit 1;; esac
: "${SPEEDTEST_URL:=https://xn--e1a.eu.org/300.zip}" "${SPEEDTEST_MAX_BYTES:=4194304}" "${SPEEDTEST_TIMEOUT:=30}"
: "${SPEED_CONCURRENCY:=3}"
: "${MIN_SPEED_MBPS:=40}"
case "$MIN_SPEED_MBPS" in ''|*[!0-9]*|0) echo '错误：MIN_SPEED_MBPS 必须是正整数' >&2; exit 1;; esac
: "${CF_IPV4_URL:=https://www.cloudflare.com/ips-v4}"
: "${PAUSE_PROXY_SERVICES:=false}" "${PROXY_SERVICES:=}"
TMP=$(mktemp -d /tmp/cf-domain-speed-sync.XXXXXX) || exit 1
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
RESULT=失败 REASON='未知错误'
LOCK_OWNED=0
restore_services(){
 [ -f "$TMP/stopped-services" ] || return 0
 while IFS= read -r service; do
   [ -n "$service" ] || continue
   if "/etc/init.d/$service" start >/dev/null 2>&1; then
     log "已尝试恢复服务：$service"; echo "已尝试恢复服务：$service"
   else
     log "恢复服务失败：${service}，请手动检查"; echo "恢复服务失败：${service}，请手动检查" >&2
   fi
 done < "$TMP/stopped-services"
 : > "$TMP/stopped-services"
}
clean(){ restore_services; [ "$LOCK_OWNED" -eq 0 ] || rmdir "$LOCK_DIR" 2>/dev/null || :; rm -rf "$TMP"; }
on_signal(){ sig=$1; trap - EXIT HUP INT TERM; RESULT=已中断; REASON="收到信号 ${sig}，任务已停止"; log "中断：$REASON"; echo "中断：$REASON" >&2; clean; exit 130; }
wecom(){
 [ -n "${WECHAT_CORPID:-}" ] && [ -n "${WECHAT_SECRET:-}" ] && [ -n "${WECHAT_AGENTID:-}" ] || return 0
 curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=$WECHAT_CORPID&corpsecret=$WECHAT_SECRET" -o "$TMP/wt" || { log 'WeCom token request failed'; return 0; }
 token=$(jq -r '.access_token // empty' "$TMP/wt"); [ -n "$token" ] || { log 'WeCom token rejected'; return 0; }
 selected_text='本次没有选定 IP'
 if [ -s "$TMP/selected" ]; then
   selected_text=$(awk 'NR==FNR {chosen[$1]=1; next} ($2 in chosen) {printf "%s  %.2f Mbps\n", $2, $1*8/1000000}' "$TMP/selected" "$TMP/speeds")
 fi
 message=$(printf '【Cloudflare DNS %s】\n域名：%s\n%s\n候选 IP（以同步状态为准）：\n%s\n完成时间：%s' "$RESULT" "${DNS_RECORD_NAME:-未配置}" "$REASON" "$selected_text" "$(date '+%F %T')")
 payload=$(jq -n --arg to "${WECHAT_TOUSER:-@all}" --arg a "$WECHAT_AGENTID" --arg t "$message" '{touser:$to,msgtype:"text",agentid:($a|tonumber),text:{content:$t},safe:0}') || return 0
 curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" -H 'Content-Type: application/json' -d "$payload" "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$token" -o "$TMP/ws" || { log 'WeCom delivery failed'; return 0; }
 jq -e '.errcode==0' "$TMP/ws" >/dev/null 2>&1 && log 'WeCom notification sent' || log 'WeCom notification rejected'
}
trap 'wecom; clean' EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
die(){ RESULT=失败; REASON=$*; log "错误：$*"; echo "错误：$*" >&2; exit 1; }
mkdir "$LOCK_DIR" 2>/dev/null || { RESULT=已跳过; REASON='另一个更新任务正在运行'; log "跳过：$REASON"; echo "跳过：$REASON"; exit 0; }
LOCK_OWNED=1
command -v curl >/dev/null 2>&1 || die '缺少 curl，请运行 apk add curl（或 opkg install curl）'
command -v jq >/dev/null 2>&1 || die '缺少 jq，请运行 apk add jq（或 opkg install jq）'
ipok(){ echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1;exit 0}{exit 1}'; }
show(){ log "$*"; printf '%s\n' "$*"; }
if [ "$PAUSE_PROXY_SERVICES" = true ]; then
 : > "$TMP/stopped-services"
 for service in $PROXY_SERVICES; do
   case "$service" in ''|*[!A-Za-z0-9_-]*) die "无效的服务名称：$service";; esac
   service_path="/etc/init.d/$service"
   [ -x "$service_path" ] || { show "服务不存在，跳过：$service"; continue; }
   service_status=$("$service_path" status 2>/dev/null) || { show "无法确认服务状态，跳过：$service"; continue; }
   case "$service_status" in
     running|running.*|active|active.*) service_running=true ;;
     *)
       if printf '%s' "$service_status" | jq -e '[.. | objects | select(.running == true)] | length > 0' >/dev/null 2>&1; then
         service_running=true
       else
         service_running=false
       fi ;;
   esac
   if [ "$service_running" != true ]; then
     show "服务未运行或状态无法识别，跳过：$service"; continue
   fi
   # Record before stopping so a partial failure still triggers restoration.
   printf '%s\n' "$service" >> "$TMP/stopped-services"
   "$service_path" stop >/dev/null 2>&1 || die "停止服务失败：${service}，正在恢复已暂停的服务"
   show "已暂停服务：$service"
 done
elif [ "$PAUSE_PROXY_SERVICES" != false ]; then
 die 'PAUSE_PROXY_SERVICES 必须为 true 或 false'
fi
download_speed(){
 ip=$1
 # Resolve the URL host/path while connecting the socket to candidate IP;
 # curl still sends the proper Host header and validates TLS for the URL host.
 case "$SPEEDTEST_URL" in https://*) authority=${SPEEDTEST_URL#https://}; port=443;; http://*) authority=${SPEEDTEST_URL#http://}; port=80;; *) return 1;; esac
 host=${authority%%/*}
 case "$host" in *:*|*@*|*\?*|*\#*) return 1;; esac
 [ -n "$host" ] || return 1
 result=$(curl -fsS --noproxy '*' --connect-timeout "$CONNECT_TIMEOUT" --max-time "$SPEEDTEST_TIMEOUT" --max-filesize "$SPEEDTEST_MAX_BYTES" --range "0-$((SPEEDTEST_MAX_BYTES-1))" --resolve "$host:$port:$ip" -o /dev/null -w '%{http_code} %{size_download} %{time_total}' "$SPEEDTEST_URL" 2>/dev/null) || return 1
 set -- $result; [ "$#" -eq 3 ] || return 1
 code=$1; bytes=$2; secs=$3
 [ "$code" = 206 ] || return 1
 awk -v b="$bytes" -v s="$secs" -v max="$SPEEDTEST_MAX_BYTES" 'BEGIN{if(s>0 && b>0 && b<=max) printf "%.3f", b/s; else exit 1}'
}
speed_worker(){
 ip=$1
 result_file=$2
 bps=$(download_speed "$ip") || { printf 'FAIL\n' > "$result_file"; return; }
 printf '%s\n' "$bps" > "$result_file"
 mbps=$(awk -v b="$bps" 'BEGIN{printf "%.2f",b*8/1000000}')
 printf '下载测速完成：%s，%s Mbps\n' "$ip" "$mbps" >> "$result_file.log"
}
src="$TMP/source"
curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$SOURCE_URL" -o "$src" || die '候选源下载失败'
[ -s "$src" ] || die 'candidate source is empty'
# cf_domains.txt is a plain one-hostname-per-line list. Resolve each name to
# IPv4 candidates; the download probe then connects to each address directly.
awk '{gsub(/\r/, ""); if ($0 ~ /^[A-Za-z0-9.-]+$/) print tolower($0)}' "$src" | awk '!x[$0]++' > "$TMP/domains"
: > "$TMP/candidates"
while IFS= read -r domain; do
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$domain" 2>/dev/null | awk '/^Name:[[:space:]]/ {answer=1; next} answer && $1 ~ /^Address/ && $NF ~ /^[0-9]+\./ {print $NF}'
  fi
done < "$TMP/domains" | awk '!x[$0]++' > "$TMP/candidates"
# Validate and use the current official CIDR list; never sync if it is unavailable.
show '正在获取 Cloudflare 官方 IPv4 网段列表……'
curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$CF_IPV4_URL" -o "$TMP/cidrs" || die 'Cloudflare 网段列表下载失败，已停止同步'
awk '
function valid(ip, a,n,i) {
 n=split(ip,a,"."); if(n!=4) return 0
 for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) return 0
 return 1
}
{
 sub(/\r$/, "")
 n=split($0,p,"/")
 if(n!=2 || !valid(p[1]) || p[2]!~/^[0-9]+$/ || p[2]>32) exit 1
 count++
}
END {if(count==0) exit 1}
' "$TMP/cidrs" || die 'Cloudflare 网段列表无效，已停止同步'
awk '
function number(ip, a) {
 split(ip,a,".")
 return ((a[1]*256+a[2])*256+a[3])*256+a[4]
}
BEGIN {count=0}
NR==FNR {
 split($0,c,"/"); size=2^(32-c[2]); start[count]=int(number(c[1])/size)*size; width[count]=size; count++; next
}
{
 if(split($0,a,".")!=4) next
 ok=1; for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) ok=0
 if(!ok) next
 ip=number($0)
 for(i=0;i<count;i++) if(ip>=start[i] && ip<start[i]+width[i]) { print; break }
}
' "$TMP/cidrs" "$TMP/candidates" > "$TMP/filtered" || die '网段匹配失败，已停止同步'
mv "$TMP/filtered" "$TMP/candidates" || die '无法保存筛选结果'
filtered_count=$(wc -l < "$TMP/candidates" | tr -d ' ')
show "Cloudflare 官方网段筛选后：$filtered_count 个 IP"
[ "$filtered_count" -ge "$SELECT_COUNT" ] || die "筛选后仅有 $filtered_count 个 IP，需要 $SELECT_COUNT 个；已停止同步"
: > "$TMP/selected"
  : > "$TMP/speeds"
 total=$(wc -l < "$TMP/candidates" | tr -d ' ')
 completed=0
 case "$SPEED_CONCURRENCY" in ''|*[!0-9]*|0) die 'SPEED_CONCURRENCY 必须是正整数';; esac
 show "开始下载测速：共 ${total} 个候选，并发数 ${SPEED_CONCURRENCY}，每个最多下载 ${SPEEDTEST_MAX_BYTES} 字节"
 batch=0
 batch_files=''
 qualified=0
  while IFS= read -r ip; do
   ipok "$ip" || continue
   result_file="$TMP/result.$ip"
   show "提交测速任务：$ip"
   speed_worker "$ip" "$result_file" &
   batch=$((batch+1))
   batch_files="$batch_files
$ip"
   if [ "$batch" -ge "$SPEED_CONCURRENCY" ]; then
     wait
     for done_ip in $batch_files; do
       completed=$((completed+1))
       result_file="$TMP/result.$done_ip"
       [ -s "$result_file.log" ] && { cat "$result_file.log"; cat "$result_file.log" >> "$LOG_FILE"; }
       if [ -s "$result_file" ] && [ "$(sed -n '1p' "$result_file")" != FAIL ]; then
         bps=$(sed -n '1p' "$result_file")
         printf '%s\t%s\n' "$bps" "$done_ip" >> "$TMP/speeds"
         if awk -v b="$bps" -v min="$MIN_SPEED_MBPS" 'BEGIN{exit !(b*8>=min*1000000)}'; then qualified=$((qualified+1)); show "达标 IP：${done_ip}，已获取合适 IP：$qualified/$SELECT_COUNT"; fi
       else
         show "下载测速失败：$done_ip"
       fi
       show "测速进度：已完成 $completed/$total，剩余 $((total-completed)) 个 IP"
     done
     batch=0; batch_files=''
     qualified=$(awk -v min="$MIN_SPEED_MBPS" '$1*8 >= min*1000000 {n++} END {print n+0}' "$TMP/speeds")
     if [ "$qualified" -ge "$SELECT_COUNT" ]; then
       show "已找到 $qualified 个不低于 $MIN_SPEED_MBPS Mbps 的 IP，停止后续测速"
       break
     fi
   fi
  done < "$TMP/candidates"
 if [ "$batch" -gt 0 ]; then
   wait
   for done_ip in $batch_files; do
     completed=$((completed+1))
     result_file="$TMP/result.$done_ip"
     [ -s "$result_file.log" ] && { cat "$result_file.log"; cat "$result_file.log" >> "$LOG_FILE"; }
     if [ -s "$result_file" ] && [ "$(sed -n '1p' "$result_file")" != FAIL ]; then
       bps=$(sed -n '1p' "$result_file")
       printf '%s\t%s\n' "$bps" "$done_ip" >> "$TMP/speeds"
       if awk -v b="$bps" -v min="$MIN_SPEED_MBPS" 'BEGIN{exit !(b*8>=min*1000000)}'; then qualified=$((qualified+1)); show "达标 IP：${done_ip}，已获取合适 IP：$qualified/$SELECT_COUNT"; fi
     else
       show "下载测速失败：$done_ip"
     fi
     show "测速进度：已完成 $completed/$total，剩余 $((total-completed)) 个 IP"
   done
 fi
  awk -v min="$MIN_SPEED_MBPS" '$1*8 >= min*1000000' "$TMP/speeds" | sort -nr -k1,1 | head -n "$SELECT_COUNT" | awk -F '\t' '{print $2}' > "$TMP/selected"
  show '测速排名（从快到慢，最多显示前 20 名）：'
  sort -nr -k1,1 "$TMP/speeds" | head -n 20 | awk -F '\t' '{printf "%d. %s — %.2f Mbps\n", NR, $2, $1*8/1000000}' | tee -a "$LOG_FILE"
n=$(wc -l < "$TMP/selected" | tr -d ' '); [ "$n" -ge "$SELECT_COUNT" ] || die "达到 $MIN_SPEED_MBPS Mbps 的 IP 只有 $n 个，需要 $SELECT_COUNT 个；不修改 DNS"
[ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_ZONE_ID:-}" ] && [ -n "${DNS_RECORD_NAME:-}" ] || die 'Cloudflare credentials or DNS_RECORD_NAME missing'
[ "$CF_PROXIED" = false ] || die '1 分钟 TTL 仅适用于 DNS only，请设置 CF_PROXIED=false'
show "开始查询 Cloudflare DNS：$DNS_RECORD_NAME"
cf(){ method=$1 path=$2 body=${3:-}; out="$TMP/cf"; if [ -n "$body" ]; then curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" -X "$method" -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' --data "$body" "https://api.cloudflare.com/client/v4$path" -o "$out" || return 1; else curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" -X "$method" -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4$path" -o "$out" || return 1; fi; jq -e '.success==true' "$out" >/dev/null 2>&1; }
records="$TMP/records"; : > "$records"; page=1
while :; do cf GET "/zones/$CF_ZONE_ID/dns_records?type=A&name=$DNS_RECORD_NAME&per_page=100&page=$page" || die 'Cloudflare DNS query failed; no DNS changes made'; jq -c '.result[]' "$TMP/cf" >> "$records" || die 'Cloudflare response invalid'; pages=$(jq -r '.result_info.total_pages // 1' "$TMP/cf"); [ "$page" -ge "$pages" ] && break; page=$((page+1)); done
rb="$TMP/rb"; mkdir "$rb"
rollback(){ show 'DNS 修改失败，正在尝试回滚'; for f in "$rb"/created.*; do [ -f "$f" ] || continue; rid=$(cat "$f"); if cf DELETE "/zones/$CF_ZONE_ID/dns_records/$rid"; then show "[回滚] 删除本次新增记录 $rid：成功"; else show "[回滚] 删除记录 $rid 失败，请人工核对"; fi; done; for f in "$rb"/deleted.*; do [ -f "$f" ] || continue; rip=$(jq -r '.content' "$f"); if cf POST "/zones/$CF_ZONE_ID/dns_records" "$(jq '{type,name,content,ttl,proxied,comment}' "$f")"; then show "[回滚] 恢复 $rip：成功"; else show "[回滚] 恢复 $rip 失败，请人工核对"; fi; done; }
created_index=0
deleted_index=0
mutate(){ d=$1 m=$2 p=$3 b=${4:-} k=${5:-}; [ "$DRY" -eq 1 ] && { show "[预演] $d"; return 0; }; show "[进行中] $d"; cf "$m" "$p" "$b" || { show "[失败] $d"; return 1; }; if [ "$k" = created ]; then created_index=$((created_index+1)); jq -er '.result.id | select(type=="string" and length>0)' "$TMP/cf" > "$rb/created.$created_index" || { log '创建成功响应缺少记录 ID，请人工核对 DNS'; return 1; }; fi; show "[成功] $d"; return 0; }
jq -s -c --arg mark "$MANAGED_COMMENT" '.[]|select(.comment==$mark)' "$records" > "$TMP/owned"
while IFS= read -r ip; do if jq -r .content "$records"|grep -Fxq "$ip"; then show "[保留] $ip：已存在"; continue; fi; data=$(jq -n --arg name "$DNS_RECORD_NAME" --arg ip "$ip" --arg mark "$MANAGED_COMMENT" '{type:"A",name:$name,content:$ip,ttl:60,proxied:false,comment:$mark}') || { rollback; die 'payload creation failed'; }; mutate "新增 $ip（TTL 60 秒）" POST "/zones/$CF_ZONE_ID/dns_records" "$data" created || { rollback; die 'Cloudflare 创建失败或结果不明，请核对 DNS'; }; done < "$TMP/selected"
while IFS= read -r rec; do
 ip=$(printf %s "$rec"|jq -r .content); id=$(printf %s "$rec"|jq -r .id)
 if ! grep -Fxq "$ip" "$TMP/selected"; then
  mutate "删除旧记录 $ip" DELETE "/zones/$CF_ZONE_ID/dns_records/$id" '' || { rollback; die 'Cloudflare 删除失败或结果不明，请核对 DNS'; }
  if [ "$DRY" -eq 0 ]; then
   deleted_index=$((deleted_index+1))
   printf '%s\n' "$rec" > "$rb/deleted.$deleted_index"
  fi
 fi
done < "$TMP/owned"
if [ "$DRY" -eq 1 ]; then RESULT=已跳过; REASON="预演完成，已验证 $n 个候选 IP"; else RESULT=成功; REASON="已同步 $n 个候选 IP"; fi
show "$RESULT: $REASON"
exit 0

