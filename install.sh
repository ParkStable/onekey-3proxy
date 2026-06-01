#!/bin/bash
set -e

USER="${1:-admin}"
PASS="${2:-changeme}"
HTTP_PORT="${3:-8080}"
SOCKS_PORT="${4:-1080}"

# 从源码编译
cd /tmp
wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.6.tar.gz
tar xf 0.9.6.tar.gz && cd 3proxy-0.9.6
make -f Makefile.Linux
make -f Makefile.Linux install

mkdir -p /etc/3proxy /var/log

cat > /etc/3proxy/3proxy.cfg << EOF
log /var/log/3proxy.log D
auth strong
users ${USER}:CL:${PASS}
proxy -p${HTTP_PORT} -a
socks -p${SOCKS_PORT} -a
EOF

# systemd 服务
cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 3proxy

# 放行端口
ufw allow ${HTTP_PORT}/tcp 2>/dev/null || true
ufw allow ${SOCKS_PORT}/tcp 2>/dev/null || true
iptables -I INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport ${SOCKS_PORT} -j ACCEPT 2>/dev/null || true

IP=$(curl -s ip.gs || curl -s ifconfig.me)
echo ""
echo "✓ 安装完成"
echo "HTTP:   curl -x http://${USER}:${PASS}@${IP}:${HTTP_PORT} https://ip.gs"
echo "SOCKS5: curl --socks5-hostname ${USER}:${PASS}@${IP}:${SOCKS_PORT} https://ip.gs"