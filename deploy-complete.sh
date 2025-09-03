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

# 检查系统要求
check_requirements() {
    log_info "检查系统要求..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi
    
    # 检查Python3（用于数据库初始化）
    if ! command -v python3 &> /dev/null; then
        log_warning "Python3未安装，将跳过数据库初始化脚本生成"
    fi
    
    log_success "Docker环境检查通过"
}

# 创建目录结构
create_directories() {
    log_info "创建项目目录结构..."
    
    directories=(
        "nginx/conf.d"
        "ssl"
        "static"
        "monitoring/prometheus"
        "monitoring/grafana/dashboards"
        "monitoring/grafana/datasources"
        "logs"
        "backups"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        log_info "  创建Prometheus配置文件"
    fi
    
    # 创建Grafana数据源配置
    if [[ ! -f monitoring/grafana/datasources/prometheus.yml ]]; then
        cat > monitoring/grafana/datasources/prometheus.yml << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF
        log_info "  创建Grafana数据源配置"
    fi
    
    # 创建Grafana仪表板配置
    if [[ ! -f monitoring/grafana/dashboards/dashboard.yml ]]; then
        cat > monitoring/grafana/dashboards/dashboard.yml << 'EOF'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
        log_info "  创建Grafana仪表板配置"
    fi
    
    # 创建nginx配置文件（如果不存在）
    if [[ ! -f nginx/conf.d/default.conf ]]; then
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
        log_info "  创建Nginx配置文件"
    fi
}

# 检查配置文件
check_config_files() {
    log_info "检查配置文件..."
    
    required_files=(
        ".env"
        "docker-compose.yml"
        "Dockerfile"
        "requirements.txt"
        "app.py"
        "monitoring/prometheus.yml"
        "monitoring/grafana/datasources/prometheus.yml"
        "monitoring/grafana/dashboards/dashboard.yml"
    )
    
    missing_files=()
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "缺少以下必要文件:"
        for file in "${missing_files[@]}"; do
            log_error "  - $file"
        done
        return 1
    fi
    
    log_success "配置文件检查通过"
    return 0
}

# 构建和启动服务
deploy_services() {
    log_info "开始构建和部署服务..."
    
    # 停止现有服务
    log_info "停止现有服务（如果存在）..."
    docker-compose down --remove-orphans 2>/dev/null || true
    
    # 拉取基础镜像
    log_info "拉取基础镜像..."
    docker-compose pull --ignore-pull-failures
    
    # 构建应用镜像
    log_info "构建应用镜像..."
    if ! docker-compose build; then
        log_error "镜像构建失败"
        return 1
    fi
    
    # 启动服务
    log_info "启动服务..."
    if ! docker-compose up -d; then
        log_error "服务启动失败"
        return 1
    fi
    
    # 等待服务启动
    log_info "等待服务启动..."
    sleep 30
    
    return 0
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    services=("postgres" "redis" "app" "nginx")
    all_healthy=true
    
    for service in "${services[@]}"; do
        if docker-compose ps "$service" | grep -q "Up"; then
            log_success "  $service: 运行正常"
        else
            log_error "  $service: 未正常运行"
            all_healthy=false
            
            # 显示错误日志
            log_info "  $service 服务日志:"
            docker-compose logs --tail=10 "$service" | sed 's/^/    /'
        fi
    done
    
    # 检查应用健康状态
    log_info "检查应用健康状态..."
    sleep 10
    
    for i in {1..5}; do
        if curl -s -f http://localhost/health > /dev/null 2>&1; then
            log_success "  应用健康检查通过"
            break
        else
            if [[ $i -eq 5 ]]; then
                log_warning "  应用健康检查失败，请查看日志"
                log_info "  应用日志:"
                docker-compose logs --tail=20 app | sed 's/^/    /'
                all_healthy=false
            else
                log_info "  等待应用启动... (${i}/5)"
                sleep 10
            fi
        fi
    done
    
    return $all_healthy
}

# 初始化数据库
init_database() {
    log_info "初始化数据库..."
    
    # 等待数据库启动
    log_info "等待数据库服务启动..."
    for i in {1..30}; do
        if docker-compose exec -T postgres pg_isready -U iaas_user -d vmware_iaas > /dev/null 2>&1; then
            log_success "数据库服务已就绪"
            break
        else
            if [[ $i -eq 30 ]]; then
                log_error "数据库服务启动超时"
                return 1
            fi
            sleep 2
        fi
    done
    
    # 运行数据库初始化
    log_info "运行数据库初始化脚本..."
    if docker-compose exec -T app python -c "
from app import app, db
from app import Tenant, Project, VirtualMachine, IPPool, BillingRecord, UserSession
import ipaddress
from datetime import datetime

print('Creating database tables...')
with app.app_context():
    try:
        db.create_all()
        print('Tables created successfully')
        
        # 初始化IP池
        print('Initializing IP pools...')
        network_segments = ['192.168.100.0/24', '192.168.101.0/24', '192.168.102.0/24']
        
        for segment in network_segments:
            network = ipaddress.IPv4Network(segment)
            existing_count = IPPool.query.filter_by(network_segment=segment).count()
            
            if existing_count > 0:
                print(f'Segment {segment}: {existing_count} IPs already exist')
                continue
                
            excluded_ips = {
                str(network.network_address),
                str(network.broadcast_address), 
                str(network.network_address + 1),
            }
            
            added_count = 0
            for ip in network.hosts():
                ip_str = str(ip)
                if ip_str not in excluded_ips:
                    ip_pool = IPPool(
                        network_segment=segment,
                        ip_address=ip_str,
                        is_available=True
                    )
                    db.session.add(ip_pool)
                    added_count += 1
            
            db.session.commit()
            print(f'Segment {segment}: Added {added_count} IP addresses')
        
        print('Database initialization completed successfully')
        
    except Exception as e:
        print(f'Database initialization failed: {str(e)}')
        exit(1)
"; then
        log_success "数据库初始化完成"
    else
        log_error "数据库初始化失败"
        return 1
    fi
    
    return 0
}

# 显示部署信息
show_deployment_info() {
    SERVER_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "localhost")
    
    echo ""
    echo "============================================"
    echo "🎉 VMware IaaS Platform 部署完成！"
    echo "============================================"
    echo ""
    echo "🌐 访问信息:"
    echo "   主页: http://$SERVER_IP"
    echo "   登录页: http://$SERVER_IP/login"
    echo "   健康检查: http://$SERVER_IP/health"
    echo "   监控面板: http://$SERVER_IP:3000"
    echo "   Prometheus: http://$SERVER_IP:9090"
    echo ""
    echo "🔐 默认凭据:"
    echo "   Grafana: admin / $(grep GRAFANA_PASSWORD .env | cut -d'=' -f2)"
    echo ""
    echo "🐳 Docker 管理命令:"
    echo "   查看状态: docker-compose ps"
    echo "   查看日志: docker-compose logs -f [service]"
    echo "   重启服务: docker-compose restart [service]"
    echo "   停止所有: docker-compose down"
    echo "   完全清理: docker-compose down -v --remove-orphans"
    echo ""
    echo "📁 重要文件和目录:"
    echo "   配置文件: .env"
    echo "   日志目录: logs/"
    echo "   备份目录: backups/"
    echo "   SSL证书: ssl/"
    echo ""
    echo "🔧 下一步操作:"
    echo "   1. 编辑 .env 文件配置LDAP、VMware等参数"
    echo "   2. 重启应用: docker-compose restart app"
    echo "   3. 如需SSL: 将证书放入 ssl/ 目录并更新nginx配置"
    echo "   4. 备份配置: 定期备份 .env 和数据库"
    echo ""
    echo "📖 文档和支持:"
    echo "   API文档: http://$SERVER_IP/api/health"
    echo "   查看服务状态: ./deploy-complete.sh --status"
    echo "   查看日志: ./deploy-complete.sh --logs [service]"
    echo ""
    log_success "部署完成！请根据上述信息配置和使用系统。"
}

