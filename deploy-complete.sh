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
        log_info "  创建目录: $dir"
    done
    
    log_success "目录结构创建完成"
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
        "nginx/nginx.conf"
        "nginx/conf.d/default.conf"
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
    $DOCKER_COMPOSE down --remove-orphans 2>/dev/null || true
    
    # 拉取基础镜像
    log_info "拉取基础镜像..."
    $DOCKER_COMPOSE pull --ignore-pull-failures 2>/dev/null || true
    
    # 构建应用镜像
    log_info "构建应用镜像..."
    if ! $DOCKER_COMPOSE build; then
        log_error "镜像构建失败"
        return 1
    fi
    
    # 启动服务
    log_info "启动服务..."
    if ! $DOCKER_COMPOSE up -d; then
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
        if $DOCKER_COMPOSE ps "$service" | grep -q "running"; then
            log_success "  $service: 运行正常"
        else
            log_error "  $service: 未正常运行"
            all_healthy=false
            
            # 显示错误日志
            log_info "  $service 服务日志:"
            $DOCKER_COMPOSE logs --tail=10 "$service" | sed 's/^/    /'
        fi
    done
    
    # 检查应用健康状态
    log_info "检查应用健康状态..."
    sleep 10
    
    for i in {1..5}; do
        if curl -s -f http://localhost/health > /dev/null 2>&1; then
            log_success "  应用健康检查通过"
            break
        elif curl -s -f http://localhost:80/health > /dev/null 2>&1; then
            log_success "  应用健康检查通过"
            break
        else
            if [[ $i -eq 5 ]]; then
                log_warning "  应用健康检查失败，请查看日志"
                log_info "  应用日志:"
                $DOCKER_COMPOSE logs --tail=20 app | sed 's/^/    /'
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
        if $DOCKER_COMPOSE exec postgres pg_isready -U iaas_user -d vmware_iaas > /dev/null 2>&1; then
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
    if $DOCKER_COMPOSE exec app python init_database.py --init; then
        log_success "数据库初始化完成"
    else
        log_error "数据库初始化失败，尝试手动创建表..."
        # 备用初始化方法
        if $DOCKER_COMPOSE exec app python -c "
from app import app, db
with app.app_context():
    db.create_all()
    print('Tables created successfully')
"; then
            log_success "数据库表创建成功"
        else
            log_error "数据库初始化完全失败"
            return 1
        fi
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
    echo "   控制台: http://$SERVER_IP/dashboard"
    echo "   API文档: http://$SERVER_IP/static/api-docs.html"
    echo "   健康检查: http://$SERVER_IP/health"
    echo "   监控面板: http://$SERVER_IP:3000"
    echo "   Prometheus: http://$SERVER_IP:9090"
    echo ""
    echo "🔐 默认凭据:"
    if [[ -f .env ]]; then
        grafana_pwd=$(grep GRAFANA_PASSWORD .env | cut -d'=' -f2 2>/dev/null || echo "admin123")
        echo "   Grafana: admin / $grafana_pwd"
    else
        echo "   Grafana: admin / admin123"
    fi
    echo ""
    echo "🐳 Docker 管理命令:"
    echo "   查看状态: $DOCKER_COMPOSE ps"
    echo "   查看日志: $DOCKER_COMPOSE logs -f [service]"
    echo "   重启服务: $DOCKER_COMPOSE restart [service]"
    echo "   停止所有: $DOCKER_COMPOSE down"
    echo "   完全清理: $DOCKER_COMPOSE down -v --remove-orphans"
    echo ""
    echo "📁 重要文件和目录:"
    echo "   配置文件: .env"
    echo "   日志目录: logs/"
    echo "   备份目录: backups/"
    echo "   SSL证书: ssl/"
    echo ""
    echo "🔧 下一步操作:"
    echo "   1. 使用LDAP账号登录系统"
    echo "   2. 创建第一个项目和虚拟机"
    echo "   3. 配置SSL证书 (可选)"
    echo "   4. 设置定期备份"
    echo ""
    echo "📖 获取帮助:"
    echo "   查看状态: $0 --status"
    echo "   查看日志: $0 --logs [service]"
    echo "   重启服务: $0 --restart [service]"
    echo ""
    log_success "部署完成！请根据上述信息使用系统。"
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
        detect_docker_compose
        echo "=== 服务状态 ==="
        $DOCKER_COMPOSE ps
        echo ""
        echo "=== 健康检查 ==="
        if curl -s http://localhost/health > /dev/null 2>&1; then
            echo "✅ 应用健康检查通过"
            curl -s http://localhost/health | python3 -m json.tool 2>/dev/null || echo "健康检查API响应异常"
        else
            echo "❌ 应用健康检查失败"
        fi
        ;;
    --logs)
        detect_docker_compose
        if [[ -n "${2:-}" ]]; then
            $DOCKER_COMPOSE logs -f "$2"
        else
            $DOCKER_COMPOSE logs -f
        fi
        ;;
    --stop)
        detect_docker_compose
        log_info "停止所有服务..."
        $DOCKER_COMPOSE down
        log_success "所有服务已停止"
        ;;
    --restart)
        detect_docker_compose
        if [[ -n "${2:-}" ]]; then
            log_info "重启服务: $2"
            $DOCKER_COMPOSE restart "$2"
            log_success "服务 $2 已重启"
        else
            log_info "重启所有服务..."
            $DOCKER_COMPOSE restart
            log_success "所有服务已重启"
        fi
        ;;
    --clean)
        detect_docker_compose
        echo "⚠️  WARNING: 这将删除所有数据！"
        read -p "输入 'DELETE' 确认: " confirm
        if [[ "$confirm" == "DELETE" ]]; then
            log_info "清理所有服务和数据..."
            $DOCKER_COMPOSE down -v --remove-orphans
            docker system prune -f
            log_success "清理完成"
        else
            log_info "操作已取消"
        fi
        ;;
    --update)
        detect_docker_compose
        log_info "更新服务..."
        $DOCKER_COMPOSE pull
        $DOCKER_COMPOSE build --no-cache
        $DOCKER_COMPOSE up -d
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
esac
