# LeatrixPlusExt — Leatrix Plus 扩展工具

在 **Leatrix Plus** 的左侧菜单中增加一个独立的「扩展功能*」页，页面顶部标注「Leatrix Plus Ext提供」：

- 页面本身是 Leatrix 风格的两列选项列表
- **调试**：页面底部的「启用调试控制台」复选框（入口默认隐藏，输入 `/lpext console` 显示；默认关闭，所有功能共用的调试总开关），点右侧齿轮打开二级配置页；执行 Lua、捕获 `print(...)`/`return`、读取客户端优化 CVar 的当前值/默认值/插件配置、输出可复制
- **系统界面**：「隐藏系统图腾栏」勾选即生效；其右侧齿轮是调试入口，仅在启用调试控制台后出现；「显示移动速度」在小地图原生坐标文字后面显示当前速度百分比
- **小地图**：速度文字直接挂在客户端原生坐标（`43.7（39.5）`）右侧，跟着坐标移动、缩放和隐藏
- **组队**：「寻求组队显示玩家区域」在列表每条信息的副本（活动）名后面标出队长/玩家所在区域，已在副本所在地绿色、其他金色；「寻找组队筛选」按玩家区域、职责、职业三个维度过滤列表
- **拾取**：「增强自动拾取」移植自 SpeedyAutoLoot，分格快速拾取，自动跳过需 roll 或装不下的物品
- **物品**：「标记已学会的物品」在商人、拍卖行、公会银行给已学会/已收集的物品染成绿色
- **标记/信号**：「双击快速标记/信号」双击单位执行 ping、默认标记或标记环（可组合），默认 / Alt / Ctrl / Shift 四个双击槽位独立配置，双击空地不触发
- **任务**：「自动设置任务焦点」击杀任务怪或选中任务怪后自动把对应任务设为焦点，齿轮里选择触发方式（需 Questie + QuestieDB 提供目标数据）；「任务 NPC 追踪」把任务 NPC 加入 RareScanner 并随任务状态自动清理（需 Questie + QuestieDB + RareScanner）
- **游戏体验**：常用客户端调整直接作为页面选项——任务物品高亮、扩大血条距离、放大伤害/治疗数字（可调数值的选项点右侧齿轮，在二级设置页里单独调整）
- 齿轮二级页采用 Leatrix `CreatePanel` 的窗口样式（570×370、羊皮纸背景、关闭/重置/帮助/返回/重载按钮）
- 不修改 Leatrix Plus 本身

## 目录结构

```
LeatrixPlusExt/
  LeatrixPlusExt.toc
  Core.lua                 核心：面板识别、导航、选项行、齿轮配置页、诊断
  Modules/
    Debug/
      Debug.lua            调试控制台
    TotemBar/
      TotemBar.lua         隐藏系统图腾栏
    LFGWhere/
      LFGWhere.lua         在寻求组队列表标出队长所在区域
    LFGFilter/
      LFGFilter.lua        寻求组队筛选（区域 / 职责 / 职业）
    QuestFocus/
      QuestFocus.lua       自动设置任务焦点（击杀 / 选中任务怪触发，齿轮里选择）
    SpeedyAutoLoot/
      SpeedyAutoLoot.lua   增强自动拾取（移植自 SpeedyAutoLoot）
    AlreadyKnown/
      AlreadyKnown.lua     给商人/拍卖行/公会银行中已学会的物品染色
    QuickMark/
      QuickMark.lua        双击弹出标记环或发送情境 ping，带设置页
    ClientTweaks/
      ClientTweaks.lua     常用的镜头/战斗 CVar 调整（直接作为页面选项）
    Speed/
      Speed.lua            在小地图原生坐标文字后面显示移动速度
    Quest2RareScanner/
      Locale.lua           任务 NPC 加入 RareScanner：提示文本
      Data.lua             QuestieDB 任务/NPC 数据解析
      Quest2RareScanner.lua 图标 hook、任务日志入口、RareScanner 导入与自动清理
  README.md
```

每个二级功能单独一个目录，互不干扰。新增功能时在 `Modules/` 下建新目录，并在 TOC 中加一行。

## 安装

把 `LeatrixPlusExt` 文件夹放到：

```
World of Warcraft/_forever_/Interface/AddOns/LeatrixPlusExt
```

确保 Leatrix Plus 已安装并启用，然后 `/reload`。

## 使用

- 打开 Leatrix Plus（`/ltp` 或小地图按钮），左侧菜单 → 「扩展功能*」（在 Settings 之前，悬停有提示）
- 菜单项里的 `*` 表示该页由 LeatrixPlusExt 独立提供，不是 Leatrix Plus 自带选项
- 或直接输入 `/lpext`
- `/lpext console`：显示/隐藏「启用调试控制台」入口（默认隐藏，也可以加 `on` / `off` 明确指定）
- `/lpext diag [layout|lfg|lfgfilter|lfgacts|questfocus|q2rs|minimap]`：打开对应的诊断窗口，不带参数时为 Leatrix 接入诊断；
  `minimap`（也可写 `coords`）输出小地图原生坐标元素的结构、文本、字体和锚点，结果可直接整段复制
- `/lpext q2rs`：任务 NPC 追踪的帮助和状态；`/lpext q2rs delete` 删除全部已添加的 NPC，`/lpext q2rs debug` 输出 Q2RS 组/NPC 状态
- `/lpext reset`：弹出确认框；确认后把 LeatrixPlusExt 的所有设置恢复默认值，并重载一次界面——选项开关回到
  注册默认状态，齿轮页数值、任务焦点触发方式、快速标记动作、当前角色的组队筛选条件和调试入口一并重置；
  客户端优化改过的 CVar 会还原成游戏默认值

