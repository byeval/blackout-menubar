# Blackout / 黑屏低亮度

适用于 Apple Silicon Mac 的菜单栏工具：在每块显示器上覆盖纯黑窗口，尽可能将内建屏幕与支持 DDC/CI 的外接显示器调至低亮度，并在运行期间请求系统保持显示器唤醒。它不会向显示器发送关机或待机命令。

A menu bar utility for Apple Silicon Macs. It covers every display with a black window, dims supported displays, and requests that macOS keep the displays awake while active. It does not power off the displays.

## 下载与安装 / Download and install

从 [GitHub Releases](https://github.com/byeval/blackout-menubar/releases) 下载 `Blackout-v*-macos-arm64.zip`，解压后将 `Blackout.app` 放入“应用程序”文件夹并打开。要求 Apple Silicon 与 macOS 13 或更新版本。首次使用建议先确认下方的恢复方式。

Download the ZIP from [GitHub Releases](https://github.com/byeval/blackout-menubar/releases), extract `Blackout.app`, move it to Applications, and open it. Requires Apple Silicon and macOS 13 or later. Read the recovery steps below before first use.

**签名说明 / Signing:** 当前 Release 使用 ad hoc 签名，**未经过 Apple 公证**。从网络下载时，macOS 可能阻止打开；请先核对来源，并按 Apple 的[“打开来自身份不明开发者的 App”说明](https://support.apple.com/zh-cn/102445)在“隐私与安全性”中决定是否允许。也可以从源码自行构建。不要关闭系统安全保护。

The release is ad hoc signed and **not notarized**. Gatekeeper may block a downloaded copy. Verify its source and use Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445) if you choose to run it, or build from source. Do not disable system security protections.

## 使用 / Use

- 点击菜单栏月亮图标，选择“进入黑屏低亮度”。
- 点击任一黑屏，或按 `Control-Option-Command-B`，即可关闭遮罩并恢复进入前记录的亮度。菜单里也有“恢复显示”和“退出”。
- 菜单中可选 1%、5% 或 10% 的目标亮度，默认 5%。
- 如果显示器无法通过硬件接口读取亮度，程序仍会显示黑色遮罩，并在菜单中提示硬件调光不可用。

Click the moon in the menu bar and select “进入黑屏低亮度” to enter blackout. Click any black screen or press `Control-Option-Command-B` to restore. The menu also offers Restore and Quit. Choose 1%, 5%, or 10% brightness (5% by default). Displays without working hardware brightness control are still covered by the black overlay.

需要远程启动黑屏时，可先退出已有的 Blackout 进程，再运行 `open /Applications/Blackout.app --args --start-blackout`（若安装在用户目录，请改用对应路径）。此参数只在启动新进程时生效；恢复方式不变。

To enter blackout on launch, quit any existing Blackout process, then run `open /Applications/Blackout.app --args --start-blackout` (adjust the path if needed). The argument applies only when a new process starts. Restore by clicking the black screen or using the hotkey.

## 构建 / Build

安装 Xcode 后，在 Apple Silicon Mac 上运行：

```sh
./build.sh
open build/Blackout.app
```

`./package.sh` 会生成 `dist/Blackout-v<version>-macos-arm64.zip` 和 `dist/SHA256SUMS`。构建脚本每次重新编译随附的 DDC 辅助程序，以确保 macOS 最低版本设置一致。无需运行 `sudo`。

With Xcode installed on an Apple Silicon Mac, run the commands above. `./package.sh` creates the ZIP and SHA-256 manifest in `dist/`. No `sudo` is needed.

## 恢复与诊断 / Recovery and diagnostics

程序异常退出后再次启动，会尝试恢复保存的亮度。如果没有自动恢复，请在终端运行：

```sh
/Applications/Blackout.app/Contents/MacOS/Blackout --restore
```

如果 App 位于其他位置，请相应修改路径。`--diagnose` 只读取当前可用的硬件亮度和显示器 ID，不会进入黑屏或更改亮度。亮度快照位于 `~/Library/Application Support/BlackoutMenubar/brightness.json`；若显示器暂时断开，保留该文件，重新连接后再运行 `--restore`。

After an unexpected exit, relaunching attempts to restore the saved brightness. Run the command above to retry manually (adjust the app path if needed). `--diagnose` only reads available display brightness values and IDs. If a display is disconnected, reconnect it before retrying `--restore`; the snapshot remains in the Application Support path above until restoration succeeds.

## 工作边界 / Limitations

- 外接显示器必须支持并启用 DDC/CI，且连接链路必须传递 DDC 信号，硬件亮度调节才可用。黑色遮罩仍会覆盖不支持调光的显示器。液晶屏背光保持开启时可能有漏光。
- 内建屏幕使用 macOS 私有 DisplayServices 接口；外接 DDC 调节使用私有 IOAVService 通道。系统更新可能使其失效。
- 保持显示器唤醒的请求不等于阻止系统睡眠；合盖、锁屏或系统电源策略可能改变显示状态。

External brightness control needs DDC/CI enabled and a connection that carries DDC. LCD backlights may still leak light. The brightness paths use private macOS interfaces and may break after an OS update. The display sleep assertion does not prevent all forms of system sleep.

The bundled DDC helper is a snapshot of [waydabber/m1ddc](https://github.com/waydabber/m1ddc); see [third-party notices](THIRD_PARTY_NOTICES.md) and its [MIT license](Vendor/m1ddc/LICENSE).
