# Blackout 1.0.1

Apple Silicon Mac 菜单栏黑屏低亮度工具。开启后覆盖所有显示器，并尽可能调低内建屏幕及支持 DDC/CI 的外接显示器亮度；点击黑屏或按 Control-Option-Command-B 可恢复。

新增 `--start-blackout` 启动参数，便于通过远程终端直接进入黑屏模式。Download `Blackout-v1.0.1-macos-arm64.zip` for Apple Silicon Macs running macOS 13 or later. Verify it with `SHA256SUMS`.

**Signing / 签名：** 此版本使用 ad hoc 签名，尚未经过 Apple 公证。macOS 可能阻止直接打开网络下载的 App；请先检查来源，再参照 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)决定是否允许，或从源码构建。使用前请阅读 [恢复说明](https://github.com/byeval/blackout-menubar#恢复与诊断--recovery-and-diagnostics)。

This release is ad hoc signed and not notarized. Gatekeeper may block a downloaded copy. Review the source and follow [Apple's instructions](https://support.apple.com/en-us/102445) if you choose to open it, or build from source. Read the recovery steps in the README before first use.