### 二级配置页（齿轮）

「扩展功能」页使用与 Leatrix Plus 相同的选项列表形式：

- 页面不显示分类标题，所有选项按功能分组后的顺序排成两列（第一列 146、第二列 340），从 y = -72 开始，统一行距 26
- 底部：「启用调试控制台」复选框（y = -282；入口默认隐藏，用 `/lpext console` 显示；默认关闭）；
  功能说明只在鼠标悬停时显示，不在页面上占用一行
- 需要二级配置页的功能，文字右侧紧贴 **齿轮图标**（与官方 `CfgBtn` 相同）
- 复选框未勾选时齿轮为锁定状态（禁用 + 变暗），勾选后才能点击
- 调试控制台是所有功能共用的调试总开关：启用后，带调试入口的功能才会显示并解锁齿轮
- 点击齿轮打开 570×370 的二级配置页，完全沿用 Leatrix `CreatePanel` 的布局：
  - 深色底 + 羊皮纸贴图、`GameFontNormalLarge` 标题、说明文字
  - 右上角关闭，底部「重置」「帮助」「返回主菜单」「重载」四个按钮（位置与官方一致）
  - 有说明文字时内容区从 (16, -72) 开始；说明为空时整行隐藏，内容区上移到 (16, -44)
  - 面板缩放与透明度跟随主面板设置
  - 打开时主面板自动隐藏；返回时回到扩展页

「调试」齿轮里是完整的调试控制台；其他功能的齿轮是调试入口，只有启用调试控制台后才会显示。

### 隐藏系统图腾栏

仅在角色是萨满时显示并生效，「扩展功能」页勾选「隐藏系统图腾栏」后：

- 隐藏系统多图腾动作条 `MultiCastActionBarFrame` 和暴雪图腾计时框 `TotemFrame`；
- 通过 `OnShow` 钩子阻止它们重新显示；
- 设置保存到 `LeatrixPlusExtDB.hideSystemTotemBar`；
- 不影响 TotemTimers 自己的计时按钮和它自己的多图腾按钮；
- 该选项勾选后立即生效；右侧齿轮是调试入口，启用调试控制台后可查看
  `MultiCastActionBarFrame` / `TotemFrame` 的 `shown/visible` 状态。

关闭该开关后，系统图腾栏可能需要 `/reload` 才会恢复。

### 寻求组队显示玩家区域

在「扩展功能」页勾选「寻求组队显示玩家区域」：

- 挂钩暴雪的列表行更新入口，行出现、刷新、复用时立即更新，不做定时轮询；
  面板打开、切换区域时再整体刷新一次；
- 在条目第二行的副本（活动）名称后面显示队长或玩家的当前区域（`areaName`）：
  单人列表显示该玩家位置，队伍人数大于 1 时显示队长位置并带上「队长：」前缀，
  例如「血色军械库　队长：提瑞斯法林地」；
- 按副本所在地判断颜色：队长/玩家位于副本地图或其所在区域（地图链匹配，不含更上级的大陆）时显示为绿色，
  其他情况为金色，方便判断对方是不是已经在副本附近；
- 本客户端的地图数据没有副本地图层（`mapID` 查不到地图信息），因此内置了一份副本 → 所在地
  对照表作为兜底，包含经典副本和《魔兽世界：无限》的 9 个新五人副本、2 个新团本
  （剃刀高地 → 贫瘠之地、克罗多克要塞 → 河林等），地图链与对照表任一命中即算「在副本所在地」；
  完整数据整理见 [docs/副本所在地对照表.md](docs/副本所在地对照表.md)；
- `/lpext diag lfgacts` 可列出游戏内全部组队活动并标注「已收录 / 未收录」，方便核对新副本名称；
- 设置保存到 `LeatrixPlusExtDB.lfgWhere`，默认开启；
- 来源：<https://bbs.nga.cn/read.php?tid=47901480>

### 寻找组队筛选

在「扩展功能」页勾选「寻找组队筛选」后，「寻求组队」浏览页顶部会出现三个筛选控件：

| 维度 | 控件 | 规则 |
| --- | --- | --- |
| 玩家区域 | 下拉框，「区域不限 / 副本附近」单选 | 只看队长/玩家已在副本所在地的队伍（与大绿/金色判断同一套数据）；默认「区域不限」 |
| 玩家职责 | 下拉框，可多选 | 队伍：只显示还缺所选职责的队伍；单人玩家：只显示勾选了所选职责的玩家；勾选多项时**满足任一即可** |
| 玩家职业 | 下拉框，可多选 | 勾选后**不显示已含**该职业的队伍（队长和队员都算）；单人玩家按玩家自己的职业判断；首次使用默认勾选本职业 |

- 三个维度是「且」关系，同时生效；
- 职责筛选对两类列表分开判断：多人队伍看 `GetSearchResultMemberCounts` 的职责空缺数，
  单人玩家（`numMembers == 1`，与客户端自己判定单人列表的方式一致）看该玩家勾选的
  职责（`GetSearchResultPlayerInfo` 的 `lfgRoles`，读不到时退回 `assignedRole`）；
- 职业筛选同样覆盖单人玩家：单人列表直接用该玩家的 `classFilename` 作为职业构成，
  两种来源都读不到时按不满足处理；
