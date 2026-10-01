--[[--
Painel do Gemini na parte de baixo da tela, com o livro visível em cima.

O UIManager entrega toques só à janela do topo; o painel repassa ao leitor
os toques e teclas que não são dele, para que dê para virar páginas e
selecionar texto com o painel aberto.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Panel = InputContainer:extend{
    ui = nil,             -- ReaderUI que recebe os toques fora do painel
    height_ratio = 0.5,   -- fração da altura da tela ocupada pelo painel
    title = "",
    text = "",
    buttons = nil,        -- linhas no formato de ButtonTable
    on_menu = nil,
    on_close = nil,
    covers_fullscreen = false,
}

function Panel:init()
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
    self.dimen = Geom:new{
        x = 0,
        y = Screen:getHeight() - self.height,
        w = self.width,
        h = self.height,
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
end

function Panel:build()
    if self[1] then self[1]:free() end
    local separator = LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = self.width, h = Size.line.thick },
    }
    local titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self.title,
        title_shrink_font_to_fit = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() if self.on_menu then self.on_menu() end end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = self.buttons or {},
        zero_sep = true,
        show_parent = self,
    }
    local text_padding = Size.padding.large
    local text_height = self.height - separator:getSize().h - titlebar:getHeight()
        - button_table:getSize().h - 2 * text_padding
    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            separator,
            titlebar,
            FrameContainer:new{
                padding = text_padding,
                margin = 0,
                bordersize = 0,
                ScrollTextWidget:new{
                    text = self.text,
                    face = Font:getFace("x_smallinfofont"),
                    width = self.width - 2 * text_padding,
                    height = text_height,
                    dialog = self,
                    justified = false,
                },
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
                button_table,
            },
        },
    }
end

--- Atualiza título, texto e/ou botões e redesenha só a área do painel.
function Panel:update(fields)
    for key, value in pairs(fields) do
        self[key] = value
    end
    self:build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Panel:handleEvent(event)
    if event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and ges.pos and not self.dimen:contains(ges.pos) then
            return self.ui:handleEvent(event)
        end
    end
    local handled = InputContainer.handleEvent(self, event)
    if not handled and (event.handler == "onKeyPress" or event.handler == "onKeyRepeat") then
        return self.ui:handleEvent(event)
    end
    return handled
end

function Panel:onClose()
    if self.on_close then self.on_close() end
    return true
end

return Panel
