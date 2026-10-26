# Blackout / 黑屏低亮度

适用于 Apple Silicon Mac 的菜单栏工具：在每块显示器上覆盖纯黑窗口，尽可能将内建屏幕与支持 DDC/CI 的外接显示器调至低亮度，并在运行期间请求系统保持显示器唤醒。它不会向显示器发送关机或待机命令。

A menu bar utility for Apple Silicon Macs. It covers every display with a black window, dims supported displays, and requests that macOS keep the displays awake while active. It does not power off the displays.

## 下载与安装 / Download and install

从 [GitHub Releases](https://github.com/byeval/blackout-menubar/releases) 下载 `Blackout-v*-macos-arm64.zip`，解压后将 `Blackout.app` 放入“应用程序”文件夹并打开。要求 Apple Silicon 与 macOS 13 或更新版本。首次使用建议先确认下方的恢复方式。

Download the ZIP from [GitHub Releases](https://github.com/byeval/blackout-menubar/releases), extract `Blackout.app`, move it to Applications, and open it. Requires Apple Silicon and macOS 13 or later. Read the recovery steps below before first use.

**签名说明 / Signing:** 当前 Release 使用 ad hoc 签名，**未经过 Apple 公证**。从网络下载时，macOS 可能阻止打开；请先核对来源，并按 Apple 的[“打开来自身份不明开发者的 App”说明](https://support.apple.com/zh-cn/102445)在“隐私与安全性”中决定是否允许。也可以从源码自行构建。不要关闭系统安全保护。

The release is ad hoc signed and **not notarized**. Gatekeeper may block a downloaded copy. Verify its source and use Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445) if you choose to run it, or build from source. Do not disable system security protections.

## 使用 / Use

- 点击菜单栏月亮图标，直接拖动每块显示器的亮度滑杆（1–100%）。更改立即发送到对应显示器，不需要进入黑屏。快速拖动会合并尚未执行的请求，避免积压。
- 每块屏幕显示硬件实际读数。写入后会读回确认，状态显示“已确认”；失败或无法读回时会明确提示，不将目标数字当作成功结果。打开菜单或点击“重新读取亮度”可更新读数。
- “黑屏目标亮度”单独设置为 1%、5%、10% 或 20%，仅下次进入黑屏时使用，不改变日常亮度。所有显示器使用同一黑屏目标值。
- 选择“进入黑屏低亮度”后覆盖所有屏幕，并尽可能降低硬件亮度。点击任一黑屏、按任意普通按键，或按 `Control-Option-Command-B` 可恢复进入前的各屏亮度；此组合键也可进入黑屏。
- 无法读取硬件亮度的屏幕会禁用滑杆，但仍可使用黑屏遮罩。当前版本不提供日常软件调暗。
- 普通亮度调整会保留；退出或从黑屏恢复只撤销黑屏期间的调暗，不撤销之前的日常调整。

Open the moon menu and drag each display's brightness slider (1–100%). Changes apply immediately and are confirmed by hardware readback. Blackout brightness is a separate preset used only when entering blackout. Click a black screen or press Control-Option-Command-B to restore the pre-blackout brightness of every display. Unsupported hardware controls are disabled; the black overlay still works. Ordinary brightness changes remain in effect when quitting.

需要远程启动黑屏时，先退出已有 Blackout，再运行 `open /Applications/Blackout.app --args --start-blackout`（若安装在用户目录，请改用对应路径）。恢复方式不变。App 和恢复命令共用进程锁，避免两份程序同时控制屏幕或覆盖恢复记录。

To enter blackout on launch, quit any existing copy, then run `open /Applications/Blackout.app --args --start-blackout` (adjust the path if needed).

## 构建 / Build

安装 Xcode 后，在 Apple Silicon Mac 上运行：

```sh
./build.sh
open build/Blackout.app
```

`./package.sh` 会生成 `dist/Blackout-v<version>-macos-arm64.zip` 和 `dist/SHA256SUMS`。构建脚本每次重新编译随附的 DDC 辅助程序，以确保 macOS 最低版本设置一致。无需运行 `sudo`。

With Xcode installed on an Apple Silicon Mac, run the commands above. `./package.sh` creates the ZIP and SHA-256 manifest in `dist/`. No `sudo` is needed.

## 恢复与诊断 / Recovery and diagnostics

程序正常退出或收到终止信号时会先尝试恢复。异常退出后再次启动，也会尝试恢复保存的亮度。恢复使用显示器 UUID 识别屏幕；重新连接后即使数字 ID 改变，也可匹配原屏幕。1.0 的旧记录仍可读取，但只能按旧数字 ID 恢复。

每块屏幕只有在读回确认成功后才从恢复记录中移除；未连接或恢复失败的屏幕会继续保留。存在未完成的记录时，会阻止新黑屏和日常调光，避免覆盖原值。连接恢复或系统唤醒后会重试，菜单也提供“重试恢复未完成的屏幕”。损坏的记录不会被静默删除或覆盖。

若需手动恢复，先退出 Blackout，再运行：

```sh
/Applications/Blackout.app/Contents/MacOS/Blackout --restore
```

`--diagnose` 只读取硬件亮度与显示器标识，不会黑屏或更改亮度，可在 App 运行时使用。`--verify-brightness` 是显式硬件检查：需要先退出 App；保存当前各屏亮度，短暂调整约 5 个百分点，读回确认，再恢复并确认。检查中断后可用 `--restore` 恢复。

恢复记录：`~/Library/Application Support/BlackoutMenubar/brightness.json`。屏幕未连接时保留该文件，连接后重试。新版本会迁移本机旧版 `local.xuhong.blackout` 的黑屏目标设置。

Recovery snapshots use stable display UUIDs. Successfully verified displays are removed individually; disconnected or failed displays remain pending. Relaunching, reconnecting, or waking retries recovery. An unresolved or corrupt journal blocks new brightness writes and blackout sessions. Quit the app before CLI recovery or the explicit `--verify-brightness` hardware check. Read-only `--diagnose` is safe while the app is running.

### 本地检查 / Local checks

`swift test` 使用临时目录与模拟读回检查恢复逻辑，不会调整真实显示器。真实硬件检查使用上面的显式命令。自动化通过不等于滑杆交互、黑屏覆盖和肉眼亮度效果已通过实机验收。

## 工作边界 / Limitations

- 外接显示器必须支持并启用 DDC/CI，且连接链路必须传递 DDC 信号，硬件亮度调节才可用。黑色遮罩仍会覆盖不支持调光的显示器。液晶屏背光保持开启时可能有漏光。
- “硬件亮度已确认”仅表示亮度数值已读回，不表示显示器自己的提示已被确认。Dell U2720QM 超过默认亮度时可能出现功耗确认提示；本版本不支持读取或自动确认该提示，需要使用显示器实体按键处理。
- 内建屏幕使用 macOS 私有 DisplayServices 接口；外接 DDC 调节使用私有 IOAVService 通道。系统更新可能使其失效。
- 保持显示器唤醒的请求不等于阻止系统睡眠；合盖、锁屏或系统电源策略可能改变显示状态。

External brightness control needs DDC/CI enabled and a connection that carries DDC. LCD backlights may still leak light. The brightness paths use private macOS interfaces and may break after an OS update. The display sleep assertion does not prevent all forms of system sleep.

The bundled DDC helper is a snapshot of [waydabber/m1ddc](https://github.com/waydabber/m1ddc); see [third-party notices](THIRD_PARTY_NOTICES.md) and its [MIT license](Vendor/m1ddc/LICENSE).
