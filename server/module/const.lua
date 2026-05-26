-- const: 游戏常量定义

local M = {}

-- 错误码
M.ERROR = {
	OK = 0,
	FAIL = 1,
	ACCOUNT_NOT_EXIST = 1001,
	WRONG_PASSWORD = 1002,
	ACCOUNT_EXISTS = 1003,
	PLAYER_NOT_FOUND = 2001,
	SCENE_FULL = 3001,
}

-- 消息ID
M.MSG = {
	C_LOGIN = 1,
	C_REGISTER = 2,
	C_ENTER_SCENE = 10,
	C_MOVE = 11,
	C_CHAT = 20,

	S_LOGIN_OK = 1,
	S_ERROR = 2,
	S_SCENE_ENTER = 10,
	S_SCENE_LEAVE = 11,
	S_CHAT = 20,
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

return M
