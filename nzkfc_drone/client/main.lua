-- ─── State ────────────────────────────────────────────────────────────────────
local droneEntity   = nil
local droneActive   = false
local droneSerial   = nil
local droneHealth   = Config.DroneMaxHealth
local droneItemSlot = nil

local droneStaying  = false     -- true = drone is parked, not following
local stayPos       = nil       -- position drone is staying at

local healActive    = false     -- true while heal mode is activated
local droneGrounded = false     -- true when battery dead and drone is sitting on ground
local droneWrecked  = false     -- true when drone is destroyed (health=0), storage still accessible

local batteryCharge   = 100.0   -- 0–100, mirrors stash battery item charge
local batterySlot     = nil     -- slot index of battery item in drone stash
local batteryReady    = false   -- true once stash battery has been fetched
local batteryLowTimer = 0       -- seconds since last low battery warning
local batteryEnabled  = Config.BatteryEnabled

-- Heal cooldown tracking per-use (client triggers server per heal event)
local lastHealTrigger = 0

local mainThread    = nil
local batteryThread = nil
local damageThread  = nil

-- Forward declarations (defined later, called from handlers/functions above their definition)
local wakeUpDrone
local startDamageThread
local startMainThread
local startBatteryThread

-- ─── Sounds ───────────────────────────────────────────────────────────────────
-- Uses GTA native audio from DLC_BTL_Drone_Sounds.
-- Flight_Loop is played attached to the drone entity so it moves with it
-- and is positional/audible to nearby players via GTA's own audio engine.

local flySoundId = -1  -- handle for the looping flight sound

local function startFlySound(entity)
    -- Stop any previous instance first
    if flySoundId ~= -1 then
        StopSound(flySoundId)
        ReleaseSoundId(flySoundId)
        flySoundId = -1
    end
    flySoundId = GetSoundId()
    PlaySoundFromEntity(flySoundId, 'Flight_Loop', entity, 'DLC_BTL_Drone_Sounds', false, 0)
end

local function stopFlySound()
    if flySoundId ~= -1 then
        StopSound(flySoundId)
        ReleaseSoundId(flySoundId)
        flySoundId = -1
    end
end

local function playOneshot(soundName)
    local id = GetSoundId()
    PlaySoundFrontend(id, soundName, 'DLC_BTL_Drone_Sounds', true)
    -- Release after a short delay so GTA can finish playing it
    CreateThread(function()
        Wait(3000)
        ReleaseSoundId(id)
    end)
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

-- Blocking kneel: plays anim and waits for it to finish.
local function kneelAnimation(duration)
    local ped = PlayerPedId()
    RequestAnimDict(Config.KneelDict)
    while not HasAnimDictLoaded(Config.KneelDict) do Wait(10) end
    TaskPlayAnim(ped, Config.KneelDict, Config.KneelAnim, 8.0, -8.0, duration, 1, 0, false, false, false)
    Wait(duration)
    StopAnimTask(ped, Config.KneelDict, Config.KneelAnim, 4.0)
end

-- Async kneel: plays anim and fires onFinish callback when done, non-blocking.
local function kneelAnimationAsync(duration, onFinish)
    CreateThread(function()
        local ped = PlayerPedId()
        RequestAnimDict(Config.KneelDict)
        while not HasAnimDictLoaded(Config.KneelDict) do Wait(10) end
        TaskPlayAnim(ped, Config.KneelDict, Config.KneelAnim, 8.0, -8.0, duration, 1, 0, false, false, false)
        Wait(duration)
        StopAnimTask(ped, Config.KneelDict, Config.KneelAnim, 4.0)
        if onFinish then onFinish() end
    end)
end

local function spawnDroneProp(pos)
    local model = joaat(Config.DroneModel)
    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 200 do
        Wait(10); t = t + 1
    end
    if not HasModelLoaded(model) then
        lib.notify({ type = 'error', title = 'Drone', description = 'Failed to load drone model.' })
        return nil
    end

    local ent = CreateObject(model, pos.x, pos.y, pos.z, false, false, false)
    -- Keep collision ON so ox_target raycast can hit the entity
    -- but disable it from pushing the player around
    SetEntityCollision(ent, true, false)
    SetEntityInvincible(ent, true)
    SetEntityCanBeDamaged(ent, false)
    -- Don't use FreezeEntityPosition — we manually set coords every tick instead
    SetModelAsNoLongerNeeded(model)
    return ent
end

local function deleteDroneProp()
    if droneEntity and DoesEntityExist(droneEntity) then
        DroneTargeting.Remove()
        -- Stop all entity-attached audio (including ambient hiss from DLC_BTL_Drone_Sounds)
        -- before deleting so GTA doesn't linger the sound after entity removal
        DeleteObject(droneEntity)
    end
    droneEntity = nil
