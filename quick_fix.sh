#!/bin/bash

# 快速修复脚本
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo "========================================"
echo "VMware IaaS Platform 快速修复"
echo "========================================"

# 1. 创建缺失的 nginx/conf.d/default.conf
log_info "创建 nginx/conf.d/default.conf..."
cat > nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;

    # 安全头
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # 日志
    access_log /var/log/nginx/vmware-iaas.access.log;
    error_log /var/log/nginx/vmware-iaas.error.log;

    # API代理
    location /api/ {
        proxy_pass http://app:5000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # 超时配置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 缓冲配置
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }

    # 静态文件
    location /static/ {
        alias /usr/share/nginx/html/static/;
        expires 1d;
        add_header Cache-Control "public, immutable";
        
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
            expires 1y;
        }
    }

    # 主页面代理
    location / {
        proxy_pass http://app:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # 健康检查
    location /health {
        proxy_pass http://app:5000/api/health;
        access_log off;
    }

    # 禁止访问敏感文件
    location ~ /\.(ht|env|git) {
        deny all;
        return 404;
    }
}
EOF
log_success "✓ nginx/conf.d/default.conf 已创建"

# 2. 设置脚本文件可执行权限
log_info "设置脚本文件可执行权限..."
chmod +x init_database.py
chmod +x scheduler.py
chmod +x backup_manager.py
log_success "✓ 脚本权限已设置"

# 3. 生成安全的环境变量
log_info "生成安全的环境变量..."

# 生成随机密码
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
SECRET_KEY=$(openssl rand -base64 64 | tr -d "\n")
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-12)

# 更新 .env 文件中的密码
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" .env
sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" .env
sed -i "s/SECRET_KEY=.*/SECRET_KEY=$SECRET_KEY/" .env
sed -i "s/GRAFANA_PASSWORD=.*/GRAFANA_PASSWORD=$GRAFANA_PASSWORD/" .env

log_success "✓ 安全密码已生成"

# 4. 显示需要手动配置的项目
echo ""
echo "========================================"
echo "需要手动配置的环境变量"
echo "========================================"
echo "请编辑 .env 文件，配置以下实际环境参数："
echo ""
echo "🔧 LDAP配置:"
echo "   LDAP_SERVER=ldap://your-ldap-server.com:389"
echo "   LDAP_BASE_DN=dc=company,dc=com"
echo "   LDAP_ADMIN_DN=cn=admin,dc=company,dc=com"
echo "   LDAP_ADMIN_PASSWORD=your_ldap_admin_password"
echo ""
echo "🔧 VMware vCenter配置:"
echo "   VCENTER_HOST=10.0.200.100"
echo "   VCENTER_USER=administrator@vsphere.local"
echo "   VCENTER_PASSWORD=Leinao@323"
echo ""
echo "🔧 邮件服务器配置 (可选):"
echo "   SMTP_SERVER=smtphz.qiye.163.com"
echo "   SMTP_USERNAME=opsadmin@leinao.ai"
echo "   SMTP_PASSWORD=Devmail323"
echo ""

# 5. 创建配置指导脚本
cat > configure_env.sh << 'EOF'
#!/bin/bash

echo "VMware IaaS 环境变量配置向导"
echo "=============================="

read -p "请输入LDAP服务器地址 (如: ldap://ldap.company.com:389): " ldap_server
read -p "请输入LDAP Base DN (如: dc=company,dc=com): " ldap_base_dn
read -p "请输入vCenter服务器地址 (如: vcenter.company.com): " vcenter_host
read -p "请输入vCenter用户名 (如: administrator@vsphere.local): " vcenter_user
read -s -p "请输入vCenter密码: " vcenter_password
echo ""

# 更新配置文件
sed -i "s|LDAP_SERVER=.*|LDAP_SERVER=$ldap_server|" .env
sed -i "s|LDAP_BASE_DN=.*|LDAP_BASE_DN=$ldap_base_dn|" .env
sed -i "s|VCENTER_HOST=.*|VCENTER_HOST=$vcenter_host|" .env
sed -i "s|VCENTER_USER=.*|VCENTER_USER=$vcenter_user|" .env
sed -i "s|VCENTER_PASSWORD=.*|VCENTER_PASSWORD=$vcenter_password|" .env

echo "✅ 配置已更新到 .env 文件"
echo "🚀 现在可以运行: ./deploy-complete.sh"
EOF
chmod +x configure_env.sh

log_success "✓ 配置向导已创建: ./configure_env.sh"

echo ""
echo "========================================"
echo "修复完成"
echo "========================================"
echo ""
echo "✅ 所有技术问题已修复！"
echo ""
echo "🚀 下一步操作："
echo "   1. 运行配置向导: ./configure_env.sh"
echo "   2. 或手动编辑: nano .env"
echo "   3. 验证配置: ./check_completeness.sh"
echo "   4. 开始部署: ./deploy-complete.sh"
echo ""
EOF
