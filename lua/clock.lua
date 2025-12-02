-- lua/clock/nvim.lua
-- clock.nvim - large floating ASCII clock with left→right gradient, optional Kanagawa colors.
-- Usage:
--   require("clock.nvim").setup({ map = true, gradient = { from = "#17A1D4", to = "#F5A623" } })
--   <leader>ck toggles the clock (default)

local M = {}

-- DEFAULTS
local DEFAULTS = {
	cmd = "ClockNvimToggle",
	map = true,
	padding = 1,
	scale = 1,
	interval = 1000, -- ms
	winblend = 0,
	border = "none",
	min_cols = 20,
	min_rows = 6,
	-- default gradient (the one you liked)
	gradient = { from = "#17A1D4", to = "#F5A623" },
	-- if true, attempt to derive endpoints from Kanagawa colorscheme (dragon)
	prefer_kanagawa = false,
}

-- filled digits map (5x7) using "█" and spaces
local DIGITS = {
	["0"] = {
		" █████ ",
		"█     █",
		"█     █",
		"█     █",
		" █████ ",
	},
	["1"] = {
		"   ██  ",
		" ████  ",
		"   ██  ",
		"   ██  ",
		" █████ ",
	},
	["2"] = {
		" █████ ",
		"█     █",
		"    ██ ",
		"  ███  ",
		"███████",
	},
	["3"] = {
		" █████ ",
		"█     █",
		"  ████ ",
		"█     █",
		" █████ ",
	},
	["4"] = {
		"█   ██ ",
		"█   ██ ",
		"█   ██ ",
		"███████",
		"    ██ ",
	},
	["5"] = {
		"███████",
		"█      ",
		"██████ ",
		"      █",
		"██████ ",
	},
	["6"] = {
		" █████ ",
		"█      ",
		"██████ ",
		"█     █",
		" █████ ",
	},
	["7"] = {
		"███████",
		"█    ██",
		"   ██  ",
		"  ██   ",
		"  ██   ",
	},
	["8"] = {
		" █████ ",
		"█     █",
		" █████ ",
		"█     █",
		" █████ ",
	},
	["9"] = {
		" █████ ",
		"█     █",
		" ██████",
		"      █",
		" █████ ",
	},
	[":"] = {
		"       ",
		"   ██  ",
		"       ",
		"   ██  ",
		"       ",
	},
	[" "] = {
		"       ",
		"       ",
		"       ",
		"       ",
		"       ",
	},
}

-- plugin state
local state = {
	cfg = vim.tbl_deep_extend("force", {}, DEFAULTS),
	ns = vim.api.nvim_create_namespace("clock_nvim_ns"),
	buf = nil,
	win = nil,
	timer = nil,
	timer_running = false,
	active = false,
	augroup = nil,
	_kanagawa_cache = nil,
}

-- ==== Utilities: hex/rgb/lerp ====
local function hex_to_rgb(hex)
	hex = hex:gsub("#", "")
	return tonumber("0x" .. hex:sub(1, 2)), tonumber("0x" .. hex:sub(3, 4)), tonumber("0x" .. hex:sub(5, 6))
end
local function rgb_to_hex(r, g, b)
	return string.format(
		"#%02x%02x%02x",
		math.max(0, math.min(255, math.floor(r))),
		math.max(0, math.min(255, math.floor(g))),
		math.max(0, math.min(255, math.floor(b)))
	)
