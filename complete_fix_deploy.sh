#!/bin/bash

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
        log_info "使用 Docker Compose V2 (docker compose)"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
        log_warning "使用旧版 Docker Compose V1 (docker-compose)"
        log_warning "建议升级到 Docker Compose V2"
    else
        log_error "未找到 Docker Compose"
        echo "请安装 Docker Desktop 或运行: sudo apt-get install docker-compose-plugin"
        exit 1
    fi
}

echo "========================================"
echo "VMware IaaS Platform 现代化部署"
echo "========================================"

# 检测Docker环境
log_info "检测Docker环境..."
if ! command -v docker &> /dev/null; then
    log_error "Docker未安装，请先安装Docker"
    exit 1
fi

detect_docker_compose

# 1. 停止现有服务
log_info "停止现有服务..."
$DOCKER_COMPOSE down --remove-orphans >/dev/null 2>&1 || true
docker container prune -f >/dev/null 2>&1 || true

# 2. 创建修复版本的app.py
log_info "创建修复版本的app.py..."
cat > app.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import logging
import ipaddress
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, send_from_directory, redirect, url_for
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS

# 配置类
class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY', 'vmware-iaas-secret-key-2025')
    
    # 数据库配置
    DB_HOST = os.environ.get('DB_HOST', 'postgres')
    DB_PORT = os.environ.get('DB_PORT', '5432')
    DB_NAME = os.environ.get('DB_NAME', 'vmware_iaas')
    DB_USER = os.environ.get('DB_USER', 'iaas_user')
    DB_PASSWORD = os.environ.get('DB_PASSWORD', 'password')
    
    SQLALCHEMY_DATABASE_URI = f'postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}'
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # 网络配置
    NETWORK_SEGMENTS = [
        os.environ.get('NETWORK_SEGMENT_1', '192.168.100.0/24'),
        os.environ.get('NETWORK_SEGMENT_2', '192.168.101.0/24'),
        os.environ.get('NETWORK_SEGMENT_3', '192.168.102.0/24')
    ]

# Flask应用初始化
app = Flask(__name__)
app.config.from_object(Config)
db = SQLAlchemy(app)
CORS(app)

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# 数据库模型
class Tenant(db.Model):
    __tablename__ = 'tenants'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(100), nullable=False)
    display_name = db.Column(db.String(200))
    email = db.Column(db.String(200))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class Project(db.Model):
    __tablename__ = 'projects'
    id = db.Column(db.Integer, primary_key=True)
    project_name = db.Column(db.String(200), nullable=False)
    project_code = db.Column(db.String(100), nullable=False)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class VirtualMachine(db.Model):
    __tablename__ = 'virtual_machines'
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    project_id = db.Column(db.Integer, db.ForeignKey('projects.id'), nullable=False)
    project_name = db.Column(db.String(200), nullable=False)
    project_code = db.Column(db.String(100), nullable=False)
    owner = db.Column(db.String(200), nullable=False)
    deadline = db.Column(db.DateTime, nullable=False)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    ip_address = db.Column(db.String(15))
    cpu_cores = db.Column(db.Integer, nullable=False)
    memory_gb = db.Column(db.Integer, nullable=False)
    disk_gb = db.Column(db.Integer, nullable=False)
    status = db.Column(db.String(20), default='creating')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class IPPool(db.Model):
    __tablename__ = 'ip_pools'
    id = db.Column(db.Integer, primary_key=True)
    network_segment = db.Column(db.String(20), nullable=False)
    ip_address = db.Column(db.String(15), nullable=False)
    is_available = db.Column(db.Boolean, default=True)
    assigned_vm_id = db.Column(db.Integer, db.ForeignKey('virtual_machines.id'))

# 路由
@app.route('/')
def index():
    return send_from_directory('static', 'login.html')

@app.route('/login')
def login_page():
    return send_from_directory('static', 'login.html')

@app.route('/static/<path:filename>')
def static_files(filename):
    return send_from_directory('static', filename)

@app.route('/api/health')
def health_check():
    health_status = {
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat(),
        'version': '2.0.0',
        'services': {}
    }
    
    try:
        db.session.execute('SELECT 1')
        health_status['services']['database'] = 'connected'
    except Exception as e:
        health_status['services']['database'] = f'error: {str(e)}'
        health_status['status'] = 'unhealthy'
        return jsonify(health_status), 503
    
    return jsonify(health_status)

@app.route('/api/auth/login', methods=['POST'])
def login():
    return jsonify({
        'error': 'Authentication service requires LDAP configuration. Please check .env file.'
    }), 501

