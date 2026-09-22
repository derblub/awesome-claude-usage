-- popup.lua - the details popup: header with logo, one bar per usage window, footer (awesome only).

local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local beautiful = require("beautiful")
local dpi = beautiful.xresources.apply_dpi

local prefix = (...):match("^(.*%.)") or ""
local format = require(prefix .. "format")
local brand = require(prefix .. "brand")
local icon = require(prefix .. "icon")

local M = {}

local function esc(s)
	return gears.string.xml_escape(tostring(s or ""))
end

local function span(text, color, extra)
	return string.format('<span foreground="%s"%s>%s</span>', color, extra or "", esc(text))
end

--- Build the popup content widget from structured rows.
---@param rows table from format.popup_rows
---@param opts table resolved options
---@return table widget
function M.build(rows, opts)
	local c = opts.popup_colors
	local base_font = opts.font or beautiful.font
	local _, size = brand.font_parts(base_font)
	local f_title = brand.font(base_font, size + 2, "Bold")
	local f_body = brand.font(base_font, size)
	local f_small = brand.font(base_font, math.max(size - 1, 7))
	local f_pct = brand.font(base_font, size + 1, "Bold")

	local function textbox(markup, font, align)
		return wibox.widget({
			markup = markup,
			font = font,
			align = align or "left",
			widget = wibox.widget.textbox,
		})
	end

	local function level_color(level)
		if level == "crit" then
			return c.crit
		elseif level == "warn" then
			return c.warn
		end
		return c.accent
	end

	local body = wibox.widget({
		layout = wibox.layout.fixed.vertical,
		spacing = dpi(10),
	})

	-- Header: logo + title + subtitle
	local title_lines = wibox.widget({
		textbox(span(rows.title, c.fg), f_title),
		textbox(span(rows.subtitle or "", c.muted), f_small),
		layout = wibox.layout.fixed.vertical,
		spacing = dpi(1),
	})
	body:add(wibox.widget({
		wibox.container.place(icon.starburst({ size = dpi(size * 2.6), color = c.accent }), "center", "center"),
		title_lines,
		layout = wibox.layout.fixed.horizontal,
		spacing = dpi(10),
	}))

	-- Usage windows
	local function bar_row(label, subtext, percent, level, right_text, note)
		local color = level_color(level)
		local pct_markup = percent and span(string.format("%d%%", format.round(percent)), color, ' font_weight="bold"')
			or span("--", c.muted)
		local head = wibox.widget({
			{
				textbox(span(label, c.fg, ' font_weight="bold"'), f_body),
				subtext and textbox(span(subtext, c.muted), f_small) or nil,
				layout = wibox.layout.fixed.horizontal,
				spacing = dpi(6),
			},
			nil,
			textbox(right_text or pct_markup, f_pct, "right"),
			layout = wibox.layout.align.horizontal,
		})
		local bar = wibox.widget({
			max_value = 100,
			value = math.min(percent or 0, 100),
			forced_height = dpi(6),
			shape = gears.shape.rounded_bar,
			bar_shape = gears.shape.rounded_bar,
			background_color = c.track,
			color = color,
			widget = wibox.widget.progressbar,
		})
		local row = wibox.widget({
			head,
			bar,
			note and textbox(span(note, c.muted), f_small) or nil,
			layout = wibox.layout.fixed.vertical,
			spacing = dpi(4),
		})
		return row
	end

	if rows.empty then
		body:add(textbox(span(rows.empty, c.muted), f_body))
	end
	for _, w in ipairs(rows.windows or {}) do
		local note = w.reset
		if w.active and note then
			note = note .. " · active limit"
		elseif w.active then
			note = "active limit"
		end
		body:add(bar_row(w.label, w.sub, w.percent, w.level, nil, note))
	end
	if rows.spend then
		body:add(bar_row(rows.spend.label, nil, rows.spend.percent, rows.spend.level, nil, rows.spend.text))
	end
	if rows.breakdown then
		body:add(textbox(span("This week: " .. rows.breakdown, c.muted), f_small))
	end

	-- Footer
	local footer_parts = {}
	if rows.error then
		body:add(textbox(span(rows.error, c.warn), f_small))
	end
	for _, line in ipairs(rows.footer or {}) do
		footer_parts[#footer_parts + 1] = line
	end
	if #footer_parts > 0 then
		body:add(wibox.widget({
			{
				forced_height = dpi(1),
				color = c.border,
				widget = wibox.widget.separator,
			},
			textbox(span(table.concat(footer_parts, " · "), c.muted), f_small),
			layout = wibox.layout.fixed.vertical,
			spacing = dpi(6),
		}))
	end

	return wibox.widget({
		body,
		margins = dpi(14),
		forced_width = dpi(opts.popup_width or 300),
		widget = wibox.container.margin,
	})
end

--- Attach a popup to `widget`. Returns a handle with :toggle_pinned(), :show(), :hide().
---@param widget table wibox widget
---@param model table the usage model
---@param opts table resolved options
function M.attach(widget, model, opts)
	local c = opts.popup_colors
	local popup, unsub
	local pinned = false
	local radius = dpi(opts.popup_radius or 10)

	local function ensure_popup()
		if popup then
			return popup
		end
		popup = awful.popup({
			widget = wibox.widget({ layout = wibox.layout.fixed.vertical }),
			ontop = true,
			visible = false,
			bg = c.bg,
			fg = c.fg,
			border_width = dpi(opts.popup_border_width or 1),
			border_color = c.border,
			shape = function(cr, w, h)
				gears.shape.rounded_rect(cr, w, h, radius)
			end,
			preferred_positions = { "top", "bottom" },
			preferred_anchors = "middle",
			offset = { y = dpi(6) },
		})
		return popup
	end

	local function fill(state)
		local p = ensure_popup()
		local ok, content = pcall(M.build, format.popup_rows(state, os.time(), opts), opts)
		if ok then
			p.widget = content
		else
			gears.debug.print_warning("claude_usage: popup build failed: " .. tostring(content))
		end
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
