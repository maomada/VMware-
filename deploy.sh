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
        log_info "使用 Docker Compose V2"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
        log_info "使用 Docker Compose V1"
    else
        log_error "未找到 Docker Compose"
        exit 1
    fi
}

# 检查系统要求
check_requirements() {
    log_info "检查系统要求..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    
    detect_docker_compose
    
    if ! command -v curl &> /dev/null; then
        log_warning "curl未安装，某些检查功能可能不可用"
    fi
    
    # 检查Docker服务状态
    if ! docker info &> /dev/null; then
        log_error "Docker服务未运行，请启动Docker服务"
        exit 1
    fi
    
    log_success "系统要求检查通过"
}

# 创建目录结构
setup_directories() {
    log_info "创建目录结构..."
    
    directories=(
        "nginx/conf.d"
        "ssl"
        "monitoring/grafana/dashboards"
        "monitoring/grafana/datasources"
        "logs"
        "backups"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
    done
    
    log_success "目录结构创建完成"
}

# 生成环境变量文件
generate_env() {
    if [ ! -f .env ]; then
        log_info "生成.env文件..."
        
        # 生成随机密码
        DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        SECRET_KEY=$(openssl rand -base64 64)
        GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-12)
        
        cat > .env << EOF
# VMware IaaS Platform Environment Variables
# 自动生成时间: $(date)

# 数据库配置
DB_PASSWORD=$DB_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD

# Flask密钥
SECRET_KEY=$SECRET_KEY

# LDAP配置 (需要手动配置)
LDAP_SERVER=ldap://your-ldap-server.com:389
LDAP_BASE_DN=dc=company,dc=com
LDAP_USER_DN_TEMPLATE=uid={username},ou=users,dc=company,dc=com
LDAP_ADMIN_DN=cn=admin,dc=company,dc=com
LDAP_ADMIN_PASSWORD=your_ldap_password

# VMware vCenter配置 (需要手动配置)
VCENTER_HOST=your-vcenter-server.com
VCENTER_USER=administrator@vsphere.local
VCENTER_PASSWORD=your_vcenter_password

# 邮件服务器配置 (可选)
SMTP_SERVER=smtp.company.com
SMTP_PORT=587
SMTP_USERNAME=iaas-system@company.com
SMTP_PASSWORD=your_smtp_password
SMTP_FROM=VMware IaaS Platform <iaas-system@company.com>

# 网络配置
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
        log_success ".env文件已生成"
        log_warning "请编辑.env文件，配置LDAP和VMware参数"
    else
        log_info ".env文件已存在，跳过生成"
    fi
}

# 生成Nginx配置文件
generate_nginx_config() {
    log_info "生成Nginx配置文件..."
    
    # 创建主配置文件
    if [ ! -f nginx/nginx.conf ]; then
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
        log_success "Nginx主配置文件已生成"
    fi
}

# 生成监控配置
generate_monitoring_config() {
    log_info "生成监控配置文件..."
    
    # Prometheus配置
    cat > monitoring/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'vmware-iaas'
    static_configs:
      - targets: ['app:5000']
    metrics_path: '/api/metrics'
    scrape_interval: 30s
EOF

    # Grafana数据源配置
    mkdir -p monitoring/grafana/datasources
    cat > monitoring/grafana/datasources/prometheus.yml << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

    # Grafana仪表板配置
    mkdir -p monitoring/grafana/dashboards
    cat > monitoring/grafana/dashboards/dashboard.yml << 'EOF'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

    log_success "监控配置文件已生成"
}

# 部署服务
deploy_services() {
    log_info "开始部署服务..."
    
    # 停止现有服务
    log_info "停止现有服务..."
    $DOCKER_COMPOSE down --remove-orphans 2>/dev/null || true
    
    # 清理旧镜像
    log_info "清理旧镜像..."
    docker image prune -f 2>/dev/null || true
    
    # 拉取基础镜像
    log_info "拉取基础镜像..."
    $DOCKER_COMPOSE pull --ignore-pull-failures 2>/dev/null || true
    
    # 构建应用镜像
    log_info "构建应用镜像..."
    if ! $DOCKER_COMPOSE build --no-cache app; then
        log_error "镜像构建失败"
        return 1
    fi
    
    # 逐步启动服务
    log_info "启动数据库服务..."
    $DOCKER_COMPOSE up -d postgres redis
    
    # 等待数据库就绪
    log_info "等待数据库就绪..."
    for i in {1..30}; do
        if $DOCKER_COMPOSE exec postgres pg_isready -U iaas_user -d vmware_iaas >/dev/null 2>&1; then
            log_success "数据库就绪"
            break
        fi
        if [ $i -eq 30 ]; then
            log_error "数据库启动超时"
            return 1
        fi
        sleep 2
    done
    
    # 启动应用服务
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
            log_warning "应用启动可能需要更多时间"
            break
        fi
        sleep 3
    done
    
    # 启动其他服务
    log_info "启动其他服务..."
    $DOCKER_COMPOSE up -d nginx
    
    # 启动监控服务（可选）
    if [ "${ENABLE_MONITORING:-yes}" = "yes" ]; then
        $DOCKER_COMPOSE up -d prometheus grafana
    fi
    
    return 0
}

