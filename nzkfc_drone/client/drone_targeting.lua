DroneTargeting = {}

local currentEntity = nil  -- track the entity handle so we can remove targets later

_G.droneDoingTrick = false  -- global flag so main.lua can pause the movement thread

local function playDroneTrick(droneEntity)
    if _G.droneDoingTrick then return end
    _G.droneDoingTrick = true

    CreateThread(function()
        local startPos = GetEntityCoords(droneEntity)
        local startH   = GetEntityHeading(droneEntity)

        -- Phase 1: dip down 0.5m over 30 frames
        local dipSteps = 30
        for i = 1, dipSteps do
            local t  = i / dipSteps
            local z  = startPos.z - (0.5 * t)
            SetEntityCoords(droneEntity, startPos.x, startPos.y, z, false, false, false, false)
            SetEntityRotation(droneEntity, 0.0, 0.0, startH, 2, true)
            Wait(16)
        end

        local dipPos = vector3(startPos.x, startPos.y, startPos.z - 0.5)

        -- Phase 2: rise 1.0m AND do a full 360 pitch flip simultaneously over 60 frames
        local flipSteps = 60
        for i = 1, flipSteps do
            local t     = i / flipSteps
            local z     = dipPos.z + (1.0 * t)                -- rise from dip to +0.5 above start
            local pitch = (360.0 / flipSteps) * i             -- full 360 pitch rotation
            SetEntityCoords(droneEntity, startPos.x, startPos.y, z, false, false, false, false)
            SetEntityRotation(droneEntity, pitch, 0.0, startH, 2, true)
            Wait(6)
        end

        local topPos = vector3(startPos.x, startPos.y, startPos.z + 0.5)

        -- Phase 3: settle back down 0.5m to original height over 30 frames
        local settleSteps = 30
        for i = 1, settleSteps do
            local t = i / settleSteps
            local z = topPos.z - (0.5 * t)
            SetEntityCoords(droneEntity, startPos.x, startPos.y, z, false, false, false, false)
            SetEntityRotation(droneEntity, 0.0, 0.0, startH, 2, true)
            Wait(16)
        end

        -- Restore to exact start position, flat rotation
        SetEntityCoords(droneEntity, startPos.x, startPos.y, startPos.z, false, false, false, false)
        SetEntityRotation(droneEntity, 0.0, 0.0, startH, 2, true)

        -- Update DroneMovement internal position so it doesn't snap
        if DroneMovement then
            DroneMovement.SetPos(startPos)
        end

        _G.droneDoingTrick = false
    end)
end

local storedCallbacks = nil  -- saved so SetGrounded(false) can restore full options

function DroneTargeting.Add(droneEntity, droneSerial, onOpenStorage, onGuard, onHeal, onStay, onControl, onBattery, onToggleSound)
    -- Clean up any previous target registration first
    if currentEntity then
        DroneTargeting.Remove()
    end

    currentEntity = droneEntity

    -- Store callbacks so we can restore them after waking from grounded/dead state
    storedCallbacks = { onOpenStorage = onOpenStorage, onGuard = onGuard, onHeal = onHeal, onStay = onStay, onControl = onControl, onBattery = onBattery, onToggleSound = onToggleSound }

    exports.ox_target:addLocalEntity(droneEntity, {
        {
            name     = 'nzkfc_drone_storage',
            icon     = 'fas fa-box-open',
            label    = 'Drone Storage',
            distance = 2.5,
            onSelect = function()
                onOpenStorage()
            end,
        },
		{
            name     = 'nzkfc_drone_battery',
            icon     = 'fas fa-battery-half',
            label    = 'Check Battery',
            distance = 2.5,
            canInteract = function()
                return Config.BatteryEnabled
            end,
            onSelect = function()
                onBattery()
            end,
        },
        {
            name        = 'nzkfc_drone_guard',
            icon        = 'fas fa-shield-halved',
            label       = 'Guard Mode',
            distance    = 2.5,
            canInteract = function()
                return Config.GuardEnabled
            end,
            onSelect    = function()
                onGuard()
            end,
        },
        {
            name        = 'nzkfc_drone_heal',
            icon        = 'fas fa-heart',
            label       = 'Activate Healing',
            distance    = 2.5,
            canInteract = function()
                return Config.HealEnabled
            end,
            onSelect    = function()
                onHeal()
            end,
        },     
        {
            name     = 'nzkfc_drone_control',
            icon     = 'fas fa-gamepad',
            label    = 'Take Control',
            distance = 2.5,
            onSelect = function()
                onControl()
            end,
        },
		{
            name     = 'nzkfc_drone_flip',
            icon     = 'fas fa-wand-magic-sparkles',
            label    = 'Drone Flip',
            distance = 2.5,
            onSelect = function()
                local sndId = GetSoundId()
                PlaySoundFromEntity(sndId, Config.Sound.FlipSound, droneEntity, Config.Sound.FlipAudioRef, false, 0)
                CreateThread(function()
                    Wait(5000)
                    ReleaseSoundId(sndId)
                end)
                playDroneTrick(droneEntity)
            end,
        }, 
		{
            name     = 'nzkfc_drone_stay',
            icon     = 'fas fa-map-pin',
            label    = 'Tell Drone to Stay',
            distance = 2.5,
            onSelect = function()
                onStay()
            end,
        },
		{
            name     = 'nzkfc_drone_sound',
            icon     = 'fas fa-volume-xmark',
            label    = 'Toggle Motor Sound',
            distance = 2.5,
            onSelect = function()
                onToggleSound()
            end,
        },
    })
