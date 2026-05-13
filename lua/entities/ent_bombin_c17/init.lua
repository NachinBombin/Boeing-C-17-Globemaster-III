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
-- ============================================================

local DART_SPEED  = 4500
local GRAVITY_EST = 580

-- ---------- General config ----------
local CFG_MaxHP        = 3500
local CFG_FadeDuration = 3.0
local CFG_PeacefulMin  = 6
local CFG_PeacefulMax  = 14

-- Drop point in C-17 local space.
-- At MODEL_SCALE=1.8 the belly of the fuselage is ~120u below the
-- entity origin.  -130 clears the hull and exits below the ramp.
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
local CFG_W1_JASSM_Count      = 1
local CFG_W1_JASSM_Delay      = 0
local CFG_W1_JASSM_TailOffset = Vector(0,100, -70)
local CFG_W1_JASSM_AltOffset  = 500

-- ent_bombin_jassm_owned computes:
--   IgnitionAlt = groundZ + SHA + rand(-SHA*0.25, +SHA*0.25)
-- Worst-case (highest possible ignition): groundZ + SHA * 1.25
--
-- We need: dropPos.z > IgnitionAlt_max
--   dropPos.z > groundZ + SHA * 1.25
--   SHA < (dropPos.z - groundZ) / 1.25
--   SHA_max = (dropHeight - MIN_FREEFALL_CLEARANCE) / 1.25
local CFG_W1_JASSM_MIN_FREEFALL_CLEARANCE = 800
local CFG_W1_JASSM_SHA_FLOOR              = 400
local CFG_W1_JASSM_MIN_DROP_HEIGHT = CFG_W1_JASSM_SHA_FLOOR * 1.25 + CFG_W1_JASSM_MIN_FREEFALL_CLEARANCE

-- ---------- W2 -- Heavy ordnance ----------
-- Entries are structs {class, retarded} to avoid fragile _air_v3 substring heuristic.
local CFG_W2_Count   = 2
local CFG_W2_Delay   = 4.0
local CFG_W2_Scatter = 0
local CFG_W2_Pool    = {
    { class = "sw_bomb_gbu43_v3",    retarded = false },
    { class = "sw_bomb_gbu57_v3",    retarded = false },
    { class = "sw_bomb_m118_v3",     retarded = false },
    { class = "sw_bomb_anm56_v3",    retarded = false },
    { class = "sw_bomb_anm66_v3",    retarded = false },
    { class = "sw_bomb_mk84_v3",     retarded = false },
    { class = "sw_bomb_mk84_air_v3", retarded = true  },
    { class = "sw_bomb_anmk1_v3",    retarded = false },
}

-- ---------- W3 -- GBU-53 parachute cluster ----------
-- AltStagger staggers each successive pallet further below the drop
-- point so they separate cleanly during free-fall before chute deploy.
-- This is intentional, not a geometry error.
local CFG_W3_GBU53_Count       = 3
local CFG_W3_GBU53_Delay       = 1.2
local CFG_W3_AltStagger        = 400
local CFG_W3_DropOffset        = Vector(0, 50, -60)
local CFG_W3_BodyClearance     = 80
local CFG_W3_NoCollideHoldTime = 1.8

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

local WEAPON_ROSTER = { "jassm", "heavy", "gbu53", "retarded" }

-- ============================================================
-- CARGO DOOR TIMING
-- Derived from cl_init.lua constants:
--   DOOR_SPEED = 28 deg/s
--   DOOR_TARGETS_OPEN = { 28, 28, 100 }  (three sequential bone targets)
--   Total travel = 28+28+100 = 156 deg  =>  156/28 = 5.571 s
-- We use 5.58 s (a small safety margin) so the door is fully open
-- before the first shot is permitted.  Close time is symmetric.
-- ============================================================
local DOOR_OPEN_TIME  = 5.58
local DOOR_CLOSE_TIME = 5.58

-- ============================================================
-- WOOD PALLET PROP
-- ============================================================
local PALLET_MODEL    = "models/props/de_prodigy/wood_pallet_01.mdl"
local PALLET_LIFETIME = 20
-- NoCollide hold time between a pallet and the bomb that just dropped.
-- Keeps the pallet from blowing up the bomb after it goes physics.
local PALLET_NOCLIDE_HOLD = 2.0

