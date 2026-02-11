addon.name    = 'AreYouSure'
addon.author  = 'Hanayaka'
addon.version = '1.0'
addon.desc    = 'Safety prompts before dropping or selling valuable items.'
addon.link    = 'https://ashitaxi.com/'

require('common')
local chat          = require('chat')
local imgui         = require('imgui')
local settings      = require('settings')
local vendor_prices = require('vendor_prices')

-- Default settings
local default_settings = T{
    enabled         = true,
    min_level       = 50,
    sell_whitelist  = T{},
    drop_whitelist  = T{},
    min_vendor_price = 10000, -- flag items whose total vendor value >= this
    protected_items  = T{},  -- manually protected item IDs (always treated as valuable)
}

local ays = T{
    settings = settings.load(default_settings),
}

-- Pending confirmation state
local pending = T{
    active      = false,
    action      = nil,   -- 'drop' or 'sell'
    item_id     = 0,
    item_name   = '',
    quantity    = 0,
    packet_id   = 0,
    packet_data = nil,
    selected    = 1,     -- 0 = Yes (danger), 1 = No (safe); defaults to safe
}

-- Tracks the most recent sell request (0x084) for context when 0x085 arrives
local last_sell = T{
    item_id   = 0,
    item_name = '',
    quantity  = 0,
}

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function get_vendor_price(item_id)
    return vendor_prices[item_id] or 0
end

local function is_valuable(item_id, quantity)
    -- Manually protected items always count as valuable
    if ays.settings.protected_items[tostring(item_id)] then
        return true
    end

    local res = AshitaCore:GetResourceManager():GetItemById(item_id)
    if res == nil then return false end

    -- Rare (0x8000) or Ex (0x4000)
    if bit.band(res.Flags, 0x8000) ~= 0 or bit.band(res.Flags, 0x4000) ~= 0 then
        return true
    end

    -- Equippable high-level gear
    if res.Slots ~= 0 and res.Level >= ays.settings.min_level then
        return true
    end

    -- High vendor value (unit price * quantity)
    local total_value = get_vendor_price(item_id) * (quantity or 1)
    if total_value >= ays.settings.min_vendor_price then
        return true
    end

    return false
end

local function is_whitelisted(action, item_id)
    local wl = action == 'drop' and ays.settings.drop_whitelist or ays.settings.sell_whitelist
    local key = tostring(item_id)
    return wl[key] == true
end

local function whitelist_add(action, item_id)
    local wl = action == 'drop' and ays.settings.drop_whitelist or ays.settings.sell_whitelist
    wl[tostring(item_id)] = true
    settings.save()
end

local function set_pending(action, item_id, item_name, quantity, packet_id, packet_data)
    pending.active      = true
    pending.action      = action
    pending.item_id     = item_id
    pending.item_name   = item_name
    pending.quantity    = quantity
    pending.packet_id   = packet_id
    pending.packet_data = packet_data
    pending.selected    = 1  -- default to No (safe)
end

local function clear_pending()
    pending.active      = false
    pending.action      = nil
    pending.item_id     = 0
    pending.item_name   = ''
    pending.quantity    = 0
    pending.packet_id   = 0
    pending.packet_data = nil
    pending.selected    = 1
end

----------------------------------------------------------------------------------------------------
-- Packet handler
----------------------------------------------------------------------------------------------------

