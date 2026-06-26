#!/bin/bash
set -euo pipefail

# ============================================================
#  Cloudflared 快速隧道 SSH 一键部署脚本
# ============================================================

# 颜色定义
RST='\033[0m'
BOLD='\033[1m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
WHITE='\033[37m'
BG_GREEN='\033[42m'
BG_BLUE='\033[44m'
BG_RED='\033[41m'

LOG_PREFIX=""

log_info()  { echo -e "${GREEN}${LOG_PREFIX}信息  ${RST}$*"; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX}警告  ${RST}$*"; }
log_error() { echo -e "${RED}${LOG_PREFIX}错误  ${RST}$*"; }
log_step()  { echo -e "${BOLD}${CYAN}${LOG_PREFIX}----> ${RST}${BOLD}$*${RST}"; }

TUNNEL_LOG="/var/log/cloudflared-tunnel.log"
TMUX_SESSION="cloudflared-tunnel"
TUNNEL_URL=""
PASTEBIN_URL=""
ROOT_PW=""

# ------------------------------------------------------------
# 功能块 1: 系统更新 & 安装 tmux & cloudflared
# ------------------------------------------------------------
step1_install_deps() {
    log_step "功能块 1: 系统更新 & 安装 tmux & cloudflared"

    log_info "正在执行 yum update ..."
    sudo yum update -y

    log_info "正在安装 tmux ..."
    sudo yum install -y tmux

    log_info "正在添加 cloudflared 软件源 ..."
    curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo > /dev/null

    log_info "正在更新软件源元数据 ..."
    sudo yum update -y

    log_info "正在安装 cloudflared ..."
    sudo yum install -y cloudflared

    # 验证安装结果
    command -v tmux &>/dev/null       && log_info "tmux 已安装: $(tmux -V)"       || { log_error "tmux 安装失败！";       return 1; }
    command -v cloudflared &>/dev/null && log_info "cloudflared 已安装: $(cloudflared --version 2>&1 | head -1)" || { log_error "cloudflared 安装失败！"; return 1; }
}

# ------------------------------------------------------------
# 功能块 2: 配置 sshd 允许密码登录 & root 登录
# ------------------------------------------------------------
step2_configure_sshd() {
    log_step "功能块 2: 配置 sshd (PasswordAuthentication & PermitRootLogin)"

    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "$sshd_config" ]]; then
        log_error "未找到 $sshd_config！"
        return 1
    fi

    log_info "备份 $sshd_config -> ${sshd_config}.bak"
    sudo cp "$sshd_config" "${sshd_config}.bak"

    # PasswordAuthentication yes
    if grep -qP '^#?\s*PasswordAuthentication' "$sshd_config"; then
        log_info "设置 PasswordAuthentication yes"
        sudo sed -i 's/^#\?\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
    else
        log_info "追加 PasswordAuthentication yes"
        echo "PasswordAuthentication yes" | sudo tee -a "$sshd_config" > /dev/null
    fi

    # PermitRootLogin yes
    if grep -qP '^#?\s*PermitRootLogin' "$sshd_config"; then
        log_info "设置 PermitRootLogin yes"
        sudo sed -i 's/^#\?\s*PermitRootLogin.*/PermitRootLogin yes/' "$sshd_config"
    else
        log_info "追加 PermitRootLogin yes"
        echo "PermitRootLogin yes" | sudo tee -a "$sshd_config" > /dev/null
    fi

    log_info "sshd 配置已更新"
}