- 控件内嵌在原始顶部栏的第二行：对齐「类型」下拉框，挂在原生「类型 / 活动」两个筛选的
  正下方；顶部栏高度自动增加，列表区域整体下移（分隔沿用原始界面：现代样式是
  `groupfinder-ScrollLine` 线和石质顶栏，经典样式是列表面板的上边缘），不是浮在列表上；
  关闭模块会把顶部栏和列表恢复原样；
- 过滤方式与 LFGmore 相同：包装列表数据源的 `GetLinearized` 后再交给暴雪自己的
  滚动/行回收逻辑，标题和分隔行始终保留；
- 三个控件都直接用客户端的原生下拉框模板（`WowStyle1DropdownTemplate`，与「类型 / 活动」同款）：
  外观、高度、箭头、字体、菜单（单选圆点 / 多选勾）全部走原生，不另加背景或改字；
  标题显示简短摘要（如「缺坦/治」「不含3个」）；
- 区域设置全局保存；职责、职业按角色保存（`LeatrixPlusExtDB.lfgFilterArea` /
  `lfgFilterRoles` / `lfgFilterClasses`），模块开关是 `lfgFilter`，默认开启；
- 关闭模块会立即撤掉过滤、还原顶部栏并隐藏三个控件，列表恢复完整；
- `/lpext diag lfgfilter` 可在可复制窗口里查看布局与筛选状态（控件坐标、原界面样式、
  布局位移、缓存条数），布局异常时用它反馈；
- 与 LFGmore（`D:\WorkPlace\WOW\LFGmore`）同时启用时，两者的控件会重叠在同一位置，
  只保留一个即可。

### 增强自动拾取

在「扩展功能」页勾选「增强自动拾取」（默认关闭）：

- 该功能移植自 **SpeedyAutoLoot** 插件（作者 Yuyuli），鼠标悬停在复选框上会提示来源；
- 游戏自动拾取开启时，每 33ms 拾取一格（约 30 格/秒），比暴雪默认节奏更快；
- 达到当前需求/贪婪门槛且仍被锁定的物品不会被自动拾取，留给你自己 roll；
- 拾取前检查背包空间（含钥匙链、材料包和背包类型），装不下的物品不拾取；
- 拾取失败或背包满时自动展开暴雪拾取框；钓鱼战利品会播放收线音效；
- 没有二级配置页，设置保存到 `LeatrixPlusExtDB.speedyAutoLoot`。

未移植的部分：战利品滚动列表（Loot Display）、ElvUI 拾取框接管、自动确认拾取绑定。

启用本模块时不会改写 Leatrix Plus 的「加速自动拾取」（`LeaPlusDB.FasterLooting`），
两边以 Leatrix Plus 的设置为优先，避免两套逻辑同时调用 `LootSlot`：

- 登录/重载时如果该项是 `On`，本模块会保持关闭（如果存档里原本是开启的，会改为关闭并在聊天框提示）；
- 游戏内勾选本模块时如果该项是开启的，勾选会被取消，并提示先到 Leatrix Plus 里关闭它；
- 需要本插件接管时，请先在 Leatrix Plus 里关闭「加速自动拾取」，点击面板底部的「重载」，
  重载后再勾选本功能；
- 如果之后又在 Leatrix Plus 里手动开启它并重载，本模块会再次自动关闭。

这样两个插件的加载顺序不再重要。TOC 使用 `OptionalDeps: Leatrix_Plus` 只是让 Leatrix Plus
（如果启用）先加载，方便初始化时找到它的面板；没有使用 `DependsOn`，所以未安装 Leatrix Plus
时仍然会回退到独立窗口。

### 标记已学会的物品

在「扩展功能」页勾选「标记已学会的物品」（默认开启），然后在商人、拍卖行、公会银行里查看：

- 已学会/已收集的物品图标会染成固定的绿色；
- 判断依据与原 AlreadyKnown 插件一致：物品说明里的「已学会」、宠物/坐骑/玩具收集状态、
  部分容器（火箭配方包）与术士宠物技能书；
- 兼容旧版拍卖行（`Blizzard_AuctionUI`）、新版拍卖行（`Blizzard_AuctionHouseUI`）和公会银行；
- 该功能没有二级配置页，勾选后直接生效。

原 AlreadyKnown 独立插件可以停用，避免两套钩子同时给图标染色。

### 双击快速标记/信号

在「扩展功能」页勾选「双击快速标记/信号」（默认开启）：

- 四个双击槽位，各自独立配置效果：
  - 双击单位：执行「默认双击」所选效果；
  - `Alt` + 双击：执行「Alt + 双击」所选效果；
  - `Ctrl` + 双击：执行「Ctrl + 双击」所选效果；
  - `Shift` + 双击：执行「Shift + 双击」所选效果；
  - 同时按住多个修饰键时按 `Ctrl` > `Alt` > `Shift` 的顺序取效果；
- 可选效果共 5 种：
  - **ping + 默认标记**：发一个情境 ping，并给目标上「默认标记」；
  - **ping**：只发一个情境 ping；
  - **ping + 标记环**：发一个情境 ping，然后打开目标标记环；
  - **默认标记**：直接给目标上「默认标记」；
  - **标记环**：打开目标标记环（8 个标记 + 中心清除全部）；
- 「默认标记」可在设置页单独选择：星形 / 圆圈 / 菱形 / 三角 / 月亮 / 方块 / 十字 / 骷髅（默认骷髅）；
- 双击时会检测「设置选项 → 游戏功能 → 信号系统」的开关（CVar `enablePings`）：若未开启，
  带 ping 的效果自动改用对应的标记效果（ping → 默认标记，ping + 标记环 → 标记环），
  悬停提示和设置页顶部都会给出红色说明；
