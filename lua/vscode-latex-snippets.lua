local M = {}

-- Default configuration
M.config = {
    snippets_dir = nil, -- Must be set by user
}

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
    
    -- Check if snippets directory is configured
    if not M.config.snippets_dir then
        vim.notify("vscode-latex-snippets: snippets_dir not configured", vim.log.levels.WARN)
        return
    end
    
    -- Load snippets for each package
    for pkg, _ in pairs(pkgs) do
        if not M.packages[pkg] then
            M.packages[pkg] = 1
            local pkg_json = M.config.snippets_dir .. "/" .. pkg .. ".json"
            if file_exists(pkg_json) then
                require("luasnip.loaders.from_vscode").load_standalone({ path = pkg_json })
            end
        end
    end
end

-- Setup function
M.setup = function(user_config)
    -- Merge user configuration with defaults
    M.config = vim.tbl_deep_extend("force", M.config, user_config or {})
    
    -- Validate configuration
    if not M.config.snippets_dir then
        vim.notify("vscode-latex-snippets: snippets_dir must be set in setup()", vim.log.levels.ERROR)
        return
    end
    
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
