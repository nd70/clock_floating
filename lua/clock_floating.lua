-- lua/clock_floating.lua
-- ClockFloating: show a large ASCII/block clock in a centered floating window
-- Single-file plugin, idiomatic Neovim Lua (no Vimscript dependencies).
--
-- Fixes applied:
--  - safe timer lifecycle (no use of nonexistent :is_closing())
--  - no comma-separated "function arguments" mistakes (pcall uses functions)
--  - robust window updates and cleanup
--  - mapping creation controlled by config.map (defaults to true)
--
-- API:
--   require("clock_floating").setup(opts)  -- configure and (optionally) create mapping
--   require("clock_floating").toggle()     -- toggle clock on/off
--   require("clock_floating").start()      -- start (programmatic)
--   require("clock_floating").stop()       -- stop (programmatic)
--   require("clock_floating").is_active()  -- boolean
--
-- Implementation notes:
-- - Uses two floating windows (shadow + main) to render a subtle 3D effect
-- - Uses vim.loop.new_timer for periodic updates; we track timer state in Lua
-- - Uses safe pcall wrappers for all operations that might error
-- - Keeps the underlying buffer visible via winblend

local M = {}

local DEFAULTS = {
	-- Presentation
	fg = "#a8ff60", -- main digit color (gui hex)
	shadow_fg = "#2b5d1a", -- shadow color
	winblend = 40, -- transparency for main window (0-100)
	shadow_winblend = 60, -- transparency for shadow
	border = "none", -- floating window border style
	padding = 2, -- spaces around the clock
	scale = 1, -- integer scale multiplier for digits (1,2,...)
	use_shadow = true, -- draw a shadow window behind the main clock
	interval = 1000, -- update interval in ms
	min_cols = 30, -- minimum terminal columns to show clock
	min_rows = 8, -- minimum terminal rows to show clock
	map = true, -- create <leader>ck mapping by default
	cmd = "ClockFloatingToggle", -- user command name
}

-- block-digit font (5 rows). Use simple block characters
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
	timer = nil, -- uv timer handle
	timer_running = false, -- boolean indicating timer is active
	bufs = { main = nil, shadow = nil },
	wins = { main = nil, shadow = nil },
	active = false,
	augroup = nil,
}

-- Helper: safely pcall a function and ignore errors
local function safe_call(fn)
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn)
	if not ok then
		vim.schedule(function()
			-- Avoid noisy errors; you can uncomment the following for debugging:
			-- vim.notify("clock_floating error: " .. tostring(err), vim.log.levels.DEBUG)
		end)
	end
end

-- Create highlights (idempotent)
local function create_highlights(cfg)
	-- use 'default' so user custom highlights are not overwritten
	vim.cmd(string.format("highlight default ClockFloatingMain guifg=%s guibg=NONE", cfg.fg))
	vim.cmd(string.format("highlight default ClockFloatingShadow guifg=%s guibg=NONE", cfg.shadow_fg))
end

-- horizontal scale a row by repeating each character 'scale' times
local function hscale_row(row, scale)
	if scale <= 1 then
		return row
	end
	local parts = {}
	for ch in row:gmatch(".") do
		parts[#parts + 1] = ch:rep(scale)
	end
	return table.concat(parts)
end

-- scale block (rows) both vertically and horizontally
local function scale_block(block, scale)
	if scale <= 1 then
		return vim.deepcopy(block)
	end
	local out = {}
	for _, row in ipairs(block) do
		local hr = hscale_row(row, scale)
		for i = 1, scale do
			table.insert(out, hr)
		end
	end
	return out
end

-- Build lines for time "HH:MM:SS"
local function build_clock_lines(time_str, cfg)
	local chars = {}
	for ch in time_str:gmatch(".") do
		table.insert(chars, ch)
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

-- Compute display size of lines
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

-- Create a scratch buffer
local function make_buf()
	local buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "filetype", "clockfloating")
	end
	return buf
end

-- Open a floating window for given lines and config. Returns buf, win.
local function open_floating(lines, opts)
	local buf = make_buf()
	if not buf then
		return nil, nil
	end
	-- ensure modifiable so we can set lines
	safe_call(function()
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end)
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

-- Compute centered float config for given lines
local function make_center_config(lines, cfg, offset_row, offset_col)
	local rows, cols = compute_size(lines)
	local ui_cols = vim.o.columns
	local ui_rows = vim.o.lines - vim.o.cmdheight
	local row = math.max(0, math.floor((ui_rows - rows) / 2) + (offset_row or 0))
	local col = math.max(0, math.floor((ui_cols - cols) / 2) + (offset_col or 0))
	return {
		relative = "editor",
		row = row,
		col = col,
		width = cols,
		height = rows,
		style = "minimal",
		border = cfg.border,
		winblend = cfg.winblend,
	}
end