-- Spawns a wood pallet as physics debris.
-- bombRef: the bomb entity to NoCollide against (may be nil for pure decoration).
-- Spawned via timer.Simple(0) so it lands in the NEXT physics tick,
-- preventing interpenetration with the bomb that was spawned this tick.
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
        -- NoCollide between pallet and the bomb so the pallet scatter
        -- impulse never reaches an armed munition.
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

-- ============================================================
-- CARGO DOOR
-- ============================================================
function C17_SetCargoDoor(planeEnt, open)
    if not IsValid(planeEnt) then return end
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
    self:SetNWBool("CargoDoorOpen", false)

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

    -- Weapon state.
    -- WPN_Phase values:
    --   nil / false = idle (no active weapon)
    --   "opening"   = door commanded open, waiting for animation to finish
    --   "firing"    = door fully open, actively shooting
    --   "closing"   = all shots done, door commanded closed, waiting for animation
    self.WPN_Active     = nil
    self.WPN_Phase      = nil
    self.WPN_ShotsFired = 0
    self.WPN_NextShot   = 0
    self.WPN_WindowEnd  = 0
    self.WPN_PhaseUntil = 0   -- time when current phase (opening/closing) finishes
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

    self.DesiredVelocity = Vector(0, 0, 0)

    self.OrbitAngle    = math.atan2(spawnOffset.y, spawnOffset.x)
    self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDirection

    self:Debug("C-17 spawned, orbit radius=" .. self.OrbitRadius .. " sky=" .. self.sky)
end

function ENT:Debug(msg)
    print("[Bombin C-17] " .. tostring(msg))
end

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

function ENT:UpdateOrbit(ct, dt)
    local phys = self.PhysObj
    if not IsValid(phys) then
        self.PhysObj = self:GetPhysicsObject()
        phys = self.PhysObj
    end
    if not IsValid(phys) then return end
    if phys:IsAsleep() then phys:Wake() end

    self.WanderPhaseX = self.WanderPhaseX + self.WanderRateX
    self.WanderPhaseY = self.WanderPhaseY + self.WanderRateY
    self.DynamicCenterPos.x = self.BaseCenterPos.x + math.sin(self.WanderPhaseX) * self.WanderAmp
    self.DynamicCenterPos.y = self.BaseCenterPos.y + math.cos(self.WanderPhaseY) * self.WanderAmp

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

    self.OrbitAngle = self.OrbitAngle + self.OrbitAngSpeed * dt

    if ct >= self.AltDriftNextPick then
        self.AltDriftNextPick = ct + math.Rand(12, 30)
        self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

    self.JitterPhase = self.JitterPhase + dt * 1.3
    local jitterZ = math.sin(self.JitterPhase) * self.JitterAmplitude

    local desZ   = self.AltDriftCurrent + jitterZ
    local curPos = self:GetPos()
    local velZ   = math.Clamp((desZ - curPos.z) * 8, -120, 120)

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

    local yawDelta    = math.NormalizeAngle(desiredYaw - prevYaw)
    local turnRate    = yawDelta / math.max(dt, 0.001)
    self.PrevTurnRate = Lerp(0.15, self.PrevTurnRate, turnRate)

    local targetRoll  = -math.Clamp(self.PrevTurnRate * ROLL_SUSTAINED_GAIN + turnRate * ROLL_TRANSIENT_GAIN, -ROLL_MAX, ROLL_MAX)
    local rollLerp    = (math.abs(targetRoll) > math.abs(self.SmoothedRoll)) and ROLL_LERP_IN or ROLL_LERP_OUT
    self.SmoothedRoll = Lerp(rollLerp, self.SmoothedRoll, targetRoll)

    local curVel  = phys:GetVelocity()
    local desVelX = math.cos(math.rad(desiredYaw)) * self.Speed
    local desVelY = math.sin(math.rad(desiredYaw)) * self.Speed
    self.DesiredVelocity = Vector(
        Lerp(0.12, curVel.x, desVelX),
        Lerp(0.12, curVel.y, desVelY),
        velZ
    )

    self.ang = Angle(-self.SmoothedRoll, self.flightYaw + MODEL_YAW_OFFSET, -self.SmoothedPitch)
    self:SetAngles(self.ang)
end

function ENT:PhysicsUpdate(phys, dt)
    if self.Destroyed then return end
    if not self.DesiredVelocity then return end
    if phys:IsAsleep() then phys:Wake() end
    phys:SetVelocity(self.DesiredVelocity)
