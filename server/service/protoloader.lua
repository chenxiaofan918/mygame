-- protoloader: 加载 sproto 协议到全局槽位
-- c2s → slot 1,  s2c → slot 2
--
-- 加载策略（双模式）:
--   1) 优先从 .spb 文件加载（生产模式，无需 sprotoparser/lpeg）
--   2) 回退到运行时解析 .sproto 文本（开发模式，Windows 友好）
--
-- 生产部署：运行 `make proto` 生成 .spb，可移除 sprotoparser.lua + lpeg.so

local skynet = require "skynet"
local sprotoloader = require "sprotoloader"

local function load_spb(filename, index)
	local f = io.open(filename, "rb")
	if not f then
		return false, filename .. " not found"
	end
	local bin = f:read("*a")
	f:close()
	if #bin == 0 then
		return false, filename .. " is empty"
	end
	sprotoloader.save(bin, index)
	skynet.error("[protoloader] loaded " .. filename .. " -> slot " .. index)
	return true
end

skynet.start(function()
	-- 第一优先: 从 .spb 文件加载
	local c2s_ok, c2s_err = load_spb("proto/c2s.spb", 1)
	local s2c_ok, s2c_err = load_spb("proto/s2c.spb", 2)

	if c2s_ok and s2c_ok then
		skynet.error("[protoloader] proto loaded from .spb (fast mode)")
		return
	end

	-- 回退: 运行时解析 .sproto 文本（需要 sprotoparser + lpeg）
	skynet.error("[protoloader] .spb not available (" ..
		(c2s_err or "?") .. "; " .. (s2c_err or "?") ..
		"), falling back to runtime parse")

	local sprotoparser = require "sprotoparser"

	local proto_dir = "./proto/"

	local function read_sproto(name)
		local f = io.open(proto_dir .. name, "r")
		if not f then return "" end
		local content = f:read("*a")
		f:close()
		return content
	end

	local modules = { "common", "login", "bag", "chat", "rank" }

	local c2s_parts = {}
	local s2c_parts = {}

	for _, mod in ipairs(modules) do
		local public = read_sproto(mod .. "_public.sproto")
		if #public > 0 then
			table.insert(c2s_parts, public)
			table.insert(s2c_parts, public)
		end

		local c2s = read_sproto(mod .. "_c2s.sproto")
		if #c2s > 0 then
			table.insert(c2s_parts, c2s)
		end

		local s2c = read_sproto(mod .. "_s2c.sproto")
		if #s2c > 0 then
			table.insert(s2c_parts, s2c)
		end
	end

	if not c2s_ok and #c2s_parts > 0 then
		sprotoloader.save(sprotoparser.parse(table.concat(c2s_parts, "\n")), 1)
		skynet.error("[protoloader] parsed c2s.sproto -> slot 1 (fallback)")
	end

	if not s2c_ok and #s2c_parts > 0 then
		sprotoloader.save(sprotoparser.parse(table.concat(s2c_parts, "\n")), 2)
		skynet.error("[protoloader] parsed s2c.sproto -> slot 2 (fallback)")
	end

	skynet.error("[protoloader] proto loaded (fallback mode)")
end)
