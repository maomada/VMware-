#!/bin/bash
# VMware IaaS 统一管理脚本

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
    else
        COMPOSE="docker-compose"
    fi
}

# 显示帮助
show_help() {
    echo "VMware IaaS 管理工具"
    echo ""
    echo "用法: ./manage.sh [命令]"
    echo ""
    echo "命令:"
    echo "  start       启动所有服务"
    echo "  stop        停止所有服务"
    echo "  restart     重启所有服务"
    echo "  status      查看服务状态"
    echo "  logs        查看日志 (可选: logs app/nginx/postgres)"
    echo "  init-db     初始化数据库"
    echo "  backup      备份数据库"
    echo "  clean       清理所有数据（危险）"
    echo "  update      更新并重启服务"
    echo "  help        显示帮助"
}

detect_compose

case "${1:-help}" in
    start)
        echo -e "${GREEN}启动服务...${NC}"
        $COMPOSE up -d
        echo "✅ 服务已启动"
        echo "访问: http://$(hostname -I | awk '{print $1}')"
        ;;
    stop)
        echo -e "${YELLOW}停止服务...${NC}"
        $COMPOSE down
        echo "✅ 服务已停止"
        ;;
    restart)
        echo -e "${BLUE}重启服务...${NC}"
        $COMPOSE restart ${2:-}
        echo "✅ 服务已重启"
        ;;
    status)
        $COMPOSE ps
        echo ""
        echo "健康检查:"
        curl -s http://localhost/api/health 2>/dev/null && echo "✅ API正常" || echo "❌ API异常"
        ;;
    logs)
        $COMPOSE logs -f ${2:-}
        ;;
    init-db)
        echo -e "${BLUE}初始化数据库...${NC}"
        $COMPOSE exec app python init_database.py --init
        echo "✅ 数据库初始化完成"
        ;;
    backup)
        echo -e "${BLUE}备份数据库...${NC}"
        $COMPOSE exec app python backup_manager.py --backup
        ;;
    clean)
        echo -e "${RED}⚠️  警告：将删除所有数据！${NC}"
        read -p "输入 'DELETE' 确认: " confirm
        if [[ "$confirm" == "DELETE" ]]; then
            $COMPOSE down -v
            echo "✅ 清理完成"
        fi
        ;;
    update)
        echo -e "${BLUE}更新服务...${NC}"
        git pull
        $COMPOSE build --no-cache
        $COMPOSE up -d
        echo "✅ 更新完成"
        ;;
    *)
        show_help
        ;;
esac
