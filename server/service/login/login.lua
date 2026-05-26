-- login: 登录注册服务
-- 通过 dbproxy 完成账号的 CRUD 和会话管理
local skynet = require "skynet"
require "skynet.manager"
local crypt = require "skynet.crypt"

local DB = ".dbproxy"

local CMD = {}

-- 密码加盐哈希
local function hash_password(salt, password)
	return crypt.hexencode(crypt.sha1(crypt.sha1(password) .. salt))
end

-- 生成登录 token
local function make_token(player_id)
	local str = tostring(player_id) .. tostring(skynet.now()) .. tostring(math.random())
	return crypt.base64encode(crypt.sha1(str)):sub(1, 32)
end

-- 注册账号
function CMD.register(account, password)
	if not account or #account < 3 then
		return { ok = false, err = "account too short" }
	end
	if not password or #password < 6 then
		return { ok = false, err = "password too short" }
	end

	local qaccount = skynet.call(DB, "lua", "mysql.quote", account)

	-- 检查账号是否已存在
	local rows = skynet.call(DB, "lua", "mysql.query",
		"SELECT id FROM account WHERE account = " .. qaccount .. " LIMIT 1")

	if rows and #rows > 0 then
		return { ok = false, err = "account already exists" }
	end

	-- 创建账号
	local salt = tostring(math.random(100000, 999999))
	local pwhash = hash_password(salt, password)
	local quoted_pw = skynet.call(DB, "lua", "mysql.quote", pwhash)
	local quoted_salt = skynet.call(DB, "lua", "mysql.quote", salt)

	local result = skynet.call(DB, "lua", "mysql.execute",
		"INSERT INTO account (account, password, salt, created_at) VALUES (" ..
		qaccount .. ", " .. quoted_pw .. ", " .. quoted_salt .. ", NOW())")

	if not result or result.badresult then
		return { ok = false, err = "db error: " .. tostring(result and result.err or "unknown") }
	end

	local player_id = result.insert_id

	-- 创建初始玩家数据
	skynet.call(DB, "lua", "mysql.execute",
		"INSERT INTO player (id, nickname, level, created_at) VALUES (" ..
		player_id .. ", " .. qaccount .. ", 1, NOW())")

	skynet.error("[login] new account: " .. account .. " -> player_id: " .. player_id)
	return { ok = true, player_id = player_id }
end

-- 登录
function CMD.login(account, password)
	local qaccount = skynet.call(DB, "lua", "mysql.quote", account)

	local rows = skynet.call(DB, "lua", "mysql.query",
		"SELECT id, password, salt FROM account WHERE account = " .. qaccount .. " LIMIT 1")

	if not rows or #rows == 0 then
		return { ok = false, err = "account not found" }
	end

	local row = rows[1]
	local pwhash = hash_password(row.salt, password)

	if pwhash ~= row.password then
		return { ok = false, err = "wrong password" }
	end

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
