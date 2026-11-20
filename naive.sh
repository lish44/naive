#!/usr/bin/env bash
# NaiveProxy 独立管理脚本 (for klzgrad/forwardproxy v2.11.2-naive)
# 特性：零第三方脚本依赖、升级/改配不覆盖自定义 Caddy 路由、自动 socat 中转支持公网 SOCKS5 出站

set -o pipefail

# ======================== 基础配置 ========================
CADDY_RELEASE="v2.11.2-naive"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_RELEASE}/caddy-forwardproxy-naive.tar.xz"
CADDY_SHA256="19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8"

REPO_RAW="https://raw.githubusercontent.com/lish44/naive/main"
SCRIPT_URL="${REPO_RAW}/naive.sh"
HTML_URL="${REPO_RAW}/html.tar.gz"

AUTOCONFIG="/etc/caddy/.autoconfig"
CADDY_JSON="/etc/caddy/caddy_config.json"
SERVICE_FILE="/etc/systemd/system/naive.service"
RELAY_SERVICE="/etc/systemd/system/naive-socks-relay.service"
RELAY_PORT="10808"
SCRIPT_PATH="/root/.naive.sh"

# ======================== 终端输出 ========================
red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; none='\e[0m'
_red()    { echo -e "${red}$*${none}"; }
_green()  { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_cyan()   { echo -e "${cyan}$*${none}"; }

# ======================== 环境检查 ========================
[[ $(id -u) -ne 0 ]] && { _red "请使用 root 用户运行。"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { _red "当前系统不支持 systemd。"; exit 1; }

if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    _red "仅支持 apt-get / dnf / yum 系统。"
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64)         ARCH="amd64" ;;
    aarch64|arm64|armv8*) ARCH="arm64" ;;
    *) _red "不支持的架构: $(uname -m)"; exit 1 ;;
esac

# ======================== 通用工具 ========================
download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
    else
        return 1
    fi
}

install_dependencies() {
    case "$PKG_MGR" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                ca-certificates curl wget tar xz-utils jq socat libcap2-bin certbot cron
            ;;
        dnf)
            dnf -y install ca-certificates curl wget tar xz jq socat libcap certbot cronie
            ;;
        yum)
            yum -y install epel-release || true
            yum -y install ca-certificates curl wget tar xz jq socat libcap certbot cronie
            ;;
    esac
}

ensure_tool() {
    local bin="$1"
    command -v "$bin" >/dev/null 2>&1 && return 0
    _yellow "未检测到 ${bin}，正在自动安装..."
    install_dependencies
}

valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 && 10#$1 != 80 )); }
valid_any_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_domain()   { [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *. ]]; }
valid_user()     { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9_.-]+$ && "$1" != *:* ]]; }
valid_password() { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9_.@+-]+$ ]]; }

# forwardproxy v2.11.2 JSON 认证需要双层 Base64: base64(base64(user:pass))
json_auth_credential() {
    printf '%s' "$1:$2" | base64 | tr -d '\n' | base64 | tr -d '\n'
}

get_ip() {
    ipv4=""
    for u in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.co/ip; do
        ipv4="$(curl -4fsS --max-time 6 "$u" 2>/dev/null | tr -d '\r\n ' || true)"
        [[ "$ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        ipv4=""
    done
    ipv6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)"
    [[ -n "$ipv4" || -n "$ipv6" ]] || { _red "未检测到公网 IP。"; return 1; }
}

port_80_busy() {
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|\]):80$|(^|:)80$'
}

show_listen() {
    ss -lntup 2>/dev/null | grep -E "caddy|socat|:443|:80|:${RELAY_PORT}" || true
}

# ======================== 配置读写与增量修补 ========================
load_saved_config() {
    [[ -f "$AUTOCONFIG" ]] || return 1
    domain="$(awk -F= '/^域名domain/{print $2; exit}' "$AUTOCONFIG" | xargs)"
    naive_port="$(awk -F= '/^端口port/{print $2; exit}' "$AUTOCONFIG" | xargs)"
    user="$(awk -F= '/^用户名user/{print $2; exit}' "$AUTOCONFIG" | xargs)"
    password="$(awk -F= '/^密码password/{print $2; exit}' "$AUTOCONFIG" | xargs)"
    email="$(awk -F= '/^邮箱email/{print $2; exit}' "$AUTOCONFIG" | xargs)"
    [[ -n "$domain" && -n "$naive_port" && -n "$user" && -n "$password" ]]
}

