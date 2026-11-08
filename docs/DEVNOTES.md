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

## v0.3.3 色阶刻度 + 轨迹导出

**为什么图例要带刻度**
三个视图上色的口径都是 `f = pow(value / peak, gamma)` 再交给 `AKSScheme.heat(f)`。
原来页头那条「少 → 多」的渐变只是把 `heat()` 采样几个点，等于什么都没说：
深蓝到赭石之间夹了一个 `pow`，颜色深浅和次数根本不成正比，换个周期 `peak` 又变了。

所以 `HeatScaleInfo` 把口径收拢成一处：
`peak`（键盘取 max，接触面取 95 分位）、`gamma`（0.45 / 0.5）、`unit`。
图例把 f 反算回数值：`value = peak * f^(1/gamma)`。这样刻度和色块用的是同一组参数，
改归一化方式时不会出现「图变了、图例没跟上」。

中间那个刻度特意取 `pivot = 0.55` 处的值 —— 那正是 `heat()` 从墨蓝切到赭石的临界点，
条上也在同一位置画了一条细线。于是「颜色开始偏红 = 多少次」一眼可读，比标个中位数有用得多。

**渐变条用 Canvas 逐段填，不用 LinearGradient**
`heat()` 是一条带幂次的折线（0→0.55 走冷到墨蓝，0.55→1 走墨蓝到赭石），
`sRGB` 空间里的线性插值会在中段偏色。64 段填色，视觉上和键帽完全一致，成本可以忽略。

**紧凑模式**
概览三张小卡最窄只有 196pt（触控板 286、鼠标 196）。`compact` 只是把条压到 6pt、
字号压到 8.5、去掉说明行，三个刻度保留 —— 少了中间刻度就退化成「猜」。

**轨迹导出为什么流式**
一天的 `pad.bin` 几百 KB ~ 几十 MB，全部历史几百万个点。`TrajectoryWriter.read` 有 `limit`（默认 20 万），
拿它导出会静默截断。所以另写了 `TrajectoryExport.forEachPoint`：
按 1MB 分块读、按记录长度对齐解码、**余下的半条记录留到下一块**，永远不把整个文件读进内存。
v1（8B/点，无 id）和 v2（10B/点）都认，导出时 v1 的 finger 一律写 0。

写 CSV 也一样：攒 256KB 就 `write`，内存峰值和总点数无关。
表头是英文列名（`date,time,t,x,y,finger`），不写 BOM —— 加了 BOM 会让 pandas 读出个带 `\ufeff` 的列名。

**导出前必须 flush**
采集缓冲是 4KB，里面可能压着最后几百个点。不 flush 就导出，文件尾总是少几秒，
用户会以为丢数据。`AppState.exportTrajectory` 第一行就是 `engine.flush()`。

**空白天不进导出**
只导真有 `.pad.bin` 的日期。空白天导出来只有表头，看起来像坏了；
一个都没有时直接抛 `noTrajectory`，界面显示「这段时间还没有轨迹数据」。

自检：`./.build/release/AKeyStats --export-traj /tmp/x.csv`，
本机 6 天数据导出 76,891 点 / 4.0 MB，头尾时间戳与 `t` 换算一致。

## v0.4.0 轨迹回放导出视频

### 先说为什么返工

第一版我把视频当成「一张海报」来做：大留白、左上日期、右上时钟、底部进度条和里程、
结尾热力淡入、当前触点光点。技术上跑通了，但方向错了 —— 用户要的是
**把 App 里点「回放」看到的那块东西录下来**，不是重新设计一个画面。

返工后把画布、热力、双层描边、角标全部对齐 `TrackpadHeatView`，
推进节奏也对齐 `AppState.startReplay`，画面里不出现任何 App 里没有的东西。
教训：这类「导出」需求默认是 WYSIWYG，加信息量要先问。

### 复用回放的三个口径

1. **推进**：App 是 `trailLimit = points.count * progress`，按**点位索引**均匀走，
   不是按真实时间。所以 Painter 里也只算 `progress = frame / (frames - 1)` 再乘点数。
