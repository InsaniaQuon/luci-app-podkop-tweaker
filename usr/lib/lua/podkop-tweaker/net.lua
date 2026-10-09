-- Podkop Tweaker | bounded HTTP downloads (standalone Lua compatible)
local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local M = {}

function M.valid_url(url, https_only)
    if type(url) ~= "string" or #url > 4096 or url:find("[%c%s]") then return false end
    if https_only then return url:match("^https://[^/]+") ~= nil end
    return url:match("^https?://[^/]+") ~= nil
end

-- Pipe output is bounded even on curl builds whose max-filesize only checks
-- Content-Length. Closing an over-limit pipe stops the producer (broken pipe).
function M.fetch(url, limit, timeout, user_agent, https_only)
    if not M.valid_url(url, https_only) then return nil, "Invalid HTTP(S) URL" end
    local protocols = https_only and "=https" or "=http,https"
    local cmd = "curl --disable --silent --show-error --fail --location --globoff --max-redirs 5" ..
        " --max-time " .. tostring(timeout or 15) .. " --max-filesize " .. tostring(limit) ..
        " --proto " .. LIB.shell_escape(protocols) .. " --proto-redir " .. LIB.shell_escape(protocols) ..
        " -A " .. LIB.shell_escape(user_agent or "PodkopTweaker") .. " " .. LIB.shell_escape(url) ..
        " 2>/dev/null; printf '\\nPT_CURL_EXIT:%s\\n' \"$?\""
    local fd = io.popen(cmd, "r")
    if not fd then return nil, "Cannot start download" end
    local raw, err = SRV.read_stream(fd, limit + 64)
    fd:close()
    if not raw then return nil, err end
    local body, status = raw:match("^(.*)\nPT_CURL_EXIT:(%d+)\n$")
    if not body then return nil, "Cannot determine download result" end
    if #body > limit or status == "63" then return nil, "Response exceeds size limit" end
    if status ~= "0" then return nil, "Download failed (curl exit " .. status .. ")" end
    return body
end

return M
