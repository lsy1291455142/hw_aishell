#!/bin/bash
# novnc-browser.sh — noVNC + Firefox + cloudflared tunnel 一键脚本
# 用法:
#   ./novnc-browser.sh install   # 安装所有依赖
#   ./novnc-browser.sh start     # 启动所有服务 + 看门狗保活
#   ./novnc-browser.sh stop      # 停止所有服务 + 看门狗
#   ./novnc-browser.sh restart   # 重启
#   ./novnc-browser.sh status    # 查看状态
#   ./novnc-browser.sh url       # 获取公网URL
#   ./novnc-browser.sh           # 默认: install + start

set -euo pipefail

# 在任何 cd 之前保存脚本所在目录（用于定位 watchdog.sh 等同级文件）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== 配置 ====================
DISPLAY_NUM=99
VNC_PORT=5901
NOVNC_PORT=6080
VNC_PASSWORD="aishell123"
SCREEN_SIZE="1280x900x24"
AISHELL_URL="https://developer.huaweicloud.com/aishell.html"
FIREFOX_PROFILE="/root/firefox-novnc-profile"
LOG_DIR="/root/novnc-logs"
PID_DIR="/root/novnc-pids"
WATCHDOG_INTERVAL=30  # 秒

mkdir -p "$LOG_DIR" "$PID_DIR"

# ==================== 工具函数 ====================
log() { echo "[$(date '+%H:%M:%S')] $*"; }

