local ox_inventory = exports.ox_inventory

local activeHealCooldowns = {}  -- [targetSrc] = timestamp

-- Item Use Notes ─────────────────────────────────────────────────────────
-- Item use is handled entirely through ox_inventory's items.lua.
-- Both ESX and QBX use the same item config:
--   client = { event = 'nzkfc_drone:useItem' }
-- This fires the AddEventHandler('nzkfc_drone:useItem') on the client.
-- No server-side ESX.RegisterUsableItem needed when using ox_inventory.

-- Block drone items from being placed in any drone stash.
-- itemFilter targets the item by name, inventoryFilter matches stash IDs by pattern.
-- Returning false cancels the move.
ox_inventory:registerHook('swapItems', function(payload)
    -- Only block moves INTO a drone stash (toInventory matches), not out of it
    local toDest = payload.toInventory
    if type(toDest) == 'string' and toDest:sub(1, 11) == 'nzkfc_drone' then
        return false
    end
end, {
    itemFilter = {
        [Config.DroneItem] = true,
    },
})

-- Drone Storage

RegisterNetEvent('nzkfc_drone:openStorage', function(serial, slots, weight)
    local src     = source
    local stashId = 'nzkfc_drone_' .. serial

    ox_inventory:RegisterStash(stashId, 'Drone Storage [' .. serial .. ']', slots, weight)
    TriggerClientEvent('ox_inventory:openInventory', src, 'stash', stashId)
end)

-- Drone Health: Save to item metadata

RegisterNetEvent('nzkfc_drone:saveHealth', function(serial, health)
    local src   = source
    local items = ox_inventory:GetInventoryItems(src)
    if not items then return end

    for slot, item in pairs(items) do
        if item and item.name == Config.DroneItem then
            local meta = item.metadata or {}
            if meta.serial == serial then
                meta.health = math.max(0, math.floor(health))
                ox_inventory:SetMetadata(src, slot, meta)
                break
            end
        end
    end
end)

-- Drone Destroyed: Remove item from player

RegisterNetEvent('nzkfc_drone:destroyed', function(serial)
    local src   = source
    local items = ox_inventory:GetInventoryItems(src)
    if not items then return end

    for slot, item in pairs(items) do
        if item and item.name == Config.DroneItem then
            local meta = item.metadata or {}
            if meta.serial == serial then
                ox_inventory:RemoveItem(src, Config.DroneItem, 1, nil, slot)
                TriggerClientEvent('ox_lib:notify', src, {
                    type        = 'error',
                    title       = 'Drone',
                    description = 'Your drone has been destroyed!',
                })
                break
            end
        end
    end
end)

-- Healing

RegisterNetEvent('nzkfc_drone:healNearby', function(droneCoords)
    local src     = source
    local now     = GetGameTimer()
    local players = GetPlayers()

    -- Send a heal tick to every player in range regardless of their current health.
    -- The client decides whether to apply it or report back that they're full.
    -- This avoids the server health lag issue where GetEntityHealth lags behind
    -- client-side SetEntityHealth calls.
    for _, targetSrc in ipairs(players) do
        targetSrc = tonumber(targetSrc)
        local ped = GetPlayerPed(targetSrc)
        if ped and ped ~= 0 then
            local targetCoords = GetEntityCoords(ped)
            local dist = #(vector3(droneCoords.x, droneCoords.y, droneCoords.z) - targetCoords)

            if dist <= Config.HealRadius then
                TriggerClientEvent('nzkfc_drone:applyHeal', targetSrc, Config.HealAmount)
            end
        end
    end
end)

-- Client reports they are full — deactivate heal mode on that client
RegisterNetEvent('nzkfc_drone:healComplete', function()
    local src = source
    TriggerClientEvent('nzkfc_drone:healComplete', src)
end)

-- Generate Serial Number

RegisterNetEvent('nzkfc_drone:generateSerial', function(slot)
    local src    = source
    local serial = string.format('DRN-%06d', math.random(100000, 999999))

    slot = tonumber(slot)
    if not slot then
        print('[nzkfc_drone] generateSerial: invalid slot received')
        return
    end

    local item = ox_inventory:GetSlot(src, slot)

    if item and item.name == Config.DroneItem then
        local meta = item.metadata or {}
        if not meta.serial then
            meta.serial = serial
            meta.health = Config.DroneMaxHealth
            meta.label  = 'Drone [' .. serial .. ']'
            ox_inventory:SetMetadata(src, slot, meta)

            local stashId = 'nzkfc_drone_' .. serial
            ox_inventory:RegisterStash(stashId, 'Drone [' .. serial .. '] Storage', Config.StorageSlots, Config.StorageWeight)
            ox_inventory:AddItem(stashId, Config.BatteryItem, 1, {
                charge = 100,
                label  = 'Drone Battery (100%)',
            })

            TriggerClientEvent('nzkfc_drone:serialAssigned', src, meta)
        else
            local stashId = 'nzkfc_drone_' .. meta.serial
            ox_inventory:RegisterStash(stashId, 'Drone [' .. meta.serial .. '] Storage', Config.StorageSlots, Config.StorageWeight)
            TriggerClientEvent('nzkfc_drone:serialAssigned', src, meta)
        end
    else
        print(('[nzkfc_drone] generateSerial: slot %s did not contain %s (got %s)'):format(
            tostring(slot),
            Config.DroneItem,
            item and item.name or 'nil'
        ))
    end
end)