# ------------------------------------------------------------
# 功能块 3: 设置 root 密码（随机密码 / 自定义）
# ------------------------------------------------------------
step3_set_root_password() {
    log_step "功能块 3: 设置 root 密码"

    # 生成随机密码：大小写字母+数字，16位
    local rand_pw
    rand_pw=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16) || true

    echo ""
    echo -e "已生成随机密码: ${BOLD}${GREEN}${rand_pw}${RST}"
    echo ""
    read -rp "直接回车使用随机密码，或输入自定义密码: " user_input

    local final_pw
    if [[ -z "$user_input" ]]; then
        final_pw="$rand_pw"
        log_info "使用随机密码"
    else
        final_pw="$user_input"
        log_info "使用自定义密码"
    fi

    # 临时禁用 PAM 密码复杂度规则
    local pam_files=()
    for f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-password; do
        if [[ -f "$f" ]]; then pam_files+=("$f"); fi
    done

    log_info "临时禁用 PAM 密码复杂度规则 ..."
    for f in "${pam_files[@]}"; do
        sudo sed -i 's/^\(password.*pam_pwquality\.so\)/#\1/' "$f"
        sudo sed -i 's/^\(password.*pam_cracklib\.so\)/#\1/' "$f"
        sudo sed -i 's/^\(password.*pam_pwhistory\.so\)/#\1/' "$f"
        sudo sed -i 's/use_authtok//' "$f"
    done

    # 设置密码
    log_info "设置 root 密码 ..."
    echo "root:${final_pw}" | sudo chpasswd

    # 恢复 PAM 规则
    log_info "恢复 PAM 密码复杂度规则 ..."
    for f in "${pam_files[@]}"; do
        sudo sed -i 's/^#\(password.*pam_pwquality\.so\)/\1/' "$f"
        sudo sed -i 's/^#\(password.*pam_cracklib\.so\)/\1/' "$f"
        sudo sed -i 's/^#\(password.*pam_pwhistory\.so\)/\1/' "$f"
        sudo sed -i 's/\(pam_unix\.so.*sha512.*shadow.*nullok.*try_first_pass\)/\1 use_authtok/' "$f"
    done

    echo -e "root 密码已设置: ${BOLD}${YELLOW}${final_pw}${RST}"
    ROOT_PW="$final_pw"
}

# ------------------------------------------------------------
# 功能块 4: 在 tmux 中启动隧道 & 捕获公网地址
# ------------------------------------------------------------
step4_start_tunnel() {
    log_step "功能块 4: 在 tmux 中启动 cloudflared 隧道"

    # 关闭已有会话
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_warn "关闭已有的 tmux 会话 '$TMUX_SESSION' ..."
        tmux kill-session -t "$TMUX_SESSION"
    fi

    # 创建日志文件
    sudo touch "$TUNNEL_LOG"
    sudo chmod 644 "$TUNNEL_LOG"

    # 在 tmux 中启动 cloudflared
    log_info "在 tmux 会话 '$TMUX_SESSION' 中启动 cloudflared 隧道 ..."
    tmux new-session -d -s "$TMUX_SESSION" \
        "cloudflared tunnel --url ssh://localhost:22 2>&1 | tee $TUNNEL_LOG"

    # 等待 trycloudflare.com 地址出现
    log_info "正在等待隧道公网地址（超时 30 秒）..."
    local url=""
    for i in $(seq 1 30); do
        sleep 1
        url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        if [[ -n "$url" ]]; then
            break
        fi
    done

    if [[ -z "$url" ]]; then
        log_error "30 秒内未获取到隧道地址，请查看日志: $TUNNEL_LOG"
        log_warn "可手动查看: tmux attach -t $TMUX_SESSION"
        return 1
    fi

    TUNNEL_URL="$url"
}

