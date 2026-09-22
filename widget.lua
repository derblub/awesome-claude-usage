-- widget.lua - the wibar widget: textbox, colours, mouse buttons, popup (awesome only).

local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local beautiful = require("beautiful")

local prefix = (...):match("^(.*%.)") or ""
local format = require(prefix .. "format")
local popup = require(prefix .. "popup")

local M = {}

--- Create the widget.
---@param model table usage model (already set up)
---@param opts table resolved options
---@return table widget  a wibox.container.background holding the textbox; fields .textbox, .model, .popup
function M.new(model, opts)
	local textbox = wibox.widget({
		widget = wibox.widget.textbox,
		font = opts.font or beautiful.font,
		align = opts.align or "center",
		valign = "center",
		forced_width = opts.forced_width,
	})

	local container = wibox.widget({
		textbox,
		widget = wibox.container.background,
	})

	local function render(state)
		local text = gears.string.xml_escape(format.bar_text(state, opts))
		local color = nil
		if opts.color_target ~= "none" then
			color = format.color_for(state, opts)
		end
		if color then
			text = string.format('<span foreground="%s">%s</span>', color, text)
		end
		textbox:set_markup(text)
	end

	render(model.state)
	model.subscribe(render)

	local popup_handle = nil
	if opts.popup then
		popup_handle = popup.attach(container, model, opts)
	end

	local function run_action(action, default)
		if type(action) == "function" then
			local ok, err = pcall(action, model.state, container)
			if not ok then
				gears.debug.print_warning("claude_usage: click handler failed: " .. tostring(err))
			end
		elseif type(action) == "string" and action ~= "" then
			awful.spawn.with_shell(action)
		elseif default then
			default()
		end
	end

	container.buttons = {
		awful.button({}, 1, function()
			run_action(opts.on_click)
		end),
		awful.button({}, 2, function()
			run_action(opts.on_middle_click, function()
				if popup_handle then
					popup_handle:toggle_pinned()
				end
			end)
		end),
		awful.button({}, 3, function()
			run_action(opts.on_right_click, function()
				model.refresh({ force = true })
			end)
		end),
	}

	container.textbox = textbox
	container.model = model
	container.popup = popup_handle
	return container
end

return M
