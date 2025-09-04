#!/bin/bash
# VMware IaaS 统一管理脚本 v2.0

set -e

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 检测Docker Compose版本
detect_compose() {
    if docker compose version &> /dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE="docker-compose"
    else
        echo -e "${RED}❌ Docker Compose未找到${NC}"
        exit 1
    fi
}

# 显示帮助
show_help() {
    echo "VMware IaaS 管理工具 v2.0"
    echo ""
    echo "用法: ./manage.sh [命令] [参数]"
    echo ""
    echo "🚀 部署命令:"
    echo "  deploy      完整部署系统"
    echo "  start       启动所有服务"
    echo "  stop        停止所有服务"
    echo "  restart     重启服务 [可选: 服务名]"
    echo ""
    echo "📊 监控命令:"
    echo "  status      查看服务状态"
    echo "  logs        查看日志 [可选: 服务名]"
    echo "  health      检查系统健康状态"
    echo "  ps          查看容器详细状态"
    echo ""
    echo "🗄️ 数据库命令:"
    echo "  init-db     初始化数据库"
    echo "  backup      备份数据库"
    echo "  restore     恢复数据库备份 [备份文件]"
    echo "  reset-db    重置数据库（危险）"
    echo ""
    echo "🔧 维护命令:"
    echo "  update      更新并重启服务"
    echo "  rebuild     重新构建镜像"
    echo "  clean       清理所有数据（危险）"
    echo "  reset       重置整个系统"
    echo "  prune       清理无用的Docker资源"
    echo ""
    echo "📋 配置命令:"
    echo "  config      显示当前配置"
    echo "  env         编辑环境变量"
    echo "  test        测试系统功能"
    echo ""
    echo "🔍 调试命令:"
    echo "  shell       进入容器 [容器名，默认app]"
    echo "  exec        在容器中执行命令 [容器名] [命令]"
    echo "  tail        实时查看日志 [服务名]"
    echo ""
    echo "示例:"
    echo "  ./manage.sh deploy          # 首次部署"
    echo "  ./manage.sh logs app        # 查看应用日志"
    echo "  ./manage.sh restart nginx   # 重启nginx服务"
    echo "  ./manage.sh backup          # 备份数据库"
    echo "  ./manage.sh shell postgres  # 进入数据库容器"
    echo ""
    echo "更多帮助: https://github.com/your-repo/vmware-iaas"
}

# 获取服务器IP
get_server_ip() {
    ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "localhost"
}

