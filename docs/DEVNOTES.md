# 2026-10-27

## 妙控板原始触控数据采集工具（trackpad-probe）
- 工作区 `trackpad-probe/`：`main.swift`（Swift CLI）+ `render.py`（纯标准库 CSV→HTML 报告）
- 技术路线：`dlopen` 私有框架 `/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport`
  - `MTDeviceCreateList` / `MTRegisterContactFrameCallback` / `MTDeviceStart`
  - `Finger` 结构体 64 位 sizeof=96，用 `UnsafeRawPointer.load(fromByteOffset:)` 按偏移解析：frame0/timestamp8/id16/state20/x32/y36/vx40/vy44/size48/angle56/major60/minor64/density92
- 实测 macOS 27.0.1（build 26A434）：**无需输入监控/辅助功能授权**即可读；枚举到 2 个设备（0x70=10×15 鼠标、0x81=30×22 妙控板）
- MT 回调**有接触才触发**，空闲不回调 → 工具默认「等第一次触碰再开始计时」
- `MTDeviceGetDeviceID` == ioreg `AppleMultitouchDevice` 的 `LocationID`，用它区分触控板 / 鼠标 / 内建（Magic Mouse 上表面也上报接触点，不区分会串数据）

## A-Key-Stats（新项目，/Volumes/askb-d/Agent-Projects/A-Key-Stats）
- SwiftPM 三 target：`AKeyKit`（采集引擎，零 UI）/ `AKeyUI`（博客皮肤+六页）/ `AKeyApp`（主窗+菜单栏+AKit+自检）；`Sources/Vendor/AKitStatusKit.swift` 从 A-Kit 复制
- 采集：键盘 `IOHIDManager`（usage page 0x07，pressed 集合去自动重复）；鼠标按钮 0x09；滚轮 `NSEvent` 全局+局部监视器；触控板 `MultitouchSupport`
- 数据：`~/Library/Application Support/A-Key-Stats/days/*.json`（每日聚合 + 32×24 热力网格）+ `traj/*.bin`（8B/点：Float32 t + UInt16 x + UInt16 y，位移<0.002 且 dt<0.05 丢弃）
- 界面：askb.app 皮肤（宋体标题 / #FBFAF7 / 墨蓝 #34557A / 赭石 #B5562E），四套配列（ANSI 紧凑/全尺寸/ISO/JIS），触控板热力 + 轨迹回放，鼠标俯视剪影 + 表面热力
- 打包：`Scripts/build.sh`，**签名必须用 SHA-1**（同名 Apple Development 证书有两张，按名字会 ambiguous）；固定证书签名才能让输入监控授权跨构建保留
- 验证：合成滚轮事件（CGEvent）确认落盘链路通（无输入监控也能用 NSEvent）；`--snapshot` 离屏渲染对版式；`--selftest` / `--livepad` 查权限与设备
- 坑：Canvas 里 `context.clip` 不如 `.clipShape()` 可靠；键帽用字符 `⇧⌘⌥⌃` 会缺字，改成文字 shift/cmd/opt/ctrl；深色模式热力色冷端要用卡片底色

## 坑：HID usage ≠ macOS 虚拟键码（v0.1.1 修）

首版 `InputTap` 直接把 `IOHIDElementGetUsage()` 的返回值当成虚拟键码存进 `DayStats.keys`，
而界面配列表用的是 `kVK_*`（`NSEvent.keyCode` 那一套）。两套编号毫无关系：

| 物理键 | HID usage | macOS 虚拟键码 | 首版会点亮 |
|---|---|---|---|
| A | 0x04 (4) | 0x00 (0) | H |
| 空格 | 0x2C (44) | 0x31 (49) | / |
| 回车 | 0x28 (40) | 0x24 (36) | K |
| Backspace | 0x2A (42) | 0x33 (51) | \ |

修法：新增 `AKeyKit/HIDKeymap.swift`，采集时立刻换算，回调对外一律是虚拟键码；
`usage == 0`（键盘的空报）直接丢弃；去自动重复的 pressed 集合改成按设备指针分桶（原来按设备名，同名设备会串）。
历史数据由 `Store.migrateKeycodesIfNeeded()` 一次性换算（标记文件 `.keycodes-v2`），同一天里多个 usage
落到同一个键的按次数相加。

**验证方式**：`--keylog 20`，同一次按键同时打印 HID usage / 映射结果 / 系统真实键码，三个能对上才算对。
注意不能用 `CGEvent.post` 合成按键来验证——合成事件到不了 IOHID 设备层，抓不到。

## v0.2.0 四件修复，都是「看起来能用其实不对」的那类

**1. 双指滚动轨迹连成 Z 字**
`recordContacts` 把同一帧里所有接触点顺序写进一条流，两根手指逐帧交替出现
（f1,f2,f1,f2…），渲染时按顺序连线就变成了来回横跳的 Z。
修法：轨迹格式升到 v2，每点多存 2 字节手指 id；渲染时按 id 分组、各自成线。
旧 v1 文件在首次写入时原地升级（旧点 id 记 0），不丢数据。