# 主函数
main() {
    echo "========================================"
    echo "VMware IaaS Platform 完整部署脚本"
    echo "========================================"
    echo ""
    
    local all_success=true
    
    if ! check_requirements; then
        exit 1
    fi
    
    if ! create_directories; then
        all_success=false
    fi
    
    if ! generate_configs; then
        all_success=false
    fi
    
    if ! check_config_files; then
        exit 1
    fi
    
    if ! deploy_services; then
        exit 1
    fi
    
    if ! init_database; then
        log_warning "数据库初始化失败，请手动运行初始化"
        all_success=false
    fi
    
    if ! check_services; then
        log_warning "部分服务可能存在问题，请检查日志"
        all_success=false
    fi
    
    show_deployment_info
    
    if $all_success; then
        echo ""
        log_success "🎉 所有组件部署成功！"
        exit 0
    else
        echo ""
        log_warning "⚠️  部署完成，但存在一些警告，请检查上述日志"
        exit 0
    fi
}

# 显示帮助信息
show_help() {
    echo "VMware IaaS Platform 部署脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --help     显示帮助信息"
    echo "  --deploy   完整部署（默认）"
    echo "  --status   查看服务状态"
    echo "  --logs     查看服务日志"
    echo "  --stop     停止所有服务"
    echo "  --restart  重启所有服务"
    echo "  --clean    清理所有服务和数据（危险操作）"
    echo "  --update   更新服务"
    echo ""
    echo "示例:"
    echo "  $0                    # 完整部署"
    echo "  $0 --status          # 查看状态"
    echo "  $0 --logs app        # 查看应用日志"
    echo "  $0 --restart app     # 重启应用服务"
}

