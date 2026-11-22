package.path="./usr/lib/lua/?.lua;./tests/?.lua;"..package.path
local H = require("pt_harness")
describe("Persistent outbound identity",function()
    local M,p,sec,cfg
    before_each(function()
        H.begin{}
        M=require("podkop-tweaker.outbound_wrapper")
        p={tcp=false,record=true,delay="500ms",rules={["main:A"]="fragment"}}
        sec={main={[".type"]="section",connection_type="proxy",proxy_config_type="urltest",
            urltest_proxy_links={"vless://u@b:443#B","vless://u@a:443#A"}}}
        cfg={outbounds={{tag="main-1-out",type="vless",uuid="u",server="b",server_port=443,tls={enabled=true}},
            {tag="main-2-out",type="vless",uuid="u",server="a",server_port=443,tls={enabled=true,record_fragment=true}}}}
    end)
    after_each(H.finish)
    it("ignores deleted sections on reads and prunes both modes only on valid Apply",function()
        local path="/etc/sing-box/config.json"
        sec.main[".name"]="main"
        sec.settings={[".name"]="settings",[".type"]="settings",config_path=path}
        p.rules["YouTube:A"]="fragment"
        p.rules["YouTube:B"]="mask"
        p.rules["main:missing"]="mask"
        local original=H.json.stringify(p)
        local u=require("luci.model.uci").cursor()
        local db={outbound_wrapper_v1=original}
        local fail,commits,restarts=false,0,0
        u.get_all=function(_,pkg)
            if pkg=="podkop" then return sec,fail and "Incomplete Podkop read" or nil end
            return db
        end
        u.get=function() return path end
        u.set=function(_,pkg,section,opt,value) db[opt]=value; return true end
        u.commit=function() commits=commits+1; return true end
        H.vfs_write(path,H.json.stringify(cfg))
        local S=require("podkop-tweaker.services")
        S.restart_service=function() restarts=restarts+1; return {success=true} end
        require("podkop-tweaker.outbound_hook").status=function() return true end
        local v=M.status()
        assert.is_nil(v.error)
        assert.equals("ON",v.fragment.state)
        assert.equals(1,v.fragment.selected)
        assert.equals("ERROR",v.mask.state)
        assert.equals(1,v.mask.selected)
        for _,r in ipairs(v.rows) do assert.equals("main",r.section) end
        assert.equals(original,db.outbound_wrapper_v1)
        local req=H.json.stringify({mode="fragment",ids={"main:A"},revision=v.revision,tcp=false,record=true,delay="500ms"})
        fail=true
        assert.is_truthy(M.status().error)
        assert.is_truthy(M.apply(req).error)
        assert.equals(original,db.outbound_wrapper_v1)
        assert.equals(0,commits)
        assert.equals(0,restarts)
        fail=false
        local result=M.apply(req)
        assert.is_true(result.success,result.error)
        assert.same({["main:A"]="fragment",["main:missing"]="mask"},H.json.parse(db.outbound_wrapper_v1).rules)
        assert.equals(1,commits)
        assert.equals(1,restarts)
    end)
    it("resolves by section and link identity after slot reorder",function()
        local r=M.inventory(cfg,sec,p)
        assert.is_nil(r[1].wanted)
        assert.equals("main-2-out",r[2].tag)
        assert.equals("fragment",r[2].wanted)
        assert.equals("ON",M.summary(r,p,"fragment",true).state)
        cfg.outbounds[2].server="different"
        r=M.inventory(cfg,sec,p)
        assert.is_false(r[2].eligible)
        assert.equals("ERROR",M.summary(r,p,"fragment",true).state)
    end)
    it("never sends a missing or ambiguous selection to the remaining slot",function()
        sec.main.urltest_proxy_links[2]=nil
        local r=M.inventory(cfg,sec,p)
        assert.equals("ERROR",M.summary(r,p,"fragment",true).state)
        assert.is_true(r[1].missing)
        sec.main.urltest_proxy_links={"vless://u@b:443#A","vless://u@a:443#A"}
        for _,node in ipairs(M.inventory(cfg,sec,p)) do assert.is_false(node.eligible) end
    end)
    it("observes temporary config without adopting it",function()
        p.rules={}
        cfg.outbounds[1].finalmask={tcp={{type="fragment",packets="1-1",length="100-200",max_split="2"},
            {type="fragment",packets="tlshello",length="11-24",delay="0"}}}
        local r=M.inventory(cfg,sec,p)
        local summary=M.summary(r,p,"mask",true)
        assert.equals("Temporary",summary.state)
        assert.equals(1,summary.temporary)
        cfg.outbounds[1].finalmask.tcp[1].packets="1-2"
        assert.equals("ERROR",M.summary(M.inventory(cfg,sec,p),p,"mask",true).state)
    end)
end)