**2. 触控板双指滚动被算成鼠标滚轮**
`NSEvent` 的 scrollWheel 全局监听分不清设备。修法两条并用：
`event.phase`（连续手势）判断是不是触控板/触控表面；再用最近 0.3 秒内
哪台设备有接触点判定归属，一次手势（含松手后的惯性滚动）沿用同一归属。
数据模型加 `ClickStats.padScroll`，老 JSON 缺字段按 0 解码。

**3. 按一次键记两次**
先排除了「一块键盘被枚举成多个 IOHIDDevice」（实测只有 1 个），
改成两道路径：同一物理身份（vendor+product+location）共用一份按下表 +
同一颗键 35ms 内只计一次。被挡下的重复不计入统计，但会推一条 `duplicateKey`
事件给检测页，作为「连键」证据 —— 统计干净，症状仍然看得见。

**4. 图标**
ImageGen 出 1024 原图（奶油底 + 墨蓝键帽 + 一颗赭石），`Scripts/IconMaker.swift`
自动找内容边界 → 重排到 824×824 内容区 → 圆角遮罩 → 四周透明 → 出全尺寸 iconset。
生成原图外侧是白底，不做这一步直接当 .icns 用，Dock 里会是个白方块。

## v0.2.1 检测页：扫键卡顿 + 高亮闪没

两个毛病其实是三处问题叠在一起。

**1. 快速扫键时 UI 卡住**
检测页的键盘是 `KeyboardHeatView` —— 用 SwiftUI 逐键堆出来的，100+ 个 View，
每个还挂了 `.help`（会挂 tooltip tracking area）和 `.animation`。再叠加每个按键事件都写
`@Published`（一次 keyDown 要写 5~7 个属性），每次写都触发一轮 body 重算。
手扫键盘时事件率能到 100/s，主线程直接被压住。

修法两层：
· `TesterStore` 的状态先写进内部影子 `Snapshot` 结构，UI 只订阅一个 `snapshot`，
  发布节流到 60Hz（`schedulePublish` + `Task.sleep(16ms)`）。事件一个不丢，只是合并重绘。
· 检测页改用 `TesterKeyboardView`：**Canvas 一次画完**所有键帽，不建 View、不挂 tooltip、
  不做逐键动画。重绘成本从「100+ 视图 diff」降到「100 次 fill/stroke/draw」。

**2. 有时候亮有时候不亮**
真凶不是高亮逻辑，是 `state.tester` 是普通 `let` 常量、不是 `@Published`：
键盘视图**根本没订阅**它的变化，只有 AppState 每秒刷新的定时器顺带重算一次。
快速扫键时手指早抬起来了才轮到那一帧 → 随机亮。

修法：`TesterView` 拆成薄壳 + `TesterContent`（`@ObservedObject var tester`），
只让检测页内容跟着 tester 重算，不带着侧栏一起刷。

**3. 语义本来就错了**
`pressedKeys` 只在按住期间存在，扫过去当然不留痕。用户要的是「这颗键有没有反应」，
所以新增 `testedKeys`：触发过就插入，**只增不减**，直到点「重置测试」。
两套集合并存：tested 画淡填充 + 描边，pressed 画实心。
顺带补了覆盖率（已覆盖 42/77）和「还没按到」的键名清单 —— 亮满即通过，
这才是键盘体检该有的样子。

注意：`TesterStore.handle` 仍由 `Task { @MainActor in }` 从 IOHID 回调投递，
事件本身是主线程来的（manager 调度在 main runloop），单次只是几次字典写，不是瓶颈。

## v0.3.0 概览支持月 / 年 / 全部周期

数据本来就是按天一份 JSON 存着的，所以跨周期不需要改存储，只需要一层聚合。

**聚合口径**（`AKeyKit/Period.swift`）
· 键次数、点击、滚轮、接触帧、活跃时长：逐日相加
· 热力网格：`HeatGrid.merge` 逐格相加，所以「今年」的热力图是 365 天的叠加
· 峰值接触面积：取 max（面积不能相加）
· `dayCount` 只数有活动的天——空白白天如果也进分母，日均会被稀释成假数字

**性能：历史缓存 + 今天实时**
`refresh()` 是 1Hz 跑的，如果每次都 `loadAll()` 读一年 365 个文件，直接卡死。
所以拆成两段：
· `historyPeriods` 缓存「除今天以外」的四个周期聚合，只在**跨天时**重建一次
· 每次刷新只把 `engine.snapshot()`（今天的内存数据）叠上去，纯内存加法

注意盘上那份「今天」最多比内存晚 20 秒（落盘间隔），聚合时按 `day.date != todayKey`
跳过，否则今天的数据会被算两遍。

**UI**
· 新增 `PeriodTabs`：既是切换器也是总览条，每格给出周期名 + 按键总数 + 天数
· 抬头（kicker / 标题 / lede）跟着周期变，「全部」会写出 `2025-01-14 → 2026-10-29` 这样的范围
· 手指行程按量级换单位（cm → m → km），累计到几公里时不再顶着六位厘米数
· 活跃时长超过一天换成「N.N 天」
· 跨周期不叠轨迹——轨迹点的 `t` 是当天秒数，跨天拼起来没有意义，概览里本就关着轨迹

**顺手修的**
`KeyRankList` 的数字列原来只有 46pt，累计到七位数（1,313,650）会折成两行，
加宽到 66pt 并允许缩放到 0.65。