# 处理命令行参数
case "${1:-}" in
    --help)
        show_help
        exit 0
        ;;
    --status)
        echo "=== 服务状态 ==="
        docker-compose ps
        echo ""
        echo "=== 健康检查 ==="
        curl -s http://localhost/health | python3 -m json.tool 2>/dev/null || echo "健康检查失败"
        ;;
    --logs)
        if [[ -n "${2:-}" ]]; then
            docker-compose logs -f "$2"
        else
            docker-compose logs -f
        fi
        ;;
    --stop)
        log_info "停止所有服务..."
        docker-compose down
        log_success "所有服务已停止"
        ;;
    --restart)
        if [[ -n "${2:-}" ]]; then
            log_info "重启服务: $2"
            docker-compose restart "$2"
            log_success "服务 $2 已重启"
        else
            log_info "重启所有服务..."
            docker-compose restart
            log_success "所有服务已重启"
        fi
        ;;
    --clean)
        echo "⚠️  WARNING: 这将删除所有数据！"
        read -p "输入 'DELETE' 确认: " confirm
        if [[ "$confirm" == "DELETE" ]]; then
            log_info "清理所有服务和数据..."
            docker-compose down -v --remove-orphans
            docker system prune -f
            log_success "清理完成"
        else
            log_info "操作已取消"
        fi
        ;;
    --update)
        log_info "更新服务..."
        docker-compose pull
        docker-compose build --no-cache
        docker-compose up -d
        log_success "服务更新完成"
        ;;
    --deploy|"")
        main
        ;;
    *)
        echo "未知选项: $1"
        show_help
        exit 1
        ;;
esac "  创建目录: $dir"
    done
    
    log_success "目录结构创建完成"
}

# 生成配置文件
generate_configs() {
    log_info "生成配置文件..."
    
    # 生成强随机密码
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    SECRET_KEY=$(openssl rand -base64 64 | tr -d "\n")
    GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-12)
    
    # 创建.env文件
    if [[ ! -f .env ]]; then
        cat > .env << EOF
# VMware IaaS Platform 环境变量
# 自动生成时间: $(date)

# 数据库配置
DB_PASSWORD=$DB_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SECRET_KEY=$SECRET_KEY

# LDAP配置 - 请根据实际环境修改
LDAP_SERVER=ldap://your-ldap-server.com:389
LDAP_BASE_DN=dc=company,dc=com
LDAP_USER_DN_TEMPLATE=uid={username},ou=users,dc=company,dc=com
LDAP_ADMIN_DN=cn=admin,dc=company,dc=com
LDAP_ADMIN_PASSWORD=your_ldap_admin_password

# VMware vCenter配置 - 请根据实际环境修改
VCENTER_HOST=your-vcenter-server.com
VCENTER_USER=administrator@vsphere.local
VCENTER_PASSWORD=your_vcenter_admin_password

# 邮件服务器配置 - 请根据实际环境修改
SMTP_SERVER=smtp.company.com
SMTP_PORT=587
SMTP_USERNAME=iaas-system@company.com
SMTP_PASSWORD=your_smtp_password
SMTP_FROM=VMware IaaS Platform <iaas-system@company.com>

# 网络配置 - 请根据实际环境修改
NETWORK_SEGMENT_1=192.168.100.0/24
NETWORK_SEGMENT_2=192.168.101.0/24
NETWORK_SEGMENT_3=192.168.102.0/24

# 价格配置（每日单价）
PRICE_CPU=0.08
PRICE_MEMORY=0.16
PRICE_DISK=0.5
PRICE_GPU_3090=11.0
PRICE_GPU_T4=5.0

# 监控配置
GRAFANA_PASSWORD=$GRAFANA_PASSWORD

# 日志级别
LOG_LEVEL=INFO
EOF
        
        log_success "环境变量文件创建完成: .env"
        log_warning "请编辑 .env 文件配置LDAP、VMware、邮件参数"
    else
        log_info "环境变量文件已存在，跳过创建"
    fi
    
    # 创建Prometheus配置
    if [[ ! -f monitoring/prometheus.yml ]]; then
        cat > monitoring/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

scrape_configs:
  - job_name: 'vmware-iaas'
    static_configs:
      - targets: ['app:5000']
    metrics_path: '/api/metrics'
    scrape_interval: 30s
    scrape_timeout: 10s
    
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
        log_info
