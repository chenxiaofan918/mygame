-- login: 登录注册服务
-- 账号/玩家数据: MongoDB, 令牌/在线状态/限流: Redis
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local crypt = require "skynet.crypt"
local const = require "const"

local DB = ".redisproxy"     -- Redis 操作
local MONGO = ".mongoproxy"  -- MongoDB 操作

local CMD = {}

-- 速率限制（5 分钟内最多 5 次失败）
local RATE_LIMIT_MAX = 5
local RATE_LIMIT_WINDOW = 300

local function check_ratelimit(key)
	local count = skynet.call(DB, "lua", "get_int", "ratelimit:" .. key)
	if count >= RATE_LIMIT_MAX then
		return false
	end
	return true
end

local function incr_ratelimit(key)
	skynet.call(DB, "lua", "call", "INCR", "ratelimit:" .. key)
	skynet.call(DB, "lua", "call", "EXPIRE", "ratelimit:" .. key, RATE_LIMIT_WINDOW)
end

local function reset_ratelimit(key)
	skynet.call(DB, "lua", "call", "del", "ratelimit:" .. key)
end

-- 密码加盐哈希（迭代 SHA1，100 轮，防暴力破解）
local HASH_ITERATIONS = 100

local function hash_password(salt, password)
	local h = crypt.sha1(password)
	for i = 1, HASH_ITERATIONS do
		h = crypt.sha1(h .. salt .. tostring(i))
	end
	return crypt.hexencode(h)
end

local function make_salt()
	return crypt.hexencode(crypt.sha1(tostring(skynet.now()) .. tostring(math.random()) .. tostring(math.random(1, 999999))))
end

-- 生成登录 token（使用加密安全随机数）
local function make_token(player_id)
	local random_part = crypt.randomkey(16)
	local str = tostring(player_id) .. tostring(skynet.now()) .. random_part
	return crypt.base64encode(crypt.sha1(str)):sub(1, 32)
end

-- 注册账号
function CMD.register(account, password)
	if not account or #account < 3 then
		return { ok = false, err = "account too short", errcode = const.ERROR.FAIL }
	end
	if not password or #password < 6 then
		return { ok = false, err = "password too short", errcode = const.ERROR.FAIL }
	end

	if not check_ratelimit("reg:" .. account) then
		return { ok = false, err = "too many attempts, try later", errcode = const.ERROR.FAIL }
	end
	incr_ratelimit("reg:" .. account)

	-- 检查账号是否已存在
	local existing = skynet.call(MONGO, "lua", "mongo.find_one", "account", { account = account })
	if existing then
		return { ok = false, err = "account already exists", errcode = const.ERROR.ACCOUNT_EXISTS }
	end

	-- 生成 player_id（Redis 自增）
	local player_id = skynet.call(DB, "lua", "gen_id", "player:id")

	-- 密码哈希
	local salt = make_salt()
	local pwhash = hash_password(salt, password)
	local now = os.time()

	-- 创建账号文档
	local account_result = skynet.call(MONGO, "lua", "mongo.insert_safe", "account", {
		player_id = player_id,
		account = account,
		password = pwhash,
		salt = salt,
		created_at = now,
	})
	if not account_result or account_result.badresult then
		return { ok = false, err = "db error: create account failed", errcode = const.ERROR.FAIL }
	end

	-- 创建玩家数据文档
	local player_result = skynet.call(MONGO, "lua", "mongo.insert_safe", "player", {
		player_id = player_id,
		nickname = account,
		level = 1,
		exp = 0,
		vip_level = 0,
		gold = 0,
		diamond = 0,
		created_at = now,
		updated_at = now,
	})
	if not player_result or player_result.badresult then
		-- 回滚：删除已创建的账号
		skynet.call(MONGO, "lua", "mongo.delete_one", "account", { player_id = player_id })
		skynet.error("[login] register rollback account " .. player_id .. " for player creation failure")
		return { ok = false, err = "db error: create player failed", errcode = const.ERROR.FAIL }
	end

	skynet.error("[login] new account: " .. account .. " -> player_id: " .. player_id)
	return { ok = true, player_id = player_id }
end

-- 登录
function CMD.login(account, password)
	if not check_ratelimit("login:" .. account) then
		return { ok = false, err = "too many attempts, try later", errcode = const.ERROR.FAIL }
	end

	local row = skynet.call(MONGO, "lua", "mongo.find_one", "account", { account = account })

	if not row then
		incr_ratelimit("login:" .. account)
		return { ok = false, err = "account not found", errcode = const.ERROR.ACCOUNT_NOT_EXIST }
	end

	local pwhash = hash_password(row.salt, password)

	if pwhash ~= row.password then
		incr_ratelimit("login:" .. account)
		return { ok = false, err = "wrong password", errcode = const.ERROR.WRONG_PASSWORD }
	end

	-- 登录成功，清除失败计数
	reset_ratelimit("login:" .. account)
	local player_id = row.player_id

	-- 查询基础玩家数据
	local player_data = {}
	local player = skynet.call(MONGO, "lua", "mongo.find_one", "player", { player_id = player_id })
	if player then
		player_data = player
		-- 异步预热缓存
		skynet.send(".player", "lua", "cache", player_id, player)
	end

	-- 生成 token 并写入 Redis (24h 过期)
	local token = make_token(player_id)
	skynet.call(DB, "lua", "setex", "token:" .. token, player_id, 86400)
	skynet.call(DB, "lua", "setex", "online:" .. player_id, token, 86400)

	skynet.error("[login] player login: " .. player_id .. " (" .. account .. ")")
	skynet.send(".player_log", "lua", "log", player_id, "login", {})
	return {
		ok = true,
		player_id = player_id,
		token = token,
		nickname = player_data.nickname,
		level = player_data.level,
	}
end

-- token 验证（其他服务调用）
function CMD.auth(token)
	if not token then
		return nil
	end
	local player_id = skynet.call(DB, "lua", "get_int", "token:" .. token)
	if player_id == 0 then
		return nil
	end
	return player_id
end

-- 登出
function CMD.logout(player_id, token)
	if token then
		skynet.call(DB, "lua", "call", "del", "token:" .. token)
	end
	skynet.call(DB, "lua", "call", "del", "online:" .. player_id)
	skynet.error("[login] player logout: " .. tostring(player_id))
	skynet.send(".player_log", "lua", "log", player_id, "logout", {})
	return { ok = true }
end

skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local f = assert(CMD[cmd], "unknown login cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	skynet.register ".login"
	skynet.error("[login] service started")
end)
