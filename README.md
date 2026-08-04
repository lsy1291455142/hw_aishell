# hw_aishell — AI Shell 保活方案

在华为云 AI Shell 容器上通过 noVNC 远程浏览器 + cloudflared 隧道保持会话心跳，防止容器因 1 小时断连被销毁重建。

## 文件说明

| 文件 | 作用 |
|------|------|
| `novnc-browser.sh` | 主脚本：安装依赖、启动/停止/重启服务、查看状态、获取公网URL |
| `watchdog.sh` | 看门狗：每 30s 巡检，自动重启挂掉的进程 |

## 快速使用

```bash
./novnc-browser.sh          # 一键安装+启动（全新容器只需这一条命令）
./novnc-browser.sh install  # 安装 tmux + Xvfb + TigerVNC + Firefox + websockify + noVNC + cloudflared
./novnc-browser.sh start    # 启动所有服务 + 看门狗保活
./novnc-browser.sh status   # 查看运行状态
./novnc-browser.sh url      # 获取公网 URL
./novnc-browser.sh stop     # 停止所有服务
./novnc-browser.sh restart  # 重启
```

## 工作原理

1. Xvfb 创建虚拟显示 :99
2. Firefox 在虚拟显示中打开 AI Shell 页面
3. x0vncserver 将虚拟显示转为 VNC 流（端口 5901）
4. websockify + noVNC 将 VNC 转为 WebSocket（端口 6080）
5. cloudflared 隧道暴露公网 URL
6. watchdog 每 30s 检查所有进程，挂了自动拉起

## 登录自动打印

install 时自动安装 /etc/profile.d/novnc-info.sh，每次 SSH 登录自动显示当前公网 URL、VNC 密码、服务状态。

## 注意事项

- cloudflared 隧道 URL 是临时的，每次 start 或隧道重启会变
- 容器被重建后需重新执行 ./novnc-browser.sh 并重新登录
- 适用于华为云 EulerOS 2.0 (aarch64)
