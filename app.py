# ===============================
# VMware IaaS 多租户平台完整实现
# ===============================

#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import ldap
import jwt
import ping3
import logging
import ipaddress
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, g
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS
from functools import wraps
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim
import ssl
import atexit
import threading
import schedule
import time
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import smtplib

# ===============================
# 配置文件
# ===============================

class Config:
    # Flask应用配置
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'vmware-iaas-super-secret-key-2025'
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL') or 'postgresql://iaas_user:iaas_password@localhost/vmware_iaas'
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # LDAP配置
    LDAP_SERVER = 'ldap://your-ldap-server.com:389'
    LDAP_BASE_DN = 'dc=company,dc=com'
    LDAP_USER_DN_TEMPLATE = 'uid={username},ou=users,dc=company,dc=com'
    LDAP_ADMIN_DN = 'cn=admin,dc=company,dc=com'
    LDAP_ADMIN_PASSWORD = 'admin_password'
    LDAP_USER_SEARCH_BASE = 'ou=users,dc=company,dc=com'
    LDAP_ATTRIBUTES = ['uid', 'cn', 'mail', 'ou', 'memberOf']
    
    # VMware配置
    VCENTER_HOST = 'your-vcenter-server.com'
    VCENTER_USER = 'administrator@vsphere.local'
    VCENTER_PASSWORD = 'vcenter_admin_password'
    VCENTER_PORT = 443
    
    # 计费配置 (每日单价)
    PRICING = {
        'cpu_per_core': 0.08,      # 每核心每天
        'memory_per_gb': 0.16,     # 每GB每天
        'disk_per_100gb': 0.5,     # 每100GB每天
        'gpu_3090': 11.0,          # 每张每天
        'gpu_t4': 5.0              # 每张每天
    }
    
    # 邮件配置
    SMTP_SERVER = 'smtp.company.com'
    SMTP_PORT = 587
    SMTP_USERNAME = 'iaas-system@company.com'
    SMTP_PASSWORD = 'smtp_password'
    SMTP_FROM = 'VMware IaaS Platform <iaas-system@company.com>'
    
    # 网络配置
    NETWORK_SEGMENTS = [
        '192.168.100.0/24',
        '192.168.101.0/24',
        '192.168.102.0/24'
    ]

# ===============================
# Flask应用初始化
# ===============================

app = Flask(__name__)
app.config.from_object(Config)
db = SQLAlchemy(app)
CORS(app)

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/vmware-iaas/app.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ===============================
# 数据库模型
# ===============================

class Tenant(db.Model):
    __tablename__ = 'tenants'
    
    id = db.Column(db.Integer, primary_key=True)
    ldap_uid = db.Column(db.String(100), unique=True, nullable=False)
    username = db.Column(db.String(100), nullable=False)
    display_name = db.Column(db.String(200))
    email = db.Column(db.String(200))
    department = db.Column(db.String(100))
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)

class Project(db.Model):
    __tablename__ = 'projects'
    
    id = db.Column(db.Integer, primary_key=True)
    project_name = db.Column(db.String(200), nullable=False)
    project_code = db.Column(db.String(100), nullable=False)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class VirtualMachine(db.Model):
    __tablename__ = 'virtual_machines'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    project_id = db.Column(db.Integer, db.ForeignKey('projects.id'), nullable=False)
    project_name = db.Column(db.String(200), nullable=False)
    project_code = db.Column(db.String(100), nullable=False)
    owner = db.Column(db.String(200), nullable=False)  # 申请人
    deadline = db.Column(db.DateTime, nullable=False)  # 过期时间
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    vcenter_uuid = db.Column(db.String(100), unique=True)
    ip_address = db.Column(db.String(15))
    cpu_cores = db.Column(db.Integer, nullable=False)
    memory_gb = db.Column(db.Integer, nullable=False)
    disk_gb = db.Column(db.Integer, nullable=False)
    gpu_type = db.Column(db.String(50))  # '3090', 't4', None
    gpu_count = db.Column(db.Integer, default=0)
    host_name = db.Column(db.String(200))
    status = db.Column(db.String(20), default='creating')  # creating, running, stopped, expired, deleted
    template_name = db.Column(db.String(100))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class IPPool(db.Model):
    __tablename__ = 'ip_pools'
    
    id = db.Column(db.Integer, primary_key=True)
    network_segment = db.Column(db.String(20), nullable=False)
    ip_address = db.Column(db.String(15), nullable=False)
    is_available = db.Column(db.Boolean, default=True)
    assigned_vm_id = db.Column(db.Integer, db.ForeignKey('virtual_machines.id'))
    assigned_at = db.Column(db.DateTime)

