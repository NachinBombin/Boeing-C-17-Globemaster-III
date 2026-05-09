AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_trailsystem.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- MODEL / FLIGHT ORIENTATION NOTES
-- The C-17 model nose points along LOCAL +X.
-- MODEL_YAW_OFFSET = -90 aligns the visual nose with flightYaw.
-- bank  (wing tilt)   = GMod Angle.p   (negative sign: right turn -> right wing down)
-- pitch (nose up/dn)  = GMod Angle.r
-- Final angle: Angle( -SmoothedRoll, flightYaw+OFFSET, -SmoothedPitch )
-- ============================================================
local MODEL_YAW_OFFSET = -90

local ROLL_SUSTAINED_GAIN = 2.2
local ROLL_TRANSIENT_GAIN = 55.0
local ROLL_MAX            = 22.0
local ROLL_LERP_IN        = 0.08
local ROLL_LERP_OUT       = 0.012

local ENGINE_LOOP_SOUND = "sound/b52/b52.wav"

local MODEL_SCALE = 1.8

-- ============================================================
-- SW MUNITIONS CATALOGUE
-- ============================================================
-- Window IDs (active):
--   W1 "jassm"   -- AGM-158 JASSM parachute drop
--   W2 "heavy"   -- heavy GP / penetrators
--   W3 "gbu53"   -- GBU-53 parachute cluster drop  (replaces old medium carpet)
--   W6 "retarded"-- parachute / retarder bombs
--
-- Removed:
--   W4 "light"     -- REMOVED
--   W5 "hellfire"  -- REMOVED
--   W3 "medium"    -- REPLACED by gbu53
-- ============================================================

local DART_SPEED  = 4500
local GRAVITY_EST = 580

-- ---------- General config ----------
local CFG_MaxHP        = 450
local CFG_FadeDuration = 3.0
local CFG_PeacefulMin  = 6
local CFG_PeacefulMax  = 14

local CFG_BombBayLocal = Vector(0, 0, -35)

-- Orbit / target-tracking tuning.
local TARGET_ORBIT_RADIUS        = 1800
local TARGET_ORBIT_RADIUS_MIN    = 1200
local TARGET_ORBIT_RADIUS_MAX    = 2600
local TARGET_CENTER_LERP         = 0.035
local TARGET_LOOKAHEAD_TIME      = 2.25
local TARGET_MAX_LOOKAHEAD_DIST  = 1200
local TARGET_REACQUIRE_INTERVAL  = 0.35
local TARGET_PASS_BIAS           = 0.55

-- ---------- W1 -- JASSM parachute drop (AC-130 pattern) ----------
local CFG_W1_JASSM_Count      = 1
local CFG_W1_JASSM_Delay      = 0
local CFG_W1_JASSM_TailOffset = Vector(-60, 0, 0)
local CFG_W1_JASSM_SkyAdd     = 0

-- ---------- W2 -- Heavy ordnance ----------
local CFG_W2_Count   = 2
local CFG_W2_Delay   = 4.0
local CFG_W2_Scatter = 0
local CFG_W2_Pool    = {
    "sw_bomb_gbu43_v3",
    "sw_bomb_gbu57_v3",
    "sw_bomb_m118_v3",
    "sw_bomb_anm56_v3",
    "sw_bomb_anm66_v3",
    "sw_bomb_mk84_v3",
    "sw_bomb_mk84_air_v3",
    "sw_bomb_anmk1_v3",
}

-- ---------- W3 -- GBU-53 parachute cluster (replaces medium carpet) ----------
-- Each "shot" drops one ent_bombin_gbu53_owned which handles the
-- chute+palette assembly internally and loiters after ignition.
local CFG_W3_GBU53_Count  = 3          -- pallets per window
local CFG_W3_GBU53_Delay  = 1.2        -- seconds between pallets
local CFG_W3_AltStagger   = 400        -- altitude separation per pallet (units)
local CFG_W3_DropOffset   = Vector(-60, 0, 0)  -- local drop point (bomb bay)
local CFG_W3_BodyClearance = 220       -- extra downward clearance below aircraft body for pallet 0