- 双击空地不触发任何效果：本客户端的 `/wm` 地面光柱不可用，鼠标位置信号也不能由插件发送；
- 双击判定只作用于游戏世界（单位模型、姓名板等）；在队伍/团队框体上双击不会触发；
- 打开标记环后，单击环外、再次双击或 8 秒后自动关闭；战斗中不响应；
- 所有按钮都是安全动作按钮，通过 `/tm`、`/ping` 宏执行，不会触发“受保护函数”报错；
- 设置保存在 `LeatrixPlusExtDB.quickMarkOptions`，开关本身保存在 `LeatrixPlusExtDB.quickMark`。

右侧齿轮打开设置页，五个下拉菜单单列从上往下排列：

- **默认双击**：5 种效果（默认 `ping`；系统信号未开启时自动改用默认标记）；
- **Alt + 双击**：5 种效果（默认「标记环」）；
- **Ctrl + 双击**：5 种效果（默认「默认标记」）；
- **Shift + 双击**：5 种效果（默认「ping + 默认标记」）；
- **默认标记**：星形 / 圆圈 / 菱形 / 三角 / 月亮 / 方块 / 十字 / 骷髅（默认骷髅）。

信号相关说明：

- 信号在**单人模式下自己也能看到**（实测），不需要组队即可测试；
- 信号系统开关以 CVar `enablePings` 为准（关闭时读到 `0`）；本客户端的
  `C_Ping.IsPingSystemEnabled()` 在关闭后仍返回 `true`，不能用来判断；
- 本客户端的 `/ping` **不区分信号类型**：实测 `Assist` / `Attack` / `OnMyWay` / `Warning`
  产出的都是同一种按目标关系决定的默认信号，所以设置页不提供类型选择，
  也不提供 4 方向信号盘（各方向效果完全相同，只会误导）；
- 带 ping / 默认标记的效果分两路执行，宏只在**第一次按下**时拼装一次，两路用的是同一份：
  1. **硬件点击**：第一次点击抬起后，先把 `mouseover` 锁成 `target`，再把隐藏的安全按钮
     移到光标下并启用鼠标，让第二次物理点击直接落在按钮上，由客户端自己执行
     `/ping [@target] <类型>`（带默认标记时再追加 `/tm N`）；
  2. **捕获补发**：原地双击时光标焦点常被缓存，按钮可能收不到第二次点击。若第二次按下
     仍由世界捕获框收到，就直接对同一个按钮调用 `button.Click()` 执行同一份宏，并立刻
     收起按钮，避免这次点击的抬起又触发一次。客户端是否接受这路补发由调试输出确认；
- 目标必须**在按钮启用之前**锁定：按钮一旦压在光标下，客户端就认为鼠标停在界面上，
  `mouseover` 不再指向世界里的单位，宏里的 `/target mouseover` 会落空；
- `/ping` 必须带类型参数才会发送；只写 `/ping [@target]` 时客户端只会切换信号监听，
  不会发出任何信号（类型仍然不区分效果）；
- 标记首先走宏：第二次点击落在硬件按钮上时，按钮宏里的 `/tm N` 会真实执行
  （`/tm` 是受保护动作，只有硬件点击才执行）。执行后若 `GetRaidTargetIndex` 仍为空，
  再用 `SetRaidTarget` 在 Lua 里补发一次；
- 安全按钮的属性是**按修饰键**查找的（`ctrl-type1`、`alt-macrotext1`……）。只设 `type1`/`macrotext1`
  时，按住 Ctrl/Alt/Shift 的点击找不到属性，整条宏都不会执行 —— 所以按钮同时设了不带后缀的
  `type`/`macrotext` 作为兜底；
- 标记的单位按 **第一次按下时的 GUID** 找回，而不是直接标当前 `target`：第二次点击时
  隐藏按钮压在光标下，`mouseover` 可能是空的；`target` 也可能还停在旧单位上，直接标会标错人；
- 标记环效果不占按钮：第二次点击即使没落在按钮上，仍会正常打开标记环；
- 「默认标记」同样走这个按钮的宏，保证与 ping 在同一次硬件点击里完成；
- 插件通过 `/ping` 发出的信号只能指向单位，需要队伍或团队；非队长/助理在团队中可能受限制，
  且有防刷屏冷却；
- 双击**不能**唤起游戏自带的信号轮盘，也**不能**发送光标位置的地面信号。原生信号键是按键绑定
  `TOGGLEPINGLISTENER`（本机绑定 `H`），采用“按住”语义；
- 该链路对插件完全封闭，实测证据：
  - `PingListenerFrame` / `PingFrame` 属于 `Blizzard_PingUI`，对插件是“禁止访问对象”
    （`Attempt to access forbidden object from code tainted by an AddOn`）；
  - `C_Ping.SendMacroPing` 无论传什么参数都只返回 `true` 而无任何效果；
  - 从插件调用 `RunBinding("TOGGLEPINGLISTENER")` 同样无效；
  - 挂钩替换 `C_Ping.TogglePingListener` 会让按键绑定经过插件代码，导致玩家按 H 也失效；
- 双击相关的功能在战斗中不可用（标记动作本身仍可通过动作条上的 `/tm` 宏在战斗中使用）。

### 自动设置任务焦点

在「扩展功能」页勾选「自动设置任务焦点」（默认关闭）后，右侧齿轮里有两项触发方式，可多选：

