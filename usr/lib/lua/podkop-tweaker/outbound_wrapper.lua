-- Shared read-only discovery, persistent selection and generator CLI.
local S = require("podkop-tweaker.services")
local H = require("podkop-tweaker.outbound_hook")
local L = require("podkop-tweaker.lib")
local J = require("luci.jsonc")
local M = {}
local option = "outbound_wrapper_v1"
local mask = {tcp={{type="fragment",packets="1-1",length="100-200",max_split="2"},
    {type="fragment",packets="tlshello",length="11-24",delay="0"}}}
local function equal(a,b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function decode(v)
    return (v:gsub("%%(%x%x)", function(x) return string.char(tonumber(x,16)) end))
end
local function text(v)
    return type(v)=="string" and #v>0 and #v<=256 and not v:find("%c")
end
local function settings(uci)
    local cfg = assert(uci:get_all("podkop-tweaker","settings"), "Cannot read Tweaker settings")
    if cfg[option] == nil then return {rules={},tcp=false,record=true,delay="500ms"} end
    assert(type(cfg[option])=="string" and #cfg[option]<=65536,"Invalid wrapper settings")
    local p=assert(J.parse(cfg[option]),"Invalid wrapper settings JSON")
    assert(type(p)=="table" and type(p.rules)=="table","Invalid wrapper rules")
    for id,mode in pairs(p.rules) do
        assert(type(id)=="string" and #id<=512 and (mode=="fragment" or mode=="mask"),"Invalid saved selection")
    end
    assert(type(p.tcp)=="boolean" and type(p.record)=="boolean" and type(p.delay)=="string" and
        #p.delay<=12 and (p.delay:match("^%d+ms$") or p.delay:match("^%d+s$")),"Invalid Fragment profile")
    return p
end
local function inventory(cfg, sections, p)
    assert(type(cfg)=="table" and type(cfg.outbounds)=="table","Invalid generated outbounds")
    local bytag,rows,counts={},{},{}
    for _,o in ipairs(cfg.outbounds) do
        if type(o.tag)=="string" then
            assert(not bytag[o.tag],"Duplicate outbound tag")
            bytag[o.tag]=o
        end
    end
    local function add(sec,tag,link,single)
        local o=bytag[tag]
        if not o then return end
        local name=type(link)=="string" and link:match("#(.+)$")
        name=name and decode(name)
        local named=text(name)
        local id=sec..":"..(named and name or (single and "@section" or tag))
        local tls=o.tls or {}
        local eligible=(named or single) and tls.enabled==true and not o.detour
        if link and eligible then
            local protocol,auth,host,port=link:match("^([%w]+)://([^@]+)@([^:/?#]+):(%d+)")
            if not host then protocol,auth,host,port=link:match("^([%w]+)://([^@]+)@%[([^%]]+)%]:(%d+)") end
            eligible=host~=nil and protocol==o.type and host==o.server and tonumber(port)==o.server_port
                and ((protocol=="vless" and decode(auth)==o.uuid) or (protocol=="trojan" and decode(auth)==o.password))
        end
        local frag=tls.fragment==true or tls.record_fragment==true
        local matched=frag and (tls.fragment==true)==p.tcp and (tls.record_fragment==true)==p.record and
            (not p.tcp or tls.fragment_fallback_delay==p.delay)
        rows[#rows+1]={id=id,section=sec,name=named and name or tag,tag=tag,
            eligible=eligible==true, mask=o.finalmask~=nil, exact=equal(o.finalmask,mask),
            fragment=frag, matches_fragment=matched, wanted=p.rules[id]}
        counts[id]=(counts[id] or 0)+1
    end
    for sec,v in pairs(sections) do
        if v[".type"]=="section" and v.connection_type=="proxy" then
            local function list(key,suffix)
                local links=v[key] or {}
                if type(links)=="string" then links={links} end
                assert(type(links)=="table","Invalid Podkop link list")
                for i,link in ipairs(links) do add(sec,sec..suffix..i.."-out",link,false) end
            end
            if v.proxy_config_type=="urltest" then
                list("urltest_proxy_links","-"); list("urltest_fallback_links","-fallback-")
            elseif v.proxy_config_type=="selector" then list("selector_proxy_links","-")
            elseif v.proxy_config_type=="url" then add(sec,sec.."-out",v.proxy_string,true)
            elseif v.proxy_config_type=="outbound" then add(sec,sec.."-out",nil,true) end
        end
    end
    for _,r in ipairs(rows) do
        if counts[r.id]~=1 then r.eligible=false end
    end
    for id,mode in pairs(p.rules) do
        if not counts[id] then rows[#rows+1]={id=id,section=id:match("^([^:]+)") or "Missing",
            name=id:match(":(.*)$") or id,tag="",eligible=false,missing=true,wanted=mode} end
    end
    table.sort(rows,function(a,b) return a.section<b.section or (a.section==b.section and a.tag<b.tag) end)
    return rows
end
local function snapshot(path)
    local u=require("luci.model.uci").cursor()
    local sections,err=u:get_all("podkop")
    assert(not err and type(sections)=="table",err or "Cannot read Podkop configuration")
    for name,section in pairs(sections) do
        assert(type(name)=="string" and type(section)=="table" and section[".name"]==name
            and type(section[".type"])=="string","Invalid Podkop section inventory")
    end
    local live=assert(sections.settings and sections.settings.config_path,"Missing Podkop config path")
    assert(u:get("sing-box","main","conffile")==live,"Podkop and sing-box paths differ")
    local bytes=assert(S.read_file(path or live,S.SINGBOX_MAX_SIZE))
    local p=settings(u)
    -- Filter only the freshly decoded working copy. Status and generation never
    -- commit it. Apply re-reads under its locks and commits both modes together.
    for id in pairs(p.rules) do
        local owner=assert(id:match("^([^:]+):.+$"),"Invalid saved outbound identity")
        if not sections[owner] then p.rules[id]=nil end
    end
    return inventory(assert(J.parse(bytes),"Invalid sing-box JSON"),sections,p),p
end
local function summary(rows,p,mode,ready)
    local applied,selected,temporary,bad=0,0,0,0
    for id,v in pairs(p.rules) do if v==mode then selected=selected+1 end end
    for _,r in ipairs(rows) do
        local present=(mode=="mask" and r.mask) or (mode=="fragment" and r.fragment)
        if r.wanted==mode then
            if r.eligible and ((mode=="mask" and r.exact and not r.fragment) or
                (mode=="fragment" and r.matches_fragment and not r.mask)) then applied=applied+1 end
        elseif present then temporary=temporary+1 end
        if present and ((r.mask and r.fragment) or (mode=="mask" and not r.exact)) then bad=bad+1 end
    end
    local state="OFF"
    if bad>0 or applied~=selected or (selected>0 and not ready) then state="ERROR"
    elseif selected>0 then state="ON"
    elseif temporary>0 then state="Temporary" end
    return {state=state,applied=applied,selected=selected,temporary=temporary}
end
local function view()
    local rows,p=snapshot()
    local ready=H.status()
    -- Stable snapshot for stale-tab protection, not an authentication credential.
    local facts={tostring(ready),tostring(p.tcp),tostring(p.record),p.delay}
    for _,r in ipairs(rows) do
        facts[#facts+1]=J.stringify({r.id,r.tag,r.wanted or "",r.eligible,r.mask or false,r.exact or false,
            r.fragment or false,r.matches_fragment or false})
    end
    local hash=7
    for i=1,#facts do for j=1,#facts[i] do hash=(hash*131+facts[i]:byte(j))%2147483647 end end
    return {rows=rows,count=#rows,revision=tostring(hash),ready=ready,
        fragment=summary(rows,p,"fragment",ready),mask=summary(rows,p,"mask",ready),
        tcp=p.tcp,record=p.record,delay=p.delay},p
end
local function guarded(fn,...)
    local ok,result=pcall(fn,...)
    return ok and result or {error=tostring(result)}
end
function M.status() return guarded(view) end
function M.repair() return guarded(H.install) end
local function save(raw)
    assert(type(raw)=="string" and #raw<65536,"Invalid selection")
    local req=assert(J.parse(raw),"Invalid selection JSON")
    local mode=req.mode
    assert((mode=="mask" or mode=="fragment") and type(req.ids)=="table","Invalid mode or selection")
    local result,err,uncertain=S.with_lock("podkop",function()
        local changed,why=S.with_lock("tweaker",function()
            local v,p=view()
            assert(v.ready and v.revision==req.revision,"Wrapper or inventory changed; reopen settings")
            local chosen,available={},{}
            for _,r in ipairs(v.rows) do available[r.id]=r end
            for i,id in pairs(req.ids) do
                local r=available[id]
                assert(type(i)=="number" and i>=1 and i<=#req.ids and not chosen[id] and r and
                    (r.eligible or r.wanted==mode),"Invalid or unavailable selection")
                assert(not (r.mask and not r.exact),"Existing custom mask cannot be replaced")
                if (r.wanted and r.wanted~=mode) or (mode=="mask" and r.fragment) or
                    (mode=="fragment" and r.mask) then assert(req.replace==true,"Explicit mode replacement required") end
                chosen[id]=true
            end
            if mode=="fragment" then
                assert(type(req.tcp)=="boolean" and type(req.record)=="boolean" and
                    (not next(chosen) or req.tcp or req.record),"Choose a fragmentation method")
                assert(type(req.delay)=="string" and #req.delay<=12 and
                    (req.delay:match("^%d+ms$") or req.delay:match("^%d+s$")),"Invalid fallback delay")
                p.tcp,p.record,p.delay=req.tcp,req.record,req.delay
            elseif next(chosen) then
                local ok,version=S.exec_bounded("sing-box version")
                assert(ok and version:find("dialer.finalmask",1,true),"Installed engine does not advertise dialer.finalmask")
            end
            for id,m in pairs(p.rules) do if m==mode and not chosen[id] then p.rules[id]=nil end end
            for id in pairs(chosen) do p.rules[id]=mode end
            local u=require("luci.model.uci").cursor()
            assert(u:set("podkop-tweaker","settings",option,J.stringify(p)),"Cannot stage selection")
            assert(u:commit("podkop-tweaker"),"Cannot commit selection")
            assert(equal(settings(require("luci.model.uci").cursor()),p),"Cannot verify saved selection")
            return true
        end)
        assert(changed,why)
        local r=S.restart_service("podkop")
        r.settings_saved=true
        return r
    end)
    return result or {error=err,unknown=uncertain}
end
function M.apply(raw) return guarded(save,raw) end

-- jq preserves empty JSON arrays/objects in untouched upstream fields. Never
-- decode/serialize the entire generated config with Lua's ambiguous {}.
local transform=[[
(.outbounds[] | select(.tag as $t | $rules[$t]=="mask") | .finalmask)=$mask |
(.outbounds[] | select(.tag as $t | $rules[$t]=="fragment") | .tls) |=
  (.fragment=$tcp | .record_fragment=$record |
   if $tcp then .fragment_fallback_delay=$delay else del(.fragment_fallback_delay) end)
]]
local function generate(path)
    if not next(settings(require("luci.model.uci").cursor()).rules) then return end
    local rows,p=snapshot(path)
    local rules={}
    for _,r in ipairs(rows) do
        if r.wanted then
            if not r.eligible or (r.wanted=="mask" and (r.fragment or (r.mask and not r.exact))) or
                (r.wanted=="fragment" and r.mask) then
                io.stderr:write("Outbound wrapper: skipped missing, ambiguous or conflicting selection: ",r.id,"\n")
            else rules[r.tag]=r.wanted end
        end
    end
    if not next(rules) then return end
    -- The generator owns path; jq output goes to its private candidate, using
    -- the reserved copy as input so no write truncates the source of jq.
    local bytes=assert(S.read_file(path,S.SINGBOX_MAX_SIZE))
    local stage=assert(S.stage_file(path,bytes,{mode="600"}))
    local q=L.shell_escape
    local cmd="jq -e --argjson rules "..q(J.stringify(rules)).." --argjson mask "..q(J.stringify(mask))..
        " --argjson tcp "..tostring(p.tcp).." --argjson record "..tostring(p.record)..
        " --arg delay "..q(p.delay).." "..q(transform).." "..q(stage).." > "..q(path)
    local ok,details=S.exec_checked(cmd)
    assert(S.discard_stage(stage))
    assert(ok,details)
end
if arg and arg[0] and arg[0]:match("/outbound_wrapper%.lua$") then
    if arg[1]=="generate" then generate(assert(arg[2]))
    elseif arg[1]=="install" then local r=M.repair(); assert(r.success,r.error)
    else error("Expected install or generate") end
end
M.inventory=inventory
M.summary=summary
return M