end

-- Swap the current drone entity to a different model in-place.
-- Used for wreck (shot down) and dead (battery removed) states.
local function swapDroneProp(newModel)
    if not droneEntity or not DoesEntityExist(droneEntity) then return end
    local pos = GetEntityCoords(droneEntity)
    local rot = GetEntityRotation(droneEntity, 2)

    -- Remove targets from old entity (doesn't nil currentEntity in targeting)
    DroneTargeting.Remove()
    DeleteObject(droneEntity)
    droneEntity = nil

    -- Spawn replacement model
    local model = joaat(newModel)
    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 200 do Wait(10); t = t + 1 end
    if not HasModelLoaded(model) then return end

    local ent = CreateObject(model, pos.x, pos.y, pos.z, false, false, false)
    SetEntityCollision(ent, true, false)
    SetEntityInvincible(ent, true)
    SetEntityCanBeDamaged(ent, false)
    SetEntityRotation(ent, rot.x, rot.y, rot.z, 2, true)
    SetModelAsNoLongerNeeded(model)
    droneEntity = ent
    return ent
end

-- ─── Battery ─────────────────────────────────────────────────────────────────
-- Charge lives on the drone_battery item in the drone stash.
-- On deploy the server is asked for the current battery item and its slot.
-- Drain happens client-side and is saved to the stash item every 10 seconds.
-- When charge hits 0 the battery item is removed from the stash and the drone
-- powers down. The player must place a new drone_battery in the stash to resume.

startBatteryThread = function()
    if not batteryEnabled then return end
    if batteryThread then return end

    -- Ask server for battery in stash
    batteryReady = false
    TriggerServerEvent('nzkfc_drone:getBattery', droneSerial)

    batteryThread = CreateThread(function()
        -- Wait up to 5s for stash battery response before proceeding
        local waited = 0
        while not batteryReady and waited < 5000 do
            Wait(100)
            waited = waited + 100
        end

        if not batterySlot then
            lib.notify({ type = 'error', title = 'Drone', description = 'No battery found in drone storage! Place a drone_battery in the stash.' })
            TriggerEvent('nzkfc_drone:forceUndeploy')
            batteryThread = nil
            return
        end

        local saveTimer = 0
        while droneActive do
            Wait(1000)

            local drain = Config.BatteryDrainMoving
            if drain > 0 then
                batteryCharge = math.max(0, batteryCharge - drain)

                -- Save to stash battery every 10 seconds, also check it's still there
                saveTimer = saveTimer + 1
                if saveTimer >= 10 then
                    saveTimer = 0
                    TriggerServerEvent('nzkfc_drone:saveBatteryToStash', droneSerial, batteryCharge, batterySlot)
                    -- Re-verify battery still in stash (player may have removed it)
                    TriggerServerEvent('nzkfc_drone:getBattery', droneSerial)
                end

                -- Low battery warning
                if batteryCharge <= Config.BatteryLowThreshold then
                    batteryLowTimer = batteryLowTimer + 1
                    if batteryLowTimer >= Config.BatteryLowSoundEvery then
                        batteryLowTimer = 0
                        lib.notify({ type = 'warning', title = 'Drone', description = ('Battery low! %d%% remaining — replace battery in drone storage.'):format(math.floor(batteryCharge)) })
                    end
                end

                -- Battery dead — land drone and enter grounded/waiting state
                if batteryCharge <= 0 then
                    -- Swap battery item to empty variant in stash
                    TriggerServerEvent('nzkfc_drone:drainBattery', droneSerial, batterySlot)
                    batterySlot = nil
                    TriggerEvent('nzkfc_drone:groundDrone')
                    batteryThread = nil
                    return
                end
            end
        end
        batteryThread = nil
    end)
end

-- Callback from server with stash battery info
RegisterNetEvent('nzkfc_drone:receiveBattery', function(charge, slot)
    if charge ~= nil then
        batteryCharge = charge
        batterySlot   = slot
        -- Wake drone if it's grounded waiting for a battery
        if droneGrounded then
            wakeUpDrone()
        end
    else
        batterySlot = nil
        -- If flying and battery was pulled, ground the drone
        if droneActive and not droneGrounded then
            TriggerEvent('nzkfc_drone:groundDrone')
        end
    end
    batteryReady = true
end)

-- ─── Ground Drone (battery dead or removed) ─────────────────────────────────
-- Lands the drone, swaps to dead model, storage+pack targets only.
-- Poll thread watches stash for a new battery and wakes drone when found.

local groundPollThread = nil

local function landAndGround()
    if not droneActive or not droneEntity or not DoesEntityExist(droneEntity) then return end

    droneGrounded = true
    healActive    = false
    droneStaying  = false
    droneActive   = false  -- stop main/battery threads before moving entity

    Wait(10)

    stopFlySound()

    -- Drop straight down to ground below current position
    local startPos = GetEntityCoords(droneEntity)
    local foundZ, groundZ = GetGroundZFor_3dCoord(startPos.x, startPos.y, startPos.z, false)
    if not foundZ then groundZ = startPos.z - 5.0 end
    local landPos = vector3(startPos.x, startPos.y, groundZ + 0.1)

    -- Fast fall with slight ease-out near ground
    local steps = 30
    for i = 1, steps do
        local t  = i / steps
        local et = 1.0 - (1.0 - t) * (1.0 - t)
        local lz = startPos.z + (landPos.z - startPos.z) * et
        SetEntityCoords(droneEntity, startPos.x, startPos.y, lz, false, false, false, false)
        Wait(16)
    end

    SetEntityCoords(droneEntity, landPos.x, landPos.y, landPos.z, false, false, false, false)
    SetEntityRotation(droneEntity, 0.0, 0.0, GetEntityHeading(droneEntity), 2, true)

    -- Swap to dead/powerless model
    swapDroneProp(Config.DroneDeadModel)

    lib.notify({ type = 'error', title = 'Drone', description = 'No battery! Open drone storage and insert a drone_battery.' })

    -- Storage + pack targets
    DroneTargeting.SetGrounded(droneEntity, true)

    -- Poll for battery insertion
    if groundPollThread then return end
    groundPollThread = CreateThread(function()
        while droneGrounded do
            Wait(2000)  -- poll every 2s so battery insertion feels responsive
            if not droneGrounded then break end
            TriggerServerEvent('nzkfc_drone:getBattery', droneSerial)
        end
        groundPollThread = nil
    end)
end

AddEventHandler('nzkfc_drone:groundDrone', function()
    landAndGround()
end)

-- Called when a battery is detected in stash while grounded — wake drone back up
wakeUpDrone = function()
    if not droneGrounded then return end
    droneGrounded = false
    droneActive   = true

    lib.notify({ type = 'success', title = 'Drone', description = 'Battery inserted — drone powering back up!' })

    -- Swap back to flight model
    local pos = GetEntityCoords(droneEntity)
    swapDroneProp(Config.DroneModel)

    -- Re-apply damage settings on new entity
    if Config.DamageEnabled then
        SetEntityInvincible(droneEntity, false)
        SetEntityCanBeDamaged(droneEntity, true)
    end

    -- Re-init movement from current ground position
    DroneMovement.Init(GetEntityCoords(droneEntity), GetEntityHeading(PlayerPedId()))

    -- Restore full targets
    DroneTargeting.SetGrounded(droneEntity, false)

    -- Lift back to shoulder
    CreateThread(function()
        local ped2       = PlayerPedId()
        local pedPos2    = GetEntityCoords(ped2)
        local h2         = GetEntityHeading(ped2)
        local shoulderPos = vector3(
            pedPos2.x + Config.TargetOffsetLocal.x * math.cos(math.rad(-h2)) - Config.TargetOffsetLocal.y * math.sin(math.rad(-h2)),
            pedPos2.y + Config.TargetOffsetLocal.x * math.sin(math.rad(-h2)) + Config.TargetOffsetLocal.y * math.cos(math.rad(-h2)),
            pedPos2.z + Config.TargetOffsetLocal.z
        )
        local liftStart = GetEntityCoords(droneEntity)
        local steps     = 80
        for i = 1, steps do
            if not droneActive then break end
            local t  = i / steps
            local et = t * t
            local lx = liftStart.x + (shoulderPos.x - liftStart.x) * et
            local ly = liftStart.y + (shoulderPos.y - liftStart.y) * et
            local lz = liftStart.z + (shoulderPos.z - liftStart.z) * et
            DroneMovement.SetPos(vector3(lx, ly, lz))
            SetEntityCoords(droneEntity, lx, ly, lz, false, false, false, false)
            Wait(16)
        end
        startMainThread()
    end)

    -- Restart battery drain and damage monitoring
    batteryLowTimer = 0
    startBatteryThread()
    if Config.DamageEnabled then
        Wait(0)
        startDamageThread()
    end

end

-- ─── Damage Monitoring ───────────────────────────────────────────────────────

startDamageThread = function()
    if damageThread then return end
    damageThread = CreateThread(function()
        -- Wait 2 frames so GTA fully registers the health pool after SetEntityCanBeDamaged(true).
        -- Reading immediately returns 0 on a fresh prop, skewing all future diff calculations.
        Wait(100)
        local prevEntityHealth = GetEntityHealth(droneEntity)

        while droneActive and droneEntity and DoesEntityExist(droneEntity) do
            Wait(500)

            if not Config.DamageEnabled then
                damageThread = nil
                return
            end

            -- Re-check entity still exists and drone still active before reading health.
            -- DeleteObject briefly sets entity health to 0 — without this guard a normal
            -- pack-away would be misread as destruction.
            if not droneActive or not droneEntity or not DoesEntityExist(droneEntity) then
                damageThread = nil
                return
            end

            local curEntityHealth = GetEntityHealth(droneEntity)

            -- Only ignore zero-health if the entity is also gone (pack-away race).
            -- If entity still exists and droneActive is true, zero health is a real destruction.
            if curEntityHealth == 0 and not DoesEntityExist(droneEntity) then
                damageThread = nil
                return
            end

            if curEntityHealth < prevEntityHealth then
                local diff = prevEntityHealth - curEntityHealth
                -- Scale GTA entity health loss to our drone HP pool
                local dmg = math.floor((diff / 1000) * Config.DroneMaxHealth)
                droneHealth = math.max(0, droneHealth - math.max(dmg, 10))
                prevEntityHealth = curEntityHealth

                lib.notify({ type = 'warning', title = 'Drone', description = ('Drone hit! Health: %d/%d'):format(droneHealth, Config.DroneMaxHealth) })
                TriggerServerEvent('nzkfc_drone:saveHealth', droneSerial, droneHealth)
            end

            -- Check droneHealth outside the diff block — once entity health reaches 0
            -- it stays at 0 so curEntityHealth < prevEntityHealth never fires again,
            -- meaning the destroy check inside would never be reached.
            if droneHealth <= 0 then
                lib.notify({ type = 'error', title = 'Drone', description = 'Drone destroyed! Storage is still recoverable.' })
                TriggerServerEvent('nzkfc_drone:destroyed', droneSerial)
                TriggerEvent('nzkfc_drone:wreckDrone')
                damageThread = nil
                return
            end
        end
        damageThread = nil
    end)
end

-- ─── Main Follow Thread ───────────────────────────────────────────────────────

startMainThread = function()
    if mainThread then return end

    startFlySound(droneEntity)

    mainThread = CreateThread(function()
        local healTimer = 0  -- ticks since last heal fire

        while droneActive and droneEntity and DoesEntityExist(droneEntity) do
            Wait(0)

            -- Pause movement when drone is grounded (battery dead)
            if droneGrounded then
                goto continue
            end

            -- If controlling via FPV or doing a trick, skip follow logic
            if DroneControl.IsControlling() then
                goto continue
            end

            -- Pause follow during drone trick animation
            if _G.droneDoingTrick then
                goto continue
            end

            -- Determine target override
            local target = nil
            if droneStaying then
                -- Drone is parked — hover in place
                target = stayPos
            elseif DroneControl.GetControlPos() then
                -- Just returned from control — let movement take over naturally
            end

            -- Tick movement
            local newPos, newH, delta = DroneMovement.Tick(droneEntity, target)

            -- Heal tick: only runs while heal mode is active
            if healActive and Config.HealEnabled then
                healTimer = healTimer + 1
                if healTimer >= (Config.HealInterval * 60) then
                    healTimer = 0
                    TriggerServerEvent('nzkfc_drone:healNearby', GetEntityCoords(droneEntity))
                end
            end

            ::continue::
        end

        mainThread = nil
    end)
end

-- ─── Deploy ───────────────────────────────────────────────────────────────────

local function deployDrone(itemMeta, slot)
    if droneActive then return end

    droneSerial     = itemMeta.serial
    -- If saved health is 0 (edge case from interrupted destroy), reset to full.
    droneHealth     = (itemMeta.health and itemMeta.health > 0) and itemMeta.health or Config.DroneMaxHealth
    droneItemSlot   = slot
    droneStaying    = false
    stayPos         = nil
    batteryCharge   = 100.0   -- will be overwritten when stash battery is fetched
    batterySlot     = nil
    batteryReady    = false
    batteryLowTimer = 0
    droneWrecked    = false

    lib.notify({ type = 'inform', title = 'Drone', description = 'Deploying drone...' })

    -- Spawn drone on ground in front of player BEFORE kneeling,
    -- so it's visible sitting there as the player crouches down.
    local ped    = PlayerPedId()
    local pedPos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad     = math.rad(-heading)

    -- 0.8m in front of player, probed to actual ground Z
    local spawnX   = pedPos.x + -0.90 * math.sin(math.rad(heading))
    local spawnY   = pedPos.y + 0.90 * math.cos(math.rad(heading))
    local foundZ, groundZ = GetGroundZFor_3dCoord(spawnX, spawnY, pedPos.z - 0.3, false)
    if not foundZ then groundZ = pedPos.z - 0.3 end
    local spawnPos = vector3(spawnX, spawnY, groundZ - 0.2)

    local ent = spawnDroneProp(spawnPos)
    if not ent then return end
    droneEntity = ent
    droneActive = true

    DroneMovement.Init(spawnPos, heading)

    -- Kneel animation (blocking) — drone sits on ground while player crouches
    kneelAnimation(Config.KneelDuration)

    -- Player is now standing back up — lift off
    -- Liftoff: ease-in curve so it accelerates off the ground naturally
    CreateThread(function()
        local ped2    = PlayerPedId()
        local pedPos2 = GetEntityCoords(ped2)
        local h2      = GetEntityHeading(ped2)

        -- Shoulder target position
        local shoulderPos = vector3(
            pedPos2.x + Config.TargetOffsetLocal.x * math.cos(math.rad(-h2)) - Config.TargetOffsetLocal.y * math.sin(math.rad(-h2)),
            pedPos2.y + Config.TargetOffsetLocal.x * math.sin(math.rad(-h2)) + Config.TargetOffsetLocal.y * math.cos(math.rad(-h2)),
            pedPos2.z + Config.TargetOffsetLocal.z
        )

        local liftStart = GetEntityCoords(droneEntity)
        local steps     = 80  -- ~1.3s at 60fps

        for i = 1, steps do
            if not droneActive then break end
            -- Ease-in: starts slow, accelerates
            local t  = i / steps
            local et = t * t
            local lx = liftStart.x + (shoulderPos.x - liftStart.x) * et
            local ly = liftStart.y + (shoulderPos.y - liftStart.y) * et
            local lz = liftStart.z + (shoulderPos.z - liftStart.z) * et
            DroneMovement.SetPos(vector3(lx, ly, lz))
            SetEntityCoords(droneEntity, lx, ly, lz, false, false, false, false)
            Wait(16)
        end

        -- Hand off to normal follow thread
        startMainThread()
    end)

    -- Add targets
    DroneTargeting.Add(
        droneEntity,
        droneSerial,

        -- onOpenStorage
        function()
            TriggerServerEvent('nzkfc_drone:openStorage', droneSerial, Config.StorageSlots, Config.StorageWeight)
        end,

        -- onHeal
        function()
            if healActive then
                -- Turn off
                healActive = false
                lib.notify({ type = 'inform', title = 'Drone', description = 'Healing deactivated.' })
            else
                -- Turn on — immediately fire first tick then let timer handle the rest
                healActive = true
                TriggerServerEvent('nzkfc_drone:healNearby', GetEntityCoords(droneEntity))
                lib.notify({ type = 'success', title = 'Drone', description = 'Healing activated.' })
            end
        end,

        -- onStay
        function()
            if droneStaying then
                -- Already staying, cancel stay
                droneStaying = false
                stayPos      = nil
                lib.notify({ type = 'inform', title = 'Drone', description = 'Drone is following you again.' })
            else
                droneStaying = true
                stayPos      = GetEntityCoords(droneEntity)
                lib.notify({ type = 'inform', title = 'Drone', description = 'Drone is staying put. Use /calldrone to recall.' })
            end
        end,

        -- onControl
        function()
            if DroneControl.IsControlling() then
                lib.notify({ type = 'warning', title = 'Drone', description = 'Already in control mode.' })
                return
            end
            droneStaying = false
            DroneControl.Start(droneEntity, GetEntityCoords(droneEntity))
        end,

        -- onBattery
        function()
            if not batteryEnabled then
                lib.notify({ type = 'inform', title = 'Drone', description = 'Battery system is disabled.' })
                return
            end
            if not batteryReady then
                lib.notify({ type = 'inform', title = 'Drone', description = 'Reading battery...' })
                return
            end
            local pct   = math.floor(batteryCharge)
            local level = pct > 50 and 'success' or (pct > 20 and 'warning' or 'error')
            local icon  = pct > 50 and 'fa-battery-full' or (pct > 20 and 'fa-battery-half' or 'fa-battery-empty')
            lib.notify({
                type        = level,
                title       = 'Drone Battery',
                description = ('Battery: %d%%'):format(pct),
                icon        = 'fas ' .. icon,
            })
        end
    )

    -- Start battery and damage monitoring
    startBatteryThread()
    if Config.DamageEnabled then
        -- Enable damage BEFORE starting the thread so prevEntityHealth is
        -- captured after the entity has a real health pool (default 1000).
        SetEntityInvincible(droneEntity, false)
        SetEntityCanBeDamaged(droneEntity, true)
        Wait(0)  -- one yield so GTA registers the health pool
        startDamageThread()
    end

    lib.notify({ type = 'success', title = 'Drone', description = ('Drone deployed! [%s] HP: %d/%d'):format(droneSerial, droneHealth, Config.DroneMaxHealth) })
end

-- ─── Undeploy ─────────────────────────────────────────────────────────────────

local function undeployDrone()
    if not droneActive then return end
    if droneWrecked then return end   -- wrecked drones cannot be packed away
    healActive    = false
    droneGrounded = false

    -- Stop control mode if active
    if DroneControl.IsControlling() then
        DroneControl.Stop(droneEntity)
        Wait(600)
    end

    droneStaying = false
    local ped     = PlayerPedId()
    local pedPos  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Land spot: 0.8m in front of player, probed to actual ground Z
    local landX   = pedPos.x + -0.90 * math.sin(math.rad(heading))
    local landY   = pedPos.y + 0.90 * math.cos(math.rad(heading))
	
    -- Probe from 2m above player downward to find the actual surface.
    -- pedPos.z is the player's feet — probing from below that misses the ground.
    local foundLZ, landGZ = GetGroundZFor_3dCoord(landX, landY, pedPos.z + 2.0, false)
    if not foundLZ then landGZ = pedPos.z end
    local landPos = vector3(landX, landY, landGZ + 0.1)

    lib.notify({ type = 'inform', title = 'Drone', description = 'Recalling drone...' })
    stopFlySound()

    -- Kill the follow/main thread first so it stops fighting the glide animation.
    -- droneActive=false stops all threads cleanly; we keep the entity alive for the glide.
    droneActive = false
    Wait(10)  -- one yield so threads see the flag before we start moving the entity

    -- Glide drone down to land position with ease-out curve (~1.2s)
    local startPos = GetEntityCoords(droneEntity)
    local glideMs  = 1200
    local steps    = math.floor(glideMs / 16)
    for i = 1, steps do
        local t  = i / steps
        local et = 1.0 - (1.0 - t) * (1.0 - t)  -- ease-out: decelerates near ground
        local lx = startPos.x + (landPos.x - startPos.x) * et
        local ly = startPos.y + (landPos.y - startPos.y) * et
        local lz = startPos.z + (landPos.z - startPos.z) * et
        SetEntityCoords(droneEntity, lx, ly, lz, false, false, false, false)
        Wait(16)
    end

    -- Drone is on the ground — now player kneels to pick it up
    kneelAnimation(Config.KneelDuration)

    -- Save battery charge back to stash item
    if batteryEnabled and batterySlot and droneSerial then
        TriggerServerEvent('nzkfc_drone:saveBatteryToStash', droneSerial, batteryCharge, batterySlot)
    end

    -- Save health
    if droneSerial then
        TriggerServerEvent('nzkfc_drone:saveHealth', droneSerial, droneHealth)
    end

    deleteDroneProp()
    stopFlySound()  -- call again after entity deleted — entity deletion + full undeploy duration should fully clear the audio tail

    lib.notify({ type = 'success', title = 'Drone', description = 'Drone packed away.' })
end

-- ─── Wreck Drone (health reaches 0) ─────────────────────────────────────────
-- Swaps to wreck model, falls to ground, storage-only target.
-- Notifies server to schedule prop cleanup after WreckCleanupMinutes.

AddEventHandler('nzkfc_drone:wreckDrone', function()
    if not droneActive then return end

    droneWrecked  = true
    droneActive   = false
    healActive    = false
    droneGrounded = false

    stopFlySound()

    if not droneEntity or not DoesEntityExist(droneEntity) then return end

    -- Capture fall start before swap
    local pos    = GetEntityCoords(droneEntity)
    local ped    = PlayerPedId()
    local pedPos = GetEntityCoords(ped)

    -- Swap to broken wreck model at same position
    local newEnt = swapDroneProp(Config.DroneWreckModel)
    if not newEnt then return end

    -- Find ground below crash position
    local foundZ, groundZ = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z, false)
    if not foundZ then groundZ = pedPos.z end

    -- Fast fall to ground
    local startZ = pos.z
    local steps  = 20
    for i = 1, steps do
        local t  = i / steps
        local lz = startZ + (groundZ - startZ) * t
        SetEntityCoords(droneEntity, pos.x, pos.y, lz, false, false, false, false)
        Wait(16)
    end

    -- Tilt to sell the crash
    SetEntityRotation(droneEntity, 0.0, 25.0, GetEntityHeading(droneEntity), 2, true)

    -- Storage-only target
    DroneTargeting.SetWrecked(droneEntity)

    -- Tell server to schedule stash cleanup after WreckCleanupMinutes
    TriggerServerEvent('nzkfc_drone:scheduleWreckCleanup', droneSerial)
end)

