Config = {}

-- ─── Item ────────────────────────────────────────────────────────────────────
Config.DroneItem = 'drone'                -- ox_inventory item name

-- ─── Drone Prop ──────────────────────────────────────────────────────────────
Config.DroneModel = 'xs_prop_arena_drone_02'

-- ─── Follow Positioning ──────────────────────────────────────────────────────
-- Local offset from player (left shoulder, behind, above)
-- X = left/right (negative = player's left), Y = forward/back (negative = behind), Z = up/down
Config.TargetOffsetLocal = vector3(-1.0, -1.0, 1.1)

Config.LerpSpeed          = 0.04    -- How fast drone moves toward target (lower = floatier)
Config.MaxSpeedPerTick    = 0.35    -- Max metres/tick for normal shoulder following
Config.ReturnSpeedPerTick = 0.12    -- Max metres/tick when returning from far away (~7m/s)
Config.ReturnThreshold    = 3.0     -- Metres from target beyond which return speed is used
Config.BobAmount          = 0.04    -- Hover bob amplitude in metres
Config.BobSpeed           = 1.5     -- Hover bob frequency
Config.RotationLerpSpeed  = 0.06    -- How fast drone yaw rotates toward travel direction
Config.HeadingFollowDelay = 1.8     -- Seconds player heading must settle before drone follows

-- ─── Deploy/Recall Animations ────────────────────────────────────────────────
Config.KneelDict     = 'amb@world_human_gardener_plant@male@base'
Config.KneelAnim     = 'base'
Config.KneelDuration = 3000            -- milliseconds (0 = no kneel delay)

-- ─── Drone Storage (Inventory) ───────────────────────────────────────────────
Config.StorageSlots  = 6
Config.StorageWeight = 5000         -- in grams (ox_inventory units)

-- ─── Drone Healing ───────────────────────────────────────────────────────────
Config.HealEnabled       = true
Config.HealAmount        = 10       -- Health points restored per heal tick
Config.HealRadius        = 5.0      -- Metres around drone to heal players
Config.HealInterval      = 5        -- Seconds between each heal tick on a target
Config.HealCooldown      = 30       -- Seconds before same player can be healed again

-- ─── Drone Control (FPV mode) ────────────────────────────────────────────────
Config.ControlMaxRange         = 400.0  -- GTA units the drone can fly from the player
Config.ControlMoveSpeed        = 0.1   -- How fast drone moves when player controlled
Config.ControlAscendSpeed      = 0.1   -- Ascend/descend speed
Config.ControlYawSensitivity   = 10.0  -- Mouse horizontal turn speed (lower = slower)
Config.ControlPitchSensitivity = 8.0  -- Mouse vertical look speed (lower = slower)
Config.ControlCamOffsetZ       = -0.16  -- Camera height on drone (~3 inches below centre)

-- ─── Drone Damage & Health ───────────────────────────────────────────────────
Config.DamageEnabled        = true
Config.DroneMaxHealth       = 600      -- Maximum drone health points
Config.DroneWreckModel      = 'm23_2_prop_m32_drone_brk_01a'  -- prop swapped to on destruction
Config.DroneDeadModel       = 'ch_prop_casino_drone_broken01a' -- prop when battery removed (could just use same as xs_prop_arena_drone_02 so it looks the same)
Config.WreckCleanupMinutes  = 5       -- Minutes before a wrecked/abandoned drone prop is removed

-- ─── Battery System ──────────────────────────────────────────────────────────
-- Battery system: drone requires a drone_battery item in its stash to operate.
-- A battery is automatically placed in the stash on first deploy.
-- When depleted, the item is removed — player must place a new one to continue.
-- Drain is per-second. At 0.025/s a full charge lasts ~66 minutes.
Config.BatteryEnabled        = true
Config.BatteryItem           = 'drone_battery'        -- charged battery item name
Config.BatteryEmptyItem      = 'drone_battery_empty'  -- depleted battery item name (swapped in when dead)
Config.BatteryDrainIdle      = 0               -- Drain per second when hovering still
Config.BatteryDrainMoving    = 0.025           -- Drain per second when active (~66 mins full charge)
Config.BatteryLowThreshold   = 10             -- % remaining to trigger low battery warning
Config.BatteryLowSoundEvery  = 180            -- Seconds between low battery sound alerts
Config.BatteryPollInterval   = 5              -- Seconds between stash checks when grounded/waiting for battery

-- ─── Sounds ──────────────────────────────────────────────────────────────────
Config.FlightSoundEnabled = true   -- default state for drone motor sound (player can toggle via target menu)
-- Uses GTA native audio: AudioName = "Flight_Loop", AudioRef = "DLC_BTL_Drone_Sounds"
-- No external sound files needed.
Config.Sound = {
    FlyLoop          = 'Flight_Loop',           -- looping flight sound attached to drone entity
    AudioRef         = 'DLC_BTL_Drone_Sounds',  -- audio bank reference
	--
    GuardActivate    = 'Security_Box_Online',       -- played when guard mode is toggled on
    GuardAudioRef    = 'dlc_ch_heist_finale_security_alarms_sounds',
    GuardDeactivate  = 'Security_Box_Offline_Tazer', -- played when guard mode is toggled off
    GuardDeactAudioRef = 'dlc_ch_heist_finale_security_alarms_sounds',
    FlipSound        = 'Win',                        -- played when drone flip is triggered
    FlipAudioRef     = 'dlc_vw_casino_lucky_wheel_sounds',
}

-- ─── Guard Mode ───────────────────────────────────────────────────────────────
-- When active, the drone automatically fires at any entity that enters the radius.
-- Bullets are fired from the drone position using ShootSingleBulletBetweenCoords.
Config.GuardEnabled     = true
Config.GuardWeapon      = 'WEAPON_SMG'  -- any valid GTA weapon hash string
Config.GuardRadius      = 5.0   -- metres around drone to scan for targets
Config.GuardDamage      = 5     -- damage per bullet
Config.GuardAutomatic   = false  -- true = full auto, false = burst or single
Config.GuardBurst       = true   -- true = burst fire, false = single shot (ignored if automatic)
Config.GuardBurstCount  = 3      -- bullets per burst (only used when GuardBurst = true)
Config.GuardFireRate    = 500   -- ms between bursts/shots (per target)

-- Entity types to target. Set to false to exclude.
Config.GuardTargets = {
    players = true,   -- other players
    peds    = true,   -- mission/ambient peds (gang members, cops, civilians)
    animals = true,  -- animal peds
}
