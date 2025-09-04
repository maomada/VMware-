#!/bin/bash

# VMware IaaS Platform 完整性检查脚本
# 检查所有必要的文件和配置是否完整

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

echo "========================================"
echo "VMware IaaS Platform 完整性检查"
echo "========================================"
echo ""

# 检查核心文件
log_info "检查核心文件..."

core_files=(
    "app.py:主应用文件"
    "requirements.txt:Python依赖"
    "Dockerfile:主应用容器配置"
    "Dockerfile.scheduler:定时任务容器配置"
    "docker-compose.yml:Docker编排配置"
    ".env:环境变量配置"
    "init.sql:数据库初始化脚本"
    "crontab:定时任务配置"
)

missing_core=()
for item in "${core_files[@]}"; do
    file="${item%%:*}"
    desc="${item##*:}"
    if [[ -f "$file" ]]; then
        log_success "  ✓ $file ($desc)"
    else
        log_error "  ✗ $file ($desc)"
        missing_core+=("$file")
    fi
done

# 检查前端文件
log_info "检查前端文件..."

frontend_files=(
    "static/login.html:登录页面"
    "static/index.html:主控制台页面"
    "static/app.js:前端应用脚本"
    "static/error.html:错误页面"
    "static/api-docs.html:API文档页面"
)

missing_frontend=()
for item in "${frontend_files[@]}"; do
    file="${item%%:*}"
    desc="${item##*:}"
    if [[ -f "$file" ]]; then
        log_success "  ✓ $file ($desc)"
    else
        log_error "  ✗ $file ($desc)"
        missing_frontend+=("$file")
    fi
done

# 检查配置文件
log_info "检查配置文件..."

config_files=(
    "nginx/nginx.conf:Nginx主配置"
    "nginx/conf.d/default.conf:Nginx站点配置"
    "monitoring/prometheus.yml:Prometheus配置"
    "monitoring/grafana/datasources/prometheus.yml:Grafana数据源"
    "monitoring/grafana/dashboards/dashboard.yml:Grafana仪表板配置"
    "monitoring/grafana/dashboards/vmware-iaas.json:IaaS仪表板"
)

missing_config=()
for item in "${config_files[@]}"; do
    file="${item%%:*}"
    desc="${item##*:}"
    if [[ -f "$file" ]]; then
        log_success "  ✓ $file ($desc)"
    else
        log_error "  ✗ $file ($desc)"
        missing_config+=("$file")
    fi
done

# 检查脚本文件
log_info "检查管理脚本..."

script_files=(
    "init_database.py:数据库初始化脚本"
    "scheduler.py:独立定时任务脚本"
    "backup_manager.py:数据库备份脚本"
    "deploy-complete.sh:完整部署脚本"
)

missing_scripts=()
for item in "${script_files[@]}"; do
    file="${item%%:*}"
    desc="${item##*:}"
    if [[ -f "$file" ]]; then
        log_success "  ✓ $file ($desc)"
        # 检查脚本是否可执行
        if [[ -x "$file" ]]; then
            log_success "    ↳ 可执行权限 ✓"
        else
            log_warning "    ↳ 缺少可执行权限"
        fi
    else
        log_error "  ✗ $file ($desc)"
        missing_scripts+=("$file")
    fi
done

# 检查目录结构
log_info "检查目录结构..."

required_dirs=(
    "static:静态文件目录"
    "nginx:Nginx配置目录"
    "nginx/conf.d:Nginx站点配置目录"
    "monitoring:监控配置目录"
    "monitoring/grafana:Grafana配置目录"
    "monitoring/grafana/dashboards:Grafana仪表板目录"
    "monitoring/grafana/datasources:Grafana数据源目录"
    "ssl:SSL证书目录"
    "logs:日志目录"
    "backups:备份目录"
)

missing_dirs=()
for item in "${required_dirs[@]}"; do
    dir="${item%%:*}"
    desc="${item##*:}"
    if [[ -d "$dir" ]]; then
        log_success "  ✓ $dir/ ($desc)"
    else
        log_warning "  ⚠ $dir/ ($desc) - 将自动创建"
        mkdir -p "$dir"
        missing_dirs+=("$dir")
    fi
done

# 检查Docker环境
log_info "检查Docker环境..."

if command -v docker &> /dev/null; then
    log_success "  ✓ Docker 已安装"
    docker_version=$(docker --version)
    log_info "    版本: $docker_version"
