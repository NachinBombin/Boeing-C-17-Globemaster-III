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
local ROLL_MAX            = 19.0
local ROLL_LERP_IN        = 0.08
local ROLL_LERP_OUT       = 0.012

local ENGINE_LOOP_SOUND = "sound/b52/b52.wav"

local MODEL_SCALE = 1.8

-- ============================================================
-- SW MUNITIONS CATALOGUE
-- ============================================================
-- Window IDs (active):
--   W1 "jassm"    -- AGM-158 JASSM parachute drop
--   W2 "heavy"    -- heavy GP / penetrators
--   W3 "gbu53"    -- GBU-53 parachute cluster drop
--   W6 "retarded" -- parachute / retarder bombs
--   W7 "wp"       -- WP illumination canister (parachute)
-- ============================================================

local DART_SPEED  = 4500
local GRAVITY_EST = 580

-- ---------- General config ----------
local CFG_MaxHP        = 3500
local CFG_FadeDuration = 3.0
local CFG_PeacefulMin  = 6
local CFG_PeacefulMax  = 14

local CFG_BombBayLocal = Vector(100,100, -30)

-- Orbit / target-tracking tuning.
local TARGET_ORBIT_RADIUS        = 1800
local TARGET_ORBIT_RADIUS_MIN    = 1200
local TARGET_ORBIT_RADIUS_MAX    = 2600
local TARGET_CENTER_LERP         = 0.035
local TARGET_LOOKAHEAD_TIME      = 2.25
local TARGET_MAX_LOOKAHEAD_DIST  = 1200
local TARGET_REACQUIRE_INTERVAL  = 0.35
local TARGET_PASS_BIAS           = 0.55

-- ---------- W1 -- JASSM parachute drop ----------
local CFG_W1_JASSM_Count                = 1
local CFG_W1_JASSM_Delay               = 0
local CFG_W1_JASSM_TailOffset          = Vector(0,100,-70)
local CFG_W1_JASSM_AltOffset           = 500
local CFG_W1_JASSM_MIN_FREEFALL_CLEARANCE = 800
local CFG_W1_JASSM_MIN_DROP_HEIGHT     = 1200
local CFG_W1_JASSM_SHA_FLOOR           = 400

-- ---------- W2 -- heavy unguided ----------
local CFG_W2_Count      = 6
local CFG_W2_Delay      = 0.35
local CFG_W2_DropOffset = Vector(0, 60, -50)

-- ---------- W3 -- GBU-53 parachute cluster ----------
local CFG_W3_GBU53_Count   = 3
local CFG_W3_GBU53_Delay   = 1.2
local CFG_W3_DropOffset    = Vector(0, 60, -50)
local CFG_W3_BodyClearance = 100
local CFG_W3_AltStagger    = 0
local CFG_W3_NoCollideHold = 1.5

-- ---------- W6 -- retarded / parachute bombs ----------
local CFG_W6_Count         = 4
local CFG_W6_Delay         = 0.9
local CFG_W6_DropOffset    = Vector(0, 55, -55)
local CFG_W6_BodyClearance = 90
local CFG_W6_NoCollideHold = 1.5

-- ---------- W7 -- WP Illumination parachute canister ----------
local CFG_W7_Count         = 4
local CFG_W7_Delay         = 1.5
local CFG_W7_DropOffset    = Vector(0, 50, -60)
local CFG_W7_BodyClearance = 80
local CFG_W7_NoCollideHold = 1.8
local CFG_W7_SpreadAngles  = { -28, -9, 9, 28 }
local CFG_W7_ForwardFrac   = 0.55
local CFG_W7_ForwardBoost  = 80

local WEAPON_ROSTER = { "jassm", "heavy", "gbu53", "retarded", "wp" }

-- ============================================================
-- MISC CONSTANTS
-- ============================================================
local DOOR_OPEN_TIME  = 2.2
local DOOR_CLOSE_TIME = 1.8

local PALLET_MODEL        = "models/props/de_prodigy/wood_pallet_01.mdl"
local PALLET_LIFETIME     = 20
local PALLET_NOCLIDE_HOLD = 1.2

