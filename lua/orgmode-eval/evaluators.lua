local M = {}

local uv = vim.uv
local util = require("orgmode-eval.util")
local ui = require("orgmode-eval.ui")

local gettime = util.gettime

local sched = vim.schedule_wrap(function(upd, tbl)
    upd(tbl)
end)

---@class OrgEvalBlock
---@field buf integer
---@field lnum integer
---@field end_lnum integer
---@field block OrgBlock
---@field lang string
---@field environ table<string, string>
---@field clear_environ boolean
---@field args string[]
---@field output_format "plain"|"terminal"|"image"
---@field last_upd OrgEvalUpdate?
---@field update_virt_text integer?
---@field total_time {[1]: OrgEvalStage, [2]: number}[]?

---@alias OrgEvalStage "prepare"|"compile"|"run"

---@class OrgEvalResult
---@field block OrgEvalBlock
---@field result "error"|"ok"
---@field error_stage OrgEvalStage?
---@field exitcode integer?
---@field stdout (string|string[])?
---@field stderr (string|string[])?
---@field errors {[1]: integer, [2]: string}[]?

---@class OrgEvalCompilationResult
---@field out vim.SystemCompleted
---@field tmpdir string
---@field program string

---@class OrgEvalUpdate
---@field block OrgEvalBlock
---@field event "start"|"done"
---@field stage OrgEvalStage
---@field time number

---@alias OrgEvalDoneCb fun(res: OrgEvalResult)
---@alias OrgEvalProgressCb fun(res: OrgEvalUpdate)
---@alias OrgEvalEvaluator fun(block: OrgEvalBlock, cb: OrgEvalDoneCb, upd: OrgEvalProgressCb)


---@type OrgEvalEvaluator
local nvim_lua_evaluator
do
    local get_print_handler = function(dest)
        return function(...)
            local as_str = table.concat(vim.tbl_map(function(v)
                return type(v) == "string" and v or vim.inspect((v))
            end, { ... }), " ")

            vim.list_extend(dest, vim.split(as_str, "\n"))
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

    nvim_lua_evaluator = function(block, cb, upd)
        local source = table.concat(block.block:get_content(), "\n")
        local chunk_name = block.block:get_name() or "Lua"

        local on_error = get_error_handler(chunk_name)
        local chunk, err = load(source, "@" .. chunk_name)
        if not chunk then
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
        if not block.clear_environ then
            package.seeall(env)
        end
        env.print = get_print_handler(messages)
        env.arg = block.args


        setfenv(chunk, env)
        upd {
            block = block,
            event = "start",
            stage = "run",
            time = gettime()
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
            }
        else
            cb(error_result)
        end
    end
end

---@type OrgEvalEvaluator
local identity_evaluator = function(block, cb, upd)
    cb {
        result = "ok",
        block = block,
        stdout = block.block:get_content()
    }
end

---@param stderr string
---@param error_pattern string
---@return {[1]: integer, [2]: string}[] Errors
---@return string[] Output
local collect_error_format = function(stderr, error_pattern)
    local stderr_split = vim.split(stderr, "\n")
    local filtered_stderr = {}
    local errors = {}
    for _, line in ipairs(stderr_split) do
        local lnum, errmsg = line:match(error_pattern)
        if lnum and errmsg then
            table.insert(errors, { lnum, errmsg })
        else
            table.insert(filtered_stderr, line)
        end
    end

    return errors, filtered_stderr
end

---@param cmd string[]
---@param error_pattern string? Regex that captures the line and error message
---@return OrgEvalEvaluator
local make_stdio_evaluator = function(cmd, error_pattern)
    return function(block, cb, upd)
        upd {
            block = block,
            stage = "run",
            event = "start",
            time = gettime()
        }
        vim.system(cmd, {
            stdin = block.block:get_content(),
            clear_env = block.clear_environ,
            env = not vim.tbl_isempty(block.environ) and block.environ or nil,
        }, function(out)
            ---@type OrgEvalResult
            ---@diagnostic disable-next-line: missing-fields
            local res = {
                exitcode = out.code,
                block = block,
                stderr = out.stderr,
                stdout = out.stdout,
            }

            if out.code == 0 then
                res.result = "ok"
            else
                res.result = "error"
                res.error_stage = "run"

                if error_pattern then
                    local errors, filtered = collect_error_format(out.stderr, error_pattern)
                    res.errors = errors
                    res.stderr = filtered
                end
            end

            vim.schedule(function()
                upd {
                    block = block,
                    stage = "run",
                    event = "done",
                    time = gettime()
                }
                cb(res)
            end)
        end)
    end
end

