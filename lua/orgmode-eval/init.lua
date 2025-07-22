local M = {}

local api = vim.api

local parser = require("orgmode-eval.parser")
local eval = require("orgmode-eval.evaluators")
local ui = require("orgmode-eval.ui")
local util = require("orgmode-eval.util")

M.run_code_block = function()
    local block = parser.get_parsed_current_block()
    if not block then
        return
    end
    eval.evaluate(block, ui.display_evaluation_result, ui.update_in_progress)
end

M.clear_buffer = function(buf)
    buf = buf or api.nvim_get_current_buf()

    vim.diagnostic.set(ui.diagnostics, buf, {})
    api.nvim_buf_clear_namespace(buf, ui.highlights, 0, -1)
    util.clear_images(buf)
end

M.setup = require("orgmode-eval.opts").setup

M.register = eval.register_evaluator
M.register_compiler = eval.register_compiler
M.register_interpreter = eval.register_interpreter

return M
