# =====================================
# VMware IaaS Platform - 主应用Dockerfile
# =====================================

FROM python:3.11-slim

# 设置工作目录
WORKDIR /app

# 设置环境变量
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    build-essential \
    libldap2-dev \
    libsasl2-dev \
    libssl-dev \
    libpq-dev \
    curl \
    wget \
    iputils-ping \
    net-tools \
    vim \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# 创建非root用户
RUN groupadd -r iaas && useradd -r -g iaas iaas

# 复制requirements文件并安装Python依赖
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 安装额外的Python包（用于健康检查等）
RUN pip install --no-cache-dir requests

# 复制应用代码
COPY . .

# 创建auth.py文件（如果不存在）
RUN if [ ! -f auth.py ]; then \
    cat > auth.py << 'EOF'
#!/usr/bin/env python3
import os
import logging
import jwt
from datetime import datetime, timedelta
from functools import wraps
from flask import request, jsonify, current_app

logger = logging.getLogger(__name__)

class LDAPAuth:
    def __init__(self, app=None):
        self.demo_mode = True
        
    def authenticate(self, username, password):
        demo_users = {
            'admin': {'password': 'admin123', 'display_name': '系统管理员', 'department': 'IT'},
            'user1': {'password': 'user123', 'display_name': '张三', 'department': '研发'},
            'user2': {'password': 'user123', 'display_name': '李四', 'department': '测试'},
        }
        
        if username in demo_users and demo_users[username]['password'] == password:
            return {
                'username': username,
                'display_name': demo_users[username]['display_name'],
                'email': f'{username}@demo.com',
                'department': demo_users[username]['department'],
                'ldap_uid': username
            }
        return None
    
    def generate_token(self, user_info):
        payload = {
            'username': user_info['username'],
            'display_name': user_info['display_name'],
            'email': user_info['email'],
            'department': user_info['department'],
            'exp': datetime.utcnow() + timedelta(hours=24),
            'iat': datetime.utcnow()
        }
        
        return jwt.encode(payload, current_app.config['SECRET_KEY'], algorithm='HS256')
    
    def verify_token(self, token):
        try:
            return jwt.decode(token, current_app.config['SECRET_KEY'], algorithms=['HS256'])
        except:
            return None

ldap_auth = LDAPAuth()

def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = None
        if 'Authorization' in request.headers:
            try:
                token = request.headers['Authorization'].split(" ")[1]
            except:
                return jsonify({'error': 'Invalid authorization header'}), 401
        
        if not token:
            return jsonify({'error': 'Token is missing'}), 401
        
        current_user = ldap_auth.verify_token(token)
        if current_user is None:
            return jsonify({'error': 'Token is invalid'}), 401
        
        return f(current_user, *args, **kwargs)
    return decorated

def get_current_user():
    token = None
    if 'Authorization' in request.headers:
        try:
            token = request.headers['Authorization'].split(" ")[1]
        except:
            return None
    if not token:
        return None
    return ldap_auth.verify_token(token)
EOF
fi

# 创建必要目录并设置权限
RUN mkdir -p /app/logs /app/backups /app/static && \
    chown -R iaas:iaas /app

# 创建健康检查脚本
RUN echo '#!/bin/bash\npython3 -c "import requests; requests.get(\"http://localhost:5000/api/health\", timeout=5)" || exit 1' > /app/healthcheck.sh && \
    chmod +x /app/healthcheck.sh

# 切换到非root用户
USER iaas

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /app/healthcheck.sh

# 暴露端口
EXPOSE 5000

# 启动命令
CMD ["python3", "app.py"]
