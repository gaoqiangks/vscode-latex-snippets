local M = {}

-- Track loaded packages
M.packages = {}
-- Cache for file existence to avoid repeated I/O
M.file_cache = {}

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
    if source:sub(1, 1) == '@' then
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
    if vim.b.vimtex == nil then
        return
    end
    
    -- Create a unique identifier for the current vimtex state
    local current_state = vim.b.vimtex.documentclass or ""
    local pkgs = vim.b.vimtex.packages or {}
    
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
    
    -- Get packages from vimtex
    local class = "class-" .. vim.b.vimtex.documentclass
    
    -- Always include these
    pkgs["_environments"] = 1
    pkgs["_commands"] = 1
    pkgs[class] = 1
    
    -- Collect all packages to load
    local packages_to_load = {}
    for pkg, _ in pairs(pkgs) do
        if not M.packages[pkg] then
            M.packages[pkg] = 1
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
            require("luasnip.loaders.from_vscode").load_standalone({ path = pkg_json })
        end
    end
end

-- Debounced version of reload_snippets to prevent excessive calls
local reload_debounced = (function()
    local timer = nil
    local pending = false
    
    return function()
        if timer then
            timer:close()
            timer = nil
        end
        
        if not pending then
            pending = true
            timer = vim.defer_fn(function()
                M.reload_snippets()
                pending = false
            end, 100) -- Debounce for 100ms
        end
    end
end)()

-- Setup function
M.setup = function()
    -- Clear caches when starting
    M.packages = {}
    M.file_cache = {}
    M.last_vimtex_state = nil
    
    -- Set up autocommands with less frequent triggers
    vim.api.nvim_create_autocmd("User", {
        pattern = "VimtexEventInitPost",
        callback = function()
            -- Clear caches when vimtex is reinitialized
            M.packages = {}
            M.file_cache = {}
            M.last_vimtex_state = nil
            reload_debounced()
        end,
    })
    
    -- Only reload when entering insert mode, not when leaving it
    vim.api.nvim_create_autocmd("ModeChanged", {
        pattern = "*:i", -- Only when entering insert mode
        callback = reload_debounced,
    })
    
    -- Also reload when the buffer is first loaded
    vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "*.tex",
        callback = function()
            -- Small delay to ensure vimtex is initialized
            vim.defer_fn(reload_debounced, 50)
        end,
        once = true,
    })
end

return M