# 检查服务健康状态
check_health() {
    echo "🔍 系统健康检查"
    echo "=========================="
    
    # 检查容器状态
    echo "📦 容器状态:"
    $COMPOSE ps --format table
    echo ""
    
    # 检查各个服务
    services=("postgres" "redis" "app" "nginx")
    
    for service in "${services[@]}"; do
        if $COMPOSE ps | grep -q "$service.*running"; then
            echo -e "✅ $service: ${GREEN}运行中${NC}"
        else
            echo -e "❌ $service: ${RED}未运行${NC}"
        fi
    done
    
    echo ""
    echo "🌐 网络检查:"
    
    # 检查应用API
    if curl -s -f http://localhost:5000/api/health >/dev/null 2>&1; then
        echo -e "✅ 应用API: ${GREEN}正常${NC}"
        health_status=$(curl -s http://localhost:5000/api/health | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "未知")
        echo "   健康状态: $health_status"
        
        # 显示详细健康信息
        echo "   详细信息:"
        curl -s http://localhost:5000/api/health | python3 -m json.tool 2>/dev/null | sed 's/^/     /' || echo "     无法解析健康检查响应"
    else
        echo -e "❌ 应用API: ${RED}异常${NC}"
    fi
    
    # 检查Web访问
    if curl -s -f http://localhost >/dev/null 2>&1; then
        echo -e "✅ Web访问: ${GREEN}正常${NC}"
    else
        echo -e "❌ Web访问: ${RED}异常${NC}"
    fi
    
    # 检查数据库
    if $COMPOSE exec -T postgres pg_isready -U iaas_user -d vmware_iaas >/dev/null 2>&1; then
        echo -e "✅ 数据库: ${GREEN}正常${NC}"
        # 显示数据库统计
        echo "   数据库信息:"
        $COMPOSE exec -T postgres psql -U iaas_user -d vmware_iaas -c "
            SELECT 
                schemaname,
                tablename,
                n_tup_ins as inserts,
                n_tup_upd as updates,
                n_tup_del as deletes
            FROM pg_stat_user_tables 
            ORDER BY schemaname, tablename;
        " 2>/dev/null | sed 's/^/     /' || echo "     无法获取数据库统计"
    else
        echo -e "❌ 数据库: ${RED}异常${NC}"
    fi
    
    # 检查Redis
    if $COMPOSE exec -T redis redis-cli --no-auth-warning ping >/dev/null 2>&1; then
        echo -e "✅ Redis: ${GREEN}正常${NC}"
    else
        echo -e "❌ Redis: ${RED}异常${NC}"
    fi
    
    echo ""
    echo "💾 资源使用:"
    # Docker资源使用情况
    echo "   Docker资源:"
    docker system df | sed 's/^/     /'
    
    echo ""
    echo "🔗 访问地址:"
    SERVER_IP=$(get_server_ip)
    echo "   主页: http://$SERVER_IP"
    echo "   登录: http://$SERVER_IP/static/login.html"
    echo "   控制台: http://$SERVER_IP/dashboard"
    echo "   API健康检查: http://$SERVER_IP/api/health"
    
    if $COMPOSE ps | grep -q "grafana.*running"; then
        echo "   监控面板: http://$SERVER_IP:3000"
    fi
    
    if $COMPOSE ps | grep -q "prometheus.*running"; then
        echo "   Prometheus: http://$SERVER_IP:9090"
    fi
}

# 显示配置信息
show_config() {
    echo "📋 当前配置"
    echo "=========================="
    
    if [ -f .env ]; then
        echo "环境变量文件: .env"
        echo "主要配置:"
        echo "  数据库密码: $(grep DB_PASSWORD .env | cut -d'=' -f2 | sed 's/./*/g')"
        echo "  Redis密码: $(grep REDIS_PASSWORD .env | cut -d'=' -f2 | sed 's/./*/g')"
        echo "  LDAP服务器: $(grep LDAP_SERVER .env | cut -d'=' -f2 || echo "未配置")"
        echo "  vCenter主机: $(grep VCENTER_HOST .env | cut -d'=' -f2 || echo "未配置")"
        echo "  网络段1: $(grep NETWORK_SEGMENT_1 .env | cut -d'=' -f2 || echo "192.168.100.0/24")"
        echo "  网络段2: $(grep NETWORK_SEGMENT_2 .env | cut -d'=' -f2 || echo "192.168.101.0/24")"
        echo "  网络段3: $(grep NETWORK_SEGMENT_3 .env | cut -d'=' -f2 || echo "192.168.102.0/24")"
        echo "  日志级别: $(grep LOG_LEVEL .env | cut -d'=' -f2 || echo "INFO")"
    else
        echo -e "${YELLOW}⚠️  .env文件不存在${NC}"
    fi
    
    echo ""
    echo "Docker配置:"
    echo "  Compose版本: $($COMPOSE version --short 2>/dev/null || echo "未知")"
    echo "  使用命令: $COMPOSE"
    echo "  Docker版本: $(docker --version 2>/dev/null || echo "未知")"
    
    echo ""
    echo "目录结构:"
    for dir in nginx logs backups ssl monitoring static; do
        if [ -d "$dir" ]; then
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo -e "  $dir/: ${GREEN}存在${NC} ($size)"
        else
            echo -e "  $dir/: ${YELLOW}不存在${NC}"
        fi
    done
    
    echo ""
    echo "网络配置:"
    $COMPOSE exec -T app python3 -c "
import os
print(f'  网络段1: {os.environ.get(\"NETWORK_SEGMENT_1\", \"未配置\")}')
print(f'  网络段2: {os.environ.get(\"NETWORK_SEGMENT_2\", \"未配置\")}')
print(f'  网络段3: {os.environ.get(\"NETWORK_SEGMENT_3\", \"未配置\")}')
" 2>/dev/null || echo "  无法获取网络配置"
}

# 测试系统功能
test_system() {
    echo "🧪 系统功能测试"
    echo "=========================="
    
    # 测试API接口
    echo "1. 测试API健康检查..."
    if curl -s -f http://localhost:5000/api/health >/dev/null; then
        echo -e "   ${GREEN}✅ API健康检查通过${NC}"
    else
        echo -e "   ${RED}❌ API健康检查失败${NC}"
    fi
    
    # 测试数据库连接
    echo "2. 测试数据库连接..."
    if $COMPOSE exec -T app python3 -c "
from app import app, db
with app.app_context():
    db.session.execute('SELECT 1')
    print('Database connection OK')
" 2>/dev/null; then
        echo -e "   ${GREEN}✅ 数据库连接正常${NC}"
    else
        echo -e "   ${RED}❌ 数据库连接失败${NC}"
    fi
    
    # 测试Redis连接
    echo "3. 测试Redis连接..."
    if $COMPOSE exec -T redis redis-cli ping >/dev/null 2>&1; then
        echo -e "   ${GREEN}✅ Redis连接正常${NC}"
    else
        echo -e "   ${RED}❌ Redis连接失败${NC}"
    fi
    
    # 测试Web访问
    echo "4. 测试Web页面访问..."
    if curl -s -f http://localhost/static/login.html >/dev/null; then
        echo -e "   ${GREEN}✅ 登录页面可访问${NC}"
    else
        echo -e "   ${RED}❌ 登录页面不可访问${NC}"
    fi
    
    # 测试API接口
    echo "5. 测试模板API..."
    if curl -s -f http://localhost:5000/api/templates >/dev/null; then
        echo -e "   ${GREEN}✅ 模板API可访问${NC}"
    else
        echo -e "   ${RED}❌ 模板API不可访问${NC}"
    fi
    
    echo ""
    echo "测试完成！"
}

detect_compose

case "${1:-help}" in
    deploy)
        echo -e "${BLUE}🚀 开始部署VMware IaaS Platform...${NC}"
        if [ -f deploy.sh ]; then
            ./deploy.sh "${@:2}"
        else
            echo -e "${RED}❌ deploy.sh文件不存在${NC}"
            exit 1
        fi
        ;;
    start)
        echo -e "${GREEN}🔄 启动所有服务...${NC}"
        $COMPOSE up -d
        echo -e "${GREEN}✅ 服务已启动${NC}"
        echo "访问地址: http://$(get_server_ip)"
        ;;
    stop)
        echo -e "${YELLOW}⏹️  停止所有服务...${NC}"
        $COMPOSE down
        echo -e "${GREEN}✅ 服务已停止${NC}"
        ;;
    restart)
        echo -e "${BLUE}🔄 重启服务...${NC}"
        if [ -n "${2:-}" ]; then
            echo "重启服务: $2"
            $COMPOSE restart "$2"
        else
            echo "重启所有服务"
            $COMPOSE restart
        fi
        echo -e "${GREEN}✅ 服务已重启${NC}"
        ;;
    status)
        $COMPOSE ps
        ;;
    ps)
        echo "详细容器状态:"
        $COMPOSE ps --format table
        echo ""
        echo "Docker系统信息:"
        docker system df
        ;;
    health)
        check_health
        ;;
    logs)
        if [ -n "${2:-}" ]; then
            echo "查看服务日志: $2"
            $COMPOSE logs -f "$2"
        else
            echo "查看所有日志（按Ctrl+C退出）"
            $COMPOSE logs -f
        fi
        ;;
    tail)
        service="${2:-app}"
        echo "实时查看 $service 日志（按Ctrl+C退出）"
        $COMPOSE logs -f --tail=50 "$service"
        ;;
    init-db)
        echo -e "${BLUE}🗄️  初始化数据库...${NC}"
        if $COMPOSE exec app python3 -c "
