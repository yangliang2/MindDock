# MindDock

> **An open-source, zero-inbox attention dock that lives on your desktop edge and phone lock screen — bridging the gap between work and life without opening an app.**

**MindDock** 是为“事情太多、频繁被打断、不写传统笔记也不排日程表”的人设计的开源跨场景注意力停靠坞：

- **0 步闪投（Drop）**：不打开复杂软件、不选文件夹、不填日期——在电脑前按全局热键动嘴/敲半句，在外面直接给飞书机器人发语音或短句，1 秒清空大脑工作记忆。
- **跨场景无缝接力（Shift）**：
  - 上班在电脑前顺口丢的**生活琐事**，白天隐身不打扰工作；锁屏或合盖离开工位时自动通过飞书系统级推送浮现在**手机锁屏卡片**上接住你（0 云服务器、0 域名、无需侧载 APK）。
  - 下班在路上/睡前冒出的**工作灵感**，即使 MacBook 合盖断网装在包里，发给飞书机器人的语音/文字也会自动暂存；回到工位一开盖自动拉取、转写、后台备料（**Prep**），带着不超过 3 行的行动线索停在**电脑边角泊位（Berth）**等你。
- **有限台面 + 印象打捞（Dock & Recall）**：每个场景（`Work` / `Life`）眼前永远严格只停靠最多 **3 个活跃泊位**，溢出项自动进入后台 FIFO 队列并在销项后自动递补；干完即沉入深海（**Deep**），日后凭一句模糊印象随时打捞（**Recall**），且原始 `raw` 文字永远原封不动保留。

---

## V0.1 Quick Start (macOS 14+)

MindDock V0.1 交付为**单个原生 macOS 应用包（`dist/MindDock.app`）**，基于本地 SQLite 持久化，无需部署任何后端服务器。

### 1. 构建独立应用包（`MindDock.app`）

```bash
./scripts/build-app.sh
```

该脚本会编译 Release 二进制、生成菜单栏常驻配置（`LSUIElement` + 按需麦克风/语音识别权限说明）、完成本地签名并输出至 `dist/MindDock.app`。

### 2. 配置 AI 备料与飞书手机桥接（二选一，双向互通）

**方式 A — 交互式命令行向导（推荐首次配置）**：

```bash
./scripts/setup-wizard.sh
```

向导会分步引导你获取 OpenAI 兼容 API Key（如 DeepSeek / OpenAI / SiliconFlow）以及飞书企业自建机器人（或单行 Webhook），并以 `0600` 权限写入 `~/.config/minddock/.env`。

**方式 B — 应用内图形设置面板（支持免重启热生效）**：

1. 启动应用：`open dist/MindDock.app`（也可拖入 `/Applications`）。
2. 点击右上角状态栏图标 → **`Settings & Mobile Setup…`**（或按 `⌘,` / 点击停靠台右上角齿轮图标）。
3. 填入 LLM `Base URL` / `API Key` / `Model` 及飞书机器人凭证，点击 **`Save & Apply Live`** 即可立即热更新生效；可随时点击 **`Test LLM`**、**`Test Lock-Screen Push`**、**`Sync Mobile Drops Now`** 在线验证。

> 两种方式共享 `~/.config/minddock/` 配置（`0600` 权限保存，密钥永不写入日志）；即使完全不填密钥或处于离线状态，MindDock 也会自动退化为本地规则分流与同义词打捞。

---

## Global Shortcuts & 24h Work ↔ Life Workflow

| 操作 / 场景 | 触发方式 | 行为说明 |
| :--- | :--- | :--- |
| **唤醒闪投 / 打捞栏** | `Option + Space`（无需辅助功能权限） | 默认进入 **Drop** 模式；支持**单击切换录音**或**按住说话松手结束**，可一键切换中英识别语言（`zh-CN` / `en-US`，说完美即释放硬件，平时 **0% CPU、无常亮橙点**），按 `Tab` 可手动指定 `Auto / Work / Life`，按 `Enter` 立即停靠。切换到 **Recall** 标签即可凭模糊印象打捞深海记忆。 |
| **显隐屏幕边缘停靠台** | `Option + Shift + Space` | 随时召唤或隐藏右侧非抢焦点 3 泊位悬浮停靠台（`EdgeDockPanel`）。 |
| **泊位一键处置** | 停靠台泊位按钮 | `✓ Resolve` 销项沉入深海并从后台 FIFO 队列自动递补下一项；`⇄ Life/Work` 一键纠偏换道；`↓ Deep` 直接沉入深海记忆。 |
| **下班离席（Desk → Phone）** | 锁屏或合盖睡眠自动触发 | `SystemShiftMonitor` 监听系统锁屏/睡眠，自动换场至 `Life` 并将当前活跃的生活泊位 + `Prep` 备料推送到手机飞书锁屏卡片（指纹去重，空台面不打扰）。 |
| **在外销项与移动闪投（Phone → Mac）** | 在手机飞书对话直接回复 | 在飞书回复 `done 1` / `完成 1` / `1` 自动销项并递补；在地铁或路上随时发**语音或文字**给机器人，回到工位开盖唤醒时自动拉取转写、完成备料并停靠到 `Work` 台面。 |

## Development & Tests

```bash
# 运行全部领域与桥接契约测试
swift run --disable-sandbox MindDockTests

# 按名称过滤运行单条测试
swift run --disable-sandbox MindDockTests settings_store
```

## Documentation

- [Domain Glossary](./GLOSSARY.md)
- [ADR-0001: Single Native macOS App with Feishu Serverless Mailbox Bridge](./docs/adr/0001-cross-context-hub-and-zero-install-mobile.md)
- Research & Validation:
  - [Community Pain & UX Validation](./docs/research/0001-community-pain-and-ux-validation.md)
  - [Competitor Field-Test Guide](./docs/research/0002-competitor-field-test-guide.md)

## License

This project is licensed under the [MIT License](LICENSE).
