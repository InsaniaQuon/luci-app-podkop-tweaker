-- Author: InsaniaQuon
-- Podkop Tweaker | v4.1.0 | 22.08.2026 | Controller split: dispatcher only, endpoint logic in podkop-tweaker/api_* modules

local APP_VERSION = "4.1.0"

local H = require("podkop-tweaker.http")
local PDK = require("podkop-tweaker.api_podkop")
local SUB = require("podkop-tweaker.api_subs")
local STB = require("podkop-tweaker.api_stubby")
local SBX = require("podkop-tweaker.api_singbox")
local DIA = require("podkop-tweaker.api_diag")
local ARG = require("podkop-tweaker.api_argon")
local BND = require("podkop-tweaker.api_bundle")
local UPD = require("podkop-tweaker.api_update")

UPD.init(APP_VERSION)

module("luci.controller.podkop-tweaker", package.seeall)

function index()
    entry({"admin", "services", "podkop-tweaker"},
        alias("admin", "services", "podkop-tweaker", "config"),
        _("Podkop Tweaker"), 60)

    entry({"admin", "services", "podkop-tweaker", "config"},
        call("action_config"), nil, 10)

    entry({"admin", "services", "podkop-tweaker", "stubby"},
        call("action_stubby"), nil, 15)

    entry({"admin", "services", "podkop-tweaker", "singbox"},
        call("action_singbox"), nil, 16)

    entry({"admin", "services", "podkop-tweaker", "diagnostics"},
        call("action_diagnostics"), nil, 17)

    entry({"admin", "services", "podkop-tweaker", "import-export"},
        call("action_import_export"), nil, 20)

    entry({"admin", "services", "podkop-tweaker", "subscriptions"},
        call("action_subscriptions"), nil, 40)

    entry({"admin", "services", "podkop-tweaker", "argon"},
        call("action_argon"), nil, 45)

    entry({"admin", "services", "podkop-tweaker", "system-info"},
        call("action_system_info"), nil, 30)

    entry({"admin", "services", "podkop-tweaker", "update"},
        call("action_update"), nil, 50)

    entry({"admin", "services", "podkop-tweaker", "about"},
        call("action_about"), nil, 60)

    entry({"admin", "services", "podkop-tweaker", "api", "read_config"},
        call("api_read_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_config"},
        call("api_save_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_stubby_config"},
        call("api_read_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_stubby_config"},
        call("api_save_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_service_status"},
        call("api_stubby_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_service_toggle"},
        call("api_stubby_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback_stubby"},
        call("api_rollback_stubby")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_stubby_config"},
        call("api_export_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_stubby_backup"},
        call("api_download_stubby_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_chain_info"},
        call("api_stubby_chain_info")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_init_check"},
        call("api_stubby_init_check")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_init_fix"},
        call("api_stubby_init_fix")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_stubby_config"},
        call("api_import_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "apply_recommended_stubby"},
        call("api_apply_recommended_stubby")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_singbox_config"},
        call("api_read_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_singbox_config"},
        call("api_save_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_service_status"},
        call("api_singbox_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_service_toggle"},
        call("api_singbox_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback_singbox"},
        call("api_rollback_singbox")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_singbox_config"},
        call("api_export_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_singbox_backup"},
        call("api_download_singbox_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_singbox_config"},
        call("api_import_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_outbounds"},
        call("api_singbox_outbounds")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_patch_fragment"},
        call("api_singbox_patch_fragment")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "wrapper_status"},
        call("api_wrapper_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "wrapper_toggle"},
        call("api_wrapper_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "fragment_settings"},
        call("api_fragment_settings")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "argon_typography"},
        call("api_argon_typography")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "argon_typography_save"},
        call("api_argon_typography_save")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "argon_typography_reset"},
        call("api_argon_typography_reset")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "argon_reinject"},
        call("api_argon_reinject")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_service_toggle"},
        call("api_podkop_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_autostart"},
        call("api_podkop_autostart")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_autostart_toggle"},
        call("api_podkop_autostart_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_autostart"},
        call("api_stubby_autostart")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_autostart_toggle"},
        call("api_stubby_autostart_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_dns"},
        call("api_diag_dns")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_proxy"},
        call("api_diag_proxy")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_e2e"},
        call("api_diag_e2e")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_dns_leak"},
        call("api_diag_dns_leak")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_config"},
        call("api_export_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_config"},
        call("api_import_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_bundle"},
        call("api_export_bundle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_bundle"},
        call("api_import_bundle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_backup"},
        call("api_download_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "service_status"},
        call("api_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback"},
        call("api_rollback")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "system_info"},
        call("api_system_info")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "update_start"},
        call("api_update_start")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_state"},
        call("api_subscription_state")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_fetch"},
        call("api_subscription_fetch")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_attach"},
        call("api_subscription_attach")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_detach"},
        call("api_subscription_detach")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "settings_read"},
        call("api_settings_read")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "settings_save"},
        call("api_settings_save")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "update_all_subs"},
        call("api_update_all_subs")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_sub_backup"},
        call("api_download_sub_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "upload_update"},
        call("api_upload_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "apply_update"},
        call("api_apply_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "tweaker_check_update"},
        call("api_tweaker_check_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "tweaker_git_update"},
        call("api_tweaker_git_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "clear_cache"},
        call("api_clear_cache")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "app_version"},
        call("api_app_version")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_update_log"},
        call("api_read_update_log")).leaf = true
end

local function render_page(template_name, extra)
    local uci = require("luci.model.uci").cursor()
    local vars = {
        app_version = APP_VERSION,
        csrf_token = H.ensure_csrf_token(),
        show_argon = (uci:get("podkop-tweaker", "settings", "show_argon_tab") == "1")
    }
    if extra then for k, v in pairs(extra) do vars[k] = v end end
    luci.template.render("podkop-tweaker/" .. template_name, vars)
end

function action_config()
    render_page("config")
end

function action_stubby()
    render_page("stubby")
end

function action_singbox()
    render_page("singbox")
end

function action_diagnostics()
    render_page("diagnostics")
end

function action_import_export()
    local nixio = require("nixio")
    local auto_backup_attr = nixio.fs.stat("/etc/config/podkop.auto-backup")
    local auto_backup_time = auto_backup_attr
        and os.date("%H:%M %d.%m.%Y", auto_backup_attr.mtime) or nil
    local sub_backup_attr = nixio.fs.stat("/etc/config/podkop.sub-backup")
    local auto_sub_backup_time = sub_backup_attr
        and os.date("%H:%M %d.%m.%Y", sub_backup_attr.mtime) or nil
    local stubby_backup_attr = nixio.fs.stat("/etc/config/stubby.auto-backup")
    local stubby_backup_time = stubby_backup_attr
        and os.date("%H:%M %d.%m.%Y", stubby_backup_attr.mtime) or nil
    local singbox_backup_attr = nixio.fs.stat("/etc/sing-box/config.json.auto-backup")
    local singbox_backup_time = singbox_backup_attr
        and os.date("%H:%M %d.%m.%Y", singbox_backup_attr.mtime) or nil
    render_page("import-export", {
        auto_backup_time = auto_backup_time,
        auto_sub_backup_time = auto_sub_backup_time,
        stubby_backup_time = stubby_backup_time,
        singbox_backup_time = singbox_backup_time
    })
end

function action_system_info()
    render_page("system-info")
end

function action_subscriptions()
    render_page("subscriptions")
end

function action_argon()
    local uci = require("luci.model.uci").cursor()
    if uci:get("podkop-tweaker", "settings", "show_argon_tab") ~= "1" then
        luci.http.redirect(luci.dispatcher.build_url("admin/services/podkop-tweaker/config"))
        return
    end
    render_page("argon")
end

function action_update()
    render_page("update")
end

function action_about()
    render_page("about")
end

function api_app_version()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    http.write_json({ version = APP_VERSION })
end

-- === Podkop ===

function api_system_info() return PDK.system_info() end
function api_update_start() return PDK.update_start() end
function api_read_config() return PDK.read_config() end
function api_save_config() return PDK.save_config() end
function api_export_config() return PDK.export_config() end
function api_download_backup() return PDK.download_backup() end
function api_import_config() return PDK.import_config() end
function api_service_status() return PDK.service_status() end
function api_rollback() return PDK.rollback() end
function api_podkop_service_toggle() return PDK.service_toggle() end
function api_podkop_autostart() return PDK.autostart() end
function api_podkop_autostart_toggle() return PDK.autostart_toggle() end

-- === Subscriptions ===

function api_subscription_state() return SUB.subscription_state() end
function api_subscription_fetch() return SUB.subscription_fetch() end
function api_subscription_attach() return SUB.subscription_attach() end
function api_subscription_detach() return SUB.subscription_detach() end
function api_settings_read() return SUB.settings_read() end
function api_settings_save() return SUB.settings_save() end
function api_update_all_subs() return SUB.update_all() end
function api_download_sub_backup() return SUB.download_sub_backup() end

-- === Stubby ===

function api_read_stubby_config() return STB.read_config() end
function api_save_stubby_config() return STB.save_config() end
function api_stubby_service_status() return STB.service_status() end
function api_stubby_service_toggle() return STB.service_toggle() end
function api_rollback_stubby() return STB.rollback() end
function api_export_stubby_config() return STB.export_config() end
function api_download_stubby_backup() return STB.download_backup() end
function api_stubby_chain_info() return STB.chain_info() end
function api_stubby_init_check() return STB.init_check() end
function api_stubby_init_fix() return STB.init_fix() end
function api_import_stubby_config() return STB.import_config() end
function api_apply_recommended_stubby() return STB.apply_recommended() end
function api_stubby_autostart() return STB.autostart() end
function api_stubby_autostart_toggle() return STB.autostart_toggle() end

-- === Sing-box ===

function api_read_singbox_config() return SBX.read_config() end
function api_save_singbox_config() return SBX.save_config() end
function api_singbox_service_status() return SBX.service_status() end
function api_singbox_service_toggle() return SBX.service_toggle() end
function api_rollback_singbox() return SBX.rollback() end
function api_export_singbox_config() return SBX.export_config() end
function api_download_singbox_backup() return SBX.download_backup() end
function api_import_singbox_config() return SBX.import_config() end
function api_singbox_outbounds() return SBX.outbounds() end
function api_singbox_patch_fragment() return SBX.patch_fragment() end
function api_wrapper_status() return SBX.wrapper_status() end
function api_wrapper_toggle() return SBX.wrapper_toggle() end
function api_fragment_settings() return SBX.fragment_settings() end

-- === Diagnostics ===

function api_diag_dns() return DIA.dns() end
function api_diag_proxy() return DIA.proxy() end
function api_diag_e2e() return DIA.e2e() end
function api_diag_dns_leak() return DIA.dns_leak() end

-- === Argon ===

function api_argon_typography() return ARG.typography() end
function api_argon_typography_save() return ARG.typography_save() end
function api_argon_typography_reset() return ARG.typography_reset() end
function api_argon_reinject() return ARG.reinject() end

-- === Bundle ===

function api_export_bundle() return BND.export() end
function api_import_bundle() return BND.import() end

-- === Update ===

function api_upload_update() return UPD.upload() end
function api_apply_update() return UPD.apply() end
function api_clear_cache() return UPD.clear_cache() end
function api_read_update_log() return UPD.read_log() end
function api_tweaker_check_update() return UPD.check_update() end
function api_tweaker_git_update() return UPD.git_update() end
