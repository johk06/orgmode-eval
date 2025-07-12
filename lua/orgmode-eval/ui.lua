local M = {}

local api = vim.api
local opts = require("orgmode-eval.opts").config.output

local ns = api.nvim_create_namespace("org.evaluator.highlights")
M.highlights = ns
local diags = api.nvim_create_namespace("org.evaluator.diagnostics")
M.diagnostics = diags


---@param node TSNode
local get_heading_level = function(node)
    local parent = node
    while true do
        parent = parent:parent()
        if not parent then
            return 0
        end
        if parent:type() == "section" then
            break
        end
    end
    local stars = parent:field("headline")[1]:field("stars")[1]
    return stars:byte_length()
end

local get_leading_chars = function(block)
    return opts.prefix:format((" "):rep(get_heading_level(block.node) + 1))
end

---@type table<OrgEvalStage, string>
local error_messages = {
    prepare = "Setup Error",
    run = "Runtime Error",
    compile = "Compilation Error",
}


---@type table<OrgEvalStage, string>
local update_messages = {
    prepare = "Preparing",
    run = "Running",
    compile = "Compiling",
}

---@type table<OrgEvalStage, string>
local done_messages = {
    prepare = "Prepare",
    run = "Run",
    compile = "Compile",
}

---@param block OrgEvalBlock
---@param result "ok"|"error"?
local show_stages = function(block, result)
    local message = { { get_leading_chars(block.block), opts.prefix_highlight } }
    if result then
        table.insert(message, result == "error"
            and { "Error ", opts.error_highlight }
            or { "OK ", opts.ok_highlight })
    end
    for i, time in ipairs(block.total_time) do
        if i ~= 1 then
            table.insert(message, { ", ", "@punctuation.delimiter" })
        end
        table.insert(message, {
            ("%s: "):format(done_messages[time[1]]),
            opts.highlight,
        })
        table.insert(message, {
            ("%.2fs"):format(time[2]),
            opts.time_highlight,
        })
    end

    if block.last_upd and (
            #block.total_time == 0
            or block.last_upd.stage ~= block.total_time[#block.total_time][1]) then
        table.insert(message, {
            (" %s..."):format(update_messages[block.last_upd.stage]), opts.highlight
        })
    end
    block.update_virt_text = api.nvim_buf_set_extmark(block.buf, ns, block.lnum, 0, {
        virt_lines = { message },
        virt_lines_above = true,
    })
end

---@type OrgEvalProgressCb
M.update_in_progress = function(upd)
    local block = upd.block
    if block.update_virt_text then
        api.nvim_buf_del_extmark(block.buf, ns, block.update_virt_text)
    end

    if upd.event == "start" then
        block.last_upd = upd
    else
        table.insert(block.total_time, { upd.stage, upd.time - block.last_upd.time })
    end

    show_stages(block)
end


---@param dst table
---@param stream string|string[]
---@param prefix {[1]: string, [2]: string}
---@param title {[1]: string, [2]: string}
local add_stream_with_prefix = function(dst, stream, prefix, heading_prefix, title)
    local output
    if type(stream) == "string" then
        output = vim.split(stream --[[@as string]], "\n")
    else
        output = stream --[[@as string[] ]]
    end

    if #output > 0 then
        table.insert(dst, {
            heading_prefix, title,
        })
        for i, line in ipairs(output) do
            if i > opts.max_lines - 1 then
                local delta = #output - i + 1
                table.insert(dst, {
                    prefix, { "...", opts.highlight },
                    { ("%d more line%s"):format(delta, delta == 1 and "" or "s"),
                        opts.info_highlight },
                })
                break
            end
            if not (i == #output and #line == 0) then
                table.insert(dst, {
                    prefix, { line, opts.highlight }
                })
            end
        end
    end
end

---@type OrgEvalDoneCb
M.display_evaluation_result = function(res)
    local block = res.block
    local buf = block.buf
    local node = block.block.node
    local indent = get_heading_level(node)
    local padding = (" "):rep(indent + 1)
    local prefix = { opts.prefix:format(padding), opts.prefix_highlight }
    local plain_prefix = { padding .. "  " }


    api.nvim_buf_clear_namespace(buf, ns, block.lnum, block.end_lnum)


    local lines = {}
    ---@type vim.Diagnostic[]
    local diagnostics = {}

    if res.result == "error" then
        table.insert(diagnostics, {
            severity = vim.diagnostic.severity.ERROR,
            message = (error_messages[res.error_stage] or "Unknown Error") ..
                (res.exitcode and (": %d"):format(res.exitcode) or ""),
            lnum = block.lnum,
            col = 0,
            end_col = node:byte_length(),
        })
        if res.errors then
            vim.list_extend(diagnostics, vim.tbl_map(function(e)
                return {
                    severity = vim.diagnostic.severity.ERROR,
                    message = e[2],
                    lnum = e[1] + block.lnum,
                    col = 0,
                }
            end, res.errors))
        end
    end
    show_stages(block, res.result)

    vim.diagnostic.set(diags, buf, vim.list_extend(vim.tbl_filter(function(d)
        return d.lnum > block.end_lnum or d.lnum < block.lnum
    end, vim.diagnostic.get(buf, { namespace = diags })), diagnostics))

    if res.stderr and #res.stderr > 0 then
        add_stream_with_prefix(lines, res.stderr, plain_prefix, prefix, { "Errors", opts.error_highlight })
    end
    if res.stdout and #res.stdout > 0 then
        add_stream_with_prefix(lines, res.stdout, plain_prefix, prefix, { "Output", opts.info_highlight })
    end
    api.nvim_buf_set_extmark(buf, ns, block.end_lnum - 1, 0, {
        virt_lines = lines
    })
end
return M
