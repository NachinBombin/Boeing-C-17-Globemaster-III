if SERVER then
    AddCSLuaFile()

    util.AddNetworkString("BombinC17_FlareSpawned")

    local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

    local cv_enabled  = CreateConVar("npc_bombinc17_enabled",   "1",    SHARED_FLAGS, "Enable/disable C-17 support calls")
    local cv_chance   = CreateConVar("npc_bombinc17_chance",    "0.10", SHARED_FLAGS, "Probability per check")
    local cv_interval = CreateConVar("npc_bombinc17_interval",  "15",   SHARED_FLAGS, "Seconds between NPC checks")
    local cv_cooldown = CreateConVar("npc_bombinc17_cooldown",  "70",   SHARED_FLAGS, "Cooldown per NPC after calling")
    local cv_max_dist = CreateConVar("npc_bombinc17_max_dist",  "3500", SHARED_FLAGS, "Max call distance")
    local cv_min_dist = CreateConVar("npc_bombinc17_min_dist",  "400",  SHARED_FLAGS, "Min call distance")
    local cv_delay    = CreateConVar("npc_bombinc17_delay",     "6",    SHARED_FLAGS, "Flare to C-17 arrival delay")
    local cv_life     = CreateConVar("npc_bombinc17_lifetime",  "120",  SHARED_FLAGS, "C-17 lifetime seconds")
    local cv_speed    = CreateConVar("npc_bombinc17_speed",     "260",  SHARED_FLAGS, "C-17 forward speed HU/s")
    local cv_radius   = CreateConVar("npc_bombinc17_radius",    "4200", SHARED_FLAGS, "Orbit radius HU")
    local cv_height   = CreateConVar("npc_bombinc17_height",    "7000", SHARED_FLAGS, "Altitude above ground HU")
    local cv_announce = CreateConVar("npc_bombinc17_announce",  "0",    SHARED_FLAGS, "Debug prints")

    local CALLERS = {
        ["npc_combine_s"]     = true,
        ["npc_metropolice"]   = true,
        ["npc_combine_elite"] = true,
    }

    local function BSP_Debug(msg)
        if not cv_announce:GetBool() then return end
        local full = "[Bombin C-17] " .. tostring(msg)
        print(full)
        for _, ply in ipairs(player.GetHumans()) do
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, full) end
        end
    end

    local function RandomFlatDir()
        local ang = math.Rand(0, 360)
        return Vector(math.cos(math.rad(ang)), math.sin(math.rad(ang)), 0)
    end

    local function CheckSkyAbove(pos)
        local tr = util.TraceLine({
            start  = pos + Vector(0, 0, 50),
            endpos = pos + Vector(0, 0, 1050),
        })
        if tr.Hit and not tr.HitSky then
            tr = util.TraceLine({
                start  = tr.HitPos + Vector(0, 0, 50),
                endpos = tr.HitPos + Vector(0, 0, 1000),
            })
        end
        return not (tr.Hit and not tr.HitSky)
    end

    local function ThrowSupportFlare(npc, targetPos)
        local npcEyePos = npc:EyePos()
        local toTarget  = (targetPos - npcEyePos):GetNormalized()

        local flare = ents.Create("ent_bombin_flare_blue")
        if not IsValid(flare) then BSP_Debug("Flare spawn failed") return nil end

        flare:SetPos(npcEyePos + toTarget * 52)
        flare:SetAngles(npc:GetAngles())
        flare:Spawn()
        flare:Activate()

        local dir  = targetPos - flare:GetPos()
        local dist = dir:Length()
        dir:Normalize()

        timer.Simple(0, function()
            if not IsValid(flare) then return end
            local phys = flare:GetPhysicsObject()
            if not IsValid(phys) then return end
            phys:SetVelocity(dir * 700 + Vector(0, 0, dist * 0.25))
            phys:Wake()
        end)

        net.Start("BombinC17_FlareSpawned")
        net.WriteEntity(flare)
        net.Broadcast()

        BSP_Debug("Flare thrown")
        return flare
    end

    local function SpawnC17AtPos(centerPos)
        if not scripted_ents.GetStored("ent_bombin_c17") then
            BSP_Debug("ent_bombin_c17 not registered")
            return false
        end

        local c17 = ents.Create("ent_bombin_c17")
        if not IsValid(c17) then BSP_Debug("ents.Create returned invalid entity") return false end

        local randomDir = RandomFlatDir()

        c17:SetPos(centerPos)
        c17:SetAngles(randomDir:Angle())
        c17:SetVar("CenterPos",    centerPos)
        c17:SetVar("CallDir",      randomDir)
        c17:SetVar("Lifetime",     cv_life:GetFloat())
        c17:SetVar("Speed",        cv_speed:GetFloat())
        c17:SetVar("OrbitRadius",  cv_radius:GetFloat())
        c17:SetVar("SkyHeightAdd", cv_height:GetFloat())
        c17:Spawn()
        c17:Activate()

        if not IsValid(c17) then BSP_Debug("Entity invalid after Spawn()") return false end

        BSP_Debug("C-17 spawned at " .. tostring(centerPos) .. " dir " .. tostring(randomDir))
        return true
    end

    local function FireC17(npc, target)
        if not IsValid(npc) then BSP_Debug("NPC invalid") return false end
        if not IsValid(target) or not target:IsPlayer() or not target:Alive() then
            BSP_Debug("Target invalid") return false
        end

        local targetPos = target:GetPos() + Vector(0, 0, 36)
        if not CheckSkyAbove(targetPos) then BSP_Debug("No open sky above target") return false end

        local flare = ThrowSupportFlare(npc, targetPos)
        if not IsValid(flare) then BSP_Debug("Flare failed") return false end

        local fallbackPos = Vector(targetPos.x, targetPos.y, targetPos.z)

        timer.Simple(cv_delay:GetFloat(), function()
            local centerPos = IsValid(flare) and flare:GetPos() or fallbackPos
            SpawnC17AtPos(centerPos)
        end)

        return true
    end

    -- Manual spawn net receiver
    -- FIX (BUG-1): Gate on IsAdmin() — any unauthenticated client could
    -- previously spam-spawn C-17s by sending this net message directly.
    util.AddNetworkString("BombinC17_ManualSpawn")

    net.Receive("BombinC17_ManualSpawn", function(len, ply)
        if not IsValid(ply) then return end

        -- Security gate: only admins may manually spawn a C-17.
        if not ply:IsAdmin() then
            ply:PrintMessage(HUD_PRINTCENTER, "[Bombin C-17] Admins only!")
            return
        end

        local tr = util.TraceLine({
            start  = ply:EyePos(),
            endpos = ply:EyePos() + ply:EyeAngles():Forward() * 3000,
            filter = ply,
        })
        local centerPos = tr.Hit and tr.HitPos or (ply:GetPos() + Vector(0,0,100))
        local callDir   = ply:EyeAngles():Forward()
        callDir.z = 0
        if callDir:LengthSqr() <= 1 then callDir = Vector(1,0,0) end
        callDir:Normalize()

        if not scripted_ents.GetStored("ent_bombin_c17") then
            ply:PrintMessage(HUD_PRINTCENTER, "[Bombin C-17] Entity not registered!") return
        end

        local c17 = ents.Create("ent_bombin_c17")
        if not IsValid(c17) then
            ply:PrintMessage(HUD_PRINTCENTER, "[Bombin C-17] Spawn failed!") return
        end

        c17:SetPos(centerPos)
        c17:SetAngles(callDir:Angle())
        c17:SetVar("CenterPos",    centerPos)
        c17:SetVar("CallDir",      callDir)
        c17:SetVar("Lifetime",     cv_life:GetFloat())
        c17:SetVar("Speed",        cv_speed:GetFloat())
        c17:SetVar("OrbitRadius",  cv_radius:GetFloat())
        c17:SetVar("SkyHeightAdd", cv_height:GetFloat())
        c17:Spawn()
        c17:Activate()

        ply:PrintMessage(HUD_PRINTCENTER, "[Bombin C-17] C-17 inbound!")
    end)

    -- NPC poll timer
    timer.Create("BombinC17_Think", 0.5, 0, function()
        if not cv_enabled:GetBool() then return end

        local now      = CurTime()
        local interval = math.max(1, cv_interval:GetFloat())

        for _, npc in ipairs(ents.GetAll()) do
            if not IsValid(npc) or not CALLERS[npc:GetClass()] then continue end

            if not npc.__bombinc17_hooked then
                npc.__bombinc17_hooked    = true
                npc.__bombinc17_nextCheck = now + math.Rand(1, interval)
                npc.__bombinc17_lastCall  = 0
            end

            if now < npc.__bombinc17_nextCheck then continue end

            local jitter = math.min(2, interval * 0.5)
            npc.__bombinc17_nextCheck = now + interval + math.Rand(-jitter, jitter)

            if now - npc.__bombinc17_lastCall < cv_cooldown:GetFloat() then continue end
            if npc:Health() <= 0 then continue end

            local enemy = npc:GetEnemy()
            if not IsValid(enemy) or not enemy:IsPlayer() or not enemy:Alive() then continue end

            local dist = npc:GetPos():Distance(enemy:GetPos())
            if dist > cv_max_dist:GetFloat() or dist < cv_min_dist:GetFloat() then continue end

            if math.random() > cv_chance:GetFloat() then continue end

            if FireC17(npc, enemy) then
                npc.__bombinc17_lastCall = now
                BSP_Debug("Call accepted targeting " .. tostring(enemy))
            end
        end
    end)

end -- SERVER

-- CLIENT: flare dynamic light
if CLIENT then
    local activeFlares = {}

    net.Receive("BombinC17_FlareSpawned", function()
        local flare = net.ReadEntity()
        if IsValid(flare) then activeFlares[flare:EntIndex()] = flare end
    end)

    hook.Add("Think", "BombinC17_FlareLight", function()
        for idx, flare in pairs(activeFlares) do
            if not IsValid(flare) then activeFlares[idx] = nil continue end
            local dlight = DynamicLight(flare:EntIndex())
            if dlight then
                dlight.Pos        = flare:GetPos()
                dlight.r          = 0
                dlight.g          = 80
                dlight.b          = 255
                dlight.Brightness = (math.random() > 0.4) and math.Rand(4.0, 6.0) or math.Rand(0.0, 0.2)
                dlight.Size       = 55
                dlight.Decay      = 3000
                dlight.DieTime    = CurTime() + 0.05
            end
        end
    end)
end
