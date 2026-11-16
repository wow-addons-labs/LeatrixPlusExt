-----------------------------------------------------------------------
-- LeatrixPlusExt：任务 NPC 加入 RareScanner（Locale）
-- 移植自 Quest2RareScanner 插件
-----------------------------------------------------------------------

local addonName, NS = ...

local L = {
    HELP_TITLE = "任务 NPC 加入 RareScanner",
    HELP_MAP = "世界地图：Alt+左键点击 Questie 图标，把对应 NPC 加入 RareScanner。",
    HELP_GROUP = "加入的 NPC 会按任务分组，方便在 RareScanner 里管理。",
    HELP_CMD = "/lpext q2rs - 显示帮助和状态；/lpext q2rs delete - 删除所有已添加的 NPC",
    RECENTLY_SEEN_HINT = "提示：删除后图标可能还会短暂显示，等一会或 /reload 即可。",
    IMPORTED = "已添加 %d 个 NPC 到 RareScanner：",
    NO_RARESCANNER = "RareScanner 未加载，无法加入追踪。",
    IMPORT_ERROR = "导入失败，请 /reload 后重试。",
    STATUS = "Questie：%s | RareScanner：%s | 地图图标：%s | 坐标：%s",
    READY = "就绪",
    NOT_READY = "未就绪",
    ALT_HINT = "Alt+左键：加入 RareScanner",
    POS_PATROL = "巡逻 %d 条路径",
    POS_MULTI = "已知 %d 个刷新地点",
    POS_FIXED = "固定单点",
    POS_UNKNOWN = "位置未知",
    LOAD_ERROR_QUESTIE = "需要安装 Questie，当前未加载。",
    LOAD_ERROR_DB = "Questie 数据未加载，无法读取 NPC 信息。",
    ZONE_NOT_READY = "Questie 地图数据未加载，坐标可能不完整。",
    HOOK_ERROR = "无法在 Questie 地图图标上添加功能入口，请更新 Questie 后再试。",
    BUTTON_TITLE = "任务 NPC 加入 RareScanner",
    BUTTON_LEFT = "左键：删除所有已添加的 NPC",
    BUTTON_RIGHT = "右键：帮助/状态",
    BUTTON_DRAG = "拖动：调整位置",
    BUTTON_COUNT = "当前：%d 个 NPC，%d 个组",
    DELETE_CONFIRM = "删除「任务 NPC 加入 RareScanner」添加的所有 NPC？\n\n%d 个 NPC，%d 个组。",
    DELETE_NONE = "没有找到已添加的 NPC，无需删除。",
    DELETE_IN_COMBAT = "战斗中不能删除，请脱离战斗后再试。",
    DELETE_NO_RARESCANNER = "RareScanner 未加载，无法删除。",
    DELETE_DONE = "已删除 %d 个组（原来 %d 个 NPC）。",
    DELETE_PARTIAL = "部分 NPC 未能立即从 RareScanner 移除，请 /reload 后确认是否已移除。",
    DELETE_FAILED = "删除失败：%s",
    REFRESHING = "正在刷新 RareScanner 地图图标…",
    AUTO_REMOVED = "任务「%s」：自动移除 %d 个追踪 NPC%s。",
    AUTO_KEPT = "（保留任务交付 NPC %d 个）",
    AUTO_GIVERS_REMOVED = "任务「%s」：自动移除 %d 个任务给予者。",
    AUTO_GROUP_REMOVED = "任务「%s」：已移除整组（%d 个 NPC）。",
    START_ITEM_CLEANED = "任务「%s」：已移除 %d 个起始物品的掉落怪。",
    LOG_NO_QUEST = "这个任务已经不在任务日志里。",
    LOG_NO_NPCS = "这个任务没有可加入的 NPC。",
    LOG_ADD_IN_COMBAT = "战斗中不能加入追踪，请脱离战斗后再试。",
    QUEST_LOG_ADDED = "任务「%s」：已添加 %d 个 NPC（击杀 / 掉落目标 %d，任务交付 %d）。",
    CLEANUP_RELOAD = "部分 NPC 未能立即从 RareScanner 移除，请 /reload 后确认是否已移除。",
}

NS.Q2RSLocale = L
