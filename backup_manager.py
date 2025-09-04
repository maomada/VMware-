#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
VMware IaaS Platform - 数据库备份管理器
"""

import os
import sys
import subprocess
import logging
import gzip
import shutil
from datetime import datetime, timedelta
from pathlib import Path

# 添加应用根目录到Python路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class BackupManager:
    def __init__(self):
        self.backup_dir = Path('/app/backups')
        self.backup_dir.mkdir(exist_ok=True)
        
        # 数据库配置
        self.db_host = app.config['DB_HOST']
        self.db_port = app.config['DB_PORT']
        self.db_name = app.config['DB_NAME']
        self.db_user = app.config['DB_USER']
        self.db_password = app.config['DB_PASSWORD']
        
    def create_db_backup(self):
        """创建数据库备份"""
        try:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            backup_filename = f"vmware_iaas_backup_{timestamp}.sql"
            backup_path = self.backup_dir / backup_filename
            compressed_path = self.backup_dir / f"{backup_filename}.gz"
            
            logger.info(f"Starting database backup to {backup_path}")
            
            # 设置环境变量避免密码提示
            env = os.environ.copy()
            env['PGPASSWORD'] = self.db_password
            
            # 执行pg_dump
            cmd = [
                'pg_dump',
                '-h', self.db_host,
                '-p', str(self.db_port),
                '-U', self.db_user,
                '-d', self.db_name,
                '--no-password',
                '--verbose',
                '--clean',
                '--create',
                '--format=plain'
            ]
            
            with open(backup_path, 'w') as f:
                result = subprocess.run(
                    cmd,
                    env=env,
                    stdout=f,
                    stderr=subprocess.PIPE,
                    text=True
                )
            
            if result.returncode == 0:
                logger.info("Database backup completed successfully")
                
                # 压缩备份文件
                logger.info("Compressing backup file...")
                with open(backup_path, 'rb') as f_in:
                    with gzip.open(compressed_path, 'wb') as f_out:
                        shutil.copyfileobj(f_in, f_out)
                
                # 删除未压缩的文件
                backup_path.unlink()
                
                logger.info(f"Backup compressed and saved to {compressed_path}")
                
                # 清理旧备份
                self.cleanup_old_backups()
                
                return True
            else:
                logger.error(f"Database backup failed: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Error creating database backup: {str(e)}")
            return False
    
    def cleanup_old_backups(self, keep_days=30):
        """清理旧的备份文件"""
        try:
            cutoff_date = datetime.now() - timedelta(days=keep_days)
            logger.info(f"Cleaning up backups older than {keep_days} days")
            
            deleted_count = 0
            for backup_file in self.backup_dir.glob("vmware_iaas_backup_*.sql.gz"):
                try:
                    file_time = datetime.fromtimestamp(backup_file.stat().st_mtime)
                    if file_time < cutoff_date:
                        backup_file.unlink()
                        deleted_count += 1
                        logger.info(f"Deleted old backup: {backup_file.name}")
                except Exception as e:
                    logger.error(f"Error deleting backup file {backup_file}: {str(e)}")
            
            logger.info(f"Cleanup completed: {deleted_count} old backups deleted")
            
        except Exception as e:
            logger.error(f"Error during backup cleanup: {str(e)}")
    
    def restore_db_backup(self, backup_file):
        """恢复数据库备份"""
        try:
            backup_path = self.backup_dir / backup_file
            if not backup_path.exists():
                logger.error(f"Backup file not found: {backup_path}")
                return False
            
            logger.info(f"Restoring database from {backup_path}")
            
            # 如果是压缩文件，先解压
            if backup_path.suffix == '.gz':
                temp_path = backup_path.with_suffix('')
                with gzip.open(backup_path, 'rb') as f_in:
                    with open(temp_path, 'wb') as f_out:
                        shutil.copyfileobj(f_in, f_out)
                restore_path = temp_path
            else:
                restore_path = backup_path
            
            # 设置环境变量
            env = os.environ.copy()
            env['PGPASSWORD'] = self.db_password
            
            # 执行恢复
            cmd = [
                'psql',
                '-h', self.db_host,
                '-p', str(self.db_port),
                '-U', self.db_user,
                '-d', 'postgres',  # 连接到postgres数据库执行恢复
                '--no-password',
                '-f', str(restore_path)
            ]
            
            result = subprocess.run(
                cmd,
                env=env,
                capture_output=True,
                text=True
            )
            
            # 清理临时文件
            if backup_path.suffix == '.gz' and restore_path.exists():
                restore_path.unlink()
            
            if result.returncode == 0:
                logger.info("Database restore completed successfully")
                return True
            else:
                logger.error(f"Database restore failed: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Error restoring database backup: {str(e)}")
            return False
    
    def list_backups(self):
        """列出所有可用的备份"""
        try:
            backups = []
            for backup_file in sorted(self.backup_dir.glob("vmware_iaas_backup_*.sql.gz")):
                stat = backup_file.stat()
                backups.append({
                    'filename': backup_file.name,
                    'size': self._format_size(stat.st_size),
                    'created': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S'),
                    'path': str(backup_file)
                })
            
            return backups
            
        except Exception as e:
            logger.error(f"Error listing backups: {str(e)}")
            return []
    
    def _format_size(self, size_bytes):
        """格式化文件大小"""
        if size_bytes == 0:
            return "0B"
        
        size_names = ["B", "KB", "MB", "GB", "TB"]
        import math
        i = int(math.floor(math.log(size_bytes, 1024)))
        p = math.pow(1024, i)
        s = round(size_bytes / p, 2)
        return f"{s} {size_names[i]}"
    
    def get_backup_status(self):
        """获取备份状态信息"""
        try:
            backups = self.list_backups()
            total_size = sum(
                Path(backup['path']).stat().st_size 
                for backup in backups
            )
            
            latest_backup = None
            if backups:
                latest_backup = backups[-1]
            
            return {
                'total_backups': len(backups),
                'total_size': self._format_size(total_size),
                'latest_backup': latest_backup,
                'backup_directory': str(self.backup_dir)
            }
            
        except Exception as e:
            logger.error(f"Error getting backup status: {str(e)}")
            return None

def main():
    """主函数"""
    import argparse
    
    parser = argparse.ArgumentParser(description='VMware IaaS Backup Manager')
    parser.add_argument('--backup', action='store_true', help='Create database backup')
    parser.add_argument('--restore', type=str, help='Restore from backup file')
    parser.add_argument('--list', action='store_true', help='List all backups')
    parser.add_argument('--status', action='store_true', help='Show backup status')
    parser.add_argument('--cleanup', type=int, metavar='DAYS', help='Cleanup backups older than N days')
    
    args = parser.parse_args()
    
    backup_manager = BackupManager()
    
    if args.backup:
        logger.info("Starting database backup...")
        success = backup_manager.create_db_backup()
        if success:
            print("✅ Database backup completed successfully")
        else:
            print("❌ Database backup failed")
            sys.exit(1)
    
    elif args.restore:
        logger.info(f"Starting database restore from {args.restore}...")
        success = backup_manager.restore_db_backup(args.restore)
        if success:
            print("✅ Database restore completed successfully")
        else:
            print("❌ Database restore failed")
            sys.exit(1)
    
    elif args.list:
        backups = backup_manager.list_backups()
        if backups:
            print("Available backups:")
            print("-" * 80)
            print(f"{'Filename':<40} {'Size':<10} {'Created':<20}")
            print("-" * 80)
            for backup in backups:
                print(f"{backup['filename']:<40} {backup['size']:<10} {backup['created']:<20}")
        else:
            print("No backups found")
    
    elif args.status:
        status = backup_manager.get_backup_status()
        if status:
            print("Backup Status:")
            print(f"  Total backups: {status['total_backups']}")
            print(f"  Total size: {status['total_size']}")
            print(f"  Backup directory: {status['backup_directory']}")
            if status['latest_backup']:
                print(f"  Latest backup: {status['latest_backup']['filename']}")
                print(f"  Created: {status['latest_backup']['created']}")
        else:
            print("❌ Could not get backup status")
    
    elif args.cleanup:
        logger.info(f"Cleaning up backups older than {args.cleanup} days...")
        backup_manager.cleanup_old_backups(args.cleanup)
        print(f"✅ Cleanup completed")
    
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