-- ─── Pack Drone (called from target option when grounded) ────────────────────

local function packDrone()
    if not droneActive then return end

    -- Save health before packing
    if droneSerial then
        TriggerServerEvent('nzkfc_drone:saveHealth', droneSerial, droneHealth)
    end

    droneActive   = false
    droneGrounded = false
    healActive    = false

    deleteDroneProp()
    kneelAnimation(Config.KneelDuration)
    lib.notify({ type = 'success', title = 'Drone', description = 'Drone packed away.' })
end

-- Expose so targeting can call it
_G.dronePackDrone = packDrone

-- ─── Force Undeploy (battery dead / destroyed) ────────────────────────────────

AddEventHandler('nzkfc_drone:forceUndeploy', function()
    if not droneActive then return end
    droneActive   = false
    droneGrounded = false
    droneWrecked  = false
    deleteDroneProp()
end)

-- ─── /calldrone command ───────────────────────────────────────────────────────

RegisterCommand('calldrone', function()
    if not droneActive then
        lib.notify({ type = 'error', title = 'Drone', description = 'No active drone to recall.' })
        return
    end
    if droneStaying then
        droneStaying = false
        stayPos      = nil
        lib.notify({ type = 'success', title = 'Drone', description = 'Drone is returning to you.' })
    else
        lib.notify({ type = 'inform', title = 'Drone', description = 'Drone is already following you.' })
    end
end, false)

