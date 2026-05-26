-- utils: 通用工具函数

local M = {}

function M.split(str, delimiter)
	local result = {}
	local from = 1
	local delim_from, delim_to = string.find(str, delimiter, from)
	while delim_from do
		table.insert(result, string.sub(str, from, delim_from - 1))
		from = delim_to + 1
		delim_from, delim_to = string.find(str, delimiter, from)
	end
	table.insert(result, string.sub(str, from))
	return result
end

function M.trim(str)
	return (string.gsub(str, "^%s*(.-)%s*$", "%1"))
end

function M.uid()
	local socket = require "skynet.socket"
	local now = socket.now()
	local rand = math.random(10000, 99999)
	return string.format("%.0f", now * 1000) .. tostring(rand)
end

function M.table_count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

function M.table_merge(t1, t2)
	for k, v in pairs(t2) do
		t1[k] = v
	end
	return t1
end

function M.table_keys(t)
	local keys = {}
	for k in pairs(t) do
		table.insert(keys, k)
	end
	return keys
end

function M.clone(t)
	if type(t) ~= "table" then
		return t
	end
	local copy = {}
	for k, v in pairs(t) do
		copy[M.clone(k)] = M.clone(v)
	end
	return copy
end

return M
