#!/usr/bin/env python3
"""Package OneClickGrade.lrplugin into a distributable zip.

Usage: python pack.py [version]
Default version is read from Info.lua when omitted.
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_DIR = os.path.join(ROOT, "OneClickGrade.lrplugin")

INSTALL = """一键调色 Lightroom Classic 插件 {version}

安装
1. 关闭 Lightroom Classic。
2. 把 OneClickGrade.lrplugin 整个文件夹复制到：
   Windows: C:\\Users\\<用户名>\\AppData\\Roaming\\Adobe\\Lightroom\\Modules\\
   macOS:   ~/Library/Application Support/Adobe/Lightroom/Modules/
3. 启动 Lightroom，菜单「文件 > 增效工具额外功能」里会出现「一键调色」。

使用
选中一张或多张照片，执行「一键调色」。设置与诊断在「一键调色·设置…」「一键调色·诊断…」。
视频文件会被自动跳过。

详细说明见 README.md。
"""


def read_version():
    with open(os.path.join(PLUGIN_DIR, "Info.lua"), encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"VERSION\s*=\s*\{\s*major\s*=\s*(\d+),\s*minor\s*=\s*(\d+),\s*revision\s*=\s*(\d+)", text)
    if not match:
        raise SystemExit("VERSION not found in Info.lua")
    return ".".join(match.groups())


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else read_version()
    out = os.path.join(ROOT, "OneClickGrade-%s.zip" % version)
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in sorted(os.listdir(PLUGIN_DIR)):
            if name.endswith(".lua"):
                zf.write(os.path.join(PLUGIN_DIR, name), "OneClickGrade.lrplugin/" + name)
                count += 1
        zf.writestr("INSTALL.txt", INSTALL.format(version=version))
    print("wrote %s (version %s, %d lua files, %d bytes)" % (out, version, count, os.path.getsize(out)))


if __name__ == "__main__":
    main()
