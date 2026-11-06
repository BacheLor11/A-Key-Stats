# A-Key-Stats

按键与妙控板热力图。每天敲了哪些键、手指在板子上磨出什么形状，一屏看完。

- **不记录你打了什么**：只累计「每颗键被按了多少次」，不存按键顺序、不存字符、不存窗口标题。
- **数据全在本地**：`~/Library/Application Support/A-Key-Stats/`，没有网络请求、没有账号、没有上报。
- **界面**：askb.app 那套排版（宋体标题 / 米白底 / 墨蓝与赭石），支持深色模式。

---

## 采集方式

| 部分 | 技术 | 权限 |
|---|---|---|
| 键盘按键 | `IOHIDManager` 读物理键（usage page 0x07） | 需要「输入监控」 |
| 鼠标点击 / 滚轮 | `IOHIDManager` 按钮元素 + `NSEvent` 滚轮 | 同上 |
| 触控板 / 鼠标表面 | `MultitouchSupport.framework`（私有，`dlopen` 动态取符号） | 不需要 |

`MultitouchSupport` 给的接触点带归一化坐标、速度、接触面积、椭圆长短轴。
`MTDeviceGetDeviceID` 拿到的就是 ioreg 里 `AppleMultitouchDevice` 的 `LocationID`，
用它把设备区分成 **触控板 / 鼠标 / 内建触控板** —— Magic Mouse 上表面也是电容面，会上报接触点，
不区分就会把鼠标的数据算进触控板。

触控板归一化坐标的原点在**左下**，UI 画布原点在左上，所以默认翻转 Y 轴；
如果热力图上下颠倒，去「设置 → 翻转 Y 轴」切一下。

## 数据

```
~/Library/Application Support/A-Key-Stats/
├── days/2026-10-27.json      # 每日聚合：每键次数、24 小时分布、点击、热力网格、里程
└── traj/2026-10-27.pad.bin   # 触控板原始轨迹（降采样，10 字节/点，带手指 id）
    traj/2026-10-27.mouse.bin # 鼠标表面轨迹
```

- 热力网格：32 × 24 格，每格记「停留帧数」≈ 停留时间。
- 轨迹降采样规则：位移 < 0.002 且间隔 < 0.05s 的点丢掉，一周下来几 MB。
- 轨迹格式：`AKST` + 版本(2B) + 保留(2B) 头，之后每点
  `Float32 t(当天秒数) + UInt16 x + UInt16 y + UInt16 手指 id`（v2，10 字节）。
  旧 v1 文件（8 字节，无 id）会原地升级，不会丢数据。
  手指 id 是必需的：双指滚动时两根手指逐帧交替上报，不分段画就会连成一整片 Z 字。
- 滚动口径：触控板双指滚动记作 **触控滚动**（`padScroll`），鼠标（含妙控鼠标表面）的滚动计入 **滚轮**（`scroll`）。
  判定靠 `NSEvent.phase`（连续手势）+ 最近 0.3 秒内哪台设备有接触点，一次手势内的惯性滚动沿用同一归属。

想清空：设置页「清空全部数据」，或直接删掉上面这个目录。

## 页面

概览（可按需隐藏触控板/鼠标卡片）· 键盘热力（四套配列）· 触控板（热力 + 轨迹回放）
· 鼠标（表面热力 + 点击）· **检测**（按键响应 / 连键 / 鼠标按键）· 历史 · 设置。

概览页顶部有 **今天 / 本月 / 今年 / 全部** 四个周期，条上直接给出各周期的按键总数和天数，
点一下整页（KPI、三张热力图、24 小时分布、按键排行）都跟着切。
跨周期是把逐日统计相加：次数相加、热力网格逐格相加、接触面积取峰值。
「全部」的抬头会写出数据覆盖的日期范围，右侧指标给出日均和累计天数。

「检测」页只做物理层面的体检，不写进任何统计：
手扫一遍键盘，**按过的键会一直亮着**（赭石淡填充 + 描边），正按住的键画成实心，
顶部显示「已覆盖 42/77」和还没按到的键名 —— 全部亮满就说明没有哑键。
另外统计按住时长、同键两次的间隔、鼠标左右中键、双击与连点，
并在同一颗键 50ms 内自己又触发时标红 —— 机械轴触点氧化的典型症状。

## 构建

```bash
./Scripts/build.sh              # 出 build/A-Key-Stats.app
./Scripts/build.sh --install    # 装到 ~/Applications
./Scripts/build.sh --release    # 额外打 zip
```

签名：默认取钥匙串里第一张未吊销的 Apple Development 证书（用 SHA-1，避免同名证书歧义）。
**用固定证书签名很重要** —— 输入监控授权绑定签名身份，ad-hoc 签名每次重建都会掉授权。
可用 `CODESIGN_ID=<sha1或名字>` 指定。

## 开发自检

```bash
./.build/release/AKeyStats --selftest                 # 权限 / 设备识别 / 数据目录
AKS_DEMO=1 ./.build/release/AKeyStats --snapshot a.png dashboard   # 离屏渲染（假数据）
./.build/release/AKeyStats --snapshot b.png keyboard  # 离屏渲染（真实数据）
AKS_LAYOUT=ansiFull ./.build/release/AKeyStats --snapshot c.png keyboard  # 指定配列
AKS_DARK=1 ./.build/release/AKeyStats --snapshot d.png dashboard          # 深色
```

## A-Kit 接入

走 L1 状态协议（`Sources/Vendor/AKitStatusKit.swift`，与 A-Sweep 同一套）：

- `bundleId` = `com.aibao.AKeyStats`，`akit.json` 的 `id` = `a-key-stats`
- 菜单项：打开 / 键盘热力 / 触控板 / 鼠标 / 暂停记录 / 设置
- Hub 接管时自己收起菜单栏图标，Hub 掉线 5 秒内自己回来

## 已知限制

1. **ISO 配列的回车画成普通高度**：竖条回车会和工作区的右 shift 抢位置，暂不画 L 形。
2. **接触面积 ≠ 力度**：`size` 是电容接触面大小，真 Force Touch 压力要 `NSEvent.pressure`，
   而且只在按下/拖动时才有值。
3. **私有框架风险**：`MultitouchSupport` 是系统私有组件，macOS 大版本更新可能改符号。
   取不到符号时只会「不支持」，不会崩。
4. **计数口径**：按住不放只记 1 次（IOHID 侧做了按下状态去重），修饰键也计入。
   同一颗键 35ms 内的重复上报会被挡掉（不计入统计，但在「检测」页计为异常），
   人手物理上做不到 35ms 内连按两次同一颗键。
5. **图标**：`Resources/AppIcon.icns` 由 `Scripts/IconMaker.swift` 生成 —— 原图裁成
   824×824 内容区 + 圆角遮罩 + 透明边，符合 macOS 图标网格。