save_config_info() {
    mkdir -p /etc/caddy
    cat > "$AUTOCONFIG" <<EOF
域名domain   =$domain
端口port     =$naive_port
用户名user   =$user
密码password =$password
邮箱email    =$email
EOF
    chmod 600 "$AUTOCONFIG"
}

get_current_upstream() {
    [[ -f "$CADDY_JSON" ]] && command -v jq >/dev/null 2>&1 || return 0
    jq -r '.. | objects | select(.handler? == "forward_proxy") | .upstream // empty' "$CADDY_JSON" 2>/dev/null | head -n1
}

get_relay_target() {
    [[ -f "$RELAY_SERVICE" ]] || return 0
    grep -oE 'TCP:[^ ]+' "$RELAY_SERVICE" 2>/dev/null | head -n1 | sed 's/^TCP://'
}

setup_socks_relay() {
    local target_host="$1" target_port="$2"
    ensure_tool socat || return 1
    cat > "$RELAY_SERVICE" <<EOF
[Unit]
Description=Local TCP Relay for NaiveProxy SOCKS5 Upstream
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${RELAY_PORT},bind=127.0.0.1,reuseaddr,fork TCP:${target_host}:${target_port}
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable naive-socks-relay >/dev/null 2>&1 || true
    systemctl restart naive-socks-relay
    sleep 1
    if ! systemctl is-active --quiet naive-socks-relay; then
        _red "本机 socat 中转服务启动失败："
        journalctl -u naive-socks-relay -n 20 --no-pager
        return 1
    fi
    return 0
}

remove_socks_relay() {
    if [[ -f "$RELAY_SERVICE" ]] || systemctl is-active --quiet naive-socks-relay 2>/dev/null; then
        systemctl disable --now naive-socks-relay >/dev/null 2>&1 || true
        rm -f "$RELAY_SERVICE"
        systemctl daemon-reload
    fi
}

# 原子化增量修补 Caddy JSON（保留其他自定义路由 + 自动校验回滚）
patch_caddy_json() {
    ensure_tool jq || return 1
    [[ -f "$CADDY_JSON" ]] || { _red "未找到 $CADDY_JSON"; return 1; }

    local tmp backup
    tmp="$(mktemp /etc/caddy/caddy_config.json.XXXXXX)" || return 1
    backup="${CADDY_JSON}.bak.$(date +%s)"
    cp -a "$CADDY_JSON" "$backup"

    if ! jq "$@" "$CADDY_JSON" > "$tmp"; then
        rm -f "$tmp"
        _red "JSON 修改失败，已保持原配置不变。"
        return 1
    fi

    if [[ -x /usr/bin/caddy ]]; then
        if ! /usr/bin/caddy validate --config "$tmp" >/tmp/naive-caddy-validate.log 2>&1; then
            cat /tmp/naive-caddy-validate.log
            rm -f "$tmp"
            _red "Caddy 配置校验失败，已自动回滚。"
            return 1
        fi
    fi

    mv -f "$tmp" "$CADDY_JSON"
    chmod 600 "$CADDY_JSON"
    return 0
}

# 仅在全新安装或旧配置无法通过校验时生成默认 JSON
write_default_caddy_config() {
    local auth tmp backup
    auth="$(json_auth_credential "$user" "$password")" || return 1
    mkdir -p /etc/caddy /var/www/html
    tmp="$(mktemp /etc/caddy/caddy_config.json.XXXXXX)" || return 1
    backup="${CADDY_JSON}.bak.$(date +%s)"
    [[ -f "$CADDY_JSON" ]] && cp -a "$CADDY_JSON" "$backup"

    cat > "$tmp" <<EOF
{
  "admin": {"disabled": true},
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":$naive_port"],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": ["$auth"],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [{"host": ["$domain"]}],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "/var/www/html",
                          "index_names": ["index.html"]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {"match": {"sni": ["$domain"]}}
          ],
          "automatic_https": {"disable": true}
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "/etc/letsencrypt/live/$domain/fullchain.pem",
            "key": "/etc/letsencrypt/live/$domain/privkey.pem"
          }
        ]
      }
    }
  }
}
EOF

    if [[ -x /usr/bin/caddy ]] && ! /usr/bin/caddy validate --config "$tmp" >/tmp/naive-caddy-validate.log 2>&1; then
        cat /tmp/naive-caddy-validate.log
        rm -f "$tmp"
        _red "默认配置校验失败。"
        return 1
    fi
    mv -f "$tmp" "$CADDY_JSON"
    chmod 600 "$CADDY_JSON"
}