-- ─── Item Use ─────────────────────────────────────────────────────────────────
-- When ox_inventory calls a client.export it passes ONE argument: the item data table.
-- The slot number is at data.slot — there is no second argument.
-- When using client.event it triggers a local event with the item data table as arg 1.

local itemUseLock = false  -- prevent double-firing while serial is being assigned

local function handleItemUse(data)
    if itemUseLock then return end
    -- If wrecked but not active, the prop is just sitting in the world — player can deploy a new drone
    if droneWrecked and not droneActive then droneWrecked = false end
    if droneWrecked then return end

    -- data is the full item table from ox_inventory
    local slot     = data.slot
    local metadata = data.metadata or {}

    if droneActive then
        undeployDrone()
    else
        if metadata.serial then
            deployDrone(metadata, slot)
        else
            -- First use — ask server to generate a serial
            itemUseLock   = true
            droneItemSlot = slot
            TriggerServerEvent('nzkfc_drone:generateSerial', slot)
        end
    end
end

-- Called when item has: client = { export = 'nzkfc_drone.useDrone' }
exports('useDrone', function(data)
    handleItemUse(data)
end)

-- Called when item has: client = { event = 'nzkfc_drone:useItem' }
AddEventHandler('nzkfc_drone:useItem', function(data)
    handleItemUse(data)
end)