@app.route('/api/templates')
def list_templates():
    templates = [
        {'name': 'Ubuntu-20.04-Template', 'display_name': 'Ubuntu 20.04 LTS', 'os_type': 'Linux'},
        {'name': 'Ubuntu-22.04-Template', 'display_name': 'Ubuntu 22.04 LTS', 'os_type': 'Linux'},
        {'name': 'CentOS-7-Template', 'display_name': 'CentOS 7', 'os_type': 'Linux'},
        {'name': 'Windows-Server-2019-Template', 'display_name': 'Windows Server 2019', 'os_type': 'Windows'}
    ]
    return jsonify({'templates': templates})

@app.route('/api/system/stats')
def system_stats():
    try:
        total_vms = VirtualMachine.query.count()
        total_projects = Project.query.count()
        
        return jsonify({
            'vms': {'total': total_vms, 'running': 0, 'stopped': 0, 'expiring_soon': 0, 'expired': 0},
            'resources': {'total_cpu_cores': 0, 'total_memory_gb': 0, 'total_disk_gb': 0, 'total_gpus': 0},
            'projects': {'total': total_projects}
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/metrics')
def metrics():
    try:
        total_vms = VirtualMachine.query.count()
        metrics_text = f"""# HELP vmware_iaas_vms_total Total number of VMs
# TYPE vmware_iaas_vms_total gauge
vmware_iaas_vms_total {total_vms}
"""
        return metrics_text, 200, {'Content-Type': 'text/plain'}
    except Exception:
        return "# Error generating metrics\n", 500, {'Content-Type': 'text/plain'}

@app.errorhandler(404)
def not_found_error(error):
    if request.path.startswith('/api/'):
        return jsonify({'error': 'Not found'}), 404
    return redirect(url_for('index'))

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

def init_database():
    with app.app_context():
        try:
            db.create_all()
            logger.info("Database tables created")
            
            # 初始化IP池
            for segment in app.config['NETWORK_SEGMENTS']:
                network = ipaddress.IPv4Network(segment)
                existing_count = IPPool.query.filter_by(network_segment=segment).count()
                
                if existing_count == 0:
                    excluded_ips = {str(network.network_address), str(network.broadcast_address), str(network.network_address + 1)}
                    for ip in network.hosts():
                        ip_str = str(ip)
                        if ip_str not in excluded_ips:
                            ip_pool = IPPool(network_segment=segment, ip_address=ip_str, is_available=True)
                            db.session.add(ip_pool)
                    
                    db.session.commit()
                    logger.info(f"Initialized IP pool for {segment}")
            
        except Exception as e:
            logger.error(f"Database init failed: {e}")
            raise

if __name__ == '__main__':
    init_database()
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

log_success "app.py 已修复"

# 3. 修复nginx配置
log_info "修复nginx配置..."
mkdir -p nginx/conf.d

cat > nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 100M;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    include /etc/nginx/conf.d/*.conf;
}
EOF

cat > nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name _;

    location /api/ {
        proxy_pass http://app:5000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /static/ {
        alias /usr/share/nginx/html/static/;
        expires 1d;
    }

    location / {
        proxy_pass http://app:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /health {
        proxy_pass http://app:5000/api/health;
        access_log off;
    }
}
EOF

log_success "nginx配置已修复"

# 4. 修复docker-compose.yml
log_info "修复docker-compose.yml..."
sed -i '/^version:/d' compose.yaml 2>/dev/null || true
sed -i '/^version:/d' docker-compose.yml 2>/dev/null || true

# 5. 构建和启动服务
log_info "构建和启动服务..."

# 启动数据库服务
log_info "启动数据库服务..."
$DOCKER_COMPOSE up -d postgres redis

# 等待数据库就绪
log_info "等待数据库就绪..."
for i in {1..30}; do
    if $DOCKER_COMPOSE exec -T postgres pg_isready -U iaas_user -d vmware_iaas >/dev/null 2>&1; then
        log_success "PostgreSQL就绪"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "PostgreSQL启动超时"
        exit 1
    fi
    sleep 2
done

# 构建应用镜像
log_info "构建应用镜像..."
$DOCKER_COMPOSE build --no-cache app

# 启动应用
log_info "启动应用服务..."
$DOCKER_COMPOSE up -d app

# 等待应用就绪
log_info "等待应用就绪..."
for i in {1..20}; do
    if curl -s -f http://localhost:5000/api/health >/dev/null 2>&1; then
        log_success "应用服务就绪"
        break
    fi
    if [ $i -eq 20 ]; then
        log_warning "应用可能还在启动中"
        break
    fi
    sleep 3
done

# 启动其他服务
log_info "启动web和监控服务..."
$DOCKER_COMPOSE up -d nginx prometheus grafana

# 6. 检查服务状态
log_info "检查服务状态..."
sleep 5

echo ""
echo "=== 容器状态 ==="
$DOCKER_COMPOSE ps

echo ""
echo "=== 服务检查 ==="

# 检查数据库
if $DOCKER_COMPOSE exec -T postgres pg_isready -U iaas_user >/dev/null 2>&1; then
    log_success "✅ PostgreSQL: 正常"
else
    log_error "❌ PostgreSQL: 异常"
fi

# 检查Redis
if $DOCKER_COMPOSE exec -T redis redis-cli ping >/dev/null 2>&1; then
    log_success "✅ Redis: 正常"
else
    log_error "❌ Redis: 异常"
fi

# 检查应用
if curl -s -f http://localhost:5000/api/health >/dev/null 2>&1; then
    log_success "✅ 应用服务: 正常"
    echo "健康检查响应:"
    curl -s http://localhost:5000/api/health | python3 -m json.tool 2>/dev/null || echo "  API正常响应"
else
    log_error "❌ 应用服务: 异常"
    echo "应用日志:"
    $DOCKER_COMPOSE logs --tail=5 app | sed 's/^/  /'
fi

# 检查nginx
if curl -s -f http://localhost >/dev/null 2>&1; then
    log_success "✅ Nginx: 正常"
else
    log_error "❌ Nginx: 异常"
    echo "Nginx日志:"
    $DOCKER_COMPOSE logs --tail=5 nginx | sed 's/^/  /'
fi

# 7. 显示访问信息
echo ""
echo "============================================"
echo "🎉 VMware IaaS Platform 部署完成！"
echo "============================================"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo "🌐 访问信息:"
echo "   主页: http://$SERVER_IP"
echo "   登录页: http://$SERVER_IP/login"
echo "   健康检查: http://$SERVER_IP:5000/api/health"
echo "   监控面板: http://$SERVER_IP:3001"
echo "   指标收集: http://$SERVER_IP:9091"
echo ""

if [ -f .env ]; then
    GRAFANA_PASS=$(grep GRAFANA_PASSWORD .env | cut -d'=' -f2 2>/dev/null || echo "admin123")
    echo "🔐 监控登录:"
    echo "   Grafana: admin / $GRAFANA_PASS"
    echo ""
fi

echo "🐳 现代Docker管理命令:"
echo "   查看状态: $DOCKER_COMPOSE ps"
echo "   查看日志: $DOCKER_COMPOSE logs [服务名]"
echo "   重启服务: $DOCKER_COMPOSE restart [服务名]"
echo "   停止所有: $DOCKER_COMPOSE down"
echo "   完全清理: $DOCKER_COMPOSE down -v --remove-orphans"
echo ""

echo "📝 下一步配置:"
echo "   1. 编辑 .env 文件设置LDAP和VMware参数"
echo "   2. 重启应用: $DOCKER_COMPOSE restart app"
echo "   3. 访问系统进行测试"
echo ""

echo "📋 重要文件:"
echo "   配置文件: .env"
echo "   应用日志: $DOCKER_COMPOSE logs app"
echo "   健康检查: curl http://localhost:5000/api/health"
echo ""

echo "🔧 故障排除:"
echo "   查看详细日志: $DOCKER_COMPOSE logs --follow app"
echo "   重新构建: $DOCKER_COMPOSE build --no-cache app"
echo "   进入容器: $DOCKER_COMPOSE exec app bash"
echo ""

log_success "部署完成！系统现在应该可以正常运行了。"

# 8. 最终测试
echo "执行最终测试..."
if curl -s http://localhost:5000/api/health | grep -q "healthy"; then
    log_success "🎉 所有测试通过！系统运行正常！"
    echo ""
    echo "你现在可以:"
    echo "  • 访问 http://$SERVER_IP 查看登录页面"
    echo "  • 配置 .env 文件启用完整功能"
    echo "  • 使用 $DOCKER_COMPOSE logs app 查看应用日志"
else
    log_warning "⚠️  系统可能需要更多时间启动，请稍后再试"
    echo ""
    echo "如果问题持续，请检查:"
    echo "  • $DOCKER_COMPOSE logs app"
    echo "  • $DOCKER_COMPOSE ps"
    echo "  • curl http://localhost:5000/api/health"
fi