# ======================== 安装与核心组件 ========================
install_caddy() {
    local work="/root/src/naive-caddy"
    local tarfile="$work/caddy-forwardproxy-naive.tar.xz"
    mkdir -p "$work"
    rm -rf "$work/caddy-forwardproxy-naive" "$tarfile"

    _cyan "正在下载 Caddy forwardproxy ${CADDY_RELEASE}..."
    download_file "$CADDY_URL" "$tarfile" || { _red "下载失败。"; return 1; }

    if command -v sha256sum >/dev/null 2>&1; then
        local sum
        sum="$(sha256sum "$tarfile" | awk '{print $1}')"
        if [[ "$sum" != "$CADDY_SHA256" ]]; then
            _red "SHA256 校验失败！"
            echo "期望: $CADDY_SHA256"
            echo "实际: $sum"
            return 1
        fi
    fi

    tar -xJf "$tarfile" -C "$work" || return 1
    local bin="$work/caddy-forwardproxy-naive/caddy"
    [[ -x "$bin" ]] || { _red "压缩包内未找到 caddy 可执行文件。"; return 1; }

    if command -v file >/dev/null 2>&1 && [[ "$ARCH" == "arm64" ]] && file "$bin" | grep -q "x86-64"; then
        _red "该预编译包为 x86_64，与当前 ARM64 架构不匹配。"
        return 1
    fi

    [[ -f /usr/bin/caddy ]] && cp -a /usr/bin/caddy /usr/bin/caddy.bak 2>/dev/null || true
    cp -f "$bin" /usr/bin/caddy
    chmod 0755 /usr/bin/caddy
    command -v setcap >/dev/null 2>&1 && setcap cap_net_bind_service=+ep /usr/bin/caddy || true
    /usr/bin/caddy version
}