2. **时长**：`min(max(span / 8, 1.2), 12)`。和 `startReplay` 里同一行公式，
   抽成 `Config.autoDuration(span:)` 以免两处漂移。
3. **线宽**：App 里是 2.4 / 0.95 pt，但那是在 360pt 高的组件里。
   视频里触控板高 1038px，所以 `s = padHeight / 360`，线宽、字号、内圈 inset 全部乘 s。
   不乘的话放大近 3 倍后线会细得像划痕。

### 双层累积位图，而不是「每帧重画全部路径」

每帧重画 4.7 万个点会是 O(帧数 × 点数)，实测不可接受。
所以沿用增量思路：只把「上一帧之后新增的点」画进累积位图。

但有个陷阱 —— **累积层会让 alpha 饱和**。
App 里每帧重画一次，同一条线只描一遍，`accent2.opacity(0.45)` 就是 0.45；
累积层里同一处被后续批次反复描，实色会一直堆到不透明，最后糊成一片。

解法是把双层描边拆成两张位图：
- `wideLayer`：用背景色描 2.4×s 的宽边（作用是给轨迹"挖"掉热力）
- `thinLayer`：用赭石描 0.95×s 的细线

两张都画**实色**，合成时才给整体 alpha（宽边 0.70、细线 0.45~0.85）。
这样每条线等效于「以固定透明度画一次」，和 App 每帧重画的结果一致，不会越叠越黑。

细线的透明度还沿用 App 的规则：按出现过的 finger id 数量 `>40 → 0.45 / >12 → 0.65 / else 0.85`。

### 热力底图预渲染

`makeHeatLayer` 把 32×24 的格子一次性填成一张 CGImage，之后每帧 `draw(image)`。
原来每帧现画 768 个格子，600 帧白花十几秒，而且每帧的浮点结果一样。

注意格子的 y 要用 `size.height - (row + 1) * ch` —— CGContext 原点在左下，
而 HeatGrid 的 row 0 是顶部。

### 编码

`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`，像素格式 32BGRA，
`CGContext(bitmapInfo: premultipliedFirst | byteOrder32Little)` 正好对上。

两个坑：
- `input.isReadyForMoreMediaData` 要自旋等，不能硬塞，否则 append 静默失败。
- `finishWriting` 的回调要靠 runloop 驱动。后台线程里用
  `while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(...) }`
  同时等和泵，否则会一直挂着。

### 自检

`./.build/release/AKeyStats --video /tmp/x.mp4 2026-10-30 [秒数]`，
渲完用 `AVAssetImageGenerator` 抽 5 帧 PNG（10% / 35% / 62% / 85% / 99%）落到 /tmp 对版式。

本机 2026-10-30：47581 点 → 360 帧 / 12 秒 / 3.7MB，渲染 7 秒。

## v0.4.1 回放视频里多指没分开

复刻 `TrackpadHeatView` 时漏了一件事：App 里画轨迹是**先把点按 finger id 分组**
（`groups[p.id]` 各成一条折线），视频的 `advance()` 却把所有手指的线段塞进了同一条
`CGMutablePath`。当时以为用 `lastPoint` / `lastTime` 两张字典按 id 记状态就够了，其实不够。

**为什么不够**
`path.addLine(to:)` 是从**路径的当前点**连过去，不是从你记的 lastPoint 连过去。
双指滚动时两根手指逐帧交替采样（f1,f2,f1,f2…），每根手指各自「连续」，
但路径当前点永远是另一根手指的落点。于是 f1 的线被接到 f2 的位置，画出一条横穿板面的直线。

本来 `opened` 这个 Set 想在「本批第一次见到该 finger」时 move 一次，之后不再 move —— 恰好把
断开的机会也用掉了，等于保证了跨指一定连上。

