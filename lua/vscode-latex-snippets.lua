local M = {}

local uv = vim.uv or vim.loop
local luasnip = require("luasnip")
local parse_snippet = luasnip.parser.parse_snippet
local snippet_proxy = require("luasnip.nodes.snippetProxy")
local snippet_source = luasnip.snippet_source

M.packages = {}
M.base_snippets = {}
M.command_cache = {}
M.project_states = {}
M.scan_generation = 0

local query_sources = {
	[[
    (new_command_definition
      declaration: (curly_group_command_name
        command: (command_name) @cmdname)
      .
      implementation: (curly_group) @implementation)
    ]],
	[[
    (new_command_definition
      declaration: (curly_group_command_name
        command: (command_name) @cmdname)
      argc: (brack_group_argc
        value: (argc) @argc)
      implementation: (curly_group) @implementation)
    ]],
}

local command_queries

local function get_command_queries()
	if command_queries then
		return command_queries
	end

	command_queries = {}
	for i, source in ipairs(query_sources) do
		local ok, query = pcall(vim.treesitter.query.parse, "latex", source)
		if not ok then
			command_queries = {}
			vim.notify_once(
				"vscode-latex-snippets: Tree-sitter LaTeX parser unavailable; dynamic command scanning is disabled",
				vim.log.levels.WARN
			)
			break
		end
		command_queries[i] = query
	end
	return command_queries
end

local function read_file(path, size)
	local fd = uv.fs_open(path, "r", 438)
	if not fd then
		return nil
	end
	local data = uv.fs_read(fd, size, 0)
	uv.fs_close(fd)
	return data
end

local function first_node(value)
	if type(value) == "table" then
		return value[1]
	end
	return value
end