local function SpawnWoodPallet(pos, vel, bombRef)
    timer.Simple(0, function()
        local p = ents.Create("prop_physics")
        if not IsValid(p) then return end
        p:SetModel(PALLET_MODEL)
        p:SetPos(pos)
        p:SetAngles(Angle(math.Rand(0,360), math.Rand(0,360), math.Rand(0,360)))
        p:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
        p:Spawn()
        p:Activate()
        local ph = p:GetPhysicsObject()
        if IsValid(ph) then
            ph:SetVelocity(vel or Vector(0,0,0))
        end
        if IsValid(bombRef) then
            local ncHandle = constraint.NoCollide(p, bombRef, 0, 0)
            timer.Simple(PALLET_NOCLIDE_HOLD, function()
                if IsValid(ncHandle) then ncHandle:Remove() end
            end)
        end
        timer.Simple(PALLET_LIFETIME, function()
            if IsValid(p) then p:Remove() end
        end)
    end)
end

util.AddNetworkString("bombin_c17_damage_tier")
util.AddNetworkString("bombin_c17_cargo_door")

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
local function BroadcastCargoDoor(planeEnt, open)
    net.Start("bombin_c17_cargo_door")
    net.WriteUInt(planeEnt:EntIndex(), 16)
    net.WriteBool(open)
    net.Broadcast()
    planeEnt:SetNWBool("CargoDoorOpen", open)
end

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

    self:SetModel("models/v92/c17/c17.mdl")
    self:SetModelScale(MODEL_SCALE, 0)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(false)
        phys:SetMass(50000)
        phys:SetDamping(0.99, 0.99)
        phys:Wake()
    end

    self.HP           = self.MaxHP
    self.DamageTier   = 0
    self.FadeStart    = nil
    self.Dead         = false
    self.DebugMode    = self:GetVar("DebugMode", false)
    self.SoundHandle  = nil
    self.JASSM_Stock  = 0

    local tangent = self.CallDir:GetNormalized()
    self.flightYaw    = tangent:Angle().y
    self.SmoothedRoll = 0
    self.SmoothedPitch= 0
    self.PrevYaw      = self.flightYaw

    self.ang = Angle(0, self.flightYaw + MODEL_YAW_OFFSET, 0)
    self:SetAngles(self.ang)

    local startOffset = -tangent * (self.OrbitRadius * 0.5)
    local startPos    = self.CenterPos + startOffset
    startPos.z        = self.CenterPos.z + self.SkyHeightAdd
    self:SetPos(startPos)

    self.OrbitDirection = 1
    self.OrbitRadius    = self:GetVar("OrbitRadius", TARGET_ORBIT_RADIUS)
    self.OrbitAngle     = math.atan2(startOffset.y, startOffset.x)

    self.SkyProbeDist    = math.max(1400, self.Speed * 6)
    self.SkyProbeZ       = startPos.z
    self.SkyProbeNextT   = 0
    self.TargetReacqTime = 0

    if IsValid(phys) then
        phys:SetVelocity(tangent * self.Speed)
    end

    self.WPN_Active     = nil
    self.WPN_Phase      = nil
    self.WPN_ShotsFired = 0
    self.WPN_NextShot   = 0
    self.WPN_WindowEnd  = 0
    self.WPN_PhaseUntil = 0
    self.WPN_PeaceUntil = CurTime() + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)

    BroadcastTier(self, 0)
    self:NextThink(CurTime() + 0.05)

    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        self:EmitSound(ENGINE_LOOP_SOUND, 90, 95, 1.0, CHAN_AUTO)
    end)
end

function ENT:Debug(msg)
    if self.DebugMode then
        print("[C17] " .. tostring(msg))
    end
end

-- ============================================================
-- PHYSICS UPDATE: flight control
-- ============================================================
function ENT:PhysicsUpdate(phys)
    if self.Dead then return end

    local pos        = phys:GetPos()
    local curVel     = phys:GetVelocity()
    local desiredYaw = self:ComputeDesiredYaw(pos)

    local prevYaw     = self.flightYaw
    self.flightYaw    = desiredYaw

    local yawDelta   = math.NormalizeAngle(desiredYaw - prevYaw)
    local rollTarget = math.Clamp(-yawDelta * ROLL_TRANSIENT_GAIN, -ROLL_MAX, ROLL_MAX)

    if math.abs(rollTarget) > math.abs(self.SmoothedRoll) then
        self.SmoothedRoll = Lerp(ROLL_LERP_IN,  self.SmoothedRoll, rollTarget)
    else
        self.SmoothedRoll = Lerp(ROLL_LERP_OUT, self.SmoothedRoll, rollTarget)
    end

    local desVelX = math.cos(math.rad(desiredYaw)) * self.Speed
    local desVelY = math.sin(math.rad(desiredYaw)) * self.Speed
    phys:SetVelocity(Vector(
        Lerp(0.12, curVel.x, desVelX),
        Lerp(0.12, curVel.y, desVelY),
        Lerp(0.08, curVel.z, 0)
    ))

    self.ang = Angle(-self.SmoothedRoll, self.flightYaw + MODEL_YAW_OFFSET, -self.SmoothedPitch)
    phys:SetAngles(self.ang)