-- ─── Serial assigned callback (fires after server generates a new serial) ────
RegisterNetEvent('nzkfc_drone:serialAssigned', function(metadata)
    itemUseLock = false
    lib.notify({ type = 'success', title = 'Drone', description = 'Drone initialised: ' .. metadata.serial })
    deployDrone(metadata, droneItemSlot)
end)

-- ─── Healing visual feedback helpers ─────────────────────────────────────────

-- Floating "+N" text that rises over the player's head and fades out
local function spawnFloatingHealText(amount)
    CreateThread(function()
        local ped      = PlayerPedId()
        local duration = 2000   -- ms the text stays visible
        local startMs  = GetGameTimer()
        local riseRate = 0.0012 -- how fast the text floats up per ms

        while true do
            local elapsed = GetGameTimer() - startMs
            if elapsed >= duration then break end

            local progress = elapsed / duration
            local alpha    = math.floor(255 * (1.0 - progress))  -- fade out
            local pedPos   = GetEntityCoords(ped)
            local textPos  = vector3(pedPos.x, pedPos.y, pedPos.z + 1.0 + (riseRate * elapsed))

            -- Project world pos to screen
            local onScreen, sx, sy = GetScreenCoordFromWorldCoord(textPos.x, textPos.y, textPos.z)
            if onScreen then
                SetTextFont(4)
                SetTextScale(0.5, 0.5)
                SetTextColour(0, 255, 80, alpha)
                SetTextOutline()
                SetTextCentre(true)
                BeginTextCommandDisplayText('STRING')
                AddTextComponentSubstringPlayerName('+' .. tostring(amount))
                EndTextCommandDisplayText(sx, sy)
            end

            Wait(0)
        end
    end)
