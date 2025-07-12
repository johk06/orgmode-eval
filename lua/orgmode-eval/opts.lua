local M = {}

---@class OrgEvalConfigUi
---@field max_lines integer
---@field prefix string
---@field prefix_highlight string
---@field highlight string
---@field error_highlight string
---@field ok_highlight string
---@field info_highlight string
---@field time_highlight string

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
        time_highlight = "SpecialChar",
    }
}

---@type OrgEvalConfig
M.config = defaults

M.setup = function(config)
    M.config = vim.tbl_extend("force", defaults, config)
end

return M