end

-- ============================================================
-- ORBIT / TARGET TRACKING
-- ============================================================
function ENT:ComputeDesiredYaw(pos)
    local target = self:GetTarget()
    local center

    if IsValid(target) then
        local tPos    = target:GetPos()
        local tVelNow = target:GetVelocity()
        local lookahead = math.min(tVelNow:Length() * TARGET_LOOKAHEAD_TIME, TARGET_MAX_LOOKAHEAD_DIST)
        local tPosLead  = tPos + tVelNow:GetNormalized() * lookahead
        local biasFwd   = Angle(0, self.flightYaw, 0):Forward() * (self.OrbitRadius * TARGET_PASS_BIAS)
        center = LerpVector(TARGET_CENTER_LERP, self.CenterPos, tPosLead + biasFwd)
        self.CenterPos = center
    else
        center = self.CenterPos
    end

    local toCenter = center - pos
    toCenter.z = 0

    local radiusError = toCenter:Length() - self.OrbitRadius
    local correction  = math.Clamp(radiusError * 0.012, -25, 25)
    local turnRate    = (self.Speed / self.OrbitRadius) * 57.3

    return math.NormalizeAngle(
        self.flightYaw + (turnRate * self.OrbitDirection + correction * self.OrbitDirection) * 0.05
    )
end

function ENT:GetTarget()
    if not IsValid(self.TrackedTarget) then
        if CurTime() < self.TargetReacqTime then return nil end
        self.TargetReacqTime = CurTime() + TARGET_REACQUIRE_INTERVAL
        local best, bestDist = nil, self.OrbitRadius * 2
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) and ply:Alive() then
                local d = ply:GetPos():Distance(self.CenterPos)
                if d < bestDist then best = ply; bestDist = d end
            end
        end
        self.TrackedTarget = best
    end
    return self.TrackedTarget
end

-- ============================================================
-- THINK: lifetime + weapon windows
-- ============================================================
function ENT:Think()
    if self.Dead then return end
    local ct = CurTime()

    if ct > self:GetVar("SpawnTime", 0) + self.Lifetime then
        if not self.FadeStart then
            self.FadeStart = ct
            self:StopAllSounds()
        end
        local frac = (ct - self.FadeStart) / self.FadeDuration
        if frac >= 1 then
            self:Remove()
            return
        end
        self:SetColor(Color(255,255,255, math.Round((1-frac)*255)))
        self:SetRenderMode(RENDERMODE_TRANSALPHA)
        self:NextThink(ct + 0.05)
        return true
    end

    if ct > self.SkyProbeNextT then
        self.SkyProbeNextT = ct + 1.5
        local tr = util.TraceLine({
            start  = self:GetPos() + Vector(0,0,50),
            endpos = self:GetPos() + Vector(0,0,self.SkyProbeDist),
            filter = self,
        })
        if not tr.Hit then
            self.SkyProbeZ = self:GetPos().z
        end
    end

    self:UpdateWeaponWindow(ct)
    self:NextThink(ct + 0.05)
    return true
end