ashita.events.register('packet_out', 'areyousure_packet_out', function(e)
    if e.blocked then return end
    if not ays.settings.enabled then return end
    if e.injected then return end

    -- Drop item (0x028)
    if e.id == 0x028 then
        local quantity  = struct.unpack('L', e.data_modified, 0x04 + 1)
        local container = struct.unpack('B', e.data_modified, 0x08 + 1)
        local slot      = struct.unpack('B', e.data_modified, 0x09 + 1)

        local inv  = AshitaCore:GetMemoryManager():GetInventory()
        local item = inv:GetContainerItem(container, slot)
        if item == nil or item.Id == 0 then return end

        local item_id = item.Id
        if not is_valuable(item_id, quantity) then return end
        if is_whitelisted('drop', item_id) then return end

        local res = AshitaCore:GetResourceManager():GetItemById(item_id)
        local name = res ~= nil and res.Name[1] or ('Item #' .. tostring(item_id))

        if pending.active then return end

        e.blocked = true
        set_pending('drop', item_id, name, quantity, e.id, e.data_modified:totable())
        return
    end

    -- Sell request (0x084) — let it through but record info
    if e.id == 0x084 then
        local quantity = struct.unpack('L', e.data_modified, 0x04 + 1)
        local item_id  = struct.unpack('H', e.data_modified, 0x08 + 1)

        last_sell.item_id  = item_id
        last_sell.quantity = quantity

        local res = AshitaCore:GetResourceManager():GetItemById(item_id)
        last_sell.item_name = res ~= nil and res.Name[1] or ('Item #' .. tostring(item_id))
        return
    end

    -- Sell confirm (0x085)
    if e.id == 0x085 then
        local sell_flag = struct.unpack('H', e.data_modified, 0x04 + 1)
        if sell_flag ~= 1 then return end

        local item_id = last_sell.item_id
        if item_id == 0 then return end
        if not is_valuable(item_id, last_sell.quantity) then return end
        if is_whitelisted('sell', item_id) then return end

        if pending.active then return end

        e.blocked = true
        set_pending('sell', item_id, last_sell.item_name, last_sell.quantity, e.id, e.data_modified:totable())
        return
    end
end)

----------------------------------------------------------------------------------------------------
-- ImGui confirmation dialog
----------------------------------------------------------------------------------------------------

-- Button colors
local COLOR_DANGER     = { 0.80, 0.15, 0.15, 1.0 }  -- red
local COLOR_DANGER_HOV = { 0.95, 0.25, 0.25, 1.0 }
local COLOR_DANGER_ACT = { 0.65, 0.10, 0.10, 1.0 }
local COLOR_SAFE       = { 0.15, 0.65, 0.15, 1.0 }  -- green
local COLOR_SAFE_HOV   = { 0.20, 0.80, 0.20, 1.0 }
local COLOR_SAFE_ACT   = { 0.10, 0.50, 0.10, 1.0 }
local COLOR_FOCUS_BRD  = { 1.0, 1.0, 1.0, 1.0 }     -- white border for focused button