end

-- Green particle burst on the player using a smoke/gas effect tinted green
local function spawnHealParticles(ped)
    local assetName = 'core'
    RequestNamedPtfxAsset(assetName)
    local t = 0
    while not HasNamedPtfxAssetLoaded(assetName) and t < 100 do
        Wait(10); t = t + 1
    end
    if not HasNamedPtfxAssetLoaded(assetName) then return end

    UseParticleFxAssetNextCall(assetName)
    SetParticleFxNonLoopedColour(0.0, 1.0, 0.2)  -- green tint
    SetParticleFxNonLoopedAlpha(0.8)
    -- cash pickup burst — compact green puff, fits healing perfectly
    StartParticleFxNonLoopedOnEntity('ent_anim_parachute_smoke', ped, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.8, false, false, false)

    RemoveNamedPtfxAsset(assetName)
end

-- ─── Receive heal from server ────────────────────────────────────────────────
RegisterNetEvent('nzkfc_drone:applyHeal', function(amount)
    local ped       = PlayerPedId()
    local maxHealth = GetEntityMaxHealth(ped)
    local health    = GetEntityHealth(ped)

    if health >= maxHealth then
        -- This player is full — report back so heal can deactivate
        TriggerServerEvent('nzkfc_drone:healComplete')
        return
    end

    local newHealth = math.min(maxHealth, health + amount)
    SetEntityHealth(ped, newHealth)

    -- Visual feedback: floating text + particles
    spawnFloatingHealText(amount)
    spawnHealParticles(ped)

    -- If now full after this heal, deactivate
    if newHealth >= maxHealth then
        TriggerServerEvent('nzkfc_drone:healComplete')
    end
end)