**数据**
2026-10-30 的 pad.bin：47581 点 / 11 个 finger id。
· 同 finger 相邻采样点位移：中位 0.0047，p99 0.0312（板宽比例）
· 换 finger 那一步的位移：中位 0.1581，93.1% 超过 0.1
旧算法一共连出 9506 条这类线，长度从 10% 到 90% 板宽不等。
视觉结果就是中间糊成一坨实心橙、外面一圈近乎平行的长斜线——比真实轨迹还显眼。

**改法**
每批新增的点按 finger 分桶，各建一条 `CGMutablePath`，分别描进两张累积位图：

```swift
var batch: [UInt16: CGMutablePath] = [:]
let continues = lastTime[p.id].map { p.t - $0 <= 0.25 } ?? false
if continues, let last = lastPoint[p.id] {
    let path = batch[p.id] ?? CGMutablePath()
    if path.isEmpty { path.move(to: last) }   // 跨批接续：从上一批这根手指的落点起
    path.addLine(to: pt)
    batch[p.id] = path
}
// continues == false 是抬手指后的新起点：单点不产生笔画，交给下一个点去接
```

断点这里不用再 `move(to: pt)`：单独的 move 不出笔画，而下一个点会拿 `lastPoint` 当起点 move 过去，
效果和「断点后重新起笔」一致。跨批接续也天然成立，因为 `lastPoint` 是按 id 存的。

**顺带**
每帧 `wideLayer.makeImage()` + `thinLayer.makeImage()` 各拷一张全尺寸位图，而少数帧并没有新增点。
加了个 `imagesDirty` 标志，`drawn` 没变就直接复用上一张。

自检：把同一段 800 点多指窗口分别按新旧算法画成 PNG 对比，旧版 773 段里 608 段是跨指线，
新版 0 段。

---

## 键盘为什么会「安静地」不记（0.4.2）

**现象**
触控板有数，键盘一条都没有，界面上没有任何提示，看起来像「坏了但不知道坏在哪」。

**为什么只有键盘会中招**
三路采集吃的是三种完全不同的权限：

| 通道 | 依赖 | 是否需要「输入监控」 |
| --- | --- | --- |
| 触控板 | MultitouchSupport 私有框架 + MTDevice | 不需要 |
| 鼠标 | IOHIDManager，但指向设备不受保护 | 不需要 |
| 键盘 | IOHIDManager，usagePage 0x07 | **需要** |

系统对未授权进程的处理是「把键盘设备藏起来」，不是「打开失败」——
所以 `IOHIDManagerOpen` 返回 `kIOReturnSuccess`，`IOHIDManagerCopyDevices`
里却一台键盘都没有，鼠标还在。代码里没有任何错误可捕获，只能靠主动体检。

**两种会触发的情况**
1. 授权失效：TCC 记录绑在签名身份上。重新安装 / 换签证书之后，系统设置里开关可能还亮着，
   但事件已经不往这边送了 —— 关掉再打开一次才会重建记录。
2. 按键不是本机键盘发的：KVM、远程桌面、通用控制都是把按键注入事件层，压根没有 HID 设备。
   这类情况 IOHID 永远看不见，只有事件层能看见。

**处理**
`KeyboardHealth` 把状态分成 `noAccess` / `hidden` / `tapOnly` / `ok` 四态，界面据此说话。
`hidden` 时挂一层 `CGEventTap`（`cghidEventTap`，`.listenOnly`）兜底计数；
键盘设备一露头就立刻摘掉，避免同一次按下记两遍（两条链路是互斥的）。

**踩坑**
- `tapDisabledByTimeout`：系统嫌回调慢会自己把 tap 停掉，之后一条都收不到，必须在回调里重新 `tapEnable`。
- 同一个进程往事件层塞的键，系统不会回灌给它自己的 tap。要验证监听链路，
  得另起一个进程发键（`--postkey` 子进程），否则会误判成「监听坏了」。
- `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 发出去的就是虚拟键码，
  和 IOHID 那条链路要先做 usage → kVK 换算不同，兜底这条路不用查表。
