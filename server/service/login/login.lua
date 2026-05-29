-- login: 登录注册服务
-- 通过 dbproxy 完成账号的 CRUD 和会话管理
local skynet = require "skynet"
require "skynet.manager"
local crypt = require "skynet.crypt"
local const = require "const"

local DB = ".dbproxy"

local CMD = {}

-- 速率限制（5 分钟内最多 5 次失败）
local RATE_LIMIT_MAX = 5
local RATE_LIMIT_WINDOW = 300  -- 5 秒 * 60 = 300 秒

local function check_ratelimit(key)
	local count = skynet.call(DB, "lua", "redis.get_int", "ratelimit:" .. key)
	if count >= RATE_LIMIT_MAX then
		return false
	end
	return true
end

local function incr_ratelimit(key)
	skynet.call(DB, "lua", "redis.call", "INCR", "ratelimit:" .. key)
	skynet.call(DB, "lua", "redis.call", "EXPIRE", "ratelimit:" .. key, RATE_LIMIT_WINDOW)
end

local function reset_ratelimit(key)
	skynet.call(DB, "lua", "redis.call", "del", "ratelimit:" .. key)
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

	local qaccount = skynet.call(DB, "lua", "mysql.quote", account)

	-- 检查账号是否已存在
	local rows = skynet.call(DB, "lua", "mysql.query",
		"SELECT id FROM account WHERE account = " .. qaccount .. " LIMIT 1")

	if rows and #rows > 0 then
		return { ok = false, err = "account already exists", errcode = const.ERROR.ACCOUNT_EXISTS }
	end

	-- 创建账号（事务保护：account + player 同时成功或回滚）
	skynet.call(DB, "lua", "mysql.begin")
	local ok_create, player_id = pcall(function()
		local salt = make_salt()
		local pwhash = hash_password(salt, password)
		local quoted_pw = skynet.call(DB, "lua", "mysql.quote", pwhash)
		local quoted_salt = skynet.call(DB, "lua", "mysql.quote", salt)

		local result = skynet.call(DB, "lua", "mysql.execute",
			"INSERT INTO account (account, password, salt, created_at) VALUES (" ..
			qaccount .. ", " .. quoted_pw .. ", " .. quoted_salt .. ", NOW())")

		if not result or result.badresult then
			error(result and result.err or "insert account failed")
		end

		local pid = result.insert_id

		-- 创建初始玩家数据
		local player_result = skynet.call(DB, "lua", "mysql.execute",
			"INSERT INTO player (id, nickname, level, created_at) VALUES (" ..
			pid .. ", " .. qaccount .. ", 1, NOW())")

		if not player_result or player_result.badresult then
			error(player_result and player_result.err or "insert player failed")
		end

		return pid
	end)

	if ok_create then
		skynet.call(DB, "lua", "mysql.commit")
		skynet.error("[login] new account: " .. account .. " -> player_id: " .. player_id)
		return { ok = true, player_id = player_id }
	else
		skynet.call(DB, "lua", "mysql.rollback")
		skynet.error("[login] register failed: " .. tostring(player_id))
		return { ok = false, err = "db error: " .. tostring(player_id), errcode = const.ERROR.FAIL }
	end
end

-- 登录
function CMD.login(account, password)
	if not check_ratelimit("login:" .. account) then
		return { ok = false, err = "too many attempts, try later", errcode = const.ERROR.FAIL }
	end

	local qaccount = skynet.call(DB, "lua", "mysql.quote", account)

	local rows = skynet.call(DB, "lua", "mysql.query",
		"SELECT id, password, salt FROM account WHERE account = " .. qaccount .. " LIMIT 1")

	if not rows or #rows == 0 then
		incr_ratelimit("login:" .. account)
		return { ok = false, err = "account not found", errcode = const.ERROR.ACCOUNT_NOT_EXIST }
	end

	local row = rows[1]
	local pwhash = hash_password(row.salt, password)

	if pwhash ~= row.password then
		incr_ratelimit("login:" .. account)
		return { ok = false, err = "wrong password", errcode = const.ERROR.WRONG_PASSWORD }
	end

	-- 登录成功，清除失败计数
	reset_ratelimit("login:" .. account)
	local player_id = row.id

	-- 查询基础玩家数据
	local players = skynet.call(DB, "lua", "mysql.query",
		"SELECT nickname, level, exp FROM player WHERE id = " .. player_id .. " LIMIT 1")

	local player_data = {}
	if players and #players > 0 then
		player_data = players[1]
	end

	-- 生成 token 并写入 Redis (24h 过期)
	local token = make_token(player_id)
	skynet.call(DB, "lua", "redis.setex", "token:" .. token, player_id, 86400)
	skynet.call(DB, "lua", "redis.setex", "online:" .. player_id, token, 86400)

	skynet.error("[login] player login: " .. player_id .. " (" .. account .. ")")
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
	local player_id = skynet.call(DB, "lua", "redis.get_int", "token:" .. token)
	if player_id == 0 then
		return nil
	end
	return player_id
end

-- 登出
function CMD.logout(player_id, token)
	if token then
		skynet.call(DB, "lua", "redis.call", "del", "token:" .. token)
	end
	skynet.call(DB, "lua", "redis.call", "del", "online:" .. player_id)
	skynet.error("[login] player logout: " .. tostring(player_id))
	return { ok = true }
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f = assert(CMD[cmd], "unknown login cmd: " .. tostring(cmd))
		skynet.ret(skynet.pack(f(...)))
	end)

	skynet.register ".login"
	skynet.error("[login] service started")
end)