-- ─── AOE Heal Zone Marker ────────────────────────────────────────────────────
-- Draws a pulsing green cylinder under the drone showing the heal radius.
-- Only visible when a player is within 2x the heal range.

CreateThread(function()
    local pulse    = 0.0
    local pulseDir = 1

    while true do
        -- Only draw when heal is active and drone exists
        if not healActive or not droneActive or not droneEntity or not DoesEntityExist(droneEntity) then
            Wait(200)
        else
            local dronePos = GetEntityCoords(droneEntity)

            -- Pulse alpha between 30 and 80
            pulse = pulse + (pulseDir * 0.008)
            if pulse >= 1.0 then pulseDir = -1 end
            if pulse <= 0.0 then pulseDir =  1 end
            local alpha = math.floor(30 + (pulse * 50))

            DrawMarker(
                27,                                           -- flat cylinder disc
                dronePos.x, dronePos.y, dronePos.z - 2.0,  -- position below drone
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                Config.HealRadius * 2.0,                    -- diameter
                Config.HealRadius * 2.0,
                0.3,
                0, 210, 80, alpha,                          -- green
                false, false, 2, false, nil, nil, false
            )

            Wait(0)
        end
    end
end)

-- ─── Heal complete — server says nobody in range needs healing ───────────────
RegisterNetEvent('nzkfc_drone:healComplete', function()
    if healActive then
        healActive = false
        lib.notify({ type = 'success', title = 'Drone', description = 'All players healed.' })
    end
end)

-- Storage accessible from grounded target (so player can insert new battery)
AddEventHandler('nzkfc_drone:openStorageFromTarget', function()
    if droneSerial then
        TriggerServerEvent('nzkfc_drone:openStorage', droneSerial, Config.StorageSlots, Config.StorageWeight)
    end
end)

-- ─── Cleanup on resource stop ────────────────────────────────────────────────
AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then
        stopFlySound()
        if droneEntity and DoesEntityExist(droneEntity) then
            DeleteObject(droneEntity)
        end
    end
end)

-- ─── Audio safety thread ─────────────────────────────────────────────────────
-- If the drone is not active/alive, ensure the fly sound is never running.
-- Guards against orphaned audio from script restarts or edge-case crashes.
CreateThread(function()
    while true do
        Wait(5000)
        if not droneActive then
            if flySoundId ~= -1 then
                stopFlySound()
            end
        end
    end
end)

print('[nzkfc_drone] Script loaded ok!')
