return {
    packages = {},
    reload_snippets = function()
        local vsc_latex = require("vscode-latex-snippets")
        -- local luasnip = require("luasnip")
        if vim.b.vimtex == nil then
            return
        end
        local pkgs = vim.b.vimtex.packages
        for pkg , _  in pairs(pkgs) do
            if not vsc_latex.packages[pkg] then
                vsc_latex.packages[pkg] = 1
                local pkg_json = "/home/gaoqiang/.local/share/nvim/lazy/vscode-latex-snippets/snippets/"..pkg..".json"
                require("luasnip.loaders.from_vscode").load_standalone({path = pkg_json})
            end
        end
    end
}
