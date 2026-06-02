-- const: 游戏常量定义

local M = {}

-- 错误码
M.ERROR = {
	-- 通用
	OK = 0,
	FAIL = 1,
	MISSING_PARAMS = 2,
	SERVICE_UNAVAILABLE = 3,
	UNAUTHORIZED = 4,
	UNKNOWN_CMD = 5,

	-- 账号
	ACCOUNT_NOT_EXIST = 1001,
	WRONG_PASSWORD = 1002,
	ACCOUNT_EXISTS = 1003,
	REGISTER_FAILED = 1004,
	LOGIN_FAILED = 1005,

	-- 玩家
	PLAYER_NOT_FOUND = 2001,

	-- 场景
	SCENE_FULL = 3006,

	-- 背包/物品
	ITEM_NOT_FOUND = 3001,
	ITEM_NOT_ENOUGH = 3002,
	BACKPACK_FULL = 3003,
	INVALID_ITEM_TYPE = 3004,
	CANNOT_USE_ITEM = 3005,

	-- 聊天
	CHAT_TOO_FAST = 4001,
	PLAYER_OFFLINE = 4002,
	MSG_TOO_LONG = 4003,

	-- 排行榜
	INVALID_BOARD_TYPE = 5001,
}


-- 玩家状态
M.PLAYER_STATUS = {
	OFFLINE = 0,
	ONLINE = 1,
	IN_BATTLE = 2,
}

-- 场景类型
M.SCENE_TYPE = {
	SAFE = 1,     -- 安全区
	FIELD = 2,    -- 野外
	DUNGEON = 3,  -- 副本
}

-- 聊天频道
M.CHAT_CHANNEL = {
	WORLD  = 1,
	SYSTEM = 2,
	PRIVATE = 3,
}

-- 排行榜类型
M.LEADERBOARD_TYPE = {
	LEVEL   = "level",
	GOLD    = "gold",
	DIAMOND = "diamond",
}

return M
