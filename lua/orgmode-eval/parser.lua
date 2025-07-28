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
---@return string
---@return integer
local expand_sh_style_var = function(str)
    local out = {}
    local match, len
    local replacement

    if str:sub(1, 1) == "{" then
        local stop = str:find("}")
        len = stop
        match = str:sub(2, stop - 1)
    elseif str:sub(1, 2) == "?{" then
        local stop = str:find("}")
        len = stop + 1
        local fields = vim.split(str:sub(3, stop - 1), "|")
        replacement = vim.fn.input((fields[1] or "Entry") .. ": ", fields[3] or "", fields[2])
    else
        match = str:match("^(%w+)")
        len = #match
    end

    if not replacement then
        if match == "FILE" then
            replacement = api.nvim_buf_get_name(0)
        else
            replacement = vim.env[match]
        end
    end
    return replacement, len
end

---@param str string
---@return string[]
local sh_style_wordsplit = function(str)
    local fields = {}

    local current = require("string.buffer").new(24)
    local single_quoted = false
    local double_quoted = false

    local i = 1
    local len = #str
    while i <= len do
        local c = str:sub(i, i)

        if single_quoted then
            if c == "'" then
                single_quoted = false
            else
                current:put(c)
            end
        elseif double_quoted then
            if c == '"' then
                double_quoted = false
            elseif c == "\\" then
                i = i + 1
                local nextc = str:sub(i, i)
                if nextc == '"' or nextc == "\\" or nextc == "$" then
                    current:put(nextc)
                elseif nextc == "n" then
                    current:put("\n")
                else
                    current:put("\\", nextc)
                end
            elseif c == "$" then
                local replacement, count = expand_sh_style_var(str:sub(i + 1))
                current:put(replacement)
                i = i + count
            else
                current:put(c)
            end
        else
            if c == "\\" then
                i = i + 1
                local nextc = str:sub(i, i)
                current:put(nextc)
            elseif c == '"' then
                double_quoted = true
            elseif c == "'" then
                single_quoted = true
            elseif c == "$" then
                local replacement, count = expand_sh_style_var(str:sub(i + 1))
                current:put(replacement)
                i = i + count
            elseif c:match("%s") then
                if #current > 0 then
                    table.insert(fields, current:tostring())
                    current:reset()
                end
            else
                current:put(c)
            end
        end

        i = i + 1
    end

    if #current > 0 then
        table.insert(fields, current:tostring())
    end

    return fields
end

---@param str string
---@return table<string, string>
local parse_env_vector = function(str)
    local env = {}
    local fields = sh_style_wordsplit(str)

    for _, field in ipairs(fields) do
        local name, value = field:match("^(.-)=(.*)")
        if not name then
            env[field] = vim.env[field]
        else
            env[name] = value
        end
    end

    return env
end

---@param str string
---@return string[]
local parse_arg_vector = function(str)
    return sh_style_wordsplit(str)
end


---@param str string?
---@param default boolean
---@return boolean
local parse_arg_bool = function(str, default)
    return str and (
        str == "true" or str == "yes" or str == "t" or str == "y"
    ) or default
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
        args = {
            args = args[":args"] and parse_arg_vector(args[":args"]) or {},
            environ = args[":env"] and parse_env_vector(args[":env"]) or {},
            clear_environ = parse_arg_bool(args[":clear-env"], false),
            inline = parse_arg_bool(args[":inline"], false),
        }
    }

    return parsed
end

return M
