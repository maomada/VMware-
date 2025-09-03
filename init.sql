# init.sql
-- VMware IaaS Platform Database Initialization

-- 创建扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 设置时区
SET timezone = 'UTC';

-- 创建索引（应用启动后会自动创建表）
-- 这里可以添加一些初始化数据或特殊配置

-- 创建只读用户（用于监控）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'iaas_readonly') THEN
        CREATE USER iaas_readonly WITH PASSWORD 'readonly_password';
        GRANT CONNECT ON DATABASE vmware_iaas TO iaas_readonly;
        GRANT USAGE ON SCHEMA public TO iaas_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO iaas_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO iaas_readonly;
    END IF;
END
$$;

