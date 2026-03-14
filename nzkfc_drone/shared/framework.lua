-- ─── Framework Auto-Detection ────────────────────────────────────────────────
-- Detects whether the server is running QBX (qbx_core) or ESX (es_extended)
-- and exposes a unified Framework table used across client and server scripts.
--
-- Usage (client & server):
--   Framework.isESX          -- true if ESX
--   Framework.isQBX          -- true if QBX
--
-- Usage (client only):
--   Framework.isDown()       -- true if local player is downed/dead
--   Framework.getJob()       -- returns current job name string (lowercase)
--   Framework.hasJob(jobs)   -- true if player's job matches any entry in jobs table
--   Framework.canUseOption(optionKey) -- checks Config.TargetJobOptions for this key

Framework = {}

-- Detect by checking which core resource is running
if GetResourceState('qbx_core') == 'started' then
    Framework.isQBX = true
    Framework.isESX = false
elseif GetResourceState('es_extended') == 'started' then
    Framework.isESX = true
    Framework.isQBX = false
else
    -- Fallback: assume ESX-compatible mode
    Framework.isESX = true
    Framework.isQBX = false
    print('[nzkfc_drone] WARNING: Could not detect framework (qbx_core/es_extended not found). Defaulting to ESX-compatible mode.')
end

-- ─── Client-only helpers ─────────────────────────────────────────────────────
if IsDuplicityVersion and not IsDuplicityVersion() then

    -- isDown(): true when the local player is downed or dead.
    if Framework.isQBX then
        function Framework.isDown()
            local state = LocalPlayer.state
            return state.isDown or state.isDead or IsPedDeadOrDying(PlayerPedId(), true)
        end
    else
        function Framework.isDown()
            return IsPedDeadOrDying(PlayerPedId(), true)
        end
    end

    -- ─── Job caching ─────────────────────────────────────────────────────────
    -- We maintain our own job cache so getJob() is always accurate regardless
    -- of when ESX/QBX updates their internal PlayerData table.
    --
    -- ESX: seeded from getSharedObject() on load (covers mid-session restarts),
    --      then kept current via esx:playerLoaded and esx:setJob events.
    --      esx:setJob fires BEFORE ESX updates PlayerData, so we read the new
    --      job directly from the event argument.
    --
    -- QBX: seeded from exports.qbx_core:GetPlayerData() on load, then kept
    --      current via QBCore:Client:OnJobUpdate which passes the new job
    --      as arg 1 — same pattern as ESX, no timing issues.

    local _cachedJob = ''  -- always lowercase, always a string

    if Framework.isESX then

        -- Seed from shared object on script load (handles restarts mid-session)
        local ok, _ESX = pcall(function()
            return exports['es_extended']:getSharedObject()
        end)
        if ok and _ESX and _ESX.PlayerData and _ESX.PlayerData.job then
            _cachedJob = _ESX.PlayerData.job.name:lower()
        elseif not ok then
            print('[nzkfc_drone] WARNING: Could not get ESX shared object. Error: ' .. tostring(_ESX))
        end

        -- esx:playerLoaded fires on initial login with the full player data table
        RegisterNetEvent('esx:playerLoaded')
        AddEventHandler('esx:playerLoaded', function(playerData)
            if playerData and playerData.job and playerData.job.name then
                _cachedJob = playerData.job.name:lower()
            end
        end)

        -- esx:setJob fires when the job changes — the NEW job is passed as arg 1.
        -- Read directly from the event arg since ESX updates PlayerData after firing.
        RegisterNetEvent('esx:setJob')
        AddEventHandler('esx:setJob', function(job, lastJob)
            if job and job.name then
                _cachedJob = job.name:lower()
                DroneTargeting.Refresh()
            end
        end)

        function Framework.getJob()
            return _cachedJob
        end

    else
        -- QBX: QBX.PlayerData starts as {} and is populated via QBCore:Player:SetPlayerData.
        -- We seed our cache from that event (covers both initial login and mid-session
        -- script restarts), then keep it current via QBCore:Client:OnJobUpdate which
        -- passes the new job table as arg 1 — no timing race with PlayerData.

        -- Seed on resource start via GetPlayerData (only works if already logged in)
        local ok, data = pcall(function()
            return exports['qbx_core']:GetPlayerData()
        end)
        if ok and data and data.job and data.job.name then
            _cachedJob = data.job.name:lower()
        end

        -- QBCore:Player:SetPlayerData fires when the full PlayerData is set.
        -- This covers initial login AND mid-session resource restarts.
        RegisterNetEvent('QBCore:Player:SetPlayerData')
        AddEventHandler('QBCore:Player:SetPlayerData', function(val)
            if val and val.job and val.job.name then
                _cachedJob = val.job.name:lower()
            end
        end)

        -- QBCore:Client:OnJobUpdate fires when the job changes in-game.
        -- The new job table is passed as arg 1 — read it directly.
        RegisterNetEvent('QBCore:Client:OnJobUpdate')
        AddEventHandler('QBCore:Client:OnJobUpdate', function(job)
            if job and job.name then
                _cachedJob = job.name:lower()
            end
            DroneTargeting.Refresh()
        end)

        function Framework.getJob()
            return _cachedJob
        end
    end

    -- hasJob(jobs): returns true if the player's current job matches any entry
    -- in the provided jobs table. If jobs is false/nil, always returns true
    -- (meaning unrestricted — everyone passes).
    function Framework.hasJob(jobs)
        if not jobs or jobs == false then return true end
        local current = Framework.getJob()
        for _, name in ipairs(jobs) do
            if name:lower() == current then return true end
        end
        return false
    end

    -- canUseOption(optionKey): checks Config.TargetJobOptions for the given
    -- ox_target option name. Returns true if the player is allowed to use it.
    -- Options not listed in Config.TargetJobOptions are unrestricted.
    function Framework.canUseOption(optionKey)
        if not Config.TargetJobOptions then return true end
        local restriction = Config.TargetJobOptions[optionKey]
        -- nil or false means no restriction
        if not restriction then return true end
        return Framework.hasJob(restriction)
    end

end

print(('[nzkfc_drone] Framework detected: %s'):format(Framework.isQBX and 'QBX' or 'ESX'))