- **击杀任务怪后设置焦点**（默认勾选）：击杀任务怪后自动把对应任务设为焦点；
- **选中任务怪后设置焦点**（默认不勾选）：选中可攻击的任务怪时提前把对应任务设为焦点，
  适合跑图找怪的阶段。尸体、玩家和友方 NPC 不触发。

战斗中也直接切换，没有额外开关。只有客户端在战斗中拒绝切换（接口报错或静默忽略）时，
才会记下最新的一只任务怪，等脱战（`PLAYER_REGEN_ENABLED`）后重试一次；重试时会重新按当前
任务日志和焦点判断，所以延迟期间任务已完成或已交付也不会再设焦点。

装了 Questie 时还有一点：Questie 的焦点接口（`TrackerUtils:FocusQuest`）在设焦点前要刷新
任务日志和地图数据，战斗里可能判定失败；这时会先切原生超级追踪，把任务记下来，
脱战后自动补一次 Questie 焦点同步（Questie 的追踪器本来也只在脱战后重排）。战斗中的
地图图标淡出也一并推迟到脱战后，避免战斗中反复淡入淡出。

触发后会把已接任务设为任务追踪/地图上的焦点，效果与任务日志里右键「设为焦点」相同：

- 击杀通过 `PARTY_KILL` 事件识别，队伍成员击杀也算；NPC ID 优先由
  `C_CreatureInfo.GetCreatureID` 读取，读不到时退回解析 GUID 第 6 段；
- 选中目标通过 `PLAYER_TARGET_CHANGED` 识别，同样解析目标 GUID 得到 NPC ID；
- 「任务 → 目标 NPC」的对应关系取自 **QuestieDB**（`LibQuestieDB`），覆盖击杀目标、
  任务物品的掉落怪（`objectives[3]` + `Item.npcDrops`）、`killCredits` 以及
  `extraObjectives` 里的怪物引用；给予任务与交任务的 NPC 会被排除；
- 只处理任务日志里**已接且未完成**的任务，已完成的任务不会被重新设为焦点；
- 同一只怪对应多个任务时：当前焦点如果仍是其中之一就保持不变（不打断你手动选的焦点），
  否则选日志里第一个未完成的任务；
- 焦点优先通过 **Questie 的焦点接口**（`TrackerUtils:FocusQuest`，与 Questie 追踪器里右键
  「设为焦点」完全一致）设置，同时同步原生超级追踪、Questie 追踪器和地图图标淡出；
  Questie 不在、任务数据不足或接口拒绝时退回原生 `C_SuperTrack.SetSuperTrackedQuestID`。
  之所以要同步 Questie：Questie 会隐藏暴雪任务追踪器，而它自己的追踪器默认不跟随原生超级追踪，
  只调原生接口时 Questie 界面看不到变化；
- 任务日志变化（接/交/删任务）、重载和 QuestieDB 加载后会自动重建缓存；
- **需要安装 Questie + QuestieDB**，没有时功能不生效（开关仍可勾选，仅记录设置）；
- 输入 `/lpext diag questfocus` 打开诊断窗口：当前焦点、触发方式、
  当前是否在战斗、待脱战重试的任务怪、待补同步的 Questie 焦点、超级追踪接口是否可用、
  QuestieDB 是否加载、Questie 焦点接口是否可用（并显示它最近一次的报错）、
  日志中未完成任务数、
  识别到的任务怪 NPC 数量、本次登录切换次数；还会列出**上一次触发（击杀 / 选中目标）的完整判定**：
  目标名字与 GUID、解析出的 NPC ID、是否玩家/尸体/可攻击、对应任务及完成情况、最终结果
  （未勾选、没有映射任务、当前焦点已是候选任务、客户端拒绝切换等）。调试开关问题时先选中任务怪，
  再执行这条命令即可看清卡在哪一步。

设置保存到 `LeatrixPlusExtDB.questFocusOnKill`（总开关）和
`LeatrixPlusExtDB.questFocusOptions`（`kill` / `target`）。

### 任务 NPC 追踪（加入 RareScanner）

在「扩展功能」页勾选「任务 NPC 追踪」（默认开启，移植自 Quest2RareScanner 插件）：

- 世界地图上 **Alt+左键点击 Questie 图标**，把图标对应的任务 NPC 加入 RareScanner 的自定义 NPC 列表：
  NPC 放进 `Q2RS_<任务ID>` 组，手动标记进 `Q2RS_手动`；
- 任务日志详情面板右上角会出现骷髅按钮，点开可以按「击杀 / 掉落目标」「任务交付」分类勾选后批量加入；
- 任务状态变化时自动清理：接任务后移除不再需要的任务给予者，任务可交付后只保留交付 NPC，
  交付或放弃后删除整组；删除掉的 NPC 会临时过滤，立即隐藏 RareScanner 的地图图标；
- NPC 名称、刷新点和交货人取自 **QuestieDB**，坐标由 Questie 的 ZoneDB 换算，
  导入通过 RareScanner 的 `import` 命令完成；
- 小地图按钮：左键删除所有 `Q2RS_` 组（有确认框），右键查看帮助和状态，拖动调整位置；
- `/lpext q2rs` 查看帮助和状态，`/lpext q2rs delete` 删除全部已添加的 NPC，
  `/lpext q2rs debug` 输出 Q2RS 组 / NPC 状态，`/lpext diag q2rs` 打开状态诊断窗口；
