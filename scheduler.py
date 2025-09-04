#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
VMware IaaS Platform - 独立定时任务调度器
"""

import os
import sys
import time
import logging
import schedule
from datetime import datetime, timedelta

# 添加应用根目录到Python路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app, db
from app import VirtualMachine, BillingRecord, vmware_manager, billing_manager, email_notifier

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/scheduler_logs/scheduler.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

def check_expired_vms():
    """检查过期虚拟机"""
    logger.info("=== Starting expired VMs check ===")
    
    try:
        with app.app_context():
            now = datetime.utcnow()
            
            # 查找即将过期的虚拟机 (7天内)
            expiring_vms = VirtualMachine.query.filter(
                VirtualMachine.deadline <= now + timedelta(days=7),
                VirtualMachine.deadline > now,
                VirtualMachine.status.in_(['running', 'stopped'])
            ).all()
            
            logger.info(f"Found {len(expiring_vms)} VMs expiring within 7 days")
            
            for vm in expiring_vms:
                days_until_expiry = (vm.deadline - now).days
                logger.info(f"VM {vm.name} expires in {days_until_expiry} days")
                
                # 发送通知邮件
                try:
                    email_notifier.send_expiry_notification(vm, days_until_expiry)
                    logger.info(f"Expiry notification sent for VM {vm.name}")
                except Exception as e:
                    logger.error(f"Failed to send expiry notification for VM {vm.name}: {str(e)}")
            
            # 查找已过期的虚拟机
            expired_vms = VirtualMachine.query.filter(
                VirtualMachine.deadline <= now,
                VirtualMachine.status.in_(['running', 'stopped'])
            ).all()
            
            logger.info(f"Found {len(expired_vms)} expired VMs")
            
            for vm in expired_vms:
                days_past_expiry = (now - vm.deadline).days
                logger.warning(f"VM {vm.name} expired {days_past_expiry} days ago")
                
                # 自动关机过期的运行中VM
                if days_past_expiry >= 1 and vm.status == 'running' and vmware_manager:
                    try:
                        success = vmware_manager.power_off_vm(vm.vcenter_uuid)
                        if success:
                            vm.status = 'expired'
                            db.session.commit()
                            logger.info(f"Powered off expired VM: {vm.name}")
                    except Exception as e:
                        logger.error(f"Failed to power off expired VM {vm.name}: {str(e)}")
                
                # 发送过期通知
                try:
                    email_notifier.send_expiry_notification(vm, -days_past_expiry)
                    logger.info(f"Expired notification sent for VM {vm.name}")
                except Exception as e:
                    logger.error(f"Failed to send expired notification for VM {vm.name}: {str(e)}")
            
            logger.info("=== Expired VMs check completed ===")
            
    except Exception as e:
        logger.error(f"Error in check_expired_vms: {str(e)}")

def run_daily_billing():
    """运行每日计费任务"""
    logger.info("=== Starting daily billing ===")
    
    try:
        with app.app_context():
            today = datetime.now().date()
            
            # 获取所有活跃的虚拟机
            active_vms = VirtualMachine.query.filter(
                VirtualMachine.status.in_(['running', 'stopped'])
            ).all()
            
            logger.info(f"Processing billing for {len(active_vms)} active VMs")
            
            processed_count = 0
            skipped_count = 0
            
            for vm in active_vms:
                try:
                    # 检查今天是否已经计费
                    existing_record = BillingRecord.query.filter_by(
                        vm_id=vm.id,
                        billing_date=today
                    ).first()
                    
                    if existing_record:
                        skipped_count += 1
                        continue
                    
                    # 计算费用
                    costs = billing_manager.calculate_daily_cost(vm)
                    
                    # 创建计费记录
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
                    processed_count += 1
                    
                    logger.debug(f"Created billing record for VM {vm.name}: ¥{costs['total_cost']:.2f}")
                    
                except Exception as e:
                    logger.error(f"Error processing billing for VM {vm.id}: {str(e)}")
                    continue
            
            try:
                db.session.commit()
                logger.info(f"Daily billing completed: {processed_count} records created, {skipped_count} skipped")
            except Exception as e:
                db.session.rollback()
                logger.error(f"Error committing billing records: {str(e)}")
            
            logger.info("=== Daily billing completed ===")
            
    except Exception as e:
        logger.error(f"Error in run_daily_billing: {str(e)}")

def sync_vm_status():
    """同步虚拟机状态"""
    logger.info("=== Starting VM status sync ===")
    
    if not vmware_manager:
        logger.warning("VMware manager not available, skipping status sync")
        return
    
    try:
        with app.app_context():
            vms = VirtualMachine.query.filter(
                VirtualMachine.vcenter_uuid.isnot(None),
                VirtualMachine.status.in_(['running', 'stopped'])
            ).all()
            
            logger.info(f"Syncing status for {len(vms)} VMs")
            
            updated_count = 0
            
            for vm in vms:
                try:
                    vm_obj = vmware_manager.get_vm_by_uuid(vm.vcenter_uuid)
                    if vm_obj:
                        power_state = str(vm_obj.runtime.powerState)
                        new_status = 'running' if power_state == 'poweredOn' else 'stopped'
                        
                        if vm.status != new_status:
                            old_status = vm.status
                            vm.status = new_status
                            vm.updated_at = datetime.utcnow()
                            updated_count += 1
                            logger.info(f"Updated VM {vm.name} status: {old_status} -> {new_status}")
                except Exception as e:
                    logger.error(f"Failed to sync status for VM {vm.name}: {str(e)}")
                    continue
            
            try:
                db.session.commit()
                logger.info(f"VM status sync completed: {updated_count} VMs updated")
            except Exception as e:
                db.session.rollback()
                logger.error(f"Failed to commit status updates: {str(e)}")
            
            logger.info("=== VM status sync completed ===")
            
    except Exception as e:
        logger.error(f"Error in sync_vm_status: {str(e)}")

def cleanup_old_sessions():
    """清理过期的用户会话"""
    logger.info("=== Starting session cleanup ===")
    
    try:
        with app.app_context():
            from app import UserSession
            
            now = datetime.utcnow()
            expired_sessions = UserSession.query.filter(
                UserSession.expires_at < now
            ).all()
            
            count = len(expired_sessions)
            
            for session in expired_sessions:
                db.session.delete(session)
            
            db.session.commit()
            logger.info(f"Cleaned up {count} expired sessions")
            
            logger.info("=== Session cleanup completed ===")
            
    except Exception as e:
        logger.error(f"Error in cleanup_old_sessions: {str(e)}")

def health_check():
    """调度器健康检查"""
    logger.info("Scheduler health check - OK")

def main():
    """主函数 - 设置定时任务"""
    logger.info("Starting VMware IaaS Scheduler...")
    
    # 每天凌晨2点检查过期虚拟机
    schedule.every().day.at("02:00").do(check_expired_vms)
    
    # 每天凌晨3点运行计费任务
    schedule.every().day.at("03:00").do(run_daily_billing)
    
    # 每5分钟同步虚拟机状态
    schedule.every(5).minutes.do(sync_vm_status)
    
    # 每小时清理过期会话
    schedule.every().hour.do(cleanup_old_sessions)
    
    # 每10分钟进行健康检查
    schedule.every(10).minutes.do(health_check)
    
    logger.info("Scheduler configured with following jobs:")
    for job in schedule.jobs:
        logger.info(f"  - {job}")
    
    # 初始运行一次状态同步
    logger.info("Running initial VM status sync...")
    sync_vm_status()
    
    # 主循环
    logger.info("Scheduler started successfully")
    
    while True:
        try:
            schedule.run_pending()
            time.sleep(30)  # 每30秒检查一次
        except KeyboardInterrupt:
            logger.info("Scheduler stopped by user")
            break
        except Exception as e:
            logger.error(f"Error in scheduler main loop: {str(e)}")
            time.sleep(60)  # 出错后等待1分钟再继续

if __name__ == '__main__':
    main()
