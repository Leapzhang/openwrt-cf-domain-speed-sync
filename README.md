# 域名列表下载测速与 DNS 同步

读取 cf_domains.txt 的域名，解析 IPv4 并去重，通过测速文件测量下载速度，选出最快的地址同步到 Cloudflare。无需地区筛选或 ping，支持并发与企业微信通知。

安装前请备份已有配置。安装脚本支持 apk 和 opkg；编辑 config.conf 填写 CF_API_TOKEN、CF_ZONE_ID、DNS_RECORD_NAME，以及可选的 WECHAT_CORPID、WECHAT_SECRET、WECHAT_AGENTID、WECHAT_TOUSER。SPEED_CONCURRENCY 控制并发数，SELECT_COUNT 控制选取并同步的 IP 数量。旧配置中的 IP_COUNT 仍可使用；如果同时设置，以 SELECT_COUNT 为准。

运行 `./start.sh --dry-run` 预览，并查看日志。cron.example 可供定时任务参考。DNS 解析依赖 nslookup，测速地址默认为 https://xn--e1a.eu.org/300.zip。达到 MIN_SPEED_MBPS（默认 40 Mbps）的 IP 达到 SELECT_COUNT 后停止提交新的测速；已启动的并发批次会先结束。合格 IP 数量不足时不修改 DNS。

测速前下载 Cloudflare 官方 IPv4 网段并在本地筛选；列表下载失败、格式无效或候选数量不足时停止同步。官方网段匹配不等于实时 AS13335 验证。网段来源可通过 CF_IPV4_URL 配置。

候选域名列表直接从 SOURCE_URL 下载，不再检查最后更新时间或限制列表年龄；原有配置里的 SOURCE_MAX_AGE_SECONDS 会被忽略。下载失败或结果为空时停止同步。测速服务器必须支持 HTTP 206 范围请求，重定向会被拒绝。DNS 同步先创建缺失记录，再删除过时的受管理记录，失败后尽力回滚。网络超时可能使写入结果不确定，请人工核对。新记录的 TTL 为 60 秒，已有记录的 TTL 不会自动修改。

如需临时停止代理，在 config.conf 中设置 PAUSE_PROXY_SERVICES=true，并在 PROXY_SERVICES 中保留需要暂停的 /etc/init.d/ 服务名（空格分隔）。默认关闭；脚本在检查依赖后、获取候选列表之前暂停确认正在运行的服务，不存在或状态无法识别的服务会跳过。DNS 同步和企业微信通知结束后再尝试恢复；失败或收到常见终止信号时也会尝试恢复，恢复失败会提示手动检查。强制终止或断电不能保证恢复。--dry-run 仍会实际测速，因此启用此选项时也会暂停服务。暂停代理可能导致候选源、Cloudflare API 或企业微信不可访问。
