# dmgbuild 配置：定制拖拽式安装窗口（不依赖 Finder AppleScript 权限，直接写 .DS_Store）。
# 用法：PYTHONPATH=build/py python3 -m dmgbuild -D root=<项目根目录> -s scripts/dmg-settings.py DitKit build/DitKit.dmg
# dmgbuild 用 exec 加载本文件，没有 __file__，项目根目录由 -D root=... 传入。
import os

ROOT = defines.get("root") or os.getcwd()
BUILD = os.path.join(ROOT, "build")

volume_name = "DitKit"
format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [os.path.join(BUILD, "DitKit.app")]
symlinks = {"Applications": "/Applications"}
# HiDPI 合成后卷根是 .background.tiff（没有 2x 图时是 .background.png），
# 必须显式设 invisible，否则开启了「显示隐藏文件」的 Mac 上会多出一个背景文件图标。
_hidpi = os.path.isfile(os.path.join(BUILD, "background-dmg@2x.png"))
hide = [".background.tiff" if _hidpi else ".background.png"]

# dmgbuild 会自动查找同目录的 background-dmg@2x.png 合成 HiDPI TIFF。
background = os.path.join(BUILD, "background-dmg.png")

# 窗口 660×400 点，与背景图 660×400 像素 / 1320×800@2x 对应。
window_rect = ((100, 100), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 14
label_pos = "bottom"
arrange_by = None

icon_locations = {
    "DitKit.app": (180, 200),
    "Applications": (480, 200),
}

show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = True
