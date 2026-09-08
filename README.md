> **草稿实验分支：Fn 触发与 2026-09-08 实机修复参考。**
> 本分支使用 Fn，并改变应用标识与剪贴板恢复行为；“偶尔粘贴旧内容”仍未解决。
> 请使用 `zsh scripts/build-fn-app.sh` 构建，先阅读 [Fn 分支说明](FN-VARIANT.md) 和 [实机问题记录](docs/2026-09-08-fn-field-report.md)。
> 下方保留上游左 Control 版本的原始说明作为背景，不能直接作为本实验分支的使用说明。

# DoubaoVoiceBridge（远控听写）

一个轻量的 macOS 菜单栏工具：在 MacBook 上按住左 `Control` 使用豆包语音输入法听写，松开后自动把文字通过 UU 远控粘贴到远端 Mac 的当前输入框。

> 本项目是非官方的个人自动化工具，与豆包、字节跳动、UU 远控或网易没有隶属、合作或授权关系。相关名称与商标归各自权利人所有。

## 使用方式

确保 UU 远控窗口处于前台，然后：

1. 按住左 `Control`（左 `⌃`）。
2. 在弹出的听写框中说话。
3. 松开左 `Control`。
4. 工具等待豆包语音输入法完成识别，然后通过 UU 剪贴板同步并在远端 Mac 当前输入框自动粘贴。

为了保留常用快捷键，只有 UU 远控处于前台且左 `Control` 持续按住超过阈值时才进入听写。快速使用 `Control-C` 等组合键仍保持原行为。

## 运行要求

- macOS 13 或更高版本
- Intel 或 Apple Silicon Mac
- 已安装并启用豆包语音输入法，语音快捷键设为左 `Control`
- 已安装 UU 远控，且 MacBook 与远端 Mac 可以正常连接和同步剪贴板
- 辅助功能与输入监控权限

当前实现通过 Bundle ID `com.netease.uuremote` 识别 UU 远控。如果相关应用更改 Bundle ID、快捷键或输入行为，项目可能需要同步调整。

## 从源码构建

需要 Xcode Command Line Tools 和 Swift 5.9 或更高版本。

```bash
git clone https://github.com/yupeng316888-create/DoubaoVoiceBridge.git
cd DoubaoVoiceBridge
./scripts/build-app.sh
open dist
```

构建脚本会生成通用二进制，并对本地生成的 `dist/远控听写.app` 做 ad-hoc 签名。把应用拖到你希望的位置后启动即可。该构建没有 Apple Developer ID 签名，也未经过公证。

首次启动时，请在“系统设置 → 隐私与安全性”中为“远控听写”开启：

- 辅助功能
- 输入监控

麦克风权限只需要授予豆包语音输入法，本工具本身不录音。

## 工作原理与安全边界

- 只在 UU 远控是当前前台应用时接管长按左 `Control`。
- 在本机显示一个临时文本框，让豆包语音输入法把识别结果写入其中。
- 松开按键后等待输入法提交最终文字，再把文字暂存到系统剪贴板。
- 自动粘贴前重新确认同一个 UU 进程和同一个原聚焦窗口；焦点变化时取消操作。
- 明确发送完整的 `Command` 按下、`V` 按下、`V` 松开和 `Command` 松开事件序列，避免远端只收到字母 `V`。
- 粘贴完成后，仅在剪贴板未被其他程序改动时恢复原内容。

本工具不调用豆包账号或语音服务，不保存听写正文，也不包含网络请求。网络传输与剪贴板同步由豆包语音输入法和 UU 远控各自完成。

## 测试与诊断

构建脚本会自动运行内置自检和诊断。也可以单独执行：

```bash
swift run DoubaoVoiceBridge --self-test
swift run DoubaoVoiceBridge --diagnostics
```

当前内置自检覆盖长按判定、识别文本稳定等待、延迟配置迁移、UU 同步安全下限和听写框布局。

## License

[MIT](LICENSE)
