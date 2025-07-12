local M = {}

M.gettime = function()
    local secs, msecs = vim.uv.gettimeofday()

    local total = secs + (msecs / 1000000)
    return total
end

M.error = function(message)
    vim.notify(("[org-eval] %s"):format(message), vim.log.levels.ERROR)
end

return M