from app import app, db
with app.app_context():
    db.create_all()
    print('✅ 数据库初始化完成')
"; then
            echo -e "${GREEN}✅ 数据库初始化成功${NC}"
        else
            echo -e "${RED}❌ 数据库初始化失败${NC}"
            exit 1
        fi
        ;;
    backup)
        echo -e "${BLUE}💾 备份数据库...${NC}"
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_file="backup_${timestamp}.sql"
        
        if $COMPOSE exec postgres pg_dump -U iaas_user vmware_iaas > "$backup_file"; then
            echo -e "${GREEN}✅ 数据库备份完成: $backup_file${NC}"
            echo "备份文件大小: $(du -h "$backup_file" | cut -f1)"
        else
            echo -e "${RED}❌ 数据库备份失败${NC}"
            exit 1
        fi
        ;;
    restore)
        echo -e "${BLUE}📥 恢复数据库...${NC}"
        if [ -z "${2:-}" ]; then
            echo "用法: ./manage.sh restore <备份文件>"
            echo "可用备份:"
            ls -la backup_*.sql 2>/dev/null || echo "无备份文件"
            exit 1
        fi
        
        if [ ! -f "$2" ]; then
            echo -e "${RED}❌ 备份文件不存在: $2${NC}"
            exit 1
        fi
        
        echo -e "${YELLOW}⚠️  这将覆盖现有数据，确认继续吗？ (y/N)${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            $COMPOSE exec -T postgres psql -U iaas_user -d vmware_iaas < "$2"
            echo -e "${GREEN}✅ 数据库恢复完成${NC}"
        else
            echo "操作已取消"
        fi
        ;;
    reset-db)
        echo -e "${RED}⚠️  这将删除所有数据库数据！${NC}"
        echo -n "输入 'RESET' 确认: "
        read -r confirm
        if [[ "$confirm" == "RESET" ]]; then
            $COMPOSE exec postgres psql -U iaas_user -d vmware_iaas -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
            $COMPOSE exec app python3 -c "
