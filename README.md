# DitKit

macOS 磁盘工具集：**Go 后端 + SwiftUI 前端**，四个标签页。

| 标签页 | 功能 |
| --- | --- |
| SMART 健康 | 中文化 SMART 报告，磁盘列表常驻 |
| 实时 IO | IOKit 直读计数器，0.5 秒采样、固定 10 分钟窗口的读写双曲线 |
| 测速 | 顺序读写，1 / 10 / 100 GiB，绕页缓存，单位 MiB/秒 |
| 重命名 | 读取 EXIF 拍摄时间，按 `年月日_时分秒_毫秒三位_自定义.ext` 批量原地改名 |

## 目录结构

```
cmd/ditkitd/            Go 后端入口
internal/api/           HTTP API、Bearer token、runtime.json
internal/smart/         smartctl 扫描、字段中文化、报告渲染
macos/Package.swift     SwiftPM 清单（DitKit / DitKitCore / DitKitTests）
macos/Sources/DitKit/       SwiftUI 应用与四个页面
macos/Sources/DitKitCore/   API、Daemon、IO、SpeedTest、Rename、Models
macos/Tests/            单元测试
macos/Resources/        AppIcon.icns
scripts/                构建、打包、DMG 背景图生成
testdata/               smartctl 真实 JSON 样本
docs/                   界面截图、背景图预览
build/                  所有构建产物（已 gitignore，不分层）
```

## 环境要求

- macOS 14+、Xcode / Swift（SwiftPM 需 `--disable-sandbox`）、Go 1.27+
- 构建机需 `smartctl`：`brew install smartmontools`（仅构建时复制进 bundle，最终用户无需安装）
- 首次打包会联网把 `dmgbuild` 装到 `build/py`，之后离线可复用

## 快速开始

```bash
make            # 完整构建 = make dmg
make app        # 只生成 build/DitKit.app 与 build/ditkitd
make dmg        # 生成 build/DitKit-0.2.1.dmg
make test       # go test ./... + swift test --disable-sandbox
make clean      # 删除 build/ 内的产物与中间文件
make distclean  # 再删除 macos/.build 与 build/py 缓存

open build/DitKit.app
./build/ditkitd -once          # 命令行直接输出中文 SMART 报告
```

脚本也可单独调用：`scripts/build-app.sh`、`scripts/make-dmg.sh`。
`build/` 不分层，最终产物为 `DitKit.app`、`ditkitd`、`DitKit-0.2.1.dmg`；中间背景图在打包成功后自动清理。

## 运行机制

- App 启动时由 `DaemonController` 拉起内嵌的 `Contents/MacOS/ditkitd -port 0`，后端把端口与 token 写入
  `~/Library/Application Support/DitKit/runtime.json`，App 退出时回收后端。
- `smartctl` 内嵌在 bundle 中（只依赖系统库）；查找顺序：`DITKIT_SMARTCTL` 环境变量 → ditkitd 同目录 → PATH。
- 前端 `APIClient` 使用无代理 `URLSession`，避免系统代理拦截 `127.0.0.1`。
- 调试参数（直接运行 `build/DitKit.app/Contents/MacOS/DitKit`）：`--io`、`--speedtest`、`--rename`。

## 注意事项

- 仅 ad-hoc 签名、未公证，首次打开需右键图标 →「打开」。
- 内嵌的 smartmontools 以 GPL-2.0 发布，许可证与源码获取说明位于
  `DitKit.app/Contents/Resources/ThirdPartyLicenses/`。
- 100 GiB 测速会临时占用约 107 GB 磁盘，运行前会检查可用空间。
