# UU 远控语音直输

在本机使用豆包语音输入法，让识别文字直接进入 UU 远控中的另一台 Mac。**当前公开版本：v1.0.0。**

- 跟随本机豆包设置的长按与免按快捷键，支持 Fn / Ctrl，支持连续听写。
- 支持实时更新的输入框会边说边显示；Qoder CN 等已知不兼容输入框采用结束后整句字符输入。
- 不使用剪贴板粘贴；配对后通过加密文字通道传输。
- 正常听写隐藏工具窗口；支持接收端登录自启和可选的 UU 映射自动恢复。

## 下载和安装

前往 [Releases](https://github.com/yin666888/uu-remote-dictation/releases/latest) 下载 `remote-dictation-v1.0.0.zip`。包内含发送端、接收端、中文安装说明、可选 Codex Skill 及校验文件。Skill 也可单独下载。

完整步骤见 [安装说明](docs/安装说明.md)。首次需要配置自己的端口、生成新的配对码，并按系统提示完成权限授权。程序没有预设发布者的设备、端口或配对码。

**使用条件：** 两台 macOS 13 或以上的 Mac（Apple Silicon / Intel）；本机安装豆包语音输入法，两端使用支持 TCP 端口映射的 UU 远程。当前版本不支持 Windows 控制端或接收端。接收端不需要安装豆包。

程序采用本地临时签名，未做 Apple 开发者公证。首次打开可能需要在系统“隐私与安全性”中确认，无需关闭系统安全保护。UU 和豆包需自行安装，本仓库不分发它们的软件。

## 工作原理

本机真实文本客户端接收豆包的中间识别文字与最终文字，经 AES-GCM 配对通道及 UU 的 TCP 映射发送到远端。接收端通过 macOS 辅助功能接口更新本轮文字范围；已知不兼容的输入框使用最终 Unicode 字符输入。接收端仅监听回环地址。

本工具不采集音频，语音识别由本机豆包完成。网络通道传输识别文字；两端配对密钥由各自系统钥匙串保存。同局域网与异地均使用 UU 通道，连通性取决于 UU 版本及网络。

## 从源码构建

安装 Apple Command Line Tools 和 Swift 5.9 或以上，在仓库根目录运行：

```sh
zsh scripts/build-app.sh
```

脚本生成 `dist/远控听写.app` 和 `dist/远控直输接收端.app`，包含 arm64 与 x86_64 架构，并验证签名及运行 26 组自检。

```sh
"dist/远控听写.app/Contents/MacOS/DoubaoVoiceBridge" --self-test
python3 scripts/package-release.py
```

第二条命令从明确的发布文件清单生成分享包、独立 Skill 包和校验清单，输出到 `dist/release/`。`packaging/skill/` 是 Skill 模板；发布时自动补齐程序和源码，不包含本机配置。

## 限制与排查

实时输入取决于目标应用的辅助功能支持，并非所有输入框都可实时更新。听写中切换窗口、移动光标或编辑原文可能取消本轮；断线后检查草稿再重试。UU 自动映射适配已在中文 UU 4.45.0 验证，豆包设置格式或 UU 界面变更可能需要更新。

参见 [故障定位](packaging/skill/references/troubleshooting.md)、[自动启动与映射](packaging/skill/references/automation.md)、[实现约束](packaging/skill/references/architecture.md)。提交 Issue 时请先移除密码、配对码、真实端口、设备标识、网络地址和听写正文。

## 许可与来源

采用 [MIT License](LICENSE)。基于 [DoubaoVoiceBridge](https://github.com/yupeng316888-create/DoubaoVoiceBridge) 的开发成果继续适配，保留原作者版权声明。v1.0.0 是本仓库的首个公开发行版本。

这是非官方社区工具，与豆包/字节跳动、UU/网易没有隶属或背书关系；第三方软件及服务仍遵循其各自条款。