-- Render once (update buffers/wins). Safe and idempotent.
local function render_once()
	if not state.active then
		return
	end
	local cfg = state.cfg

	-- hide/close if terminal too small
	if vim.o.columns < cfg.min_cols or (vim.o.lines - vim.o.cmdheight) < cfg.min_rows then
		-- close windows if open
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
		shadow_cfg.row = shadow_cfg.row + 1
		shadow_cfg.col = shadow_cfg.col + 2
		shadow_cfg.winblend = cfg.shadow_winblend
	end

	-- Create highlights
	create_highlights(cfg)

	-- Shadow (create or update)
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
			-- update buffer contents
			if state.bufs.shadow and vim.api.nvim_buf_is_valid(state.bufs.shadow) then
				safe_call(function()
					vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", true)
					vim.api.nvim_buf_set_lines(state.bufs.shadow, 0, -1, false, lines)
					vim.api.nvim_buf_set_option(state.bufs.shadow, "modifiable", false)
				end)
			end
			-- reposition if possible, otherwise recreate
			safe_call(function()
				local ok, res = pcall(function()
					vim.api.nvim_win_set_config(state.wins.shadow, shadow_cfg)
				end)
				if not ok then
					-- recreate
					if state.wins.shadow and vim.api.nvim_win_is_valid(state.wins.shadow) then
						pcall(vim.api.nvim_win_close, state.wins.shadow, true)
					end
					local buf_s, win_s = open_floating(lines, shadow_cfg)
					if win_s and vim.api.nvim_win_is_valid(win_s) then
						vim.api.nvim_win_set_option(win_s, "winhl", "Normal:ClockFloatingShadow")
					end
					state.bufs.shadow, state.wins.shadow = buf_s, win_s
				end
			end)
		end
	end

	-- Main window (create or update)
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
			local ok, res = pcall(function()
				vim.api.nvim_win_set_config(state.wins.main, main_cfg)
			end)
			if not ok then
				-- recreate
				if state.wins.main and vim.api.nvim_win_is_valid(state.wins.main) then
					pcall(vim.api.nvim_win_close, state.wins.main, true)
				end
				local buf_m, win_m = open_floating(lines, main_cfg)
				if win_m and vim.api.nvim_win_is_valid(win_m) then
					vim.api.nvim_win_set_option(win_m, "winhl", "Normal:ClockFloatingMain")
				end
				state.bufs.main, state.wins.main = buf_m, win_m
			end
		end)
	end
end

-- Start the repeating timer (idempotent)
local function start_timer()
	if state.timer_running then
		return
	end

	-- create uv timer
	local timer = vim.loop.new_timer()
	if not timer then
		-- fallback: don't crash; just use vim.defer_fn as last resort
		state.timer_running = true
		-- first render immediately on schedule
		vim.schedule(render_once)
		-- schedule deferred loop with vim.defer_fn (not ideal but safe)
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

	-- immediate render
	vim.schedule(render_once)

	-- start the timer safely
	-- wrap UI updates inside vim.schedule_wrap so they run on the main loop
	local wrapped = vim.schedule_wrap(function()
		if not state.active then
			return
		end
		render_once()
	end)

	local ok, err = pcall(function()
		timer:start(0, state.cfg.interval, wrapped)
	end)
	if not ok then
		-- failed to start; close if created
		pcall(function()
			timer:close()
		end)
		return
	end

	state.timer = timer
	state.timer_running = true
end

-- Stop and clean up timer, windows, bufs
local function stop_and_cleanup()
	-- stop timer safely
	if state.timer then
		-- stopping/closing timer inside pcall wrappers
		safe_call(function()
			-- stop may error if timer already stopped; pcall will catch it
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

	-- close windows if valid
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

-- Public: toggle
function M.toggle()
	if state.active then
		state.active = false
		stop_and_cleanup()
	else
		state.active = true
		-- ensure augroup exists and autocmds set
		if not state.augroup then
			state.augroup = vim.api.nvim_create_augroup("ClockFloatingAG", { clear = false })
			-- re-render on resize
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
			-- cleanup on exit
			vim.api.nvim_create_autocmd({ "VimLeavePre", "BufDelete" }, {
				group = state.augroup,
				callback = function()
					stop_and_cleanup()
				end,
			})
		end
		-- start timer
		start_timer()
	end
end

-- Public: start (ensure active)
function M.start()
	if not state.active then
		M.toggle()
	end
end

-- Public: stop (ensure inactive)
function M.stop()
	if state.active then
		M.toggle()
	end
end

function M.is_active()
	return state.active
end

-- Setup with optional user config
function M.setup(user_cfg)
	if user_cfg and type(user_cfg) == "table" then
		state.cfg = vim.tbl_deep_extend("force", {}, DEFAULTS, user_cfg)
	end

	-- create highlights
	create_highlights(state.cfg)

	-- create user command (idempotent)
	if vim.api.nvim_create_user_command then
		-- Using vim.api to avoid compatibility pitfalls
		safe_call(function()
			vim.api.nvim_create_user_command(state.cfg.cmd, function()
				M.toggle()
			end, { desc = "Toggle ClockFloating" })
		end)
	end

	-- create mapping if requested and not already mapped
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
