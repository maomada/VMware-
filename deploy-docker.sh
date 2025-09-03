# deploy-docker.sh
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

# 检查Docker和Docker Compose
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
    
    log_success "Docker环境检查通过"
}

# 创建必要目录
create_directories() {
    log_info "创建项目目录..."
    
    mkdir -p {nginx/conf.d,ssl,static,monitoring/{prometheus,grafana/{dashboards,datasources}}}
    
    log_success "目录创建完成"
}

# 生成配置文件
generate_configs() {
    log_info "生成配置文件..."
    
    # 生成随机密码
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    SECRET_KEY=$(openssl rand -base64 64 | tr -d "\n")
    
    # 创建.env文件
    if [[ ! -f .env ]]; then
        cat > .env << EOF
# 自动生成的环境变量文件
DB_PASSWORD=$DB_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SECRET_KEY=$SECRET_KEY

# 请根据实际环境修改以下配置
LDAP_SERVER=ldap://your-ldap-server.com:389
LDAP_BASE_DN=dc=company,dc=com
LDAP_ADMIN_DN=cn=admin,dc=company,dc=com
LDAP_ADMIN_PASSWORD=your_ldap_password

VCENTER_HOST=your-vcenter-server.com
VCENTER_USER=administrator@vsphere.local
VCENTER_PASSWORD=your_vcenter_password

SMTP_SERVER=smtp.company.com
SMTP_USERNAME=iaas-system@company.com
SMTP_PASSWORD=your_smtp_password
EOF
        
        log_success "环境变量文件创建完成: .env"
        log_warning "请编辑 .env 文件配置LDAP、VMware、邮件参数"
    else
        log_info "环境变量文件已存在，跳过创建"
    fi
}

# 部署应用
deploy_application() {
    log_info "开始部署VMware IaaS Platform..."
    
    # 拉取镜像
    docker-compose pull
    
    # 构建应用镜像
    docker-compose build
    
    # 启动服务
    docker-compose up -d
    
    # 等待服务启动
    log_info "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    check_services
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    services=("postgres" "redis" "app" "nginx")
    
    for service in "${services[@]}"; do
        if docker-compose ps $service | grep -q "Up"; then
            log_success "$service 服务运行正常"
        else
            log_error "$service 服务未正常运行"
            docker-compose logs $service
        fi
    done
    
    # 检查健康状态
    log_info "检查应用健康状态..."
    sleep 5
    
    if curl -s http://localhost/health | grep -q "healthy"; then
        log_success "应用健康检查通过"
    else
        log_warning "应用健康检查失败，请查看日志"
        docker-compose logs app
    fi
}

# 显示部署信息
show_deployment_info() {
    SERVER_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "localhost")
    
    echo ""
    echo "============================================"
    echo "🎉 VMware IaaS Platform Docker部署完成！"
    echo "============================================"
    echo ""
    echo "🌐 访问信息:"
    echo "   主页: http://$SERVER_IP"
    echo "   健康检查: http://$SERVER_IP/health"
    echo "   监控面板: http://$SERVER_IP:3000 (admin/admin123)"
    echo ""
    echo "🐳 Docker服务:"
    echo "   查看状态: docker-compose ps"
    echo "   查看日志: docker-compose logs -f [service]"
    echo "   重启服务: docker-compose restart [service]"
    echo "   停止所有: docker-compose down"
    echo ""
    echo "📁 重要文件:"
    echo "   配置文件: .env"
    echo "   日志查看: docker-compose logs -f app"
    echo "   数据备份: docker-compose exec postgres pg_dump -U iaas_user vmware_iaas"
    echo ""
    echo "⚙️ 下一步:"
    echo "   1. 编辑 .env 文件配置LDAP、VMware等参数"
    echo "   2. 重启应用: docker-compose restart app"
    echo "   3. 部署前端文件到 ./static/ 目录"
    echo ""
    log_success "Docker部署完成！"
}

# 主函数
main() {
    echo "========================================"
    echo "VMware IaaS Platform Docker部署脚本"
    echo "========================================"
    echo ""
    
    check_requirements
    create_directories
    generate_configs
    deploy_application
    show_deployment_info
}

# 显示帮助信息
show_help() {
    echo "VMware IaaS Platform Docker部署脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --help     显示帮助信息"
    echo "  --deploy   完整部署（默认）"
    echo "  --status   查看服务状态"
    echo "  --logs     查看日志"
    echo "  --stop     停止所有服务"
    echo "  --restart  重启所有服务"
    echo ""
    echo "示例:"
    echo "  $0                # 完整部署"
    echo "  $0 --status       # 查看状态"
    echo "  $0 --logs app     # 查看应用日志"
}

# 处理命令行参数
case "${1:-}" in
    --help)
        show_help
        exit 0
        ;;
    --status)
        docker-compose ps
        ;;
    --logs)
        docker-compose logs -f ${2:-}
        ;;
    --stop)
        docker-compose down
        ;;
    --restart)
        docker-compose restart
        ;;
    --deploy|"")
        main
        ;;
    *)
        echo "未知选项: $1"
        show_help
        exit 1
        ;;
esac
