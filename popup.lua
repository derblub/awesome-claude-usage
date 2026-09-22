-- popup.lua - hover popup with the details (awesome only).

local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local beautiful = require("beautiful")
local dpi = beautiful.xresources.apply_dpi

local prefix = (...):match("^(.*%.)") or ""
local format = require(prefix .. "format")

local M = {}

--- Attach a popup to `widget`. Returns a handle with :toggle_pinned(), :show(), :hide().
---@param widget table wibox widget
---@param model table the usage model
---@param opts table resolved options
function M.attach(widget, model, opts)
	local popup, unsub
	local pinned = false
	local font = opts.font or beautiful.font

	local lines_layout = wibox.widget({
		layout = wibox.layout.fixed.vertical,
		spacing = dpi(2),
	})

	local function fill(state)
		lines_layout:reset()
		local lines = format.popup_lines(state, os.time(), opts)
		for i, line in ipairs(lines) do
			local text = gears.string.xml_escape(line)
			if i == 1 then
				text = "<b>" .. text .. "</b>"
			end
			lines_layout:add(wibox.widget({
				markup = text,
				font = font,
				widget = wibox.widget.textbox,
			}))
		end
	end

	local function ensure_popup()
		if popup then
			return popup
		end
		popup = awful.popup({
			widget = wibox.widget({
				lines_layout,
				margins = dpi(8),
				widget = wibox.container.margin,
			}),
			ontop = true,
			visible = false,
			bg = opts.popup_bg or beautiful.bg_normal or "#222222",
			fg = opts.popup_fg or beautiful.fg_normal or "#dddddd",
			border_width = opts.popup_border_width or 1,
			border_color = opts.popup_border_color or beautiful.border_focus or "#444444",
			shape = gears.shape.rounded_rect,
			preferred_positions = { "top", "bottom" },
			preferred_anchors = "middle",
			offset = { y = dpi(4) },
		})
		return popup
	end

	local handle = {}

	function handle:show()
		local p = ensure_popup()
		if not unsub then
			unsub = model.subscribe(fill)
		else
			fill(model.state)
		end
		local geo = mouse.current_widget_geometry
		if opts.popup_placement then
			opts.popup_placement(p, geo)
		elseif geo then
			p:move_next_to(geo)
		else
			awful.placement.under_mouse(p)
			awful.placement.no_offscreen(p)
		end
		p.visible = true
	end

	function handle:hide()
		pinned = false
		if unsub then
			unsub()
			unsub = nil
		end
		if popup then
			popup.visible = false
		end
	end

	function handle:toggle_pinned()
		if pinned then
			handle:hide()
		else
			handle:show()
			pinned = true
		end
	end

	widget:connect_signal("mouse::enter", function()
		if not pinned then
			handle:show()
		end
	end)
	widget:connect_signal("mouse::leave", function()
		if not pinned then
			handle:hide()
		end
	end)

	return handle
end

return M
