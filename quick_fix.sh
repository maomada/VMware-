#!/bin/bash
# 快速修复 VMware IaaS Platform 的问题

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检测Docker Compose命令
detect_docker_compose() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        log_error "未找到 Docker Compose"
        exit 1
    fi
}

# 修复1: 创建缺失的Nginx配置文件
fix_nginx_config() {
    log_info "修复 Nginx 配置..."
    
    # 创建 common.conf 文件
    mkdir -p nginx/conf.d
    cat > nginx/conf.d/common.conf << 'EOF'
# Nginx 通用配置

# 客户端配置
client_max_body_size 100M;
client_body_timeout 60s;
client_header_timeout 60s;

# 安全头
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "strict-origin-when-cross-origin";

# API代理配置
location /api/ {
    proxy_pass http://app:5000/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    proxy_busy_buffers_size 8k;

    proxy_intercept_errors on;
    error_page 502 503 504 /50x.html;
}

# 静态文件配置
location /static/ {
    alias /usr/share/nginx/html/static/;
    expires 1d;
    add_header Cache-Control "public, immutable";
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    location ~* \.(html|htm)$ {
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
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

    proxy_intercept_errors on;
    error_page 502 503 504 /50x.html;
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

location ~ \.(bak|backup|old|orig|save|swp|tmp)$ {
    deny all;
    return 404;
}

location = /robots.txt {
    add_header Content-Type text/plain;
    return 200 "User-agent: *\nDisallow: /\n";
}

location = /favicon.ico {
    access_log off;
    log_not_found off;
    expires 1y;
}
EOF

    # 修复 default.conf，移除对 common.conf 的引用
    cat > nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name _;

    # 安全头
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # 日志
    access_log /var/log/nginx/vmware-iaas.access.log;
    error_log /var/log/nginx/vmware-iaas.error.log;

    # 客户端配置
    client_max_body_size 100M;
    client_body_timeout 60s;
    client_header_timeout 60s;

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
        proxy_busy_buffers_size 8k;

        # 错误处理
        proxy_intercept_errors on;
        error_page 502 503 504 /50x.html;
    }

    # 静态文件
    location /static/ {
        alias /usr/share/nginx/html/static/;
        expires 1d;
        add_header Cache-Control "public, immutable";
        
        # 特定文件类型的缓存
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
        
        # HTML文件不缓存
        location ~* \.(html|htm)$ {
            expires -1;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
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

        # 错误处理
        proxy_intercept_errors on;
        error_page 502 503 504 /50x.html;
    }

    # 健康检查（不记录日志）
    location /health {
        proxy_pass http://app:5000/api/health;
        access_log off;
    }

    # 监控代理（可选）
    location /grafana/ {
        proxy_pass http://grafana:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Prometheus代理（可选）
    location /prometheus/ {
        proxy_pass http://prometheus:9090/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 错误页面
    location = /50x.html {
        root /usr/share/nginx/html;
        internal;
    }

    # 禁止访问敏感文件
    location ~ /\.(ht|env|git) {
        deny all;
        return 404;
    }

    # 禁止访问备份文件
    location ~ \.(bak|backup|old|orig|save|swp|tmp)$ {
        deny all;
        return 404;
    }

    # robots.txt
    location = /robots.txt {
        add_header Content-Type text/plain;
        return 200 "User-agent: *\nDisallow: /\n";
    }

    # favicon.ico
    location = /favicon.ico {
        access_log off;
        log_not_found off;
        expires 1y;
    }
}
EOF

    log_success "Nginx 配置文件已修复"
}

# 修复2: 创建数据库修复脚本
fix_database() {
    log_info "修复数据库结构..."
    
    cat > fix_database.py << 'EOF'
#!/usr/bin/env python3
import os
import sys
import logging
from sqlalchemy import create_engine, text

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def get_database_url():
    db_host = os.environ.get('DB_HOST', 'postgres')
    db_port = os.environ.get('DB_PORT', '5432')
    db_name = os.environ.get('DB_NAME', 'vmware_iaas')
    db_user = os.environ.get('DB_USER', 'iaas_user')
    db_password = os.environ.get('DB_PASSWORD', 'password')
    return f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'

def fix_schema():
    try:
        engine = create_engine(get_database_url())
        with engine.connect() as conn:
            trans = conn.begin()
            try:
                # 添加 tenants.ldap_uid
                logger.info("检查 tenants.ldap_uid...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'tenants' AND column_name = 'ldap_uid'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 tenants.ldap_uid 字段...")
                    conn.execute(text("ALTER TABLE tenants ADD COLUMN ldap_uid VARCHAR(100)"))
                    conn.execute(text("UPDATE tenants SET ldap_uid = username WHERE ldap_uid IS NULL"))
                    # 检查是否有数据再设置约束
                    count = conn.execute(text("SELECT COUNT(*) FROM tenants")).scalar()
                    if count > 0:
                        conn.execute(text("ALTER TABLE tenants ALTER COLUMN ldap_uid SET NOT NULL"))
                        conn.execute(text("ALTER TABLE tenants ADD CONSTRAINT tenants_ldap_uid_unique UNIQUE (ldap_uid)"))
                
                # 添加 ip_pools.assigned_at
                logger.info("检查 ip_pools.assigned_at...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'ip_pools' AND column_name = 'assigned_at'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 ip_pools.assigned_at 字段...")
                    conn.execute(text("ALTER TABLE ip_pools ADD COLUMN assigned_at TIMESTAMP"))
                
                # 添加 virtual_machines.host_name
                logger.info("检查 virtual_machines.host_name...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'virtual_machines' AND column_name = 'host_name'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 virtual_machines.host_name 字段...")
                    conn.execute(text("ALTER TABLE virtual_machines ADD COLUMN host_name VARCHAR(100)"))
                
                # 检查其他可能缺失的字段
                vm_columns = [
                    ('vcenter_vm_id', 'VARCHAR(100)'),
                    ('gpu_type', 'VARCHAR(20)'),
                    ('gpu_count', 'INTEGER DEFAULT 0')
                ]
                
                for col_name, col_type in vm_columns:
                    result = conn.execute(text(f"""
                        SELECT column_name FROM information_schema.columns 
                        WHERE table_name = 'virtual_machines' AND column_name = '{col_name}'
                    """)).fetchone()
                    
                    if not result:
                        logger.info(f"添加 virtual_machines.{col_name} 字段...")
                        conn.execute(text(f"ALTER TABLE virtual_machines ADD COLUMN {col_name} {col_type}"))
                
                trans.commit()
                logger.info("✅ 数据库结构修复完成!")
                return True
                
            except Exception as e:
                trans.rollback()
                logger.error(f"修复失败: {e}")
                return False
                
    except Exception as e:
        logger.error(f"连接数据库失败: {e}")
        return False

if __name__ == '__main__':
    if fix_schema():
        print("数据库修复成功!")
    else:
        print("数据库修复失败!")
        sys.exit(1)
EOF

    chmod +x fix_database.py
    log_success "数据库修复脚本已创建"
}

# 修复3: 修复app.py中的SQLAlchemy语法
fix_app_py() {
    log_info "修复 app.py 中的 SQLAlchemy 语法..."
    
    # 备份原文件
    if [ -f app.py ]; then
        cp app.py app.py.backup.$(date +%s)
        log_info "已备份原 app.py 文件"
    fi
    
    # 创建修复补丁
    cat > app_py_patch.py << 'EOF'
# 替换 app.py 中的问题代码片段

import re

def fix_app_py():
    """修复 app.py 中的 SQLAlchemy 语法问题"""
    
    with open('app.py', 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 1. 修复健康检查中的 SQL 语句
    old_health_check = r"db\.session\.execute\('SELECT 1'\)"
    new_health_check = r"db.session.execute(text('SELECT 1'))"
    
    if old_health_check in content:
        content = re.sub(old_health_check, new_health_check, content)
        print("✅ 修复了健康检查中的 SQL 语句")
    
    # 2. 在文件开头添加 text 导入
    import_line = "from sqlalchemy import text"
    if import_line not in content:
        # 在 Flask 导入之后添加 SQLAlchemy 导入
        flask_import_pattern = r"(from flask import [^\n]+\n)"
        replacement = r"\1from sqlalchemy import text\n"
        content = re.sub(flask_import_pattern, replacement, content)
        print("✅ 添加了 SQLAlchemy text 导入")
    
    # 3. 修复其他可能的 SQL 语句
    other_sql_patterns = [
        (r"db\.session\.execute\('([^']+)'\)", r"db.session.execute(text('\1'))"),
        (r'db\.session\.execute\("([^"]+)"\)', r'db.session.execute(text("\1"))'),
    ]
    
    for pattern, replacement in other_sql_patterns:
        if re.search(pattern, content):
            content = re.sub(pattern, replacement, content)
            print(f"✅ 修复了 SQL 语句: {pattern}")
    
    # 写回文件
    with open('app.py', 'w', encoding='utf-8') as f:
        f.write(content)
    
    print("✅ app.py 修复完成")

if __name__ == '__main__':
    fix_app_py()
EOF

    python3 app_py_patch.py 2>/dev/null || {
        log_warning "自动修复 app.py 失败，需要手动修改"
        echo "请手动在 app.py 中:"
        echo "1. 添加导入: from sqlalchemy import text"
        echo "2. 将 db.session.execute('SELECT 1') 改为 db.session.execute(text('SELECT 1'))"
    }
}

# 主修复流程
main() {
    echo "=================================="
    echo "VMware IaaS Platform 快速修复工具"
    echo "=================================="
    echo
    
    detect_docker_compose
    
    log_info "开始修复系统问题..."
    
    # 1. 修复 Nginx 配置
    fix_nginx_config
    
    # 2. 修复数据库结构
    fix_database
    
    # 3. 修复 app.py
    fix_app_py
    
    log_info "重启服务以应用修复..."
    
    # 停止服务
    $DOCKER_COMPOSE down
    
    # 重新构建应用镜像
    log_info "重新构建应用镜像..."
    $DOCKER_COMPOSE build app
    
    # 启动数据库
    log_info "启动数据库服务..."
    $DOCKER_COMPOSE up -d postgres redis
    
    # 等待数据库就绪
    log_info "等待数据库就绪..."
    sleep 15
    
    # 修复数据库结构
    log_info "执行数据库结构修复..."
    $DOCKER_COMPOSE run --rm app python3 /app/fix_database.py || {
        log_warning "数据库修复脚本执行失败，将在应用启动时自动修复"
    }
    
    # 启动应用
    log_info "启动应用服务..."
    $DOCKER_COMPOSE up -d app
    
    # 等待应用就绪
    log_info "等待应用就绪..."
    sleep 20
    
    # 启动 Nginx
    log_info "启动 Nginx 服务..."
    $DOCKER_COMPOSE up -d nginx
    
    # 启动监控服务（可选）
    log_info "启动监控服务..."
    $DOCKER_COMPOSE up -d prometheus grafana 2>/dev/null || log_warning "监控服务启动失败（可忽略）"
    
    echo
    log_success "修复完成！"
    echo
    echo "🔍 系统状态检查:"
    $DOCKER_COMPOSE ps
    
    echo
    echo "🌐 访问信息:"
    SERVER_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "localhost")
    echo "   主页: http://$SERVER_IP"
    echo "   登录: http://$SERVER_IP/static/login.html"
    echo "   健康检查: http://$SERVER_IP/api/health"
    
    echo
    echo "📋 后续步骤:"
    echo "1. 检查应用日志: $DOCKER_COMPOSE logs -f app"
    echo "2. 检查健康状态: curl http://localhost/api/health"
    echo "3. 测试登录功能"
    echo
    echo "🔧 如果仍有问题:"
    echo "- 查看详细日志: $DOCKER_COMPOSE logs [service_name]"
    echo "- 重启特定服务: $DOCKER_COMPOSE restart [service_name]"
    echo "- 进入容器调试: $DOCKER_COMPOSE exec app /bin/bash"
}

# 运行主函数
main "$@"
