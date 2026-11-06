-- rc.lua - minimal AwesomeWM configuration for the screenshot generator (see generate.sh).
-- Everything the widget reads lives in $CU_SHOT_DIR; HOME points there as well.

local gears = require("gears")
local awful = require("awful")
local wibox = require("wibox")
local beautiful = require("beautiful")

local dir = assert(os.getenv("CU_SHOT_DIR"), "CU_SHOT_DIR not set")
local popup_wanted = os.getenv("CU_SHOT_POPUP") == "1"
local scenario = os.getenv("CU_SHOT_SCENARIO")

package.path = dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path

beautiful.init({
	font = "DejaVu Sans Mono 15",
	bg_normal = "#1b1b1a",
	bg_focus = "#2a2928",
	fg_normal = "#cfcdc6",
	fg_focus = "#faf9f5",
	taglist_bg_focus = "#2a2928",
	taglist_fg_focus = "#d97757",
	wibar_height = 30,
	useless_gap = 0,
})

local claude_usage = require("claude_usage")

local function write_file(name, text)
	local f = io.open(dir .. "/" .. name, "w")
	f:write(text)
	f:close()
end

local opts = {
	curl_cmd = dir .. "/fake-curl.sh",
	credentials_path = dir .. "/credentials.json",
	claude_json_path = dir .. "/none-claude.json",
	desktop_path = dir .. "/none-desktop.json",
	cache_path = dir .. "/rate_limits.json",
	history_path = dir .. "/history.csv",
	sessions_dir = dir .. "/sessions",
	sessions = false,
	watch_cache = false,
	notify_threshold = false,
	notify_attention = false,
	initial_delay = 1,
	jitter = 0,
	popup_width = 540,
	sparkline_hours = 72,
	on_click = "true",
}
if scenario == "apikey" then
	opts.sources = { "statusline" }
end

local widget = claude_usage.new(opts)

awful.screen.connect_for_each_screen(function(s)
	gears.wallpaper.set("#121211")
	awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9" }, s, awful.layout.layouts[1])
	local taglist = awful.widget.taglist({ screen = s, filter = awful.widget.taglist.filter.all })
	s.bar = awful.wibar({ position = "bottom", screen = s, height = 30 })
	s.bar:setup({
		layout = wibox.layout.align.horizontal,
		{
			layout = wibox.layout.fixed.horizontal,
			spacing = 14,
			taglist,
			widget,
			wibox.widget.textclock(" %a %d %b %H:%M "),
		},
		nil,
		nil,
	})
end)

-- Wait for the first answer from fake-curl, pin the popup, then tell generate.sh the picture is ready.
local started = os.time()
gears.timer({
	timeout = 1,
	autostart = true,
	call_now = false,
	callback = function(t)
		local st = claude_usage.state
		local waited = os.time() - started
		local have_data = st and (st.source == "api" or scenario == "apikey") and not st.error
		if not have_data and waited < 20 then
			return true
		end
		t:stop()
		if popup_wanted and claude_usage.toggle_popup() == false then
			write_file("error.txt", "popup did not open\n")
		end
		gears.timer.start_new(2, function()
			local geos = claude_usage.widget_geometries()
			local g = geos[1]
			local lines = { "source=" .. tostring(st and st.source), "error=" .. tostring(st and st.error and st.error.code) }
			if g then
				lines[#lines + 1] = string.format("bar=%d %d %d %d", g.x, g.y, g.width, g.height)
			end
			-- The popup is the biggest drawin that is not the wibar.
			local best, bg
			for _, d in ipairs(root.drawins()) do
				local geo = d:geometry()
				if d.visible and geo.height > 100 and (not bg or geo.width * geo.height > best) then
					best, bg = geo.width * geo.height, geo
				end
			end
			if bg and popup_wanted then
				lines[#lines + 1] = string.format("popup=%d %d %d %d", bg.x, bg.y, bg.width, bg.height)
			end
			write_file("ready", table.concat(lines, "\n") .. "\n")
			return false
		end)
		return false
	end,
})
