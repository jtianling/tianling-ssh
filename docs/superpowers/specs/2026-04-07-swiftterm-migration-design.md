---
date: 2026-04-07
status: draft
topic: 把手写的 terminal 子系统替换为 SwiftTerm
---

# SwiftTerm 移植设计

## 背景

`sp-tlssh` 当前的终端子系统是手写的:

- `Terminal/TerminalScreen.swift`(1058 行): 字符网格 + 内建 ANSI/VT100 状态机, `@Observable` + 手动 `version` 整数驱动 SwiftUI 更新
- `Terminal/ANSIParser.swift`(305 行): escape 序列解析
- `Terminal/TerminalView.swift`(128 行): 纯 SwiftUI 渲染, 每个 cell 是一个 `Text` view
- `Terminal/TerminalInputView.swift`(242 行): SwiftUI 写的控制键工具栏(Esc/Ctrl/Alt/Tab/方向键/^C^D^Z^L^A^E/常用符号)
- `Terminal/TerminalKeyboardInputView.swift`(97 行): 隐藏的 1×1 UIKit `UIKeyInput` view, 接收系统键盘字符
- `Terminal/TerminalContainerView.swift`(137 行): toolbar + 终端 + overlay + 输入条的 SwiftUI 组合
- `SSH/SSHManager.swift` 内的 `UTF8ChunkDecoder`(约 85 行): 处理跨 TCP chunk 的 UTF-8 边界, 把字节解码成 String 后再喂给 `TerminalScreen`

手写实现存在的问题:

1. **性能**: 每 cell 一个 SwiftUI `Text` view, 中等大小终端就会卡, 滚动尤其差
2. **VT100 兼容性**: 自己跟 escape 序列, 总有边角不兼容(选区、Sixel/Kitty 图形、真彩色等都缺失)
3. **维护负担**: ~2200 行项目代码花在终端模拟器上, 跟项目核心(SSH 客户端) 不直接相关
4. **缺失能力**: 选区/复制、IME、Sixel/Kitty 图形、搜索等都没有

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 是一个成熟的 VT100/xterm 模拟器库,  Secure Shellfish、La Terminal 等商用 iOS SSH 客户端都在用它.  本设计把它整体引入 sp-tlssh, 用它的 iOS UIKit `TerminalView` 替换上面所有手写组件.

## 五个核心决策

| # | 主题 | 选择 | 备选 |
|---|---|---|---|
| 1 | 移植深度 | **B**: 用 SwiftTerm 完整 UIKit `iOS.TerminalView`(`UIScrollView` 子类, 内建 CoreText 渲染 + 选区 + IME + accessory bar) | A: 只用 headless `Terminal` 引擎; C: 引擎 + 自写 SwiftUI 渲染 |
| 2 | 依赖管理 | **A**: SPM remote(GitHub), 跟 Citadel 一致, 锁定具体版本 / commit | B: 本地 path; C: vendor 源码 |
| 3 | 控制键工具栏 | **A**: 直接用 SwiftTerm 自带的 `TerminalAccessory`, 删现有 `TerminalInputView` 和 `TerminalKeyboardInputView` | B: SwiftUI 工具栏 + UIHostingController 包成 `inputAccessoryView`; C: 留在 VStack 底部; D: 子类化 SwiftTerm accessory 加按钮 |
| 4 | `SwiftTerm.TerminalView` 实例归属 | **A**: SSHManager(模型层) 直接持有 `let terminalView: SwiftTerm.TerminalView`, bridge view 借用. 跟 SwiftTerm sample app / 商用 app 一致 | B: SSHManager 持有 headless `Terminal` + ring buffer + 每次 mount 时 replay; C: 全局 `[SessionID: TerminalView]` registry |
| 5 | 测试 | **C**: 删整个 `TLSSHTests/` target, 不补充新测试 | A: 全删测试但保留 target; B: 补一组薄的集成 smoke 测试 |

