-- local log=require("log").log
local file_exists = function(name)
    local f=io.open(name,"r")
    if f~=nil then io.close(f) return true else return false end
end
return {
    packages = {},
    reload_snippets = function()
        local vsc_latex = require("vscode-latex-snippets")
        -- local luasnip = require("luasnip")
        if vim.b.vimtex == nil then
            return
        end
        local pkgs = vim.b.vimtex.packages
        local class = "class-"..vim.b.vimtex.documentclass
        pkgs["_environments"] = 1
        pkgs["_commands"] = 1
        pkgs[class] = 1
        local lazy_root = require("lazy.core.config").options.root
        -- log("pkgs= "..vim.inspect(pkgs))
        for pkg, _  in pairs(pkgs) do
            if not vsc_latex.packages[pkg] then
                vsc_latex.packages[pkg] = 1
                local pkg_json = lazy_root.."/vscode-latex-snippets/snippets/"..pkg..".json"
                if file_exists(pkg_json) then
                    require("luasnip.loaders.from_vscode").load_standalone({path = pkg_json})
                end
            end
        end
    end,
    setup = function()
        local vsc_tex_snips = require("vscode-latex-snippets")
        -- local vimtex = require("vimtex")
        vim.api.nvim_create_autocmd("ModeChanged", {
            pattern = "*:[nv]", -- 从插入模式切换到普通模式或可视模式
            callback = vsc_tex_snips.reload_snippets
        })
        vim.api.nvim_create_autocmd("User", {
            pattern = "VimtexEventInitPost",
            callback = vsc_tex_snips.reload_snippets
        })
    end
}
