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
    document.body.style.cursor = 'wait';
}

// 隐藏加载状态
function hideLoadingState() {
    document.body.style.cursor = 'default';
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
                    <span>${vm.cpu_cores}核/${vm.memory_gb}GB/${vm.disk_gb}GB${vm.gpu_type ? `/${vm.gpu_type.toUpperCase()}x${vm.gpu_count}` : ''}</span>
                </div>
                <div class="vm-info-row">
                    <span><strong>到期时间:</strong></span>
                    <span>${formatDateTime(vm.deadline)} (${vm.days_until_expiry}天)</span>
                </div>
            </div>
            <div class="vm-actions">
                ${generateVMActions(vm)}
            </div>
        </div>
    `).join('');
}

function renderRecentVMs(vms) {
    const recentVmsEl = document.getElementById('recent-vms');
    if (!recentVmsEl) return;
    
    if (vms.length === 0) {
        recentVmsEl.innerHTML = '<p class="empty-state">暂无虚拟机</p>';
        return;
    }
    
    recentVmsEl.innerHTML = vms.map(vm => `
        <div class="vm-card ${getVMCardClass(vm)}">
            <div class="vm-header">
                <div class="vm-name">${escapeHtml(vm.name)}</div>
                <div class="vm-status status-${vm.status}">${getStatusText(vm.status)}</div>
            </div>
            <div class="vm-info">
                <div class="vm-info-row">
                    <span><strong>项目:</strong></span>
                    <span>${escapeHtml(vm.project_name)}</span>
                </div>
                <div class="vm-info-row">
                    <span><strong>创建时间:</strong></span>
                    <span>${formatDateTime(vm.created_at)}</span>
                </div>
            </div>
        </div>
    `).join('');
}

function getVMCardClass(vm) {
    if (vm.status === 'expired' || vm.days_until_expiry <= 0) return 'expired';
    if (vm.days_until_expiry <= 7) return 'expiring';
    return '';
}

function getStatusText(status) {
    const statusMap = {
        'running': '运行中',
        'stopped': '已停止',
        'creating': '创建中',
        'expired': '已过期',
        'deleted': '已删除'
    };
    return statusMap[status] || status;
}

function generateVMActions(vm) {
    let actions = [];
    
    if (vm.status === 'stopped') {
        actions.push(`<button class="btn btn-success" onclick="powerOnVM(${vm.id})">🔋 开机</button>`);
    } else if (vm.status === 'running') {
        actions.push(`<button class="btn btn-danger" onclick="powerOffVM(${vm.id})">⏹️ 关机</button>`);
        actions.push(`<button class="btn btn-warning" onclick="restartVM(${vm.id})">🔄 重启</button>`);
    }
    
    actions.push(`<button class="btn btn-info" onclick="showVMDetails(${vm.id})">📊 详情</button>`);
    actions.push(`<button class="btn btn-danger" onclick="deleteVM(${vm.id})">🗑️ 删除</button>`);
    
    return actions.join('');
}

// 虚拟机电源操作
async function powerOnVM(vmId) {
    const result = await apiRequest(`/vms/${vmId}/power/on`, { method: 'POST' });
    if (result) {
        showAlert('虚拟机启动成功', 'success');
        await loadVMs();
    }
}

async function powerOffVM(vmId) {
    if (confirm('确定要关闭这台虚拟机吗？')) {
        const result = await apiRequest(`/vms/${vmId}/power/off`, { method: 'POST' });
        if (result) {
            showAlert('虚拟机关闭成功', 'success');
            await loadVMs();
        }
    }
}

async function restartVM(vmId) {
    if (confirm('确定要重启这台虚拟机吗？')) {
        const result = await apiRequest(`/vms/${vmId}/power/restart`, { method: 'POST' });
        if (result) {
            showAlert('虚拟机重启成功', 'success');
            await loadVMs();
        }
    }
}

async function deleteVM(vmId) {
    if (confirm('确定要删除这台虚拟机吗？此操作不可恢复！')) {
        const result = await apiRequest(`/vms/${vmId}`, { method: 'DELETE' });
        if (result) {
            showAlert('虚拟机删除成功', 'success');
            await loadVMs();
        }
    }
}

// 虚拟机详情
async function showVMDetails(vmId) {
    const vm = allVMs.find(v => v.id === vmId);
    if (!vm) return;
    
    document.getElementById('modal-vm-name').textContent = vm.name;
    
    let detailsHtml = `
        <div class="vm-info">
            <h3>基本信息</h3>
            <div class="vm-info-row">
                <span><strong>虚拟机名称:</strong></span>
                <span>${escapeHtml(vm.name)}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>项目:</strong></span>
                <span>${escapeHtml(vm.project_name)} (${escapeHtml(vm.project_code)})</span>
            </div>
            <div class="vm-info-row">
                <span><strong>申请人:</strong></span>
                <span>${escapeHtml(vm.owner)}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>状态:</strong></span>
                <span class="vm-status status-${vm.status}">${getStatusText(vm.status)}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>IP地址:</strong></span>
                <span>${vm.ip_address || '分配中...'}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>主机:</strong></span>
                <span>${vm.host_name || '自动分配'}</span>
            </div>
            
            <h3>资源配置</h3>
            <div class="vm-info-row">
                <span><strong>CPU核数:</strong></span>
                <span>${vm.cpu_cores}核</span>
            </div>
            <div class="vm-info-row">
                <span><strong>内存:</strong></span>
                <span>${vm.memory_gb}GB</span>
            </div>
            <div class="vm-info-row">
                <span><strong>磁盘:</strong></span>
                <span>${vm.disk_gb}GB</span>
            </div>
            ${vm.gpu_type ? `
            <div class="vm-info-row">
                <span><strong>GPU:</strong></span>
                <span>${vm.gpu_type.toUpperCase()} x ${vm.gpu_count}张</span>
            </div>
            ` : ''}
            
            <h3>时间信息</h3>
            <div class="vm-info-row">
                <span><strong>创建时间:</strong></span>
                <span>${formatDateTime(vm.created_at)}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>到期时间:</strong></span>
                <span>${formatDateTime(vm.deadline)}</span>
            </div>
            <div class="vm-info-row">
                <span><strong>剩余天数:</strong></span>
                <span style="color: ${vm.days_until_expiry <= 7 ? '#e74c3c' : '#27ae60'}">${vm.days_until_expiry}天</span>
            </div>
        </div>
    `;
    
    // 如果虚拟机在运行，显示监控数据
    if (vm.status === 'running' && vm.metrics) {
        detailsHtml += `
            <h3>监控数据</h3>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-value">${vm.metrics.cpu_usage_percent}%</div>
                    <div class="metric-label">CPU使用率</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${vm.metrics.memory_usage_mb}MB</div>
                    <div class="metric-label">内存使用</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${vm.metrics.disk_usage_gb.toFixed(1)}GB</div>
                    <div class="metric-label">磁盘使用</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value">${Math.floor(vm.metrics.uptime_seconds / 3600)}小时</div>
                    <div class="metric-label">运行时间</div>
                </div>
            </div>
        `;
    }
    
    document.getElementById('vm-details-content').innerHTML = detailsHtml;
    document.getElementById('vm-modal').style.display = 'block';
}

// 项目管理
async function loadProjects() {
    const data = await apiRequest('/projects');
    if (data) {
        allProjects = data.projects;
        updateProjectFilters();
    }
}

function updateProjectFilters() {
    const projectFilter = document.getElementById('project-filter');
    const billingProjectFilter = document.getElementById('billing-project-filter');
    
    if (projectFilter) {
        projectFilter.innerHTML = '<option value="">所有项目</option>' +
            allProjects.map(p => `<option value="${p.id}">${p.project_name} (${p.project_code})</option>`).join('');
    }
    
    if (billingProjectFilter) {
        billingProjectFilter.innerHTML = '<option value="">所有项目</option>' +
            allProjects.map(p => `<option value="${p.id}">${p.project_name} (${p.project_code})</option>`).join('');
    }
}

// 模板管理
async function loadTemplates() {
    const data = await apiRequest('/templates');
    if (data) {
        updateTemplateSelect(data.templates);
    }
}

function updateTemplateSelect(templates) {
    const templateSelect = document.getElementById('vm-template');
    if (templateSelect) {
        templateSelect.innerHTML = '<option value="">请选择模板</option>' +
            templates.map(t => `<option value="${t.name}">${t.display_name}</option>`).join('');
    }
}

// 标签页切换
function showTab(tabName) {
    // 隐藏所有标签页内容
    document.querySelectorAll('.tab-content').forEach(tab => {
        tab.classList.remove('active');
    });
    
    // 移除所有按钮的active类
    document.querySelectorAll('.tab-button').forEach(btn => {
        btn.classList.remove('active');
    });
    
    // 显示选中的标签页
    const selectedTab = document.getElementById(`${tabName}-tab`);
    if (selectedTab) {
        selectedTab.classList.add('active');
    }
    
    // 激活对应按钮
    event.target.classList.add('active');
    
    // 根据不同标签页加载数据
    switch(tabName) {
        case 'overview':
            loadSystemStats();
            break;
        case 'vms':
            loadVMs();
            break;
        case 'billing':
            loadBillingSummary();
            break;
        case 'create':
            resetCreateForm();
            break;
    }
}

// 筛选功能
function filterVMs() {
    const searchTerm = document.getElementById('vm-search').value.toLowerCase();
    const projectFilter = document.getElementById('project-filter').value;
    const statusFilter = document.getElementById('status-filter').value;
    
    filteredVMs = allVMs.filter(vm => {
        const matchesSearch = !searchTerm || 
            vm.name.toLowerCase().includes(searchTerm) ||
            vm.owner.toLowerCase().includes(searchTerm) ||
            vm.project_name.toLowerCase().includes(searchTerm);
        
        const matchesProject = !projectFilter || vm.project_id == projectFilter;
        const matchesStatus = !statusFilter || vm.status === statusFilter;
        
        return matchesSearch && matchesProject && matchesStatus;
    });
    
    renderVMs(filteredVMs);
}

async function refreshVMs() {
    await loadVMs();
    showAlert('虚拟机列表已刷新', 'success');
}

// 创建虚拟机
function setupEventListeners() {
    const createForm = document.getElementById('create-vm-form');
    if (createForm) {
        createForm.addEventListener('submit', handleCreateVM);
    }
}

async function handleCreateVM(event) {
    event.preventDefault();
    
    const formData = {
        name: document.getElementById('vm-name').value,
        template_name: document.getElementById('vm-template').value,
        project_name: document.getElementById('project-name').value,
        project_code: document.getElementById('project-code').value,
        owner: document.getElementById('vm-owner').value,
        deadline: document.getElementById('vm-deadline').value,
        cpu_cores: document.getElementById('vm-cpu').value,
        memory_gb: document.getElementById('vm-memory').value,
        disk_gb: document.getElementById('vm-disk').value,
        gpu_type: document.getElementById('vm-gpu-type').value || null,
        gpu_count: document.getElementById('vm-gpu-count').value || 0
    };
    
    // 查找或创建项目
    let project = allProjects.find(p => p.project_code === formData.project_code);
    if (!project) {
        // 创建新项目
        const projectData = await apiRequest('/projects', {
            method: 'POST',
            body: JSON.stringify({
                project_name: formData.project_name,
                project_code: formData.project_code
            })
        });
        
        if (!projectData) return;
        project = projectData.project;
        allProjects.push(project);
        updateProjectFilters();
    }
    
    formData.project_id = project.id;
    
    const result = await apiRequest('/vms', {
        method: 'POST',
        body: JSON.stringify(formData)
    });
    
    if (result) {
        showAlert('虚拟机创建成功！', 'success');
        resetCreateForm();
        showTab('vms');
        await loadVMs();
    }
}

function updateGPUCount() {
    const gpuType = document.getElementById('vm-gpu-type').value;
    const gpuCountRow = document.getElementById('gpu-count-row');
    
    if (gpuType) {
        gpuCountRow.style.display = 'block';
    } else {
        gpuCountRow.style.display = 'none';
    }
}

function resetCreateForm() {
    document.getElementById('create-vm-form').reset();
    document.getElementById('gpu-count-row').style.display = 'none';
}

function initializeDatePickers() {
    const deadlineInput = document.getElementById('vm-deadline');
    if (deadlineInput) {
        // 设置默认值为一周后
        const nextWeek = new Date();
        nextWeek.setDate(nextWeek.getDate() + 7);
        deadlineInput.value = nextWeek.toISOString().slice(0, 16);
    }
}

// 计费管理
async function loadBillingSummary() {
    const startDate = document.getElementById('billing-start-date').value;
    const endDate = document.getElementById('billing-end-date').value;
    const projectId = document.getElementById('billing-project-filter').value;
    
    let url = '/billing/summary';
    const params = new URLSearchParams();
    
    if (startDate) params.append('start_date', startDate);
    if (endDate) params.append('end_date', endDate);
    if (projectId) params.append('project_id', projectId);
    
    if (params.toString()) {
        url += '?' + params.toString();
    }
    
    const data = await apiRequest(url);
    if (data) {
        renderBillingSummary(data);
        await loadBillingDetails();
    }
}

function renderBillingSummary(data) {
    const summaryEl = document.getElementById('billing-summary');
    if (!summaryEl) return;
    
    let html = `
        <div class="billing-summary-cards">
            <div class="stat-card">
                <div class="stat-number">¥${data.total_cost.toFixed(2)}</div>
                <div class="stat-label">总费用</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">${data.record_count}</div>
                <div class="stat-label">计费记录数</div>
            </div>
        </div>
        <h3>项目费用分布</h3>
        <div class="table-responsive">
            <table class="billing-table">
                <thead>
                    <tr>
                        <th>项目名称</th>
                        <th>项目编号</th>
                        <th>虚拟机数</th>
                        <th>CPU费用</th>
                        <th>内存费用</th>
                        <th>磁盘费用</th>
                        <th>GPU费用</th>
                        <th>总费用</th>
                    </tr>
                </thead>
                <tbody>
    `;
    
    Object.values(data.project_stats).forEach(project => {
        html += `
            <tr>
                <td>${escapeHtml(project.project_name)}</td>
                <td>${escapeHtml(project.project_code)}</td>
                <td>${project.vm_count}</td>
                <td>¥${project.cpu_cost.toFixed(2)}</td>
                <td>¥${project.memory_cost.toFixed(2)}</td>
                <td>¥${project.disk_cost.toFixed(2)}</td>
                <td>¥${project.gpu_cost.toFixed(2)}</td>
                <td><strong>¥${project.total_cost.toFixed(2)}</strong></td>
            </tr>
        `;
    });
    
    html += `
                </tbody>
            </table>
        </div>
    `;
    
    summaryEl.innerHTML = html;
}

async function loadBillingDetails() {
    const projectId = document.getElementById('billing-project-filter').value;
    let url = '/billing/details';
    
    if (projectId) {
        url += `?project_id=${projectId}`;
    }
    
    const data = await apiRequest(url);
    if (data) {
        renderBillingDetails(data);
    }
}

function renderBillingDetails(data) {
    const detailsEl = document.getElementById('billing-details');
    if (!detailsEl) return;
    
    let html = `
        <h3>详细计费记录</h3>
        <div class="table-responsive">
            <table class="billing-table">
                <thead>
                    <tr>
                        <th>虚拟机名称</th>
                        <th>申请人</th>
                        <th>计费日期</th>
                        <th>CPU费用</th>
                        <th>内存费用</th>
                        <th>磁盘费用</th>
                        <th>GPU费用</th>
                        <th>总费用</th>
                    </tr>
                </thead>
                <tbody>
    `;
    
    data.records.forEach(record => {
        html += `
            <tr>
                <td>${escapeHtml(record.vm_name)}</td>
                <td>${escapeHtml(record.owner)}</td>
                <td>${formatDate(record.billing_date)}</td>
                <td>¥${record.cpu_cost.toFixed(2)}</td>
                <td>¥${record.memory_cost.toFixed(2)}</td>
                <td>¥${record.disk_cost.toFixed(2)}</td>
                <td>¥${record.gpu_cost.toFixed(2)}</td>
                <td><strong>¥${record.total_cost.toFixed(2)}</strong></td>
            </tr>
        `;
    });
    
    html += `
                </tbody>
            </table>
        </div>
    `;
    
    if (data.pagination.pages > 1) {
        html += renderPagination(data.pagination);
    }
    
    detailsEl.innerHTML = html;
}

function renderPagination(pagination) {
    let html = '<div class="pagination">';
    
    if (pagination.has_prev) {
        html += `<button class="btn btn-primary" onclick="loadBillingPage(${pagination.page - 1})">上一页</button>`;
    }
    
    html += `<span>第 ${pagination.page} 页，共 ${pagination.pages} 页</span>`;
    
    if (pagination.has_next) {
        html += `<button class="btn btn-primary" onclick="loadBillingPage(${pagination.page + 1})">下一页</button>`;
    }
    
    html += '</div>';
    return html;
}

async function loadBillingPage(page) {
    const projectId = document.getElementById('billing-project-filter').value;
    let url = `/billing/details?page=${page}`;
    
    if (projectId) {
        url += `&project_id=${projectId}`;
    }
    
    const data = await apiRequest(url);
    if (data) {
        renderBillingDetails(data);
    }
}

// 模态框管理
function closeModal() {
    document.getElementById('vm-modal').style.display = 'none';
}

// 点击模态框外部关闭
window.onclick = function(event) {
    const modal = document.getElementById('vm-modal');
    if (event.target === modal) {
        modal.style.display = 'none';
    }
}

// 工具函数
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDateTime(dateString) {
    const date = new Date(dateString);
    return date.toLocaleString('zh-CN', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
    });
}

function formatDate(dateString) {
    const date = new Date(dateString);
    return date.toLocaleDateString('zh-CN');
}

function showAlert(message, type = 'info') {
    // 创建提示框
    const alert = document.createElement('div');
    alert.className = `alert alert-${type}`;
    alert.textContent = message;
    alert.style.position = 'fixed';
    alert.style.top = '20px';
    alert.style.right = '20px';
    alert.style.zIndex = '9999';
    alert.style.maxWidth = '400px';
    alert.style.animation = 'slideInRight 0.3s ease-out';
    
    document.body.appendChild(alert);
    
    // 3秒后自动移除
    setTimeout(() => {
        alert.style.animation = 'slideOutRight 0.3s ease-in';
        setTimeout(() => {
            if (alert.parentNode) {
                alert.parentNode.removeChild(alert);
            }
        }, 300);
    }, 3000);
}

// 添加动画样式
const style = document.createElement('style');
style.textContent = `
    @keyframes slideInRight {
        from {
            transform: translateX(100%);
            opacity: 0;
        }
        to {
            transform: translateX(0);
            opacity: 1;
        }
    }
    
    @keyframes slideOutRight {
        from {
            transform: translateX(0);
            opacity: 1;
        }
        to {
            transform: translateX(100%);
            opacity: 0;
        }
    }
    
    .pagination {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 1rem;
        margin-top: 1rem;
        padding: 1rem;
    }
    
    .billing-summary-cards {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 1rem;
        margin-bottom: 2rem;
    }
`;
document.head.appendChild(style);

// 页面可见性变化处理
document.addEventListener('visibilitychange', function() {
    if (!document.hidden) {
        // 页面重新可见时刷新数据
        const activeTab = document.querySelector('.tab-content.active');
        if (activeTab) {
            const tabId = activeTab.id.replace('-tab', '');
            if (tabId === 'vms') {
                loadVMs();
            } else if (tabId === 'overview') {
                loadSystemStats();
            }
        }
    }
});

// 键盘快捷键
document.addEventListener('keydown', function(e) {
    // Ctrl/Cmd + R 刷新当前页面数据
    if ((e.ctrlKey || e.metaKey) && e.key === 'r') {
        e.preventDefault();
        const activeTab = document.querySelector('.tab-content.active');
        if (activeTab) {
            const tabId = activeTab.id.replace('-tab', '');
            switch(tabId) {
                case 'vms':
                    refreshVMs();
                    break;
                case 'overview':
                    loadSystemStats();
                    break;
                case 'billing':
                    loadBillingSummary();
                    break;
            }
        }
    }
    
    // ESC 关闭模态框
    if (e.key === 'Escape') {
        closeModal();
    }
});

// 网络状态监控
window.addEventListener('online', function() {
    showAlert('网络连接已恢复', 'success');
});

window.addEventListener('offline', function() {
    showAlert('网络连接已断开', 'warning');
});

// 自动保存表单数据
function autoSaveFormData() {
    const form = document.getElementById('create-vm-form');
    if (!form) return;
    
    const formData = new FormData(form);
    const data = {};
    for (let [key, value] of formData.entries()) {
        data[key] = value;
    }
    
    localStorage.setItem('draft_vm_form', JSON.stringify(data));
}

function restoreFormData() {
    const savedData = localStorage.getItem('draft_vm_form');
    if (!savedData) return;
    
    try {
        const data = JSON.parse(savedData);
        Object.keys(data).forEach(key => {
            const input = document.getElementById(key.replace('_', '-'));
            if (input && data[key]) {
                input.value = data[key];
            }
        });
    } catch (e) {
        console.error('Error restoring form data:', e);
    }
}

// 表单输入监听
document.addEventListener('input', function(e) {
    if (e.target.closest('#create-vm-form')) {
        autoSaveFormData();
    }
});

// 初始化时恢复表单数据
document.addEventListener('DOMContentLoaded', function() {
    setTimeout(restoreFormData, 1000);
});
