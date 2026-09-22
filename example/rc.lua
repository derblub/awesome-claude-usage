-- Minimal example: the Claude usage widget in a default-style AwesomeWM 4.3 rc.lua.
-- Copy the relevant lines into your own configuration.

local awful = require("awful")
local wibox = require("wibox")
local beautiful = require("beautiful")
beautiful.init(require("gears.filesystem").get_themes_dir() .. "default/theme.lua")

-- The module directory must be on package.path; ~/.config/awesome/claude_usage is by default.
local claude_usage = require("claude_usage")

local terminal = "xterm"

-- One model, one widget per screen. Options only matter on the first call.
local function claude_widget()
	return claude_usage.new({
		on_click = terminal .. " -e claude",
		thresholds = { warn = 75, crit = 90 },
		-- style = "bare",            -- text and icon only, colours from the theme
		-- forced_width = 140,        -- fixed width so the bar does not jump
		-- notify_reset = true,       -- also announce when a window resets
	})
end

awful.screen.connect_for_each_screen(function(s)
	s.mytaglist = awful.widget.taglist({ screen = s, filter = awful.widget.taglist.filter.all })
	s.mywibox = awful.wibar({ position = "top", screen = s })
	s.mywibox:setup({
		layout = wibox.layout.align.horizontal,
		{ layout = wibox.layout.fixed.horizontal, s.mytaglist },
		nil,
		{
			layout = wibox.layout.fixed.horizontal,
			spacing = 8,
			claude_widget(),
			wibox.widget.textclock(),
		},
	})
end)