get_pid() {
    local pidfile="$PID_DIR/$1.pid"
    if [[ -f "$pidfile" ]]; then
        local pid=$(cat "$pidfile" 2>/dev/null || echo 0)
        if [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    echo 0
    return 1
}

save_pid() {
    echo "$2" > "$PID_DIR/$1.pid"
}

clear_pid() {
    rm -f "$PID_DIR/$1.pid"
}

is_running() {
    local pid
    pid=$(get_pid "$1" 2>/dev/null)
    [[ "$pid" -gt 0 ]]
}

# ==================== 安装 ====================
do_install() {
    log "=== 安装依赖 ==="

    # 检查并安装 tmux (看门狗依赖)
    if ! command -v tmux &>/dev/null; then
        log "安装 tmux..."
        yum install -y tmux
    fi

    # 检查并安装 Xvfb
    if ! command -v Xvfb &>/dev/null; then
        log "安装 Xvfb..."
        yum install -y xorg-x11-server-Xvfb
    fi

    # 检查并安装 TigerVNC (x0vncserver)
    if ! command -v x0vncserver &>/dev/null; then
        log "安装 TigerVNC..."
        yum install -y tigervnc-server
    fi

    # 检查并安装 Firefox
    if ! command -v firefox &>/dev/null; then
        log "安装 Firefox..."
        yum install -y firefox
    fi

    # 检查并安装 websockify + noVNC
    if ! command -v websockify &>/dev/null; then
        log "安装 websockify..."
        pip3 install websockify 2>/dev/null || pip install websockify
    fi

    if [[ ! -d /usr/share/novnc ]]; then
        log "安装 noVNC..."
        mkdir -p /usr/share/novnc
        cd /tmp
        if [[ ! -d noVNC ]]; then
            git clone https://github.com/novnc/noVNC.git 2>/dev/null || true
        fi
        if [[ -d noVNC ]]; then
            cp -r noVNC/* /usr/share/novnc/ 2>/dev/null || true
        fi
    fi

    # 检查并安装 cloudflared
    if ! command -v cloudflared &>/dev/null; then
        log "安装 cloudflared..."
        ARCH=$(uname -m)
        if [[ "$ARCH" == "aarch64" ]]; then
            CF_ARCH="arm64"
        else
            CF_ARCH="amd64"
        fi
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
    fi

    log "=== 安装完成 ==="
    log "tmux: $(command -v tmux || echo 'MISSING')"
    log "Xvfb: $(command -v Xvfb || echo 'MISSING')"
    log "x0vncserver: $(command -v x0vncserver || echo 'MISSING')"
    log "firefox: $(command -v firefox || echo 'MISSING')"
    log "websockify: $(command -v websockify || echo 'MISSING')"
    log "cloudflared: $(command -v cloudflared || echo 'MISSING')"

    # 安装登录自动打印 hook
    do_install_login_hook
}

# ==================== 登录 Hook ====================
do_install_login_hook() {
    log "安装登录自动打印 hook..."

    cat > /etc/profile.d/novnc-info.sh << 'HOOKEOF'
# noVNC 登录信息自动打印
_novnc_print_info() {
    local PID_DIR="/root/novnc-pids"
    local VNC_PASSWORD="aishell123"
    local NOVNC_PORT=6080

    # 只在交互式 shell 中打印
    [[ -z "$PS1" ]] && return 0
    # 避免在 tmux 内重复打印
    [[ -n "$TMUX" ]] && return 0

    # 检查是否有 PID 目录
    [[ ! -d "$PID_DIR" ]] && return 0

    # 检查服务是否在运行
    local running=0
    for n in xvfb vnc firefox novnc cloudflared; do
        local pidfile="$PID_DIR/$n.pid"
        if [[ -f "$pidfile" ]]; then
            local pid=$(cat "$pidfile" 2>/dev/null || echo 0)
            if [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
                running=$((running + 1))
            fi
        fi
    done

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          noVNC 远程浏览器服务信息                          ║"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [[ "$running" -ge 5 ]]; then
        echo "║  状态: ✅ 全部运行中 (${running}/5)                         "
    elif [[ "$running" -gt 0 ]]; then
        echo "║  状态: ⚠️  部分运行 (${running}/5)                          "
    else
        echo "║  状态: ❌ 未运行                                            "
    fi

    # 打印公网 URL
    local url=""
    if [[ -f "$PID_DIR/cloudflared-url.txt" ]]; then
        url=$(cat "$PID_DIR/cloudflared-url.txt" 2>/dev/null || echo "")
    fi
    if [[ -z "$url" ]]; then
        url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /root/novnc-logs/cloudflared.log 2>/dev/null | tail -1 || true)
    fi
    if [[ -n "$url" ]]; then
        echo "║  公网URL: $url/vnc.html"
    else
        echo "║  公网URL: (未获取)                                          "
    fi

    echo "║  VNC密码: $VNC_PASSWORD                                      "
    echo "║  noVNC端口: $NOVNC_PORT                                      "
    echo "╠══════════════════════════════════════════════════════════╣"

    # 看门狗状态
    local wd_pid=""
    if [[ -f "$PID_DIR/watchdog.pid" ]]; then
        wd_pid=$(cat "$PID_DIR/watchdog.pid" 2>/dev/null || echo 0)
    fi
    if [[ "$wd_pid" -gt 0 ]] && kill -0 "$wd_pid" 2>/dev/null; then
        echo "║  看门狗: ✅ 运行中 (PID: $wd_pid)                            "
    else
        echo "║  看门狗: ❌ 未运行                                            "
    fi

    echo "╚══════════════════════════════════════════════════════════╝"

    if [[ "$running" -lt 5 ]]; then
        echo "  💡 启动服务: /root/novnc-browser.sh start"
    fi
    if [[ -n "$url" ]]; then
        echo "  💡 浏览器打开上面的公网URL即可远程访问"
    fi
    echo ""
}

_novnc_print_info
HOOKEOF

    log "登录 hook 已安装到 /etc/profile.d/novnc-info.sh"
}

# ==================== 启动单个服务 ====================
start_xvfb() {
    if is_running xvfb; then
        log "Xvfb 已在运行 (PID: $(get_pid xvfb))"
        return 0
    fi

    log "启动 Xvfb :${DISPLAY_NUM}..."
    setsid Xvfb :${DISPLAY_NUM} -screen 0 ${SCREEN_SIZE} -ac -nolisten tcp \
        > "$LOG_DIR/xvfb.log" 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        save_pid xvfb "$pid"
        log "Xvfb 启动成功 (PID: $pid)"
    else
        log "Xvfb 启动失败!"
        return 1
    fi
}

start_vnc() {
    if is_running vnc; then
        log "x0vncserver 已在运行 (PID: $(get_pid vnc))"
        return 0
    fi

    # 设置 VNC 密码
    mkdir -p /root/.vnc
    echo "${VNC_PASSWORD}" | vncpasswd -f > /root/.vnc/passwd 2>/dev/null || true
    chmod 600 /root/.vnc/passwd 2>/dev/null || true

    log "启动 x0vncserver (端口 ${VNC_PORT})..."
    setsid x0vncserver -display :${DISPLAY_NUM} -rfbport ${VNC_PORT} \
        -rfbauth /root/.vnc/passwd -SecurityTypes VncAuth \
        > "$LOG_DIR/vnc.log" 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        save_pid vnc "$pid"
        log "x0vncserver 启动成功 (PID: $pid)"
    else
        log "x0vncserver 启动失败!"
        return 1
    fi
}

start_firefox() {
    if is_running firefox; then
        log "Firefox 已在运行 (PID: $(get_pid firefox))"
        return 0
    fi

    # 确保 Xvfb 在运行
    if ! is_running xvfb; then
        start_xvfb || return 1
    fi

    log "启动 Firefox..."
    export DISPLAY=:${DISPLAY_NUM}

    # 首次运行创建 profile
    if [[ ! -d "$FIREFOX_PROFILE" ]]; then
        log "创建 Firefox profile..."
        setsid firefox --display=:${DISPLAY_NUM} --no-remote \
            -CreateProfile "novnc ${FIREFOX_PROFILE}" \
            > "$LOG_DIR/firefox-profile.log" 2>&1 &
        sleep 3
    fi

    setsid firefox --display=:${DISPLAY_NUM} --no-remote \
        -P novnc --new-instance "${AISHELL_URL}" \
        > "$LOG_DIR/firefox.log" 2>&1 &
    local pid=$!
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        save_pid firefox "$pid"
        log "Firefox 启动成功 (PID: $pid)"
    else
        log "Firefox 启动失败，尝试不带 profile..."
        setsid firefox --display=:${DISPLAY_NUM} --no-remote \
            "${AISHELL_URL}" \
            > "$LOG_DIR/firefox.log" 2>&1 &
        pid=$!
        sleep 3
        if kill -0 "$pid" 2>/dev/null; then
            save_pid firefox "$pid"
            log "Firefox 启动成功 (PID: $pid)"
        else
            log "Firefox 启动失败!"
            return 1
        fi
    fi
}

start_novnc() {
    if is_running novnc; then
        log "noVNC(websockify) 已在运行 (PID: $(get_pid novnc))"
        return 0
    fi

    log "启动 noVNC/websockify (端口 ${NOVNC_PORT})..."
    local novnc_dir="/usr/share/novnc"
    if [[ ! -d "$novnc_dir" ]]; then
        novnc_dir="/usr/local/share/novnc"
    fi

    setsid websockify --web "$novnc_dir" ${NOVNC_PORT} localhost:${VNC_PORT} \
        > "$LOG_DIR/novnc.log" 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        save_pid novnc "$pid"
        log "noVNC 启动成功 (PID: $pid)"
    else
        log "noVNC 启动失败!"
        return 1
    fi
}

start_cloudflared() {
    if is_running cloudflared; then
        log "cloudflared 已在运行 (PID: $(get_pid cloudflared))"
        return 0
    fi

    log "启动 cloudflared 隧道..."
    setsid cloudflared tunnel --url http://localhost:${NOVNC_PORT} \
        > "$LOG_DIR/cloudflared.log" 2>&1 &
    local pid=$!
    save_pid cloudflared "$pid"

    # 等待 URL 出现
    log "等待隧道 URL..."
    local url=""
    for i in $(seq 1 15); do
        sleep 2
        url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | head -1 || true)
        if [[ -n "$url" ]]; then
            break
        fi
    done

    if [[ -n "$url" ]]; then
        echo "$url" > "$PID_DIR/cloudflared-url.txt"
        log "cloudflared 隧道启动成功 (PID: $pid)"
        log "公网 URL: $url"
    else
        log "cloudflared 启动中，URL 未捕获 (PID: $pid)"
        log "查看日志: $LOG_DIR/cloudflared.log"
    fi
}

# ==================== 看门狗 ====================
start_watchdog() {
    if is_running watchdog; then
        log "看门狗已在运行 (PID: $(get_pid watchdog))"
        return 0
    fi

    # 确保 watchdog.sh 存在（使用脚本开头保存的 SCRIPT_DIR，不受 cd 影响）
    local wd_script="${SCRIPT_DIR}/watchdog.sh"
    if [[ ! -f "$wd_script" ]]; then
        log "watchdog.sh 不存在，跳过看门狗"
        return 0
    fi

    log "启动看门狗保活 (tmux detached)..."
    tmux kill-session -t wd 2>/dev/null || true
    tmux new-session -d -s wd "$wd_script"
    sleep 2

    local wpid=$(pgrep -f "watchdog.sh" | head -1)
    if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
        save_pid watchdog "$wpid"
        log "看门狗启动成功 (PID: $wpid)，每 ${WATCHDOG_INTERVAL}s 巡检一次"
    else
        log "看门狗启动失败!"
    fi
}

# ==================== 启动全部 ====================
do_start() {
    log "=== 启动所有服务 ==="

    start_xvfb     || true
    start_vnc      || true
    start_firefox  || true
    start_novnc    || true
    start_cloudflared || true
    start_watchdog

    log "=== 启动完成 ==="
    do_status
}

# ==================== 停止 ====================
do_stop() {
    log "=== 停止所有服务 ==="

    # 先停看门狗 (tmux session)
    tmux kill-session -t wd 2>/dev/null || true

    # 按依赖顺序停
    for name in watchdog cloudflared novnc firefox vnc xvfb; do
        local pid=$(get_pid "$name" 2>/dev/null)
        if [[ "$pid" -gt 0 ]]; then
            log "停止 $name (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        clear_pid "$name"
    done

    # 清理残留
    pkill -f "Xvfb :${DISPLAY_NUM}" 2>/dev/null || true
    pkill -f "x0vncserver.*:${VNC_PORT}" 2>/dev/null || true
    pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
    pkill -f "cloudflared tunnel.*${NOVNC_PORT}" 2>/dev/null || true
    pkill -f "firefox.*display=:${DISPLAY_NUM}" 2>/dev/null || true

    log "=== 已停止 ==="
}

# ==================== 状态 ====================
do_status() {
    echo "========================================"
    echo "  noVNC Browser 服务状态"
    echo "========================================"
    for name in xvfb vnc firefox novnc cloudflared watchdog; do
        local pid=$(get_pid "$name" 2>/dev/null)
        if [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
            printf "  %-12s ✅ 运行中 (PID: %s)\n" "$name" "$pid"
        else
            printf "  %-12s ❌ 未运行\n" "$name"
        fi
    done
    echo "========================================"

    local url=$(cat "$PID_DIR/cloudflared-url.txt" 2>/dev/null || echo "")
    if [[ -n "$url" ]]; then
        echo "  公网URL: $url/vnc.html"
    else
        echo "  公网URL: (未获取)"
    fi
    echo "========================================"
}

# ==================== URL ====================
do_url() {
    local url=$(cat "$PID_DIR/cloudflared-url.txt" 2>/dev/null || echo "")
    if [[ -n "$url" ]]; then
        echo "$url/vnc.html"
    else
        # 尝试从日志提取
        url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -1 || true)
        if [[ -n "$url" ]]; then
            echo "$url/vnc.html"
        else
            echo "URL 未找到，请先运行 start"
            return 1
        fi
    fi
}

# ==================== 主入口 ====================
case "${1:-default}" in
    install)
        do_install
        ;;
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        sleep 2
        do_start
        ;;
    status)
        do_status
        ;;
    url)
        do_url
        ;;
    default)
        do_install
        do_start
        ;;
    *)
        echo "用法: $0 {install|start|stop|restart|status|url}"
        echo "  无参数 = install + start"
        exit 1
        ;;
esac