write_systemd_unit() {
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=NaiveProxy Caddy
Documentation=https://github.com/klzgrad/naiveproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy_config.json
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

ensure_certificate() {
    local certdir="/etc/letsencrypt/live/$domain"
    if [[ -s "$certdir/fullchain.pem" && -s "$certdir/privkey.pem" ]]; then
        _green "检测到现有证书，直接复用。"
        return 0
    fi
    if port_80_busy; then
        _red "80 端口被占用，无法申请证书，请先释放 80 端口。"
        show_listen
        return 1
    fi
    certbot certonly --standalone --non-interactive --agree-tos \
        --preferred-challenges http -m "$email" -d "$domain" || return 1
    [[ -s "$certdir/fullchain.pem" && -s "$certdir/privkey.pem" ]]
}

install_front_page() {
    mkdir -p /var/www/html
    local tmp="/tmp/naive-html.tar.gz"
    if download_file "$HTML_URL" "$tmp" 2>/dev/null && tar -tzf "$tmp" >/dev/null 2>&1; then
        tar -xzf "$tmp" -C /var/www/ || true
        rm -f "$tmp"
    fi
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Index</title>
  <style>body{font-family:system-ui,sans-serif;max-width:680px;margin:10vh auto;padding:0 1rem;color:#222;line-height:1.6}footer{margin-top:3rem;color:#888;font-size:.85rem}</style>
</head>
<body>
  <h1>Service Status</h1>
  <p>All systems operational.</p>
  <footer>&copy; 2026</footer>
</body>
</html>
EOF
    fi
}

allow_port() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null || true
        firewall-cmd --zone=public --add-port="${naive_port}/tcp" --permanent >/dev/null || true
        firewall-cmd --zone=public --add-port="${naive_port}/udp" --permanent >/dev/null || true
        firewall-cmd --reload >/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport "$naive_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$naive_port" -j ACCEPT
        iptables -C INPUT -p udp --dport "$naive_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$naive_port" -j ACCEPT
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

add_cron() {
    mkdir -p /etc/caddy
    cat > /etc/caddy/.renew.sh <<'EOF'
#!/usr/bin/env bash
/usr/bin/certbot renew --quiet --deploy-hook "systemctl restart naive"
EOF
    chmod 700 /etc/caddy/.renew.sh
    (crontab -l 2>/dev/null | grep -vF '/etc/caddy/.renew.sh'; echo '17 3 * * * /etc/caddy/.renew.sh') | crontab -
}

start_and_verify() {
    systemctl enable naive >/dev/null 2>&1 || true
    if ! systemctl restart naive; then
        _red "NaiveProxy 启动失败："
        journalctl -u naive -n 40 --no-pager
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet naive; then
        _red "NaiveProxy 未正常运行。"
        journalctl -u naive -n 40 --no-pager
        return 1
    fi
    _green "NaiveProxy 运行正常。"
}

# ======================== 业务功能 ========================
show_config_info() {
    echo
    _cyan "=========== NaiveProxy 配置信息 ==========="
    if load_saved_config; then
        echo "域名:   $domain"
        echo "端口:   $naive_port"
        echo "用户名: $user"
        echo "密码:   $password"
        echo "连接串: naive+https://${user}:${password}@${domain}:${naive_port}"
    else
        _yellow "未找到 $AUTOCONFIG"
    fi

    local up relay_target
    up="$(get_current_upstream)"
    relay_target="$(get_relay_target)"
    if [[ -n "$up" ]]; then
        echo -e "Caddy 出站:  ${green}${up}${none}"
        if [[ -n "$relay_target" ]]; then
            local r_stat
            r_stat="$(systemctl is-active naive-socks-relay 2>/dev/null || echo inactive)"
            echo -e "socat 中转:  ${cyan}127.0.0.1:${RELAY_PORT} -> ${relay_target}${none} (${r_stat})"
        fi
    else
        echo "SOCKS5 出站: 未启用 (VPS 直出)"
    fi
    echo "-------------------------------------------"
    /usr/bin/caddy version 2>/dev/null || true
    show_listen
}

install_new() {
    install_dependencies || return 1
    while :; do
        read -r -p "NaiveProxy 端口 [默认 443，不能用 80]: " naive_port
        naive_port="${naive_port:-443}"
        valid_port "$naive_port" && break
        _red "端口无效。"
    done
    while :; do
        read -r -p "域名 (例如 n.example.com): " domain
        valid_domain "$domain" && break
        _red "域名无效。"
    done
    while :; do
        read -r -p "邮箱 (用于 Let's Encrypt): " email
        [[ "$email" == *@*.* && "$email" != *" "* ]] && break
        _red "邮箱无效。"
    done

    get_ip || return 1
    echo -e "请将 ${cyan}${domain}${none} 解析到: ${green}${ipv4:-$ipv6}${none} (CF 请关闭小黄云)"
    read -r -p "确认已解析？[y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 1

    user="User"
    password="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"

    allow_port
    ensure_certificate || return 1
    install_front_page
    install_caddy || return 1
    write_default_caddy_config || return 1
    write_systemd_unit
    save_config_info
    add_cron
    start_and_verify || return 1
    show_config_info
}

update_caddy() {
    local oldbin="/usr/bin/caddy.pre-update.$(date +%s)"
    [[ -f /usr/bin/caddy ]] && cp -a /usr/bin/caddy "$oldbin"

    systemctl stop naive 2>/dev/null || true
    if ! install_dependencies || ! install_caddy || ! write_systemd_unit; then
        _red "更新失败，正在回滚二进制..."
        [[ -f "$oldbin" ]] && cp -f "$oldbin" /usr/bin/caddy && chmod 0755 /usr/bin/caddy
        systemctl restart naive 2>/dev/null || true
        return 1
    fi

    if [[ -f "$CADDY_JSON" ]] && /usr/bin/caddy validate --config "$CADDY_JSON" >/dev/null 2>&1; then
        _green "现有 Caddy 配置校验通过，已完整保留你的自定义路由与出站配置。"
    else
        _yellow "现有配置不兼容新版本或缺失，尝试重新生成默认配置..."
        if load_saved_config; then
            write_default_caddy_config || return 1
        else
            _red "找不到 $AUTOCONFIG，请手动检查 $CADDY_JSON。"
            return 1
        fi
    fi

    start_and_verify || return 1
    show_config_info
}

install_menu() {
    if [[ -x /usr/bin/caddy && -f "$CADDY_JSON" ]]; then
        echo "检测到已安装 NaiveProxy："
        echo "1) 仅更新 Caddy 二进制（保留现有路由和 SOCKS5 配置）"
        echo "2) 全新覆盖安装（重置配置与密码）"
        echo "0) 取消"
        read -r -p "请选择 [0-2]: " c
        case "$c" in
            1) update_caddy ;;
            2) systemctl stop naive 2>/dev/null || true; install_new ;;
            *) return 0 ;;
        esac
    else
        install_new
    fi
}

