-- Podkop Tweaker | pure helper library (no luci dependencies)
-- Author: InsaniaQuon

local M = {}

M.ARGON_CASCADE_CSS = "/www/luci-static/argon/css/cascade.css"
M.ARGON_CSS_MARKER_START = "/* === Podkop Tweaker Typography === */"
M.ARGON_CSS_MARKER_END = "/* === End Podkop Tweaker Typography === */"

M.ARGON_FONT_FAMILIES = {
    ["Google Sans"] = '"Google Sans", "Microsoft Yahei", "WenQuanYi Micro Hei", sans-serif',
    ["system-ui"] = "system-ui, -apple-system, sans-serif",
    ["Arial"] = "Arial, Helvetica, sans-serif",
    ["Verdana"] = "Verdana, Geneva, sans-serif",
    ["Tahoma"] = "Tahoma, Geneva, sans-serif",
    ["monospace"] = '"Cascadia Code", "JetBrains Mono", "Fira Code", monospace',
}

function M.parse_version(ver)
    if not ver then return nil end
    ver = ver:gsub("^v", "")
    local major, minor, patch = ver:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

function M.version_lt(a, b)
    local va = M.parse_version(a)
    local vb = M.parse_version(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if (va[i] or 0) < (vb[i] or 0) then return true end
        if (va[i] or 0) > (vb[i] or 0) then return false end
    end
    return false
end

function M.sanitize_section_name(name)
    if not name or name == "" then return nil end
    if not name:match("^[a-zA-Z0-9_%-]+$") then return nil end
    return name
end

function M.validate_uci_config(content)
    if not content or content == "" then
        return false, "Configuration is empty"
    end
    if #content > 1048576 then
        return false, "Config too large (max 1MB)"
    end
    if not content:match("config%s+") then
        return false, "Invalid UCI format: no 'config' declarations found"
    end
    if content:find("\0", 1, true) then
        return false, "Invalid content: contains null bytes"
    end
    -- UCI lexer. Semantics:
    --  * single/double quoted values MAY span multiple lines (multiline values)
    --  * a quote opens a value only when preceded by whitespace / line start,
    --    so apostrophes inside bare words (don't) do not open anything
    --  * line numbers in errors count every line, blanks included (editor-accurate)
    --  * an unclosed quote is reported with the line where it was opened
    local line_no = 0
    local in_sq, in_dq = false, false
    local sq_open_line, dq_open_line
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        line_no = line_no + 1
        local skip_line = false
        if not in_sq and not in_dq then
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed == "" or trimmed:sub(1, 1) == "#" then
                skip_line = true
            elseif not trimmed:match("^config%s")
                and not trimmed:match("^option%s")
                and not trimmed:match("^list%s") then
                return false, "Invalid UCI syntax at line " .. line_no .. ": unexpected token"
            end
        end
        if not skip_line then
            local prev_space = true
            for ci = 1, #line do
                local b = line:byte(ci)
                if b < 9 or (b > 13 and b < 32) then
                    return false, "Invalid character at line " .. line_no .. ", column " .. ci
                end
                local c = line:sub(ci, ci)
                if in_sq then
                    if c == "'" then in_sq = false end
                elseif in_dq then
                    if c == '"' then in_dq = false end
                elseif c == "'" then
                    if prev_space then
                        in_sq = true
                        sq_open_line = line_no
                    end
                elseif c == '"' then
                    if prev_space then
                        in_dq = true
                        dq_open_line = line_no
                    end
                end
                prev_space = (c == " " or c == "\t")
            end
        end
    end
    if in_sq then
        return false, "Unmatched single quote (opened at line " .. tostring(sq_open_line) .. ")"
    end
    if in_dq then
        return false, "Unmatched double quote (opened at line " .. tostring(dq_open_line) .. ")"
    end
    return true
end

local function clamp_str(v, min, max)
    if v == nil or v == "" then return "" end
    v = tostring(v)
    local n = tonumber(v)
    if not n or n < min or n > max then return "" end
    return v
end

M.clamp_str = clamp_str

function M.generate_argon_css(s)
    local lines = {}
    table.insert(lines, M.ARGON_CSS_MARKER_START)
    local root_lines = {}
    if s.font_size and s.font_size ~= "" then
        table.insert(root_lines, "  font-size: " .. tonumber(s.font_size) .. "px;")
    end
    local family_css
    if s.font_family == "custom" then
        family_css = s.font_family_custom
    else
        family_css = M.ARGON_FONT_FAMILIES[s.font_family]
    end
    if family_css and family_css ~= "" then
        table.insert(root_lines, '  --font-family-sans-serif: ' .. family_css .. ';')
    end
    if #root_lines > 0 then
        table.insert(lines, ":root {")
        for _, l in ipairs(root_lines) do table.insert(lines, l) end
        table.insert(lines, "}")
    end
    local body_lines = {}
    if s.font_weight and s.font_weight ~= "" then
        table.insert(body_lines, "  font-weight: " .. tonumber(s.font_weight) .. ";")
    end
    if s.line_height and s.line_height ~= "" then
        table.insert(body_lines, "  line-height: " .. tonumber(s.line_height) .. ";")
    end
    if s.letter_spacing and s.letter_spacing ~= "" then
        table.insert(body_lines, "  letter-spacing: " .. tonumber(s.letter_spacing) .. "px;")
    end
    if #body_lines > 0 then
        table.insert(lines, "body {")
        for _, l in ipairs(body_lines) do table.insert(lines, l) end
        table.insert(lines, "}")
    end
    local menu_lines = {}
    if s.menu_font_size and s.menu_font_size ~= "" then
        table.insert(menu_lines, "font-size: " .. tonumber(s.menu_font_size) .. "rem;")
    end
    if s.menu_padding and s.menu_padding ~= "" then
        table.insert(menu_lines, "padding-top: " .. tonumber(s.menu_padding) .. "px;")
        table.insert(menu_lines, "padding-bottom: " .. tonumber(s.menu_padding) .. "px;")
    end
    if #menu_lines > 0 then
        table.insert(lines, ".main-left .nav li a { " .. table.concat(menu_lines, " ") .. " }")
    end
    table.insert(lines, M.ARGON_CSS_MARKER_END)
    return table.concat(lines, "\n")
end

return M
