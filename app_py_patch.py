# 替换 app.py 中的问题代码片段

import re

def fix_app_py():
    """修复 app.py 中的 SQLAlchemy 语法问题"""
    
    with open('app.py', 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 1. 修复健康检查中的 SQL 语句
    old_health_check = r"db\.session\.execute\('SELECT 1'\)"
    new_health_check = r"db.session.execute(text('SELECT 1'))"
    
    if old_health_check in content:
        content = re.sub(old_health_check, new_health_check, content)
        print("✅ 修复了健康检查中的 SQL 语句")
    
    # 2. 在文件开头添加 text 导入
    import_line = "from sqlalchemy import text"
    if import_line not in content:
        # 在 Flask 导入之后添加 SQLAlchemy 导入
        flask_import_pattern = r"(from flask import [^\n]+\n)"
        replacement = r"\1from sqlalchemy import text\n"
        content = re.sub(flask_import_pattern, replacement, content)
        print("✅ 添加了 SQLAlchemy text 导入")
    
    # 3. 修复其他可能的 SQL 语句
    other_sql_patterns = [
        (r"db\.session\.execute\('([^']+)'\)", r"db.session.execute(text('\1'))"),
        (r'db\.session\.execute\("([^"]+)"\)', r'db.session.execute(text("\1"))'),
    ]
    
    for pattern, replacement in other_sql_patterns:
        if re.search(pattern, content):
            content = re.sub(pattern, replacement, content)
            print(f"✅ 修复了 SQL 语句: {pattern}")
    
    # 写回文件
    with open('app.py', 'w', encoding='utf-8') as f:
        f.write(content)
    
    print("✅ app.py 修复完成")

if __name__ == '__main__':
    fix_app_py()