-- ---------- W6 -- Retarded / Parachute bombs ----------
local CFG_W6_Count   = 6
local CFG_W6_Delay   = 0.55
local CFG_W6_Scatter = 100
local CFG_W6_Pool    = {
    "sw_bomb_mk81_snakeye_v3",
    "sw_bomb_mk82_snakeye_v3",
    "sw_bomb_mk82_air_v3",
    "sw_bomb_mk84_air_v3",
}

-- Weapon roster used by PickNewWeapon
local WEAPON_ROSTER = { "jassm", "heavy", "gbu53", "retarded" }

-- ============================================================
-- NETWORK STRING
-- ============================================================
util.AddNetworkString("bombin_c17_damage_tier")

local function CalcTier(hp, maxHP)
    local f = hp / maxHP
    if f > 0.66 then return 0 elseif f > 0.33 then return 1 elseif f > 0 then return 2 else return 3 end
end
local function BroadcastTier(ent, tier)
    net.Start("bombin_c17_damage_tier")
    net.WriteUInt(ent:EntIndex(), 16)
    net.WriteUInt(tier, 2)
    net.Broadcast()
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
    self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
    self.CallDir      = self:GetVar("CallDir",      Vector(1,0,0))
    self.Lifetime     = self:GetVar("Lifetime",     120)
    self.Speed        = self:GetVar("Speed",        260)
    self.OrbitRadius  = self:GetVar("OrbitRadius",  TARGET_ORBIT_RADIUS)
    self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 7000)

    self.MaxHP        = CFG_MaxHP
    self.FadeDuration = CFG_FadeDuration

    if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
    self.CallDir.z = 0
    self.CallDir:Normalize()

    local ground = self:FindGround(self.CenterPos)
    if ground == -1 then ground = self.CenterPos.z end

    self.sky       = ground + self.SkyHeightAdd
    self.DieTime   = CurTime() + self.Lifetime
    self.SpawnTime = CurTime()

    self.OrbitRadius = math.Clamp(self.OrbitRadius, TARGET_ORBIT_RADIUS_MIN, TARGET_ORBIT_RADIUS_MAX)
    self.DynamicCenterPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z)
    self.TargetEnt = nil
    self.TargetVel = Vector(0, 0, 0)
    self.LastTargetSampleTime = CurTime()
    self.NextTargetRefresh = 0

    self.OrbitDirection = (math.random(2) == 1) and 1 or -1

    local right   = Vector(-self.CallDir.y, self.CallDir.x, 0)
    local tangent = Vector(right.x * self.OrbitDirection, right.y * self.OrbitDirection, 0)
    tangent:Normalize()

    local spawnOffset = tangent * (-self.OrbitRadius * math.Rand(0.75, 1.05))
    local spawnPos    = Vector(
        self.CenterPos.x + spawnOffset.x,
        self.CenterPos.y + spawnOffset.y,
        self.sky
    )
    if not util.IsInWorld(spawnPos) then
        spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
    end
    if not util.IsInWorld(spawnPos) then
        self:Debug("Spawn position out of world") self:Remove() return
    end

    self:SetModel("models/custom/c17_anim_compliment.mdl")
    self:SetModelScale(MODEL_SCALE)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
    self:SetPos(spawnPos)
    self:SetBodygroup(1, 1)
    self:SetRenderMode(RENDERMODE_TRANSALPHA)
    self:SetColor(Color(255, 255, 255, 0))

    self:SetNWInt("HP",    self.MaxHP)
    self:SetNWInt("MaxHP", self.MaxHP)

    self.flightYaw    = tangent:Angle().y
    self.PrevTurnRate = 0
    self.SmoothedRoll  = 0
    self.SmoothedPitch = 0
    self.ang = Angle(0, self.flightYaw + MODEL_YAW_OFFSET, 0)

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    self.AltDriftRange    = 500
    self.AltDriftLerp     = 0.001
    self.JitterPhase      = math.Rand(0, math.pi * 2)
    self.JitterAmplitude  = 8

    self.WPN_Active     = nil
    self.WPN_ShotsFired = 0
    self.WPN_NextShot   = 0
    self.WPN_WindowEnd  = 0
    self.WPN_PeaceUntil = CurTime() + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)

    self.HP           = self.MaxHP
    self.DamageTier   = 0
    self.DestroyStart = nil
    self.Destroyed    = false

    self.FadeAlpha    = 0
    self.FadeIn       = true

    self.JASSM_Stock  = 6

    self.EngineSound = CreateSound(self, ENGINE_LOOP_SOUND)
    if self.EngineSound then
        self.EngineSound:PlayEx(0.9, 95)
    end

    self:SetNWBool("Destroyed", false)

    self.WanderPhaseX = math.Rand(0, math.pi * 2)
    self.WanderPhaseY = math.Rand(0, math.pi * 2)
    self.WanderAmp    = math.Rand(80, 200)
    self.WanderRateX  = math.Rand(0.003, 0.009)
    self.WanderRateY  = math.Rand(0.002, 0.007)
    self.BaseCenterPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z)

    self.SkyYawBias      = 0
    self.SkyProbeDist    = math.max(1400, self.Speed * 6)
    self.SkyProbeLastHit = 0
    self.ObsLastEval     = 0
    self.ObsYawBias      = 0
    self.ObsConsecHits   = 0

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:EnableGravity(false)
        self.PhysObj:Wake()
        local initVel = tangent * self.Speed
        initVel.z = 0
        self.PhysObj:SetVelocity(initVel)
    end

    self.OrbitAngle    = math.atan2(spawnOffset.y, spawnOffset.x)
    self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDirection

    self:Debug("C-17 spawned, orbit radius=" .. self.OrbitRadius .. " sky=" .. self.sky)
