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
-- Each "shot" drops one ent_bombin_gbu53_chute_owned:
--   a metal palette with 4 GBU-53 munitions + a parachute riding above.
-- The chute detaches at ignition and each GBU-53 loiters independently.
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

    self.RadialGain  = 0.9
    self.MaxTurnRate = 34

    self.IsTumbling        = false
    self.TumbleStartTime   = 0
    self.TumbleGroundZ     = ground
    self.TumbleCrashed     = false
    self.TumbleVelocity    = Vector(0, 0, 0)
    self.TumbleAngVelocity = Vector(0, 0, 0)

    self.IsDestroyed = false
    self.DamageTier  = 0

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:Wake()
        self.PhysObj:EnableGravity(false)
        self.PhysObj:SetAngles(self.ang)
    end

    self.EngineLoop = CreateSound(self, ENGINE_LOOP_SOUND)
    if self.EngineLoop then
        self.EngineLoop:SetSoundLevel(80)
        self.EngineLoop:ChangePitch(100, 0)
        self.EngineLoop:ChangeVolume(1.0, 0)
        self.EngineLoop:Play()
    end

    self.CurrentWeapon   = nil
    self.IsPeaceful      = false
    self.PeacefulUntil   = 0

    self.WPN_ShotsFired  = 0
    self.WPN_NextShot    = 0
    self.WPN_MuzzleIndex = 1

    self:Debug("C-17 (SW-munitions, scale=" .. MODEL_SCALE .. ") spawned. sky=" .. self.sky)
end

-- ============================================================
-- DAMAGE
-- ============================================================
function ENT:OnTakeDamage(dmginfo)
    if self.IsDestroyed then return end
    if dmginfo:IsDamageType(DMG_CRUSH) then return end
    local hp = self:GetNWInt("HP", self.MaxHP) - dmginfo:GetDamage()
    self:SetNWInt("HP", hp)
    local tier = CalcTier(hp, self.MaxHP)
    if tier ~= self.DamageTier then
        self.DamageTier = tier
        BroadcastTier(self, tier)
    end
    if hp <= 0 then self:DestroyUAV() end
end

function ENT:StartTumble()
    self.IsTumbling      = true
    self.TumbleStartTime = CurTime()
    self.TumbleCrashed   = false
    local gnd = self:FindGround(self:GetPos())
    if gnd ~= -1 then self.TumbleGroundZ = gnd end
    local fwd = Angle(0, self.flightYaw, 0):Forward()
    self.TumbleVelocity    = Vector(fwd.x*(self.Speed or 260), fwd.y*(self.Speed or 260), -200)
    local function sign() return (math.random(2)==1) and 1 or -1 end
    self.TumbleAngVelocity = Vector(
        math.Rand(80,200)*sign(),
        math.Rand(20,80)*sign(),
        math.Rand(150,400)*sign()
    )
    local pos = self:GetPos()
    local ed  = EffectData() ed:SetOrigin(pos) ed:SetScale(4) ed:SetMagnitude(4) ed:SetRadius(400)
    util.Effect("500lb_air", ed, true, true)
    sound.Play("ambient/explosions/explode_4.wav", pos, 135, 95, 1.0)
end

function ENT:CrashExplode()
    if self.TumbleCrashed then return end
    self.TumbleCrashed = true
    local pos = self:GetPos()
    local e1=EffectData() e1:SetOrigin(pos) e1:SetScale(6) e1:SetMagnitude(6) e1:SetRadius(600) util.Effect("HelicopterMegaBomb",e1,true,true)
    local e2=EffectData() e2:SetOrigin(pos) e2:SetScale(5) e2:SetMagnitude(5) e2:SetRadius(500) util.Effect("500lb_air",e2,true,true)
    local e3=EffectData() e3:SetOrigin(pos+Vector(0,0,80)) e3:SetScale(4) e3:SetMagnitude(4) e3:SetRadius(400) util.Effect("500lb_air",e3,true,true)
    sound.Play("ambient/explosions/explode_8.wav", pos, 140, 90, 1.0)
    sound.Play("weapon_AWP.Single", pos, 145, 60, 1.0)
    util.BlastDamage(self, self, pos, 400, 200)
    self:Remove()
