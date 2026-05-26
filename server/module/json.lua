-- json: 轻量 JSON 编解码
-- 纯 Lua 实现，无外部依赖

local M = {}

local function encode_val(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		if v ~= v then
			return "null"  -- NaN
		end
		return string.format("%g", v)
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "table" then
		local is_array = true
		local max_key = 0
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
				is_array = false
			end
			if k > max_key then
				max_key = k
			end
		end
		if is_array and max_key > 0 then
			local parts = {}
			for i = 1, max_key do
				parts[i] = encode_val(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		elseif is_array and max_key == 0 then
			return "[]"
		else
			local parts = {}
			for k in pairs(v) do
				table.insert(parts, string.format("%q:%s", tostring(k), encode_val(v[k])))
			end
			-- sort for deterministic output
			table.sort(parts)
			return "{" .. table.concat(parts, ",") .. "}"
		end
	else
		return "null"
	end
end

function M.encode(v)
	return encode_val(v)
end

-- Simple recursive descent parser
local function decode_val(s, pos)
	local ch, ch2
	while pos <= #s do
		ch = s:sub(pos, pos)
		if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
			pos = pos + 1
		elseif ch == "n" then
			if s:sub(pos, pos + 3) == "null" then
				return nil, pos + 4
			end
			return nil, pos
		elseif ch == "t" then
			if s:sub(pos, pos + 3) == "true" then
				return true, pos + 4
			end
			return nil, pos
		elseif ch == "f" then
			if s:sub(pos, pos + 4) == "false" then
				return false, pos + 5
			end
			return nil, pos
		elseif ch == "\"" or ch == "'" then
			local quote = ch
			local i = pos + 1
			while i <= #s do
				ch2 = s:sub(i, i)
				if ch2 == "\\" then
					i = i + 2
				elseif ch2 == quote then
					local str = s:sub(pos + 1, i - 1)
					str = str:gsub("\\\"", "\""):gsub("\\\\", "\\"):gsub("\\/", "/")
					str = str:gsub("\\b", "\b"):gsub("\\f", "\f"):gsub("\\n", "\n")
					str = str:gsub("\\r", "\r"):gsub("\\t", "\t")
					return str, i + 1
				else
					i = i + 1
				end
			end
			return nil, pos
		elseif ch == "{" then
			local obj = {}
			pos = pos + 1
			while pos <= #s do
				ch2 = s:sub(pos, pos)
				if ch2 == " " or ch2 == "\t" or ch2 == "\n" or ch2 == "\r" then
					pos = pos + 1
				elseif ch2 == "}" then
					return obj, pos + 1
				else
					local key, new_pos = decode_val(s, pos)
					if key == nil then return nil, pos end
					pos = new_pos
					while pos <= #s do
						ch2 = s:sub(pos, pos)
						if ch2 == ":" or ch2 == "=" then
							pos = pos + 1
							break
						elseif ch2 == " " or ch2 == "\t" then
							pos = pos + 1
						else
							return nil, pos
						end
					end
					local val, new_pos = decode_val(s, pos)
					if val == nil and s:sub(pos, pos) ~= "n" then return nil, pos end
					obj[key] = val
					pos = new_pos
					while pos <= #s do
						ch2 = s:sub(pos, pos)
						if ch2 == "," then
							pos = pos + 1
							break
						elseif ch2 == "}" then
							break
						elseif ch2 == " " or ch2 == "\t" or ch2 == "\n" or ch2 == "\r" then
							pos = pos + 1
						else
							return nil, pos
						end
					end
				end
			end
			return nil, pos
		elseif ch == "[" then
			local arr = {}
			pos = pos + 1
			local idx = 1
			while pos <= #s do
				ch2 = s:sub(pos, pos)
				if ch2 == " " or ch2 == "\t" or ch2 == "\n" or ch2 == "\r" then
					pos = pos + 1
				elseif ch2 == "]" then
					return arr, pos + 1
				elseif ch2 == "," then
					pos = pos + 1
				else
					local val, new_pos = decode_val(s, pos)
					if val == nil and s:sub(pos, pos) ~= "n" then return nil, pos end
					arr[idx] = val
					idx = idx + 1
					pos = new_pos
				end
			end
			return nil, pos
		elseif ch == "-" or (ch >= "0" and ch <= "9") then
			local i = pos + 1
			while i <= #s do
				ch2 = s:sub(i, i)
				if (ch2 >= "0" and ch2 <= "9") or ch2 == "." or ch2 == "e" or ch2 == "E" or ch2 == "+" or ch2 == "-" then
					i = i + 1
				else
					break
				end
			end
			local num_str = s:sub(pos, i - 1)
			local num = tonumber(num_str)
			return num, i
		else
			return nil, pos + 1
		end
	end
	return nil, pos
end

function M.decode(s)
	if type(s) ~= "string" then
		return nil
	end
	local val, pos = decode_val(s, 1)
	return val
end

return M
