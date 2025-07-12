local M = {}

M.gettime = function()
    local secs, msecs = vim.uv.gettimeofday()

    local total = secs + (msecs / 1000000)
    return total
end

return M