# ------------------------------------------------------------
# 功能块 5: 生成连接指引 & 上传 Pastebin & 提示
# ------------------------------------------------------------
step5_show_guide() {
    log_step "功能块 5: 生成连接指引并上传 Pastebin"

    local host=${TUNNEL_URL#https://}
    local client_port=$(( RANDOM % 20000 + 40000 ))

    # 构建纯文本指引（用于终端显示和 Pastebin 上传）
    local guide=""
    guide+="========================================\n"
    guide+="  Cloudflared 隧道 SSH 连接指引\n"
    guide+="========================================\n"
    guide+="\n"
    guide+="公网地址: ${TUNNEL_URL}\n"
    guide+="root 密码: ${ROOT_PW}\n"
    guide+="\n"
    guide+="1. 本地电脑先安装 cloudflared：\n"
    guide+="   前往 https://github.com/cloudflare/cloudflared/releases\n"
    guide+="   下载对应系统的版本并安装\n"
    guide+="\n"
    guide+="2. 使用以下命令连接：\n"
    guide+="\n"
    guide+="--- 方式一：两步连接（支持 SSH 和 SFTP）---\n"
    guide+="\n"
    guide+="Windows:\n"
    guide+="  第一步 开本地代理：\n"
    guide+="  cloudflared.exe access ssh --hostname ${host} --url localhost:${client_port}\n"
    guide+="  第二步 另开终端连接：\n"
    guide+="  ssh   root@localhost -p ${client_port}\n"
    guide+="  sftp  root@localhost -P ${client_port}\n"
    guide+="\n"
    guide+="Linux / macOS:\n"
    guide+="  第一步 开本地代理：\n"
    guide+="  cloudflared access ssh --hostname ${host} --url localhost:${client_port}\n"
    guide+="  第二步 另开终端连接：\n"
    guide+="  ssh   root@localhost -p ${client_port}\n"
    guide+="  sftp  -P ${client_port} root@localhost\n"
    guide+="\n"
    guide+="--- 方式二：ProxyCommand 一键直连 ---\n"
    guide+="\n"
    guide+="Windows:\n"
    guide+="  ssh -o ProxyCommand=\"cloudflared.exe access ssh --hostname %h\" root@${host}\n"
    guide+="\n"
    guide+="Linux / macOS:\n"
    guide+="  ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@${host}\n"
    guide+="\n"
    guide+="========================================\n"

    # 终端彩色显示
    echo ""
    echo -e "${BG_GREEN}${BOLD}${WHITE}  隧道已启动！  ${RST}"
    echo ""
    echo -e "  ${CYAN}公网地址:${RST}    ${BOLD}${GREEN}${TUNNEL_URL}${RST}"
    echo -e "  ${CYAN}root 密码:${RST}    ${BOLD}${YELLOW}${ROOT_PW}${RST}"
    echo -e "  ${CYAN}tmux 会话:${RST}   tmux attach -t ${TMUX_SESSION}"
    echo -e "  ${CYAN}隧道日志:${RST}    ${TUNNEL_LOG}"
    echo ""
    echo -e "${BG_BLUE}${BOLD}${WHITE}  客户端连接指引  ${RST}"
    echo ""
    echo -e "  ${YELLOW}1.${RST} ${WHITE}本地电脑先安装 cloudflared：${RST}"
    echo -e "     前往 ${CYAN}https://github.com/cloudflare/cloudflared/releases${RST}"
    echo -e "     下载对应系统的版本并安装"
    echo ""
    echo -e "  ${YELLOW}2.${RST} ${WHITE}使用以下命令连接：${RST}"
    echo ""
    echo -e "  ${BOLD}--- 方式一：两步连接（支持 SSH 和 SFTP）---${RST}"
    echo ""
    echo -e "  ${BLUE}Windows:${RST}"
    echo -e "    第一步 开本地代理："
    echo -e "    ${GREEN}cloudflared.exe access ssh --hostname ${host} --url localhost:${client_port}${RST}"
    echo -e "    第二步 另开终端连接："
    echo -e "    ${GREEN}ssh   root@localhost -p ${client_port}${RST}"
    echo -e "    ${GREEN}sftp  root@localhost -P ${client_port}${RST}"
    echo ""
    echo -e "  ${BLUE}Linux / macOS:${RST}"
    echo -e "    第一步 开本地代理："
    echo -e "    ${GREEN}cloudflared access ssh --hostname ${host} --url localhost:${client_port}${RST}"
    echo -e "    第二步 另开终端连接："
    echo -e "    ${GREEN}ssh   root@localhost -p ${client_port}${RST}"
    echo -e "    ${GREEN}sftp  -P ${client_port} root@localhost${RST}"
    echo ""
    echo -e "  ${BOLD}--- 方式二：ProxyCommand 一键直连 ---${RST}"
    echo ""
    echo -e "  ${BLUE}Windows:${RST}"
    echo -e "    ${GREEN}ssh -o ProxyCommand=\"cloudflared.exe access ssh --hostname %h\" root@${host}${RST}"
    echo ""
    echo -e "  ${BLUE}Linux / macOS:${RST}"
    echo -e "    ${GREEN}ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@${host}${RST}"
    echo ""

    # 上传到 paste.rs（Hastebin 兼容的轻量 Pastebin）
    log_info "正在上传连接指引到 paste.rs ..."
    local paste_url
    paste_url=$(echo -e "$guide" | curl -sS --connect-timeout 10 \
        -X POST "https://paste.rs" --data-binary @- 2>/dev/null) || true

    if [[ -n "$paste_url" && "$paste_url" == https://paste.rs/* ]]; then
        PASTEBIN_URL="$paste_url"
    fi

    echo ""
    echo -e "${BG_RED}${BOLD}${WHITE}  ⚠ 重要提醒  ${RST}"
    echo ""
    if [[ -n "$PASTEBIN_URL" ]]; then
        echo -e "  ${BOLD}${YELLOW}下一步将重启 sshd，重启后当前 SSH 会话会断开，${RST}"
        echo -e "  ${BOLD}${YELLOW}终端上的内容将无法复制！${RST}"
        echo ""
        echo -e "  ${BOLD}${WHITE}连接指引已上传到 paste.rs，请在重启前保存以下链接：${RST}"
        echo ""
        echo -e "  ${BOLD}${GREEN}👉 ${PASTEBIN_URL}${RST}"
        echo ""
        echo -e "  ${WHITE}断开后可随时访问该链接查看连接命令和密码。${RST}"
    else
        echo -e "  ${BOLD}${YELLOW}下一步将重启 sshd，重启后当前 SSH 会话会断开，${RST}"
        echo -e "  ${BOLD}${YELLOW}请务必先记录上方的连接信息！${RST}"
        log_warn "paste.rs 上传失败，请手动复制上方指引。"
    fi
    echo ""
}

# ------------------------------------------------------------
# 功能块 6: 重启 sshd（pkill）— 最后执行，需回车确认
# ------------------------------------------------------------
step6_restart_sshd() {
    log_step "功能块 6: 重启 sshd"

    echo ""
    log_warn "即将执行 pkill -f sshd 重启 sshd，当前 SSH 会话将断开！"
    read -rp "按回车确认重启 sshd，Ctrl+C 取消 ... " _

    log_info "正在终止 sshd ..."
    sudo pkill -f sshd

    sleep 1
    log_info "正在启动 sshd ..."
    sudo /usr/sbin/sshd

    log_info "sshd 已重启"
}

# ============================================================
# 主流程
# ============================================================
show_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -p, --password <密码>  直接指定 root 密码（非交互）"
    echo "  -h, --help            显示帮助"
    echo ""
    echo "不带 -p 则交互式设置密码（回车使用随机密码）。"
}

main() {
    local root_password=""
    ROOT_PW=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--password)
                root_password="${2:-}"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    log_info "开始部署 ..."

    step1_install_deps
    step2_configure_sshd

    if [[ -n "$root_password" ]]; then
        # 临时禁用 PAM 密码复杂度规则
        local pam_files=()
        for f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-password; do
            if [[ -f "$f" ]]; then pam_files+=("$f"); fi
        done
        log_info "临时禁用 PAM 密码复杂度规则 ..."
        for f in "${pam_files[@]}"; do
            sudo sed -i 's/^\(password.*pam_pwquality\.so\)/#\1/' "$f"
            sudo sed -i 's/^\(password.*pam_cracklib\.so\)/#\1/' "$f"
            sudo sed -i 's/^\(password.*pam_pwhistory\.so\)/#\1/' "$f"
            sudo sed -i 's/use_authtok//' "$f"
        done
        echo "root:${root_password}" | sudo chpasswd
        log_info "恢复 PAM 密码复杂度规则 ..."
        for f in "${pam_files[@]}"; do
            sudo sed -i 's/^#\(password.*pam_pwquality\.so\)/\1/' "$f"
            sudo sed -i 's/^#\(password.*pam_cracklib\.so\)/\1/' "$f"
            sudo sed -i 's/^#\(password.*pam_pwhistory\.so\)/\1/' "$f"
            sudo sed -i 's/\(pam_unix\.so.*sha512.*shadow.*nullok.*try_first_pass\)/\1 use_authtok/' "$f"
        done
        echo -e "root 密码已设置（通过参数传入）: ${BOLD}${YELLOW}${root_password}${RST}"
        ROOT_PW="$root_password"
    else
        step3_set_root_password
    fi

    step4_start_tunnel
    step5_show_guide
    step6_restart_sshd

    echo ""
    echo -e "${BG_GREEN}${BOLD}${WHITE}  全部完成！  ${RST}"
}

main "$@"
