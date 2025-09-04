#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
VMware IaaS Platform - 数据库初始化脚本
用于创建数据库表和初始化基础数据
"""

import os
import sys
from datetime import datetime, timedelta

# 添加应用根目录到Python路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app, db
from app import Tenant, Project, VirtualMachine, IPPool, BillingRecord, UserSession
import ipaddress

def create_tables():
    """创建数据库表"""
    print("Creating database tables...")
    try:
        with app.app_context():
            db.create_all()
        print("✅ Database tables created successfully")
        return True
    except Exception as e:
        print(f"❌ Error creating tables: {str(e)}")
        return False

def init_ip_pools():
    """初始化IP地址池"""
    print("Initializing IP address pools...")
    
    network_segments = [
        '192.168.100.0/24',
        '192.168.101.0/24', 
        '192.168.102.0/24'
    ]
    
    try:
        with app.app_context():
            total_added = 0
            for segment in network_segments:
                network = ipaddress.IPv4Network(segment)
                existing_count = IPPool.query.filter_by(network_segment=segment).count()
                
                if existing_count > 0:
                    print(f"  Segment {segment}: {existing_count} IPs already exist, skipping")
                    continue
                
                # 跳过网络地址、广播地址和网关地址
                excluded_ips = {
                    str(network.network_address),  # 网络地址
                    str(network.broadcast_address),  # 广播地址
                    str(network.network_address + 1),  # 通常是网关
                }
                
                added_count = 0
                for ip in network.hosts():
                    ip_str = str(ip)
                    if ip_str not in excluded_ips:
                        ip_pool = IPPool(
                            network_segment=segment,
                            ip_address=ip_str,
                            is_available=True
                        )
                        db.session.add(ip_pool)
                        added_count += 1
                
                db.session.commit()
                total_added += added_count
                print(f"  Segment {segment}: Added {added_count} IP addresses")
            
            print(f"✅ IP pools initialized successfully. Total: {total_added} IPs")
            return True
            
    except Exception as e:
        print(f"❌ Error initializing IP pools: {str(e)}")
        return False

def create_sample_data():
    """创建示例数据"""
    print("Creating sample data...")
    
    try:
        with app.app_context():
            # 检查是否已有数据
            if Tenant.query.first():
                print("  Sample data already exists, skipping")
                return True
            
            # 创建示例租户
            tenant = Tenant(
                ldap_uid='admin',
                username='admin',
                display_name='系统管理员',
                email='admin@company.com',
                department='IT部门',
                is_active=True,
                created_at=datetime.utcnow()
            )
            db.session.add(tenant)
            db.session.flush()  # 获取ID但不提交
            
            # 创建示例项目
            projects_data = [
                {
                    'project_name': '测试项目A',
                    'project_code': 'TEST-A',
                    'tenant_id': tenant.id
                },
                {
                    'project_name': '开发环境',
                    'project_code': 'DEV-001',
                    'tenant_id': tenant.id
                },
                {
                    'project_name': '生产环境',
                    'project_code': 'PROD-001',
                    'tenant_id': tenant.id
                }
            ]
            
            for project_data in projects_data:
                project = Project(**project_data)
                db.session.add(project)
            
            db.session.commit()
            print("✅ Sample data created successfully")
            return True
            
    except Exception as e:
        print(f"❌ Error creating sample data: {str(e)}")
        db.session.rollback()
        return False

def verify_database():
    """验证数据库状态"""
    print("Verifying database...")
    
    try:
        with app.app_context():
            # 检查表是否存在
            tables = [
                ('tenants', Tenant),
                ('projects', Project),
                ('virtual_machines', VirtualMachine),
                ('ip_pools', IPPool),
                ('billing_records', BillingRecord),
                ('user_sessions', UserSession)
            ]
            
            for table_name, model in tables:
                count = model.query.count()
                print(f"  {table_name}: {count} records")
            
            # 检查IP池
            available_ips = IPPool.query.filter_by(is_available=True).count()
            total_ips = IPPool.query.count()
            print(f"  IP Pool: {available_ips}/{total_ips} available")
            
            print("✅ Database verification completed")
            return True
            
    except Exception as e:
        print(f"❌ Error verifying database: {str(e)}")
        return False

def reset_database():
    """重置数据库（危险操作）"""
    print("⚠️  WARNING: This will delete all data!")
    confirm = input("Type 'RESET' to confirm: ")
    
    if confirm != 'RESET':
        print("Operation cancelled")
        return False
    
    try:
        with app.app_context():
            db.drop_all()
            print("✅ All tables dropped")
            
            db.create_all()
            print("✅ Tables recreated")
            
            return True
            
    except Exception as e:
        print(f"❌ Error resetting database: {str(e)}")
        return False

def show_database_info():
    """显示数据库信息"""
    print("Database Information:")
    print(f"  Database URL: {app.config['SQLALCHEMY_DATABASE_URI']}")
    
    try:
        with app.app_context():
            # 测试连接
            db.session.execute('SELECT version()')
            print("  Connection: ✅ Connected")
            
            # 显示统计信息
            print("\nTable Statistics:")
            tables = [
                ('Tenants', Tenant),
                ('Projects', Project), 
                ('Virtual Machines', VirtualMachine),
                ('IP Pool', IPPool),
                ('Billing Records', BillingRecord),
                ('User Sessions', UserSession)
            ]
            
            for name, model in tables:
                try:
                    count = model.query.count()
                    print(f"  {name}: {count}")
                except Exception as e:
                    print(f"  {name}: Error - {str(e)}")
                    
    except Exception as e:
        print(f"  Connection: ❌ Failed - {str(e)}")

def main():
    """主函数"""
    import argparse
    
    parser = argparse.ArgumentParser(description='VMware IaaS Database Management')
    parser.add_argument('--init', action='store_true', help='Initialize database')
    parser.add_argument('--sample', action='store_true', help='Create sample data')
    parser.add_argument('--verify', action='store_true', help='Verify database')
    parser.add_argument('--reset', action='store_true', help='Reset database (WARNING: destructive)')
    parser.add_argument('--info', action='store_true', help='Show database info')
    parser.add_argument('--all', action='store_true', help='Run init, sample data, and verify')
    
    args = parser.parse_args()
    
    if not any(vars(args).values()):
        parser.print_help()
        return
    
    print("=== VMware IaaS Database Management ===\n")
    
    success = True
    
    if args.reset:
        success = reset_database() and success
    
    if args.init or args.all:
        success = create_tables() and success
        success = init_ip_pools() and success
    
    if args.sample or args.all:
        success = create_sample_data() and success
    
    if args.verify or args.all:
        success = verify_database() and success
    
    if args.info:
        show_database_info()
    
    if success:
        print("\n✅ All operations completed successfully!")
    else:
        print("\n❌ Some operations failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
