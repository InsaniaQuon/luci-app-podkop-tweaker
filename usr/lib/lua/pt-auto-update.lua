local M = require("pt-subs-lib")

local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local LOG_FILE = "/etc/config/pt-update.log"
local LOG_MAX = 25

local sections = M.get_proxy_sections()
local subs = M.read_subs(SUBS_FILE)
local updated, unchanged, failed = 0, 0, 0
local need_restart = false
local details = {}

for _, sec in ipairs(sections) do
    local sec_subs = subs[sec.name] or {}
    for i, link in ipairs(sec.proxy_links) do
        local sub_entry = sec_subs[i]
        if sub_entry and type(sub_entry) == "table"
            and sub_entry.subscription_url and sub_entry.subscription_url ~= "" then
            local proxy, _ = M.do_update_subscription(
                sec.name, i - 1, sub_entry.subscription_url, sub_entry.proxy_name)
            local pname = sub_entry.proxy_name or ""
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
                        table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "updated"})
                    else
                        failed = failed + 1
                        table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "failed"})
                    end
                else
                    unchanged = unchanged + 1
                    table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "unchanged"})
                end
                M.update_subs_timestamp(SUBS_FILE, sec.name, i - 1, "auto")
            else
                failed = failed + 1
                table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "failed"})
            end
        end
    end
end

if need_restart then
    os.execute("nohup /etc/init.d/podkop restart >/dev/null 2>&1 &")
end

local log_text = os.date("%H:%M %d.%m.%Y") .. "|auto|updated=" .. updated
    .. "|unchanged=" .. unchanged .. "|failed=" .. failed
local by_section = {}
for _, d in ipairs(details) do
    if not by_section[d.section] then by_section[d.section] = {} end
    by_section[d.section][#by_section[d.section] + 1] = d
end
local sec_names = {}
for k, _ in pairs(by_section) do sec_names[#sec_names + 1] = k end
table.sort(sec_names)
for _, sname in ipairs(sec_names) do
    log_text = log_text .. "\n  " .. sname .. ":"
    for _, d in ipairs(by_section[sname]) do
        log_text = log_text .. "\n    " .. d.proxy .. ": " .. d.status
    end
end
M.append_log(LOG_FILE, LOG_MAX, log_text)
