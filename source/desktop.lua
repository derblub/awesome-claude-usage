-- source/desktop.lua - read the plan usage samples Claude Desktop keeps on disk (read-only).
--
-- Claude Desktop (Linux) rewrites ~/.config/Claude/plan-usage-history.json about every 15 minutes:
--   { "version": 2, "samples": [ { "t": <epoch ms>, "org": "<uuid>", "u": { "fh": 1, "sd": 99 } }, ... ] }
-- fh is the 5-hour window, sd the 7-day window, both in percent. The format is undocumented, so
-- everything is checked and anything unexpected is skipped.

local root = (...):gsub("source%.[^%.]+$", "")
local json = require(root .. "json")

local M = {}

local function valid(s)
	return type(s) == "table"
		and type(s.t) == "number"
		and type(s.u) == "table"
		and (type(s.u.fh) == "number" or type(s.u.sd) == "number")
end

--- Read the file and return the newest sample (of one organisation when `org` is given).
---@param path string
---@param org string|nil only samples of this organisation
---@return table|nil sample { t, org, u = { fh, sd } }
function M.read(path, org)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	if not content or content == "" then
		return nil
	end
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" or type(data.samples) ~= "table" then
		return nil
	end
	local newest = nil
	for _, s in ipairs(data.samples) do
		if valid(s) and (org == nil or s.org == org) and (newest == nil or s.t > newest.t) then
			newest = s
		end
	end
	return newest
end

return M
