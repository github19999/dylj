#!/bin/bash
# =============================================================
# sing-box 订阅链接生成器
# 从 /etc/sing-box/config.json 自动解析并生成各协议订阅链接
# 支持: vless / vmess / trojan / shadowsocks / hysteria2 /
#       tuic / anytls / reality / naive / brook 等
# =============================================================

set -euo pipefail

CONFIG_FILE="${1:-/etc/sing-box/config.json}"
OUTPUT_FILE="${2:-/etc/sing-box/subscription.txt}"
BASE64_FILE="${3:-/etc/sing-box/subscription.b64}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_link()  { echo -e "${CYAN}[LINK]${NC}  $*"; }

# ─── 依赖检查 ────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in jq base64 python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing[*]}"
        log_error "请运行: apt-get install -y jq python3 coreutils"
        exit 1
    fi
}

# ─── URL 编码 ────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# 只对特殊字符编码（保留 @ : / ? = & # 等结构字符）
urlencode_component() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# ─── 获取服务器公网 IP ───────────────────────────────────────
get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb"; do
        ip=$(curl -s --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

# ─── 从 TLS 配置提取 SNI ─────────────────────────────────────
get_sni() {
    local tls_json="$1"
    local listen_addr="$2"
    local sni=""
    sni=$(echo "$tls_json" | jq -r '.server_name // empty' 2>/dev/null)
    [[ -z "$sni" || "$sni" == "null" ]] && sni="$listen_addr"
    echo "$sni"
}

# ─── 主解析函数 ──────────────────────────────────────────────
parse_inbounds() {
    local config="$1"
    local server_ip="$2"
    local links=()

    local count
    count=$(echo "$config" | jq '.inbounds | length')

    for (( i=0; i<count; i++ )); do
        local inbound
        inbound=$(echo "$config" | jq ".inbounds[$i]")

        local type tag listen port
        type=$(echo "$inbound" | jq -r '.type // empty')
        tag=$(echo "$inbound"  | jq -r '.tag  // empty')
        listen=$(echo "$inbound" | jq -r '.listen // "::"')
        port=$(echo "$inbound"  | jq -r '.listen_port // empty')

        # 监听地址解析（:: 表示所有接口，用 server_ip 替代）
        local addr="$server_ip"
        if [[ "$listen" != "::" && "$listen" != "0.0.0.0" && -n "$listen" ]]; then
            addr="$listen"
        fi

        [[ -z "$type" || -z "$port" ]] && continue

        local tls_json=""
        tls_json=$(echo "$inbound" | jq '.tls // {}' 2>/dev/null)
        local tls_enabled
        tls_enabled=$(echo "$tls_json" | jq -r '.enabled // false')

        local tag_encoded
        tag_encoded=$(urlencode "$tag")

        log_info "处理 inbound [$i]: type=$type  tag=$tag  port=$port"

        # ── VLESS ───────────────────────────────────────────
        if [[ "$type" == "vless" ]]; then
            local user_json uuid flow
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            uuid=$(echo "$user_json"  | jq -r '.uuid // empty')
            flow=$(echo "$user_json"  | jq -r '.flow // empty')

            [[ -z "$uuid" ]] && { log_warn "vless: 缺少 uuid，跳过"; continue; }

            local transport_type network header_type path sni security fp pbk sid
            transport_type=$(echo "$inbound" | jq -r '.transport.type // "tcp"')
            network="$transport_type"
            path=$(echo "$inbound" | jq -r '.transport.path // "/"')
            header_type="none"
            sni=$(get_sni "$tls_json" "$addr")
            security="none"
            [[ "$tls_enabled" == "true" ]] && security="tls"
            fp=$(echo "$tls_json" | jq -r '.utls.fingerprint // "chrome"')

            # REALITY 支持
            local reality_json
            reality_json=$(echo "$tls_json" | jq '.reality // {}')
            local reality_enabled
            reality_enabled=$(echo "$reality_json" | jq -r '.enabled // false')
            if [[ "$reality_enabled" == "true" ]]; then
                security="reality"
                pbk=$(echo "$reality_json" | jq -r '.public_key // empty')
                sid=$(echo "$reality_json" | jq -r '.short_id // empty')
            fi

            local params="encryption=none"
            [[ -n "$flow" ]] && params+="&flow=$flow"
            params+="&security=$security&sni=$sni"
            [[ "$security" == "tls" || "$security" == "reality" ]] && params+="&fp=$fp"
            [[ "$security" == "reality" ]] && params+="&pbk=$pbk&sid=$sid"
            params+="&type=$network"
            [[ "$network" == "ws" || "$network" == "http" ]] && params+="&path=$(urlencode_component "$path")"
            params+="&headerType=$header_type"

            local link="vless://${uuid}@${addr}:${port}?${params}#${tag_encoded}"
            links+=("$link")

        # ── VMESS ───────────────────────────────────────────
        elif [[ "$type" == "vmess" ]]; then
            local user_json uuid alter_id
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            uuid=$(echo "$user_json"   | jq -r '.uuid // empty')
            alter_id=$(echo "$user_json" | jq -r '.alterId // 0')

            [[ -z "$uuid" ]] && { log_warn "vmess: 缺少 uuid，跳过"; continue; }

            local network path sni tls_str
            network=$(echo "$inbound" | jq -r '.transport.type // "tcp"')
            path=$(echo "$inbound"    | jq -r '.transport.path // "/"')
            sni=$(get_sni "$tls_json" "$addr")
            tls_str="none"
            [[ "$tls_enabled" == "true" ]] && tls_str="tls"

            local vmess_obj
            vmess_obj=$(python3 -c "
import json, base64
obj = {
    'v':'2','ps':'$tag','add':'$addr','port':'$port',
    'id':'$uuid','aid':'$alter_id','scy':'auto',
    'net':'$network','type':'none','host':'$sni',
    'path':'$path','tls':'$tls_str','sni':'$sni','fp':'chrome'
}
print(base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('='))
")
            local link="vmess://${vmess_obj}"
            links+=("$link")

        # ── TROJAN ──────────────────────────────────────────
        elif [[ "$type" == "trojan" ]]; then
            local user_json password
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            password=$(echo "$user_json" | jq -r '.password // empty')

            [[ -z "$password" ]] && { log_warn "trojan: 缺少 password，跳过"; continue; }

            local network path sni
            network=$(echo "$inbound" | jq -r '.transport.type // "tcp"')
            path=$(echo "$inbound"    | jq -r '.transport.path // "/"')
            sni=$(get_sni "$tls_json" "$addr")

            local params="security=tls&sni=$sni&type=$network"
            [[ "$network" == "ws" ]] && params+="&path=$(urlencode_component "$path")"
            local link="trojan://$(urlencode_component "$password")@${addr}:${port}?${params}#${tag_encoded}"
            links+=("$link")

        # ── SHADOWSOCKS ─────────────────────────────────────
        elif [[ "$type" == "shadowsocks" ]]; then
            local method password
            method=$(echo "$inbound"   | jq -r '.method   // empty')
            password=$(echo "$inbound" | jq -r '.password // empty')

            [[ -z "$method" || -z "$password" ]] && { log_warn "ss: 缺少 method/password，跳过"; continue; }

            local userinfo
            userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0)
            # 去掉 base64 末尾 padding（部分客户端需要）
            userinfo="${userinfo%%=*}"

            local link="ss://${userinfo}@${addr}:${port}?#${tag_encoded}"
            links+=("$link")

        # ── HYSTERIA2 ───────────────────────────────────────
        elif [[ "$type" == "hysteria2" ]]; then
            local user_json password sni
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            password=$(echo "$user_json" | jq -r '.password // empty')
            sni=$(get_sni "$tls_json" "$addr")

            local up_mbps down_mbps
            up_mbps=$(echo "$inbound"   | jq -r '.up_mbps   // empty')
            down_mbps=$(echo "$inbound" | jq -r '.down_mbps // empty')

            [[ -z "$password" ]] && { log_warn "hy2: 缺少 password，跳过"; continue; }

            local params="sni=$sni&insecure=0"
            [[ -n "$up_mbps"   ]] && params+="&upmbps=$up_mbps"
            [[ -n "$down_mbps" ]] && params+="&downmbps=$down_mbps"

            local link="hysteria2://$(urlencode_component "$password")@${addr}:${port}?${params}#${tag_encoded}"
            links+=("$link")

        # ── TUIC ────────────────────────────────────────────
        elif [[ "$type" == "tuic" ]]; then
            local user_json uuid password sni
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            uuid=$(echo "$user_json"    | jq -r '.uuid     // empty')
            password=$(echo "$user_json"| jq -r '.password // empty')
            sni=$(get_sni "$tls_json" "$addr")

            [[ -z "$uuid" ]] && { log_warn "tuic: 缺少 uuid，跳过"; continue; }

            local congestion
            congestion=$(echo "$inbound" | jq -r '.congestion_control // "bbr"')

            local params="sni=$sni&congestion_control=$congestion&alpn=h3&udp_relay_mode=native"
            local link="tuic://${uuid}:$(urlencode_component "${password}")@${addr}:${port}?${params}#${tag_encoded}"
            links+=("$link")

        # ── ANYTLS ──────────────────────────────────────────
        elif [[ "$type" == "anytls" ]]; then
            local user_json password sni
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            password=$(echo "$user_json" | jq -r '.password // empty')
            sni=$(get_sni "$tls_json" "$addr")

            [[ -z "$password" ]] && { log_warn "anytls: 缺少 password，跳过"; continue; }

            local params="security=tls&sni=$sni&type=tcp"
            local link="anytls://$(urlencode_component "$password")@${addr}:${port}?${params}#${tag_encoded}"
            links+=("$link")

        # ── NAIVE ────────────────────────────────────────────
        elif [[ "$type" == "naive" ]]; then
            local user_json username password sni
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            username=$(echo "$user_json" | jq -r '.username // empty')
            password=$(echo "$user_json" | jq -r '.password // empty')
            sni=$(get_sni "$tls_json" "$addr")

            [[ -z "$username" ]] && { log_warn "naive: 缺少 username，跳过"; continue; }

            local link="naive+https://$(urlencode_component "$username"):$(urlencode_component "$password")@${addr}:${port}?padding=true#${tag_encoded}"
            links+=("$link")

        # ── SHADOWTLS ────────────────────────────────────────
        elif [[ "$type" == "shadowtls" ]]; then
            local user_json password sni version
            user_json=$(echo "$inbound" | jq '.users[0] // {}')
            password=$(echo "$user_json" | jq -r '.password // empty')
            sni=$(get_sni "$tls_json" "$addr")
            version=$(echo "$inbound" | jq -r '.version // 3')

            [[ -z "$password" ]] && { log_warn "shadowtls: 缺少 password，跳过"; continue; }
            log_warn "shadowtls 订阅格式尚无统一标准，已跳过: $tag"

        else
            log_warn "未知/不支持的 inbound 类型: $type (tag=$tag)，跳过"
        fi
    done

    # 输出结果数组（通过 stdout 传回）
    printf '%s\n' "${links[@]}"
}

# ─── 主流程 ──────────────────────────────────────────────────
main() {
    echo ""
    echo "=========================================="
    echo "  sing-box 订阅链接生成器"
    echo "=========================================="
    echo ""

    check_deps

    # 验证配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi

    local config
    config=$(cat "$CONFIG_FILE")

    # 检查是否是有效 JSON
    if ! echo "$config" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        log_warn "配置文件含注释或非标准 JSON，尝试去除注释..."
        # 去掉 // 行注释（Python 处理）
        config=$(echo "$config" | python3 -c "
import sys, re, json
raw = sys.stdin.read()
# 去掉行注释 (// ...) 但不破坏 URL 中的 //
clean = re.sub(r'(?<![:\"])//[^\n]*', '', raw)
try:
    json.loads(clean)
    print(clean)
except Exception as e:
    sys.stderr.write(str(e)); sys.exit(1)
")
    fi

    log_info "获取服务器公网 IP..."
    local server_ip
    server_ip=$(get_server_ip)
    log_info "服务器 IP: $server_ip"
    echo ""

    log_info "开始解析 inbound 配置..."
    echo ""

    local all_links
    mapfile -t all_links < <(parse_inbounds "$config" "$server_ip")

    echo ""
    log_info "共生成 ${#all_links[@]} 条订阅链接"
    echo ""

    if [[ ${#all_links[@]} -eq 0 ]]; then
        log_warn "没有生成任何链接，请检查配置文件"
        exit 0
    fi

    # 写入明文订阅文件
    printf '%s\n' "${all_links[@]}" > "$OUTPUT_FILE"
    log_info "明文订阅已写入: $OUTPUT_FILE"

    # 写入 Base64 编码订阅（Clash/V2Ray 通用格式）
    printf '%s\n' "${all_links[@]}" | base64 -w 0 > "$BASE64_FILE"
    echo "" >> "$BASE64_FILE"
    log_info "Base64 订阅已写入: $BASE64_FILE"

    echo ""
    echo "=========================================="
    echo "  所有订阅链接："
    echo "=========================================="
    for link in "${all_links[@]}"; do
        echo "$link"
    done
    echo ""
    echo "=========================================="
    log_info "完成！"
    echo ""
}

main "$@"
