-- source/claude_json.lua - read cachedUsageUtilization from ~/.claude.json (Claude Code's own cache).

local root = (...):gsub("source%.[^%.]+$", "")
local json = require(root .. "json")

local M = {}

local function valid(cu)
	return type(cu) == "table" and type(cu.utilization) == "table"
end

--- Decode only the value after the "cachedUsageUtilization" key, so a many-MB file is not
--- turned into Lua tables just to read one small object.
---@param content string
---@return table|nil
local function decode_key(content)
	local s, e = content:find('"cachedUsageUtilization"%s*:%s*')
	if not s or (s > 1 and content:sub(s - 1, s - 1) == "\\") then
		return nil
	end
	local ok, cu = pcall(json.decode_at, content, e + 1)
	if ok and valid(cu) then
		return cu
	end
	return nil
end

--- Read ~/.claude.json and return only the cachedUsageUtilization object.
---@param path string
---@return table|nil { fetchedAtMs, utilization }
function M.read(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	if not content or not content:find('"cachedUsageUtilization"', 1, true) then
		return nil
	end
	local cu = decode_key(content)
	if cu then
		return cu
	end
	-- Key not found cheaply (odd formatting or an unexpected value): decode everything.
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" or not valid(data.cachedUsageUtilization) then
		return nil
	end
	return data.cachedUsageUtilization
end

return M
