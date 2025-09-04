#!/usr/bin/env python3
import os
import sys
import logging
from sqlalchemy import create_engine, text

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def get_database_url():
    db_host = os.environ.get('DB_HOST', 'postgres')
    db_port = os.environ.get('DB_PORT', '5432')
    db_name = os.environ.get('DB_NAME', 'vmware_iaas')
    db_user = os.environ.get('DB_USER', 'iaas_user')
    db_password = os.environ.get('DB_PASSWORD', 'password')
    return f'postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'

def fix_schema():
    try:
        engine = create_engine(get_database_url())
        with engine.connect() as conn:
            trans = conn.begin()
            try:
                # 添加 tenants.ldap_uid
                logger.info("检查 tenants.ldap_uid...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'tenants' AND column_name = 'ldap_uid'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 tenants.ldap_uid 字段...")
                    conn.execute(text("ALTER TABLE tenants ADD COLUMN ldap_uid VARCHAR(100)"))
                    conn.execute(text("UPDATE tenants SET ldap_uid = username WHERE ldap_uid IS NULL"))
                    # 检查是否有数据再设置约束
                    count = conn.execute(text("SELECT COUNT(*) FROM tenants")).scalar()
                    if count > 0:
                        conn.execute(text("ALTER TABLE tenants ALTER COLUMN ldap_uid SET NOT NULL"))
                        conn.execute(text("ALTER TABLE tenants ADD CONSTRAINT tenants_ldap_uid_unique UNIQUE (ldap_uid)"))
                
                # 添加 ip_pools.assigned_at
                logger.info("检查 ip_pools.assigned_at...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'ip_pools' AND column_name = 'assigned_at'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 ip_pools.assigned_at 字段...")
                    conn.execute(text("ALTER TABLE ip_pools ADD COLUMN assigned_at TIMESTAMP"))
                
                # 添加 virtual_machines.host_name
                logger.info("检查 virtual_machines.host_name...")
                result = conn.execute(text("""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'virtual_machines' AND column_name = 'host_name'
                """)).fetchone()
                
                if not result:
                    logger.info("添加 virtual_machines.host_name 字段...")
                    conn.execute(text("ALTER TABLE virtual_machines ADD COLUMN host_name VARCHAR(100)"))
                
                # 检查其他可能缺失的字段
                vm_columns = [
                    ('vcenter_vm_id', 'VARCHAR(100)'),
                    ('gpu_type', 'VARCHAR(20)'),
                    ('gpu_count', 'INTEGER DEFAULT 0')
                ]
                
                for col_name, col_type in vm_columns:
                    result = conn.execute(text(f"""
                        SELECT column_name FROM information_schema.columns 
                        WHERE table_name = 'virtual_machines' AND column_name = '{col_name}'
                    """)).fetchone()
                    
                    if not result:
                        logger.info(f"添加 virtual_machines.{col_name} 字段...")
                        conn.execute(text(f"ALTER TABLE virtual_machines ADD COLUMN {col_name} {col_type}"))
                
                trans.commit()
                logger.info("✅ 数据库结构修复完成!")
                return True
                
            except Exception as e:
                trans.rollback()
                logger.error(f"修复失败: {e}")
                return False
                
    except Exception as e:
        logger.error(f"连接数据库失败: {e}")
        return False

if __name__ == '__main__':
    if fix_schema():
        print("数据库修复成功!")
    else:
        print("数据库修复失败!")
        sys.exit(1)
