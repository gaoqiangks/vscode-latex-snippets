# vscode-latex-snippets

LuaSnip loader for the package-aware snippets in this repository. It uses the
VimTeX project state to select package snippets and discovers project-local
`\\newcommand` definitions in the background.

```lua
require("vscode-latex-snippets").setup({
  pkgs_included = {}, -- Lua patterns; empty means all detected packages
  pkgs_excluded = {}, -- Lua patterns; exclusions take precedence
  dynamic_commands = true, -- set false to disable project command scanning
  debounce = 100, -- milliseconds before a reload starts
  scan_interval = 1, -- milliseconds yielded between project files
})
```

Project files are parsed one at a time to keep Neovim responsive on slow
filesystems such as WSL-mounted NTFS. Unchanged files are cached by size and
modification time. The `User VscodeLatexSnippetsReloaded` event is emitted when
a project scan finishes.