决策 3 的代价: 失去 Alt 键、独立方向键按钮、^C/^D/^Z/^L/^A/^E 一键键、6 个符号键(`\` `` ` `` `_` `=` `[` `]`).  获得 F1-F10 + 浮在键盘之上的 UX.  可后续按需子类化补回.

## § 1 — 总体架构

```
SessionManager → SSHSession → SSHManager
                                 │
                                 ├─ Citadel SSHClient (PTY 字节双向流)
                                 │
                                 └─ SwiftTerm.iOS.TerminalView   ← 长寿命 UIKit 实例
                                       │  (内部持有 SwiftTerm.Terminal)
                                       │
                                       │  TerminalViewDelegate.send → SSHManager.sendBytes
                                       │  PTY bytes → terminalView.feed(byteArray:)
                                       │
                                       ▼
SwiftUI 层:  TerminalContainerView
              ├─ toolbar (HStack: 标题 + Disconnect 按钮, 跟现在一样)
              ├─ SwiftTermBridgeView (UIViewRepresentable)
              │     makeUIView { sshManager.terminalView }
              │     updateUIView { /* nop */ }
              └─ connecting / failed overlay (ZStack, 跟现在一样)
```

关键变化:

1. `SSHManager` 模型层从持有 `TerminalScreen`(纯数据) 改为持有 `let terminalView: SwiftTerm.TerminalView`(UIKit).
2. PTY 写入路径: `ttyOutput → bytes → terminalView.feed(byteArray: bytes)`. 不再做 UTF-8 解码.
3. PTY 读出路径: `SwiftTerm.TerminalViewDelegate.send(source:, data:)` → SSHManager 把数据 yield 进现有的 `inputContinuation`. 字符输入、控制键、accessory 按钮都走这一条路.
4. `TerminalContainerView` 简化掉所有 keyboard focus / first-responder dance. SwiftTerm `TerminalView` 自己是 first responder.
5. 终端尺寸由 SwiftTerm 的 `sizeChanged` delegate 通知 SSHManager → `ttyWriter.changeSize(...)`. 现在的 SwiftUI `GeometryReader` + 字符宽度计算删除.

## § 2 — 文件级别的增删改

### 删除(共约 2200 行项目代码)

| 路径 | 行数 | 理由 |
|---|---|---|
| `Terminal/TerminalScreen.swift` | 1058 | SwiftTerm.Terminal 取代 |
| `Terminal/ANSIParser.swift` | 305 | SwiftTerm 内建 EscapeSequenceParser 取代 |
| `Terminal/TerminalView.swift` | 128 | SwiftTermBridgeView 取代 |
| `Terminal/TerminalInputView.swift` | 242 | SwiftTerm.TerminalAccessory 取代 |
| `Terminal/TerminalKeyboardInputView.swift` | 97 | SwiftTerm.TerminalView 自己是 UIKeyInput |
| `TLSSHTests/`(整个 target) | 137 + Info.plist | 决策 5: 删整个 target |
| `SSHManager.swift` 内的 `UTF8ChunkDecoder` | 约 85 | SwiftTerm 自己处理 UTF-8 边界 |

### 新增(< 250 行)

| 路径 | 内容 |
|---|---|
| `Terminal/SwiftTermBridgeView.swift` | `UIViewRepresentable`. `makeUIView { sshManager.terminalView }`. 60-100 行. |

### 修改

