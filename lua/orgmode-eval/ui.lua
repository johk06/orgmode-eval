local M = {}

local api = vim.api
local opts = require("orgmode-eval.opts").config.output
local org = require("orgmode")

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
    local sect = parent
    local headline = parent:field("headline")[1]
    local stars = headline:field("stars")[1]
    return stars:byte_length()
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
            table.insert(dst, {
                prefix, { line, opts.highlight }
            })
        end
    end
end

---@type table<OrgEvalResultErrorStage, string>
local error_messages = {
    run = "Runtime Error",
    compile = "Compilation Error",
}

---@param res OrgEvalResult
M.display_evaluation_result = function(res)
    local buf = res.block.block.file:bufnr()
    local node = res.block.block.node
    local srow, scol, erow, ecol = node:range()
    local indent = get_heading_level(node)
    local padding = (" "):rep(indent + 1)
    local prefix = { opts.prefix:format(padding), opts.prefix_highlight }
    local plain_prefix = { padding .. "  " }

    ---@type vim.Diagnostic[]
    local diagnostics = {}

    api.nvim_buf_clear_namespace(buf, ns, srow, erow)
    local lines = {}
    if res.result == "error" then
        table.insert(diagnostics, {
            severity = vim.diagnostic.severity.ERROR,
            message = error_messages[res.error_stage] or "Unknown Error",
            lnum = srow,
            col = 0,
            end_col = node:byte_length(),
        })
        if res.errors then
            vim.list_extend(diagnostics, vim.tbl_map(function(e)
                return {
                    severity = vim.diagnostic.severity.ERROR,
                    message = e[2],
                    lnum = e[1] + srow,
                    col = 0,
                }
            end, res.errors))
        end
    else
        api.nvim_buf_set_extmark(buf, ns, srow, 0, {
            virt_text = { { opts.ok_text, opts.ok_highlight } }
        })
    end

    vim.diagnostic.set(diags, buf, vim.list_extend(vim.tbl_filter(function(d)
        return d.lnum > erow or d.lnum < srow
    end, vim.diagnostic.get(buf, { namespace = diags })), diagnostics))

    if res.stderr then
        add_stream_with_prefix(lines, res.stderr, plain_prefix, prefix, { "Errors", opts.error_highlight })
    end
    if res.stdout then
        add_stream_with_prefix(lines, res.stdout, plain_prefix, prefix, { "Output", opts.info_highlight })
    end
    api.nvim_buf_set_extmark(buf, ns, erow - 1, 0, {
        virt_lines = lines
    })
end

return M
