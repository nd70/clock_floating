-- lua/clock_floating.lua
-- ClockFloating (corrected): show a large ASCII/block clock in a centered floating window
-- Fixes:
--  - Clamp width/height to editor size and clamp row/col so floats never start off-screen
--  - Safe timer lifecycle (no :is_closing)
--  - Safe pcall wrappers, idempotent behavior
--  - Mapping controlled by cfg.map

local M = {}

local DEFAULTS = {
	fg = "#a8ff60",
	shadow_fg = "#2b5d1a",
	winblend = 40,
	shadow_winblend = 60,
	border = "none",
	padding = 2,
	scale = 1,
	use_shadow = true,
	interval = 1000,
	min_cols = 30,
	min_rows = 8,
	map = true,
	cmd = "ClockFloatingToggle",
}

local DIGITS = {
	["0"] = {
		" █████ ",
		"█     █",
		"█     █",
		"█     █",
		" █████ ",
	},
	["1"] = {
		"   █   ",
		"  ██   ",
		"   █   ",
		"   █   ",
		"  ███  ",
	},
	["2"] = {
		" █████ ",
		"█     █",
		"    ██ ",
		"  ██   ",
		"███████",
	},
	["3"] = {
		" █████ ",
		"█     █",
		"   ███ ",
		"█     █",
		" █████ ",
	},
	["4"] = {
		"█   ██ ",
		"█   ██ ",
		"███████",
		"    ██ ",
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
		"    ██ ",
		"   ██  ",
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

-- internal state
local state = {
	cfg = vim.tbl_deep_extend("force", {}, DEFAULTS),
	timer = nil,
	timer_running = false,
	bufs = { main = nil, shadow = nil },
	wins = { main = nil, shadow = nil },
	active = false,
	augroup = nil,
}

local function safe_call(fn)
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn)
	if not ok then
		-- Silent by default. Uncomment to debug:
		-- vim.schedule(function() vim.notify("clock_floating error: " .. tostring(err), vim.log.levels.DEBUG) end)
	end
end

local function create_highlights(cfg)
	safe_call(function()
		vim.cmd(string.format("highlight default ClockFloatingMain guifg=%s guibg=NONE", cfg.fg))
		vim.cmd(string.format("highlight default ClockFloatingShadow guifg=%s guibg=NONE", cfg.shadow_fg))
	end)
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
		local block = DIGITS[ch] or DIGITS[" "]
		blocks[#blocks + 1] = scale_block(block, cfg.scale)
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
		safe_call(function()
			vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
			vim.api.nvim_buf_set_option(buf, "filetype", "clockfloating")
		end)
	end
	return buf
end

local function open_floating(lines, opts)
	local buf = make_buf()
	if not buf then
		return nil, nil
	end
	safe_call(function()
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end)
	-- ensure width/height are not bigger than editor size
	local ui_cols = vim.o.columns
	local ui_rows = vim.o.lines - vim.o.cmdheight
	if opts.width > ui_cols then
		opts.width = math.max(1, ui_cols - 2)
	end
	if opts.height > ui_rows then
		opts.height = math.max(1, ui_rows - 2)
	end
	-- clamp col/row
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

	local win = nil
	safe_call(function()
		win = vim.api.nvim_open_win(buf, false, opts)
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_option(win, "winblend", opts.winblend or 0)
			vim.api.nvim_win_set_option(win, "wrap", false)
			vim.api.nvim_win_set_option(win, "cursorline", false)
			vim.api.nvim_win_set_option(win, "signcolumn", "no")
			vim.api.nvim_win_set_option(win, "foldcolumn", "0")
		end
	end)
	return buf, win
end

local function make_center_config(lines, cfg, offset_row, offset_col)
	local rows, cols = compute_size(lines)
	-- clamp width/height to editor size (-2 to leave a small margin)
	local ui_cols = vim.o.columns
	local ui_rows = vim.o.lines - vim.o.cmdheight
	local width = math.min(cols, math.max(1, ui_cols - 2))
	local height = math.min(rows, math.max(1, ui_rows - 2))
	local col = math.floor((ui_cols - width) / 2) + (offset_col or 0)
	local row = math.floor((ui_rows - height) / 2) + (offset_row or 0)
	-- clamp to visible range
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

	return {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = cfg.border,
		winblend = cfg.winblend,
	}
end

local function render_once()
	if not state.active then
		return
	end
	local cfg = state.cfg

	-- hide if terminal too small according to config
	if vim.o.columns < cfg.min_cols or (vim.o.lines - vim.o.cmdheight) < cfg.min_rows then
		safe_call(function()
			if state.wins.main and vim.api.nvim_win_is_valid(state.wins.main) then
				vim.api.nvim_win_close(state.wins.main, true)
			end
			if state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow) then
				vim.api.nvim_win_close(state.wins.shadow, true)
			end
		end)
		state.wins.main, state.wins.shadow = nil, nil
		state.bufs.main, state.bufs.shadow = nil, nil
		return
	end

	local timestr = os.date("%H:%M:%S")
	local lines = build_clock_lines(timestr, cfg)

	local main_cfg = make_center_config(lines, cfg, 0, 0)
	main_cfg.winblend = cfg.winblend

	local shadow_cfg = nil
	if cfg.use_shadow then
		shadow_cfg = vim.deepcopy(main_cfg)
		shadow_cfg.row = math.min(shadow_cfg.row + 1, vim.o.lines - vim.o.cmdheight - 1)
		shadow_cfg.col = math.min(shadow_cfg.col + 2, math.max(0, vim.o.columns - 1))
		shadow_cfg.winblend = cfg.shadow_winblend
	end

	create_highlights(cfg)

	-- Shadow
	if cfg.use_shadow then
		if not (state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow)) then
			local buf_s, win_s = open_floating(lines, shadow_cfg)
			if win_s and vim.api.nvim_win_is_valid(win_s) then
				safe_call(function()
					vim.api.nvim_win_set_option(win_s, "winhl", "Normal:ClockFloatingShadow")
				end)
			end
			state.bufs.shadow = buf_s
			state.wins.shadow = win_s
		else
			if state.bufs.shadow and vim.api.nvim_buf_is_valid(state.bufs.shadow) then
				safe_call(function()
					vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", true)
					vim.api.nvim_buf_set_lines(state.bufs.shadow, 0, -1, false, lines)
					vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", false)
				end)
			end
			safe_call(function()
				local ok = pcall(function()
					vim.api.nvim_win_set_config(state.wins.shadow, shadow_cfg)
				end)
				if not ok then
					pcall(vim.api.nvim_win_close, state.wins.shadow, true)
					local buf_s, win_s = open_floating(lines, shadow_cfg)
					if win_s and vim.api.nvim_win_is_valid(win_s) then
						vim.api.nvim_win_set_option(win_s, "winhl", "Normal:ClockFloatingShadow")
					end
					state.bufs.shadow, state.wins.shadow = buf_s, win_s
				end
			end)
		end
	end

	-- Main
	if not (state.wins.main and vim.api.nvim_win_is_valid(state.wins.main)) then
		local buf_m, win_m = open_floating(lines, main_cfg)
		if win_m and vim.api.nvim_win_is_valid(win_m) then
			safe_call(function()
				vim.api.nvim_win_set_option(win_m, "winhl", "Normal:ClockFloatingMain")
			end)
		end
		state.bufs.main, state.wins.main = buf_m, win_m
	else
		if state.bufs.main and vim.api.nvim_buf_is_valid(state.bufs.main) then
			safe_call(function()
				vim.api.nvim_buf_set_option(state.bufs.main, "modifiable", true)
				vim.api.nvim_buf_set_lines(state.bufs.main, 0, -1, false, lines)
				vim.api.nvim_buf_set_option(state.bufs.main, "modifiable", false)
			end)
		end
		safe_call(function()
			local ok = pcall(function()
				vim.api.nvim_win_set_config(state.wins.main, main_cfg)
			end)
			if not ok then
				pcall(vim.api.nvim_win_close, state.wins.main, true)
				local buf_m, win_m = open_floating(lines, main_cfg)
				if win_m and vim.api.nvim_win_is_valid(win_m) then
					vim.api.nvim_win_set_option(win_m, "winhl", "Normal:ClockFloatingMain")
				end
				state.bufs.main, state.wins.main = buf_m, win_m
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
	local ok, err = pcall(function()
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
		safe_call(function()
			state.timer:stop()
		end)
		safe_call(function()
			state.timer:close()
		end)
		state.timer = nil
		state.timer_running = false
	else
		state.timer_running = false
	end

	safe_call(function()
		if state.wins.main and vim.api.nvim_win_is_valid(state.wins.main) then
			vim.api.nvim_win_close(state.wins.main, true)
		end
		if state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow) then
			vim.api.nvim_win_close(state.wins.shadow, true)
		end
	end)

	state.wins.main = nil
	state.wins.shadow = nil
	state.bufs.main = nil
	state.bufs.shadow = nil
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
	create_highlights(state.cfg)

	if vim.api.nvim_create_user_command then
		safe_call(function()
			vim.api.nvim_create_user_command(state.cfg.cmd, function()
				M.toggle()
			end, { desc = "Toggle ClockFloating" })
		end)
	end

	if state.cfg.map ~= false then
		local existing = vim.fn.maparg("<leader>ck", "n")
		if existing == "" then
			safe_call(function()
				vim.keymap.set("n", "<leader>ck", function()
					M.toggle()
				end, { desc = "Toggle large floating clock", silent = true })
			end)
		end
	end
end

return M
