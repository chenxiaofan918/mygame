-- agent: 玩家代理服务，sproto 协议
-- 状态机: unauth → auth → disconnected
local skynet = require "skynet"
local socket = require "skynet.socket"
local sprotoloader = require "sprotoloader"
local const = require "const"

local client_fd
local player_id
local state = "unauth"  -- unauth | auth
local watchdog
local timed_out = false

-- sproto host
local host = sprotoloader.load(1):host "package"
local core = require "sproto.core"

-- 预取 error 响应类型
local s2c = sprotoloader.load(2)
local error_resp_type = s2c:queryproto("error").response

-- ======== 封包发送 ========
local function send_error(code, msg)
	local header = core.encode(host.__package, { type = 1, session = 0 })
	local content = core.encode(error_resp_type, { code = code, msg = msg })
	local data = core.pack(header .. content)
	local package = string.pack(">s2", data)
	socket.write(client_fd, package)
end

-- ======== 未认证超时 ========
local function start_unauth_timeout()
	skynet.timeout(600, function()
		if state == "unauth" then
			timed_out = true
			send_error(const.ERROR.UNAUTHORIZED, "login timeout")
			skynet.call(watchdog, "lua", "close", client_fd)
		end
	end)
end

-- ======== 未认证状态 ========
local unauth_handlers = {}

function unauth_handlers.login(args, response)
	local account = args.account
	local password = args.password
	if not account or not password then
		return send_error(const.ERROR.MISSING_PARAMS, "missing account or password")
	end

	local ok, result = pcall(skynet.call, ".login", "lua", "login", account, password)
	if not ok then
		return send_error(const.ERROR.SERVICE_UNAVAILABLE, "login service unavailable")
	end
	if not result.ok then
		return send_error(const.ERROR.LOGIN_FAILED, result.err or "login failed")
	end

	player_id = result.player_id
	state = "auth"

	skynet.error("[agent] player auth ok: " .. player_id)

	if response then
		response({
			ok = true,
			player_id = player_id,
			token = result.token,
			nickname = result.nickname,
			level = result.level,
		})
	end
end

function unauth_handlers.register(args, response)
	local account = args.account
	local password = args.password
	if not account or not password then
		return send_error(const.ERROR.MISSING_PARAMS, "missing account or password")
	end

	local ok, result = pcall(skynet.call, ".login", "lua", "register", account, password)
	if not ok then
		return send_error(const.ERROR.SERVICE_UNAVAILABLE, "login service unavailable")
	end
	if not result.ok then
		return send_error(const.ERROR.REGISTER_FAILED, result.err or "register failed")
	end

	skynet.error("[agent] new player: " .. result.player_id)
	if response then
		response({ ok = true, player_id = result.player_id })
	end
end

-- ======== 已认证状态 ========
local auth_handlers = {}

function auth_handlers.chat(args, response)
	skynet.error("[agent] chat from " .. player_id .. ": " .. tostring(args.msg))
	if response then
		response({ msg = args.msg })
	end
end

function auth_handlers.ping()
	-- ping 无需响应
end

-- ======== 消息分发 ========
local function request_handler(name, args, response)
	local handlers = (state == "unauth") and unauth_handlers or auth_handlers
	local f = handlers[name]
	if f then
		local ok, err = pcall(f, args, response)
		if not ok then
			skynet.error("[agent] handler error:", err)
		end
	else
		if state == "unauth" then
			send_error(const.ERROR.UNAUTHORIZED, "please login first")
		else
			send_error(const.ERROR.UNKNOWN_CMD, "unknown command: " .. tostring(name))
		end
	end
end

-- ======== CMD ========
local CMD = {}

function CMD.start(conf)
	client_fd = conf.client
	watchdog = conf.watchdog
	-- 向内置 gate 注册 forward，客户端数据直接发往本 agent
	skynet.call(conf.gate, "lua", "forward", client_fd, 0)
	skynet.error("[agent] new connection: fd=" .. client_fd)
	start_unauth_timeout()
end

function CMD.disconnect()
	skynet.error("[agent] disconnect: player=" .. tostring(player_id))
	if player_id and not timed_out then
		pcall(skynet.send, ".login", "lua", "logout", player_id)
	end
	skynet.exit()
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, command, ...)
		local f = CMD[command]
		if f then
			if session ~= 0 then
				skynet.ret(skynet.pack(f(...)))
			else
				f(...)
			end
		end
	end)

	-- client 协议：skynet.redirect 过来的原始 socket 数据
	skynet.register_protocol {
		name = "client",
		id = skynet.PTYPE_CLIENT,
		unpack = function(msg, sz)
			return host:dispatch(msg, sz)
		end,
		dispatch = function(fd, _, type, ...)
			skynet.ignoreret()
			if fd ~= client_fd then
				return
			end
			if type == "REQUEST" then
				local function send_response(response_func)
					return function(args, ud)
						local data = response_func(args, ud)
						if data then
							local package = string.pack(">s2", data)
							socket.write(client_fd, package)
						end
					end
				end
				request_handler(select(1, ...), select(2, ...), send_response(select(3, ...)))
			end
		end,
	}
end)