end
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- build n colors interpolated left->right
local function build_gradient(from_hex, to_hex, n)
	if n <= 0 then
		return {}
	end
	if n == 1 then
		return { from_hex }
	end
	local fr, fg, fb = hex_to_rgb(from_hex)
	local tr, tg, tb = hex_to_rgb(to_hex)
	local out = {}
	for i = 0, n - 1 do
		local t = i / (n - 1)
		local r = lerp(fr, tr, t)
		local g = lerp(fg, tg, t)
		local b = lerp(fb, tb, t)
		out[#out + 1] = rgb_to_hex(r, g, b)
	end
	return out
end

-- safe wrapper to get highlight fg as hex (tries nvim_get_hl_by_name)
local function hl_fg_hex(name)
	if not name or name == "" then
		return nil
	end
	local ok, hl = pcall(vim.api.nvim_get_hl_by_name, name, true)
	if not ok or not hl then
		return nil
	end
	local fg = hl.foreground or hl.fg
	if not fg then
		return nil
	end
	if type(fg) == "number" then
		return string.format("#%06x", fg)
	end
	if type(fg) == "string" and fg:match("^#") then
		return fg
	end
	return nil
end

-- Try to build endpoints from Kanagawa (best effort)
local function build_kanagawa_endpoints()
	if state._kanagawa_cache then
		return state._kanagawa_cache
	end
	local endpoints = {}
	-- preference list of groups that Kanagawa commonly provides (varies by version)
	local try = function(list)
		for _, n in ipairs(list) do
			local v = hl_fg_hex(n)
			if v then
				return v
			end
		end
		return nil
	end
	endpoints.from = try({ "KanagawaBlue", "KanagawaAqua", "Statement", "Function", "Identifier" })
		or try({ "Normal" })
		or "#7fb4d1"
	endpoints.to = try({ "KanagawaOrange", "KanagawaRed", "Error", "Conditional" }) or try({ "Special" }) or "#F5A623"
	state._kanagawa_cache = endpoints
	return endpoints
end

-- Create gradient highlight groups for current time length: ClockNvimGrad1..N
local function create_gradient_highlights(colors)
	for i, hex in ipairs(colors) do
		local name = "ClockNvimGrad" .. i
		pcall(vim.api.nvim_set_hl, 0, name, { fg = hex, bg = "NONE" })
	end
	-- safe fallbacks
	pcall(
		vim.api.nvim_set_hl,
		0,
		"ClockNvimMain",
		{ fg = state.cfg.gradient and state.cfg.gradient.from or "#88ff66", bg = "NONE" }
	)
	pcall(
		vim.api.nvim_set_hl,
		0,
		"ClockNvimDigitSpace",
		{ fg = vim.o.background == "light" and "#000000" or "#2a2a2a", bg = "NONE" }
	)
end

-- build ascii lines for a time_str using scale & padding
local function scale_block(block, scale)
	if scale <= 1 then
		return vim.deepcopy(block)
	end
	local out = {}
	for _, row in ipairs(block) do
		local parts = {}
		for ch in row:gmatch(".") do
			parts[#parts + 1] = ch:rep(scale)
		end
		local hr = table.concat(parts)
		for i = 1, scale do
			out[#out + 1] = hr
		end
	end
	return out
end

local function build_clock_lines(time_str, cfg)
	local chars = {}
	for ch in time_str:gmatch(".") do
		chars[#chars + 1] = ch
	end
	local blocks = {}
	for _, ch in ipairs(chars) do
		blocks[#blocks + 1] = scale_block(DIGITS[ch] or DIGITS[" "], cfg.scale)
	end
	local rows = #blocks[1]
	local pad = string.rep(" ", cfg.padding)
	local lines = {}
	for r = 1, rows do
		local parts = {}
		for i = 1, #blocks do
			parts[#parts + 1] = blocks[i][r] or string.rep(" ", #blocks[1][r])
		end
		lines[#lines + 1] = pad .. table.concat(parts, " ") .. pad
	end
	return lines
end

local function compute_size(lines)
	local h = #lines
	local w = 0
	for _, l in ipairs(lines) do
		local len = vim.fn.strdisplaywidth(l)
		if len > w then
			w = len
		end
	end
	return h, w
end

local function make_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(function()
			vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
			vim.api.nvim_buf_set_option(buf, "filetype", "clocknvim")
		end)
	end
	return buf
end

-- main highlight application: per-'█' highlight using block -> grad group mapping
local function apply_highlights_gradient(buf, lines, cfg, time_str)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, buf, state.ns, 0, -1)

	-- measurements
	local sample = DIGITS["0"][1] or "       "
	local block_width = vim.fn.strdisplaywidth(sample) * cfg.scale
	local sep = 1
	local pad = cfg.padding

	-- decide endpoints: kanagawa preferred?
	local from_hex, to_hex
	if cfg.prefer_kanagawa then
		local ep = build_kanagawa_endpoints()
		from_hex, to_hex = ep.from, ep.to
	else
		from_hex = (cfg.gradient and cfg.gradient.from) or DEFAULTS.gradient.from
		to_hex = (cfg.gradient and cfg.gradient.to) or DEFAULTS.gradient.to
	end

	-- Build block colors and highlight groups
	local num_blocks = #time_str
	local colors = build_gradient(from_hex, to_hex, num_blocks)
	create_gradient_highlights(colors)

	-- for each '█' character, determine which block it belongs to and add highlight (byte indices)
	for line_idx = 1, #lines do
		local row = lines[line_idx]
		local start = 1
		while true do
			local s, e = row:find("█", start, true) -- s,e byte indices (1-based)
			if not s then
				break
			end
			local prefix = row:sub(1, s - 1)
			local display_col = vim.fn.strdisplaywidth(prefix)
			local rel = display_col - pad
			if rel >= 0 then
				local block_index = math.floor(rel / (block_width + sep)) + 1
				local within = rel % (block_width + sep)
				if block_index >= 1 and block_index <= num_blocks and within < block_width then
					local group = "ClockNvimGrad" .. block_index
					-- nvim_buf_add_highlight expects 0-based start (byte), exclusive end
					pcall(vim.api.nvim_buf_add_highlight, buf, state.ns, group, line_idx - 1, s - 1, e)
				end
			end
			start = e + 1
		end
	end
end

-- open a centered floating window; do NOT pass winblend to nvim_open_win
local function open_floating(lines, opts)
	local buf = make_buf()
	if not buf then
		return nil, nil
	end

	pcall(function()
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end)

	local ui_cols = vim.o.columns
	local ui_rows = vim.o.lines - vim.o.cmdheight
	if opts.width > ui_cols then
		opts.width = math.max(1, ui_cols - 2)
	end
	if opts.height > ui_rows then
		opts.height = math.max(1, ui_rows - 2)
	end
	if opts.col < 0 then
		opts.col = 0
	end
	if opts.row < 0 then
		opts.row = 0
	end
	if (opts.col + opts.width) > ui_cols then
		opts.col = math.max(0, ui_cols - opts.width)
	end
	if (opts.row + opts.height) > ui_rows then
		opts.row = math.max(0, ui_rows - height)
	end

	local open_opts = vim.tbl_deep_extend("force", {}, opts)
	local winblend_value = nil
	if open_opts.winblend ~= nil then
		winblend_value = open_opts.winblend
		open_opts.winblend = nil
	end
	open_opts.focusable = open_opts.focusable == nil and false or open_opts.focusable
	open_opts.noautocmd = open_opts.noautocmd == nil and true or open_opts.noautocmd

	local win = nil
	local ok = pcall(function()
		win = vim.api.nvim_open_win(buf, false, open_opts)
	end)
	if not ok then
		return nil, nil
	end

	if win and vim.api.nvim_win_is_valid(win) then
		if winblend_value ~= nil then
			pcall(function()
				vim.api.nvim_win_set_option(win, "winblend", winblend_value)
			end)
		end
		pcall(function()
			vim.api.nvim_win_set_option(win, "wrap", false)
		end)
		pcall(function()
			vim.api.nvim_win_set_option(win, "cursorline", false)
		end)
		pcall(function()
			vim.api.nvim_win_set_option(win, "signcolumn", "no")
		end)
		pcall(function()
			vim.api.nvim_win_set_option(win, "foldcolumn", "0")
		end)
	end
	return buf, win
end

local function make_center_config(lines, cfg)
	local rows, cols = compute_size(lines)
	local ui_cols = vim.o.columns
	local ui_rows = vim.o.lines - vim.o.cmdheight
	local width = math.min(cols, math.max(1, ui_cols - 2))
	local height = math.min(rows, math.max(1, ui_rows - 2))
	local col = math.floor((ui_cols - width) / 2)
	local row = math.floor((ui_rows - height) / 2)
	if col < 0 then
		col = 0
	end
	if row < 0 then
		row = 0
	end
	if col + width > ui_cols then
		col = math.max(0, ui_cols - width)
	end
	if row + height > ui_rows then
		row = math.max(0, ui_rows - height)
	end

	local cfg_tbl = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = state.cfg.border,
		winblend = state.cfg.winblend,
	}

	local v = vim.version()
	if v and v.major == 0 and v.minor >= 9 then
		cfg_tbl.anchor = "NW"
		cfg_tbl.zindex = 200
	end
	return cfg_tbl
end

-- render the clock once (open or update float, apply highlights)
local function render_once()
	if not state.active then
		return
	end
	local cfg = state.cfg
	if vim.o.columns < cfg.min_cols or (vim.o.lines - vim.o.cmdheight) < cfg.min_rows then
		pcall(function()
			if state.win and vim.api.nvim_win_is_valid(state.win) then
				vim.api.nvim_win_close(state.win, true)
			end
		end)
		state.win = nil
		state.buf = nil
		return
	end

	local timestr = os.date("%I:%M:%S")
	local lines = build_clock_lines(timestr, cfg)
	local main_cfg = make_center_config(lines, cfg)
	main_cfg.winblend = cfg.winblend

	-- open or update
	if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
		local buf_m, win_m = open_floating(lines, main_cfg)
		if win_m and vim.api.nvim_win_is_valid(win_m) then
			pcall(apply_highlights_gradient, buf_m, lines, cfg, timestr)
			vim.defer_fn(function()
				if buf_m and vim.api.nvim_buf_is_valid(buf_m) then
					pcall(apply_highlights_gradient, buf_m, lines, cfg, timestr)
				end
			end, 60)
		end
		state.buf, state.win = buf_m, win_m
	else
		if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
			pcall(function()
				vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
				vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
				vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
			end)
			pcall(apply_highlights_gradient, state.buf, lines, cfg, timestr)
			vim.defer_fn(function()
				if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
					pcall(apply_highlights_gradient, state.buf, lines, cfg, timestr)
				end
			end, 60)
		end
		pcall(function()
			local ok = pcall(function()
				vim.api.nvim_win_set_config(state.win, main_cfg)
			end)
			if not ok then
				pcall(vim.api.nvim_win_close, state.win, true)
				local buf_m, win_m = open_floating(lines, main_cfg)
				if win_m and vim.api.nvim_win_is_valid(win_m) then
					pcall(apply_highlights_gradient, buf_m, lines, cfg, timestr)
					vim.defer_fn(function()
						if buf_m and vim.api.nvim_buf_is_valid(buf_m) then
							pcall(apply_highlights_gradient, buf_m, lines, cfg, timestr)
						end
					end, 60)
				end
				state.buf, state.win = buf_m, win_m
			end
		end)
	end
end

-- timer/helpers
local function start_timer()
	if state.timer_running then
		return
	end
	local timer = vim.loop.new_timer()
	if not timer then
		state.timer_running = true
		vim.schedule(render_once)
		local function loop()
			if not state.timer_running then
				return
			end
			render_once()
			vim.defer_fn(loop, state.cfg.interval)
		end
		vim.defer_fn(loop, state.cfg.interval)
		state.timer = nil
		return
	end
	vim.schedule(render_once)
	local wrapped = vim.schedule_wrap(function()
		if state.active then
			render_once()
		end
	end)
	local ok = pcall(function()
		timer:start(0, state.cfg.interval, wrapped)
	end)
	if not ok then
		pcall(function()
			timer:close()
		end)
		return
	end
	state.timer = timer
	state.timer_running = true
end

local function stop_and_cleanup()
	if state.timer then
		pcall(function()
			state.timer:stop()
		end)
		pcall(function()
			state.timer:close()
		end)
		state.timer = nil
		state.timer_running = false
	else
		state.timer_running = false
	end
	pcall(function()
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			vim.api.nvim_win_close(state.win, true)
		end
	end)
	state.win = nil
	state.buf = nil
	pcall(function()
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.api.nvim_buf_clear_namespace, b, state.ns, 0, -1)
			end
		end
	end)
end

-- public API
function M.toggle()
	if state.active then
		state.active = false
		stop_and_cleanup()
	else
		state.active = true
		if not state.augroup then
			state.augroup = vim.api.nvim_create_augroup("ClockNvimAG", { clear = false })
			vim.api.nvim_create_autocmd({ "VimResized" }, {
				group = state.augroup,
				callback = function()
					vim.schedule(function()
						if state.active then
							render_once()
						end
					end)
				end,
			})
			vim.api.nvim_create_autocmd({ "VimLeavePre", "BufDelete" }, {
				group = state.augroup,
				callback = function()
					stop_and_cleanup()
				end,
			})
		end
		start_timer()
	end
end

function M.start()
	if not state.active then
		M.toggle()
	end
end

function M.stop()
	if state.active then
		M.toggle()
	end
end

function M.is_active()
	return state.active
end

-- setup: accept options, create command and optional keymap
function M.setup(user_cfg)
	if user_cfg and type(user_cfg) == "table" then
		state.cfg = vim.tbl_deep_extend("force", {}, DEFAULTS, user_cfg)
	end
	-- create initial small hl groups for fallbacks
	create_gradient_highlights({ state.cfg.gradient.from })
	-- create user command
	if vim.api.nvim_create_user_command then
		pcall(function()
			vim.api.nvim_create_user_command(state.cfg.cmd, function()
				M.toggle()
			end, { desc = "Toggle ClockNvim" })
		end)
	end
	-- keymap (if desired)
	if state.cfg.map ~= false then
		local existing = vim.fn.maparg("<leader>ck", "n")
		if existing == "" then
			pcall(function()
				vim.keymap.set("n", "<leader>ck", function()
					M.toggle()
				end, { desc = "Toggle clock.nvim", silent = true })
			end)
		end
	end
end

return M
