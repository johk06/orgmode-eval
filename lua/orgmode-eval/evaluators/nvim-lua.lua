local gettime = require("orgmode-eval.util").gettime

local get_print_handler = function(dest, err_handler, inline)
    return function(...)
        local as_str = table.concat(vim.tbl_map(function(v)
            return type(v) == "string" and v or vim.inspect((v))
        end, { ... }), " ")

        if inline then
            local level = err_handler()
            local lines =  vim.split(as_str, "\n")
            lines[1] = "=> " .. lines[1]
            table.insert(dest, { tonumber(level), lines})
        else
            vim.list_extend(dest, vim.split(as_str, "\n"))
        end
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
local evaluator =  function(block, cb, upd)
    local source = table.concat(block.block:get_content(), "\n")
    local chunk_name = block.block:get_name() or "Lua"

    upd {
        event = "start",
        stage = "prepare",
        time = gettime(),
        block = block,
    }
    local on_error = get_error_handler(chunk_name)
    local chunk, err = load(source, "@" .. chunk_name)

    local load_error
    if not chunk then
        local lnum, msg = on_error(err --[[@as string]])
        load_error = {
            result = "error",
            error_stage = "compile",
            errors = { { tonumber(lnum), msg } },
            block = block,
        }
    end

    upd {
        event = "done",
        stage = "prepare",
        time = gettime(),
        block = block,
    }

    if load_error then
        cb(load_error)
        return
    end
    ---@cast chunk function

    local env = block.args.environ --[[@as table]]
    local messages = {}
    if not block.args.clear_environ then
        package.seeall(env)
    end
    env.print = get_print_handler(messages, on_error, block.args.inline)
    env.arg = block.args.args


    setfenv(chunk, env)
    upd {
        block = block,
        event = "start",
        stage = "run",
        time = gettime(),
    }

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

    upd {
        block = block,
        event = "done",
        stage = "run",
        time = gettime()
    }

    if ok then
        cb {

            block = block,
            result = "ok",
            stdout = messages,
            output_style = block.args.inline and "inline" or nil
        }
    else
        cb(error_result)
    end
end

return evaluator
