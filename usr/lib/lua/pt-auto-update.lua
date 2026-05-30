local M = require("pt-subs-lib")

local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local LOG_FILE = "/etc/config/pt-update.log"
local LOG_MAX = 25

local sections = M.get_proxy_sections()
local subs = M.read_subs(SUBS_FILE)
local updated, unchanged, failed = 0, 0, 0
local need_restart = false

for _, sec in ipairs(sections) do
    local sec_subs = subs[sec.name] or {}
    for i, link in ipairs(sec.proxy_links) do
        local sub_entry = sec_subs[i]
        if sub_entry and type(sub_entry) == "table"
            and sub_entry.subscription_url and sub_entry.subscription_url ~= "" then
            local proxy, _ = M.do_update_subscription(
                sec.name, i - 1, sub_entry.subscription_url, sub_entry.proxy_name)
            if proxy and proxy.link then
                local current_link = link or ""
                if current_link ~= proxy.link then
                    if not need_restart then
                        local cfd = io.open("/etc/config/podkop", "r")
                        if cfd then
                            local config_data = cfd:read("*a")
                            cfd:close()
                            if config_data then
                                local bfd = io.open("/etc/config/podkop.sub-backup", "w")
                                if bfd then bfd:write(config_data); bfd:close() end
                            end
                        end
                    end
                    local rok, _ = M.replace_proxy_link(sec.name, sec.proxy_config_type, i - 1, proxy.link)
                    if rok then
                        updated = updated + 1
                        need_restart = true
                    else
                        failed = failed + 1
                    end
                else
                    unchanged = unchanged + 1
                end
                M.update_subs_timestamp(SUBS_FILE, sec.name, i - 1, "auto")
            else
                failed = failed + 1
            end
        end
    end
end

if need_restart then
    os.execute("nohup /etc/init.d/podkop restart >/dev/null 2>&1 &")
end

local log_line = os.date("%Y-%m-%d %H:%M") .. "|auto|updated=" .. updated
    .. "|unchanged=" .. unchanged .. "|failed=" .. failed
M.append_log(LOG_FILE, LOG_MAX, log_line)
