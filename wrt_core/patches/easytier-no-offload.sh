#!/bin/sh
# 在 fw4 的 flow offload 规则之前放行 EasyTier 的已建立连接。

setup_easytier_no_offload() {
    if [ "$(uci -q get firewall.easytier_no_offload)" != "include" ] || \
       [ "$(uci -q get firewall.easytier_no_offload.type)" != "script" ] || \
       [ "$(uci -q get firewall.easytier_no_offload.path)" != "/usr/share/easytier/firewall-offload.sh" ] || \
       [ "$(uci -q get firewall.easytier_no_offload.fw4_compatible)" != "1" ] || \
       [ "$(uci -q get firewall.easytier_no_offload.enabled)" != "1" ]; then
        # 由 EasyTier 原有的延迟重载流程提交，避免在服务启动中重复重载 fw4。
        uci -q batch <<'EOF' || return 1
set firewall.easytier_no_offload=include
set firewall.easytier_no_offload.type=script
set firewall.easytier_no_offload.path=/usr/share/easytier/firewall-offload.sh
set firewall.easytier_no_offload.fw4_compatible=1
set firewall.easytier_no_offload.enabled=1
EOF
    fi
    : > /var/run/easytier-no-offload.active
}

set_easytier_no_offload() {
    local chain rules tunname

    command -v nft >/dev/null 2>&1 || return 0
    chain="$(nft -a list chain inet fw4 forward 2>/dev/null)" || return 0

    # 按 handle 清理本脚本的旧规则，并与新规则在同一个 nft 事务内替换。
    rules="$(printf '%s\n' "$chain" | awk '
        /comment "EasyTier no offload (ingress|egress)"/ {
            for (i = 1; i < NF; i++) {
                if ($i == "handle" && $(i + 1) ~ /^[0-9]+$/)
                    print "delete rule inet fw4 forward handle " $(i + 1)
            }
        }
    ')"

    if [ "${1:-reload}" != "stop" ] && \
       [ -f /var/run/easytier-no-offload.active ] && \
       [ "$(uci -q get easytier.@easytier[0].enabled)" = "1" ] && \
       [ "$(uci -q get easytier.@easytier[0].auto_config_firewall || echo 1)" = "1" ] && \
       [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && \
       [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ]; then
        if [ "$(uci -q get easytier.@easytier[0].etcmd)" = "config" ]; then
            tunname="$(sed -n "s/^[[:space:]]*dev_name[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" /etc/easytier/config.toml 2>/dev/null | head -n 1)"
        else
            tunname="$(uci -q get easytier.@easytier[0].tunname)"
        fi
        tunname="${tunname:-tun0}"

        # 接口名将写入 nft 输入，禁止引号、换行等控制字符。
        case "$tunname" in
            *[!a-zA-Z0-9_.:-]*)
                logger -t easytier "无效的 TUN 接口名，跳过 PPE 防火墙修复"
                ;;
            *)
                rules="$rules
insert rule inet fw4 forward iifname \"$tunname\" ct state established,related counter accept comment \"EasyTier no offload ingress\"
insert rule inet fw4 forward oifname \"$tunname\" ct state established,related counter accept comment \"EasyTier no offload egress\""
                ;;
        esac
    fi

    [ -n "$rules" ] || return 0
    if ! printf '%s\n' "$rules" | nft -f -; then
        logger -t easytier "应用 PPE 防火墙修复失败"
        return 1
    fi
}

case "${1:-reload}" in
    start)
        setup_easytier_no_offload || exit 1
        set_easytier_no_offload
        ;;
    stop)
        rm -f /var/run/easytier-no-offload.active
        set_easytier_no_offload stop
        ;;
    *)
        # fw4 每次启动/重载执行 script include，重新检查当前配置。
        set_easytier_no_offload
        ;;
esac
