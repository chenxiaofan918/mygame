-- logger: 日志封装
local skynet = require "skynet"

local M = {}

local LEVELS = {
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4,
}

local level = LEVELS.INFO

function M.set_level(lv)
	level = LEVELS[lv] or LEVELS.INFO
end

function M.debug(...)
	if level <= LEVELS.DEBUG then
		skynet.error("[DEBUG]", ...)
	end
end

function M.info(...)
	if level <= LEVELS.INFO then
		skynet.error("[INFO]", ...)
	end
end

function M.warn(...)
	if level <= LEVELS.WARN then
		skynet.error("[WARN]", ...)
	end
end

function M.error(...)
	if level <= LEVELS.ERROR then
		skynet.error("[ERROR]", ...)
	end
end

return M
