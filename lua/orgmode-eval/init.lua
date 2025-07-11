local M = {}

local api = vim.api
local org = require("orgmode")
local ns = api.nvim_create_namespace("config.org.evaluator.highlight")
local diags = api.nvim_create_namespace("config.org.evaluator.diagnostics")

---@param file OrgFile
---@return OrgBlock?
local get_current_block = function(file)
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

---@class OrgEvalBlock
---@field block OrgBlock
---@field lang string
---@field environ table<string, string>
---@field argv string[]
---@field output_format "plain"|"terminal"|"image"

---@class OrgEvalResult
---@field block OrgEvalBlock
---@field result "error"|"ok"
---@field exitcode integer?
---@field stdout (string|string[])?
---@field stderr (string|string[])?
---@field errors {[1]: integer, [2]: string}[]?

---@alias OrgEvalEvaluator fun(block: OrgEvalBlock, cb: fun(res: OrgEvalResult))


local get_print_handler = function(dest)
    return function(...)
        local as_str = table.concat(vim.tbl_map(function(v)
            return type(v) == "string" and v or vim.inspect((v))
        end, { ... }), " ")

        table.insert(dest, as_str)
    end
end

local get_error_handler = function(name)
    ---@param err string
    return function(err)
        if err then
            local line, msg = err:match("^" .. vim.pesc(name) .. ":(%d+):(.*)")
            if line then
                return line, msg
            end
        end

        for lvl = 2, 20 do
            local info = debug.getinfo(lvl, "Sln")
            if info and info.source == "@" .. name then
                return info.currentline, err
            end
        end
    end
end

---@type OrgEvalEvaluator
local lua_evaluator = function(block, cb)
    local source = table.concat(block.block:get_content(), "\n")
    local chunk_name = block.block:get_name() or "Lua"

    local on_error = get_error_handler(chunk_name)
    local chunk, err = load(source, "@" .. chunk_name)
    if not chunk then
        vim.notify(vim.inspect(err))
        local lnum, msg = on_error(err)
        cb {
            result = "error",
            errors = { { tonumber(lnum), msg } },
            block = block,
        }
        return
    end

    local env = block.environ --[[@as table]]
    local messages = {}
    package.seeall(env)
    env.print = get_print_handler(messages)


    setfenv(chunk, env)
    xpcall(chunk, function(e)
        local lnum, err = on_error(e)
        cb {
            result = "error",
            block = block,
            errors = { { lnum, err } }
        }
    end)

    cb {
        block = block,
        result = "ok",
        stdout = messages,
    }
end

---@type table<string, OrgEvalEvaluator>
local evaluators = {
    text = function(block, cb)
        cb(block.block:get_content())
    end,
    lua = lua_evaluator
}

---@param res OrgEvalResult
local handle_result = function(res)
    local buf = res.block.block.file:bufnr()
    local node = res.block.block.node
    local srow, scol, erow, ecol = node:range()

    api.nvim_buf_clear_namespace(buf, ns, srow, erow)
    if res.result == "error" then
        if res.errors then
            vim.diagnostic.set(diags, buf, vim.tbl_map(function(e)
                return {
                    severity = vim.diagnostic.severity.ERROR,
                    message = e[2],
                    lnum = e[1] + srow,
                    col = 0,
                }
            end, res.errors))
        end
    end
    if res.stdout then
        local output
        if type(res.stdout) == "string" then
            output = vim.split(res.stdout --[[@as string]], "\n")
        else
            output = res.stdout --[[@as string[] ]]
        end
        api.nvim_buf_set_extmark(buf, ns, srow, 0, {
            virt_lines = vim.tbl_map(function(line)
                return { { line, "Comment" } }
            end, output)
        })
    end
end

---@param block OrgEvalBlock
local run_and_eval = function(block)
    local evaluator = evaluators[block.lang]
    if not evaluator then
        vim.notify("[Org] No evaluator for " .. block.lang, vim.log.levels.ERROR)
        return
    end

    evaluator(block, handle_result)
end

M.run_code_block = function()
    local file = org.files:get_current_file()
    local block = get_current_block(file)
    if not block then
        return
    end

    local args = block:get_header_args()
    ---@type OrgEvalBlock
    local parsed = {
        block = block,
        lang = block:get_language() or "text" --[[@as string]],
        output_format = args[":out"] or "plain",
        argv = args[":argv"] and parse_arg_vector(args[":argv"]) or {},
        environ = args[":env"] and parse_env_vector(args[":env"]) or {},
    }

    run_and_eval(parsed)
end

M.clear_buffer = function(buf)
    buf = buf or api.nvim_get_current_buf()

    vim.diagnostic.set(diags, buf, {})
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

return M