# 初始化数据库
init_database() {
    log_info "初始化数据库..."
    
    # 检查是否已初始化
    if $DOCKER_COMPOSE exec app python3 -c "
from app import app, db, Tenant
with app.app_context():
    try:
        count = Tenant.query.count()
        print(f'Tables exist, found {count} tenants')
        exit(0)
    except:
        print('Tables need initialization')
        exit(1)
" 2>/dev/null; then
        log_info "数据库已初始化，跳过"
        return 0
    fi
    
    # 运行初始化
    if $DOCKER_COMPOSE exec app python3 -c "
from app import app, db
import ipaddress

with app.app_context():
    try:
        # 创建表
        db.create_all()
        print('✓ 数据库表创建成功')
        
        # 初始化IP池
        from app import IPPool
        segments = ['192.168.100.0/24', '192.168.101.0/24', '192.168.102.0/24']
        total_ips = 0
        
        for segment in segments:
            network = ipaddress.IPv4Network(segment)
            existing = IPPool.query.filter_by(network_segment=segment).count()
            
            if existing == 0:
                excluded = {str(network.network_address), str(network.broadcast_address), str(network.network_address + 1)}
                count = 0
                for ip in network.hosts():
                    if str(ip) not in excluded:
                        pool = IPPool(network_segment=segment, ip_address=str(ip), is_available=True)
                        db.session.add(pool)
                        count += 1
                
                db.session.commit()
                print(f'✓ 网段 {segment}: 添加 {count} 个IP地址')
                total_ips += count
            else:
                print(f'✓ 网段 {segment}: 已存在 {existing} 个IP地址')
        
        print(f'✓ IP池初始化完成，共 {total_ips} 个可用IP')
        
    except Exception as e:
        print(f'✗ 数据库初始化失败: {str(e)}')
        exit(1)
"; then
        log_success "数据库初始化完成"
    else
        log_error "数据库初始化失败"
        return 1
    fi
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    echo ""
    echo "=== 容器状态 ==="
    $DOCKER_COMPOSE ps
    
    echo ""
    echo "=== 服务检查 ==="
    
    # 检查数据库
    if $DOCKER_COMPOSE exec postgres pg_isready -U iaas_user -d vmware_iaas >/dev/null 2>&1; then
        log_success "✅ PostgreSQL: 正常"
    else
        log_error "❌ PostgreSQL: 异常"
    fi
    
    # 检查Redis
    if $DOCKER_COMPOSE exec redis redis-cli --no-auth-warning -a "${REDIS_PASSWORD:-redis_password_123}" ping >/dev/null 2>&1; then
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
        $DOCKER_COMPOSE logs --tail=10 app | sed 's/^/  /'
    fi
    
    # 检查nginx
    if curl -s -f http://localhost >/dev/null 2>&1; then
        log_success "✅ Nginx: 正常"
    else
        log_error "❌ Nginx: 异常"
        echo "Nginx日志:"
        $DOCKER_COMPOSE logs --tail=5 nginx | sed 's/^/  /'
    fi
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
    echo "   登录页: http://$SERVER_IP/static/login.html"
    echo "   控制台: http://$SERVER_IP/dashboard"
    echo "   API文档: http://$SERVER_IP/static/api-docs.html"
    echo "   健康检查: http://$SERVER_IP/api/health"
    echo ""
    
    if [ "${ENABLE_MONITORING:-yes}" = "yes" ]; then
        if [ -f .env ]; then
            GRAFANA_PASS=$(grep GRAFANA_PASSWORD .env | cut -d'=' -f2 2>/dev/null || echo "admin123")
            echo "📊 监控面板:"
            echo "   Grafana: http://$SERVER_IP:3000 (admin / $GRAFANA_PASS)"
            echo "   Prometheus: http://$SERVER_IP:9090"
            echo ""
        fi
    fi
    
    echo "🔐 演示账号 (如未配置LDAP):"
    echo "   admin / admin123 (系统管理员)"
    echo "   user1 / user123 (普通用户)"
    echo "   user2 / user123 (普通用户)"
    echo ""
    echo "🐳 管理命令:"
    echo "   查看状态: ./manage.sh status"
    echo "   查看日志: ./manage.sh logs [service]"
    echo "   重启服务: ./manage.sh restart [service]"
    echo "   停止所有: ./manage.sh stop"
    echo "   数据库备份: ./manage.sh backup"
    echo ""
    echo "📁 重要文件:"
    echo "   配置文件: .env"
    echo "   管理脚本: ./manage.sh"
    echo "   Docker配置: docker-compose.yml"
    echo ""
    echo "🔧 下一步操作:"
    echo "   1. 编辑 .env 文件配置LDAP和VMware参数"
    echo "   2. 重启应用: ./manage.sh restart app"
    echo "   3. 使用演示账号或LDAP账号登录测试"
    echo "   4. 创建第一个项目和虚拟机"
    echo ""
    echo "📖 故障排除:"
    echo "   应用日志: ./manage.sh logs app"
    echo "   数据库日志: ./manage.sh logs postgres"
    echo "   重新构建: ./manage.sh rebuild"
    echo "   系统健康: ./manage.sh health"
    echo ""
}

