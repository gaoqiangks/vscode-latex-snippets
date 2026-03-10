local M = {}

-- Track loaded packages
M.packages = {}

-- Helper function to check if a file exists
local file_exists = function(name)
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
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

-- Reload snippets based on vimtex packages
M.reload_snippets = function()
    if vim.b.vimtex == nil then
        return
    end
    
    -- Get packages from vimtex
    local pkgs = vim.b.vimtex.packages
    local class = "class-" .. vim.b.vimtex.documentclass
    
    -- Always include these
    pkgs["_environments"] = 1
    pkgs["_commands"] = 1
    pkgs[class] = 1
    
    -- Load snippets for each package
    for pkg, _ in pairs(pkgs) do
        if not M.packages[pkg] then
            M.packages[pkg] = 1
            local pkg_json = M.snippets_dir .. "/" .. pkg .. ".json"
            if file_exists(pkg_json) then
                require("luasnip.loaders.from_vscode").load_standalone({ path = pkg_json })
            end
        end
    end
end

-- Setup function
M.setup = function()
    -- Set up autocommands
    vim.api.nvim_create_autocmd("ModeChanged", {
        pattern = "*:[nv]", -- From insert mode to normal or visual mode
        callback = M.reload_snippets,
    })
    
    vim.api.nvim_create_autocmd("User", {
        pattern = "VimtexEventInitPost",
        callback = M.reload_snippets,
    })
end

return M