edit_config() {
    load_saved_config || { _red "未找到已有配置。"; return 1; }

    local v new_port="$naive_port" new_user="$user" new_pass="$password"
    read -r -p "端口 [当前 $naive_port，回车不改]: " v
    if [[ -n "$v" ]]; then valid_port "$v" || { _red "端口无效"; return 1; }; new_port="$v"; fi

    read -r -p "用户名 [当前 $user，回车不改]: " v
    if [[ -n "$v" ]]; then valid_user "$v" || { _red "用户名无效"; return 1; }; new_user="$v"; fi

    read -r -p "密码 [回车不改]: " v
    if [[ -n "$v" ]]; then valid_password "$v" || { _red "密码含不支持字符"; return 1; }; new_pass="$v"; fi

    local auth
    auth="$(json_auth_credential "$new_user" "$new_pass")"

    patch_caddy_json --arg port ":$new_port" --arg auth "$auth" '
        (if .apps.http.servers.srv0? then .apps.http.servers.srv0.listen = [$port] else . end)
        | (.. | objects | select(.handler? == "forward_proxy")) |= (.auth_credentials = [$auth])
    ' || return 1

    naive_port="$new_port"; user="$new_user"; password="$new_pass"
    allow_port
    save_config_info
    start_and_verify || return 1
    show_config_info
}

config_socks5() {
    ensure_tool jq || return 1
    [[ -f "$CADDY_JSON" ]] || { _red "未找到 Caddy 配置文件，请先安装。"; return 1; }

    local cur relay_target
    cur="$(get_current_upstream)"
    relay_target="$(get_relay_target)"
    echo
    _cyan "=========== SOCKS5 住宅出站配置 ==========="
    echo "Caddy 出站: ${cur:-未启用 (VPS 直出)}"
    [[ -n "$relay_target" ]] && echo "实际转发目标: ${relay_target} (经 127.0.0.1:${RELAY_PORT})"
    echo "1) 设置 / 修改 SOCKS5 出站"
    echo "2) 清除 SOCKS5 出站（恢复 VPS 直出）"
    echo "0) 返回"
    read -r -p "请选择 [0-2]: " c

    case "$c" in
        1)
            local s_host s_port s_user s_pass caddy_host caddy_port upstream_url
            read -r -p "SOCKS5 地址 (IP 或域名): " s_host
            [[ -n "$s_host" ]] || { _red "地址不能为空。"; return 1; }
            read -r -p "SOCKS5 端口: " s_port
            valid_any_port "$s_port" || { _red "端口无效。"; return 1; }
            read -r -p "SOCKS5 用户名 (无认证直接回车): " s_user
            if [[ -n "$s_user" ]]; then
                read -r -p "SOCKS5 密码: " s_pass
            fi

            # klzgrad/forwardproxy 仅允许 socks5 连接 localhost，公网地址自动启用本机 socat 中转
            if [[ "$s_host" == "127.0.0.1" || "$s_host" == "localhost" ]]; then
                remove_socks_relay
                caddy_host="$s_host"
                caddy_port="$s_port"
            else
                _cyan "检测到公网地址，正在配置本机 socat 中转 (127.0.0.1:${RELAY_PORT} -> ${s_host}:${s_port})..."
                setup_socks_relay "$s_host" "$s_port" || return 1
                caddy_host="127.0.0.1"
                caddy_port="$RELAY_PORT"
            fi

            if [[ -n "$s_user" ]]; then
                upstream_url="socks5://${s_user}:${s_pass}@${caddy_host}:${caddy_port}"
            else
                upstream_url="socks5://${caddy_host}:${caddy_port}"
            fi

            patch_caddy_json --arg up "$upstream_url" '
                (.. | objects | select(.handler? == "forward_proxy")) |= (. + {upstream: $up})
            ' || return 1

            start_and_verify || return 1
            _green "SOCKS5 出站已生效: ${s_host}:${s_port}"
            ;;
        2)
            patch_caddy_json '
                (.. | objects | select(.handler? == "forward_proxy")) |= del(.upstream)
            ' || return 1
            remove_socks_relay
            start_and_verify || return 1
            _green "已清除 SOCKS5 出站及本机中转，恢复为 VPS 直出。"
            ;;
        *) return 0 ;;
    esac
}

