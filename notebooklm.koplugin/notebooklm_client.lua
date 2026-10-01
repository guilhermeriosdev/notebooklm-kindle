--[[--
Cliente HTTP da ponte do Gemini (bridge/server.py).

Todas as funções bloqueiam até a resposta e devolvem `data` ou
`nil, mensagem_de_erro` já traduzida para mostrar ao usuário.
--]]--

local ffiutil = require("ffi/util")
local http = require("socket.http")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = ffiutil.template

local Client = {}
Client.__index = Client

--- O decodificador JSON pode devolver um sentinela para `null`.
function Client.str(value)
    return type(value) == "string" and value or nil
end

function Client.new(settings)
    return setmetatable({ settings = settings }, Client)
end

function Client:baseUrl()
    local url = self.settings:readSetting("server_url")
    if not url or url == "" then return nil end
    return (url:gsub("/+$", ""))
end

function Client:headers()
    return {
        ["X-Bridge-Token"] = self.settings:readSetting("token") or "",
        ["Accept"] = "application/json",
    }
end

local function perform(request, timeouts)
    socketutil:set_timeout(timeouts[1], timeouts[2])
    local ok, code = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok or type(code) ~= "number" then
        logger.warn("Gemini: falha de rede", request.method, request.url, code)
        return nil, T(_("Não foi possível falar com a ponte:\n%1"), tostring(code))
    end
    return code
end

local function decode(code, sink)
    local content = table.concat(sink)
    local decoded, data = pcall(json.decode, content)
    if not decoded then data = nil end
    if code ~= 200 then
        local detail = type(data) == "table" and Client.str(data.detail) or content
        return nil, T(_("Erro %1: %2"), code, detail)
    end
    return data
end

--- Requisição com corpo e resposta JSON.
function Client:request(method, path, body, timeouts)
    local base = self:baseUrl()
    if not base then
        return nil, _("Configure o endereço da ponte em Gemini → Configurar servidor.")
    end
    local payload = body and json.encode(body)
    local headers = self:headers()
    if payload then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    local sink = {}
    local code, err = perform({
        url = base .. path,
        method = method,
        headers = headers,
        source = payload and ltn12.source.string(payload),
        sink = socketutil.table_sink(sink),
    }, timeouts or { 15, 60 })
    if not code then return nil, err end
    return decode(code, sink)
end

--- Envia um arquivo local como corpo cru de um POST; resposta JSON.
function Client:upload(path, file_path, timeouts)
    local base = self:baseUrl()
    if not base then
        return nil, _("Configure o endereço da ponte em Gemini → Configurar servidor.")
    end
    local size = lfs.attributes(file_path, "size")
    local fh = size and io.open(file_path, "rb")
    if not fh then
        return nil, T(_("Não foi possível ler %1"), file_path)
    end
    local headers = self:headers()
    headers["Content-Type"] = "application/octet-stream"
    headers["Content-Length"] = tostring(size)
    local sink = {}
    local code, err = perform({
        url = base .. path,
        method = "POST",
        headers = headers,
        source = ltn12.source.file(fh),
        sink = socketutil.table_sink(sink),
    }, timeouts or { 60, 900 })
    pcall(fh.close, fh)
    if not code then return nil, err end
    return decode(code, sink)
end

--- Baixa `path` da ponte para o arquivo `dest`.
function Client:download(path, dest)
    local base = self:baseUrl()
    if not base then
        return nil, _("Configure o endereço da ponte em Gemini → Configurar servidor.")
    end
    local fh = io.open(dest, "wb")
    if not fh then
        return nil, T(_("Não foi possível gravar em %1"), dest)
    end
    local code, err = perform({
        url = base .. path,
        method = "GET",
        headers = self:headers(),
        sink = ltn12.sink.file(fh),
    }, { 15, 120 })
    if code ~= 200 then
        pcall(fh.close, fh)
        os.remove(dest)
        return nil, err or T(_("Falha ao baixar o documento (erro %1)."), code)
    end
    return dest
end

return Client