| 路径 | 改什么 |
|---|---|
| `project.yml` | `packages` 加 SwiftTerm SPM 依赖 + 版本; `targets.TLSSH.dependencies` 加 SwiftTerm; 删整个 `targets.TLSSHTests` + `schemes.TLSSH.test` 段 + `schemes.TLSSHTests` 段 |
| `SSH/SSHManager.swift` | 删 `UTF8ChunkDecoder` 和它的使用; 删 `terminalScreen`/`terminalColumns`/`terminalRows` 属性; 加 `let terminalView: SwiftTerm.TerminalView`(init 时 new); 改 ttyOutput 循环成 `terminalView.feed(byteArray: bytes)`; 实现 `TerminalViewDelegate`(`send`/`sizeChanged`/其它 stub); 删 `updateTerminalSize` public 方法; `connectWith(...)` 入口加 `terminalView.getTerminal().resetToInitialState()` |
| `Terminal/TerminalContainerView.swift` | 删 `focusRequest`/`requestKeyboardFocus`/`onTapGesture`/`KeyboardInputUIView` 浮空挂载; 把 `TerminalView` 替换成 `SwiftTermBridgeView`; 把 `TerminalInputView` 工具栏整段删除; connecting/failed overlay 保留 |
| `Session/SessionManager.swift` | 大概率不动. 但要 audit 是否有任何代码访问 `sshManager.terminalScreen` |
| `App/ContentView.swift` | 同上, audit terminalScreen 访问 |
| `AGENTS.md` / `CLAUDE.md` | 更新"数据流"/"关键实现细节"章节. `TerminalScreen` 段落删除, 改成 SwiftTerm 集成说明 |
| `docs/` | 检查 README 等是否引用 `TerminalScreen`/`ANSIParser`, 同步更新 |

净变化: 自己维护的代码量从约 2050 行(Terminal/ 1830 + UTF8ChunkDecoder 85 + tests 137) → 约 250 行, 减少约 1800 行.

## § 3 — 数据流细节

### 输出路径(host → screen)

```
Citadel ttyOutput AsyncStream<TTYOutput>
  │
  ▼
SSHManager.startShellSession Task
  │   for try await chunk in ttyOutput
  │     case .stdout(buf), .stderr(buf):
  │       let bytes = Array(buf.readableBytesView)   // 不再 UTF8 解码
  │       await MainActor.run {
  │         strongSelf.terminalView.feed(byteArray: bytes[...])
  │       }
  ▼
SwiftTerm.TerminalView.feed → 内部 Terminal → buffer 更新 → setNeedsDisplay
```

要点:

- `terminalView.feed(byteArray:)` 接受 `ArraySlice<UInt8>`. 必须在 main actor 上调用(SwiftTerm 不是 thread-safe).
- 不再处理跨 chunk 的 UTF-8 边界 — SwiftTerm 引擎内部维护 parser state, 字节级别 streaming 安全.
- `.stdout` 和 `.stderr` 都 feed 到同一个 `TerminalView`(跟现在 `TerminalScreen` 行为一致).

### 输入路径(user → host)

```
用户在 SwiftTerm.TerminalView 上敲键 / 点 TerminalAccessory 按钮
  │
  ▼
SwiftTerm 内部把动作转成字节, 调用 TerminalViewDelegate.send(source:, data: ArraySlice<UInt8>)
  │
  ▼
SSHManager 实现的 delegate:
  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    inputContinuation?.yield(Data(data))
  }
  │
  ▼
现有的 inputStream 消费循环(不变):
  for await data in inputStream {
    let buffer = ByteBuffer(data: data)
    try? await ttyStdinWriter.write(buffer)
  }
```

要点:

- 现有的 `inputContinuation`/`inputStream`/`ttyStdinWriter.write` 这条链路完全保留.
- `SSHManager.sendBytes(_:)` public 方法保留, 给 startup script 注入用.
- `TerminalAccessory` 的 ctrl modifier 状态由 SwiftTerm 自己维护.

### 尺寸变化路径

```
SwiftTerm.TerminalView.layoutSubviews → processSizeChange(newSize:)
  → 内部计算 newCols / newRows
  → TerminalViewDelegate.sizeChanged(source:, newCols:, newRows:)
  │
  ▼
SSHManager.sizeChanged(...) {
  ttyWriter?.changeSize(cols: newCols, rows: newRows, ...)
}
```

要点:

- 删 `TerminalView` 里的 `GeometryReader` + 字符宽度计算 + `onSizeChanged` 回调.
- 删 `SSHManager.updateTerminalSize(cols:rows:)` public 方法.
- `terminalColumns`/`terminalRows` 缓存属性删, 每次直接 `terminalView.getTerminal().cols/rows` 读.
- PTY 创建时 `withPTY` 用的初始 cols/rows 改成从 `terminalView.getTerminal()` 读.

