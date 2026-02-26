-- Handles all drone positional movement, follow logic, hover bob

DroneMovement = {}

-- ─── Internal state ──────────────────────────────────────────────────────────
local dronePos          = nil
local droneHeading      = 0.0
local lastPlayerHeading = 0.0
local headingChangeTimer = 0.0
local lockedHeading     = 0.0
local bobTimer          = 0.0
local lastTickTime      = 0

-- ─── Math helpers ─────────────────────────────────────────────────────────────

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerpAngle(a, b, t)
    local diff = b - a
    while diff >  180.0 do diff = diff - 360.0 end
    while diff < -180.0 do diff = diff + 360.0 end
    return a + diff * t
end

local function vecLen(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vecNorm(v)
    local l = vecLen(v)
    if l < 0.0001 then return vector3(0, 0, 0) end
    return vector3(v.x / l, v.y / l, v.z / l)
end

local function localOffsetToWorld(offset, headingDeg)
    local rad  = math.rad(-headingDeg)
    local cosH = math.cos(rad)
    local sinH = math.sin(rad)
    return vector3(
        offset.x * cosH - offset.y * sinH,
        offset.x * sinH + offset.y * cosH,
        offset.z
    )
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Initialise movement state from a given world position
function DroneMovement.Init(startPos, startHeading)
    dronePos          = startPos
    droneHeading      = startHeading
    lastPlayerHeading = startHeading
    lockedHeading     = startHeading
    headingChangeTimer = 0.0
    bobTimer          = 0.0
    lastTickTime      = GetGameTimer()
end

--- Called every tick; returns newPos, newHeading, movementDelta
--- @param droneEntity  number  GTA entity handle
--- @param overrideTarget  vector3|nil  if set, move toward this pos instead of shoulder
function DroneMovement.Tick(droneEntity, overrideTarget)
    local now = GetGameTimer()
    local dt  = (now - lastTickTime) / 1000.0
    lastTickTime = now
    if dt > 0.1 then dt = 0.1 end

    local ped    = PlayerPedId()
    local pedPos = GetEntityCoords(ped)
    local pedH   = GetEntityHeading(ped)

    -- ── Heading follow delay (only relevant in shoulder-follow mode) ──────────
    if not overrideTarget then
        local hdiff = math.abs(pedH - lastPlayerHeading)
        if hdiff > 180 then hdiff = 360 - hdiff end

        if hdiff > 5.0 then
            headingChangeTimer = 0.0
        else
            headingChangeTimer = headingChangeTimer + dt
            if headingChangeTimer >= Config.HeadingFollowDelay then
                lockedHeading = pedH
            end
        end
        lastPlayerHeading = pedH
    end

    -- ── Compute target ────────────────────────────────────────────────────────
    local targetPos
    if overrideTarget then
        targetPos = overrideTarget
    else
        bobTimer = bobTimer + dt * Config.BobSpeed
        local bob = math.sin(bobTimer) * Config.BobAmount

        local worldOffset = localOffsetToWorld(Config.TargetOffsetLocal, lockedHeading)
        targetPos = vector3(
            pedPos.x + worldOffset.x,
            pedPos.y + worldOffset.y,
            pedPos.z + worldOffset.z + bob
        )
    end

    -- ── Move toward target ────────────────────────────────────────────────────
    local toTarget = vector3(
        targetPos.x - dronePos.x,
        targetPos.y - dronePos.y,
        targetPos.z - dronePos.z
    )
    local dist = vecLen(toTarget)
    local prevPos = dronePos

    if dist > 0.001 then
        local step    = dist * Config.LerpSpeed
        -- Use slower return speed when drone is far from its target (e.g. returning from stay)
        local maxStep = dist > Config.ReturnThreshold and Config.ReturnSpeedPerTick or Config.MaxSpeedPerTick
        if step > maxStep then step = maxStep end
        local dir = vecNorm(toTarget)
        dronePos = vector3(
            dronePos.x + dir.x * step,
            dronePos.y + dir.y * step,
            dronePos.z + dir.z * step
        )
    end

    -- ── Heading from movement ─────────────────────────────────────────────────
    if dist > 0.05 then
        local desiredH = math.deg(math.atan(toTarget.x, toTarget.y))
        droneHeading = lerpAngle(droneHeading, desiredH, Config.RotationLerpSpeed)
    end

    -- ── Apply to entity ───────────────────────────────────────────────────────
    SetEntityCoords(droneEntity, dronePos.x, dronePos.y, dronePos.z, false, false, false, false)
    SetEntityHeading(droneEntity, droneHeading)

    -- Return movement delta so battery system can measure it
    local delta = vecLen(vector3(dronePos.x - prevPos.x, dronePos.y - prevPos.y, dronePos.z - prevPos.z))
    return dronePos, droneHeading, delta
end

--- Force-set internal position (e.g. when landing/teleporting)
function DroneMovement.SetPos(pos)
    dronePos = pos
end

function DroneMovement.GetPos()
    return dronePos
end

function DroneMovement.GetHeading()
    return droneHeading
end
