local M = {}

local api = vim.api
local org = require("orgmode")

---@param file OrgFile
---@return OrgBlock?
M.get_current_block = function(file)
    local row = api.nvim_win_get_cursor(0)[1]
    ---@type OrgBlock[]
    local blocks = vim.tbl_filter(function(b)
        return b:get_type() == "src"
    end, file:get_blocks())

    local block
    for _, b in ipairs(blocks) do
        local srow, _, erow, _ = b.node:range()
        if srow + 1 <= row and erow >= row then
            block = b
            break
        end
    end

    return block
end

---@param str string
---@return table<string, string>
local parse_env_vector = function(str)
    local out = {}
    local values = vim.split(str, " ")
    for _, pair in pairs(values) do
        local lhs, rhs = pair:match("^(.-)=(.*)")
        out[lhs] = rhs
    end

    return out
end

---@param str string
---@return string[]
local parse_arg_vector = function(str)
    return vim.split(str, " ")
end


---@param str string?
---@param default boolean
---@return boolean
local parse_arg_bool = function(str, default)
    return str and (str == "true" or str == "yes") or default
end

---@return OrgEvalBlock?
M.get_parsed_current_block = function()
    local file = org.files:get_current_file()
    local block = M.get_current_block(file)
    if not block then
        return
    end

    local args = block:get_header_args()
    local srow, scol, erow, ecol = block.node:range()
    ---@type OrgEvalBlock
    local parsed = {
        buf = block.file:bufnr(),
        lnum = srow,
        end_lnum = erow,
        block = block,
        lang = block:get_language() or "text" --[[@as string]],
        output_format = args[":out"] or "plain",
        args = args[":args"] and parse_arg_vector(args[":args"]) or {},
        environ = args[":env"] and parse_env_vector(args[":env"]) or {},
        clear_environ = parse_arg_bool(args[":clear-env"], false)
    }

    return parsed
end

return M