end

function ENT:UpdateFade(dt)
    if not self.FadeIn then return end
    self.FadeAlpha = math.min(self.FadeAlpha + dt / self.FadeDuration * 255, 255)
    self:SetColor(Color(255, 255, 255, math.floor(self.FadeAlpha)))
    if self.FadeAlpha >= 255 then
        self:SetRenderMode(RENDERMODE_NORMAL)
        self.FadeIn = false
    end
end

function ENT:PickNewWeapon(ct)
    local available = {}
    for _, w in ipairs(WEAPON_ROSTER) do
        if w ~= "jassm" or self.JASSM_Stock > 0 then
            table.insert(available, w)
        end
    end
    if #available == 0 then return end
    local w = available[math.random(#available)]
    self.WPN_Active     = w
    self.WPN_Phase      = "opening"
    self.WPN_PhaseUntil = ct + DOOR_OPEN_TIME
    self.WPN_ShotsFired = 0
    -- WPN_NextShot and WPN_WindowEnd are set when we transition to "firing"
    self.WPN_NextShot   = 0
    self.WPN_WindowEnd  = 0
    -- Open the door now so the animation starts immediately.
    self:SetNWBool("CargoDoorOpen", true)
    self:Debug("Weapon window: " .. w .. " | door opening for " .. DOOR_OPEN_TIME .. "s")
end

-- ============================================================
-- UpdateWeapons  -  3-phase state machine
--
--  Phase "opening":
--    Door open command sent, waiting DOOR_OPEN_TIME for the client
--    animation to fully open before the first shot is allowed.
--
--  Phase "firing":
--    Door is fully open.  Each weapon's Update* function fires its
--    shots.  The weapon window timer only counts during this phase.
--    When all shots are done (or the window expires), we move to
--    "closing".
--
--  Phase "closing":
--    All shots fired.  Door close command sent, waiting DOOR_CLOSE_TIME
--    for the animation to fully close before starting the peace timer.
--    Only after this phase ends does WPN_PeaceUntil get set.
-- ============================================================
function ENT:UpdateWeapons(ct)
    -- Peace timer: nothing happens until it expires.
    if ct < self.WPN_PeaceUntil then return end

    -- No active weapon: pick one if a target exists.
    if not self.WPN_Active then
        if not IsValid(self:RefreshTarget(ct)) then return end
        self:PickNewWeapon(ct)
        return
    end

    -- ---- Phase: opening ----
    if self.WPN_Phase == "opening" then
        if ct < self.WPN_PhaseUntil then return end  -- still animating
        -- Door fully open - enter firing phase.
        self.WPN_Phase     = "firing"
        self.WPN_NextShot  = ct                        -- first shot may fire this tick
        self.WPN_WindowEnd = ct + 12
        self:Debug("Weapon window: " .. self.WPN_Active .. " | door open, firing begins")
        -- Fall through into the firing block below.
    end

    -- ---- Phase: firing ----
    if self.WPN_Phase == "firing" then
        local w    = self.WPN_Active
        local done = false

        -- Weapon window hard timeout (safety net).
        if ct > self.WPN_WindowEnd then
            done = true
        else
            if     w == "jassm"    then done = self:UpdateJASSM(ct)
            elseif w == "heavy"    then done = self:UpdateHeavy(ct)
            elseif w == "gbu53"    then done = self:UpdateGBU53(ct)
            elseif w == "retarded" then done = self:UpdateRetarded(ct)
            end
        end

        if done then
            -- All shots fired.  Close door and wait for animation.
            self.WPN_Phase      = "closing"
            self.WPN_PhaseUntil = ct + DOOR_CLOSE_TIME
            self:SetNWBool("CargoDoorOpen", false)
            self:Debug("Weapon window: " .. w .. " | shots done, door closing for " .. DOOR_CLOSE_TIME .. "s")
        end
        return
    end

    -- ---- Phase: closing ----
    if self.WPN_Phase == "closing" then
        if ct < self.WPN_PhaseUntil then return end  -- still animating
        -- Door fully closed - start peace timer.
        self:Debug("Weapon window: " .. self.WPN_Active .. " | door closed, peace timer started")
        self.WPN_Active     = nil
        self.WPN_Phase      = nil
        self.WPN_PeaceUntil = ct + math.Rand(CFG_PeacefulMin, CFG_PeacefulMax)
        return
    end
end

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

function ENT:DestroyPlane()
    if self.Destroyed then return end
    self.Destroyed = true
    self:SetNWBool("Destroyed", true)
    self:SetNWBool("CargoDoorOpen", false)
    -- Cancel any in-flight weapon state so UpdateWeapons never fires again.
    self.WPN_Active     = nil
    self.WPN_Phase      = nil
    self.WPN_PeaceUntil = math.huge
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

function ENT:OnRemove()
    if self.EngineSound then
        self.EngineSound:Stop()
        self.EngineSound = nil
    end
end

-- ============================================================
-- VELOCITY SOLVERS
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
    if hDist < 1 then return Vector(0, 0, 0) end
    local hSpeed = math.min(hDist / math.max(tF, 0.1), DART_SPEED)
    local hDir = Vector(dx, dy, 0):GetNormalized()
    return Vector(
        hDir.x * hSpeed + aircraftFwdVel.x,
        hDir.y * hSpeed + aircraftFwdVel.y,
        0
    )
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

-- ============================================================
-- SPAWN HELPERS
-- ============================================================
function ENT:SpawnDartBomb(entClass, dropPos, targetPos, isRetarded)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("SpawnDartBomb: class not found: " .. tostring(entClass))
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

    -- NoCollide bomb <-> plane before touching physics or arming.
    local handle = constraint.NoCollide(bomb, self, 0, 0)
    timer.Simple(0.6, function()
        if IsValid(handle) then handle:Remove() end
    end)

    -- Bug C fix: set velocity BEFORE arming.
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        bPhys:SetVelocity(CalcDartVelocity(dropPos, targetPos))
    end

    if bomb.Arm then bomb:Arm()
    elseif bomb.Armed ~= nil then bomb.Armed = true end

    return bomb
end

function ENT:SpawnCarpetBomb(entClass, dropPos, aimPos)
    local bomb = ents.Create(entClass)
    if not IsValid(bomb) then
        self:Debug("SpawnCarpetBomb: class not found: " .. tostring(entClass))
        return nil
    end
    bomb.IsOnPlane = true
    bomb.Launcher  = self
    bomb:SetOwner(self)
    bomb:SetPos(dropPos)
    bomb:SetAngles(Angle(90, self.flightYaw, 0))
    bomb:Spawn()
    bomb:Activate()

    local handle = constraint.NoCollide(bomb, self, 0, 0)
    timer.Simple(0.6, function()
        if IsValid(handle) then handle:Remove() end
    end)

    -- Bug C fix: velocity before arm.
    local bPhys = bomb:GetPhysicsObject()
    if IsValid(bPhys) then
        local aircraftFwd = Angle(0, self.flightYaw, 0):Forward() * self.Speed
        aircraftFwd.z = 0
        bPhys:SetVelocity(CalcCarpetImpulse(dropPos, aimPos, aircraftFwd))
    end

    if bomb.Arm then bomb:Arm()
    elseif bomb.Armed ~= nil then bomb.Armed = true end

    return bomb
end

-- ============================================================
-- W1: JASSM PARACHUTE DROP
-- ============================================================
function ENT:SpawnOneJASSM(dropIndex)
    dropIndex = dropIndex or 0

    local tailWorld = self:LocalToWorld(CFG_W1_JASSM_TailOffset)
    local dropPos = Vector(tailWorld.x, tailWorld.y, tailWorld.z - (dropIndex * CFG_W1_JASSM_AltOffset))
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - (dropIndex * CFG_W1_JASSM_AltOffset))
    end

    local missile = ents.Create("ent_bombin_jassm_owned")
    if not IsValid(missile) then
        self:Debug("W1 JASSM: ent_bombin_jassm_owned not found - dependency missing")
        return
    end

    local callDir = Angle(0, self.flightYaw, 0):Forward()
    local groundZ = self:FindGround(dropPos)
    if groundZ == -1 then groundZ = self.CenterPos.z end
    local dropHeight = math.max(dropPos.z - groundZ, 0)

    if dropHeight < CFG_W1_JASSM_MIN_DROP_HEIGHT then
        self:Debug("W1 JASSM: drop altitude too low (" .. math.Round(dropHeight) .. "u), aborting drop")
        return
    end

    local shaMax = (dropHeight - CFG_W1_JASSM_MIN_FREEFALL_CLEARANCE) / 1.25
    local sha    = math.max(shaMax, CFG_W1_JASSM_SHA_FLOOR)

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
    missile.IsOnPlane = true
    missile.Launcher  = self
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
        local cPlaneHandle   = constraint.NoCollide(chute, self, 0, 0)
        local cMissileHandle = constraint.NoCollide(chute, missile, 0, 0)
        timer.Simple(1.25, function()
            if IsValid(cPlaneHandle)   then cPlaneHandle:Remove()   end
            if IsValid(cMissileHandle) then cMissileHandle:Remove() end
        end)
    else
        self:Debug("W1 JASSM: ent_bombin_jassm_chute_owned not found - chute missing")
    end

    SpawnWoodPallet(dropPos + Vector(0,0,-20), Vector(math.Rand(-60,60), math.Rand(-60,60), -80), nil)

    if self.JASSM_Stock > 0 then
        self.JASSM_Stock = self.JASSM_Stock - 1
    end
    self:Debug("W1 JASSM drop #" .. (dropIndex+1) .. " pos=" .. tostring(dropPos) .. " SHA=" .. math.Round(sha) .. " dropHeight=" .. math.Round(dropHeight))
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

    local entry     = CFG_W2_Pool[math.random(#CFG_W2_Pool)]
    local dropPos   = self:LocalToWorld(CFG_BombBayLocal)
    local targetPos = self:GetAimPos(CFG_W2_Scatter)
    local bomb      = self:SpawnDartBomb(entry.class, dropPos, targetPos, entry.retarded)
    SpawnWoodPallet(dropPos + Vector(0,0,-10), Vector(math.Rand(-80,80), math.Rand(-80,80), -60), bomb)
    return (self.WPN_ShotsFired >= CFG_W2_Count)
end

-- ============================================================
-- W3: GBU-53 PARACHUTE CLUSTER DROP
-- ============================================================
function ENT:SpawnOneGBU53Pallet(palletIndex)
    palletIndex = palletIndex or 0

    -- All 3 pallets spawn at the same cargo door position.
    -- The 1.2s inter-shot delay (CFG_W3_GBU53_Delay) provides
    -- the only separation needed; pallets drift apart naturally
    -- during free-fall once released.
    local tailWorld = self:LocalToWorld(CFG_W3_DropOffset)
    local dropPos = Vector(
        tailWorld.x,
        tailWorld.y,
        tailWorld.z - CFG_W3_BodyClearance
    )
    if not util.IsInWorld(dropPos) then
        dropPos = Vector(self.CenterPos.x, self.CenterPos.y, self:GetPos().z - CFG_W3_BodyClearance)
    end

    local pallet = ents.Create("ent_bombin_gbu53_owned")
    if not IsValid(pallet) then
        self:Debug("W3 GBU53: ent_bombin_gbu53_owned not found")
        return
    end

    local callDir = Angle(0, self.flightYaw, 0):Forward()

    pallet:SetPos(dropPos)
    pallet:SetAngles(Angle(0, self.flightYaw, 0))
    pallet.SpawnedFromPlane = true
    pallet.CenterPos    = self.CenterPos
    pallet.CallDir      = callDir
    pallet.Lifetime     = math.min(self.Lifetime or 120, 60)
    pallet.Speed        = 420
    pallet.OrbitRadius  = self.OrbitRadius
    local groundZ = self:FindGround(dropPos)
    if groundZ == -1 then
        pallet.SkyHeightAdd = 1200
    else
        pallet.SkyHeightAdd = math.max(dropPos.z - groundZ, 1200)
    end
    pallet:SetOwner(self)
    pallet.IsOnPlane = true
    pallet.Launcher  = self
    pallet:Spawn()
    pallet:Activate()

    local pHandle = constraint.NoCollide(pallet, self, 0, 0)
    timer.Simple(CFG_W3_NoCollideHoldTime, function()
        if IsValid(pHandle) then pHandle:Remove() end
    end)

    SpawnWoodPallet(dropPos + Vector(0,0,-15), Vector(math.Rand(-50,50), math.Rand(-50,50), -70), nil)
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
    local bomb      = self:SpawnDartBomb(entClass, dropPos, aimPos, true)
    if self.WPN_ShotsFired == 1 then
        SpawnWoodPallet(dropPos + Vector(0,0,-10), Vector(math.Rand(-50,50), math.Rand(-50,50), -60), bomb)
    end
    return (self.WPN_ShotsFired >= CFG_W6_Count)
end

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
