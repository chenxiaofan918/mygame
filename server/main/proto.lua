-- proto: sproto 协议定义入口
-- 按功能+方向拆分在 proto/*_{c2s,s2c,public}.sproto
-- 加载规则: c2s = *_public + *_c2s,  s2c = *_public + *_s2c
--
-- 注意: 此模块已不再被运行时引用。
-- 生产环境通过 `make proto` 预编译 .sproto → .spb，
-- 由 protoloader 直接加载 .spb 二进制。
-- 此文件保留作为协议组装的参考，构建工具 compile_sproto.lua 也与此对标。
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

local proto = {}
proto.c2s = sprotoparser.parse(table.concat(c2s_parts, "\n"))
proto.s2c = sprotoparser.parse(table.concat(s2c_parts, "\n"))

return proto
