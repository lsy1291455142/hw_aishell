#!/bin/bash
set -euo pipefail

# ============================================================
#  Cloudflared Quick Tunnel SSH Setup Script
# ============================================================

LOG_PREFIX="[cloudflared-setup]"
TUNNEL_LOG="/var/log/cloudflared-tunnel.log"
TMUX_SESSION="cloudflared-tunnel"
TUNNEL_URL=""

log_info()  { echo "$LOG_PREFIX INFO  $*"; }
log_warn()  { echo "$LOG_PREFIX WARN  $*"; }
log_error() { echo "$LOG_PREFIX ERROR $*"; }
log_step()  { echo "$LOG_PREFIX ----> $*"; }

# ------------------------------------------------------------
# Block 1: System update & Install tmux & cloudflared
# ------------------------------------------------------------
block1_install_deps() {
    log_step "Block 1: System update & Install tmux & cloudflared"

    # 1.1 yum update
    log_info "Running yum update ..."
    sudo yum update -y

    # 1.2 Install tmux
    log_info "Installing tmux ..."
    sudo yum install -y tmux

    # 1.3 Add cloudflared repo
    log_info "Adding cloudflared.repo to /etc/yum.repos.d/ ..."
    curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo > /dev/null

    # 1.4 Update repo metadata
    log_info "Updating repo metadata ..."
    sudo yum update -y

    # 1.5 Install cloudflared
    log_info "Installing cloudflared ..."
    sudo yum install -y cloudflared

    # Verify
    command -v tmux &>/dev/null       && log_info "tmux installed: $(tmux -V)"       || { log_error "tmux installation failed!";       return 1; }
    command -v cloudflared &>/dev/null && log_info "cloudflared installed: $(cloudflared --version 2>&1 | head -1)" || { log_error "cloudflared installation failed!"; return 1; }
}

# ------------------------------------------------------------
# Block 2: Configure sshd for password & root login
# ------------------------------------------------------------
block2_configure_sshd() {
    log_step "Block 2: Configure sshd (PasswordAuthentication & PermitRootLogin)"

    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "$sshd_config" ]]; then
        log_error "$sshd_config not found!"
        return 1
    fi

    # Backup original config
    log_info "Backing up $sshd_config -> ${sshd_config}.bak"
    sudo cp "$sshd_config" "${sshd_config}.bak"

    # PasswordAuthentication yes
    if grep -qP '^#?\s*PasswordAuthentication' "$sshd_config"; then
        log_info "Setting PasswordAuthentication yes"
        sudo sed -i 's/^#\?\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
    else
        log_info "Appending PasswordAuthentication yes"
        echo "PasswordAuthentication yes" | sudo tee -a "$sshd_config" > /dev/null
    fi

    # PermitRootLogin yes
    if grep -qP '^#?\s*PermitRootLogin' "$sshd_config"; then
        log_info "Setting PermitRootLogin yes"
        sudo sed -i 's/^#\?\s*PermitRootLogin.*/PermitRootLogin yes/' "$sshd_config"
    else
        log_info "Appending PermitRootLogin yes"
        echo "PermitRootLogin yes" | sudo tee -a "$sshd_config" > /dev/null
    fi

    # Restart sshd
    log_info "Restarting sshd ..."
    if systemctl status sshd &>/dev/null; then
        sudo systemctl restart sshd
    elif service ssh status &>/dev/null; then
        sudo service ssh restart
    else
        sudo kill -HUP "$(cat /var/run/sshd.pid 2>/dev/null || pgrep -x sshd | head -1)" 2>/dev/null \
            && log_info "Sent SIGHUP to sshd" \
            || log_warn "Could not restart sshd automatically, please restart manually"
    fi

    log_info "sshd config updated and service restarted"
}

# ------------------------------------------------------------
# Block 3: Set root password
# ------------------------------------------------------------
block3_set_root_password() {
    log_step "Block 3: Set root password"

    local new_password=""
    if [[ -n "${1:-}" ]]; then
        new_password="$1"
    else
        # Interactive prompt
        read -rsp "Enter new root password: " new_password
        echo
        if [[ -z "$new_password" ]]; then
            log_error "Password cannot be empty!"
            return 1
        fi
        local confirm=""
        read -rsp "Confirm new root password: " confirm
        echo
        if [[ "$new_password" != "$confirm" ]]; then
            log_error "Passwords do not match!"
            return 1
        fi
    fi

    log_info "Setting root password ..."
    echo "root:${new_password}" | sudo chpasswd
    log_info "Root password updated successfully"
}

# ------------------------------------------------------------
# Block 4: Start cloudflared tunnel in tmux & capture URL
# ------------------------------------------------------------
block4_start_tunnel() {
    log_step "Block 4: Start cloudflared tunnel in tmux"

    # Kill existing session if any
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_warn "Killing existing tmux session '$TMUX_SESSION' ..."
        tmux kill-session -t "$TMUX_SESSION"
    fi

    # Create log file
    sudo touch "$TUNNEL_LOG"
    sudo chmod 644 "$TUNNEL_LOG"

    # Start cloudflared in tmux, redirect output to log file
    log_info "Starting cloudflared tunnel in tmux session '$TMUX_SESSION' ..."
    tmux new-session -d -s "$TMUX_SESSION" \
        "cloudflared tunnel --url ssh://localhost:22 2>&1 | tee $TUNNEL_LOG"

    # Wait for the trycloudflare.com URL to appear in the log
    log_info "Waiting for tunnel URL (timeout 30s) ..."
    local url=""
    for i in $(seq 1 30); do
        sleep 1
        url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        if [[ -n "$url" ]]; then
            break
        fi
    done

    if [[ -z "$url" ]]; then
        log_error "Failed to capture tunnel URL within 30s. Check $TUNNEL_LOG for details."
        log_warn "You can manually check: tmux attach -t $TMUX_SESSION"
        return 1
    fi

    TUNNEL_URL="$url"

    # Generate a random high port for client local proxy
    local client_port=$(( RANDOM % 20000 + 40000 ))

    echo ""
    echo "============================================================"
    log_info "Tunnel is UP!"
    log_info "Public URL:  $TUNNEL_URL"
    log_info "Tmux session: tmux attach -t $TMUX_SESSION"
    log_info "Tunnel log:   $TUNNEL_LOG"
    echo "============================================================"
    echo ""
    echo "---------- Windows 客户端 ----------"
    echo "1) 开本地代理:"
    echo "   cloudflared.exe access ssh --hostname ${TUNNEL_URL#https://} --url localhost:${client_port}"
    echo ""
    echo "2) 另开终端连接:"
    echo "   ssh root@localhost -p ${client_port}"
    echo ""
    echo "---------- Linux / macOS 客户端 ----------"
    echo "1) 开本地代理:"
    echo "   cloudflared access ssh --hostname ${TUNNEL_URL#https://} --url localhost:${client_port}"
    echo ""
    echo "2) 另开终端连接:"
    echo "   ssh root@localhost -p ${client_port}"
    echo ""
    echo "---------- 或者用 ProxyCommand 一行直连 ----------"
    echo "   ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@${TUNNEL_URL#https://}"
    echo ""
    echo "============================================================"
}

# ============================================================
# Main
# ============================================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --password <PASS>  Set root password (non-interactive)"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Without -p, you will be prompted for the root password."
}

main() {
    local root_password=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--password)
                root_password="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Starting setup ..."

    block1_install_deps
    block2_configure_sshd
    block3_set_root_password "$root_password"
    block4_start_tunnel

    log_info "All done!"
}

main "$@"
