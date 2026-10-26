# Blackout 1.1.0

- 菜单栏新增每屏实时亮度滑杆，显示实际硬件读数与调光确认结果。
- 黑屏目标亮度独立设置，不再与普通亮度调整混淆。
- 写入及恢复后读回确认；恢复记录按显示器 UUID 匹配，逐屏清除成功项，保留失败项。
- 增加快速拖动合并、硬件调用超时、进程互斥与终止信号恢复，避免旧请求覆盖恢复后的亮度。
- 兼容 1.0 恢复记录，迁移旧本地安装的黑屏目标设置。
- 亮度确认指硬件数值读回；Dell 显示器自身的功耗提示仍需通过实体按键确认，本版不提供自动确认。

Apple Silicon / macOS 13+。本地构建使用 ad hoc 签名，未公证。本次更新不包含软件调暗、HDR 增亮或虚拟屏幕功能。

下载 `Blackout-v1.1.0-macos-arm64.zip`，并用 `SHA256SUMS` 校验。macOS 可能阻止打开下载的 App，请核对来源后参照 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)，或从源码构建。

# Blackout 1.0.1

Apple Silicon Mac 菜单栏黑屏低亮度工具。开启后覆盖所有显示器，并尽可能调低内建屏幕及支持 DDC/CI 的外接显示器亮度；点击黑屏或按 Control-Option-Command-B 可恢复。

新增 `--start-blackout` 启动参数，便于通过远程终端直接进入黑屏模式。Download `Blackout-v1.0.1-macos-arm64.zip` for Apple Silicon Macs running macOS 13 or later. Verify it with `SHA256SUMS`.

**Signing / 签名：** 此版本使用 ad hoc 签名，尚未经过 Apple 公证。macOS 可能阻止直接打开网络下载的 App；请先检查来源，再参照 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)决定是否允许，或从源码构建。使用前请阅读 [恢复说明](https://github.com/byeval/blackout-menubar#恢复与诊断--recovery-and-diagnostics)。

This release is ad hoc signed and not notarized. Gatekeeper may block a downloaded copy. Review the source and follow [Apple's instructions](https://support.apple.com/en-us/102445) if you choose to open it, or build from source. Read the recovery steps in the README before first use.