# 主函数
main() {
    echo "========================================"
    echo "VMware IaaS Platform 自动部署脚本 v2.0"
    echo "========================================"
    echo ""
    
    # 检查参数
    case "${1:-}" in
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --help, -h     显示帮助信息"
            echo "  --no-monitoring 不启动监控服务"
            echo "  --force        强制重新部署"
            echo "  --dev          开发模式部署"
            echo ""
            exit 0
            ;;
        --no-monitoring)
            export ENABLE_MONITORING=no
            ;;
        --force)
            export FORCE_DEPLOY=yes
            ;;
        --dev)
            export DEV_MODE=yes
            export LOG_LEVEL=DEBUG
            ;;
    esac
    
    local all_success=true
    
    # 执行部署步骤
    if ! check_requirements; then
        exit 1
    fi
    
    setup_directories
    generate_env
    generate_nginx_config
    generate_monitoring_config
    
    if ! deploy_services; then
        log_error "服务部署失败"
        exit 1
    fi
    
    if ! init_database; then
        log_warning "数据库初始化失败，请手动检查"
        all_success=false
    fi
    
    sleep 10  # 等待服务完全启动
    
    check_services
    show_deployment_info
    
    if $all_success; then
        echo ""
        log_success "🎉 所有组件部署成功！"
        
        # 最终测试
        if curl -s http://localhost/api/health | grep -q "healthy\|degraded"; then
            log_success "✅ 最终测试通过！系统运行正常！"
        else
            log_warning "⚠️  系统可能需要更多时间启动，请稍后再试"
        fi
        
        exit 0
    else
        echo ""
        log_warning "⚠️  部署完成，但存在一些警告，请检查上述日志"
        exit 0
    fi
}

# 清理函数
cleanup() {
    log_info "执行清理操作..."
    $DOCKER_COMPOSE down --remove-orphans
    docker system prune -f
    log_success "清理完成"
}

# 更新函数
update() {
    log_info "更新系统..."
    if command -v git >/dev/null 2>&1; then
        git pull
    fi
    $DOCKER_COMPOSE build --no-cache
    $DOCKER_COMPOSE up -d
    log_success "更新完成"
}

# 备份函数
backup() {
    log_info "执行数据库备份..."
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="backup_${timestamp}.sql"
    
    if $DOCKER_COMPOSE exec postgres pg_dump -U iaas_user vmware_iaas > "$backup_file"; then
        log_success "数据库备份完成: $backup_file"
    else
        log_error "数据库备份失败"
        exit 1
    fi
}

# 处理命令行参数
if [ "${1:-}" = "cleanup" ]; then
    cleanup
    exit 0
elif [ "${1:-}" = "update" ]; then
    update
    exit 0
elif [ "${1:-}" = "backup" ]; then
    backup
    exit 0
else
    main "$@"
fi