end

-- ============================================================
-- DEBUG
-- ============================================================
function ENT:Debug(msg)
    print("[Bombin C-17] " .. tostring(msg))
end

-- ============================================================
-- FINDGROUND
-- ============================================================
function ENT:FindGround(pos)
    local tr = util.TraceLine({
        start  = Vector(pos.x, pos.y, pos.z + 100),
        endpos = Vector(pos.x, pos.y, pos.z - 32768),
        filter = function(e) return e:IsWorld() end,
        mask   = MASK_SOLID_BRUSHONLY,
    })
    if tr.Hit then return tr.HitPos.z end
    return -1
end

-- ============================================================
-- TARGET TRACKING
-- ============================================================
function ENT:RefreshTarget(ct)
    if ct < self.NextTargetRefresh then return self.TargetEnt end
    self.NextTargetRefresh = ct + TARGET_REACQUIRE_INTERVAL

    local closest, closestDist = nil, math.huge
    local selfPos = self:GetPos()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local d = ply:GetPos():DistToSqr(selfPos)
        if d < closestDist then
            closestDist = d
            closest = ply
        end
    end

    self.TargetEnt = closest
    return closest
end

-- ============================================================
-- ORBIT PHYSICS
-- ============================================================
function ENT:UpdateOrbit(ct, dt)
    local phys = self.PhysObj
    if not IsValid(phys) then
        self.PhysObj = self:GetPhysicsObject()
        phys = self.PhysObj
    end
    if not IsValid(phys) then return end
    if phys:IsAsleep() then phys:Wake() end

    -- Dynamic centre wander
    self.WanderPhaseX = self.WanderPhaseX + self.WanderRateX
    self.WanderPhaseY = self.WanderPhaseY + self.WanderRateY
    self.DynamicCenterPos.x = self.BaseCenterPos.x + math.sin(self.WanderPhaseX) * self.WanderAmp
    self.DynamicCenterPos.y = self.BaseCenterPos.y + math.cos(self.WanderPhaseY) * self.WanderAmp

    -- Target-based centre pull
    local target = self:RefreshTarget(ct)
    if IsValid(target) then
        local tPos = target:GetPos()
        local tVelNow = target:GetVelocity()
        local lookahead = math.min(tVelNow:Length() * TARGET_LOOKAHEAD_TIME, TARGET_MAX_LOOKAHEAD_DIST)
        local predictedPos = tPos + tVelNow:GetNormalized() * lookahead
        local biasFwd = Angle(0, self.flightYaw, 0):Forward() * (self.OrbitRadius * TARGET_PASS_BIAS)
        local desiredCenter = Vector(
            predictedPos.x + biasFwd.x,
            predictedPos.y + biasFwd.y,
            self.DynamicCenterPos.z
        )
        self.DynamicCenterPos.x = Lerp(TARGET_CENTER_LERP, self.DynamicCenterPos.x, desiredCenter.x)
        self.DynamicCenterPos.y = Lerp(TARGET_CENTER_LERP, self.DynamicCenterPos.y, desiredCenter.y)
    end

    -- Advance orbit angle
    self.OrbitAngle = self.OrbitAngle + self.OrbitAngSpeed * dt

    local desX = self.DynamicCenterPos.x + math.cos(self.OrbitAngle) * self.OrbitRadius
    local desY = self.DynamicCenterPos.y + math.sin(self.OrbitAngle) * self.OrbitRadius

    -- Altitude drift
    if ct >= self.AltDriftNextPick then
        self.AltDriftNextPick = ct + math.Rand(12, 30)
        self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

    -- Jitter
    self.JitterPhase = self.JitterPhase + dt * 1.3
    local jitterZ = math.sin(self.JitterPhase) * self.JitterAmplitude

    local desZ  = self.AltDriftCurrent + jitterZ
    local curPos = self:GetPos()
    local velZ  = math.Clamp((desZ - curPos.z) * 8, -120, 120)

    -- Sky clearance raycast
    if ct - self.SkyProbeLastHit > 0.3 then
        local fwd = Angle(0, self.flightYaw, 0):Forward()
        local probeEnd = curPos + fwd * self.SkyProbeDist
        local tr = util.TraceLine({
            start  = curPos,
            endpos = probeEnd,
            filter = function(e) return e ~= self end,
            mask   = MASK_SOLID_BRUSHONLY,
        })
        if tr.Hit then
            self.SkyYawBias   = self.SkyYawBias + (30 * self.OrbitDirection * dt)
            self.SkyProbeLastHit = ct
        else
            self.SkyYawBias = self.SkyYawBias * (1 - dt * 0.3)
        end
    end

    local desiredYaw  = math.deg(self.OrbitAngle + (math.pi / 2) * self.OrbitDirection) + self.SkyYawBias
    local prevYaw     = self.flightYaw
    self.flightYaw    = desiredYaw

    -- Angular velocity for bank calculation
    local yawDelta    = math.NormalizeAngle(desiredYaw - prevYaw)
    local turnRate    = yawDelta / math.max(dt, 0.001)
    self.PrevTurnRate = Lerp(0.15, self.PrevTurnRate, turnRate)

    local targetRoll  = -math.Clamp(self.PrevTurnRate * ROLL_SUSTAINED_GAIN + turnRate * ROLL_TRANSIENT_GAIN, -ROLL_MAX, ROLL_MAX)
    local rollLerp    = (math.abs(targetRoll) > math.abs(self.SmoothedRoll)) and ROLL_LERP_IN or ROLL_LERP_OUT
    self.SmoothedRoll = Lerp(rollLerp, self.SmoothedRoll, targetRoll)

    local curVel  = phys:GetVelocity()
    local desVelX = math.cos(math.rad(desiredYaw)) * self.Speed
    local desVelY = math.sin(math.rad(desiredYaw)) * self.Speed
    local newVel  = Vector(
        Lerp(0.12, curVel.x, desVelX),
        Lerp(0.12, curVel.y, desVelY),
        velZ
    )
    phys:SetVelocity(newVel)

    self.ang = Angle(-self.SmoothedRoll, self.flightYaw + MODEL_YAW_OFFSET, -self.SmoothedPitch)
    self:SetAngles(self.ang)
