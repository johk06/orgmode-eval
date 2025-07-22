local M = {}

M.gettime = function()
    local secs, msecs = vim.uv.gettimeofday()

    local total = secs + (msecs / 1000000)
    return total
end

M.error = function(message)
    vim.notify(("[org-eval] %s"):format(message), vim.log.levels.ERROR)
end


local has_image, image = pcall(require, "image")

M.has_image = has_image
M.image = image

M.clear_images = function(buf)
    if has_image then
        for _, img in ipairs(image.get_images { buffer = buf, namespace = "orgmode-eval" }) do
            img:clear()
        end
    end
end
return M