### 字体 / 配色 / cursor

- SwiftTerm 默认字体是系统等宽字体, 大小可通过 `font` 属性配置.
- 默认配色和当前 SwiftUI 渲染层(黑底/绿字) 不一样 — 需要在 `terminalView.nativeBackgroundColor` / `terminalView.installColors(...)` 设成黑底.
- 配色微调留给实施 Step 6.

## § 4 — 错误处理 / 边界情况

### 现有错误处理保留情况

| 现有逻辑 | 迁移后 |
|---|---|
| `connectionState: .disconnected/.connecting/.connected/.failed(String)` | 不变 |
| Citadel 抛连接错误 → `connectionState = .failed(error.localizedDescription)` | 不变 |
| ttyOutput 循环 throw → `connectionState = .failed(...)` | 不变 |
| `OpenSSHEd25519Parser` / `KeyFileError` | 不变 |
| `disconnect()` 链路(取消 task / finish stream / close client) | 不变 |
| `terminalScreen.reset()` 在 disconnect 时调用 | 改成在 `connectWith(...)` 入口调用 `terminalView.getTerminal().resetToInitialState()`(reconnect 前清屏, 不在 disconnect 时清, 更安全) |

### 新引入的边界情况

1. **Disconnect 后 terminalView 复用**
   - SSHManager 实例和 terminalView 实例都长寿命存在
   - 在 `connectWith(...)` 入口 reset, 而不是 disconnect 时 reset

2. **PTY 还没建立时 SwiftTerm `sizeChanged` 回调先到**
   - SwiftTerm view 一被加进 view tree 就 layout, sizeChanged 立刻回调
   - 但 `ttyWriter` 此时是 `nil`
   - 处理: `func sizeChanged(...)` 里 `guard let ttyWriter else { return }`
   - PTY 建立后用 `terminalView.getTerminal().cols/rows` 当作初始 size

3. **PTY 建立成功后第一次 size 同步**
   - 在 `withPTY` callback 拿到 `ttyStdinWriter` 后, 立刻 `ttyWriter.changeSize(cols: terminal.cols, rows: terminal.rows, ...)`

4. **`MainActor` 隔离**
   - SwiftTerm.TerminalView 必须只在 main thread 操作(包括 feed)
   - SSHManager 整体标显式 `@MainActor`(目前隐式)
   - feed 路径继承 `await MainActor.run` 模式

5. **App 进入后台 → 回前台**
   - 现在没有特殊处理, 不新增

6. **TerminalAccessory 的 control modifier 状态**
   - SwiftTerm 内部维护

7. **session 列表里多个会话**
   - 每个 SSHManager 独立持有自己的 terminalView
   - 不影响现有 session-switch 逻辑

## § 5 — 风险

| # | 风险 | 缓解 | 等级 |
|---|---|---|---|
| 1 | SwiftTerm main-actor 与 Citadel async stream 兼容 | 每次 feed 都 `await MainActor.run`, 跟现有模式一致 | 低 |
| 2 | SwiftTerm 在 fullScreenCover 里 mount/unmount 时 first responder / accessory bar 行为 | Step 2 单独写 smoke test 验证, 在写 SSH 接线之前完成 | 中 |
| 3 | 配色 / 字体 / 字号视觉差异 | Step 6 单独调整 `nativeBackgroundColor`/`installColors`/`font` | 低 |
| 4 | SwiftTerm SPM 版本可能没有稳定 semver release | Step 1 确认 GitHub releases / tags, 必要时用 `revision: <commit>` 或 `branch: main` | 低 |
| 5 | SwiftTerm 默认 keyboard 行为(IME / 自动大写 / 自动纠错) | Step 2 smoke test 验证, 必要时设 `autocorrectionType = .no` 等 | 低 |

## § 6 — 实施顺序

每步独立可验证.

