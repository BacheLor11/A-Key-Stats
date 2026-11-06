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

## 构建

```bash
swift build --release
bash Scripts/build.sh --install     # 装到 ~/Applications/A-Key-Stats.app
```

## A-Kit 接入

两个形态走同一个 target 布局：

| | 独立 app | 插件 |
|---|---|---|
| 入口 | `Sources/AKeyApp` | `Sources/AKeyPlugin` |
| 界面 | `AKeyUI.PanelView` / `RootView` | 同一份 |
| 数据 | `~/Library/Application Support/A-Key-Stats/` | 同一份 |

插件产出 `libAKeyPlugin.dylib`，由 `Scripts/build.sh` 组装进 `Contents/PlugIns/AKeyStats.akitplugin`；
A-Kit 装工具时把它软链到自己的插件目录，所以 app 一更新插件跟着更新。

## 文档

- 📖 [详细说明](docs/README.md)：采集方式、权限、配列、已知限制
- 🛠 [开发笔记](docs/DEVNOTES.md)
- 📝 [更新日志](CHANGELOG.md)
