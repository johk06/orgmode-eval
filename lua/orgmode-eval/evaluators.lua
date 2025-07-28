local M = {}

local uv = vim.uv
local util = require("orgmode-eval.util")
local ui = require("orgmode-eval.ui")
local config = require("orgmode-eval.opts").config

local gettime = util.gettime

local sched = vim.schedule_wrap(function(upd, tbl)
    upd(tbl)
end)

local startrun = function(cb, block)
    cb {
        block = block,
        event = "start",
        stage = "run",
        time = gettime()
    }
end

local stoprun = function(cb, block)
    cb {
        block = block,
        event = "done",
        stage = "run",
        time = gettime()
    }
end

---@type OrgEvalEvaluator
local nvim_vimscript_evaluator = function(block, cb, upd)
    local lines = block.block:get_content()
    local search, hlsearch, view
    if block.args.clear_environ then
        search = vim.fn.getreg("/")
        hlsearch = vim.v.hlsearch
        view = vim.fn.winsaveview()
    end

    startrun(upd, block)
    local ok, res = pcall(vim.api.nvim_exec2, table.concat(lines, "\n"), { output = true })
    stoprun(upd, block)

    if ok then
        cb {
            block = block,
            result = "ok",
            stdout = res.output,
        }
    else
        local lnum, msg = res:match("nvim_exec2%(%), line (%d+): (.*)")
        cb {
            block = block,
            result = "error",
            error_stage = "run",
            errors = { { lnum, msg } }
        }
    end

    if block.args.clear_environ then
        vim.fn.setreg("/", search)
        vim.v.hlsearch = hlsearch
        vim.fn.winrestview(view)
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
        startrun(upd, block)
        local full_cmd = vim.list_extend({}, cmd)
        vim.list_extend(full_cmd, block.args.args)
        vim.system(full_cmd, {
            stdin = block.block:get_content(),
            clear_env = block.args.clear_environ,
            env = block.args.environ,
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
                stoprun(upd, block)
                cb(res)
            end)
        end)
    end
end

---@param compiler string[]
---@param input string
---@param output string
---@return string[]
local format_compiler_name = function(compiler, input, output)
    local out = {}
    for _, field in ipairs(compiler) do
        if field == "{input}" then
            out[#out + 1] = input
        elseif field == "{output}" then
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
    local command = vim.list_extend({ program }, block.args.args)
    vim.system(command, {
        env = block.args.environ,
        clear_env = block.args.clear_environ,
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
                ---@diagnostic disable-next-line: cast-local-type
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

---@param cmd string[]
---@param extension string?
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

---@param name string
---@param callback OrgEvalEvaluator
---@param languages string[]? Automatically register for languages
M.register_evaluator = function(name, callback, languages)
    M.evaluators[name] = callback
    if languages then
        for _, lang in ipairs(languages) do
            config.evaluators[lang] = name
        end
    end
end

---@param name string
---@param command string[]
---@param opts {error_pattern: string?, languages: string[]?}
M.register_interpreter = function(name, command, opts)
    M.register_evaluator(name, make_stdio_evaluator(command, opts.error_pattern), opts.languages)
end

---@param name string
---@param command (string|boolean)[]
---@param opts {file_extension: string, error_pattern: string?, languages: string[]?}
M.register_compiler = function(name, command, opts)
    M.register_evaluator(name, make_compiler_evaluator(command, opts.file_extension, opts.error_pattern), opts.languages)
end

-- Defaults {{{
---@type table<string, OrgEvalEvaluator>
M.evaluators = {}

M.register_evaluator("identity", identity_evaluator, { "text" })
M.register_evaluator("lua-nvim", require("orgmode-eval.evaluators.nvim-lua"), { "lua" })
M.register_evaluator("vim-nvim", nvim_vimscript_evaluator, { "vim" })

M.register_interpreter("lua-system", { "lua", "-" }, {})
M.register_interpreter("bash", { "bash", "-s" }, {
    error_pattern = "^bash: line (%d+): (.*)",
    languages = { "bash" }
})
M.register_interpreter("python", { "python" }, {
    languages = { "python", "-" }
})

M.register_compiler("gcc", { "gcc", "{input}", "-o", "{output}" }, {
    file_extension = ".c",
    error_pattern = "^%S-:(%d+):%d+: error: (.*)",
    languages = { "c" }
})

vim.defer_fn(function ()
   require("orgmode-eval.evaluators.qalculate")
end, 100)
-- }}}

---@param block OrgEvalBlock
---@param cb OrgEvalDoneCb
---@param upd OrgEvalProgressCb
M.evaluate = function(block, cb, upd)
    local evaluator = config.evaluators[block.lang]
    if not evaluator then
        util.error("No evaluator for " .. block.lang)
        return
    end
    local eval_func = M.evaluators[evaluator]
    if not eval_func then
        util.error("Not a valid evaluator: " .. evaluator)
        return
    end

    vim.api.nvim_buf_clear_namespace(block.buf, ui.highlights, block.lnum, block.end_lnum)
    block.total_time = {}
    eval_func(block, cb, upd)
end

return M