class BillingRecord(db.Model):
    __tablename__ = 'billing_records'
    
    id = db.Column(db.Integer, primary_key=True)
    vm_id = db.Column(db.Integer, db.ForeignKey('virtual_machines.id'), nullable=False)
    project_id = db.Column(db.Integer, db.ForeignKey('projects.id'), nullable=False)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    billing_date = db.Column(db.Date, nullable=False)
    cpu_cost = db.Column(db.Float, default=0)
    memory_cost = db.Column(db.Float, default=0)
    disk_cost = db.Column(db.Float, default=0)
    gpu_cost = db.Column(db.Float, default=0)
    total_cost = db.Column(db.Float, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class UserSession(db.Model):
    __tablename__ = 'user_sessions'
    
    id = db.Column(db.Integer, primary_key=True)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    session_token = db.Column(db.String(500), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, nullable=False)
    is_active = db.Column(db.Boolean, default=True)

# ===============================
# LDAP认证类
# ===============================

class LDAPAuth:
    def __init__(self):
        self.server = app.config['LDAP_SERVER']
        self.base_dn = app.config['LDAP_BASE_DN']
        self.user_dn_template = app.config['LDAP_USER_DN_TEMPLATE']
        self.admin_dn = app.config['LDAP_ADMIN_DN']
        self.admin_password = app.config['LDAP_ADMIN_PASSWORD']
        self.user_search_base = app.config['LDAP_USER_SEARCH_BASE']
        self.attributes = app.config['LDAP_ATTRIBUTES']
    
    def authenticate(self, username, password):
        """LDAP身份验证"""
        try:
            conn = ldap.initialize(self.server)
            conn.protocol_version = ldap.VERSION3
            conn.set_option(ldap.OPT_REFERRALS, 0)
            
            user_dn = self.user_dn_template.format(username=username)
            conn.simple_bind_s(user_dn, password)
            
            user_info = self.get_user_info(conn, username)
            conn.unbind_s()
            
            logger.info(f"LDAP authentication successful for user: {username}")
            return True, user_info
            
        except ldap.INVALID_CREDENTIALS:
            logger.warning(f"LDAP authentication failed for user: {username}")
            return False, None
        except Exception as e:
            logger.error(f"LDAP authentication error: {str(e)}")
            return False, None
    
    def get_user_info(self, conn, username):
        """获取用户详细信息"""
        try:
            search_filter = f"(uid={username})"
            result = conn.search_s(
                self.user_search_base,
                ldap.SCOPE_SUBTREE,
                search_filter,
                self.attributes
            )
            
            if result:
                dn, attrs = result[0]
                return {
                    'uid': attrs.get('uid', [b''])[0].decode('utf-8'),
                    'display_name': attrs.get('cn', [b''])[0].decode('utf-8'),
                    'email': attrs.get('mail', [b''])[0].decode('utf-8'),
                    'department': attrs.get('ou', [b''])[0].decode('utf-8')
                }
            return None
        except Exception as e:
            logger.error(f"Error getting user info: {str(e)}")
            return None

# ===============================
# VMware管理类
# ===============================

class VMwareManager:
    def __init__(self):
        self.host = app.config['VCENTER_HOST']
        self.user = app.config['VCENTER_USER']
        self.password = app.config['VCENTER_PASSWORD']
        self.port = app.config['VCENTER_PORT']
        self.si = None
        self.content = None
        self._connect()
    
    def _connect(self):
        """连接到vCenter"""
        try:
            context = ssl._create_unverified_context()
            self.si = SmartConnect(
                host=self.host,
                user=self.user,
                pwd=self.password,
                port=self.port,
                sslContext=context
            )
            self.content = self.si.RetrieveContent()
            atexit.register(Disconnect, self.si)
            logger.info("Connected to vCenter successfully")
        except Exception as e:
            logger.error(f"Failed to connect to vCenter: {str(e)}")
            raise
    
    def get_obj_by_name(self, vimtype, name):
        """根据名称获取vSphere对象"""
        container = self.content.viewManager.CreateContainerView(
            self.content.rootFolder, [vimtype], True
        )
        for obj in container.view:
            if obj.name == name:
                container.Destroy()
                return obj
        container.Destroy()
        return None
    
    def get_vm_by_uuid(self, uuid):
        """根据UUID获取虚拟机"""
        return self.content.searchIndex.FindByUuid(None, uuid, True, True)
    
    def get_all_hosts(self):
        """获取所有ESXi主机"""
        container = self.content.viewManager.CreateContainerView(
            self.content.rootFolder, [vim.HostSystem], True
        )
        hosts = container.view[:]
        container.Destroy()
        return hosts
    
    def find_suitable_host_for_gpu(self, gpu_type, gpu_count, cpu_cores, memory_gb):
        """为GPU虚拟机找到合适的主机"""
        hosts = self.get_all_hosts()
        
        for host in hosts:
            try:
                token = auth_header.split(" ")[1]  # Bearer <token>
            except IndexError:
                return jsonify({'error': 'Invalid token format'}), 401
        
        if not token:
            return jsonify({'error': 'Token is missing'}), 401
        
        payload = decode_jwt_token(token)
        if not payload:
            return jsonify({'error': 'Token is invalid or expired'}), 401
        
        session = UserSession.query.filter_by(
            session_token=token,
            is_active=True
        ).first()
        
        if not session or session.expires_at < datetime.utcnow():
            return jsonify({'error': 'Session expired'}), 401
        
        g.current_user = {
            'tenant_id': payload['tenant_id'],
            'username': payload['username']
        }
        
        return f(*args, **kwargs)
    return decorated_function

# ===============================
# 全局对象初始化
# ===============================

ldap_auth = LDAPAuth()
vmware_manager = VMwareManager()
ip_manager = IPManager()
billing_manager = BillingManager()
email_notifier = EmailNotifier()

# ===============================
# 认证API路由
# ===============================

@app.route('/api/auth/login', methods=['POST'])
def login():
    """用户登录接口"""
    try:
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            return jsonify({'error': 'Username and password are required'}), 400
        
        # LDAP身份验证
        auth_success, user_info = ldap_auth.authenticate(username, password)
        
        if not auth_success:
            return jsonify({'error': 'Invalid credentials'}), 401
        
        # 检查或创建租户记录
        tenant = Tenant.query.filter_by(ldap_uid=user_info['uid']).first()
        
        if not tenant:
            tenant = Tenant(
                ldap_uid=user_info['uid'],
                username=username,
                display_name=user_info['display_name'],
                email=user_info['email'],
                department=user_info['department']
            )
            db.session.add(tenant)
            db.session.commit()
        else:
            tenant.display_name = user_info['display_name']
            tenant.email = user_info['email']
            tenant.department = user_info['department']
            tenant.last_login = datetime.utcnow()
            db.session.commit()
        
        # 生成JWT token
        token = generate_jwt_token({
            'id': tenant.id,
            'username': tenant.username
        })
        
        # 创建用户session记录
        session = UserSession(
            tenant_id=tenant.id,
            session_token=token,
            expires_at=datetime.utcnow() + timedelta(hours=24)
        )
        db.session.add(session)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'token': token,
            'user': {
                'id': tenant.id,
                'username': tenant.username,
                'display_name': tenant.display_name,
                'email': tenant.email,
                'department': tenant.department
            }
        })
        
    except Exception as e:
        logger.error(f"Login error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/auth/logout', methods=['POST'])
@jwt_required
def logout():
    """用户登出接口"""
    try:
        token = request.headers.get('Authorization', '').split(" ")[1]
        session = UserSession.query.filter_by(session_token=token).first()
        if session:
            session.is_active = False
            db.session.commit()
        
        return jsonify({'success': True, 'message': 'Logout successful'})
    except Exception as e:
        logger.error(f"Logout error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/auth/profile', methods=['GET'])
@jwt_required
def get_profile():
    """获取当前用户信息"""
    try:
        tenant = Tenant.query.get(g.current_user['tenant_id'])
        if not tenant:
            return jsonify({'error': 'User not found'}), 404
        
        return jsonify({
            'user': {
                'id': tenant.id,
                'username': tenant.username,
                'display_name': tenant.display_name,
                'email': tenant.email,
                'department': tenant.department,
                'last_login': tenant.last_login.isoformat() if tenant.last_login else None
            }
        })
    except Exception as e:
        logger.error(f"Get profile error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

# ===============================
# 项目管理API路由
# ===============================

@app.route('/api/projects', methods=['GET'])
@jwt_required
def list_projects():
    """获取当前租户的项目列表"""
    try:
        projects = Project.query.filter_by(tenant_id=g.current_user['tenant_id']).all()
        
        projects_data = []
        for project in projects:
            vm_count = VirtualMachine.query.filter_by(project_id=project.id).count()
            projects_data.append({
                'id': project.id,
                'project_name': project.project_name,
                'project_code': project.project_code,
                'vm_count': vm_count,
                'created_at': project.created_at.isoformat()
            })
        
        return jsonify({'projects': projects_data})
    except Exception as e:
        logger.error(f"List projects error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/projects', methods=['POST'])
@jwt_required
def create_project():
    """创建新项目"""
    try:
        data = request.get_json()
        project_name = data.get('project_name')
        project_code = data.get('project_code')
        
        if not project_name or not project_code:
            return jsonify({'error': 'Project name and code are required'}), 400
        
        # 检查项目编号是否已存在
        existing_project = Project.query.filter_by(project_code=project_code).first()
        if existing_project:
            return jsonify({'error': 'Project code already exists'}), 400
        
        project = Project(
            project_name=project_name,
            project_code=project_code,
            tenant_id=g.current_user['tenant_id']
        )
        
        db.session.add(project)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'project': {
                'id': project.id,
                'project_name': project.project_name,
                'project_code': project.project_code
            }
        })
    except Exception as e:
        logger.error(f"Create project error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

# ===============================
# 虚拟机管理API路由
# ===============================

@app.route('/api/vms', methods=['GET'])
@jwt_required
def list_vms():
    """获取当前租户的虚拟机列表"""
    try:
        project_id = request.args.get('project_id')
        
        query = VirtualMachine.query.filter_by(tenant_id=g.current_user['tenant_id'])
        if project_id:
            query = query.filter_by(project_id=project_id)
        
        vms = query.all()
        
        vms_data = []
        for vm in vms:
            # 计算剩余天数
            days_until_expiry = (vm.deadline - datetime.utcnow()).days
            
            # 获取监控数据
            metrics = vmware_manager.get_vm_metrics(vm.vcenter_uuid) if vm.vcenter_uuid else None
            
            vm_data = {
                'id': vm.id,
                'name': vm.name,
                'project_name': vm.project_name,
                'project_code': vm.project_code,
                'owner': vm.owner,
                'deadline': vm.deadline.isoformat(),
                'days_until_expiry': days_until_expiry,
                'ip_address': vm.ip_address,
                'cpu_cores': vm.cpu_cores,
                'memory_gb': vm.memory_gb,
                'disk_gb': vm.disk_gb,
                'gpu_type': vm.gpu_type,
                'gpu_count': vm.gpu_count,
                'host_name': vm.host_name,
                'status': vm.status,
                'template_name': vm.template_name,
                'created_at': vm.created_at.isoformat(),
                'metrics': metrics
            }
            vms_data.append(vm_data)
        
        return jsonify({'vms': vms_data})
    except Exception as e:
        logger.error(f"List VMs error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/vms', methods=['POST'])
@jwt_required
def create_vm():
    """创建新虚拟机"""
    try:
        data = request.get_json()
        
        # 验证必填字段
        required_fields = ['name', 'project_id', 'project_name', 'project_code', 
                          'owner', 'deadline', 'cpu_cores', 'memory_gb', 'disk_gb', 'template_name']
        
        for field in required_fields:
            if not data.get(field):
                return jsonify({'error': f'{field} is required'}), 400
        
        # 解析过期时间
        try:
            deadline = datetime.fromisoformat(data['deadline'].replace('Z', '+00:00'))
        except ValueError:
            return jsonify({'error': 'Invalid deadline format'}), 400
        
        # 检查过期时间是否合理
        if deadline <= datetime.utcnow():
            return jsonify({'error': 'Deadline must be in the future'}), 400
        
        # 验证项目归属
        project = Project.query.filter_by(
            id=data['project_id'],
            tenant_id=g.current_user['tenant_id']
        ).first()
        
        if not project:
            return jsonify({'error': 'Project not found or not authorized'}), 404
        
        # 分配IP地址
        vm_temp = VirtualMachine(
            name=data['name'],
            project_id=data['project_id'],
            project_name=data['project_name'],
            project_code=data['project_code'],
            owner=data['owner'],
            deadline=deadline,
            tenant_id=g.current_user['tenant_id'],
            cpu_cores=int(data['cpu_cores']),
            memory_gb=int(data['memory_gb']),
            disk_gb=int(data['disk_gb']),
            gpu_type=data.get('gpu_type'),
            gpu_count=int(data.get('gpu_count', 0)),
            template_name=data['template_name'],
            status='creating'
        )
        
        db.session.add(vm_temp)
        db.session.commit()
        
        # 分配IP
        ip_address = ip_manager.allocate_ip(vm_temp.id)
        if not ip_address:
            db.session.delete(vm_temp)
            db.session.commit()
            return jsonify({'error': 'No available IP address'}), 400
        
        vm_temp.ip_address = ip_address
        
        # 寻找合适的主机
        target_host = None
        if vm_temp.gpu_type and vm_temp.gpu_count > 0:
            target_host = vmware_manager.find_suitable_host_for_gpu(
                vm_temp.gpu_type, vm_temp.gpu_count, 
                vm_temp.cpu_cores, vm_temp.memory_gb
            )
            
            if not target_host:
                ip_manager.release_ip(vm_temp.id)
                db.session.delete(vm_temp)
                db.session.commit()
                return jsonify({
                    'error': f'No suitable host found for {vm_temp.gpu_type} GPU x{vm_temp.gpu_count}. Please contact administrator.'
                }), 400
        
        try:
            # 创建虚拟机
            vm_uuid = vmware_manager.create_vm_from_template(
                template_name=vm_temp.template_name,
                vm_name=vm_temp.name,
                cpu_cores=vm_temp.cpu_cores,
                memory_gb=vm_temp.memory_gb,
                disk_gb=vm_temp.disk_gb,
                ip_address=ip_address,
                target_host=target_host
            )
            
            # 更新数据库记录
            vm_temp.vcenter_uuid = vm_uuid
            vm_temp.host_name = target_host.name if target_host else 'auto-assigned'
            vm_temp.status = 'stopped'
            db.session.commit()
            
            return jsonify({
                'success': True,
                'vm': {
                    'id': vm_temp.id,
                    'name': vm_temp.name,
                    'ip_address': ip_address,
                    'status': vm_temp.status,
                    'vcenter_uuid': vm_uuid
                }
            })
            
        except Exception as e:
            # 创建失败，清理资源
            ip_manager.release_ip(vm_temp.id)
            db.session.delete(vm_temp)
            db.session.commit()
            logger.error(f"VM creation failed: {str(e)}")
            return jsonify({'error': f'VM creation failed: {str(e)}'}), 500
        
    except Exception as e:
        logger.error(f"Create VM error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/vms/<int:vm_id>/power/<action>', methods=['POST'])
@jwt_required
def vm_power_action(vm_id, action):
    """虚拟机电源操作"""
    try:
        vm = VirtualMachine.query.filter_by(
            id=vm_id,
            tenant_id=g.current_user['tenant_id']
        ).first()
        
        if not vm:
            return jsonify({'error': 'VM not found'}), 404
        
        if not vm.vcenter_uuid:
            return jsonify({'error': 'VM not properly initialized'}), 400
        
        success = False
        if action == 'on':
            success = vmware_manager.power_on_vm(vm.vcenter_uuid)
            if success:
                vm.status = 'running'
        elif action == 'off':
            success = vmware_manager.power_off_vm(vm.vcenter_uuid)
            if success:
                vm.status = 'stopped'
        elif action == 'restart':
            success = vmware_manager.reset_vm(vm.vcenter_uuid)
        else:
            return jsonify({'error': 'Invalid action'}), 400
        
        if success:
            vm.updated_at = datetime.utcnow()
            db.session.commit()
            return jsonify({'success': True, 'status': vm.status})
        else:
            return jsonify({'error': 'Operation failed'}), 500
        
    except Exception as e:
        logger.error(f"VM power action error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/vms/<int:vm_id>/metrics', methods=['GET'])
@jwt_required
def get_vm_metrics(vm_id):
    """获取虚拟机监控数据"""
    try:
        vm = VirtualMachine.query.filter_by(
            id=vm_id,
            tenant_id=g.current_user['tenant_id']
        ).first()
        
        if not vm:
            return jsonify({'error': 'VM not found'}), 404
        
        if not vm.vcenter_uuid:
            return jsonify({'error': 'VM not properly initialized'}), 400
        
        metrics = vmware_manager.get_vm_metrics(vm.vcenter_uuid)
        if metrics:
            return jsonify({'metrics': metrics})
        else:
            return jsonify({'error': 'Unable to get metrics. VM may be powered off.'}), 400
        
    except Exception as e:
        logger.error(f"Get VM metrics error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/vms/<int:vm_id>', methods=['DELETE'])
@jwt_required
def delete_vm(vm_id):
    """删除虚拟机"""
    try:
        vm = VirtualMachine.query.filter_by(
            id=vm_id,
            tenant_id=g.current_user['tenant_id']
        ).first()
        
        if not vm:
            return jsonify({'error': 'VM not found'}), 404
        
        # 从VMware中删除虚拟机
        if vm.vcenter_uuid:
            success = vmware_manager.destroy_vm(vm.vcenter_uuid)
            if not success:
                return jsonify({'error': 'Failed to delete VM from VMware'}), 500
        
        # 释放IP地址
        ip_manager.release_ip(vm.id)
        
        # 删除数据库记录
        db.session.delete(vm)
        db.session.commit()
        
        return jsonify({'success': True, 'message': 'VM deleted successfully'})
        
    except Exception as e:
        logger.error(f"Delete VM error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

# ===============================
# 计费API路由
# ===============================

@app.route('/api/billing/summary', methods=['GET'])
@jwt_required
def billing_summary():
    """获取计费摘要"""
    try:
        # 获取查询参数
        project_id = request.args.get('project_id')
        start_date = request.args.get('start_date')
        end_date = request.args.get('end_date')
        
        # 构建查询
        query = BillingRecord.query.filter_by(tenant_id=g.current_user['tenant_id'])
        
        if project_id:
            query = query.filter_by(project_id=project_id)
        
        if start_date:
            query = query.filter(BillingRecord.billing_date >= datetime.fromisoformat(start_date).date())
        
        if end_date:
            query = query.filter(BillingRecord.billing_date <= datetime.fromisoformat(end_date).date())
        
        billing_records = query.all()
        
        # 按项目统计
        project_stats = {}
        total_cost = 0
        
        for record in billing_records:
            project_key = f"{record.project_id}"
            if project_key not in project_stats:
                vm = VirtualMachine.query.get(record.vm_id)
                project_stats[project_key] = {
                    'project_name': vm.project_name if vm else 'Unknown',
                    'project_code': vm.project_code if vm else 'Unknown',
                    'total_cost': 0,
                    'cpu_cost': 0,
                    'memory_cost': 0,
                    'disk_cost': 0,
                    'gpu_cost': 0,
                    'vm_count': set()
                }
            
            project_stats[project_key]['total_cost'] += record.total_cost
            project_stats[project_key]['cpu_cost'] += record.cpu_cost
            project_stats[project_key]['memory_cost'] += record.memory_cost
            project_stats[project_key]['disk_cost'] += record.disk_cost
            project_stats[project_key]['gpu_cost'] += record.gpu_cost
            project_stats[project_key]['vm_count'].add(record.vm_id)
            
            total_cost += record.total_cost
        
        # 转换vm_count为数字
        for project in project_stats.values():
            project['vm_count'] = len(project['vm_count'])
        
        return jsonify({
            'total_cost': round(total_cost, 2),
            'project_stats': project_stats,
            'record_count': len(billing_records)
        })
        
    except Exception as e:
        logger.error(f"Billing summary error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/billing/details', methods=['GET'])
@jwt_required
def billing_details():
    """获取详细计费记录"""
    try:
        page = int(request.args.get('page', 1))
        per_page = int(request.args.get('per_page', 50))
        project_id = request.args.get('project_id')
        
        query = db.session.query(
            BillingRecord,
            VirtualMachine.name.label('vm_name'),
            VirtualMachine.owner
        ).join(VirtualMachine).filter(
            BillingRecord.tenant_id == g.current_user['tenant_id']
        )
        
        if project_id:
            query = query.filter(BillingRecord.project_id == project_id)
        
        pagination = query.order_by(BillingRecord.billing_date.desc()).paginate(
            page=page, per_page=per_page, error_out=False
        )
        
        records_data = []
        for billing_record, vm_name, owner in pagination.items:
            records_data.append({
                'id': billing_record.id,
                'vm_name': vm_name,
                'owner': owner,
                'billing_date': billing_record.billing_date.isoformat(),
                'cpu_cost': billing_record.cpu_cost,
                'memory_cost': billing_record.memory_cost,
                'disk_cost': billing_record.disk_cost,
                'gpu_cost': billing_record.gpu_cost,
                'total_cost': billing_record.total_cost
            })
        
        return jsonify({
            'records': records_data,
            'pagination': {
                'page': pagination.page,
                'pages': pagination.pages,
                'per_page': pagination.per_page,
                'total': pagination.total,
                'has_next': pagination.has_next,
                'has_prev': pagination.has_prev
            }
        })
        
    except Exception as e:
        logger.error(f"Billing details error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

# ===============================
# 系统管理API路由
# ===============================

@app.route('/api/templates', methods=['GET'])
@jwt_required
def list_templates():
    """获取可用的虚拟机模板"""
    try:
        # 这里可以从VMware中动态获取模板列表
        # 简化版本，返回预定义模板
        templates = [
            {
                'name': 'Ubuntu-20.04-Template',
                'display_name': 'Ubuntu 20.04 LTS',
                'os_type': 'Linux',
                'description': 'Ubuntu 20.04 LTS 服务器版'
            },
            {
                'name': 'CentOS-7-Template',
                'display_name': 'CentOS 7',
                'os_type': 'Linux',
                'description': 'CentOS 7 服务器版'
            },
            {
                'name': 'Windows-Server-2019-Template',
                'display_name': 'Windows Server 2019',
                'os_type': 'Windows',
                'description': 'Windows Server 2019 标准版'
            }
        ]
        
        return jsonify({'templates': templates})
        
    except Exception as e:
        logger.error(f"List templates error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/system/stats', methods=['GET'])
@jwt_required
def system_stats():
    """获取系统统计信息"""
    try:
        tenant_id = g.current_user['tenant_id']
        
        # 虚拟机统计
        total_vms = VirtualMachine.query.filter_by(tenant_id=tenant_id).count()
        running_vms = VirtualMachine.query.filter_by(
            tenant_id=tenant_id, status='running'
        ).count()
        stopped_vms = VirtualMachine.query.filter_by(
            tenant_id=tenant_id, status='stopped'
        ).count()
        
        # 资源统计
        vms = VirtualMachine.query.filter_by(tenant_id=tenant_id).all()
        total_cpu = sum(vm.cpu_cores for vm in vms)
        total_memory = sum(vm.memory_gb for vm in vms)
        total_disk = sum(vm.disk_gb for vm in vms)
        total_gpus = sum(vm.gpu_count for vm in vms if vm.gpu_count)
        
        # 过期统计
        now = datetime.utcnow()
        expiring_soon = VirtualMachine.query.filter(
            VirtualMachine.tenant_id == tenant_id,
            VirtualMachine.deadline <= now + timedelta(days=7),
            VirtualMachine.deadline > now
        ).count()
        
        expired = VirtualMachine.query.filter(
            VirtualMachine.tenant_id == tenant_id,
            VirtualMachine.deadline <= now
        ).count()
        
        # 项目统计
        total_projects = Project.query.filter_by(tenant_id=tenant_id).count()
        
        return jsonify({
            'vms': {
                'total': total_vms,
                'running': running_vms,
                'stopped': stopped_vms,
                'expiring_soon': expiring_soon,
                'expired': expired
            },
            'resources': {
                'total_cpu_cores': total_cpu,
                'total_memory_gb': total_memory,
                'total_disk_gb': total_disk,
                'total_gpus': total_gpus
            },
            'projects': {
                'total': total_projects
            }
        })
        
    except Exception as e:
        logger.error(f"System stats error: {str(e)}")
        return jsonify({'error': 'Internal server error'}), 500

# ===============================
# 定时任务
# ===============================

def check_expired_vms():
    """检查过期虚拟机"""
    logger.info("Checking expired VMs...")
    
    now = datetime.utcnow()
    
    # 查找即将过期的虚拟机 (7天内)
    expiring_vms = VirtualMachine.query.filter(
        VirtualMachine.deadline <= now + timedelta(days=7),
        VirtualMachine.deadline > now,
        VirtualMachine.status.in_(['running', 'stopped'])
    ).all()
    
    for vm in expiring_vms:
        days_until_expiry = (vm.deadline - now).days
        logger.info(f"VM {vm.name} expires in {days_until_expiry} days")
        
        # 发送通知邮件
        email_notifier.send_expiry_notification(vm, days_until_expiry)
    
    # 查找已过期的虚拟机
    expired_vms = VirtualMachine.query.filter(
        VirtualMachine.deadline <= now,
        VirtualMachine.status.in_(['running', 'stopped'])
    ).all()
    
    for vm in expired_vms:
        days_past_expiry = (now - vm.deadline).days
        logger.warning(f"VM {vm.name} expired {days_past_expiry} days ago")
        
        if days_past_expiry >= 1 and vm.status == 'running':
            # 自动关机
            try:
                success = vmware_manager.power_off_vm(vm.vcenter_uuid)
                if success:
                    vm.status = 'expired'
                    db.session.commit()
                    logger.info(f"Powered off expired VM: {vm.name}")
            except Exception as e:
                logger.error(f"Failed to power off expired VM {vm.name}: {str(e)}")
        
        # 发送过期通知
        email_notifier.send_expiry_notification(vm, -days_past_expiry)

def run_daily_billing():
    """运行每日计费任务"""
    logger.info("Running daily billing...")
    billing_manager.generate_daily_billing()

def sync_vm_status():
    """同步虚拟机状态"""
    logger.info("Syncing VM status...")
    
    vms = VirtualMachine.query.filter(
        VirtualMachine.vcenter_uuid.isnot(None),
        VirtualMachine.status.in_(['running', 'stopped'])
    ).all()
    
    for vm in vms:
        try:
            vm_obj = vmware_manager.get_vm_by_uuid(vm.vcenter_uuid)
            if vm_obj:
                power_state = str(vm_obj.runtime.powerState)
                new_status = 'running' if power_state == 'poweredOn' else 'stopped'
                
                if vm.status != new_status:
                    vm.status = new_status
                    vm.updated_at = datetime.utcnow()
                    logger.info(f"Updated VM {vm.name} status to {new_status}")
        except Exception as e:
            logger.error(f"Failed to sync status for VM {vm.name}: {str(e)}")
    
    try:
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        logger.error(f"Failed to commit status updates: {str(e)}")

# ===============================
# 定时任务调度
# ===============================

def start_scheduler():
    """启动定时任务调度器"""
    # 每天凌晨2点检查过期虚拟机
    schedule.every().day.at("02:00").do(check_expired_vms)
    
    # 每天凌晨3点运行计费任务
    schedule.every().day.at("03:00").do(run_daily_billing)
    
    # 每5分钟同步虚拟机状态
    schedule.every(5).minutes.do(sync_vm_status)
    
    def run_scheduler():
        while True:
            schedule.run_pending()
            time.sleep(60)
    
    scheduler_thread = threading.Thread(target=run_scheduler, daemon=True)
    scheduler_thread.start()
    logger.info("Scheduler started successfully")

# ===============================
# 数据库初始化函数
# ===============================

def init_database():
    """初始化数据库"""
    with app.app_context():
        try:
            db.create_all()
            logger.info("Database tables created successfully")
            
            # 初始化IP池
            ip_manager._init_ip_pools()
            logger.info("IP pools initialized successfully")
            
        except Exception as e:
            logger.error(f"Database initialization failed: {str(e)}")
            raise

def create_sample_data():
    """创建示例数据"""
    with app.app_context():
        try:
            # 检查是否已有数据
            if Tenant.query.first():
                logger.info("Sample data already exists")
                return
            
            # 创建示例租户
            tenant = Tenant(
                ldap_uid='testuser',
                username='testuser',
                display_name='Test User',
                email='testuser@company.com',
                department='IT'
            )
            db.session.add(tenant)
            db.session.commit()
            
            # 创建示例项目
            project = Project(
                project_name='测试项目',
                project_code='TEST001',
                tenant_id=tenant.id
            )
            db.session.add(project)
            db.session.commit()
            
            logger.info("Sample data created successfully")
            
        except Exception as e:
            logger.error(f"Failed to create sample data: {str(e)}")
            db.session.rollback()

# ===============================
# 错误处理
# ===============================

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Resource not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    db.session.rollback()
    return jsonify({'error': 'Internal server error'}), 500

@app.errorhandler(400)
def bad_request(error):
    return jsonify({'error': 'Bad request'}), 400

# ===============================
# 健康检查接口
# ===============================

@app.route('/api/health', methods=['GET'])
def health_check():
    """健康检查接口"""
    try:
        # 检查数据库连接
        db.session.execute('SELECT 1')
        
        # 检查VMware连接
        vmware_status = 'connected' if vmware_manager.si else 'disconnected'
        
        return jsonify({
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'services': {
                'database': 'connected',
                'vmware': vmware_status,
                'ldap': 'available'
            }
        })
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500

# ===============================
# 主程序入口
# ===============================

if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='VMware IaaS Platform')
    parser.add_argument('--init-db', action='store_true', help='Initialize database')
    parser.add_argument('--sample-data', action='store_true', help='Create sample data')
    parser.add_argument('--host', default='0.0.0.0', help='Host to bind to')
    parser.add_argument('--port', type=int, default=5000, help='Port to bind to')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode')
    
    args = parser.parse_args()
    
    if args.init_db:
        print("Initializing database...")
        init_database()
        print("Database initialized successfully!")
        sys.exit(0)
    
    if args.sample_data:
        print("Creating sample data...")
        create_sample_data()
        print("Sample data created successfully!")
        sys.exit(0)
    
    # 确保数据库已初始化
    try:
        with app.app_context():
            db.create_all()
    except Exception as e:
        logger.error(f"Database check failed: {str(e)}")
        print("Please run with --init-db to initialize the database first")
        sys.exit(1)
    
    # 启动定时任务调度器
    start_scheduler()
    
    # 启动Flask应用
    logger.info(f"Starting VMware IaaS Platform on {args.host}:{args.port}")
    app.run(host=args.host, port=args.port, debug=args.debug, threaded=True)
                # 检查主机状态
                if host.runtime.connectionState != 'connected':
                    continue
                
                # 检查CPU和内存资源
                cpu_total = host.summary.hardware.numCpuCores
                cpu_usage = host.summary.quickStats.overallCpuUsage or 0
                cpu_free = cpu_total - (cpu_usage / 100 * cpu_total)
                
                memory_total = host.summary.hardware.memorySize / (1024**3)  # GB
                memory_usage = host.summary.quickStats.overallMemoryUsage or 0
                memory_free = memory_total - memory_usage
                
                if cpu_free < cpu_cores or memory_free < memory_gb:
                    continue
                
                # 检查GPU资源
                if gpu_type and gpu_count > 0:
                    available_gpus = self._count_available_gpus(host, gpu_type)
                    if available_gpus < gpu_count:
                        continue
                
                return host
                
            except Exception as e:
                logger.error(f"Error checking host {host.name}: {str(e)}")
                continue
        
        return None
    
    def _count_available_gpus(self, host, gpu_type):
        """统计主机上可用的GPU数量"""
        gpu_count = 0
        try:
            for device in host.hardware.pciDevice:
                device_name = device.deviceName.lower()
                if gpu_type.lower() == '3090' and '3090' in device_name:
                    gpu_count += 1
                elif gpu_type.lower() == 't4' and 't4' in device_name:
                    gpu_count += 1
        except Exception as e:
            logger.error(f"Error counting GPUs on host {host.name}: {str(e)}")
        return gpu_count
    
    def create_vm_from_template(self, template_name, vm_name, cpu_cores, memory_gb, 
                               disk_gb, ip_address, target_host=None):
        """从模板创建虚拟机"""
        try:
            template = self.get_obj_by_name(vim.VirtualMachine, template_name)
            if not template:
                raise Exception(f"Template {template_name} not found")
            
            # 获取数据中心和资源池
            datacenter = self.content.rootFolder.childEntity[0]
            resource_pool = datacenter.hostFolder.childEntity[0].resourcePool
            
            # 如果指定了目标主机，使用该主机的资源池
            if target_host:
                resource_pool = target_host.parent.resourcePool
            
            # 配置规格
            config_spec = vim.vm.ConfigSpec()
            config_spec.numCPUs = cpu_cores
            config_spec.memoryMB = memory_gb * 1024
            
            # 克隆规格
            clone_spec = vim.vm.CloneSpec()
            clone_spec.location = vim.vm.RelocateSpec()
            clone_spec.location.pool = resource_pool
            if target_host:
                clone_spec.location.host = target_host
            clone_spec.config = config_spec
            clone_spec.powerOn = False
            clone_spec.template = False
            
            # 执行克隆
            task = template.Clone(
                folder=datacenter.vmFolder,
                name=vm_name,
                spec=clone_spec
            )
            
            # 等待任务完成
            while task.info.state == vim.TaskInfo.State.running:
                time.sleep(1)
            
            if task.info.state == vim.TaskInfo.State.success:
                vm = task.info.result
                
                # 配置网络IP
                self._configure_vm_network(vm, ip_address)
                
                return vm.config.uuid
            else:
                raise Exception(f"Clone task failed: {task.info.error}")
                
        except Exception as e:
            logger.error(f"Error creating VM: {str(e)}")
            raise
    
    def _configure_vm_network(self, vm, ip_address):
        """配置虚拟机网络IP"""
        try:
            # 这里需要根据实际环境配置网络
            # 可以使用guest customization或者cloud-init
            pass
        except Exception as e:
            logger.error(f"Error configuring VM network: {str(e)}")
    
    def power_on_vm(self, vm_uuid):
        """开启虚拟机"""
        vm = self.get_vm_by_uuid(vm_uuid)
        if vm:
            task = vm.PowerOnVM_Task()
            return self._wait_for_task(task)
        return False
    
    def power_off_vm(self, vm_uuid):
        """关闭虚拟机"""
        vm = self.get_vm_by_uuid(vm_uuid)
        if vm:
            task = vm.PowerOffVM_Task()
            return self._wait_for_task(task)
        return False
    
    def reset_vm(self, vm_uuid):
        """重启虚拟机"""
        vm = self.get_vm_by_uuid(vm_uuid)
        if vm:
            task = vm.ResetVM_Task()
            return self._wait_for_task(task)
        return False
    
    def destroy_vm(self, vm_uuid):
        """删除虚拟机"""
        vm = self.get_vm_by_uuid(vm_uuid)
        if vm:
            # 先关机
            if vm.runtime.powerState == vim.VirtualMachinePowerState.poweredOn:
                self.power_off_vm(vm_uuid)
                time.sleep(5)
            
            # 删除虚拟机
            task = vm.Destroy_Task()
            return self._wait_for_task(task)
        return False
    
    def get_vm_metrics(self, vm_uuid):
        """获取虚拟机监控数据"""
        vm = self.get_vm_by_uuid(vm_uuid)
        if vm and vm.runtime.powerState == vim.VirtualMachinePowerState.poweredOn:
            return {
                'cpu_usage_percent': vm.summary.quickStats.overallCpuUsage or 0,
                'memory_usage_mb': vm.summary.quickStats.hostMemoryUsage or 0,
                'disk_usage_gb': (vm.summary.storage.committed or 0) / (1024**3),
                'power_state': str(vm.runtime.powerState),
                'uptime_seconds': vm.summary.quickStats.uptimeSeconds or 0,
                'guest_full_name': vm.summary.config.guestFullName or 'Unknown',
                'tools_status': str(vm.summary.guest.toolsStatus) if vm.summary.guest else 'Unknown'
            }
        return None
    
    def _wait_for_task(self, task, timeout=300):
        """等待任务完成"""
        start_time = time.time()
        while task.info.state == vim.TaskInfo.State.running:
            if time.time() - start_time > timeout:
                return False
            time.sleep(1)
        
        return task.info.state == vim.TaskInfo.State.success

# ===============================
# IP管理类
# ===============================

class IPManager:
    def __init__(self):
        self.network_segments = app.config['NETWORK_SEGMENTS']
        self._init_ip_pools()
    
    def _init_ip_pools(self):
        """初始化IP池"""
        for segment in self.network_segments:
            network = ipaddress.IPv4Network(segment)
            existing_ips = set(ip.ip_address for ip in IPPool.query.filter_by(network_segment=segment).all())
            
            for ip in network.hosts():
                ip_str = str(ip)
                if ip_str not in existing_ips:
                    ip_pool = IPPool(
                        network_segment=segment,
                        ip_address=ip_str,
                        is_available=True
                    )
                    db.session.add(ip_pool)
            
            try:
                db.session.commit()
            except Exception as e:
                db.session.rollback()
                logger.error(f"Error initializing IP pool: {str(e)}")
    
    def is_ip_alive(self, ip_address, timeout=2):
        """检查IP是否在使用中"""
        try:
            result = ping3.ping(ip_address, timeout=timeout)
            return result is not None
        except Exception:
            return False
    
    def allocate_ip(self, vm_id):
        """为虚拟机分配IP"""
        # 首先尝试从数据库中找可用IP
        available_ip = IPPool.query.filter_by(is_available=True).first()
        
        if available_ip:
            # 再次ping检查确保IP真的可用
            if not self.is_ip_alive(available_ip.ip_address):
                available_ip.is_available = False
                available_ip.assigned_vm_id = vm_id
                available_ip.assigned_at = datetime.utcnow()
                db.session.commit()
                return available_ip.ip_address
            else:
                # IP被占用，标记为不可用
                available_ip.is_available = False
                db.session.commit()
                return self.allocate_ip(vm_id)  # 递归查找下一个
        
        return None
    
    def release_ip(self, vm_id):
        """释放虚拟机的IP"""
        ip_record = IPPool.query.filter_by(assigned_vm_id=vm_id).first()
        if ip_record:
            ip_record.is_available = True
            ip_record.assigned_vm_id = None
            ip_record.assigned_at = None
            db.session.commit()
            return ip_record.ip_address
        return None

# ===============================
# 计费管理类
# ===============================

class BillingManager:
    def __init__(self):
        self.pricing = app.config['PRICING']
    
    def calculate_daily_cost(self, vm):
        """计算虚拟机每日费用"""
        cpu_cost = vm.cpu_cores * self.pricing['cpu_per_core']
        memory_cost = vm.memory_gb * self.pricing['memory_per_gb']
        disk_cost = (vm.disk_gb / 100) * self.pricing['disk_per_100gb']
        
        gpu_cost = 0
        if vm.gpu_type and vm.gpu_count > 0:
            if vm.gpu_type.lower() == '3090':
                gpu_cost = vm.gpu_count * self.pricing['gpu_3090']
            elif vm.gpu_type.lower() == 't4':
                gpu_cost = vm.gpu_count * self.pricing['gpu_t4']
        
        total_cost = cpu_cost + memory_cost + disk_cost + gpu_cost
        
        return {
            'cpu_cost': cpu_cost,
            'memory_cost': memory_cost,
            'disk_cost': disk_cost,
            'gpu_cost': gpu_cost,
            'total_cost': total_cost
        }
    
    def generate_daily_billing(self):
        """生成每日计费记录"""
        today = datetime.now().date()
        
        # 获取所有活跃的虚拟机
        active_vms = VirtualMachine.query.filter(
            VirtualMachine.status.in_(['running', 'stopped'])
        ).all()
        
        for vm in active_vms:
            # 检查今天是否已经计费
            existing_record = BillingRecord.query.filter_by(
                vm_id=vm.id,
                billing_date=today
            ).first()
            
            if not existing_record:
                costs = self.calculate_daily_cost(vm)
                
                billing_record = BillingRecord(
                    vm_id=vm.id,
                    project_id=vm.project_id,
                    tenant_id=vm.tenant_id,
                    billing_date=today,
                    cpu_cost=costs['cpu_cost'],
                    memory_cost=costs['memory_cost'],
                    disk_cost=costs['disk_cost'],
                    gpu_cost=costs['gpu_cost'],
                    total_cost=costs['total_cost']
                )
                
                db.session.add(billing_record)
        
        try:
            db.session.commit()
            logger.info("Daily billing generated successfully")
        except Exception as e:
            db.session.rollback()
            logger.error(f"Error generating daily billing: {str(e)}")

# ===============================
# 邮件通知类
# ===============================

class EmailNotifier:
    def __init__(self):
        self.smtp_server = app.config['SMTP_SERVER']
        self.smtp_port = app.config['SMTP_PORT']
        self.username = app.config['SMTP_USERNAME']
        self.password = app.config['SMTP_PASSWORD']
        self.from_email = app.config['SMTP_FROM']
    
    def send_email(self, to_email, subject, body, is_html=False):
        """发送邮件"""
        try:
            msg = MIMEMultipart('alternative')
            msg['Subject'] = subject
            msg['From'] = self.from_email
            msg['To'] = to_email
            
            if is_html:
                msg.attach(MIMEText(body, 'html'))
            else:
                msg.attach(MIMEText(body, 'plain'))
            
            server = smtplib.SMTP(self.smtp_server, self.smtp_port)
            server.starttls()
            server.login(self.username, self.password)
            server.send_message(msg)
            server.quit()
            
            logger.info(f"Email sent successfully to {to_email}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to send email: {str(e)}")
            return False
    
    def send_expiry_notification(self, vm, days_until_expiry):
        """发送过期通知"""
        tenant = Tenant.query.get(vm.tenant_id)
        
        subject = f"虚拟机即将过期通知 - {vm.name}"
        
        body = f"""
        尊敬的 {vm.owner}，
        
        您的虚拟机即将过期，请及时处理：
        
        虚拟机信息：
        - 名称: {vm.name}
        - 项目: {vm.project_name} ({vm.project_code})
        - 过期时间: {vm.deadline.strftime('%Y-%m-%d %H:%M:%S')}
        - 剩余天数: {days_until_expiry}天
        
        配置信息：
        - CPU: {vm.cpu_cores}核
        - 内存: {vm.memory_gb}GB
        - 磁盘: {vm.disk_gb}GB
        - GPU: {vm.gpu_type} x {vm.gpu_count}张 (如果有)
        
        请在过期前联系管理员进行续期，否则虚拟机将被自动关机。
        
        VMware IaaS 平台
        """
        
        if tenant and tenant.email:
            return self.send_email(tenant.email, subject, body)
        return False

# ===============================
# JWT工具函数
# ===============================

def generate_jwt_token(user_data, expires_hours=24):
    """生成JWT token"""
    payload = {
        'tenant_id': user_data['id'],
        'username': user_data['username'],
        'exp': datetime.utcnow() + timedelta(hours=expires_hours),
        'iat': datetime.utcnow()
    }
    return jwt.encode(payload, app.config['SECRET_KEY'], algorithm='HS256')

def decode_jwt_token(token):
    """解析JWT token"""
    try:
        payload = jwt.decode(token, app.config['SECRET_KEY'], algorithms=['HS256'])
        return payload
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None

# ===============================
# 认证装饰器
# ===============================

def jwt_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        token = None
        
        if 'Authorization' in request.headers:
            auth_header = request.headers['Authorization']
            try:
