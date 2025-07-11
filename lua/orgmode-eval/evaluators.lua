local M = {}

---@class OrgEvalBlock
---@field block OrgBlock
---@field lang string
---@field environ table<string, string>
---@field argv string[]
---@field output_format "plain"|"terminal"|"image"

---@alias OrgEvalResultErrorStage "compile"|"run"

---@class OrgEvalResult
---@field block OrgEvalBlock
---@field result "error"|"ok"
---@field error_stage OrgEvalResultErrorStage?
---@field exitcode integer?
---@field stdout (string|string[])?
---@field stderr (string|string[])?
---@field errors {[1]: integer, [2]: string}[]?

---@alias OrgEvalEvaluator fun(block: OrgEvalBlock, cb: fun(res: OrgEvalResult))

---@type OrgEvalEvaluator
local lua_evaluator
do
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

    lua_evaluator = function(block, cb)
        local source = table.concat(block.block:get_content(), "\n")
        local chunk_name = block.block:get_name() or "Lua"

        local on_error = get_error_handler(chunk_name)
        local chunk, err = load(source, "@" .. chunk_name)
        if not chunk then
            vim.notify(vim.inspect(err))
            local lnum, msg = on_error(err --[[@as string]])
            cb {
                result = "error",
                error_stage = "compile",
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
        local error_result
        local ok = xpcall(chunk, function(e)
            local lnum, msg = on_error(e)
            error_result = {
                result = "error",
                error_stage = "run",
                block = block,
                stdout = messages,
                errors = { { lnum, msg } },
            }
        end)

        if ok then
            cb {
                block = block,
                result = "ok",
                stdout = messages,
            }
        else
            cb(error_result)
        end
    end
end

---@type OrgEvalEvaluator
local identity_evaluator = function(block, cb)
        cb {
            result = "ok",
            block = block,
            stdout = block.block:get_content()
        }
    end

---@type table<string, OrgEvalEvaluator>
local evaluators = {
    text = identity_evaluator,
    lua = lua_evaluator
}

M.evaluators = {
    nvim_lua = lua_evaluator,
    identity = identity_evaluator,
}

M.per_type = evaluators

---@param block OrgEvalBlock
---@param cb fun(res: OrgEvalResult)
M.evaluate = function(block, cb)
    local evaluator = evaluators[block.lang]
    if not evaluator then
        vim.notify("[Org] No evaluator for " .. block.lang, vim.log.levels.ERROR)
        return
    end

    evaluator(block, cb)
end

return M
