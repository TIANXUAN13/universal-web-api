#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
依赖完整性检测脚本
退出码: 0=完整, 1=缺失
"""

import sys
import platform
import re
from pathlib import Path


def _marker_matches(marker: str) -> bool:
    """最小化支持 requirements 环境标记（当前覆盖 platform_system）"""
    marker = marker.strip()
    if not marker:
        return True

    current_system = platform.system()

    m_eq = re.search(r"platform_system\s*==\s*['\"]([^'\"]+)['\"]", marker)
    if m_eq:
        return current_system == m_eq.group(1)

    m_ne = re.search(r"platform_system\s*!=\s*['\"]([^'\"]+)['\"]", marker)
    if m_ne:
        return current_system != m_ne.group(1)

    # 未识别标记时保守处理：不跳过，避免漏检
    return True


def check_dependencies():
    """检测 requirements.txt 中的包是否都已安装"""
    
    req_file = Path(__file__).parent / "requirements.txt"
    if not req_file.exists():
        print("[ERROR] requirements.txt not found")
        return False
    
    # 读取并解析 requirements.txt
    packages = []
    for line in req_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        # 跳过空行和注释
        if not line or line.startswith("#"):
            continue

        # 处理环境标记，例如: pywin32; platform_system == "Windows"
        if ";" in line:
            requirement_part, marker_part = line.split(";", 1)
            if not _marker_matches(marker_part):
                continue
            line = requirement_part.strip()
            if not line:
                continue

        # 提取包名（去掉版本约束）
        pkg_name = line.split(">=")[0].split("<=")[0].split("<")[0].split(">")[0].split("==")[0].split("[")[0].strip()
        if pkg_name:
            packages.append(pkg_name)
    
    # 包名到实际模块名的映射（处理特殊情况）
    # 键：requirements.txt 中的包名（小写）
    # 值：实际 import 时用的模块名
    name_mapping = {
        "pillow": "PIL",
        "beautifulsoup4": "bs4",
        "python-dotenv": "dotenv",
        "pywin32": "win32api",
        "pyyaml": "yaml",
        "drissionpage": "DrissionPage",  # 保持大小写
    }
    
    missing = []
    for pkg in packages:
        pkg_lower = pkg.lower()
        
        # 优先使用映射表
        if pkg_lower in name_mapping:
            module_name = name_mapping[pkg_lower]
        else:
            # 默认：小写并替换连字符
            module_name = pkg_lower.replace("-", "_")
        
        try:
            __import__(module_name)
        except ImportError:
            missing.append(pkg)
    
    if missing:
        print(f"[WARN] Missing packages: {', '.join(missing)}")
        return False
    
    return True


if __name__ == "__main__":
    if check_dependencies():
        sys.exit(0)
    else:
        sys.exit(1)
