#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
LDAP认证模块
支持LDAP认证和演示模式
"""

import os
import logging
import jwt
from datetime import datetime, timedelta
from functools import wraps
from flask import request, jsonify, current_app

logger = logging.getLogger(__name__)

class LDAPAuth:
    def __init__(self, app=None):
        self.app = app
        if app is not None:
            self.init_app(app)
    
    def init_app(self, app):
        """初始化认证模块"""
        self.ldap_server = os.environ.get('LDAP_SERVER', '')
        self.ldap_base_dn = os.environ.get('LDAP_BASE_DN', '')
        self.ldap_user_dn_template = os.environ.get('LDAP_USER_DN_TEMPLATE', '')
        self.ldap_admin_dn = os.environ.get('LDAP_ADMIN_DN', '')
        self.ldap_admin_password = os.environ.get('LDAP_ADMIN_PASSWORD', '')
        
        # 检查LDAP配置
        if not all([self.ldap_server, self.ldap_base_dn, self.ldap_user_dn_template]):
            logger.warning("LDAP配置不完整，将使用演示模式")
            self.demo_mode = True
        else:
            self.demo_mode = False
            
            # 尝试导入LDAP模块
            try:
                import ldap
                self.ldap = ldap
                logger.info("LDAP模块加载成功")
                
                # 测试LDAP连接
                try:
                    conn = ldap.initialize(self.ldap_server)
                    conn.set_option(ldap.OPT_REFERRALS, 0)
                    conn.set_option(ldap.OPT_TIMEOUT, 10)
                    conn.simple_bind_s(self.ldap_admin_dn, self.ldap_admin_password)
                    conn.unbind()
                    logger.info("LDAP连接测试成功")
                except Exception as e:
                    logger.warning(f"LDAP连接测试失败: {str(e)}，将使用演示模式")
                    self.demo_mode = True
                    
            except ImportError:
                logger.warning("LDAP模块未安装，使用演示模式")
                self.demo_mode = True
    
    def authenticate(self, username, password):
        """用户认证"""
        if self.demo_mode:
            return self._demo_authenticate(username, password)
        
        try:
            # LDAP认证
            user_dn = self.ldap_user_dn_template.format(username=username)
            conn = self.ldap.initialize(self.ldap_server)
            conn.set_option(self.ldap.OPT_REFERRALS, 0)
            conn.set_option(self.ldap.OPT_TIMEOUT, 10)
            
            # 尝试绑定用户
            conn.simple_bind_s(user_dn, password)
            
            # 获取用户信息
            search_filter = f'(uid={username})'
            result = conn.search_s(
                self.ldap_base_dn,
                self.ldap.SCOPE_SUBTREE,
                search_filter,
                ['uid', 'cn', 'mail', 'departmentNumber', 'displayName', 'sn', 'givenName']
            )
            
            if result:
                dn, attrs = result[0]
                
                # 提取用户信息
                display_name = self._get_attr_value(attrs, 'displayName') or \
                              self._get_attr_value(attrs, 'cn') or \
                              f"{self._get_attr_value(attrs, 'givenName', '')} {self._get_attr_value(attrs, 'sn', '')}".strip() or \
                              username
                
                user_info = {
                    'username': username,
                    'display_name': display_name,
                    'email': self._get_attr_value(attrs, 'mail') or f'{username}@company.com',
                    'department': self._get_attr_value(attrs, 'departmentNumber') or 'IT',
                    'ldap_uid': username,
                    'ldap_dn': dn
                }
                
                conn.unbind()
                logger.info(f"LDAP authentication successful for user: {username}")
                return user_info
            else:
                conn.unbind()
                logger.warning(f"LDAP user not found: {username}")
                return None
                
        except Exception as e:
            logger.error(f"LDAP认证失败 for {username}: {str(e)}")
            return None
    
    def _get_attr_value(self, attrs, attr_name, default=None):
        """从LDAP属性中提取值"""
        try:
            if attr_name in attrs and attrs[attr_name]:
                return attrs[attr_name][0].decode('utf-8')
        except (IndexError, UnicodeDecodeError, AttributeError):
            pass
        return default
    
    def _demo_authenticate(self, username, password):
        """演示模式认证"""
        # 演示用户数据
        demo_users = {
            'admin': {
                'password': 'admin123',
                'display_name': '系统管理员',
                'department': 'IT',
                'email': 'admin@demo.com'
            },
            'user1': {
                'password': 'user123',
                'display_name': '张三',
                'department': '研发部',
                'email': 'zhangsan@demo.com'
            },
            'user2': {
                'password': 'user123',
                'display_name': '李四',
                'department': '测试部',
                'email': 'lisi@demo.com'
            },
            'manager': {
                'password': 'manager123',
                'display_name': '王经理',
                'department': '管理部',
                'email': 'manager@demo.com'
            },
            'test': {
                'password': 'test123',
                'display_name': '测试用户',
                'department': '质量保证',
                'email': 'test@demo.com'
            }
        }
        
        if username in demo_users and demo_users[username]['password'] == password:
            user_data = demo_users[username]
            logger.info(f"Demo authentication successful for user: {username}")
            return {
                'username': username,
                'display_name': user_data['display_name'],
                'email': user_data['email'],
                'department': user_data['department'],
                'ldap_uid': username
            }
        
        logger.warning(f"Demo authentication failed for user: {username}")
        return None
    
    def generate_token(self, user_info):
        """生成JWT令牌"""
        try:
            payload = {
                'username': user_info['username'],
                'display_name': user_info['display_name'],
                'email': user_info['email'],
                'department': user_info['department'],
                'ldap_uid': user_info['ldap_uid'],
                'exp': datetime.utcnow() + timedelta(hours=24),
                'iat': datetime.utcnow(),
                'iss': 'vmware-iaas-platform'
            }
            
            token = jwt.encode(
                payload,
                current_app.config['SECRET_KEY'],
                algorithm='HS256'
            )
            
            logger.info(f"JWT token generated for user: {user_info['username']}")
            return token
            
        except Exception as e:
            logger.error(f"Token generation failed: {str(e)}")
            return None
    
    def verify_token(self, token):
        """验证JWT令牌"""
        try:
            payload = jwt.decode(
                token,
                current_app.config['SECRET_KEY'],
                algorithms=['HS256'],
                options={'verify_exp': True}
            )
            
            # 检查必需字段
            required_fields = ['username', 'display_name', 'email', 'ldap_uid']
            for field in required_fields:
                if field not in payload:
                    logger.warning(f"Token missing required field: {field}")
                    return None
            
            return payload
            
        except jwt.ExpiredSignatureError:
            logger.warning("Token has expired")
            return None
        except jwt.InvalidTokenError as e:
            logger.warning(f"Invalid token: {str(e)}")
            return None
        except Exception as e:
            logger.error(f"Token verification error: {str(e)}")
            return None
    
    def refresh_token(self, token):
        """刷新令牌"""
        try:
            payload = self.verify_token(token)
            if not payload:
                return None
            
            # 检查令牌是否即将过期（1小时内）
            exp_time = datetime.fromtimestamp(payload['exp'])
            if exp_time - datetime.utcnow() > timedelta(hours=1):
                # 令牌还有效期，不需要刷新
                return token
            
            # 生成新令牌
            user_info = {
                'username': payload['username'],
                'display_name': payload['display_name'],
                'email': payload['email'],
                'department': payload.get('department', 'IT'),
                'ldap_uid': payload['ldap_uid']
            }
            
            return self.generate_token(user_info)
            
        except Exception as e:
            logger.error(f"Token refresh error: {str(e)}")
            return None

# 全局实例
ldap_auth = LDAPAuth()

def token_required(f):
    """令牌验证装饰器"""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = None
        
        # 从Header获取令牌
        if 'Authorization' in request.headers:
            auth_header = request.headers['Authorization']
            try:
                if auth_header.startswith('Bearer '):
                    token = auth_header.split(" ")[1]
                else:
                    token = auth_header  # 兼容性处理
            except IndexError:
                return jsonify({'error': '无效的认证头格式'}), 401
        
        if not token:
            return jsonify({'error': '缺少认证令牌'}), 401
        
        # 验证令牌
        current_user = ldap_auth.verify_token(token)
        if current_user is None:
            return jsonify({'error': '令牌无效或已过期'}), 401
        
        # 将用户信息传递给路由函数
        return f(current_user, *args, **kwargs)
    
    return decorated

def get_current_user():
    """获取当前用户信息"""
    token = None
    
    if 'Authorization' in request.headers:
        auth_header = request.headers['Authorization']
        try:
            if auth_header.startswith('Bearer '):
                token = auth_header.split(" ")[1]
            else:
                token = auth_header
        except IndexError:
            return None
    
    if not token:
        return None
    
    return ldap_auth.verify_token(token)

def admin_required(f):
    """管理员权限装饰器"""
    @wraps(f)
    def decorated(*args, **kwargs):
        current_user = get_current_user()
        if not current_user:
            return jsonify({'error': '需要认证'}), 401
        
        # 检查是否为管理员（这里简单检查用户名）
        admin_users = ['admin', 'administrator', 'root']
        if current_user.get('username') not in admin_users:
            return jsonify({'error': '需要管理员权限'}), 403
        
        return f(current_user, *args, **kwargs)
    
    return decorated

# 用户角色检查
def has_role(user, role):
    """检查用户是否有指定角色"""
    user_roles = {
        'admin': ['admin', 'user'],
        'manager': ['manager', 'user'],
        'user1': ['user'],
        'user2': ['user'],
        'test': ['user']
    }
    
    username = user.get('username', '')
    return role in user_roles.get(username, ['user'])

def role_required(role):
    """角色验证装饰器"""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            current_user = get_current_user()
            if not current_user:
                return jsonify({'error': '需要认证'}), 401
            
            if not has_role(current_user, role):
                return jsonify({'error': f'需要{role}角色权限'}), 403
            
            return f(current_user, *args, **kwargs)
        
        return decorated
    return decorator