- 需要 **Questie + QuestieDB + RareScanner**；缺少依赖时开关仍可勾选，但功能不会工作；
- 开关保存在 `LeatrixPlusExtDB.quest2RareScanner`，运行数据（小地图角度、临时过滤记录）
  在 `LeatrixPlusExtDB.quest2RareScannerData`；
- **请停用独立的 Quest2RareScanner 插件**：两者会同时挂钩 Questie 图标、同时处理同一批
  `Q2RS_` 组，只能保留一个。首次登录检测到独立版存档时，会把 `minimapAngle` /
  `autoFiltered` 迁移到本插件并自动勾选本模块；迁移用的 `Quest2RareScannerDB`
  声明确认无用后可以从 TOC 移除。

### 客户端优化

这些选项直接排在「扩展功能」页里，按「画面 → 战斗」的顺序排布。每一项都对应一条常用
`/console` 设置，关闭该项时优先把对应的 CVar 还原成客户端的系统默认值
（`GetCVarDefault` / `C_CVar.GetCVarDefault`）；姓名板距离的客户端默认值与实际效果不符，
固定还原成 20 码，其余项在客户端不提供接口时用下表的兜底值。

| 选项 | 作用 | CVar | 可选数值（本插件开启时） | 游戏默认 |
| --- | --- | --- | --- | --- |
| 任务物品高亮 | 任务物品闪光 | `outlineModeShowLootEffectWhenDisabled 1` | — | 0（不闪光） |
| 扩大血条显示距离 | 姓名板显示距离 | `nameplateMaxDistance` | 齿轮页 20 - 41 码（开启时 41） | 20 |
| 放大伤害/治疗数字 | 浮动战斗数字缩放 | `WorldTextScale` / `WorldTextScale_v2` | 齿轮页 1 - 5（开启时 3） | 1 |

- 旧版本的「TAB 切换目标距离」已移除：本 Camelot 客户端没有
  `targetNearestDistance` / `targetNearestDistanceRadius`（`GetCVar`、`GetCVarDefault`、
  `C_CVar.GetCVarInfo` 都返回 `nil`，`SetCVar` 也返回 `nil`），写入不会生效；
- 「放大伤害/治疗数字」在加载时只保留客户端真实存在的 CVar：本 Camelot 客户端是
  `WorldTextScale_v2`（`WorldTextScale` 不存在），关闭时也只还原这一个；
- 「超远视野」和「关闭灵魂状态灰色界面」由 Leatrix Plus 自带的 System 页选项提供
  （Max camera zoom / Disable screen effects），本插件不再重复。Leatrix Plus 的
  「Max camera zoom」会把 `cameraDistanceMaxZoomFactor` 设成 `2.6`，与 Forever 控制台
  指南给出的安全上限一致（默认 `1.9`；`3.34` / `4.0` 只是玩家反馈，客户端可能自行压低）；
- 两个可调数值的选项右侧都有齿轮，点开进入各自的二级设置页，用滑条（或鼠标滚轮）单独调整；
- 齿轮页里的「重置」会把数值恢复成开启时使用的默认值，并回到该选项的默认开关状态；
- 本插件改过的 CVar 和修改前的原值记录在 `LeatrixPlusExtDB.cvarBackups`，重启或重载后依然会还原；
  只有这份记录里有的 CVar 才会被还原，玩家自己改过、但本插件没动过的设置不会被重置；
- 单独关闭某一项时只还原那一项的 CVar；
- 姓名板距离按实际效果取值：游戏自带选项默认 20、上限 41；`nameplateMaxDistance`
  虽然能写入 45 或 60（`GetCVarDefault` 也报 45），但超过 41 后画面上的距离不再变化，
  实测无效。因此插件滑条使用 20-41，关闭时强制还原成 20（不采用客户端报的 45）；
  旧存档里超出 20-41 的数值会自动改回 41；
- 滑条允许调到 20，是为了覆盖游戏原生的整段范围；插件开启时的默认值仍是最远的 41 码；
- 「扩大血条显示距离」关闭或调小距离会立即生效；调大距离后，远处已经被移除的姓名板
  不会马上回来，需要重载界面（或重新登录）让客户端重新创建（客户端只在创建姓名板时
  读取距离）。进入世界后客户端可能重新套用 `Config.wtf` 里的值，插件会在登录、切换地图
  和重载后 1 秒再写一次；
- 部分客户端另有 `nameplatePlayerMaxDistance`，单独限制玩家姓名板的距离；「CVar 探测」
  会显示它是否存在以及当前值；
- 「放大伤害/治疗数字」勾选或调整后立即生效，不需要重载或登出；
- 「任务物品高亮」不会改动轮廓（描边）设置；轮廓模式开着时任务物品显示轮廓而不是闪光。
  关闭后需要登出再登录（不是 `/reload`），不必重启游戏，闪光才会完全消失；切换画质预设可能把这 CVar 重置为 0，
  插件开启期间会在登录时以及画质变化后自动写回；
- 部分设置可能需要重载界面才能完全生效，二级配置页底部有「重载」按钮。

外部参考资料（都是 Interface 16001 / Forever）：