end

-- Switch between flight options and grounded "Pack Drone" option
function DroneTargeting.SetGrounded(entity, grounded)
    if not entity then return end

    -- Remove all current options including wrecked state
    exports.ox_target:removeLocalEntity(entity, {
        'nzkfc_drone_battery',
        'nzkfc_drone_sound',
        'nzkfc_drone_storage',
        'nzkfc_drone_guard',
        'nzkfc_drone_heal',
        'nzkfc_drone_flip',
        'nzkfc_drone_stay',
        'nzkfc_drone_control',
        'nzkfc_drone_pack',
        'nzkfc_drone_wrecked_storage',
    })

    if grounded then
        -- Only show Pack Drone when battery dead and sitting on ground
        exports.ox_target:addLocalEntity(entity, {
            {
                name     = 'nzkfc_drone_storage',
                icon     = 'fas fa-box-open',
                label    = 'Drone Storage',
                distance = 2.5,
                onSelect = function()
                    -- Storage still accessible so player can insert battery
                    TriggerEvent('nzkfc_drone:openStorageFromTarget')
                end,
            }
        })
    else
        -- Ungrounding — re-add full flight options on the (possibly new) entity
        -- needed after model swap where the entity handle changed
        currentEntity = entity
        if storedCallbacks then
            DroneTargeting.Add(entity, nil,
                storedCallbacks.onOpenStorage,
                storedCallbacks.onGuard,
                storedCallbacks.onHeal,
                storedCallbacks.onStay,
                storedCallbacks.onControl,
                storedCallbacks.onBattery,
                storedCallbacks.onToggleSound
            )
        end
    end
end

-- Wrecked state: drone destroyed, storage accessible to ALL players.
-- Uses addEntity (networked) so other clients can loot the wreck.
-- The server broadcasts the netId so every client can register the target.
function DroneTargeting.SetWrecked(entity, serial)
    if not entity then return end

    exports.ox_target:removeLocalEntity(entity, {
        'nzkfc_drone_battery',
        'nzkfc_drone_sound',
        'nzkfc_drone_storage',
        'nzkfc_drone_guard',
        'nzkfc_drone_heal',
        'nzkfc_drone_flip',
        'nzkfc_drone_stay',
        'nzkfc_drone_control',
        'nzkfc_drone_pack',
        'nzkfc_drone_wrecked_storage',
    })

    -- Owner still gets a local target (fastest path)
    exports.ox_target:addLocalEntity(entity, {
        {
            name     = 'nzkfc_drone_wrecked_storage',
            icon     = 'fas fa-box-open',
            label    = 'Recover Storage',
            distance = 2.5,
            onSelect = function()
                TriggerEvent('nzkfc_drone:openStorageFromTarget')
            end,
        },
    })

    -- Broadcast netId + serial to all other clients so they can register
    -- a target on the networked entity and loot the wreck too
    local netId = NetworkGetNetworkIdFromEntity(entity)
    TriggerServerEvent('nzkfc_drone:broadcastWreck', netId, serial)
end

-- Called on non-owner clients when a nearby drone is wrecked
RegisterNetEvent('nzkfc_drone:registerWreckTarget', function(netId, serial)
    -- Wait for the entity to be streamed in
    CreateThread(function()
        local entity = nil
        local t = 0
        while t < 100 do
            entity = NetworkGetEntityFromNetworkId(netId)
            if entity and entity ~= 0 and DoesEntityExist(entity) then break end
            Wait(100)
            t = t + 1
        end
        if not entity or not DoesEntityExist(entity) then return end

        exports.ox_target:addLocalEntity(entity, {
            {
                name     = 'nzkfc_drone_wrecked_storage',
                icon     = 'fas fa-box-open',
                label    = 'Recover Storage',
                distance = 2.5,
                onSelect = function()
                    -- Non-owner opens stash via server event with the serial
                    TriggerServerEvent('nzkfc_drone:openStorageAsGuest', serial)
                end,
            },
        })
    end)
end)

function DroneTargeting.Remove()
    if currentEntity then
        exports.ox_target:removeLocalEntity(currentEntity, {
            'nzkfc_drone_battery',
            'nzkfc_drone_storage',
            'nzkfc_drone_heal',
            'nzkfc_drone_flip',
            'nzkfc_drone_stay',
            'nzkfc_drone_control',
            'nzkfc_drone_pack',
            'nzkfc_drone_wrecked_storage',
        })
        currentEntity = nil
    end
end
