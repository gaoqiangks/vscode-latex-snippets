local M = {}

-- Track loaded packages
M.packages = {}
-- Cache for file existence to avoid repeated I/O
M.file_cache = {}
-- Track processed buffers to avoid reloading on every BufEnter
M.processed_buffers = {}

-- More efficient file existence check with caching
local function file_exists_cached(name)
    if M.file_cache[name] ~= nil then
        return M.file_cache[name]
    end

    local f = io.open(name, "r")
    local exists = f ~= nil
    if f then
        io.close(f)
    end

    M.file_cache[name] = exists
    return exists
end

-- Get the snippets directory automatically
local function get_snippets_dir()
    -- Get the path of the current Lua file
    local info = debug.getinfo(1, "S")
    local source = info.source
    -- source starts with '@' for files
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    -- Get the directory of this file
    local current_dir = vim.fn.fnamemodify(source, ":p:h")
    -- The snippets directory is in the parent directory under 'snippets'
    local snippets_dir = vim.fn.fnamemodify(current_dir, ":h") .. "/snippets"
    return snippets_dir
end

-- Store the snippets directory
M.snippets_dir = get_snippets_dir()

-- Track the last vimtex state to avoid unnecessary reloads
M.last_vimtex_state = nil

-- Reload snippets based on vimtex packages
M.reload_snippets = function()
    -- Check if vimtex is available
    if not vim.b or not vim.b.vimtex then
        return
    end

    local vimtex = vim.b.vimtex
    local documentclass = vimtex.documentclass or ""

    -- Create a unique identifier for the current vimtex state
    local current_state = documentclass
    local pkgs = vimtex.packages or {}

    -- Sort package names to create a stable state identifier
    local sorted_pkgs = {}
    for pkg, _ in pairs(pkgs) do
        table.insert(sorted_pkgs, pkg)
    end
    table.sort(sorted_pkgs)

    for _, pkg in ipairs(sorted_pkgs) do
        current_state = current_state .. ":" .. pkg
    end

    -- Only reload if the state has changed
    if M.last_vimtex_state == current_state then
        return
    end

    M.last_vimtex_state = current_state

    -- Always include these
    pkgs["_environments"] = 1
    pkgs["_commands"] = 1
    if documentclass ~= "" then
        pkgs["class-" .. documentclass] = 1
    end

    -- Helper function to check if a package matches any regex in a list
    local function matches_any(package_name, regex_list)
        for _, pattern in ipairs(regex_list) do
            if package_name:match(pattern) then
                return true
            end
        end
        return false
    end

    -- Collect all packages to load
    local packages_to_load = {}
    for pkg, _ in pairs(pkgs) do
        -- Check if package should be loaded based on included/excluded lists
        local should_load = true
        
        -- First, check if it's excluded (highest priority)
        if #M.pkgs_excluded > 0 and matches_any(pkg, M.pkgs_excluded) then
            should_load = false
        -- Then, check if included list is specified
        elseif #M.pkgs_included > 0 then
            -- If included list is not empty, only load if it matches
            should_load = matches_any(pkg, M.pkgs_included)
        end
        -- If both lists are empty, load all packages
        
        if should_load and not M.packages[pkg] then
            M.packages[pkg] = true
            local pkg_json = M.snippets_dir .. "/" .. pkg .. ".json"
            if file_exists_cached(pkg_json) then
                table.insert(packages_to_load, pkg_json)
            end
        end
    end

    -- Load all snippets at once if there are any to load
    if #packages_to_load > 0 then
        -- Use a single call to load all snippets
        for _, pkg_json in ipairs(packages_to_load) do
            local ok, err = pcall(function()
                require("luasnip.loaders.from_vscode").load_standalone({ path = pkg_json })
            end)
            if not ok then
                vim.notify("Failed to load snippets from " .. pkg_json .. ": " .. err, vim.log.levels.WARN)
            end
        end
    end
end

-- Debounced version of reload_snippets to prevent excessive calls
local reload_debounced = (function()
    local timer = nil

    return function()
        -- Safely stop the timer if it exists
        if timer then
            pcall(function()
                timer:stop()
                timer:close()
            end)
            timer = nil
        end

        timer = vim.defer_fn(function()
            M.reload_snippets()
            timer = nil
        end, 150) -- Debounce for 150ms
    end
end)()

-- Setup function
M.setup = function(opts)
    opts = opts or {}
    -- Configuration options
    M.pkgs_included = opts.pkgs_included or {}  -- List of regex patterns for packages to include
    M.pkgs_excluded = opts.pkgs_excluded or {}  -- List of regex patterns for packages to exclude (higher priority)
    
    -- Clear caches when starting
    M.packages = {}
    M.file_cache = {}
    M.last_vimtex_state = nil
    M.processed_buffers = {}

    -- Set up autocommands with less frequent triggers
    vim.api.nvim_create_autocmd("User", {
        pattern = "VimtexEventInitPost",
        callback = function()
            -- Clear caches when vimtex is reinitialized
            M.packages = {}
            M.file_cache = {}
            M.last_vimtex_state = nil
            M.processed_buffers = {}
            reload_debounced()
        end,
    })

    -- Reload snippets when saving LaTeX files (in case vimtex state changed)
    vim.api.nvim_create_autocmd("BufWritePost", {
        pattern = "*.tex",
        callback = reload_debounced,
    })

    -- Reload when entering insert mode in LaTeX files
    -- vim.api.nvim_create_autocmd("ModeChanged", {
    --     pattern = "*:i",
    --     callback = function(args)
    --         if vim.bo[args.buf].filetype == "tex" then
    --             reload_debounced()
    --         end
    --     end,
    -- })

    -- Also reload when entering a LaTeX buffer
    vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "*.tex",
        callback = function(args)
            local buf = args.buf
            -- Use a delay to ensure vimtex is initialized
            vim.defer_fn(function()
                reload_debounced()
            end, 100)
        end,
    })
end

return M