-- ============================================================
-- WEAPON WINDOW STATE MACHINE
-- ============================================================
function ENT:UpdateWeaponWindow(ct)
    if ct < self.WPN_PeaceUntil then return end

    if not self.WPN_Active then
        local w = WEAPON_ROSTER[math.random(#WEAPON_ROSTER)]
        self.WPN_Active     = w
        self.WPN_Phase      = "opening"
        self.WPN_PhaseUntil = ct + DOOR_OPEN_TIME
        self.WPN_ShotsFired = 0
        self.WPN_NextShot   = 0
        self.WPN_WindowEnd  = 0
        BroadcastCargoDoor(self, true)
        self:Debug("Weapon window: " .. w .. " | opening cargo door")
        return
    end

    if self.WPN_Phase == "opening" then
        if ct < self.WPN_PhaseUntil then return end
        self.WPN_Phase     = "firing"
        self.WPN_NextShot  = ct
        self.WPN_WindowEnd = ct + 12
        self:Debug("Weapon window: " .. self.WPN_Active .. " | door open, firing begins")
    end

    if self.WPN_Phase == "firing" then
        local w    = self.WPN_Active
        local done = false
        if ct > self.WPN_WindowEnd then
            done = true
        else
            if     w == "jassm"    then done = self:UpdateJASSM(ct)
            elseif w == "heavy"    then done = self:UpdateHeavy(ct)
            elseif w == "gbu53"    then done = self:UpdateGBU53(ct)
            elseif w == "retarded" then done = self:UpdateRetarded(ct)
            elseif w == "wp"       then done = self:UpdateWP(ct)
            else done = true end
        end
        if done then
            self.WPN_Phase      = "closing"
            self.WPN_PhaseUntil = ct + DOOR_CLOSE_TIME
            BroadcastCargoDoor(self, false)
            self:Debug("Weapon window: " .. self.WPN_Active .. " | firing done, closing door")
        end
    end

    if self.WPN_Phase == "closing" then
        if ct < self.WPN_PhaseUntil then return end
        self:Debug("Weapon window: " .. self.WPN_Active .. " | door closed, peace timer started")
        self.WPN_Active     = nil
        self.WPN_Phase      = nil
        self.WPN_PeaceUntil = ct + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)
    end
end

-- ============================================================
-- DAMAGE
-- ============================================================
function ENT:OnTakeDamage(dmginfo)
    if self.Dead then return end
    self.HP = self.HP - dmginfo:GetDamage()
    local tier = CalcTier(math.max(self.HP, 0), self.MaxHP)
    if tier ~= self.DamageTier then
        self.DamageTier = tier
        BroadcastTier(self, tier)
    end
    if self.HP <= 0 then self:Die() end
end

function ENT:Die()
    if self.Dead then return end
    self.Dead = true
    self:StopAllSounds()
    BroadcastTier(self, 3)
    BroadcastCargoDoor(self, false)
    self.WPN_Active     = nil
    self.WPN_Phase      = nil
    self.WPN_PeaceUntil = math.huge
    local pos = self:GetPos()
    local ed  = EffectData()
    ed:SetOrigin(pos)
    ed:SetScale(4)
    util.Effect("Explosion", ed, true, true)
    sound.Play("ambient/explosions/explode_4.wav", pos, 100, 80, 1.0)
    self.FadeStart = CurTime()
end

function ENT:OnRemove()
    self:StopAllSounds()
end

-- ============================================================
-- WEAPON UPDATERS
-- ============================================================
function ENT:UpdateJASSM(ct)
    if self.WPN_ShotsFired >= CFG_W1_JASSM_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W1_JASSM_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneJASSM(self.WPN_ShotsFired - 1)
    return (self.WPN_ShotsFired >= CFG_W1_JASSM_Count)
end

function ENT:UpdateHeavy(ct)
    if self.WPN_ShotsFired >= CFG_W2_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W2_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneHeavy()
    return (self.WPN_ShotsFired >= CFG_W2_Count)
end

function ENT:UpdateGBU53(ct)
    if self.WPN_ShotsFired >= CFG_W3_GBU53_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W3_GBU53_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneGBU53Pallet(self.WPN_ShotsFired - 1)
    return (self.WPN_ShotsFired >= CFG_W3_GBU53_Count)
end

function ENT:UpdateRetarded(ct)
    if self.WPN_ShotsFired >= CFG_W6_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W6_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneRetarded()
    return (self.WPN_ShotsFired >= CFG_W6_Count)
end

function ENT:UpdateWP(ct)
    if self.WPN_ShotsFired >= CFG_W7_Count then return true end
    if ct < self.WPN_NextShot then return false end
    self.WPN_NextShot   = ct + CFG_W7_Delay
    self.WPN_ShotsFired = self.WPN_ShotsFired + 1
    self:SpawnOneWP(self.WPN_ShotsFired)
    return (self.WPN_ShotsFired >= CFG_W7_Count)
end

-- ============================================================
-- W1: SpawnOneJASSM
-- ============================================================
function ENT:SpawnOneJASSM(dropIndex)
    local tailWorld = self:LocalToWorld(CFG_W1_JASSM_TailOffset)
    local dropPos   = Vector(tailWorld.x, tailWorld.y, tailWorld.z)
    if not util.IsInWorld(dropPos) then
        dropPos = self.CenterPos + Vector(0, 0, self.SkyHeightAdd)
    end

    local groundTr = util.TraceLine({
        start  = dropPos,
        endpos = dropPos - Vector(0, 0, 50000),
        mask   = MASK_SOLID_BRUSHONLY,
    })
    local groundZ   = (groundTr.Hit and groundTr.HitPos.z) or self.CenterPos.z
    local dropHeight = math.max(dropPos.z - groundZ, 0)

    if dropHeight < CFG_W1_JASSM_MIN_DROP_HEIGHT then
        self:Debug("W1 JASSM: drop altitude too low (" .. math.Round(dropHeight) .. "u), aborting")
        return
    end

    local shaMax = (dropHeight - CFG_W1_JASSM_MIN_FREEFALL_CLEARANCE) / 1.25
    local sha    = math.max(shaMax, CFG_W1_JASSM_SHA_FLOOR)

    local missile = ents.Create("ent_bombin_jassm_owned")
    if not IsValid(missile) then
        self:Debug("W1 JASSM: ent_bombin_jassm_owned not found")
        return
    end

    local callDir = Angle(0, self.flightYaw, 0):Forward()
    missile:SetPos(dropPos)
    missile:SetAngles(callDir:Angle())
    missile.SpawnedFromPlane = true
    missile.CenterPos    = self.CenterPos
    missile.CallDir      = callDir
    missile.Lifetime     = math.min(self.Lifetime or 120, 35)
    missile.Speed        = 250
    missile.OrbitRadius  = self.OrbitRadius * 0.75
    missile.SkyHeightAdd = sha
    missile:SetOwner(self)
    missile.IsOnPlane    = true
    missile.Launcher     = self
    missile:Spawn()
    missile:Activate()

    local mHandle = constraint.NoCollide(missile, self, 0, 0)
    timer.Simple(1.25, function()
        if IsValid(mHandle) then mHandle:Remove() end
    end)

    local chute = ents.Create("ent_bombin_jassm_chute_owned")
    if IsValid(chute) then
        chute:SetOwner(missile)
        chute:SetPos(dropPos + Vector(0, 0, 105))
        chute:SetAngles(Angle(0, self.flightYaw, 0))
        chute:Spawn()
        chute:Activate()
        local cP = constraint.NoCollide(chute, self, 0, 0)
        local cM = constraint.NoCollide(chute, missile, 0, 0)
        timer.Simple(1.25, function()
            if IsValid(cP) then cP:Remove() end
            if IsValid(cM) then cM:Remove() end
        end)
    else
        self:Debug("W1 JASSM: ent_bombin_jassm_chute_owned not found")
    end

    SpawnWoodPallet(dropPos + Vector(0,0,-20), Vector(math.Rand(-60,60), math.Rand(-60,60), -80), nil)
    self:Debug("W1 JASSM drop #" .. (dropIndex+1) .. " SHA=" .. math.Round(sha))
end

-- ============================================================
-- W2: SpawnOneHeavy
-- ============================================================
function ENT:SpawnOneHeavy()
    local tailWorld = self:LocalToWorld(CFG_W2_DropOffset)
    local dropPos   = Vector(tailWorld.x, tailWorld.y, tailWorld.z - 50)
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - 50)
    end

    local bomb = ents.Create("ent_bombin_heavybomb_owned")
    if not IsValid(bomb) then
        self:Debug("W2 Heavy: ent_bombin_heavybomb_owned not found")
        return
    end

    bomb:SetPos(dropPos)
    bomb:SetAngles(Angle(90, self.flightYaw, 0))
    bomb:SetOwner(self)
    bomb.Launcher = self
    bomb:Spawn()
    bomb:Activate()

    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        local fwd = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        bPhys:SetVelocity(Vector(fwd.x, fwd.y, -120))
    end

    local ncHandle = constraint.NoCollide(bomb, self, 0, 0)
    timer.Simple(1.0, function()
        if IsValid(ncHandle) then ncHandle:Remove() end
    end)

    SpawnWoodPallet(dropPos + Vector(0,0,-10), Vector(math.Rand(-80,80), math.Rand(-80,80), -60), bomb)
    self:Debug("W2 Heavy bomb dropped")
