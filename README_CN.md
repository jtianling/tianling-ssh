# Tianling SSH

一个使用 SwiftUI 构建的原生 iOS SSH 客户端.  终端模拟由 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 驱动.

[English](./README.md)

## 为什么选择 Tianling SSH?

相比其他 iOS SSH 客户端, 本应用功能更少, 设计更简洁.  它的亮点在于**对 iPad 外接实体键盘的一流支持**, 包括**中文输入法的正确处理**.

很多 iOS SSH 应用 — 包括知名的商业产品 — 在 iPad 连接实体键盘时都存在问题: 修饰键工作异常, 输入法组合被打断, 或者中文输入完全不可用.  Tianling SSH 专注于把这些基础体验做对, 让你在 iPad + 实体键盘的环境下也能顺畅工作.

## 功能特性

- **多种认证方式** - 支持密码和 SSH 密钥 (Ed25519 / RSA) 认证, 可导入密钥文件或直接粘贴密钥内容
- **多会话管理** - 同时创建, 切换, 编辑和删除多个 SSH 会话
- **终端模拟器** - 基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 的完整 VT100 / xterm 兼容, CoreText 渲染, ANSI 颜色, 选区, 备用缓冲区
- **键盘配件栏** - SwiftTerm 内建 `TerminalAccessory` 浮于软键盘之上, 提供 Esc / Ctrl / Tab / F1-F10 / 常用符号
- **启动脚本** - 配置连接后自动执行的命令
- **会话持久化** - 保存的会话在应用重启后自动恢复

## 系统要求

- iOS 17.0+
- Xcode 15+
- Swift 5.0+

## 快速开始

1. 克隆仓库:

```bash
git clone https://github.com/jtianling/tianling-ssh.git
cd tianling-ssh
```

2. 重新生成并打开 Xcode 项目:

```bash
xcodegen generate
open tianling-ssh.xcodeproj
```

3. Xcode 会自动解析 Swift Package 依赖.  构建并在模拟器或真机上运行即可.

## 依赖

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - VT100 / xterm 终端模拟器和 UIKit view
- [Citadel](https://github.com/orlandos-nl/Citadel) - 基于 SwiftNIO 的 SSH 客户端库

## 项目结构

```
App/
  TLSSHApp.swift             # 应用入口
  ContentView.swift           # 根导航和会话路由
Connection/
  ConnectionConfigView.swift  # 连接表单(主机, 认证, 启动脚本)
Session/
  SessionManager.swift        # 会话生命周期和持久化(@MainActor)
  SessionListView.swift       # 会话列表 UI
SSH/
  SSHManager.swift            # SSH 连接, PTY, SwiftTerm 集成(@MainActor)
Terminal/
  TerminalContainerView.swift # 终端容器和覆盖层
  SwiftTermBridgeView.swift   # 包裹 SwiftTerm.TerminalView 的 UIViewRepresentable
```

## 致谢

本项目依赖 Joannis Orlandos 的 [Citadel](https://github.com/orlandos-nl/Citadel) 实现 SSH 协议, 依赖 Miguel de Icaza 的 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 实现终端模拟与渲染.

## 许可证

本项目基于 [MIT 许可证](./LICENSE) 开源.
