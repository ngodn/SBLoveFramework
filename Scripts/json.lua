--[[
    SBLoveFramework -- minimal JSON decoder
    ------------------------------------------------------------------
    Decode only. Addon files are read, never written, so there is no encoder and
    no round-trip to get wrong.

    Written rather than vendored so there is no third party licence to carry in
    a mod that is meant to be freely redistributable, and so errors can carry a
    character offset. An addon author with a stray comma needs to be told where
    it is, not that "parsing failed".

    Handles the whole of RFC 8259 except for two deliberate omissions:

      - numbers are parsed with tonumber, so Lua's numeric range applies. Scene
        files hold offsets and play rates, not big integers.
      - duplicate keys resolve last-wins, matching most implementations.

    Surrogate pairs ARE handled, because animation packs come from authors
    writing in Japanese, Korean and Chinese, and a display name that decodes to
    mojibake is worse than one that fails loudly.
--]]

local Json = {}

local escapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

--- Line and column for an offset, so an error can be acted on.
local function Position(text, offset)
    local line, lineStart = 1, 1
    for i = 1, math.min(offset, #text) do
        if text:sub(i, i) == '\n' then line = line + 1 lineStart = i + 1 end
    end
    return line, offset - lineStart + 1
end

local function Fail(text, offset, message)
    local line, column = Position(text, offset)
    error(string.format("line %d column %d: %s", line, column, message), 0)
end

local function SkipSpace(text, offset)
    local _, stop = text:find("^[ \t\r\n]*", offset)
    return (stop or offset - 1) + 1
end

--- UTF-8 encode a code point. UE4SS's Lua has no utf8 library guarantee, so
--- this is done by hand.
local function Utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
    elseif code < 0x10000 then
        return string.char(0xE0 | (code >> 12),
                           0x80 | ((code >> 6) & 0x3F),
                           0x80 | (code & 0x3F))
    end
    return string.char(0xF0 | (code >> 18),
                       0x80 | ((code >> 12) & 0x3F),
                       0x80 | ((code >> 6) & 0x3F),
                       0x80 | (code & 0x3F))
end

local ParseValue

local function ParseString(text, offset)
    offset = offset + 1                       -- skip the opening quote
    local parts, start = {}, offset

    while true do
        local char = text:sub(offset, offset)
        if char == "" then Fail(text, offset, "unterminated string") end

        if char == '"' then
            parts[#parts + 1] = text:sub(start, offset - 1)
            return table.concat(parts), offset + 1
        end

        if char == "\\" then
            parts[#parts + 1] = text:sub(start, offset - 1)
            local code = text:sub(offset + 1, offset + 1)

            if escapes[code] then
                parts[#parts + 1] = escapes[code]
                offset = offset + 2
            elseif code == "u" then
                local hex = text:sub(offset + 2, offset + 5)
                local value = tonumber(hex, 16)
                if not value or #hex < 4 then
                    Fail(text, offset, "bad \\u escape")
                end
                offset = offset + 6

                -- A high surrogate must be followed by a low one; together they
                -- form a single code point above the basic plane.
                if value >= 0xD800 and value <= 0xDBFF then
                    if text:sub(offset, offset + 1) ~= "\\u" then
                        Fail(text, offset, "high surrogate with no low surrogate")
                    end
                    local low = tonumber(text:sub(offset + 2, offset + 5), 16)
                    if not low or low < 0xDC00 or low > 0xDFFF then
                        Fail(text, offset, "bad low surrogate")
                    end
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    offset = offset + 6
                end

                parts[#parts + 1] = Utf8(value)
            else
                Fail(text, offset, "unknown escape \\" .. code)
            end
            start = offset
        else
            offset = offset + 1
        end
    end
end

local function ParseNumber(text, offset)
    local literal = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", offset)
    if not literal or literal == "" then Fail(text, offset, "bad number") end
    local value = tonumber(literal)
    if not value then Fail(text, offset, "bad number '" .. literal .. "'") end
    return value, offset + #literal
end

local function ParseArray(text, offset)
    offset = SkipSpace(text, offset + 1)
    local list = {}

    if text:sub(offset, offset) == "]" then return list, offset + 1 end

    while true do
        local value
        value, offset = ParseValue(text, offset)
        list[#list + 1] = value
        offset = SkipSpace(text, offset)

        local char = text:sub(offset, offset)
        if char == "]" then return list, offset + 1 end
        if char ~= "," then Fail(text, offset, "expected ',' or ']' in array") end
        offset = SkipSpace(text, offset + 1)
    end
end

local function ParseObject(text, offset)
    offset = SkipSpace(text, offset + 1)
    local object = {}

    if text:sub(offset, offset) == "}" then return object, offset + 1 end

    while true do
        if text:sub(offset, offset) ~= '"' then
            Fail(text, offset, "expected a quoted key")
        end
        local key
        key, offset = ParseString(text, offset)

        offset = SkipSpace(text, offset)
        if text:sub(offset, offset) ~= ":" then
            Fail(text, offset, "expected ':' after key '" .. key .. "'")
        end

        offset = SkipSpace(text, offset + 1)
        local value
        value, offset = ParseValue(text, offset)
        object[key] = value

        offset = SkipSpace(text, offset)
        local char = text:sub(offset, offset)
        if char == "}" then return object, offset + 1 end
        if char ~= "," then
            Fail(text, offset, "expected ',' or '}' after key '" .. key .. "'")
        end
        offset = SkipSpace(text, offset + 1)
    end
end

ParseValue = function(text, offset)
    offset = SkipSpace(text, offset)
    local char = text:sub(offset, offset)

    if char == "" then Fail(text, offset, "unexpected end of input") end
    if char == "{" then return ParseObject(text, offset) end
    if char == "[" then return ParseArray(text, offset) end
    if char == '"' then return ParseString(text, offset) end

    if text:sub(offset, offset + 3) == "true"  then return true,  offset + 4 end
    if text:sub(offset, offset + 4) == "false" then return false, offset + 5 end
    -- null becomes nil, which erases a table key. Callers that need to tell
    -- "absent" from "explicitly null" should not use null in the format.
    if text:sub(offset, offset + 3) == "null"  then return nil,   offset + 4 end

    if char:match("[%d%-]") then return ParseNumber(text, offset) end

    Fail(text, offset, "unexpected character '" .. char .. "'")
end

--- Decode a JSON string. Returns value, or nil plus a message with line and
--- column. Never raises, so a malformed addon cannot take the mod down.
function Json.decode(text)
    if type(text) ~= "string" then return nil, "input is not a string" end

    -- Strip a UTF-8 BOM. Editors on Windows add one and it is not valid JSON.
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end

    local ok, value, offset = pcall(ParseValue, text, 1)
    if not ok then return nil, tostring(value) end

    offset = SkipSpace(text, offset)
    if offset <= #text then
        local line, column = Position(text, offset)
        return nil, string.format("line %d column %d: trailing content", line, column)
    end
    return value
end

--- Read and decode a file.
function Json.decodeFile(path)
    local file, err = io.open(path, "r")
    if not file then return nil, "cannot open: " .. tostring(err) end
    local text = file:read("*a")
    file:close()

    local value, decodeError = Json.decode(text)
    if value == nil and decodeError then
        return nil, path .. ": " .. decodeError
    end
    return value
end

return Json