end

function ENT:DestroyUAV()
    if self.IsDestroyed then return end
    self.IsDestroyed = true
    if self.EngineLoop then
        self.EngineLoop:ChangeVolume(0, 0.3)
        timer.Simple(0.4, function()
            if self.EngineLoop then self.EngineLoop:Stop() end
        end)
    end
    self:StartTumble()
    timer.Simple(12, function()
        if IsValid(self) then self:CrashExplode() end
    end)
end

function ENT:Debug(msg) print("[Bombin C-17] " .. tostring(msg)) end

function ENT:UpdateTrackedTarget(ct)
    if ct < (self.NextTargetRefresh or 0) and IsValid(self.TargetEnt) then return self.TargetEnt end

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

function ENT:GetTargetOrbitCenter(ct)
    local target = self:UpdateTrackedTarget(ct)
    local desiredCenter = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z)

    if IsValid(target) then
        local tpos = target:GetPos()
        local tvel = target.GetVelocity and target:GetVelocity() or Vector(0,0,0)
        tvel.z = 0
        local lookAhead = math.min(tvel:Length() * TARGET_LOOKAHEAD_TIME, TARGET_MAX_LOOKAHEAD_DIST)
        desiredCenter = tpos + tvel:GetNormalized() * lookAhead
        desiredCenter.z = tpos.z
        self.TargetVel = tvel
        self.LastTargetSampleTime = ct
    end

    self.DynamicCenterPos = LerpVector(TARGET_CENTER_LERP, self.DynamicCenterPos or desiredCenter, desiredCenter)
    self.CenterPos = self.DynamicCenterPos
    return self.DynamicCenterPos, target
end

-- ============================================================
-- WEAPON SYSTEM STATE MACHINE
-- ============================================================