- [BleakfibersUnitToggles-Forever](https://github.com/Bleakfiber/BleakfibersUnitToggles-Forever)：
  这个同版本插件的 `Config.lua` 使用 20 个 `UnitName*` CVar（单位姓名、宠物/图腾名字、
  公会名等）。只参考 CVar 名称，不复制它的代码；
- [WoW Forever 控制台命令与镜头距离](https://botwowforever.com/zh/guides/wow-forever-console-commands-camera-distance)：
  列出 `cameraDistanceMaxZoomFactor`（默认 1.9，安全上限 2.6）、`nameplateMaxVerticalDistance`
  等命令。「CVar 探测」按钮会顺便检查这两份资料里列出的 CVar 在本客户端是否存在。

### 小地图坐标后显示移动速度

开启「显示移动速度」后，当前速度百分比显示在小地图下方原生坐标文字的右侧，
例如 `43.7（39.5） 100%`：

- 速度文字是 `MinimapCluster.MinimapContainer.PlayerCoords` 的子 FontString，
  字体、颜色、缩放沿用坐标文字；
- 每次刷新按坐标文字宽度重新贴到它右侧；坐标被客户端隐藏时一起隐藏；
- 每 0.2 秒刷新一次；Camelot 客户端的速度是机密数值，只能用
  `AbbreviateNumbers` 缩放成百分比，不做任何比较和算术；
- 默认开启，切换后立即生效，不需要重载。

### 调试控制台

调试控制台入口默认隐藏。先输入 `/lpext console` 显示页面底部的「启用调试控制台」，
勾选后点右侧齿轮进入二级配置页（再次输入 `/lpext console off` 可以隐藏入口）。

1. 在「Lua 命令」输入框输入代码，例如：

```lua
print(GetLocale())
return UnitName("player")
```

2. 按回车或点「执行」。
3. 输出显示在下方；点「全选复制」后按 `Ctrl+C`。
4. 快捷按钮：
   - **3 秒取鼠标元素**：点击后 3 秒内把鼠标移到目标上，输出它的 frame 链。
   - **读取配置项**：列出客户端优化涉及的 CVar（`outlineModeShowLootEffectWhenDisabled`、`nameplateMaxDistance`、
     `WorldTextScale` / `WorldTextScale_v2`），
     每项显示系统当前值、系统默认值、插件备份值以及插件开关/数值；
     功能开启但系统值与插件设置不同会标注「与插件设置不一致」；客户端有这项设置但读不到值时
     标注「客户端读不到，无法核对」，并附上各接口的失败原因（返回 nil / 机密值 / 调用报错）；
     客户端没有这项设置时直接显示「客户端没有这个设置」（依据 `C_CVar.GetCVarInfo` 返回 `nil`）；
     浮点默认值会去掉末尾多余的 0（如 `45.000000` 显示为 `45`）。
   - **CVar 探测**：判断插件用到的 CVar 在当前客户端是否真的存在。依次记录
     `GetCVar` / `C_CVar.GetCVar` / `GetCVarDefault` / `C_CVar.GetCVarDefault` /
     `C_CVar.GetCVarInfo` 的返回结果，并对存在的 `nameplateMaxDistance` 做一次
     「写回当前值」测试（不会改变游戏设置）。末尾给出插件用到的 CVar 是否存在的小结；
     另外检查参考资料里列出的 `cameraDistanceMaxZoomFactor`、`nameplateMaxVerticalDistance`
     和 20 个 `UnitName*`。
     客户端有 `C_Console.GetAllCommands` 时还会显示注册的 CVar / 命令总数。
     要列出全部名称，可在 Lua 命令框执行：
     `local t={} for _,v in pairs(C_Console.GetAllCommands()) do t[#t+1]=v.command end table.sort(t) return table.concat(t,"\n")`
   - **清空输出** / **全选复制**

## 实现方式

Leatrix Plus 没有公开扩展 API，`LeaPlusLC` 是本地变量；本客户端也没有 `debug` 库，无法读取闭包 upvalue。

LeatrixPlusExt 改为**运行时识别 UI**：

1. 优先使用旧版全局 `_G.LeaPlusGlobalPanel`，否则在 `UIParent` 子 frame 中按标题 `Leatrix Plus` 识别主面板；
2. 找到面板左侧的导航按钮（`TOPLEFT`、x=16 的 Button）；
3. 参考 Dreadful 插件：只把最后两个导航下移 10px，在 Settings 之前插入「扩展功能*」导航；
4. 创建一个与主面板同尺寸的扩展页；
5. 原有页面或搜索结果 `OnShow` 时隐藏扩展页；点击扩展导航时隐藏原有整页 frame；
6. 打开扩展页时顺便隐藏 Leatrix 的侧边配置面板。

TOC 对 Leatrix Plus 只声明 `OptionalDeps`（如果启用则先加载，方便找到主面板），不声明 `DependsOn`，
因此客户端不会弹「缺少依赖」，未安装或未启用时仍由插件自己在登录后判断并在聊天框提示：

- 未安装或未启用 Leatrix Plus → 「未检测到 Leatrix Plus（未安装或未启用），已使用独立窗口」；
- 已加载但找不到主面板 → 「已加载 Leatrix Plus，但没有找到它的主面板，已使用独立窗口」。

两种情况都会回退到**独立窗口**，调试控制台（需先用 `/lpext console` 显示入口）和隐藏图腾栏功能仍然可用。

**不会修改 Leatrix Plus 文件。**

## 接入失败排查

如果 `/lpext` 提示“扩展页尚未就绪”：

1. 确认 **Leatrix Plus 已安装并且在插件列表中启用**；
2. 执行：

```text
/lpext diag
```

会打开一个可复制的诊断窗口，包含：

- `UIParent` 子 frame 数量
- 是否找到标题含 `Leatrix Plus` 的主面板
- 面板名字、尺寸
- 找到的导航按钮数量与每个按钮的 y 坐标
- 整页 frame 数量
- 扩展页是否就绪

点「全选（Ctrl+C）」复制后反馈即可定位。

## 更新记录

- **0.1.0**：首个公开基准版本。
  - 在 Leatrix Plus 左侧菜单新增「扩展功能*」页（`*` 表示由本插件独立提供），
    提供调试控制台、隐藏系统图腾栏、寻求组队位置、寻求组队筛选、增强自动拾取、已学会物品标记、
    双击快速标记/信号，以及任务物品高亮、血条距离、伤害数字缩放等客户端优化选项；
  - 可调数值的客户端优化项（血条距离、伤害数字缩放）各自带齿轮二级设置页，
    用滑条单独调整；
  - 「双击快速标记/信号」支持 ping、默认标记、标记环及其组合效果，默认 / Alt / Ctrl / Shift
    四个双击槽位独立配置，标记单位按第一次按下时的 GUID 找回；
  - 「调试控制台」支持执行 Lua、捕获 print 输出；入口默认隐藏，输入 `/lpext console` 显示。

## 添加新的功能

每个功能注册为「主页复选框 + 可选齿轮二级页」：

```lua
NS.RegisterModule({
    key = "myFeature",              -- SavedVariables 字段名
    section = "我的功能",            -- 内部分组/二级页标题的兜底，页面不显示
    label = "启用我的功能",          -- 复选框文字
    tip = "勾选后点击右侧齿轮配置。", -- 复选框悬停提示
    default = false,                -- 默认关闭
    -- bottomRow = true,            -- 可选：放到页面底部（Social 页样式）
    -- gearRequiresDebug = true,    -- 可选：齿轮改为跟随「启用调试控制台」开关
    -- isVisible = function()       -- 可选：返回 false 时隐藏整行入口（调试控制台用这个默认隐藏）
    --     return true
    -- end,
    panelTitle = "我的功能",         -- 齿轮二级页标题
    panelDesc = "这里是说明。",      -- 齿轮二级页说明
    buildPanel = function(parent, panel)
        -- parent 是二级页内容区，坐标相对左上角 (0, 0)
        -- 与官方配置面板一致：左下为「重置/帮助/返回/重载」，内容从 (0, 0) 开始
    end,
    onToggle = function(enabled)
        -- 复选框状态变化时执行
    end,
    reset = function(panel)
        -- 二级页「重置」按钮
    end,
})
```

- 页面不显示分类标题；选项排成两列（第一列 146，第二列 340），从 y=-72 开始，统一行距 26；
  选项按功能分组（`Core.lua` 的 `MODULE_GROUPS`：任务、组队、拾取与物品、界面、战斗与画面），
  同组入口连续排列，组与组之间也保持同样行距；上一组只占左半格时下一组直接补满，
  避免右侧空出一格；未列进分组的新模块接在最后；
- 标记 `bottomRow = true` 的功能放到页面底部（y=-282，两个一列），与官方 Social 页的底部选项一致；
- 需要让玩家自定义数值时，把控件放进 `buildPanel` 的二级页里（参考 `ClientTweaks.lua` 的
  `CreateValuePanel`：Leatrix `LeaPlusConfigurationPanelSliderTemplate` 滑条 + 数值显示 + 范围提示）；
  数值存入 `LeatrixPlusExtDB`，功能启用时立即写入 CVar，关闭时还原系统默认值；
- 复选框未勾选时齿轮会按官方规则禁用并变暗；标记 `gearRequiresDebug = true` 的齿轮改为跟随调试控制台开关；
- 提供 `isVisible` 且返回 `false` 时，整行入口（复选框和齿轮）会隐藏，且不占位置（后面的选项自动补上来）；入口是否显示与功能本身是否启用无关；
- 齿轮二级页使用 Leatrix `CreatePanel` 的配置面板样式；
- 页面已经构建后再注册也会立即追加一行。

## 构建与发布

推送 `v*` 或数字开头的标签（例如 `v0.2.0`）时，GitHub Actions 会自动构建并创建 Release：

- `.github/workflows/release.yml`：监听标签推送，先按标签校验版本号并写入 `.toc` 的 `## Version:`，
  再构建、压缩、上传到同名 Release，最后把版本号提交回默认分支；
- `.github/scripts/build-release.js`：只收集 `.toc` 和 `.lua` 文件，删除每个 Lua 文件里的注释
  （字符串中的 `--`、长字符串内容保持不变），输出到 `dist/LeatrixPlusExt/`；
- Release 附件名为 `LeatrixPlusExt-<版本>.zip`（标签去掉开头的 `v`，例如 `v0.2.0` → `LeatrixPlusExt-0.2.0.zip`），
  解压后是 `LeatrixPlusExt/` 文件夹，可直接放进 `Interface/AddOns`；
- 本地预览构建结果：`node .github/scripts/build-release.js`，输出在 `dist/`（已在 `.gitignore` 中忽略）。

## 限制

- 依赖 Leatrix Plus 的内部实现；如果上游大改菜单结构，兼容层可能需要更新。
- 控制台运行在插件环境中，不能调用受保护函数（如施法、移动、受保护 UI 操作）。
- 最后一次输入的命令保存在 `LeatrixPlusExtDB.lastCommand`。
- Leatrix Plus 自带的选项搜索只索引它自己的选项表，扩展页无法加入搜索结果（不修改 Leatrix 的前提下）。
- 齿轮的锁定状态与官方一致：选项关闭时禁用并变暗，必须先勾选才能打开二级页；
  调试入口（图腾栏）例外，它跟随「启用调试控制台」开关显示与解锁。
