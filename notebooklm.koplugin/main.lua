--[[--
Gemini para KOReader.

Conversa com a ponte HTTP (bridge/server.py) que roda num computador da mesma
rede e fala com o Google Gemini. No leitor, abre um painel na metade de
baixo da tela (tela dividida) ligado a um caderno do livro aberto:
  * cria um caderno com o próprio livro como fonte, ou usa um existente;
  * responde perguntas sobre trechos selecionados ou sobre o livro;
  * envia destaques e notas; gera guias de estudo e briefings.

@module koplugin.notebooklm
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local Screen = Device.screen

-- Módulos do próprio plugin: só podem ser carregados agora, durante o
-- carregamento do plugin, quando a pasta dele está no package.path.
local Client = require("notebooklm_client")
local Panel = require("notebooklm_panel")
local str = Client.str

-- Configuração gerada por bridge/install_plugin.py (opcional).
local has_config, InstallConfig = pcall(require, "notebooklm_config")
if not has_config or type(InstallConfig) ~= "table" then InstallConfig = {} end

local DEFAULT_GESTURE = "hold_bottom_right_corner"
local GESTURE_HINTS = {
    hold_bottom_right_corner = _("segure o canto inferior direito da tela"),
    two_finger_tap_bottom_right_corner = _("toque com dois dedos no canto inferior direito"),
    double_tap_bottom_right_corner = _("toque duas vezes no canto inferior direito"),
}

local POLL_INTERVAL = 20  -- segundos entre verificações de documento gerado
local POLL_MAX = 45       -- ~15 minutos
local BOOK_POLL_INTERVAL = 10
local BOOK_POLL_MAX = 60  -- ~10 minutos

-- Corta o texto sem quebrar um caractere UTF-8 no meio.
local function shorten(text, max)
    if #text <= max then return text end
    local cut = max
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end

local function urlEncode(text)
    return (tostring(text):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local Gemini = WidgetContainer:extend{
    name = "notebooklm",
    is_doc_only = false,
}

function Gemini:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/notebooklm.lua")
    self.client = Client.new(self.settings)
    self.history = {}
    self:applyInstallConfig()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("notebooklm", function(highlight)
            return {
                text = _("Gemini"),
                callback = function()
                    local text = highlight.selected_text and highlight.selected_text.text
                    if text and util.cleanupSelectedText then
                        text = util.cleanupSelectedText(text)
                    end
                    highlight:onClose()
                    if text and text ~= "" then
                        self:passageDialog(text)
                    end
                end,
            }
        end)
    end
end

-- Cada instalação nova (generated_at diferente) atualiza endereço e token,
-- por exemplo quando o IP do computador da ponte mudou.
function Gemini:applyInstallConfig()
    local cfg = InstallConfig
    if not cfg.generated_at or self.settings:readSetting("config_applied") == cfg.generated_at then
        return
    end
    for __, key in ipairs({ "server_url", "token", "panel_ratio" }) do
        if cfg[key] ~= nil then
            self.settings:saveSetting(key, cfg[key])
        end
    end
    self.settings:saveSetting("config_applied", cfg.generated_at)
    self.settings:flush()
end

-- Na primeira vez que um livro abre, liga um gesto ao painel no plugin de
-- gestos do KOReader, sem tocar num gesto que o usuário já tenha usado.
-- Roda em ReaderReady porque o plugin de gestos pode iniciar depois deste.
function Gemini:onReaderReady()
    if self.settings:has("gesture_installed") then return end
    local gesture = InstallConfig.gesture
    if gesture == nil then gesture = DEFAULT_GESTURE end
    if not gesture then
        self:save("gesture_installed", false)
        return
    end
    local gestures = self.ui.gestures
    local reader = gestures and gestures.data and gestures.data.gesture_reader
    if not reader then return end -- plugin de gestos desligado: tenta de novo depois

    local message
    if reader[gesture] == nil or next(reader[gesture]) == nil then
        reader[gesture] = { notebooklm_panel = true }
        gestures.updated = true
        gestures:onFlushSettings()
        self:save("gesture_installed", gesture)
        message = T(_("Gemini instalado!\n\nPara abrir ou fechar o painel, %1."),
            GESTURE_HINTS[gesture] or _("use o gesto configurado"))
    else
        self:save("gesture_installed", false)
        message = _("Gemini instalado!\n\nO gesto padrão já estava em uso, então não mudei nada. Abra o painel pelo menu Ferramentas → Gemini, ou escolha um gesto em Configurações → Gestos (ação \"Painel do Gemini\").")
    end
    UIManager:show(InfoMessage:new{ text = message, timeout = 8 })
end

function Gemini:onDispatcherRegisterActions()
    Dispatcher:registerAction("notebooklm_panel", {
        category = "none",
        event = "ToggleGeminiPanel",
        title = _("Painel do Gemini"),
        reader = true,
    })
end

function Gemini:addToMainMenu(menu_items)
    local items
    if self.ui.document then
        items = {
            {
                text = _("Painel do Gemini (tela dividida)"),
                checked_func = function() return self.panel ~= nil end,
                callback = function() self:onToggleGeminiPanel() end,
            },
            {
                text = _("Enviar destaques deste livro"),
                callback = function() self:sendHighlights() end,
                separator = true,
            },
        }
    else
        items = {
            {
                text = _("Perguntar ao caderno…"),
                callback = function() self:askDialog() end,
                separator = true,
            },
        }
    end
    table.insert(items, {
        text = _("Gerar guia de estudo"),
        callback = function() self:generateReport("study_guide") end,
    })
    table.insert(items, {
        text = _("Gerar briefing"),
        callback = function() self:generateReport("briefing") end,
    })
    table.insert(items, {
        text = _("Baixar documentos gerados"),
        callback = function() self:listReports() end,
        separator = true,
    })
    table.insert(items, {
        text_func = function()
            local nb = self:currentNotebook()
            local label = self.ui.document and _("Caderno deste livro: %1") or _("Caderno padrão: %1")
            return T(label, nb and nb.title or _("nenhum"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:chooseNotebook(function(nb)
                touchmenu_instance:updateItems()
                self:offerUpload(nb)
            end)
        end,
    })
    table.insert(items, {
        text = _("Configurar servidor"),
        keep_menu_open = true,
        callback = function() self:configureServer() end,
    })
    table.insert(items, {
        text = _("Testar conexão"),
        keep_menu_open = true,
        callback = function() self:testConnection() end,
    })
    menu_items.notebooklm = {
        text = _("Gemini"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

-- ------------------------------------------------------------------------- --
-- Infraestrutura

function Gemini:save(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Gemini:showError(err)
    UIManager:show(InfoMessage:new{ text = err or _("Erro desconhecido.") })
end

function Gemini:online(fn)
    NetworkMgr:runWhenOnline(fn)
end

-- Mostra uma mensagem enquanto `fn` bloqueia esperando a rede.
function Gemini:busy(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local result, err = fn()
    UIManager:close(msg)
    return result, err
end

function Gemini:bookInfo()
    local doc = self.ui.document
    if not doc then return nil end
    local props = self.ui.doc_props or doc:getProps() or {}
    local title = props.display_title or props.title
    if not title or title == "" then
        local _dir, filename = util.splitFilePathName(doc.file)
        title = filename
    end
    local authors = props.authors and props.authors:gsub("\n", ", ")
    return title, authors
end

function Gemini:outputDir()
    local home = G_reader_settings:readSetting("home_dir")
        or require("apps/filemanager/filemanagerutil").getDefaultDir()
    return home .. "/Gemini"
end

function Gemini:openFile(path)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(path)
    else
        ReaderUI:showReader(path)
    end
end

-- ------------------------------------------------------------------------- --
-- Cadernos: no leitor, cada livro tem o seu (guardado nas configurações do
-- livro); fora dele, vale o caderno padrão.

function Gemini:currentNotebook()
    if self.ui.doc_settings then
        return self.ui.doc_settings:readSetting("notebooklm_notebook")
    end
    return self.settings:readSetting("notebook")
end

function Gemini:storeNotebook(nb)
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("notebooklm_notebook", nb)
    else
        self:save("notebook", nb)
    end
end

function Gemini:setCurrentNotebook(nb)
    local value = { id = nb.id, title = str(nb.title) or "", source_id = str(nb.source_id) }
    self:storeNotebook(value)
    self.history = {}
    self.conversation_id = nil
    self.book_status = nil
    self:refreshPanel()
    return value
end

-- Executa `fn(notebook)`; sem caderno, abre a escolha (ou o painel de
-- configuração, se houver um livro aberto).
function Gemini:withNotebook(fn)
    local nb = self:currentNotebook()
    if nb then return fn(nb) end
    if self.ui.document then
        self:openPanel()
        UIManager:show(InfoMessage:new{
            text = _("Primeiro ligue este livro a um caderno do Gemini."),
            timeout = 3,
        })
    else
        self:chooseNotebook(fn)
    end
end

function Gemini:chooseNotebook(on_chosen)
    self:online(function()
        local list, err = self:busy(_("Buscando cadernos…"), function()
            return self.client:request("GET", "/notebooks")
        end)
        if not list then return self:showError(err) end
        local dialog
        local buttons = {}
        if self.ui.document then
            table.insert(buttons, {{
                text = _("+ Criar caderno com este livro"),
                callback = function()
                    UIManager:close(dialog)
                    self:createWithBook()
                end,
            }})
        end
        for __, nb in ipairs(list) do
            local title = str(nb.title)
            table.insert(buttons, {{
                text = (title and title ~= "") and title or _("(sem título)"),
                callback = function()
                    UIManager:close(dialog)
                    local chosen = self:setCurrentNotebook(nb)
                    if on_chosen then on_chosen(chosen) end
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Cancelar"),
            callback = function() UIManager:close(dialog) end,
        }})
        dialog = ButtonDialog:new{
            title = _("Escolha o caderno do Gemini"),
            buttons = buttons,
        }
        UIManager:show(dialog)
    end)
end

-- ------------------------------------------------------------------------- --
-- Livro aberto como fonte do caderno

function Gemini:createWithBook()
    local title = self:bookInfo()
    self:online(function()
        local nb, err = self:busy(_("Criando caderno…"), function()
            return self.client:request("POST", "/notebooks", { title = title })
        end)
        if not nb then return self:showError(err) end
        self:uploadBook(self:setCurrentNotebook(nb))
    end)
end

-- Ao escolher um caderno existente, oferece incluir o livro como fonte.
function Gemini:offerUpload(nb)
    if not self.ui.document or not nb or nb.source_id then return end
    UIManager:show(ConfirmBox:new{
        text = T(_("Adicionar o arquivo deste livro como fonte do caderno «%1»?\n\nAssim o Gemini responde com base no texto do livro."), nb.title),
        ok_text = _("Adicionar"),
        cancel_text = _("Agora não"),
        ok_callback = function() self:uploadBook(nb) end,
    })
end

function Gemini:setBookStatus(text, transient)
    self.book_status = text
    self.book_status_transient = transient
    self:refreshPanel()
end

function Gemini:uploadBook(nb)
    local file = self.ui.document.file
    local _dir, filename = util.splitFilePathName(file)
    local title = self:bookInfo()
    local key = self.ui.doc_settings:readSetting("partial_md5_checksum")
        or (util.partialMD5 and util.partialMD5(file)) or filename
    local path = "/notebooks/" .. nb.id .. "/book"
        .. "?filename=" .. urlEncode(filename)
        .. "&title=" .. urlEncode(title)
        .. "&book_key=" .. urlEncode(key)
    self:openPanel()
    self:online(function()
        self:setBookStatus(_("Enviando o livro ao Gemini… isso pode levar alguns minutos."))
        UIManager:forceRePaint()
        local data, err = self.client:upload(path, file)
        if not data then
            self:setBookStatus(nil)
            return self:showError(err)
        end
        nb.source_id = str(data.source_id)
        self:storeNotebook(nb)
        if data.ready == true then
            self:setBookStatus(_("Livro pronto no Gemini. Já pode perguntar sobre ele."), true)
        else
            self:setBookStatus(_("O Gemini está processando o livro… você já pode perguntar, mas as respostas só vão considerá-lo quando terminar."))
            self:pollBook(nb, nb.source_id, 1)
        end
    end)
end

function Gemini:pollBook(nb, source_id, attempt)
    UIManager:scheduleIn(BOOK_POLL_INTERVAL, function()
        if not self.ui.document then return end -- livro fechado
        local data = self.client:request("GET", "/notebooks/" .. nb.id .. "/sources/" .. source_id, nil, { 10, 20 })
        if data and data.ready == true then
            self:setBookStatus(_("Livro pronto no Gemini. Já pode perguntar sobre ele."), true)
        elseif data and data.error == true then
            self:setBookStatus(_("O Gemini não conseguiu processar o arquivo do livro."), true)
        elseif attempt < BOOK_POLL_MAX then
            self:pollBook(nb, source_id, attempt + 1)
        else
            self:setBookStatus(nil)
        end
    end)
end

-- ------------------------------------------------------------------------- --
-- Painel (tela dividida)

function Gemini:onToggleGeminiPanel()
    if self.panel then
        self:closePanel()
    else
        self:openPanel()
    end
    return true
end

function Gemini:panelText()
    local parts = {}
    if self.book_status then
        table.insert(parts, "[" .. self.book_status .. "]")
    end
    local last = self.history[#self.history]
    if last then
        if last.passage then
            table.insert(parts, "«" .. shorten(last.passage, 300) .. "»")
        end
        table.insert(parts, "P: " .. last.question)
        table.insert(parts, last.answer or _("Consultando o Gemini…"))
    else
        table.insert(parts, T(_("Pergunte qualquer coisa sobre «%1».\n\nDicas:\n• Selecione um trecho do livro e toque em «Gemini».\n• Toques fora deste painel continuam virando as páginas.\n• Toque no texto deste painel para rolar."), self:bookInfo() or ""))
    end
    return table.concat(parts, "\n\n")
end

function Gemini:panelContent()
    local nb = self:currentNotebook()
    if not nb then
        return {
            title = _("Gemini"),
            text = _("Este livro ainda não está ligado a um caderno do Gemini.\n\n• Criar caderno com este livro: cria um caderno novo e envia o arquivo do livro como fonte.\n• Escolher caderno existente: usa um caderno que você já tem (e, se quiser, adiciona o livro a ele)."),
            buttons = {
                {{
                    text = _("Criar caderno com este livro"),
                    callback = function() self:createWithBook() end,
                }},
                {{
                    text = _("Escolher caderno existente"),
                    callback = function()
                        self:chooseNotebook(function(chosen) self:offerUpload(chosen) end)
                    end,
                }},
            },
        }
    end
    return {
        title = nb.title ~= "" and nb.title or _("Gemini"),
        text = self:panelText(),
        buttons = {
            {
                { text = _("Perguntar"), callback = function() self:askDialog() end },
                { text = _("Resumir capítulo"), callback = function() self:summarizeChapter() end },
            },
            {
                { text = _("Enviar destaques"), callback = function() self:sendHighlights() end },
                { text = _("Mais…"), callback = function() self:showPanelMenu() end },
            },
        },
    }
end

function Gemini:openPanel()
    if self.panel or not self.ui.document then return end
    local content = self:panelContent()
    self.panel = Panel:new{
        ui = self.ui,
        height_ratio = self.settings:readSetting("panel_ratio") or 0.5,
        title = content.title,
        text = content.text,
        buttons = content.buttons,
        on_menu = function() self:showPanelMenu() end,
        on_close = function() self:closePanel() end,
    }
    self:reflowBook(self.panel.height)
    UIManager:show(self.panel, "ui", self.panel.dimen, self.panel.dimen.x, self.panel.dimen.y)
end

function Gemini:closePanel()
    if not self.panel then return end
    local panel = self.panel
    self.panel = nil
    UIManager:close(panel, "ui", panel.dimen)
    self:restoreBook()
end

function Gemini:refreshPanel()
    if self.panel then
        self.panel:update(self:panelContent())
    end
end

-- Em livros refluíveis (EPUB etc.), aumenta temporariamente a margem de
-- baixo para o texto caber inteiro acima do painel. Não é salvo no livro:
-- as margens configuradas pelo usuário continuam em typeset.unscaled_margins.
function Gemini:reflowBook(panel_height)
    local typeset = self.ui.typeset
    if not (self.ui.rolling and typeset and typeset.unscaled_margins) then return end
    if not self.settings:nilOrTrue("reflow_book") then return end
    local m = typeset.unscaled_margins
    self.ui.document:setPageMargins(
        Screen:scaleBySize(m[1]),
        Screen:scaleBySize(m[2]),
        Screen:scaleBySize(m[3]),
        Screen:scaleBySize(m[4]) + panel_height)
    self.ui:handleEvent(Event:new("UpdatePos"))
    self.reflowed = true
end

function Gemini:restoreBook()
    if not self.reflowed then return end
    self.reflowed = false
    if self.ui.document then
        self.ui:handleEvent(Event:new("SetPageMargins", self.ui.typeset.unscaled_margins))
    end
end

function Gemini:resizePanel(ratio)
    self:save("panel_ratio", ratio)
    if self.panel then
        self:closePanel()
        self:openPanel()
    end
end

function Gemini:showPanelMenu()
    local nb = self:currentNotebook()
    local dialog
    local function action(text, fn)
        return { text = text, callback = function() UIManager:close(dialog); fn() end }
    end
    local reflow = self.settings:nilOrTrue("reflow_book")
    local buttons = {
        { action(_("Trocar caderno"), function()
            self:chooseNotebook(function(chosen) self:offerUpload(chosen) end)
        end) },
    }
    if nb and not nb.source_id then
        table.insert(buttons, { action(_("Adicionar este livro ao caderno"), function() self:uploadBook(nb) end) })
    end
    table.insert(buttons, {
        action(_("Ver conversa completa"), function() self:showHistory() end),
        action(_("Nova conversa"), function()
            self.history = {}
            self.conversation_id = nil
            self:refreshPanel()
        end),
    })
    table.insert(buttons, {
        action(_("Painel 40%"), function() self:resizePanel(0.4) end),
        action(_("50%"), function() self:resizePanel(0.5) end),
        action(_("60%"), function() self:resizePanel(0.6) end),
        action(_("70%"), function() self:resizePanel(0.7) end),
    })
    if self.ui.rolling then
        table.insert(buttons, { action(
            reflow and _("Não reorganizar o texto do livro") or _("Reorganizar o texto do livro acima do painel"),
            function()
                self:save("reflow_book", not reflow)
                if self.panel then
                    self:closePanel()
                    self:openPanel()
                end
            end) })
    end
    table.insert(buttons, { action(_("Fechar painel"), function() self:closePanel() end) })
    dialog = ButtonDialog:new{
        title = nb and nb.title or _("Gemini"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Gemini:showHistory()
    local parts = {}
    for __, entry in ipairs(self.history) do
        local block = "P: " .. entry.question .. "\n\n" .. (entry.answer or "…")
        if entry.passage then
            block = "«" .. shorten(entry.passage, 300) .. "»\n\n" .. block
        end
        table.insert(parts, block)
    end
    UIManager:show(TextViewer:new{
        title = _("Conversa com o Gemini"),
        text = #parts > 0 and table.concat(parts, "\n\n―――――\n\n") or _("Nenhuma pergunta ainda."),
    })
end

function Gemini:onCloseDocument()
    if self.panel then
        UIManager:close(self.panel)
        self.panel = nil
    end
    self.reflowed = false
end

-- Girar a tela muda as dimensões: fecha o painel em vez de deixá-lo torto.
function Gemini:onSetDimensions()
    self:closePanel()
end

-- ------------------------------------------------------------------------- --
-- Perguntas

function Gemini:passageDialog(passage)
    local dialog
    dialog = ButtonDialog:new{
        title = "«" .. shorten(passage, 200) .. "»",
        buttons = {
            {{
                text = _("Explicar este trecho"),
                callback = function()
                    UIManager:close(dialog)
                    self:ask(_("Explique este trecho usando as fontes do caderno."), passage)
                end,
            }},
            {{
                text = _("Perguntar sobre o trecho…"),
                callback = function()
                    UIManager:close(dialog)
                    self:askDialog(passage)
                end,
            }},
            {{
                text = _("Cancelar"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Gemini:askDialog(passage)
    local dialog
    dialog = InputDialog:new{
        title = passage and _("Perguntar sobre o trecho") or _("Perguntar ao Gemini"),
        description = passage and ("«" .. shorten(passage, 300) .. "»"),
        input_hint = _("Sua pergunta"),
        buttons = {{
            {
                text = _("Cancelar"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Perguntar"),
                is_enter_default = true,
                callback = function()
                    local question = dialog:getInputText()
                    UIManager:close(dialog)
                    if question and question:match("%S") then
                        self:ask(question, passage)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Gemini:summarizeChapter()
    local title = self:bookInfo()
    local page = self.ui.paging and self.ui.paging.current_page or self.ui.document:getCurrentPage()
    local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(page)
    if chapter and chapter ~= "" then
        self:ask(T(_("Resuma o capítulo \"%1\" do livro \"%2\", destacando as ideias principais."), chapter, title))
    else
        self:ask(T(_("Resuma as ideias principais do livro \"%1\"."), title))
    end
end

function Gemini:ask(question, passage)
    self:withNotebook(function(nb)
        self:online(function()
            if self.ui.document then
                self:askInPanel(nb, question, passage)
            else
                self:askInDialog(nb, question)
            end
        end)
    end)
end

function Gemini:askPayload(nb, question, passage)
    return {
        notebook_id = nb.id,
        question = question,
        passage = passage,
        book_title = self:bookInfo(),
        conversation_id = self.conversation_id,
    }
end

function Gemini:askInPanel(nb, question, passage)
    self:openPanel()
    if self.book_status_transient then
        self.book_status = nil
        self.book_status_transient = nil
    end
    local entry = { question = question, passage = passage }
    table.insert(self.history, entry)
    self:refreshPanel()
    UIManager:forceRePaint()
    local data, err = self.client:request("POST", "/ask", self:askPayload(nb, question, passage), { 120, 300 })
    if data then
        entry.answer = str(data.answer) or ""
        self.conversation_id = str(data.conversation_id) or self.conversation_id
    else
        entry.answer = T(_("Erro: %1"), err)
    end
    self:refreshPanel()
end

-- Fora do leitor (gerenciador de arquivos) não há livro: resposta em janela.
function Gemini:askInDialog(nb, question)
    local data, err = self:busy(_("Consultando o Gemini…"), function()
        return self.client:request("POST", "/ask", self:askPayload(nb, question), { 120, 300 })
    end)
    if not data then return self:showError(err) end
    self.conversation_id = str(data.conversation_id) or self.conversation_id
    local viewer
    viewer = TextViewer:new{
        title = nb.title,
        text = "P: " .. question .. "\n\n" .. (str(data.answer) or ""),
        buttons_table = {{
            {
                text = _("Continuar conversa"),
                callback = function()
                    UIManager:close(viewer)
                    self:askDialog()
                end,
            },
            {
                text = _("Fechar"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- ------------------------------------------------------------------------- --
-- Destaques

function Gemini:collectHighlights()
    local items = {}
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    if annotations then
        -- KOReader 2024.07+: anotações já vêm em ordem de leitura.
        for __, a in ipairs(annotations) do
            if a.drawer and a.text and a.text ~= "" then
                table.insert(items, {
                    text = a.text,
                    note = a.note,
                    chapter = a.chapter,
                    page = a.pageref or a.pageno,
                    datetime = a.datetime,
                })
            end
        end
    elseif self.ui.bookmark and self.ui.bookmark.bookmarks then
        -- Versões antigas: lista de marcadores, da mais recente para a mais antiga.
        local bookmarks = self.ui.bookmark.bookmarks
        for i = #bookmarks, 1, -1 do
            local b = bookmarks[i]
            if b.highlighted and b.notes and b.notes ~= "" then
                table.insert(items, {
                    text = b.notes,
                    chapter = b.chapter,
                    page = type(b.page) == "number" and b.page or nil,
                    datetime = b.datetime,
                })
            end
        end
    end
    return items
end

function Gemini:sendHighlights()
    local highlights = self:collectHighlights()
    if #highlights == 0 then
        return UIManager:show(InfoMessage:new{ text = _("Este livro ainda não tem destaques.") })
    end
    local title, authors = self:bookInfo()
    self:withNotebook(function(nb)
        self:online(function()
            local data, err = self:busy(T(_("Enviando %1 destaques…"), #highlights), function()
                return self.client:request("POST", "/highlights", {
                    notebook_id = nb.id,
                    book_title = title,
                    authors = authors,
                    highlights = highlights,
                }, { 60, 180 })
            end)
            if not data then return self:showError(err) end
            UIManager:show(InfoMessage:new{
                text = T(_("%1 destaques enviados para «%2»."), data.count, nb.title),
                timeout = 4,
            })
        end)
    end)
end

-- ------------------------------------------------------------------------- --
-- Configuração

function Gemini:configureServer()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Ponte do Gemini"),
        fields = {
            {
                description = _("Endereço"),
                text = self.settings:readSetting("server_url") or "",
                hint = "http://192.168.0.10:8765",
            },
            {
                description = _("Token"),
                text = self.settings:readSetting("token") or "",
                hint = _("mostrado ao iniciar a ponte"),
            },
        },
        buttons = {{
            {
                text = _("Cancelar"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Salvar"),
                callback = function()
                    local fields = dialog:getFields()
                    self:save("server_url", util.trim(fields[1]))
                    self:save("token", util.trim(fields[2]))
                    UIManager:close(dialog)
                    self:testConnection()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Gemini:testConnection()
    self:online(function()
        local list, err = self:busy(_("Testando conexão…"), function()
            return self.client:request("GET", "/notebooks")
        end)
        if not list then return self:showError(err) end
        UIManager:show(InfoMessage:new{
            text = T(_("Conectado! %1 caderno(s) encontrados."), #list),
            timeout = 3,
        })
    end)
end

-- ------------------------------------------------------------------------- --
-- Documentos gerados

function Gemini:generateReport(kind)
    self:withNotebook(function(nb)
        self:online(function()
            local data, err = self:busy(_("Pedindo ao Gemini…"), function()
                return self.client:request("POST", "/reports", {
                    notebook_id = nb.id,
                    kind = kind,
                    notebook_title = nb.title,
                })
            end)
            if not data then return self:showError(err) end
            UIManager:show(InfoMessage:new{
                text = _("O Gemini está gerando o documento. Isso leva alguns minutos; você será avisado quando estiver pronto."),
                timeout = 5,
            })
            self:pollReport(data.job_id, 1)
        end)
    end)
end

function Gemini:pollReport(job_id, attempt)
    UIManager:scheduleIn(POLL_INTERVAL, function()
        local data = self.client:request("GET", "/reports/" .. job_id, nil, { 10, 20 })
        if data and data.status == "done" then
            self:downloadAndOffer(data.filename)
        elseif data and data.status == "error" then
            self:showError(T(_("Falha ao gerar o documento:\n%1"), tostring(data.error)))
        elseif attempt < POLL_MAX then
            self:pollReport(job_id, attempt + 1)
        else
            self:showError(_("O documento está demorando. Use \"Baixar documentos gerados\" mais tarde."))
        end
    end)
end

function Gemini:downloadAndOffer(filename)
    local dir = self:outputDir()
    util.makePath(dir)
    local path, err = self:busy(_("Baixando documento…"), function()
        return self.client:download("/files/" .. filename, dir .. "/" .. filename)
    end)
    if not path then return self:showError(err) end
    UIManager:show(ConfirmBox:new{
        text = T(_("Documento salvo em:\n%1\n\nAbrir agora?"), path),
        ok_text = _("Abrir"),
        ok_callback = function() self:openFile(path) end,
    })
end

function Gemini:listReports()
    self:online(function()
        local list, err = self:busy(_("Buscando documentos…"), function()
            return self.client:request("GET", "/reports")
        end)
        if not list then return self:showError(err) end
        if #list == 0 then
            return UIManager:show(InfoMessage:new{ text = _("Nenhum documento gerado ainda.") })
        end
        local dialog
        local buttons = {}
        for __, item in ipairs(list) do
            table.insert(buttons, {{
                text = item.filename,
                callback = function()
                    UIManager:close(dialog)
                    self:downloadAndOffer(item.filename)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Cancelar"),
            callback = function() UIManager:close(dialog) end,
        }})
        dialog = ButtonDialog:new{
            title = _("Documentos na ponte"),
            buttons = buttons,
        }
        UIManager:show(dialog)
    end)
end

return Gemini