end

-- ============================================================
-- W3: SpawnOneGBU53Pallet
-- ============================================================
function ENT:SpawnOneGBU53Pallet(palletIndex)
    local tailWorld = self:LocalToWorld(CFG_W3_DropOffset)
    local dropPos   = Vector(tailWorld.x, tailWorld.y, tailWorld.z - CFG_W3_BodyClearance)
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - CFG_W3_BodyClearance)
    end

    local pallet = ents.Create("ent_bombin_gbu53_chute_owned")
    if not IsValid(pallet) then
        self:Debug("W3 GBU53: ent_bombin_gbu53_chute_owned not found")
        return
    end

    pallet:SetPos(dropPos)
    pallet:SetAngles(Angle(0, self.flightYaw, 0))
    pallet:SetOwner(self)
    pallet.Launcher = self
    pallet:Spawn()
    pallet:Activate()

    local ncHandle = constraint.NoCollide(pallet, self, 0, 0)
    timer.Simple(CFG_W3_NoCollideHold, function()
        if IsValid(ncHandle) then ncHandle:Remove() end
    end)

    SpawnWoodPallet(dropPos + Vector(0,0,-15), Vector(math.Rand(-50,50), math.Rand(-50,50), -70), nil)
    self:Debug("W3 GBU53 pallet #" .. (palletIndex+1) .. " at " .. tostring(dropPos))