ashita.events.register('d3d_present', 'areyousure_present', function()
    if not pending.active then return end

    -- Keyboard navigation
    if imgui.IsKeyPressed(513) then      -- Left arrow
        pending.selected = 0
    elseif imgui.IsKeyPressed(514) then  -- Right arrow
        pending.selected = 1
    elseif imgui.IsKeyPressed(525) then  -- Enter
        if pending.selected == 0 then
            whitelist_add(pending.action, pending.item_id)
            AshitaCore:GetPacketManager():AddOutgoingPacket(pending.packet_id, pending.packet_data)
            print(chat.header(addon.name):append(chat.message('Allowed and whitelisted: ')):append(chat.success(pending.item_name)))
            clear_pending()
            return
        else
            print(chat.header(addon.name):append(chat.message('Blocked: ')):append(chat.warning(pending.item_name)))
            clear_pending()
            return
        end
    elseif imgui.IsKeyPressed(526) then  -- Escape
        print(chat.header(addon.name):append(chat.message('Blocked: ')):append(chat.warning(pending.item_name)))
        clear_pending()
        return
    end

    local title = pending.action == 'drop' and 'Confirm Drop' or 'Confirm Sale'
    local action_verb = pending.action == 'drop' and 'DROP' or 'SELL'

    -- Center the popup window
    local io = imgui.GetIO()
    imgui.SetNextWindowPos({ io.DisplaySize.x * 0.5, io.DisplaySize.y * 0.5 }, ImGuiCond_Always, { 0.5, 0.5 })
    imgui.SetNextWindowSize({ 460, -1 }, ImGuiCond_Always)

    if imgui.Begin(('%s###AreYouSureConfirm'):fmt(title), nil, bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoSavedSettings)) then
        -- Warning header
        imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, ('Are you sure you want to %s this item?'):fmt(action_verb))
        imgui.Separator()
        imgui.Spacing()

        imgui.Text(('Action: %s'):fmt(action_verb))
        imgui.Text(('Item:   %s'):fmt(pending.item_name))
        if pending.quantity > 1 then
            imgui.Text(('Qty:    %d'):fmt(pending.quantity))
        end
        local unit_price = get_vendor_price(pending.item_id)
        if unit_price > 0 then
            local total = unit_price * pending.quantity
            imgui.TextColored({ 1.0, 0.4, 0.4, 1.0 }, ('Vendors for: %s gil'):fmt(tostring(total)))
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.TextColored({ 1.0, 0.8, 0.0, 1.0 }, ('Yes = %s + whitelist for future'):fmt(action_verb:lower()))
        imgui.PushTextWrapPos(0)
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Navigate: Left/Right arrows, Enter to confirm, Esc to cancel')
        imgui.PopTextWrapPos()

        imgui.Spacing()

        -- Yes button (DANGER — red)
        local btn_w = 150
        local spacing = 16
        local total_w = btn_w * 2 + spacing
        local avail = imgui.GetContentRegionAvail()
        local start_x = (avail - total_w) * 0.5
        if start_x > 0 then imgui.SetCursorPosX(imgui.GetCursorPosX() + start_x) end

        -- Draw focused border for selected button
        if pending.selected == 0 then
            imgui.PushStyleColor(ImGuiCol_Border, COLOR_FOCUS_BRD)
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2.0)
        end
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_DANGER)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_DANGER_HOV)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_DANGER_ACT)
        local yes_clicked = imgui.Button(('Yes, %s'):fmt(action_verb), { btn_w, 30 })
        imgui.PopStyleColor(3)
        if pending.selected == 0 then
            imgui.PopStyleVar(1)
            imgui.PopStyleColor(1)
        end

        imgui.SameLine(0, spacing)

        -- No button (SAFE — green)
        if pending.selected == 1 then
            imgui.PushStyleColor(ImGuiCol_Border, COLOR_FOCUS_BRD)
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2.0)
        end
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_SAFE)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_SAFE_HOV)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_SAFE_ACT)
        local no_clicked = imgui.Button('No, Keep It', { btn_w, 30 })
        imgui.PopStyleColor(3)
        if pending.selected == 1 then
            imgui.PopStyleVar(1)
            imgui.PopStyleColor(1)
        end

        imgui.Spacing()

        -- Handle mouse clicks
        if yes_clicked then
            whitelist_add(pending.action, pending.item_id)
            AshitaCore:GetPacketManager():AddOutgoingPacket(pending.packet_id, pending.packet_data)
            print(chat.header(addon.name):append(chat.message('Allowed and whitelisted: ')):append(chat.success(pending.item_name)))
            clear_pending()
        elseif no_clicked then
            print(chat.header(addon.name):append(chat.message('Blocked: ')):append(chat.warning(pending.item_name)))
            clear_pending()
        end
    end
    imgui.End()
end)

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

