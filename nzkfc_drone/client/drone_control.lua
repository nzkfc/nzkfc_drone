-- Handles first-person drone control mode (FPV)

DroneControl = {}

local controlling    = false
local controlPos     = nil   -- current controlled drone position
local droneEntityRef = nil   -- ref to drone entity from main

-- GTA key codes
local KEY = {
    W     = 32,   -- InputMoveUpOnly
    S     = 33,   -- InputMoveDownOnly
    A     = 34,   -- InputMoveLeftOnly
    D     = 35,   -- InputMoveRightOnly
    Q     = 44,   -- InputDuck (crouch/Q)
    Z     = 20,   -- InputDetachVehicle (Z key)
    SPACE = 22,   -- InputJump
}

-- E key descend — use RegisterKeyMapping to avoid control index conflicts
local eKeyHeld = false
-- +/- command pair tracks held state of the E key for descend
RegisterCommand('+drone_descend', function() eKeyHeld = true  end, false)
RegisterCommand('-drone_descend', function() eKeyHeld = false end, false)
RegisterKeyMapping('+drone_descend', 'Drone: Descend (hold E)', 'keyboard', 'e')

local function applyTimecycleEffect()
    SetTimecycleModifier('heliGunCamMP')
    SetTimecycleModifierStrength(1.0)
end

local function clearTimecycleEffect()
    ClearTimecycleModifier()
end

local function getFovCam(entity)
    local camHandle = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        60.0, true, 2
    )
    AttachCamToEntity(camHandle, entity, 0.0, 0.0, Config.ControlCamOffsetZ, true)
    SetCamActive(camHandle, true)
    RenderScriptCams(true, true, 500, true, true)
    return camHandle
end

function DroneControl.IsControlling()
    return controlling
end

function DroneControl.GetControlPos()
    return controlPos
end

function DroneControl.Start(droneEntity, startPos)
    if controlling then return end
    controlling    = true
    controlPos     = startPos
    droneEntityRef = droneEntity

    applyTimecycleEffect()

    -- Show control hint
    lib.notify({ type = 'inform', title = 'Drone Control', description = 'W/S/A/D = Move | Q = Up | E = Down | SPACE = Disconnect' })

    -- Hide player ped
    --SetEntityVisible(PlayerPedId(), false, false)

    local cam = getFovCam(droneEntity)

    -- Camera pitch control (look up/down)
    local camPitch = 0.0

    CreateThread(function()
        while controlling do
            -- Check max range
            local pedPos = GetEntityCoords(PlayerPedId())
            local dist   = #(controlPos - pedPos)

            if dist > Config.ControlMaxRange then
                lib.notify({ type = 'error', title = 'Drone', description = 'Signal lost — drone returning.' })
                DroneControl.Stop(droneEntity)
                break
            end

            -- Disconnect
            if IsDisabledControlJustPressed(0, KEY.SPACE) then
                DroneControl.Stop(droneEntity)
                break
            end

            -- Movement
            local heading = GetEntityHeading(droneEntity)
            local rad     = math.rad(-heading)
            local cosH    = math.cos(rad)
            local sinH    = math.sin(rad)

            local moveX, moveY, moveZ = 0.0, 0.0, 0.0
            local speed = Config.ControlMoveSpeed

            if IsDisabledControlPressed(0, KEY.W) then
                moveX = moveX + sinH * speed
                moveY = moveY + cosH * speed
            end
            if IsDisabledControlPressed(0, KEY.S) then
                moveX = moveX - sinH * speed
                moveY = moveY - cosH * speed
            end
            if IsDisabledControlPressed(0, KEY.A) then
                moveX = moveX - cosH * speed
                moveY = moveY + sinH * speed
            end
            if IsDisabledControlPressed(0, KEY.D) then
                moveX = moveX + cosH * speed
                moveY = moveY - sinH * speed
            end
            if IsDisabledControlPressed(0, KEY.Q) then
                moveZ = moveZ + Config.ControlAscendSpeed
            end
            if eKeyHeld then
                moveZ = moveZ - Config.ControlAscendSpeed
            end

            -- Collision check via raycast before applying movement.
            -- Cast a short ray in the intended direction — if it hits world geometry, block that axis.
            local probeRadius = 0.35  -- how close to geometry before stopping (metres)

            local function isBlocked(dx, dy, dz)
                local from = controlPos
                local to   = vector3(controlPos.x + dx, controlPos.y + dy, controlPos.z + dz)
                local _, hit, _, _, _ = GetShapeTestResult(StartShapeTestRay(
                    from.x, from.y, from.z,
                    to.x,   to.y,   to.z,
                    1 + 16,  -- 1=world static, 16=water/terrain
                    droneEntityRef, 4
                ))
                return hit == 1
            end

            -- Test each axis independently so the drone slides along surfaces
            if moveX ~= 0.0 and isBlocked(moveX + (moveX > 0 and probeRadius or -probeRadius), 0, 0) then moveX = 0.0 end
            if moveY ~= 0.0 and isBlocked(0, moveY + (moveY > 0 and probeRadius or -probeRadius), 0) then moveY = 0.0 end
            if moveZ ~= 0.0 and isBlocked(0, 0, moveZ + (moveZ > 0 and probeRadius or -probeRadius)) then moveZ = 0.0 end

            -- Hard floor clamp — prevent going below terrain regardless of raycast
            local _, floorZ = GetGroundZFor_3dCoord(controlPos.x, controlPos.y, controlPos.z + 2.0, false)
            if floorZ and controlPos.z + moveZ < floorZ + probeRadius then
                moveZ = math.max(0.0, moveZ)  -- only allow upward movement if at floor
            end

            controlPos = vector3(
                controlPos.x + moveX,
                controlPos.y + moveY,
                controlPos.z + moveZ
            )

            -- Yaw: mouse horizontal input
            local mouseX = GetDisabledControlNormal(0, 1) -- InputLookLeftRight
            local newH   = (GetEntityHeading(droneEntity) - mouseX * Config.ControlYawSensitivity) % 360.0
            SetEntityHeading(droneEntity, newH)

            -- Camera pitch: mouse vertical
            camPitch = math.max(-89.0, math.min(89.0, camPitch + GetDisabledControlNormal(0, 2) * -Config.ControlPitchSensitivity))
            SetCamRot(cam, camPitch, 0.0, newH, 2)

            -- Suppress normal controls so player doesn't move
            DisableAllControlActions(0)
            EnableControlAction(0, KEY.SPACE, true)

            SetEntityCoords(droneEntity, controlPos.x, controlPos.y, controlPos.z, false, false, false, false)

            Wait(0)
        end

        -- Clean up camera
        RenderScriptCams(false, true, 500, true, true)
        DestroyCam(cam, false)
        clearTimecycleEffect()
    end)
end

function DroneControl.Stop(droneEntity)
    if not controlling then return end
    controlling = false
    --SetEntityVisible(PlayerPedId(), true, false)
    lib.notify({ type = 'success', title = 'Drone', description = 'Disconnected from drone.' })
end