### Step 1 — 加依赖, 不动现有代码

- `project.yml` 加 SwiftTerm SPM 依赖
- `xcodegen generate`
- 编译通过, 现有 app 行为不变

### Step 2 — 写 `SwiftTermBridgeView` smoke test

- 新建 `Terminal/SwiftTermBridgeView.swift`(`UIViewRepresentable`)
- 临时 SwiftUI 入口: 弹一个 fullScreenCover 只放 `SwiftTermBridgeView`, view 持有自己 new 的 `SwiftTerm.TerminalView`, init 时 feed 一段 hardcoded ascii(`"Hello SwiftTerm\r\n"`)
- 验证: 显示正常 / 键盘弹起 / `TerminalAccessory` 浮在键盘上 / dismiss 后再 mount 状态保留 / 横竖屏 layout 正常 / 配色和字体目测可接受
- 此时不接 SSH, 不动 SSHManager

### Step 3 — `SSHManager` 切换到 SwiftTerm

- `SSHManager` 加 `let terminalView: SwiftTerm.TerminalView`(init 时 new)
- 删 `terminalScreen` / `terminalColumns` / `terminalRows` / `UTF8ChunkDecoder` / `updateTerminalSize`
- ttyOutput 循环改成 `terminalView.feed(byteArray:)`
- 实现 `TerminalViewDelegate`: `send` 把字节 yield 进 `inputContinuation`; `sizeChanged` 调 `ttyWriter.changeSize`
- `connectWith(...)` 入口加 `terminalView.getTerminal().resetToInitialState()`
- `disconnect()` 不再 reset 终端
- 编译此时会断: ContentView/TerminalContainerView 还引用 `terminalScreen`. 临时注释来过编译, Step 4 一起验证

### Step 4 — `TerminalContainerView` + `SwiftTermBridgeView` 接入 SSHManager

- `SwiftTermBridgeView` 改成 `init(sshManager: SSHManager)`, `makeUIView` 返回 `sshManager.terminalView`
- `TerminalContainerView` 把 `TerminalView(screen: ...)` 替换成 `SwiftTermBridgeView(sshManager: sshManager)`
- 删 `focusRequest` / `requestKeyboardFocus` / `onTapGesture` / `KeyboardInputUIView` 浮空挂载
- 删 `TerminalInputView` 工具栏整段
- toolbar(标题 + Disconnect) 和 connecting/failed overlay 保留
- 真实 SSH 验证清单:
  - 连接到真实 SSH server, 登录后 prompt 显示正常
  - 输入字符 → 服务器回显正常
  - 上下左右方向键(从软键盘) 在 vim 里能动光标
  - Ctrl 切换 + C 能 SIGINT
  - `ls --color` 输出有色彩
  - `vim /etc/hosts` → 退出 → 屏幕恢复(alt buffer 切换)
  - 横竖屏切换 → SSH server 端 `stty size` 报告正确尺寸
  - disconnect → 重新进入 → 屏幕清空, 重新连
  - 切换会话 → 各自终端状态独立

### Step 5 — 删旧文件 + 删 TLSSHTests target

- 删 `Terminal/TerminalScreen.swift` / `ANSIParser.swift` / `TerminalView.swift` / `TerminalInputView.swift` / `TerminalKeyboardInputView.swift`
- 删 `TLSSHTests/` 整个目录
- `project.yml` 删 `targets.TLSSHTests` + `schemes.TLSSHTests` + `schemes.TLSSH.test` 段
- `xcodegen generate`
- 编译通过(任何残余引用此时会暴露)
- 更新 `CLAUDE.md` / `AGENTS.md` / `docs/`(数据流图、关键实现细节段落)
- 重跑 Step 4 的真实 SSH 验证清单

### Step 6 — 配色/字体微调

- `terminalView.nativeBackgroundColor = .black`
- `installColors(...)` 调一组顺眼的 ANSI 调色板
- 字体大小调到接近现在 13pt 的视觉密度
- 完全 cosmetic, 不影响 Step 5 的 merge