optimize_bbr() {
    cat > /etc/sysctl.d/99-naive-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-naive-bbr.conf
    _green "BBR 与 TCP 网络参数已生效："
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
}

cert_menu() {
    echo "1) 查看证书详情"
    echo "2) 手动续签证书"
    read -r -p "请选择 [1-2]: " c
    case "$c" in
        1) certbot certificates ;;
        2)
            port_80_busy && _yellow "警告：80 端口被占用，standalone 续签可能失败。"
            certbot renew --deploy-hook "systemctl restart naive"
            ;;
    esac
}

shell_renew() {
    local tmp="${SCRIPT_PATH}.new"
    download_file "$SCRIPT_URL" "$tmp" || { _red "脚本下载失败。"; return 1; }
    if ! bash -n "$tmp"; then
        _red "新脚本语法检查失败，已放弃覆盖。"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$SCRIPT_PATH"
    chmod 0755 "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" /usr/bin/naive
    _green "脚本已更新至最新版本，请重新运行 naive。"
}

uninstall_naive() {
    read -r -p "确认卸载 NaiveProxy？(保留 Let's Encrypt 证书) [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0
    systemctl disable --now naive 2>/dev/null || true
    remove_socks_relay
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    (crontab -l 2>/dev/null | grep -vF '/etc/caddy/.renew.sh') | crontab - 2>/dev/null || true
    rm -rf /usr/bin/caddy /usr/bin/naive /etc/caddy "$SCRIPT_PATH" /root/src/naive-caddy
    _green "NaiveProxy 已卸载。"
}

# ======================== 主菜单 ========================
main() {
    while :; do
        echo
        _cyan "========== NaiveProxy 独立管理脚本 =========="
        echo " 1. 安装 / 更新 Caddy (保留自定义路由)"
        echo " 2. 查看配置与状态"
        echo " 3. 修改端口 / 账号密码"
        echo " 4. 配置 SOCKS5 住宅出站"
        echo " 5. 开启原生 BBR 网络优化"
        echo " 6. 证书查看 / 续签"
        echo " 7. 重启 / 停止服务"
        echo " 8. 查看最近日志"
        echo " 9. 更新本脚本"
        echo "10. 卸载 NaiveProxy"
        echo " 0. 退出"
        read -r -p "请选择 [0-10]: " choose
        case "$choose" in
            1) install_menu ;;
            2) systemctl status naive --no-pager -l | head -n 12; show_config_info ;;
            3) edit_config ;;
            4) config_socks5 ;;
            5) optimize_bbr ;;
            6) cert_menu ;;
            7)
                read -r -p "1) 重启  2) 停止: " act
                [[ "$act" == "1" ]] && start_and_verify
                [[ "$act" == "2" ]] && { systemctl stop naive; _yellow "已停止。"; }
                ;;
            8) journalctl -u naive -n 80 --no-pager ;;
            9) shell_renew; exit 0 ;;
            10) uninstall_naive; exit 0 ;;
            0) exit 0 ;;
            *) _red "输入错误。" ;;
        esac
    done
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
