#!/bin/bash
# watchdog.sh — 看门狗保活，每30s巡检，自动重启挂掉的进程

INTERVAL=30
PID_DIR="/root/novnc-pids"
LOG_DIR="/root/novnc-logs"
DISPLAY_NUM=99
VNC_PORT=5901
NOVNC_PORT=6080
SCREEN_SIZE="1280x900x24"
AISHELL_URL="https://aishell.huaweicloud.com"

mkdir -p "$PID_DIR" "$LOG_DIR"

wlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $*" >> "$LOG_DIR/watchdog.log"; }

check_and_restart() {
    local name="$1"
    local pidfile="$PID_DIR/$name.pid"
    local pid=0
    [[ -f "$pidfile" ]] && pid=$(cat "$pidfile" 2>/dev/null || echo 0)

    if [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    wlog "$name 进程不存在 (PID=$pid)，尝试重启..."
    rm -f "$pidfile"

    case "$name" in
        xvfb)
            setsid Xvfb :${DISPLAY_NUM} -screen 0 ${SCREEN_SIZE} -ac -nolisten tcp \
                > "$LOG_DIR/xvfb.log" 2>&1 &
            echo $! > "$pidfile"
            sleep 1
            ;;
        vnc)
            setsid x0vncserver -display :${DISPLAY_NUM} -rfbport ${VNC_PORT} \
                -rfbauth /root/.vnc/passwd -SecurityType VncAuth \
                > "$LOG_DIR/vnc.log" 2>&1 &
            echo $! > "$pidfile"
            sleep 1
            ;;
        firefox)
            export DISPLAY=:${DISPLAY_NUM}
            setsid firefox --display=:${DISPLAY_NUM} --no-remote \
                -P novnc --new-instance "${AISHELL_URL}" \
                > "$LOG_DIR/firefox.log" 2>&1 &
            echo $! > "$pidfile"
            sleep 3
            ;;
        novnc)
            local novnc_dir="/usr/share/novnc"
            [[ ! -d "$novnc_dir" ]] && novnc_dir="/usr/local/share/novnc"
            setsid websockify --web "$novnc_dir" ${NOVNC_PORT} localhost:${VNC_PORT} \
                > "$LOG_DIR/novnc.log" 2>&1 &
            echo $! > "$pidfile"
            sleep 1
            ;;
        cloudflared)
            setsid cloudflared tunnel --url http://localhost:${NOVNC_PORT} \
                > "$LOG_DIR/cloudflared.log" 2>&1 &
            echo $! > "$pidfile"
            sleep 5
            local url=""
            for i in $(seq 1 10); do
                sleep 2
                url=$(grep -oP "https://[a-z0-9-]+\.trycloudflare\.com" "$LOG_DIR/cloudflared.log" 2>/dev/null | head -1 || true)
                [[ -n "$url" ]] && break
            done
            if [[ -n "$url" ]]; then
                echo "$url" > "$PID_DIR/cloudflared-url.txt"
                wlog "cloudflared 重启成功，新URL: $url"
            else
                wlog "cloudflared 重启但URL未捕获"
            fi
            ;;
    esac

    local newpid=$(cat "$pidfile" 2>/dev/null || echo 0)
    if [[ "$newpid" -gt 0 ]] && kill -0 "$newpid" 2>/dev/null; then
        wlog "$name 重启成功 (PID: $newpid)"
    else
        wlog "$name 重启失败!"
    fi
}

wlog "看门狗启动，巡检间隔 ${INTERVAL}s"

while true; do
    sleep $INTERVAL

    check_and_restart xvfb
    check_and_restart vnc
    check_and_restart firefox
    check_and_restart novnc
    check_and_restart cloudflared

    alive=0
    for n in xvfb vnc firefox novnc cloudflared; do
        p=$(cat "$PID_DIR/$n.pid" 2>/dev/null || echo 0)
        if [[ "$p" -gt 0 ]] && kill -0 "$p" 2>/dev/null; then
            alive=$((alive + 1))
        fi
    done
    wlog "巡检完成: ${alive}/5 进程存活"
done