ashita.events.register('command', 'areyousure_command', function(e)
    local args = e.command:args()
    if #args == 0 then return end

    local cmd = args[1]:lower()
    if cmd ~= '/areyousure' and cmd ~= '/ays' then return end

    e.blocked = true

    -- Toggle
    if #args == 1 then
        ays.settings.enabled = not ays.settings.enabled
        settings.save()
        print(chat.header(addon.name):append(chat.message('Enabled: ')):append(chat.success(tostring(ays.settings.enabled))))
        return
    end

    local sub = args[2]:lower()

    -- Reset whitelists
    if sub == 'reset' then
        local target = #args >= 3 and args[3]:lower() or 'all'
        if target == 'sell' or target == 'all' then
            ays.settings.sell_whitelist = T{}
            print(chat.header(addon.name):append(chat.message('Sell whitelist cleared.')))
        end
        if target == 'drop' or target == 'all' then
            ays.settings.drop_whitelist = T{}
            print(chat.header(addon.name):append(chat.message('Drop whitelist cleared.')))
        end
        settings.save()
        return
    end

    -- Add protected item
    if sub == 'add' then
        if #args < 3 then
            print(chat.header(addon.name):append(chat.warning('Usage: /ays add <item_id>')))
            return
        end
        local id = tonumber(args[3])
        if id == nil then
            print(chat.header(addon.name):append(chat.warning('Item ID must be a number.')))
            return
        end
        local res = AshitaCore:GetResourceManager():GetItemById(id)
        if res == nil then
            print(chat.header(addon.name):append(chat.warning('Unknown item ID: ' .. tostring(id))))
            return
        end
        ays.settings.protected_items[tostring(id)] = true
        settings.save()
        print(chat.header(addon.name):append(chat.message('Protected: ')):append(chat.success(res.Name[1])))
        return
    end

    -- Remove protected item
    if sub == 'remove' then
        if #args < 3 then
            print(chat.header(addon.name):append(chat.warning('Usage: /ays remove <item_id>')))
            return
        end
        local id = tonumber(args[3])
        if id == nil then
            print(chat.header(addon.name):append(chat.warning('Item ID must be a number.')))
            return
        end
        local key = tostring(id)
        if not ays.settings.protected_items[key] then
            print(chat.header(addon.name):append(chat.warning('Item not in protected list.')))
            return
        end
        ays.settings.protected_items[key] = nil
        settings.save()
        local res = AshitaCore:GetResourceManager():GetItemById(id)
        local name = res ~= nil and res.Name[1] or tostring(id)
        print(chat.header(addon.name):append(chat.message('Unprotected: ')):append(chat.success(name)))
        return
    end

    -- List protected items
    if sub == 'list' then
        local count = 0
        for k, _ in pairs(ays.settings.protected_items) do
            local id = tonumber(k)
            local res = id and AshitaCore:GetResourceManager():GetItemById(id) or nil
            local name = res ~= nil and res.Name[1] or k
            print(chat.header(addon.name):append(chat.message(('  [%s] %s'):fmt(k, name))))
            count = count + 1
        end
        if count == 0 then
            print(chat.header(addon.name):append(chat.message('No manually protected items.')))
        end
        return
    end

    -- Min level
    if sub == 'level' then
        if #args >= 3 then
            local lvl = tonumber(args[3])
            if lvl then
                ays.settings.min_level = lvl
                settings.save()
                print(chat.header(addon.name):append(chat.message('Min level set to: ')):append(chat.success(tostring(lvl))))
            end
        else
            print(chat.header(addon.name):append(chat.message('Min level: ')):append(chat.success(tostring(ays.settings.min_level))))
        end
        return
    end

    -- Min vendor price
    if sub == 'price' then
        if #args >= 3 then
            local val = tonumber(args[3])
            if val then
                ays.settings.min_vendor_price = val
                settings.save()
                print(chat.header(addon.name):append(chat.message('Min vendor price set to: ')):append(chat.success(tostring(val))))
            end
        else
            print(chat.header(addon.name):append(chat.message('Min vendor price: ')):append(chat.success(tostring(ays.settings.min_vendor_price))))
        end
        return
    end

    -- Help
    print(chat.header(addon.name):append(chat.message('Commands:')))
    print(chat.header(addon.name):append(chat.message('  /ays             - Toggle enabled')))
    print(chat.header(addon.name):append(chat.message('  /ays reset [sell|drop|all] - Clear whitelist(s)')))
    print(chat.header(addon.name):append(chat.message('  /ays level [n]   - Get/set min equip level threshold')))
    print(chat.header(addon.name):append(chat.message('  /ays price [n]   - Get/set min vendor price threshold')))
    print(chat.header(addon.name):append(chat.message('  /ays add <id>    - Protect an item by ID')))
    print(chat.header(addon.name):append(chat.message('  /ays remove <id> - Unprotect an item')))
    print(chat.header(addon.name):append(chat.message('  /ays list        - Show protected items')))
end)

----------------------------------------------------------------------------------------------------
-- Settings reload on character switch
----------------------------------------------------------------------------------------------------

settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        ays.settings = s
    end
    settings.save()
end)
