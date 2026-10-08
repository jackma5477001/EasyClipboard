# EasyClipboard

一个原生 macOS 剪贴板工具，界面遵循 [已选定的浅色设计](docs/界面设计.png)，应用图标由 AI 绘制，原图及提示词见 [图标生成说明](docs/图标生成说明.md)。需要 macOS 15.5 或更新版本，使用 SwiftUI、AppKit、Core Data，无第三方依赖。

## 使用

1. 在 Xcode 中打开 `EasyClipboard.xcodeproj`，选择 EasyClipboard / My Mac 并运行。已构建的本机应用放在 `build/EasyClipboard.app`。
2. 按 Command+C 复制文字、图片或文件，应用每 500 毫秒检查一次系统剪贴板并保存历史。
3. 在目标应用中放好光标，将鼠标移到屏幕右侧中间的小标签附近，即可展开历史，点击条目粘贴。
4. 自动粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」允许 EasyClipboard。未授权时会恢复系统剪贴板，可自行按 Command+V。

应用常驻菜单栏，关闭设置窗口不会退出。菜单提供打开历史、暂停记录、设置、授权入口、清空历史和退出。鼠标离开标签与历史面板约 300 毫秒后，面板收起；每个显示器共享同一份历史。面板宽 280 点，高度随记录数量调整，最高 480 点；记录较多时可滚动查看。

## 保存规则

- 默认保留最近 20 条，可在设置中输入任意正整数；调小上限会清理最旧记录。重复复制同一内容会更新到顶部。
- 文字以纯文本保存，图片保留 PNG/TIFF 数据。
- 每个普通文件小于 **10 MiB（10 × 1024 × 1024 字节）**时保存副本，保留原文件名。大于或等于此值的文件、文件夹和符号链接引用原位置；一次复制多个文件形成一条记录。
- 原位置失效会提示具体文件；多文件记录不会静默粘贴部分内容。小文件副本创建失败时显示状态并回退为原位置引用。
- 历史位于 `~/Library/Application Support/EasyClipboard/History.sqlite`，附件位于同目录的 `Attachments/`。删除和超限清理只处理自建附件，不删除原文件。系统剪贴板仍引用的副本会延迟到剪贴板改变后清理。
- 所有数据保存在本机。暂停期间复制的内容不会在恢复后补录。首次启动会读取一次当前支持的剪贴板内容。

粘贴遵循目标应用自己的 Command+V 行为：文字输入框不一定接受图片或文件，Finder 可接收文件。面板不会激活应用或抢走键盘焦点；展开后若切换了目标应用，则提示手动粘贴。

## 开发与测试

本机版本关闭 App Sandbox，以使用辅助功能和事件发送。直接分发所需的 Developer ID 签名、公证、商店上架及云同步不包含在第一版中。

```sh
xcodebuild -project EasyClipboard.xcodeproj -scheme EasyClipboard \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/EasyClipboard-validation \
  test CODE_SIGN_IDENTITY=-
```

单元测试使用模拟剪贴板和独立存储。UI 测试通过 `--ui-testing` 使用独立数据目录及偏好设置，不读取或修改用户的真实剪贴板。共享 Scheme 已包含全部测试目标。21 项单元测试和 3 项 UI 测试已全部通过；具体记录及实机待验证项目见 [验收记录](docs/验收记录.md)。

需要观察浮动面板时，可在独立测试数据下启动：

```sh
build/EasyClipboard.app/Contents/MacOS/EasyClipboard \
  --ui-testing --preview-panel --seed-history \
  --test-root /private/tmp/EasyClipboard-preview \
  --test-suite EasyClipboard.Preview
```

该模式仅用于检查界面，使用模拟剪贴板。测试结束后退出该进程，再正常启动应用。
