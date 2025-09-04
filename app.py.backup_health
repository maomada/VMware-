#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import logging
import ipaddress
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, send_from_directory, redirect, url_for
from flask_sqlalchemy import SQLAlchemy
from flask_cors import CORS

# 配置类
class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY', 'vmware-iaas-secret-key-2025')
    
    # 数据库配置
    DB_HOST = os.environ.get('DB_HOST', 'postgres')
    DB_PORT = os.environ.get('DB_PORT', '5432')
    DB_NAME = os.environ.get('DB_NAME', 'vmware_iaas')
    DB_USER = os.environ.get('DB_USER', 'iaas_user')
    DB_PASSWORD = os.environ.get('DB_PASSWORD', 'password')
    
    SQLALCHEMY_DATABASE_URI = f'postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}'
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # 网络配置
    NETWORK_SEGMENTS = [
        os.environ.get('NETWORK_SEGMENT_1', '192.168.100.0/24'),
        os.environ.get('NETWORK_SEGMENT_2', '192.168.101.0/24'),
        os.environ.get('NETWORK_SEGMENT_3', '192.168.102.0/24')
    ]

# Flask应用初始化
app = Flask(__name__)
app.config.from_object(Config)
db = SQLAlchemy(app)
CORS(app)

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# 数据库模型
class Tenant(db.Model):
    __tablename__ = 'tenants'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(100), nullable=False)
    display_name = db.Column(db.String(200))
    email = db.Column(db.String(200))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

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
    owner = db.Column(db.String(200), nullable=False)
    deadline = db.Column(db.DateTime, nullable=False)
    tenant_id = db.Column(db.Integer, db.ForeignKey('tenants.id'), nullable=False)
    ip_address = db.Column(db.String(15))
    cpu_cores = db.Column(db.Integer, nullable=False)
    memory_gb = db.Column(db.Integer, nullable=False)
    disk_gb = db.Column(db.Integer, nullable=False)
    status = db.Column(db.String(20), default='creating')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class IPPool(db.Model):
    __tablename__ = 'ip_pools'
    id = db.Column(db.Integer, primary_key=True)
    network_segment = db.Column(db.String(20), nullable=False)
    ip_address = db.Column(db.String(15), nullable=False)
    is_available = db.Column(db.Boolean, default=True)
    assigned_vm_id = db.Column(db.Integer, db.ForeignKey('virtual_machines.id'))

# 路由
@app.route('/')
def index():
    return send_from_directory('static', 'login.html')

@app.route('/login')
def login_page():
    return send_from_directory('static', 'login.html')

@app.route('/static/<path:filename>')
def static_files(filename):
    return send_from_directory('static', filename)

@app.route('/api/health')
def health_check():
    health_status = {
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat(),
        'version': '2.0.0',
        'services': {}
    }
    
    try:
        db.session.execute('SELECT 1')
        health_status['services']['database'] = 'connected'
    except Exception as e:
        health_status['services']['database'] = f'error: {str(e)}'
        health_status['status'] = 'unhealthy'
        return jsonify(health_status), 503
    
    return jsonify(health_status)

@app.route('/api/auth/login', methods=['POST'])
def login():
    return jsonify({
        'error': 'Authentication service requires LDAP configuration. Please check .env file.'
    }), 501

@app.route('/api/templates')
def list_templates():
    templates = [
        {'name': 'Ubuntu-20.04-Template', 'display_name': 'Ubuntu 20.04 LTS', 'os_type': 'Linux'},
        {'name': 'Ubuntu-22.04-Template', 'display_name': 'Ubuntu 22.04 LTS', 'os_type': 'Linux'},
        {'name': 'CentOS-7-Template', 'display_name': 'CentOS 7', 'os_type': 'Linux'},
        {'name': 'Windows-Server-2019-Template', 'display_name': 'Windows Server 2019', 'os_type': 'Windows'}
    ]
    return jsonify({'templates': templates})

@app.route('/api/system/stats')
def system_stats():
    try:
        total_vms = VirtualMachine.query.count()
        total_projects = Project.query.count()
        
        return jsonify({
            'vms': {'total': total_vms, 'running': 0, 'stopped': 0, 'expiring_soon': 0, 'expired': 0},
            'resources': {'total_cpu_cores': 0, 'total_memory_gb': 0, 'total_disk_gb': 0, 'total_gpus': 0},
            'projects': {'total': total_projects}
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/metrics')
def metrics():
    try:
        total_vms = VirtualMachine.query.count()
        metrics_text = f"""# HELP vmware_iaas_vms_total Total number of VMs
# TYPE vmware_iaas_vms_total gauge
vmware_iaas_vms_total {total_vms}
"""
        return metrics_text, 200, {'Content-Type': 'text/plain'}
    except Exception:
        return "# Error generating metrics\n", 500, {'Content-Type': 'text/plain'}

@app.errorhandler(404)
def not_found_error(error):
    if request.path.startswith('/api/'):
        return jsonify({'error': 'Not found'}), 404
    return redirect(url_for('index'))

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

def init_database():
    with app.app_context():
        try:
            db.create_all()
            logger.info("Database tables created")
            
            # 初始化IP池
            for segment in app.config['NETWORK_SEGMENTS']:
                network = ipaddress.IPv4Network(segment)
                existing_count = IPPool.query.filter_by(network_segment=segment).count()
                
                if existing_count == 0:
                    excluded_ips = {str(network.network_address), str(network.broadcast_address), str(network.network_address + 1)}
                    for ip in network.hosts():
                        ip_str = str(ip)
                        if ip_str not in excluded_ips:
                            ip_pool = IPPool(network_segment=segment, ip_address=ip_str, is_available=True)
                            db.session.add(ip_pool)
                    
                    db.session.commit()
                    logger.info(f"Initialized IP pool for {segment}")
            
        except Exception as e:
            logger.error(f"Database init failed: {e}")
            raise

if __name__ == '__main__':
    init_database()
    app.run(host='0.0.0.0', port=5000, debug=False)
