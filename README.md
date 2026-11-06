# A-Key-Stats · A宝的键鼠账本

> 每天敲了哪些键、手指在板子上磨出什么形状，一屏看完。

macOS 菜单栏小工具。读物理键（`IOHIDManager`）和妙控板/鼠标表面（`MultitouchSupport`），
把「哪个键按得多、鼠标在哪儿点得多、触控板磨出了什么轨迹」画成热力图。
界面是 askb.app 那套排版：宋体标题、米白底、墨蓝与赭石点缀，支持深色。

- **不记录你打了什么**：只累计「每颗键被按了多少次」，不存按键顺序、不存字符、不存窗口标题。
- **数据全在本地**：`~/Library/Application Support/A-Key-Stats/`，没有网络请求、没有账号、没有上报。
- **双形态**：既能独立运行，也能作为 [A-Kit Tools Hub](https://github.com/BacheLor11/A-Kit-Tools-Hub-macOS) 的插件加载
  —— 面板里显示的就是它自己的界面，不是重绘的菜单。

---

## 装

两种都行：

**A-Kit 里装**：把本仓库地址 `https://github.com/BacheLor11/A-Key-Stats` 粘进 A-Kit 的「导入工具」，之后装、更、删都由它管。

**自己装**：从 [Releases](https://github.com/BacheLor11/A-Key-Stats/releases) 下载 zip，解压把 `A-Key-Stats.app` 拖进「应用程序」。

首次运行需要授「输入监控」（系统设置 → 隐私与安全性 → 输入监控）—— 键盘和鼠标计数靠它。
`MultitouchSupport` 是系统私有框架，用 `dlopen` 动态取符号，取不到只会降级成「不支持」，不会崩。

## 构建

```bash
swift build --release
bash Scripts/build.sh --install     # 装到 ~/Applications/A-Key-Stats.app
```

插件形态由 `Scripts/build.sh` 一并产出：组装进 `Contents/PlugIns/AKeyStats.akitplugin`。
A-Kit 装工具时把它软链到自己的插件目录，所以 app 一更新插件跟着更新。
仓库自包含，不需要先克隆 A-Kit 才能编译。

## 结构

| target | 干什么 |
|---|---|
| `AKeyKit` | 采集引擎与存储：物理键、鼠标按钮、电容面接触点、35ms 同键去重、统计周期 |
| `AKeyUI` | 博客皮肤 + 六个页面，含 `PanelView`（菜单栏面板）与 `RootView`（整页） |
| `AKeyApp` | 独立入口：菜单栏常驻 + 主窗口 + 离屏快照 |
| `AKeyPlugin` | A-Kit 插件入口，导出 `akit_plugin_main`，界面复用 `AKeyUI` |

两个形态读写**同一份**数据（`~/Library/Application Support/A-Key-Stats/`）。
`UserDefaults` 也显式指定 `suiteName: com.aibao.AKeyStats` —— 插件跑在 A-Kit 进程里时
`UserDefaults.standard` 会落到宿主的域，这是插件形态第一个坑。

## 文档

- 📖 [详细说明](docs/README.md)：采集方式、权限、配列、已知限制
- 🛠 [开发笔记](docs/DEVNOTES.md)
- 📝 [更新日志](CHANGELOG.md)

## 许可

MIT，见 [LICENSE](LICENSE)。
