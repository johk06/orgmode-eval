local has_qalc, qalculate = pcall(require, "qalculate")
if not has_qalc then
    return
end

local gettime = require("orgmode-eval.util").gettime
local strbuf = require("string.buffer")

local cur_img
local getrgb = function(hlgroup, field)
    local value = vim.api.nvim_get_hl(0, {
        name = hlgroup,
    })

    return ("#%06x"):format(value[field])
end

local qalc = qalculate.new(function(x, y, meta)
    local file = vim.fn.tempname()
    local values = strbuf.new()
    for i = 1, #x do
        values:putf("%f %f\n", x[i], y[i])
    end

    local directives = strbuf.new()
    if meta.step then
        directives:putf("set xtics %f\n", meta.step)
    end
    if meta.xfmt then
        directives:putf('set format x "%s"\n', meta.xfmt)
    end
    if meta.range then
        directives:putf('set yrange [%f:%f]\n', meta.range[1], meta.range[2])
    end

    local fg = getrgb("Normal", "fg")
    local bg = getrgb("Normal", "bg")
    local hl = getrgb("SpecialChar", "fg")
    local stdin = ([=[
    set terminal pngcairo size 1200, 600 background '%s' font "Mono,24"
    set output '%s'
    %s
    %s
    set border linecolor rgb '%s'
    plot '-' with %s linecolor rgb '%s'
    %s
    ]=]):format(
        bg,
        file,
        directives,
        table.concat(meta.extra, "\n"),
        fg,
        meta.type or "linespoints", hl, values)
    vim.system({ "gnuplot" }, {
        stdin = stdin,
    }):wait()
    cur_img = file
end)
---@type QalcPrintOptions
local opts = {
    interval_display = "concise",
    unicode = "on",
}

---@param block QalcExpression
---@return string[]
local format_block = function(block)
    if block:type() == "matrix" then
        local value = assert(block:as_matrix())
        local rows, cols = #value, #value[1]
        local middle = math.floor((rows + 1) / 2)

        local lines = {}
        for i, row in ipairs(value) do
            table.insert(lines, ("%s%s"):format(
                i == middle and (block:is_approximate() and "≈ " or "= ") or "  ",
                table.concat(vim.tbl_map(function(el)
                    return el:print()
                end, row), " ")
            ))
        end

        return lines
    else
        return {
            ("%s %s"):format(block:is_approximate() and "≈" or "=", block:print(opts))
        }
    end
end

require("orgmode-eval.evaluators").register_evaluator("math-qalc", function(block, cb, upd)
    upd {
        block = block,
        event = "start",
        stage = "run",
        time = gettime()
    }
    cur_img = nil

    local lines = block.block:get_content()

    ---@type OrgEvalResult
    ---@diagnostic disable-next-line: missing-fields
    local out = {
        block = block,
        errors = {},
        output_style = "inline",
        images = {},
    }

    ---@type string[][]
    local stdout = {}

    qalc:reset(true)

    for i, line in ipairs(lines) do
        if not line:match("^%s*$") then
            local res, errs = qalc:eval(line, nil, true)
            local img = cur_img
            cur_img = nil
            if img then
                table.insert(out.images, {i, img})
            end

            if errs then
                for _, err in ipairs(errs) do
                    table.insert(out.errors, { i, err[1], err[2] })
                end
            end
            table.insert(stdout, { i, format_block(res)})
        end
    end

    upd {
        block = block,
        event = "done",
        stage = "run",
        time = gettime(),
    }

    out.result = "ok"
    out.stdout = stdout
    cur_img = nil
    cb(out)
end, { "math", "qalc" })