-- Battery: Get battery item from drone stash

RegisterNetEvent('nzkfc_drone:getBattery', function(serial)
    local src     = source
    local stashId = 'nzkfc_drone_' .. serial
    local items   = ox_inventory:GetInventoryItems(stashId)
    local battery = nil
    local battSlot = nil

    if items then
        for s, it in pairs(items) do
            if it and it.name == Config.BatteryItem then
                battery  = it
                battSlot = s
                break
            end
        end
    end

    if battery then
        local charge = (battery.metadata and battery.metadata.charge)

        if charge == nil then
            charge = 100
            ox_inventory:SetMetadata(stashId, battSlot, {
                charge = 100,
                label  = 'Drone Battery (100%)',
            })
        end

        TriggerClientEvent('nzkfc_drone:receiveBattery', src, charge, battSlot)
    else
        TriggerClientEvent('nzkfc_drone:receiveBattery', src, nil, nil)
    end
end)

-- Battery: Save charge to battery item in stash

RegisterNetEvent('nzkfc_drone:saveBatteryToStash', function(serial, charge, battSlot)
    local stashId  = 'nzkfc_drone_' .. serial
    if battSlot then
        local stored = math.max(0, math.floor(charge))
        ox_inventory:SetMetadata(stashId, battSlot, {
            charge = stored,
            label  = ('Drone Battery (%d%%)'):format(stored),
        })
    end
end)

-- Battery: Drain battery — swap drone_battery → drone_battery_empty
-- The empty item stays in the stash so the player can see/remove it.
-- ox_inventory has no direct "swap item" — remove charged, add empty.

RegisterNetEvent('nzkfc_drone:drainBattery', function(serial, battSlot)
    local stashId = 'nzkfc_drone_' .. serial
    if not battSlot then return end

    ox_inventory:RemoveItem(stashId, Config.BatteryItem, 1, nil, battSlot)

    ox_inventory:AddItem(stashId, Config.BatteryEmptyItem, 1)
end)

-- Wreck Cleanup: clear stash after WreckCleanupMinutes

RegisterNetEvent('nzkfc_drone:scheduleWreckCleanup', function(serial)
    local src     = source
    local stashId = 'nzkfc_drone_' .. serial
    local waitMs  = Config.WreckCleanupMinutes * 60 * 1000

    SetTimeout(waitMs, function()
        local items = ox_inventory:GetInventoryItems(stashId)
        if items then
            for slot, item in pairs(items) do
                if item then
                    ox_inventory:RemoveItem(stashId, item.name, item.count or 1, nil, slot)
                end
            end
        end
        print(('[nzkfc_drone] Wreck stash cleared: %s'):format(stashId))
    end)
end)


-- Drone Sound: Relay to other nearby players

RegisterNetEvent('nzkfc_drone:startSound', function(netId)
    local src = source
    for _, playerId in ipairs(GetPlayers()) do
        playerId = tonumber(playerId)
        if playerId ~= src then
            TriggerClientEvent('nzkfc_drone:playRemoteSound', playerId, netId)
        end
    end
end)

RegisterNetEvent('nzkfc_drone:stopSound', function(netId)
    local src = source
    for _, playerId in ipairs(GetPlayers()) do
        playerId = tonumber(playerId)
        if playerId ~= src then
            TriggerClientEvent('nzkfc_drone:stopRemoteSound', playerId, netId)
        end
    end
end)

-- Wreck: Broadcast to all other clients so they can loot the drone

RegisterNetEvent('nzkfc_drone:broadcastWreck', function(netId, serial)
    local src = source
    for _, playerId in ipairs(GetPlayers()) do
        playerId = tonumber(playerId)
        if playerId ~= src then
            TriggerClientEvent('nzkfc_drone:registerWreckTarget', playerId, netId, serial)
        end
    end
end)

-- Guest Storage: Non-owner opens a wrecked drone stash

RegisterNetEvent('nzkfc_drone:openStorageAsGuest', function(serial)
    local src     = source
    local stashId = 'nzkfc_drone_' .. serial
    ox_inventory:RegisterStash(stashId, 'Drone Storage [' .. serial .. ']', Config.StorageSlots, Config.StorageWeight)
    TriggerClientEvent('ox_inventory:openInventory', src, 'stash', stashId)
end)

-- Position Sync: Relay owner position to other clients for smooth lerp

RegisterNetEvent('nzkfc_drone:broadcastPos', function(netId, x, y, z, h)
    local src = source
    for _, playerId in ipairs(GetPlayers()) do
        playerId = tonumber(playerId)
        if playerId ~= src then
            TriggerClientEvent('nzkfc_drone:recvPos', playerId, netId, x, y, z, h)
        end
    end
end)
