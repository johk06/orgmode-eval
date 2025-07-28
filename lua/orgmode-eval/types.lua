---@class (exact) OrgEvalArgs
---@field environ table<string, string>
---@field clear_environ boolean
---@field args string[]
---@field inline boolean

---@class (exact) OrgEvalBlock
---@field buf integer
---@field lnum integer
---@field end_lnum integer
---@field block OrgBlock
---@field lang string
---@field args OrgEvalArgs
---@field last_upd OrgEvalUpdate?
---@field update_virt_text integer?
---@field total_time {[1]: OrgEvalStage, [2]: number}[]?

---@alias OrgEvalStage "prepare"|"compile"|"run"

---@class OrgEvalResult
---@field block OrgEvalBlock
---@field result "error"|"ok"
---@field error_stage OrgEvalStage?
---@field exitcode integer?
---@field stdout (string|string[][])?
---@field output_style "plain"|"inline"?
---@field stderr (string|{[1]: integer, [2]: string[]})?
---@field images {[1]: integer, [2]: string}[]?
---@field errors {[1]: integer, [2]: string, [3]: integer?}[]?

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