else
    log_error "  ✗ Docker 未安装"
fi

if command -v docker-compose &> /dev/null; then
    log_success "  ✓ Docker Compose 已安装"
    compose_version=$(docker-compose --version)
    log_info "    版本: $compose_version"
elif docker compose version &> /dev/null; then
    log_success "  ✓ Docker Compose Plugin 已安装"
    compose_version=$(docker compose version)
    log_info "    版本: $compose_version"
else
    log_error "  ✗ Docker Compose 未安装"
fi

# 检查环境变量配置
log_info "检查环境变量配置..."

if [[ -f ".env" ]]; then
    required_vars=(
        "DB_PASSWORD"
        "REDIS_PASSWORD"
        "SECRET_KEY"
        "LDAP_SERVER"
        "VCENTER_HOST"
        "SMTP_SERVER"
    )
    
    missing_vars=()
    for var in "${required_vars[@]}"; do
        if grep -q "^${var}=" .env; then
            value=$(grep "^${var}=" .env | cut -d'=' -f2-)
            if [[ "$value" == *"your-"* ]] || [[ "$value" == *"change"* ]] || [[ -z "$value" ]]; then
                log_warning "  ⚠ $var 需要配置实际值"
                missing_vars+=("$var")
            else
                log_success "  ✓ $var 已配置"
            fi
        else
            log_error "  ✗ $var 未定义"
            missing_vars+=("$var")
        fi
    done
else
    log_error "  ✗ .env 文件不存在"
fi

# 检查文件内容完整性
log_info "检查关键文件内容..."

# 检查app.py是否包含关键函数
if [[ -f "app.py" ]]; then
    key_functions=(
        "class VMwareManager"
        "def find_suitable_host_for_gpu"
        "def _configure_vm_network"
        "jwt_required"
        "/api/health"
        "/api/metrics"
    )
    
    for func in "${key_functions[@]}"; do
        if grep -q "$func" app.py; then
            log_success "  ✓ $func 函数存在"
        else
            log_error "  ✗ $func 函数缺失"
        fi
    done
fi

# 检查static/app.js是否完整
if [[ -f "static/app.js" ]]; then
    js_functions=(
        "loadVMs"
        "showTab"
        "filterVMs"
        "handleCreateVM"
        "loadBillingSummary"
    )
    
    for func in "${js_functions[@]}"; do
        if grep -q "$func" static/app.js; then
            log_success "  ✓ JavaScript $func 函数存在"
        else
            log_error "  ✗ JavaScript $func 函数缺失"
        fi
    done
fi

# 生成总结报告
echo ""
echo "========================================"
echo "检查总结"
echo "========================================"

total_issues=0

if [[ ${#missing_core[@]} -gt 0 ]]; then
    log_error "缺少 ${#missing_core[@]} 个核心文件"
    total_issues=$((total_issues + ${#missing_core[@]}))
fi

if [[ ${#missing_frontend[@]} -gt 0 ]]; then
    log_error "缺少 ${#missing_frontend[@]} 个前端文件"
    total_issues=$((total_issues + ${#missing_frontend[@]}))
fi

if [[ ${#missing_config[@]} -gt 0 ]]; then
    log_error "缺少 ${#missing_config[@]} 个配置文件"
    total_issues=$((total_issues + ${#missing_config[@]}))
fi

if [[ ${#missing_scripts[@]} -gt 0 ]]; then
    log_error "缺少 ${#missing_scripts[@]} 个脚本文件"
    total_issues=$((total_issues + ${#missing_scripts[@]}))
fi

if [[ ${#missing_dirs[@]} -gt 0 ]]; then
    log_warning "创建了 ${#missing_dirs[@]} 个缺失目录"
fi

echo ""
if [[ $total_issues -eq 0 ]]; then
    log_success "🎉 所有文件检查通过！系统已完整！"
    echo ""
    log_info "下一步操作:"
    echo "  1. 配置 .env 文件中的实际环境参数"
    echo "  2. 运行: ./deploy-complete.sh"
    echo "  3. 访问: http://your-server-ip"
    echo ""
    exit 0
else
    log_error "❌ 发现 $total_issues 个问题需要解决"
    echo ""
    log_info "建议操作:"
    echo "  1. 检查上述缺失的文件"
    echo "  2. 运行相应的修复命令"
    echo "  3. 重新运行此检查脚本"
    echo ""
    exit 1
fi
