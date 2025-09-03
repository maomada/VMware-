// VMware IaaS Platform - 前端应用脚本
// 版本: 2.0

// API基础配置
const API_BASE_URL = window.location.origin + '/api';
let authToken = localStorage.getItem('auth_token');
let currentUser = null;
let allVMs = [];
let allProjects = [];
let filteredVMs = [];

// 页面初始化
document.addEventListener('DOMContentLoaded', function() {
    if (!authToken) {
        window.location.href = '/static/login.html';
        return;
    }

    initializeApp();
});

// 初始化应用
async function initializeApp() {
    try {
        showLoadingState();
        
        await loadUserProfile();
        await loadSystemStats();
        await loadVMs();
        await loadProjects();
        await loadTemplates();
        
        initializeDatePickers();
        setupEventListeners();
        
        hideLoadingState();
    } catch (error) {
        console.error('App initialization failed:', error);
        handleInitializationError();
    }
}

// 显示加载状态
function showLoadingState() {
    // 可以添加全局加载指示器
}

// 隐藏加载状态
function hideLoadingState() {
    // 隐藏全局加载指示器
}

// 处理初始化错误
function handleInitializationError() {
    showAlert('系统初始化失败，请刷新页面重试', 'danger');
}

// API请求封装
async function apiRequest(url, options = {}) {
    const headers = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${authToken}`,
        ...options.headers
    };

    try {
        const response = await fetch(`${API_BASE_URL}${url}`, {
            ...options,
            headers
        });

        if (response.status === 401) {
            localStorage.removeItem('auth_token');
            localStorage.removeItem('user_info');
            window.location.href = '/static/login.html';
            return null;
        }

        const data = await response.json();
        
        if (!response.ok) {
            throw new Error(data.error || 'Request failed');
        }

        return data;
    } catch (error) {
        console.error('API request failed:', error);
        showAlert(error.message, 'danger');
        return null;
    }
}

// 用户相关函数
async function loadUserProfile() {
    const data = await apiRequest('/auth/profile');
    if (data) {
        currentUser = data.user;
        updateUserDisplay();
    }
}

function updateUserDisplay() {
    if (!currentUser) return;
    
    const displayNameEl = document.getElementById('user-display-name');
    const avatarEl = document.getElementById('user-avatar');
    
    if (displayNameEl) {
        displayNameEl.textContent = currentUser.display_name || currentUser.username;
    }
    
    if (avatarEl) {
        const initials = (currentUser.display_name || currentUser.username)
            .split(' ')
            .map(name => name[0])
            .join('')
            .toUpperCase()
            .slice(0, 2);
        avatarEl.textContent = initials;
    }
}

async function logout() {
    try {
        await apiRequest('/auth/logout', { method: 'POST' });
    } catch (error) {
        console.error('Logout error:', error);
    } finally {
        localStorage.removeItem('auth_token');
        localStorage.removeItem('user_info');
        window.location.href = '/static/login.html';
    }
}

// 系统统计
async function loadSystemStats() {
    const data = await apiRequest('/system/stats');
    if (data) {
        renderStats(data);
    }
}

function renderStats(stats) {
    const statsGrid = document.getElementById('stats-grid');
    if (!statsGrid) return;
    
    const statCards = [
        {
            number: stats.vms.total,
            label: '总虚拟机数',
            icon: '💻',
            color: '#667eea'
        },
        {
            number: stats.vms.running,
            label: '运行中',
            icon: '✅',
            color: '#27ae60'
        },
        {
            number: stats.vms.stopped,
            label: '已停止',
            icon: '⏹️',
            color: '#e74c3c'
        },
        {
            number: stats.vms.expiring_soon,
            label: '即将过期',
            icon: '⚠️',
            color: '#f39c12'
        },
        {
            number: `${stats.resources.total_cpu_cores}`,
            label: '总CPU核数',
            icon: '⚡',
            color: '#9b59b6'
        },
        {
            number: `${stats.resources.total_memory_gb}GB`,
            label: '总内存',
            icon: '🧠',
            color: '#3498db'
        },
        {
            number: `${stats.resources.total_disk_gb}GB`,
            label: '总磁盘',
            icon: '💾',
            color: '#1abc9c'
        },
        {
            number: stats.projects.total,
            label: '项目数量',
            icon: '📁',
            color: '#34495e'
        }
    ];

    statsGrid.innerHTML = statCards.map(stat => `
        <div class="stat-card">
            <div class="stat-number" style="color: ${stat.color};">
                ${stat.icon} ${stat.number}
            </div>
            <div class="stat-label">${stat.label}</div>
        </div>
    `).join('');
}

// 虚拟机管理
async function loadVMs() {
    const data = await apiRequest('/vms');
    if (data) {
        allVMs = data.vms;
        filteredVMs = [...allVMs];
        renderVMs(filteredVMs);
        renderRecentVMs(allVMs.slice(0, 5));
    }
}

function renderVMs(vms) {
    const vmsGrid = document.getElementById('vms-grid');
    if (!vmsGrid) return;
    
    if (vms.length === 0) {
        vmsGrid.innerHTML = `
            <div class="empty-state">
                <div class="empty-icon">💻</div>
                <h3>暂无虚拟机</h3>
                <p>您还没有创建任何虚拟机<br>点击"创建虚拟机"开始使用</p>
                <button class="btn btn-primary" onclick="showTab('create')">创建虚拟机</button>
            </div>
        `;
        return;
    }

    vmsGrid.innerHTML = vms.map(vm => `
        <div class="vm-card ${getVMCardClass(vm)}" data-vm-id="${vm.id}">
            <div class="vm-header">
                <div class="vm-name">${escapeHtml(vm.name)}</div>
                <div class="vm-status status-${vm.status}">${getStatusText(vm.status)}</div>
            </div>
            <div class="vm-info">
                <div class="vm-info-row">
                    <span><strong>项目:</strong></span>
                    <span>${escapeHtml(vm.project_name)} (${escapeHtml(vm.project_code)})</span>
                </div>
                <div class="vm-info-row">
                    <span><strong>申请人:</strong></span>
                    <span>${escapeHtml(vm.owner)}</span>
                </div>
                <div class="vm-info-row">
                    <span><strong>IP地址:</strong></span>
                    <span>${vm.ip_address || '分配中...'}</span>
                </div>
                <div class="vm-info-row">
                    <span><strong>配置:</strong></span>