local function strip_comments(source)
	local output = {}
	for original in (source .. "\n"):gmatch("(.-)\n") do
		local line = original
		local start = 1
		while true do
			local index = line:find("%", start, true)
			if not index then
				break
			end
			local escapes = 0
			local cursor = index - 1
			while cursor > 0 and line:sub(cursor, cursor) == "\\" do
				escapes = escapes + 1
				cursor = cursor - 1
			end
			if escapes % 2 == 0 then
				line = line:sub(1, index - 1)
				break
			end
			start = index + 1
		end
		output[#output + 1] = line
	end
	return table.concat(output, "\n")
end

local function get_includes(source)
	source = strip_comments(source)
	local includes = {}
	for _, command in ipairs({ "input", "include", "subfile" }) do
		for path in source:gmatch("\\" .. command .. "%s*{%s*([^}]-)%s*}") do
			includes[#includes + 1] = { path = path }
		end
	end
	for _, command in ipairs({ "import", "subimport", "inputfrom", "subinputfrom", "includefrom", "subincludefrom" }) do
		local pattern = "\\" .. command .. "%s*{%s*([^}]-)%s*}%s*{%s*([^}]-)%s*}"
		for directory, path in source:gmatch(pattern) do
			includes[#includes + 1] = { directory = directory, path = path }
		end
	end
	return includes
end

local function get_newcommands(path)
	local stat = uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return {}, {}
	end

	local stamp = table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
	local cached = M.command_cache[path]
	if cached and cached.stamp == stamp then
		return cached.commands, cached.includes
	end

	local source = read_file(path, stat.size)
	if not source then
		return {}, {}
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, source, "latex")
	if not ok then
		return {}, {}
	end
	local trees = parser:parse()
	if not trees or not trees[1] then
		return {}, {}
	end

	local commands = {}
	local seen = {}
	local root = trees[1]:root()
	for _, query in ipairs(get_command_queries()) do
		local captures = {}
		for id, name in ipairs(query.captures) do
			captures[name] = id
		end
		for _, match in query:iter_matches(root, source, 0, -1) do
			local cmd_node = first_node(match[captures.cmdname])
			local implementation_node = first_node(match[captures.implementation])
			if cmd_node and implementation_node then
				local cmd = vim.treesitter.get_node_text(cmd_node, source)
				local argc_node = captures.argc and first_node(match[captures.argc])
				local argc = argc_node and tonumber(vim.treesitter.get_node_text(argc_node, source)) or nil
				local key = cmd .. ":" .. tostring(argc or 0)
				if not seen[key] then
					seen[key] = true
					commands[#commands + 1] = {
						cmd = cmd,
						argc = argc,
						implementation = vim.treesitter.get_node_text(implementation_node, source),
					}
				end
			end
		end
	end

	local includes = get_includes(source)
	M.command_cache[path] = { stamp = stamp, commands = commands, includes = includes }
	return commands, includes
end

local function get_snippets_dir()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	return vim.fs.dirname(vim.fs.dirname(source)) .. "/snippets"
end

M.snippets_dir = get_snippets_dir()

local snippet_filetypes = { "tex", "plaintex" }

local function snippet_key(name, filetype)
	return "vscode_latex_snippets_" .. name .. "_" .. filetype
end

local function read_snippet_data(path)
	local stat = uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil, "file does not exist"
	end

	local contents = read_file(path, stat.size)
	if not contents then
		return nil, "file could not be read"
	end

	local ok, data = pcall(vim.json.decode, contents)
	if not ok or type(data) ~= "table" then
		return nil, ok and "top-level value is not an object" or data
	end

	return data
end

local function parse_snippet_data(data, path)
	local snippets = {}
	for name, parts in pairs(data) do
		if type(parts) == "table" and parts.prefix and parts.body then
			local prefixes = type(parts.prefix) == "table" and parts.prefix or { parts.prefix }
			local body = type(parts.body) == "table" and table.concat(parts.body, "\n") or parts.body
			local config = parts.luasnip or {}
			for _, prefix in ipairs(prefixes) do
				if type(prefix) == "string" and type(body) == "string" then
					local parsed_ok, snippet = pcall(snippet_proxy, {
						trig = prefix,
						name = name,
						desc = parts.description or name,
						wordTrig = config.wordTrig,
						priority = config.priority,
						snippetType = config.autotrigger and "autosnippet" or "snippet",
					}, body)
					if not parsed_ok then
						return nil, ("snippet %s could not be parsed: %s"):format(name, snippet)
					end
					snippet._source = snippet_source.from_location(path)
					snippets[#snippets + 1] = snippet
				end
			end
		end
	end
	return snippets
end

local function unload_snippet_file(name)
	for _, filetype in ipairs(snippet_filetypes) do
		luasnip.add_snippets(filetype, {}, {
			type = "snippets",
			key = snippet_key(name, filetype),
		})
	end
end

local function load_snippet_file(name)
	local path = M.snippets_dir .. "/" .. name .. ".json"
	local data, err = read_snippet_data(path)
	if not data then
		unload_snippet_file(name)
		return false, err
	end
	-- Snippet objects cannot be shared by two filetypes because LuaSnip assigns
	-- each object an id while adding it. Parse once per target filetype instead.
	for _, filetype in ipairs(snippet_filetypes) do
		local snippets, parse_err = parse_snippet_data(data, path)
		if not snippets then
			unload_snippet_file(name)
			return false, parse_err
		end
		luasnip.add_snippets(filetype, snippets, {
			type = "snippets",
			key = snippet_key(name, filetype),
		})
	end
	return true
end

local function load_base_snippets()
	for _, name in ipairs({ "environments", "commands" }) do
		if not M.base_snippets[name] then
			local ok, err = load_snippet_file(name)
			if ok then
				M.base_snippets[name] = true
			else
				vim.notify(("Failed to load %s snippets: %s"):format(name, err), vim.log.levels.WARN)
			end
		end
	end
end

local function matches_any(name, patterns)
	for _, pattern in ipairs(patterns) do
		if name:match(pattern) then
			return true
		end
	end
	return false
end

local function load_package_snippets(vimtex)
	local packages = vim.tbl_keys(vimtex.packages or {})
	if vimtex.documentclass and vimtex.documentclass ~= "" then
		packages[#packages + 1] = "class-" .. vimtex.documentclass
	end

	local wanted = {}
	for _, package in ipairs(packages) do
		local enabled = not matches_any(package, M.pkgs_excluded)
			and (#M.pkgs_included == 0 or matches_any(package, M.pkgs_included))
		if enabled then
			wanted[package] = true
		end
	end

	local unloaded = false
	for package in pairs(M.packages) do
		if not wanted[package] then
			unload_snippet_file(package)
			M.packages[package] = nil
			unloaded = true
		end
	end
	if unloaded then
		luasnip.clean_invalidated({ inv_limit = 0 })
	end

	for package in pairs(wanted) do
		if not M.packages[package] then
			local ok, err = load_snippet_file(package)
			if ok then
				M.packages[package] = true
			elseif err ~= "file does not exist" then
				vim.notify(("Failed to load package %s snippets: %s"):format(package, err), vim.log.levels.WARN)
			end
		end
	end
end

local function generate_latex_cmds(definitions)
	M.new_commands = definitions
	local snippets = {}
	for _, definition in ipairs(definitions) do
		local trigger = definition.cmd:gsub("^\\", "")
		if trigger ~= "" then
			local body = "\\\\" .. trigger
			for i = 1, definition.argc or 0 do
				body = body .. "{$" .. i .. "}"
			end
			snippets[#snippets + 1] = parse_snippet({
				trig = trigger,
				desc = definition.implementation,
			}, body)
		end
	end

	luasnip.add_snippets("tex", snippets, {
		type = "snippets",
		key = "dynamic_latex_defs_tex",
	})
	luasnip.add_snippets("plaintex", snippets, {
		type = "snippets",
		key = "dynamic_latex_defs_plaintex",
	})
end

local function get_project(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local vimtex = vim.b[bufnr].vimtex
	if type(vimtex) ~= "table" or not vimtex.tex then
		return nil
	end

	local state
	local id = vim.b[bufnr].vimtex_id
	if type(id) == "number" then
		local ok, state_module = pcall(require, "vimtex.state")
		if ok then
			state = state_module.get(id)
		end
	end
	state = state or vimtex

	local root = state.root or vim.fs.dirname(state.tex)
	local files = { vim.fs.normalize(state.tex) }
	local discover_sources = true
	-- Reuse VimTeX's list only when another feature has already populated it.
	-- Calling get_sources() here would synchronously parse the whole project.
	if type(state.__sources) == "table" then
		files = {}
		discover_sources = false
		for _, source in ipairs(state.__sources) do
			files[#files + 1] = vim.fs.normalize(vim.fs.joinpath(root, source))
		end
	end

	return {
		key = vim.fs.normalize(state.tex),
		files = files,
		root = root,
		discover_sources = discover_sources,
		vimtex = vimtex,
	}
end

local function scan_project(project, generation)
	local definitions = {}
	local seen_definitions = {}
	local seen_files = {}
	local queued_files = {}
	for _, path in ipairs(project.files) do
		queued_files[path] = true
	end
	local index = 1

	local function enqueue_include(parent, include)
		local path = include.path
		if path == "" or path:find("\\", 1, true) then
			return
		end
		if not path:match("%.[%w]+$") then
			path = path .. ".tex"
		end

		local base = vim.fs.dirname(parent)
		if include.directory and include.directory ~= "" then
			base = vim.fs.joinpath(base, include.directory)
		end
		local candidate = vim.fs.normalize(vim.fs.joinpath(base, path))
		if not uv.fs_stat(candidate) then
			candidate = vim.fs.normalize(vim.fs.joinpath(project.root, include.directory or "", path))
		end
		if uv.fs_stat(candidate) and not queued_files[candidate] then
			queued_files[candidate] = true
			project.files[#project.files + 1] = candidate
		end
	end

	local function scan_next()
		if generation ~= M.scan_generation then
			return
		end

		while index <= #project.files do
			local path = project.files[index]
			index = index + 1
			if not seen_files[path] then
				seen_files[path] = true
				local commands, includes = get_newcommands(path)
				for _, command in ipairs(commands) do
					local key = command.cmd .. ":" .. tostring(command.argc or 0)
					if not seen_definitions[key] then
						seen_definitions[key] = true
						definitions[#definitions + 1] = command
					end
				end
				if project.discover_sources then
					for _, include in ipairs(includes) do
						enqueue_include(path, include)
					end
				end
				vim.defer_fn(scan_next, M.scan_interval)
				return
			end
		end

		M.project_states[project.key] = definitions
		generate_latex_cmds(definitions)
		M.active_project_key = project.key
		M.scanning_project_key = nil
		vim.api.nvim_exec_autocmds("User", {
			pattern = "VscodeLatexSnippetsReloaded",
			modeline = false,
			data = { project = project.key, files = #project.files },
		})
	end

	scan_next()
end

function M.reload_snippets(bufnr, force)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	load_base_snippets()
	local project = get_project(bufnr)
	if not project then
		return
	end

	load_package_snippets(project.vimtex)
	if not M.dynamic_commands then
		return
	end
	if M.project_states[project.key] and not force then
		if M.active_project_key ~= project.key then
			generate_latex_cmds(M.project_states[project.key])
			M.active_project_key = project.key
		end
		return
	end
	if M.scanning_project_key == project.key and not force then
		return
	end

	M.scan_generation = M.scan_generation + 1
	M.scanning_project_key = project.key
	scan_project(project, M.scan_generation)
end

local timer
local pending_bufnr
local pending_force = false

local function reload_debounced(bufnr, force)
	pending_bufnr = bufnr
	pending_force = pending_force or force
	if timer then
		timer:stop()
		timer:close()
	end
	timer = vim.defer_fn(function()
		timer = nil
		local target, do_force = pending_bufnr, pending_force
		pending_bufnr, pending_force = nil, false
		M.reload_snippets(target, do_force)
	end, M.debounce)
end

function M.setup(opts)
	opts = opts or {}
	M.pkgs_included = opts.pkgs_included or {}
	M.pkgs_excluded = opts.pkgs_excluded or {}
	M.dynamic_commands = opts.dynamic_commands ~= false
	M.debounce = opts.debounce or 100
	M.scan_interval = opts.scan_interval or 1
	load_base_snippets()

	local group = vim.api.nvim_create_augroup("VscodeLatexSnippets", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "VimtexEventInitPost",
		callback = function(args)
			reload_debounced(args.buf, false)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*.tex",
		callback = function(args)
			local path = vim.api.nvim_buf_get_name(args.buf)
			M.command_cache[path] = nil
			local vimtex = vim.b[args.buf].vimtex
			if vimtex and vimtex.tex then
				M.project_states[vim.fs.normalize(vimtex.tex)] = nil
			end
			reload_debounced(args.buf, true)
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = "*.tex",
		callback = function(args)
			reload_debounced(args.buf, false)
		end,
	})
end

return M
