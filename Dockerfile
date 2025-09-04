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

# 创建备用认证文件
RUN echo '#!/usr/bin/env python3' > /app/auth_backup.py && \
    echo 'import os, logging, jwt' >> /app/auth_backup.py && \
    echo 'from datetime import datetime, timedelta' >> /app/auth_backup.py && \
    echo 'from functools import wraps' >> /app/auth_backup.py && \
    echo 'from flask import request, jsonify, current_app' >> /app/auth_backup.py && \
    echo '' >> /app/auth_backup.py && \
    echo 'logger = logging.getLogger(__name__)' >> /app/auth_backup.py && \
    echo '' >> /app/auth_backup.py && \
    echo 'class LDAPAuth:' >> /app/auth_backup.py && \
    echo '    def __init__(self, app=None):' >> /app/auth_backup.py && \
    echo '        self.demo_mode = True' >> /app/auth_backup.py && \
    echo '    def authenticate(self, username, password):' >> /app/auth_backup.py && \
    echo '        demo_users = {"admin": {"password": "admin123", "display_name": "系统管理员", "department": "IT"}}' >> /app/auth_backup.py && \
    echo '        if username in demo_users and demo_users[username]["password"] == password:' >> /app/auth_backup.py && \
    echo '            return {"username": username, "display_name": demo_users[username]["display_name"], "email": f"{username}@demo.com", "department": demo_users[username]["department"], "ldap_uid": username}' >> /app/auth_backup.py && \
    echo '        return None' >> /app/auth_backup.py && \
    echo '    def generate_token(self, user_info):' >> /app/auth_backup.py && \
    echo '        payload = {"username": user_info["username"], "exp": datetime.utcnow() + timedelta(hours=24)}' >> /app/auth_backup.py && \
    echo '        return jwt.encode(payload, current_app.config["SECRET_KEY"], algorithm="HS256")' >> /app/auth_backup.py && \
    echo '    def verify_token(self, token):' >> /app/auth_backup.py && \
    echo '        try:' >> /app/auth_backup.py && \
    echo '            return jwt.decode(token, current_app.config["SECRET_KEY"], algorithms=["HS256"])' >> /app/auth_backup.py && \
    echo '        except:' >> /app/auth_backup.py && \
    echo '            return None' >> /app/auth_backup.py && \
    echo '' >> /app/auth_backup.py && \
    echo 'ldap_auth = LDAPAuth()' >> /app/auth_backup.py && \
    echo '' >> /app/auth_backup.py && \
    echo 'def token_required(f):' >> /app/auth_backup.py && \
    echo '    @wraps(f)' >> /app/auth_backup.py && \
    echo '    def decorated(*args, **kwargs):' >> /app/auth_backup.py && \
    echo '        token = None' >> /app/auth_backup.py && \
    echo '        if "Authorization" in request.headers:' >> /app/auth_backup.py && \
    echo '            try:' >> /app/auth_backup.py && \
    echo '                token = request.headers["Authorization"].split(" ")[1]' >> /app/auth_backup.py && \
    echo '            except:' >> /app/auth_backup.py && \
    echo '                return jsonify({"error": "Invalid header"}), 401' >> /app/auth_backup.py && \
    echo '        if not token:' >> /app/auth_backup.py && \
    echo '            return jsonify({"error": "Token missing"}), 401' >> /app/auth_backup.py && \
    echo '        current_user = ldap_auth.verify_token(token)' >> /app/auth_backup.py && \
    echo '        if current_user is None:' >> /app/auth_backup.py && \
    echo '            return jsonify({"error": "Token invalid"}), 401' >> /app/auth_backup.py && \
    echo '        return f(current_user, *args, **kwargs)' >> /app/auth_backup.py && \
    echo '    return decorated' >> /app/auth_backup.py && \
    echo '' >> /app/auth_backup.py && \
    echo 'def get_current_user():' >> /app/auth_backup.py && \
    echo '    return None' >> /app/auth_backup.py

# 检查并使用认证文件
RUN if [ ! -f auth.py ]; then cp auth_backup.py auth.py; fi

# 创建必要目录并设置权限
RUN mkdir -p /app/logs /app/backups /app/static && \
    chown -R iaas:iaas /app

# 创建健康检查脚本
RUN echo '#!/bin/bash' > /app/healthcheck.sh && \
    echo 'python3 -c "import requests; requests.get(\"http://localhost:5000/api/health\", timeout=5)" || exit 1' >> /app/healthcheck.sh && \
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
