#!/bin/bash

echo "VMware IaaS 环境变量配置向导"
echo "=============================="

read -p "请输入LDAP服务器地址 (如: ldap://ldap.company.com:389): " ldap_server
read -p "请输入LDAP Base DN (如: dc=company,dc=com): " ldap_base_dn
read -p "请输入vCenter服务器地址 (如: vcenter.company.com): " vcenter_host
read -p "请输入vCenter用户名 (如: administrator@vsphere.local): " vcenter_user
read -s -p "请输入vCenter密码: " vcenter_password
echo ""

# 更新配置文件
sed -i "s|LDAP_SERVER=.*|LDAP_SERVER=$ldap_server|" .env
sed -i "s|LDAP_BASE_DN=.*|LDAP_BASE_DN=$ldap_base_dn|" .env
sed -i "s|VCENTER_HOST=.*|VCENTER_HOST=$vcenter_host|" .env
sed -i "s|VCENTER_USER=.*|VCENTER_USER=$vcenter_user|" .env
sed -i "s|VCENTER_PASSWORD=.*|VCENTER_PASSWORD=$vcenter_password|" .env

echo "✅ 配置已更新到 .env 文件"
echo "🚀 现在可以运行: ./deploy-complete.sh"
