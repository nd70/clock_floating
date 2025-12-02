-- lua/clock_floating.lua
-- ClockFloating: per-cell Gruvbox coloring, no shadow, robust float handling.
-- Fixed: use byte indices for nvim_buf_add_highlight to avoid mixed colors.

local M = {}

local DEFAULTS = {
	fg = "#88ff66",
	winblend = 0,
	border = "none",
	padding = 1,
	scale = 1,
	interval = 1000,
	min_cols = 20,
	min_rows = 6,
	map = true,
	cmd = "ClockFloatingToggle",
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

local KANAGAWA = {
	red = "#D14A3A",
	orange = "#DCA561",
	yellow = "#E6C384",
	green = "#7FB4CA",
	blue = "#7FB4D1",
	purple = "#CBA6D6",
	teal = "#6FB3B8",
	gray = "#81707a",
	light = "#E6D7B6",
	dark = "#2a2a2e",
}

local DIGIT_COLOR = {
	["0"] = KANAGAWA.gray,
	["1"] = KANAGAWA.red,
	["2"] = KANAGAWA.green,
	["3"] = KANAGAWA.yellow,
	["4"] = KANAGAWA.blue,
	["5"] = KANAGAWA.purple,
	["6"] = KANAGAWA.teal,
	["7"] = KANAGAWA.orange,
	["8"] = KANAGAWA.light,
	["9"] = KANAGAWA.dark,
	[":"] = KANAGAWA.blue,
}

local state = {
	cfg = vim.tbl_deep_extend("force", {}, DEFAULTS),
	timer = nil,
	timer_running = false,
	buf = nil,
	win = nil,
	active = false,
	augroup = nil,
	ns = vim.api.nvim_create_namespace("clock_floating_ns"),
}

local function create_digit_highlights()
	for ch, hex in pairs(DIGIT_COLOR) do
		local name = (ch == ":" and "ClockFloatingDigitColon") or ("ClockFloatingDigit" .. ch)
		pcall(vim.api.nvim_set_hl, 0, name, { fg = hex, bg = "NONE" })
	end
	pcall(vim.api.nvim_set_hl, 0, "ClockFloatingMain", { fg = state.cfg.fg, bg = "NONE" })
	pcall(vim.api.nvim_set_hl, 0, "ClockFloatingDigitSpace", { fg = state.cfg.fg, bg = "NONE" })
end

local function hscale_row(row, scale)
	if not row or scale <= 1 then
		return row
	end
	local parts = {}
	for ch in row:gmatch(".") do
		parts[#parts + 1] = ch:rep(scale)
	end
	return table.concat(parts)
end

local function scale_block(block, scale)
	if scale <= 1 then
		return vim.deepcopy(block)
	end
	local out = {}
	for _, row in ipairs(block) do
		local hr = hscale_row(row, scale)
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
			vim.api.nvim_buf_set_option(buf, "filetype", "clockfloating")
		end)
	end
	return buf
end

local function safe_hl_name(dchar)
	if dchar == ":" then
		return "ClockFloatingDigitColon"
	end
	if dchar:match("^%d$") then
		return "ClockFloatingDigit" .. dchar
	end
	if dchar == " " then
		return "ClockFloatingDigitSpace"
	end
	local s = (dchar or ""):gsub("%W", "_")
	if s == "" then
		s = "Unknown"
	end
	return "ClockFloatingDigit" .. s
end

-- ===== FIXED: use byte indices (s,e from string.find) for highlight start/end =====
local function apply_digit_highlights(buf, lines, cfg, time_str)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local ns = state.ns
	pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)

	local sample = DIGITS["0"][1] or "       "
	local block_width = vim.fn.strdisplaywidth(sample) * cfg.scale
	local sep = 1
	local pad = cfg.padding

	-- use time_str directly -> exact per-block digit mapping
	local timechars = {}
	for i = 1, #time_str do
		timechars[i] = time_str:sub(i, i)
	end

	for line_idx = 1, #lines do
		local row = lines[line_idx]
		local start = 1
		while true do
			local s, e = row:find("█", start, true) -- s,e are byte indices (1-based)
			if not s then
				break
			end
			local prefix = row:sub(1, s - 1)
			local display_col = vim.fn.strdisplaywidth(prefix)
			local rel = display_col - pad
			if rel >= 0 then
				local block_index = math.floor(rel / (block_width + sep)) + 1
				local within = rel % (block_width + sep)
				if block_index >= 1 and block_index <= #timechars and within < block_width then
					local digit_char = timechars[block_index] or " "
					local hl = safe_hl_name(digit_char)
					-- nvim_buf_add_highlight expects start/end as character positions (byte indices)
					-- use zero-based start = s-1, exclusive end = e
					pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl, line_idx - 1, s - 1, e)
				end
			end
			start = e + 1
		end
	end
end
-- ===== end fixed highlight application =====

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
		opts.row = math.max(0, ui_rows - opts.height)
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
	local ok, _ = pcall(function()
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

	local timestr = os.date("%H:%M:%S")
	local lines = build_clock_lines(timestr, cfg)
	local main_cfg = make_center_config(lines, cfg)
	main_cfg.winblend = cfg.winblend

	create_digit_highlights()

	if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
		local buf_m, win_m = open_floating(lines, main_cfg)
		if win_m and vim.api.nvim_win_is_valid(win_m) then
			pcall(apply_digit_highlights, buf_m, lines, cfg, timestr)
			vim.defer_fn(function()
				if buf_m and vim.api.nvim_buf_is_valid(buf_m) then
					pcall(apply_digit_highlights, buf_m, lines, cfg, timestr)
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
			pcall(apply_digit_highlights, state.buf, lines, cfg, timestr)
			vim.defer_fn(function()
				if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
					pcall(apply_digit_highlights, state.buf, lines, cfg, timestr)
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
					pcall(apply_digit_highlights, buf_m, lines, cfg, timestr)
					vim.defer_fn(function()
						if buf_m and vim.api.nvim_buf_is_valid(buf_m) then
							pcall(apply_digit_highlights, buf_m, lines, cfg, timestr)
						end
					end, 60)
				end
				state.buf, state.win = buf_m, win_m
			end
		end)
	end
end

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
	local ok, _ = pcall(function()
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

function M.toggle()
	if state.active then
		state.active = false
		stop_and_cleanup()
	else
		state.active = true
		if not state.augroup then
			state.augroup = vim.api.nvim_create_augroup("ClockFloatingAG", { clear = false })
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

function M.setup(user_cfg)
	if user_cfg and type(user_cfg) == "table" then
		state.cfg = vim.tbl_deep_extend("force", {}, DEFAULTS, user_cfg)
	end
	create_digit_highlights()
	if vim.api.nvim_create_user_command then
		pcall(function()
			vim.api.nvim_create_user_command(state.cfg.cmd, function()
				M.toggle()
			end, { desc = "Toggle ClockFloating" })
		end)
	end
	if state.cfg.map ~= false then
		local existing = vim.fn.maparg("<leader>ck", "n")
		if existing == "" then
			pcall(function()
				vim.keymap.set("n", "<leader>ck", function()
					M.toggle()
				end, { desc = "Toggle large floating clock", silent = true })
			end)
		end
	end
end

return M