function ENT:PickNewWeapon(ct)
    self.IsPeaceful    = true
    self.PeacefulUntil = ct + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)
    self.CurrentWeapon = nil

    local choice = WEAPON_ROSTER[math.random(#WEAPON_ROSTER)]

    timer.Simple(self.PeacefulUntil - ct, function()
        if not IsValid(self) or self.IsDestroyed then return end
        self.IsPeaceful      = false
        self.CurrentWeapon   = choice
        self.WPN_ShotsFired  = 0
        self.WPN_NextShot    = CurTime()
        self.WPN_MuzzleIndex = 1
        self:Debug("Armed: " .. choice)
    end)

    self:Debug("Peaceful until +" .. string.format("%.1f", self.PeacefulUntil - ct) .. "s, next=" .. choice)
end

function ENT:HandleWeaponSystem(ct)
    if self.CurrentWeapon == nil and not self.IsPeaceful then
        self:PickNewWeapon(ct)
        return
    end

    if self.IsPeaceful then return end

    if self.CurrentWeapon == nil then return end

    local done = false
    local w = self.CurrentWeapon

    if     w == "jassm"    then done = self:UpdateJASSM(ct)
    elseif w == "heavy"    then done = self:UpdateHeavy(ct)
    elseif w == "gbu53"    then done = self:UpdateGBU53(ct)
    elseif w == "retarded" then done = self:UpdateRetarded(ct)
    else
        self:Debug("Unknown weapon '" .. tostring(w) .. "', resetting")
        done = true
    end

    if done then
        self:PickNewWeapon(ct)
    end
end

-- ============================================================
-- THINK / PHYSICS UPDATE
-- ============================================================
function ENT:Think()
    if not self.DieTime or not self.SpawnTime then
        self:NextThink(CurTime()+0.1) return true
    end
    local ct = CurTime()

    if self.IsTumbling and not self.TumbleCrashed then
        local pos = self:GetPos()
        if pos.z <= (self.TumbleGroundZ or -16384)+150 then self:CrashExplode() return end
        local tr = util.TraceLine({start=pos, endpos=pos+Vector(0,0,-200), filter=self})
        if tr.HitWorld then self:CrashExplode() return end
        self:NextThink(ct+0.05) return true
    end

    if ct >= self.DieTime then self:Remove() return end
    if not IsValid(self.PhysObj) then self.PhysObj = self:GetPhysicsObject() end
    if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then self.PhysObj:Wake() end

    local age  = ct - self.SpawnTime
    local left = self.DieTime - ct
    local alpha = 255
    if age  < self.FadeDuration then alpha = math.Clamp(255*(age /self.FadeDuration),0,255)
    elseif left < self.FadeDuration then alpha = math.Clamp(255*(left/self.FadeDuration),0,255) end
    self:SetColor(Color(255,255,255,math.Round(alpha)))

    if not self.IsDestroyed then
        self:HandleWeaponSystem(ct)
    end

    self:NextThink(ct)
    return true
end

function ENT:PhysicsUpdate(phys)
    if not self.DieTime or not self.sky then return end

    if self.IsTumbling then
        if self.TumbleCrashed then return end
        local dt  = engine.TickInterval()
        self.TumbleVelocity.z = self.TumbleVelocity.z + physenv.GetGravity().z * dt
        local pos    = self:GetPos()
        local newPos = pos + self.TumbleVelocity * dt
        local av     = self.TumbleAngVelocity
        self.ang = Angle(self.ang.p+av.x*dt, self.ang.y+av.y*dt, self.ang.r+av.z*dt)
        self:SetPos(newPos) self:SetAngles(self.ang)
        if IsValid(phys) then phys:SetPos(newPos) phys:SetAngles(self.ang) end
        return
    end

    if CurTime() >= self.DieTime then self:Remove() return end

    local pos = self:GetPos()
    local dt  = engine.TickInterval()

    if CurTime() >= self.AltDriftNextPick then
        self.AltDriftTarget   = self.sky - math.Rand(0, self.AltDriftRange)
        self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)
    self.JitterPhase = self.JitterPhase + 0.02
    local liveAlt = math.Clamp(
        self.AltDriftCurrent + math.sin(self.JitterPhase) * self.JitterAmplitude,
        self.sky - self.AltDriftRange, self.sky
    )

    local dynamicCenter = self:GetTargetOrbitCenter(CurTime())
    local flatPos    = Vector(pos.x, pos.y, 0)
    local flatCenter = Vector(dynamicCenter.x, dynamicCenter.y, 0)
    local toCenter   = flatCenter - flatPos
    local dist       = toCenter:Length()

    local radialDir  = (dist > 1) and (toCenter / dist) or Vector(0,0,0)
    local tangentDir = Vector(
        -radialDir.y * self.OrbitDirection,
         radialDir.x * self.OrbitDirection,
        0
    )
    if tangentDir:LengthSqr() < 0.001 then
        local fb = Angle(0, self.flightYaw, 0):Forward()
        tangentDir = Vector(fb.x, fb.y, 0)
    end
    tangentDir:Normalize()

    local targetBiasDir = radialDir
    local target = self.TargetEnt
    if IsValid(target) then
        local targetFlat = Vector(target:GetPos().x, target:GetPos().y, 0)
        local toTarget = targetFlat - flatPos
        if toTarget:LengthSqr() > 1 then
            targetBiasDir = toTarget:GetNormalized()
        end
    end

    local radialError = 0
    if self.OrbitRadius > 0 then
        radialError = math.Clamp((dist - self.OrbitRadius) / self.OrbitRadius, -1, 1)
    end

    local desired2 = Vector(
        tangentDir.x + radialDir.x * radialError * self.RadialGain + targetBiasDir.x * TARGET_PASS_BIAS,
        tangentDir.y + radialDir.y * radialError * self.RadialGain + targetBiasDir.y * TARGET_PASS_BIAS,
        0
    )
    if desired2:LengthSqr() < 0.001 then desired2 = tangentDir end
    desired2:Normalize()

    local fwdAngle = Angle(0, self.flightYaw, 0)
    local fwd3     = fwdAngle:Forward()
    local fwd2     = Vector(fwd3.x, fwd3.y, 0)
    if fwd2:LengthSqr() > 0 then fwd2:Normalize() end

    local cross    = fwd2.x * desired2.y - fwd2.y * desired2.x
    local dot      = math.Clamp(fwd2.x * desired2.x + fwd2.y * desired2.y, -1, 1)
    local urgency  = 0.35 + (1 - dot) * 0.65
    local turnRate = math.Clamp(
        cross * urgency * self.MaxTurnRate * 2,
        -self.MaxTurnRate, self.MaxTurnRate
    )

    self.flightYaw      = self.flightYaw + turnRate * dt
    local turnRateDelta = turnRate - self.PrevTurnRate
    self.PrevTurnRate   = turnRate

    local sustained  = math.Clamp(turnRate      * ROLL_SUSTAINED_GAIN, -20, 20)
    local transient  = math.Clamp(turnRateDelta * ROLL_TRANSIENT_GAIN, -12, 12)
    local rollTarget = math.Clamp(sustained + transient, -ROLL_MAX, ROLL_MAX)

    local building = (rollTarget * self.SmoothedRoll >= 0)
                     and (math.abs(rollTarget) > math.abs(self.SmoothedRoll))
    self.SmoothedRoll = Lerp(building and ROLL_LERP_IN or ROLL_LERP_OUT, self.SmoothedRoll, rollTarget)

    local climbDelta   = math.Clamp((liveAlt - pos.z) / 400, -1, 1)
    local targetPitch  = math.Clamp(climbDelta * 6, -8, 8)
    self.SmoothedPitch = Lerp(0.03, self.SmoothedPitch, targetPitch)

    self.ang = Angle(
        -self.SmoothedRoll,
        self.flightYaw + MODEL_YAW_OFFSET,
        -self.SmoothedPitch
    )

    local newPos = pos + fwdAngle:Forward() * self.Speed * dt
    newPos.z     = Lerp(0.07, pos.z, liveAlt)

    if not util.IsInWorld(newPos) then
        self:Debug("OOB guard - steering to center")
        local toC = flatCenter - Vector(pos.x, pos.y, 0)  toC.z = 0
        if toC:LengthSqr() < 0.001 then toC = Vector(-fwd2.x, -fwd2.y, 0) end
        toC:Normalize()
        local sCross = fwd2.x*toC.y - fwd2.y*toC.x
        self.flightYaw = self.flightYaw
            + math.Clamp(sCross * self.MaxTurnRate, -self.MaxTurnRate, self.MaxTurnRate) * dt
        self:SetPos(pos)
        self:SetAngles(Angle(-self.SmoothedRoll, self.flightYaw+MODEL_YAW_OFFSET, -self.SmoothedPitch))
        return
    end

    self:SetPos(newPos)
    self:SetAngles(self.ang)
end

-- ============================================================
-- TARGET ACQUISITION
-- ============================================================
function ENT:GetPrimaryTarget()
    local target = self:UpdateTrackedTarget(CurTime())
    if IsValid(target) then return target end

    local closest, closestDist = nil, math.huge
    local selfPos = self:GetPos()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local d = ply:GetPos():DistToSqr(selfPos)
        if d < closestDist then closestDist = d  closest = ply end
    end
    return closest
end

function ENT:GetDirectTarget(scatter)
    scatter = scatter or 0
    local target = self:GetPrimaryTarget()
    local base
    if IsValid(target) then
        base = target:GetPos()
        local tvel = target.GetVelocity and target:GetVelocity() or Vector(0,0,0)
        local dist = self:GetPos():Distance(base)
        local travelTime = dist / DART_SPEED
        base = base + tvel * travelTime
        base.z = target:GetPos().z
    else
        local tr = util.QuickTrace(
            Vector(self.CenterPos.x, self.CenterPos.y, self.sky),
            Vector(0,0,-30000), self)
        base = tr.HitPos
    end
    if scatter > 0 then
        base = base + Vector(
            math.Rand(-scatter, scatter),
            math.Rand(-scatter, scatter),
            0
        )
    end
    return base
end

function ENT:GetAimedGroundPos(scatter)
    scatter = scatter or 0
    local target = self:GetPrimaryTarget()
    local base
    if IsValid(target) then
        local dropPos   = self:LocalToWorld(CFG_BombBayLocal)
        local targetPos = target:GetPos()
        local targetVel = target.GetVelocity and target:GetVelocity() or Vector(0,0,0)
        targetVel.z = 0
        local H        = math.max(dropPos.z - targetPos.z, 100)
        local fallTime = math.sqrt(2 * H / GRAVITY_EST)
        base   = targetPos + targetVel * fallTime
        base.z = targetPos.z
    else
        local tr = util.QuickTrace(
            Vector(self.CenterPos.x, self.CenterPos.y, self.sky),
            Vector(0,0,-30000), self)
        base = tr.HitPos
    end
    if scatter > 0 then
        base = base + Vector(
            math.Rand(-scatter, scatter),
            math.Rand(-scatter, scatter),
            0
        )
    end
    return base
end

-- ============================================================
-- DART VELOCITY SOLVER
-- ============================================================
local function CalcDartVelocity(dropPos, targetPos)
    local dir = targetPos - dropPos
    if dir:LengthSqr() < 1 then return Vector(0, 0, -DART_SPEED) end
    dir:Normalize()
    return dir * DART_SPEED
end

-- ============================================================
-- CARPET BALLISTIC SOLVER (unused after W3 replaced, kept for W6 if needed)
-- ============================================================
local CARPET_SPEED_MIN = 150
local CARPET_SPEED_MAX = 3200

local function CalcCarpetImpulse(dropPos, aimPos, aircraftFwdVel)
    local H        = math.max(dropPos.z - aimPos.z, 100)
    local fallTime = math.sqrt(2 * H / GRAVITY_EST)
    local dx = aimPos.x - dropPos.x
    local dy = aimPos.y - dropPos.y
    local lateralDist = math.sqrt(dx*dx + dy*dy)
    local reqSpeed = math.Clamp(lateralDist / fallTime, CARPET_SPEED_MIN, CARPET_SPEED_MAX)
    local dir
    if lateralDist > 1 then
        dir = Vector(dx / lateralDist, dy / lateralDist, 0)
    else
        local a = math.Rand(0, math.pi * 2)
        dir = Vector(math.cos(a), math.sin(a), 0)
    end
    local vel = dir * reqSpeed
    vel.x = vel.x + aircraftFwdVel.x
    vel.y = vel.y + aircraftFwdVel.y
    vel.z = -60
    return vel
end

-- ============================================================
-- SPAWN HELPERS
-- ============================================================
function ENT:SpawnDartBomb(entClass, dropPos, targetPos, isRetarded)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("WARN: failed to create '" .. tostring(entClass) .. "'")
        return nil
    end
    bomb.IsOnPlane = true
    bomb.Launcher  = self
    bomb:SetOwner(self)
    local toTarget = targetPos - dropPos
    local dropAng
    if toTarget:LengthSqr() > 1 then
        toTarget:Normalize()
        dropAng = toTarget:Angle()
    else
        dropAng = Angle(90, 0, 0)
    end
    bomb:SetPos(dropPos)
    bomb:SetAngles(dropAng)
    bomb:Spawn()
    bomb:Activate()
    if isRetarded then bomb:SetBodygroup(1, 1) end
    if bomb.Arm then bomb:Arm()
    elseif bomb.Armed ~= nil then bomb.Armed = true end
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        bPhys:SetVelocity(CalcDartVelocity(dropPos, targetPos))
    end
    constraint.NoCollide(bomb, self, 0, 0)
    local ref = bomb
    timer.Simple(0.6, function()
        if IsValid(ref) and IsValid(self) then constraint.RemoveConstraints(ref, "NoCollide") end
    end)
    return bomb
end

function ENT:SpawnCarpetBomb(entClass, dropPos, aimPos)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("WARN: failed to create '" .. tostring(entClass) .. "'")
        return nil
    end
    bomb.IsOnPlane = true
    bomb.Launcher  = self
    bomb:SetOwner(self)
    bomb:SetPos(dropPos)
    bomb:SetAngles(Angle(90, 0, 0))
    bomb:Spawn()
    bomb:Activate()
    if bomb.Arm then bomb:Arm()
    elseif bomb.Armed ~= nil then bomb.Armed = true end
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        local aircraftFwd = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        aircraftFwd.z = 0
        bPhys:SetVelocity(CalcCarpetImpulse(dropPos, aimPos, aircraftFwd))
    end
    constraint.NoCollide(bomb, self, 0, 0)
    local ref = bomb
    timer.Simple(0.6, function()
        if IsValid(ref) and IsValid(self) then constraint.RemoveConstraints(ref, "NoCollide") end
    end)
    return bomb
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
        chute:SetOwner(self)
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
    local entClass   = CFG_W2_Pool[math.random(#CFG_W2_Pool)]
    local dropPos    = self:LocalToWorld(CFG_BombBayLocal)
    local targetPos  = self:GetDirectTarget(CFG_W2_Scatter)
    local isRetarded = string.find(entClass, "_air_v3", 1, true) ~= nil
    self:SpawnDartBomb(entClass, dropPos, targetPos, isRetarded)
    self:Debug("W2 HEAVY " .. self.WPN_ShotsFired .. "/" .. CFG_W2_Count .. " " .. entClass)
    return (self.WPN_ShotsFired >= CFG_W2_Count)
end

-- ============================================================
-- W3: GBU-53 PARACHUTE CLUSTER DROP
-- Spawns ent_bombin_gbu53_chute_owned: a metal palette loaded with
-- 4x GBU-53 munitions, with a parachute riding above.
-- The chute/palette assembly freefalls and detaches at ignition;
-- each GBU-53 then loiters autonomously (same pattern as the JASSM W1).
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

    -- The chute entity IS the palette: it owns the 4 munitions as sub-props
    -- and carries the visual parachute 90u above itself.
    local pallet = ents.Create("ent_bombin_gbu53_chute_owned")
    if not IsValid(pallet) then
        self:Debug("W3 GBU53: ent_bombin_gbu53_chute_owned not found - is Current-Ac-Model installed?")
        return
    end

    -- Forward all orbit / ignition parameters so the sub-munitions know
    -- where to loiter after the chute releases them.
    pallet:SetVar("CenterPos",    self.CenterPos)
    pallet:SetVar("CallDir",      Angle(0, self.flightYaw, 0):Forward())
    pallet:SetVar("SkyHeightAdd", self.SkyHeightAdd)
    pallet:SetVar("OrbitRadius",  self.OrbitRadius)
    pallet:SetOwner(self)
    pallet.IsOnPlane = true
    pallet.Launcher  = self

    pallet:SetPos(dropPos)
    pallet:SetAngles(Angle(0, self.flightYaw, 0))
    pallet:Spawn()
    pallet:Activate()

    local pPhys = pallet:GetPhysicsObject()
    if IsValid(pPhys) then
        local fwdVel = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        fwdVel.z = 0
        pPhys:SetVelocity(fwdVel)
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
    local entClass  = CFG_W6_Pool[math.random(#CFG_W6_Pool)]
    local dropPos   = self:LocalToWorld(CFG_BombBayLocal)
    local targetPos = self:GetDirectTarget(CFG_W6_Scatter)
    self:SpawnDartBomb(entClass, dropPos, targetPos, true)
    self:Debug("W6 RETARDED " .. self.WPN_ShotsFired .. "/" .. CFG_W6_Count .. " " .. entClass)
    return (self.WPN_ShotsFired >= CFG_W6_Count)
end

-- ============================================================
-- UTILITIES
-- ============================================================
function ENT:FindGround(centerPos)
    local startPos   = Vector(centerPos.x, centerPos.y, centerPos.z+64)
    local endPos     = Vector(centerPos.x, centerPos.y, -16384)
    local filterList = {self}
    local maxIter    = 0
    while maxIter < 100 do
        local tr = util.TraceLine({start=startPos, endpos=endPos, filter=filterList})
        if tr.HitWorld then return tr.HitPos.z end
        if IsValid(tr.Entity) then table.insert(filterList, tr.Entity)
        else break end
        maxIter = maxIter + 1
    end
    return -1
end

function ENT:OnRemove()
    if self.EngineLoop then
        self.EngineLoop:ChangeVolume(0, 0.5)
        timer.Simple(0.6, function()
            if self.EngineLoop then self.EngineLoop:Stop() end
        end)
    end
end