end

-- ============================================================
-- W6: SpawnOneRetarded
-- ============================================================
function ENT:SpawnOneRetarded()
    local tailWorld = self:LocalToWorld(CFG_W6_DropOffset)
    local dropPos   = Vector(tailWorld.x, tailWorld.y, tailWorld.z - CFG_W6_BodyClearance)
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - CFG_W6_BodyClearance)
    end

    local bomb = ents.Create("ent_bombin_retarded_owned")
    if not IsValid(bomb) then
        self:Debug("W6 Retarded: ent_bombin_retarded_owned not found")
        return
    end

    bomb:SetPos(dropPos)
    bomb:SetAngles(Angle(0, self.flightYaw, 0))
    bomb:SetOwner(self)
    bomb.Launcher = self
    bomb:Spawn()
    bomb:Activate()

    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        local fwd = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        bPhys:SetVelocity(Vector(fwd.x * 0.6, fwd.y * 0.6, -80))
    end

    local ncHandle = constraint.NoCollide(bomb, self, 0, 0)
    timer.Simple(CFG_W6_NoCollideHold, function()
        if IsValid(ncHandle) then ncHandle:Remove() end
    end)

    SpawnWoodPallet(dropPos + Vector(0,0,-10), Vector(math.Rand(-50,50), math.Rand(-50,50), -60), bomb)
    self:Debug("W6 Retarded bomb dropped")
end

-- ============================================================
-- W7: SpawnOneWP
-- ============================================================
function ENT:SpawnOneWP(shotIndex)
    local tailWorld = self:LocalToWorld(CFG_W7_DropOffset)
    local dropPos   = Vector(tailWorld.x, tailWorld.y, tailWorld.z - CFG_W7_BodyClearance)
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - CFG_W7_BodyClearance)
    end

    local spreadDeg = CFG_W7_SpreadAngles[shotIndex] or 0
    local spreadYaw = self.flightYaw + spreadDeg
    local fwdFrac   = Angle(0, spreadYaw, 0):Forward() * (self.Speed * CFG_W7_ForwardFrac + CFG_W7_ForwardBoost)
    local dropVel   = Vector(fwdFrac.x, fwdFrac.y, -55)

    local can = ents.Create("ent_bombin_wp_canister")
    if not IsValid(can) then
        self:Debug("W7 WP: ent_bombin_wp_canister not found")
        return
    end

    can:SetPos(dropPos)
    can:SetAngles(Angle(0, spreadYaw, 0))
    can:SetOwner(self)
    can.Launcher = self
    can.DropVel  = dropVel
    can:Spawn()
    can:Activate()

    local ncHandle = constraint.NoCollide(can, self, 0, 0)
    timer.Simple(CFG_W7_NoCollideHold, function()
        if IsValid(ncHandle) then ncHandle:Remove() end
    end)

    local palletVel = Vector(dropVel.x * 0.7, dropVel.y * 0.7, -80)
    SpawnWoodPallet(dropPos + Vector(0,0,-18), palletVel, nil)
    self:Debug("W7 WP drop #" .. shotIndex .. " spread=" .. spreadDeg .. "deg")
end

-- ============================================================
-- VAR STORE (used by spawner to pass params before Initialize)
-- ============================================================
function ENT:SetVar(key, value)
    self.__vars = self.__vars or {}
    self.__vars[key] = value
end

function ENT:GetVar(key, default)
    self.__vars = self.__vars or {}
    if self.__vars[key] ~= nil then return self.__vars[key] end
    return default
end