---@param compiler (string|boolean)[]
---@param input string
---@param output string
---@return string[]
local format_compiler_name = function(compiler, input, output)
    local out = {}
    for _, field in ipairs(compiler) do
        if field == true then
            out[#out + 1] = input
        elseif field == false then
            out[#out + 1] = output
        else
            out[#out + 1] = field
        end
    end

    return out
end

---@param program string
---@param block OrgEvalBlock
---@param cb OrgEvalDoneCb
local execute_program = function(program, block, cb)
    vim.system(vim.list_extend({ program }, block.args), {
        env = block.environ,
        clear_env = block.clear_environ,
    }, function(out)
        ---@type OrgEvalResult
        ---@diagnostic disable-next-line: missing-fields
        local res = {
            exitcode = out.code,
            block = block,
            stderr = out.stderr,
            stdout = out.stdout,
        }

        if out.code == 0 then
            res.result = "ok"
        else
            res.result = "error"
            res.error_stage = "run"
        end

        cb(res)
    end)
end

---@param out OrgEvalCompilationResult
---@param block OrgEvalBlock
---@param error_pattern string?
---@param cb OrgEvalDoneCb
---@param upd OrgEvalProgressCb
local check_compilation_result = function(out, block, error_pattern, cb, upd)
    local compiler_out = out.out
    sched(upd, {
        block = block,
        event = "done",
        stage = "compile",
        time = gettime()
    })
    if compiler_out.code ~= 0 then
        vim.schedule(function()
            local errors, stderr = nil, compiler_out.stderr
            if error_pattern and stderr then
                errors, stderr = collect_error_format(stderr, error_pattern)
            end
            cb {
                result = "error",
                error_stage = "compile",
                block = block,
                exitcode = compiler_out.code,
                stderr = stderr,
                errors = errors,
            }
        end)
    else
        sched(upd, {
            block = block,
            event = "start",
            stage = "run",
            time = gettime(),
        })
        execute_program(out.program, block, function(res)
            vim.fs.rm(out.tmpdir, { recursive = true })
            sched(upd, {
                block = block,
                event = "done",
                stage = "run",
                time = gettime(),
            })
            sched(cb, res)
        end)
    end
end

---@param cmd (string|boolean)[]
---@param extension string
---@param error_pattern string?
---@return OrgEvalEvaluator
local make_compiler_evaluator = function(cmd, extension, error_pattern)
    return function(block, cb, upd)
        local text = block.block:get_content()

        local tmpdir = vim.fn.tempname()
        assert(uv.fs_mkdir(tmpdir, 493 --[[0o755]]))

        local name = block.block:get_name() or "main"
        local input_file = vim.fs.joinpath(tmpdir, name .. extension)
        local output_file = vim.fs.joinpath(tmpdir, name)

        uv.fs_open(input_file, "w", 493, function(err, fd)
            assert(not err)
            uv.fs_write(fd, table.concat(text, "\n"), 0, function(err, n)
                assert(not err)
                local compile_command = format_compiler_name(cmd, input_file, output_file)
                sched(upd, {
                    block = block,
                    event = "start",
                    stage = "compile",
                    time = gettime(),
                })
                vim.system(compile_command, {}, function(res)
                    return check_compilation_result({
                        out = res,
                        program = output_file,
                        tmpdir = tmpdir,
                    }, block, error_pattern, cb, upd)
                end)
            end)
        end)
    end
end

M.evaluators = {
    nvim_lua = nvim_lua_evaluator,
    identity = identity_evaluator,
    shell = make_stdio_evaluator({ "bash" }, "^bash: line (%d+): (.*)"),
    python = make_stdio_evaluator({ "python" }),
    system_lua = make_stdio_evaluator({ "lua" }),
    gcc = make_compiler_evaluator({ "gcc", true, "-o", false }, ".c", "^%S-:(%d+):%d+: error: (.*)")
}

---@type table<string, OrgEvalEvaluator>
local per_filetype = {
    text = identity_evaluator,
    lua = nvim_lua_evaluator,
    bash = M.evaluators.shell,
    python = M.evaluators.python,
    c = M.evaluators.gcc,
}

M.per_type = per_filetype

---@param block OrgEvalBlock
---@param cb OrgEvalDoneCb
---@param upd OrgEvalProgressCb
M.evaluate = function(block, cb, upd)
    local evaluator = per_filetype[block.lang]
    if not evaluator then
        vim.notify("[Org] No evaluator for " .. block.lang, vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_buf_clear_namespace(block.buf, ui.highlights, block.lnum, block.end_lnum)
    block.total_time = {}
    evaluator(block, cb, upd)
end

return M
