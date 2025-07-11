local M = {}

---@class OrgEvalConfigUi
---@field highlight string
---@field prefix string
---@field prefix_highlight string
---@field error_highlight string
---@field error_text string
---@field ok_highlight string
---@field ok_text string
---@field info_highlight string
---@field max_lines integer

---@class OrgEvalConfig
---@field output OrgEvalConfigUi

---@type OrgEvalConfig
local defaults = {
    output = {
        max_lines = 10,
        highlight = "Comment",
        prefix = "%s> ",
        prefix_highlight = "Comment",
        ok_highlight = "DiagnosticOk",
        error_highlight = "DiagnosticError",
        info_highlight = "DiagnosticHint",

        ok_text = "OK",
        error_text = "Error",
    }
}

---@type OrgEvalConfig
M.config = defaults

M.setup = function(config)
    M.config = vim.tbl_extend("force", defaults, config)
end

return M