from app import app, db
with app.app_context():
    db.create_all()
    print('数据库已重置')
"
            echo -e "${GREEN}✅ 数据库重置完成${NC}"
        else
            echo "操作已取消"
        fi
        ;;
    update)
        echo -e "${BLUE}🔄 更新服务...${NC}"
        if command -v git >/dev/null 2>&1; then
            echo "拉取最新代码..."
            git pull
        fi
        echo "重新构建镜像..."
        $COMPOSE build --no-cache
        echo "重启服务..."
        $COMPOSE up -d
        echo -e "${GREEN}✅ 更新完成${NC}"
        ;;
    rebuild)
        echo -e "${BLUE}🔨 重新构建镜像...${NC}"
        $COMPOSE build --no-cache
        $COMPOSE up -d
        echo -e "${GREEN}✅ 重建完成${NC}"
        ;;
    clean)
        echo -e "${RED}⚠️  警告：这将删除所有数据！${NC}"
        echo "包括数据库数据、日志、备份等"
        echo -n "输入 'DELETE' 确认: "
        read -r confirm
        if [[ "$confirm" == "DELETE" ]]; then
            $COMPOSE down -v --remove-orphans
            docker system prune -f
            rm -rf logs/* backups/* 2>/dev/null || true
            echo -e "${GREEN}✅ 清理完成${NC}"
        else
            echo "操作已取消"
        fi
        ;;
    prune)
        echo -e "${BLUE}🧹 清理Docker资源...${NC}"
        echo "清理前："
        docker system df
        echo ""
        docker system prune -f
        docker volume prune -f
        docker image prune -f
        echo ""
        echo "清理后："
        docker system df
        echo -e "${GREEN}✅ 资源清理完成${NC}"
        ;;
    reset)
        echo -e "${RED}⚠️  这将重置整个系统到初始状态！${NC}"
        echo -n "输入 'RESET' 确认: "
        read -r confirm
        if [[ "$confirm" == "RESET" ]]; then
            $COMPOSE down -v --remove-orphans
            docker system prune -f
            rm -rf logs/* backups/* 2>/dev/null || true
            echo -e "${YELLOW}重新部署...${NC}"
            if [ -f deploy.sh ]; then
                ./deploy.sh
            else
                $COMPOSE up -d
            fi
            echo -e "${GREEN}✅ 重置完成${NC}"
        else
            echo "操作已取消"
        fi
        ;;
    config)
        show_config
        ;;
    test)
        test_system
        ;;
    env)
        if [ ! -f .env ]; then
            echo -e "${RED}.env文件不存在${NC}"
            exit 1
        fi
        
        if command -v nano >/dev/null 2>&1; then
            nano .env
        elif command -v vim >/dev/null 2>&1; then
            vim .env
        elif command -v vi >/dev/null 2>&1; then
            vi .env
        else
            echo "请手动编辑 .env 文件"
            echo "当前内容:"
            cat .env
        fi
        ;;
    shell)
        service="${2:-app}"
        echo "进入 $service 容器..."
        if $COMPOSE ps | grep -q "$service.*running"; then
            $COMPOSE exec "$service" /bin/bash
        else
            echo -e "${RED}❌ 服务 $service 未运行${NC}"
            exit 1
        fi
        ;;
    exec)
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "用法: ./manage.sh exec <容器名> <命令>"
            echo "示例: ./manage.sh exec app python3 -c 'print(\"Hello\")'"
            exit 1
        fi
        service="$2"
        command="${@:3}"
        if $COMPOSE ps | grep -q "$service.*running"; then
            $COMPOSE exec "$service" $command
        else
            echo -e "${RED}❌ 服务 $service 未运行${NC}"
            exit 1
        fi
        ;;
    monitor)
        echo "📊 系统监控面板"
        echo "=========================="
        
        # 显示实时容器状态
        while true; do
            clear
            echo "📊 VMware IaaS 实时监控 $(date)"
            echo "========================================"
            
            # 容器状态
            echo ""
            echo "📦 容器状态:"
            $COMPOSE ps --format table
            
            # 资源使用
            echo ""
            echo "💾 资源使用:"
            docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
            
            # 健康状态
            echo ""
            echo "🔍 健康检查:"
            if curl -s -f http://localhost:5000/api/health >/dev/null 2>&1; then
                echo -e "✅ API: ${GREEN}正常${NC}"
            else
                echo -e "❌ API: ${RED}异常${NC}"
            fi
            
            echo ""
            echo "按 Ctrl+C 退出监控"
            sleep 5
        done
        ;;
    *)
        show_help
        ;;
esac