end

-- ============================================================
-- FADE-IN
-- ============================================================
function ENT:UpdateFade(dt)
    if not self.FadeIn then return end
    self.FadeAlpha = math.min(self.FadeAlpha + dt / self.FadeDuration * 255, 255)
    self:SetColor(Color(255, 255, 255, math.floor(self.FadeAlpha)))
    if self.FadeAlpha >= 255 then
        self:SetRenderMode(RENDERMODE_NORMAL)
        self.FadeIn = false
    end
end

-- ============================================================
-- WEAPON SYSTEM
-- ============================================================
function ENT:PickNewWeapon()
    if #WEAPON_ROSTER == 0 then return end
    local w = WEAPON_ROSTER[math.random(#WEAPON_ROSTER)]
    if w == "jassm" and self.JASSM_Stock <= 0 then
        w = WEAPON_ROSTER[math.random(#WEAPON_ROSTER)]
    end
    self.WPN_Active     = w
    self.WPN_ShotsFired = 0
    self.WPN_NextShot   = CurTime()
    self.WPN_WindowEnd  = CurTime() + 12
    self:Debug("Weapon window: " .. w)
end

function ENT:UpdateWeapons(ct)
    if ct < self.WPN_PeaceUntil then return end

    if not self.WPN_Active then
        self:PickNewWeapon()
        return
    end

    if ct > self.WPN_WindowEnd then
        self.WPN_Active = nil
        self.WPN_PeaceUntil = ct + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)
        return
    end

    local w    = self.WPN_Active
    local done = false

    if     w == "jassm"    then done = self:UpdateJASSM(ct)
    elseif w == "heavy"    then done = self:UpdateHeavy(ct)
    elseif w == "gbu53"    then done = self:UpdateGBU53(ct)
    elseif w == "retarded" then done = self:UpdateRetarded(ct)
    end

    if done then
        self.WPN_Active = nil
        self.WPN_PeaceUntil = ct + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)
    end
end

-- ============================================================
-- THINK
-- ============================================================
function ENT:Think()
    if not self.DieTime then self:NextThink(CurTime() + 0.1) return true end

    local ct = CurTime()
    if ct >= self.DieTime then
        self:DestroyPlane()
        return
    end

    local dt = FrameTime()
    if dt <= 0 then dt = 0.015 end

    if self.Destroyed then
        self:NextThink(ct + 0.05)
        return true
    end

    self:UpdateFade(dt)
    self:UpdateOrbit(ct, dt)
    self:UpdateWeapons(ct)

    self:NextThink(ct + 0.015)
    return true
end

function ENT:PhysicsUpdate(phys, dt)
    -- Keep physics object awake; actual velocity driven in UpdateOrbit
end

-- ============================================================
-- DAMAGE
-- ============================================================
function ENT:OnTakeDamage(dmginfo)
    if self.Destroyed then return end
    local dmg = dmginfo:GetDamage()
    self.HP = math.max(self.HP - dmg, 0)
    self:SetNWInt("HP", self.HP)

    local tier = CalcTier(self.HP, self.MaxHP)
    if tier ~= self.DamageTier then
        self.DamageTier = tier
        BroadcastTier(self, tier)
    end

    if self.HP <= 0 then
        self:DestroyPlane()
    end
end

-- ============================================================
-- DESTROY
-- ============================================================
function ENT:DestroyPlane()
    if self.Destroyed then return end
    self.Destroyed = true
    self:SetNWBool("Destroyed", true)
    BroadcastTier(self, 3)

    if self.EngineSound then
        self.EngineSound:Stop()
        self.EngineSound = nil
    end

    local pos = self:GetPos()
    local expEd = EffectData()
    expEd:SetOrigin(pos)
    expEd:SetScale(4)
    util.Effect("HelicopterMegaBomb", expEd, true, true)
    sound.Play("ambient/explosions/explode_8.wav", pos, 145, 90, 1.0)

    -- Debris
    local debrisModels = {
        "models/props_c17/FurnitureDrawer001a.mdl",
        "models/props_c17/FurnitureCouch001a.mdl",
    }
    for i = 1, 4 do
        local deb = ents.Create("prop_physics")
        if IsValid(deb) then
            deb:SetModel(debrisModels[math.random(#debrisModels)])
            deb:SetPos(pos + Vector(math.Rand(-200, 200), math.Rand(-200, 200), math.Rand(-100, 100)))
            deb:SetAngles(Angle(math.Rand(0,360), math.Rand(0,360), math.Rand(0,360)))
            deb:Spawn()
            deb:Activate()
            local dp = deb:GetPhysicsObject()
            if IsValid(dp) then
                dp:SetVelocity(Vector(math.Rand(-300,300), math.Rand(-300,300), math.Rand(100,400)))
            end
            timer.Simple(8, function() if IsValid(deb) then deb:Remove() end end)
        end
    end

    timer.Simple(3.0, function()
        if IsValid(self) then self:Remove() end
    end)
end

-- ============================================================
-- REMOVE
-- ============================================================
function ENT:OnRemove()
    if self.EngineSound then
        self.EngineSound:Stop()
        self.EngineSound = nil
    end
end

-- ============================================================
-- BOMB HELPERS
-- ============================================================
local function CalcDartVelocity(dropPos, targetPos)
    local dir = targetPos - dropPos
    local H   = math.max(dropPos.z - targetPos.z, 100)
    local hDist = Vector(dir.x, dir.y, 0):Length()
    local tFall = math.sqrt(2 * H / GRAVITY_EST)
    local hSpeed = (hDist > 0) and math.min(hDist / math.max(tFall, 0.1), DART_SPEED) or 0
    local hDir   = Vector(dir.x, dir.y, 0):GetNormalized()
    return Vector(hDir.x * hSpeed, hDir.y * hSpeed, 0)
end

local function CalcCarpetImpulse(dropPos, aimPos, aircraftFwdVel)
    local H  = math.max(dropPos.z - aimPos.z, 100)
    local tF = math.sqrt(2 * H / GRAVITY_EST)
    local dx = aimPos.x - dropPos.x
    local dy = aimPos.y - dropPos.y
    local hDist = math.sqrt(dx*dx + dy*dy)
    if hDist < 1 then return Vector(0,0,0) end
    local hSpeed = hDist / math.max(tF, 0.1)
    hSpeed = math.min(hSpeed, DART_SPEED)
    local hDir = Vector(dx, dy, 0):GetNormalized()
    return Vector(hDir.x * hSpeed, hDir.y * hSpeed, 0)
end

function ENT:GetAimPos(scatter)
    scatter = scatter or 0
    local target = self:RefreshTarget(CurTime())
    if IsValid(target) then
        local p = target:GetPos()
        if scatter > 0 then
            p = p + Vector(math.Rand(-scatter, scatter), math.Rand(-scatter, scatter), 0)
        end
        return p
    end
    local cp = self.CenterPos
    if scatter > 0 then
        cp = cp + Vector(math.Rand(-scatter * 3, scatter * 3), math.Rand(-scatter * 3, scatter * 3), 0)
    end
    return cp
end

function ENT:SpawnDartBomb(entClass, dropPos, targetPos, isRetarded)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("SpawnDartBomb: class not found: " .. tostring(entClass))
        return
    end
    local toTarget = targetPos - dropPos
    local dropAng
    if toTarget:Length() > 10 then
        dropAng = toTarget:Angle()
    else
        dropAng = Angle(90, 0, 0)
    end
    bomb:SetPos(dropPos)
    bomb:SetAngles(dropAng)
    bomb:Spawn()
    bomb:Activate()
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        if isRetarded then
            bPhys:SetVelocity(CalcCarpetImpulse(dropPos, targetPos, Angle(0, self.flightYaw, 0):Forward() * self.Speed))
        else
            bPhys:SetVelocity(CalcDartVelocity(dropPos, targetPos))
        end
    end
end

function ENT:SpawnCarpetBomb(entClass, dropPos, aimPos)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("SpawnCarpetBomb: class not found: " .. tostring(entClass))
        return
    end
    bomb:SetPos(dropPos)
    bomb:SetAngles(Angle(90, self.flightYaw, 0))
    bomb:Spawn()
    bomb:Activate()
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        local aircraftFwd = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        bPhys:SetVelocity(CalcCarpetImpulse(dropPos, aimPos, aircraftFwd))
    end
end

-- ============================================================
-- W1: JASSM PARACHUTE DROP
-- ============================================================
function ENT:SpawnOneJASSM(dropIndex)
    dropIndex = dropIndex or 0

    local dropPos = self:LocalToWorld(CFG_W1_JASSM_TailOffset)
    dropPos.z = self:GetPos().z - (dropIndex * 500)

    local missile = ents.Create("ent_bombin_jassm_owned")
    if not IsValid(missile) then
        self:Debug("W1 JASSM: ent_bombin_jassm_owned not found - is the AC-130 addon installed?")
        return
    end

    missile:SetVar("CenterPos",    self.CenterPos)
    missile:SetVar("CallDir",      Angle(0, self.flightYaw, 0):Forward())
    missile:SetVar("SkyHeightAdd", self.SkyHeightAdd)
    missile:SetVar("OrbitRadius",  self.OrbitRadius)
    missile:SetOwner(self)
    missile.IsOnPlane = true
    missile.Launcher  = self

    missile:SetPos(dropPos)
    missile:SetAngles(Angle(0, self.flightYaw, 0))
    missile.SpawnedFromPlane = true  -- FIX: tell the missile to use the tail pos we just set
    missile:Spawn()
    missile:Activate()

    local mPhys = missile:GetPhysicsObject()
    if IsValid(mPhys) then
        local fwdVel = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        fwdVel.z = 0
        mPhys:SetVelocity(fwdVel)
    end

    constraint.NoCollide(missile, self, 0, 0)
    local mRef = missile
    timer.Simple(1.0, function()
        if IsValid(mRef) and IsValid(self) then constraint.RemoveConstraints(mRef, "NoCollide") end
    end)

    local chute = ents.Create("ent_bombin_jassm_chute_owned")
    if IsValid(chute) then
        chute:SetVar("MissileEnt", missile)
        chute:SetOwner(missile)  -- FIX: chute tracks the missile, not the plane
        chute:SetPos(dropPos + Vector(0, 0, 105))
        chute:SetAngles(Angle(0, self.flightYaw, 0))
        chute:Spawn()
        chute:Activate()
        chute.MissileEnt = missile
        constraint.NoCollide(chute, self, 0, 0)
        constraint.NoCollide(chute, missile, 0, 0)
        local cRef = chute
        timer.Simple(1.0, function()
            if IsValid(cRef) and IsValid(self) then constraint.RemoveConstraints(cRef, "NoCollide") end
        end)
    else
        self:Debug("W1 JASSM: ent_bombin_jassm_chute_owned not found - chute will be missing")
    end

    self:Debug("W1 JASSM drop #" .. (dropIndex+1) .. " pos=" .. tostring(dropPos))
end

function ENT:UpdateJASSM(ct)
    if self.WPN_ShotsFired >= CFG_W1_JASSM_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W1_JASSM_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneJASSM(self.WPN_ShotsFired - 1)
    return (self.WPN_ShotsFired >= CFG_W1_JASSM_Count)
end

-- ============================================================
-- W2: HEAVY ORDNANCE
-- ============================================================
function ENT:UpdateHeavy(ct)
    if self.WPN_ShotsFired >= CFG_W2_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W2_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1

    local entClass = CFG_W2_Pool[math.random(#CFG_W2_Pool)]
    local dropPos   = self:LocalToWorld(CFG_BombBayLocal)
    local targetPos = self:GetAimPos(CFG_W2_Scatter)
    self:SpawnDartBomb(entClass, dropPos, targetPos, false)
    return (self.WPN_ShotsFired >= CFG_W2_Count)
end

-- ============================================================
-- W3: GBU-53 PARACHUTE CLUSTER DROP
--
-- Spawns ent_bombin_gbu53_owned: the missile/loiter unit that
-- internally manages its own chute+palette assembly via SpawnChute().
-- Each GBU-53 freefalls, ignites at altitude, then loiters and dives.
--
-- Dependency: ent_bombin_gbu53_owned + ent_bombin_gbu53_chute_owned
-- from NachinBombin/Current-Ac-Model.
-- ============================================================
function ENT:SpawnOneGBU53Pallet(palletIndex)
    palletIndex = palletIndex or 0

    -- Drop from the aircraft-defined local release point, but force the
    -- initial Z below the fuselage so pallet 0 never spawns inside the body.
    -- Additional pallets are staggered further down from that cleared point.
    local dropPos = self:LocalToWorld(CFG_W3_DropOffset)
    dropPos.z = self:GetPos().z - CFG_W3_BodyClearance - (palletIndex * CFG_W3_AltStagger)

    -- FIX: spawn ent_bombin_gbu53_owned (the missile/loiter unit).
    -- ent_bombin_gbu53_owned handles its own chute via SpawnChute() internally,
    -- so spawning ent_bombin_gbu53_chute_owned directly here was wrong:
    -- the chute's Think() calls GetOwner() expecting a GBU53 missile entity,
    -- not the C17 plane, causing it to latch onto and follow the aircraft.
    local pallet = ents.Create("ent_bombin_gbu53_owned")
    if not IsValid(pallet) then
        self:Debug("W3 GBU53: ent_bombin_gbu53_owned not found - is Current-Ac-Model installed?")
        return
    end

    pallet:SetVar("CenterPos",    self.CenterPos)
    pallet:SetVar("CallDir",      Angle(0, self.flightYaw, 0):Forward())
    pallet:SetVar("SkyHeightAdd", self.SkyHeightAdd)
    pallet:SetVar("OrbitRadius",  self.OrbitRadius)
    pallet:SetVar("Speed",        self.Speed)
    pallet:SetOwner(self)
    pallet.IsOnPlane      = true
    pallet.Launcher       = self
    pallet.SpawnedFromPlane = true  -- tells gbu53_owned to use the pos we set, not orbit-entry

    pallet:SetPos(dropPos)
    pallet:SetAngles(Angle(0, self.flightYaw, 0))
    pallet:Spawn()
    pallet:Activate()

    -- Seed horizontal velocity so the pallet carries the plane's momentum during freefall
    local mPhys = pallet:GetPhysicsObject()
    if IsValid(mPhys) then
        local fwdVel = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        fwdVel.z = 0
        mPhys:SetVelocity(fwdVel)
    end

    constraint.NoCollide(pallet, self, 0, 0)
    local pRef = pallet
    timer.Simple(1.2, function()
        if IsValid(pRef) and IsValid(self) then constraint.RemoveConstraints(pRef, "NoCollide") end
    end)

    self:Debug("W3 GBU53 pallet #" .. (palletIndex+1) .. " dropped at " .. tostring(dropPos))
end

function ENT:UpdateGBU53(ct)
    if self.WPN_ShotsFired >= CFG_W3_GBU53_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W3_GBU53_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneGBU53Pallet(self.WPN_ShotsFired - 1)
    return (self.WPN_ShotsFired >= CFG_W3_GBU53_Count)
end

-- ============================================================
-- W6: RETARDED / PARACHUTE BOMBS
-- ============================================================
function ENT:UpdateRetarded(ct)
    if self.WPN_ShotsFired >= CFG_W6_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W6_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1

    local entClass = CFG_W6_Pool[math.random(#CFG_W6_Pool)]
    local dropPos   = self:LocalToWorld(CFG_BombBayLocal)
    local aimPos    = self:GetAimPos(CFG_W6_Scatter)
    self:SpawnDartBomb(entClass, dropPos, aimPos, true)
    return (self.WPN_ShotsFired >= CFG_W6_Count)
end

-- ============================================================
-- SETVAR / GETVAR  (simple per-entity key-value store used
-- before Spawn() to pass init params, mirrors AC-130 pattern)
-- ============================================================
function ENT:SetVar(key, value)
    self.__vars = self.__vars or {}
    self.__vars[key] = value
end

function ENT:GetVar(key, default)
    if self.__vars and self.__vars[key] ~= nil then
        return self.__vars[key]
    end
    return default
end
