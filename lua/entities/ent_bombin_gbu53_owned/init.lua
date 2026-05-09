-- ============================================================
-- ent_bombin_gbu53_owned  —  SERVER
-- GBU-53/B StormBreaker owned variant.
-- Spawned by the AC-130 support plane.  Rides under a
-- chute+palette assembly (ent_bombin_gbu53_chute_owned) during
-- freefall, ignites at IgnitionAlt, then orbits and dives.
--
-- Interface  (set via SetVar before Spawn+Activate):
--   CenterPos            Vector   — target area centre
--   CallDir              Vector   — plane heading at drop
--   Lifetime             number   — seconds before auto-remove  (default 60)
--   SkyHeightAdd         number   — ground + this = sky ceiling (default 2500)
--   OrbitRadius          number   — orbit radius in units       (default 2500)
--   Speed                number   — cruise speed in u/s         (default 250)
--   DIVE_ExplosionDamage number
--   DIVE_ExplosionRadius number
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_trailsystem.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- LOCAL CONSTANTS
-- ============================================================

local SHARD_MODEL          = "models/props_c17/FurnitureDrawer001a_Shard01.mdl"
local GRAVITY_MULT         = 1.1
local SHARD_LIFE           = 8

local GLIDE_BLEED_RATE     = 8.0    -- u/s altitude loss while orbiting
local GROUND_DETONATE_DIST = 80     -- detonate when this many u above ground

-- Freefall physics constants (must match chute expectations)
local FREEFALL_GRAVITY     = 600    -- u/s²
local TERMINAL_VEL         = -320   -- max downward speed (u/s)
local HORIZ_GLIDE_MAX      = 380    -- horizontal speed at full ramp
local HORIZ_GLIDE_RAMP     = 1.4   -- seconds to reach max horiz speed

-- Ignition altitude above the calculated ground
-- Range: SkyHeightAdd * 0.35  (≈875 u above ground for default 2500)
local IGNITION_ALT_FRAC    = 0.35

ENT.WeaponWindow  = 8
ENT.FadeDuration  = 0.0   -- no fade-in; appears solid from drop

ENT.DIVE_Speed         = 1800
ENT.DIVE_TrackInterval = 0.1

util.AddNetworkString("bombin_gbu53owned_damage_tier")

-- ============================================================
-- TIER HELPERS
-- ============================================================

local function CalcTier(hp, maxHP)
	local frac = hp / maxHP
	if frac > 0.66 then return 0 end
	if frac > 0.33 then return 1 end
	if hp   > 0    then return 2 end
	return 3
end

local function BroadcastTier(ent, tier)
	net.Start("bombin_gbu53owned_damage_tier")
		net.WriteUInt(ent:EntIndex(), 16)
		net.WriteUInt(tier, 2)
	net.Broadcast()
end

-- ============================================================
-- DEBUG
-- ============================================================

function ENT:Debug(msg)
	print("[Bombin GBU53-Owned] " .. tostring(msg))
end

-- ============================================================
-- INITIALIZE
-- ============================================================

function ENT:Initialize()
	self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
	self.CallDir      = self:GetVar("CallDir",      Vector(1,0,0))
	self.Lifetime     = self:GetVar("Lifetime",     60)
	self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 2500)

	self.DIVE_ExplosionDamage = self:GetVar("DIVE_ExplosionDamage", 700)
	self.DIVE_ExplosionRadius = self:GetVar("DIVE_ExplosionRadius", 900)

	self.MaxHP = 200

	-- Sanitise CallDir
	if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
	self.CallDir.z = 0
	self.CallDir:Normalize()

	local ground = self:FindGround(self.CenterPos)
	if ground == -1 then self:Debug("FindGround failed") self:Remove() return end
	self.GroundZ = ground

	-- Sky altitude with ±25% variance (matches JASSM pattern)
	local altVar = self.SkyHeightAdd * 0.25
	self.sky = ground + self.SkyHeightAdd + math.Rand(-altVar, altVar)

	-- Ignition altitude: IGNITION_ALT_FRAC of SkyHeightAdd above ground,
	-- with ±25% local variance so salvos don't all ignite together.
	local ignBase = ground + (self.SkyHeightAdd * IGNITION_ALT_FRAC)
	local ignVar  = self.SkyHeightAdd * IGNITION_ALT_FRAC * 0.25
	self.IgnitionAlt = ignBase + math.Rand(-ignVar, ignVar)

	self.DieTime   = CurTime() + self.Lifetime
	self.SpawnTime = CurTime()

	-- --------------------------------------------------------
	-- FREEFALL PHASE: spawn at sky, not in orbit yet
	-- --------------------------------------------------------
	self.Phase = "freefall"   -- "freefall" | "orbit"
	self.FreefallVelZ      = 0
	self.FreefallHorizT    = 0
	self.FreefallHorizSpeed = 0

	local baseRadius = self:GetVar("OrbitRadius", 2500)
	local baseSpeed  = self:GetVar("Speed",        250)
	self.OrbitRadius = baseRadius * math.Rand(0.82, 1.18)
	self.Speed       = baseSpeed  * math.Rand(0.85, 1.15)
	self.OrbitDir    = (math.random(0,1) == 0) and 1 or -1

	-- Spawn directly above CenterPos at sky altitude, offset by tail offset
	-- (mirrors the JASSM JASSM_TailOffset logic but simpler: just behind)
	local tailOffset = self.CallDir * -200
	local spawnPos   = Vector(
		self.CenterPos.x + tailOffset.x,
		self.CenterPos.y + tailOffset.y,
		self.sky
	)

	if not util.IsInWorld(spawnPos) then
		spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
	end
	if not util.IsInWorld(spawnPos) then
		self:Debug("Spawn position out of world") self:Remove() return
	end

	-- Model and physics — MOVETYPE_NONE during freefall (manual integration)
	self:SetModel("models/sw/usa/bombs/guided/gbu53.mdl")
	self:SetModelScale(1.0, 0)
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_NONE)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:SetPos(spawnPos)
	self:SetRenderMode(RENDERMODE_NORMAL)

	self:SetNWInt("HP",    self.MaxHP)
	self:SetNWInt("MaxHP", self.MaxHP)
	self:SetNWBool("Destroyed",  false)
	self:SetNWBool("EngineOn",   false)   -- CRITICAL: chute listens to this

	-- Face along CallDir
	local faceAng = self.CallDir:Angle()
	self:SetAngles(Angle(0, faceAng.y, 0))
	self.ang = self:GetAngles()

	self.SmoothedRoll  = 0
	self.SmoothedPitch = 0
	self.PrevYaw       = self.ang.y

	-- Orbit / glide state (populated at ignition)
	self.OrbitAngle    = 0
	self.OrbitAngSpeed = 0

	self.JitterPhase  = math.Rand(0, math.pi * 2)
	self.JitterPhase2 = math.Rand(0, math.pi * 2)
	self.JitterAmp1   = math.Rand(40,  80)
	self.JitterAmp2   = math.Rand(90, 180)
	self.JitterRate1  = math.Rand(0.040, 0.090)
	self.JitterRate2  = math.Rand(0.012, 0.025)

	self.GlideRollPhase = math.Rand(0, math.pi * 2)
	self.GlideRollAmp   = math.Rand(18, 38)
	self.GlideRollRate  = math.Rand(0.8, 1.6)

	self.GlideBleedRate = GLIDE_BLEED_RATE

	self.AltDriftCurrent  = self.sky
	self.AltDriftTarget   = self.sky
	self.AltDriftNextPick = CurTime() + math.Rand(8, 20)
	self.AltDriftRange    = 700
	self.AltDriftLerp     = 0.003

	self.BaseCenterPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z)
	self.WanderPhaseX  = math.Rand(0, math.pi * 2)
	self.WanderPhaseY  = math.Rand(0, math.pi * 2)
	self.WanderAmp     = math.Rand(60, 160)
	self.WanderRateX   = math.Rand(0.004, 0.010)
	self.WanderRateY   = math.Rand(0.003, 0.009)

	self.CurrentWeapon   = nil
	self.WeaponWindowEnd = 0

	self.Diving        = false
	self.DiveTarget    = nil
	self.DiveTargetPos = nil
	self.DiveNextTrack = 0
	self.DiveExploded  = false
	self.DiveAimOffset = Vector(0,0,0)

	self.DiveWobblePhase  = 0
	self.DiveWobbleAmp    = 180
	self.DiveWobbleSpeed  = 4.5
	self.DiveWobblePhaseV = math.Rand(0, math.pi * 2)
	self.DiveWobbleAmpV   = 130
	self.DiveWobbleSpeedV = 3.1

	self.DiveSpeedMin     = self.DIVE_Speed * 0.55
	self.DiveSpeedCurrent = self.DIVE_Speed * 0.55
	self.DiveSpeedLerp    = 0.018

	self.DivePitchTelegraph = 0

	self.Destroyed       = false
	self.DestroyedTime   = nil
	self.TumbleAngVel    = Vector(0,0,0)
	self.ExplodeTimer    = nil
	self.ExplodedAlready = false

	self.DamageTier = 0

	self.SkyYawBias      = 0
	self.SkyProbeDist    = math.max(1200, self.Speed * 6)
	self.SkyProbeLastHit = 0

	self.ObsLastEval   = 0
	self.ObsYawBias    = 0
	self.ObsAltBias    = 0
	self.ObsConsecHits = 0

	-- Spawn chute+palette assembly above us
	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChute()
	end)

	self:Debug("Spawned at " .. tostring(spawnPos) .. " — freefall phase, ignAt=" .. math.Round(self.IgnitionAlt))
end

-- ============================================================
-- CHUTE SPAWN
-- ============================================================

function ENT:SpawnChute()
	local chute = ents.Create("ent_bombin_gbu53_chute_owned")
	if not IsValid(chute) then
		self:Debug("Failed to create chute entity")
		return
	end
	chute:SetOwner(self)
	chute:SetPos(self:GetPos() + Vector(0, 0, 105))
	chute:SetAngles(self:GetAngles())
	chute:Spawn()
	chute:Activate()
	self.ChuteEnt = chute
end

-- ============================================================
-- FREEFALL PHYSICS
-- ============================================================

function ENT:UpdateFreefall(dt)
	-- Gravity with proportional drag to achieve terminal velocity
	local k = FREEFALL_GRAVITY / math.abs(TERMINAL_VEL)   -- drag coefficient
	self.FreefallVelZ = self.FreefallVelZ - FREEFALL_GRAVITY * dt
	local drag = k * math.abs(self.FreefallVelZ)
	self.FreefallVelZ = self.FreefallVelZ + drag * dt
	self.FreefallVelZ = math.max(self.FreefallVelZ, TERMINAL_VEL)

	-- Horizontal glide ramp along CallDir
	self.FreefallHorizT = math.min(self.FreefallHorizT + dt, HORIZ_GLIDE_RAMP)
	self.FreefallHorizSpeed = (self.FreefallHorizT / HORIZ_GLIDE_RAMP) * HORIZ_GLIDE_MAX

	local pos = self:GetPos()
	local newPos = Vector(
		pos.x + self.CallDir.x * self.FreefallHorizSpeed * dt,
		pos.y + self.CallDir.y * self.FreefallHorizSpeed * dt,
		pos.z + self.FreefallVelZ * dt
	)

	-- Cosmetic attitude
	local speedFrac = math.abs(self.FreefallVelZ) / math.abs(TERMINAL_VEL)
	local targetPitch = -25 * speedFrac
	self.SmoothedPitch = Lerp(0.06, self.SmoothedPitch, targetPitch)
	local faceAng = self.CallDir:Angle()
	self.ang.y = faceAng.y
	self.ang.p = self.SmoothedPitch
	self.ang.r = 0
	self:SetAngles(self.ang)
	self:SetPos(newPos)

	-- Check ignition altitude
	if newPos.z <= self.IgnitionAlt then
		newPos.z = self.IgnitionAlt   -- snap to prevent overshoot
		self:SetPos(newPos)
		self:IgniteEngine()
	end
end

-- ============================================================
-- ENGINE IGNITION
-- ============================================================

function ENT:IgniteEngine()
	if self.Phase == "orbit" then return end
	self.Phase = "orbit"

	self:Debug("Engine ignited at Z=" .. math.Round(self:GetPos().z))

	-- Signal the chute to detach (same NWBool pattern as JASSM)
	self:SetNWBool("EngineOn", true)

	-- Switch to VPhysics for orbit phase
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)

	self.PhysObj = self:GetPhysicsObject()
	if IsValid(self.PhysObj) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity(false)
		-- Seed momentum: preserve horizontal glide speed into orbit entry
		local seedVel = self.CallDir * math.max(self.Speed, self.FreefallHorizSpeed)
		seedVel.z = 0
		self.PhysObj:SetVelocity(seedVel)
	end

	-- Initialise orbit from current position
	local pos = self:GetPos()
	self.OrbitAngle = math.atan2(
		pos.y - self.CenterPos.y,
		pos.x - self.CenterPos.x
	)
	self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDir

	-- Set orbit altitude start to current position (climbs naturally via AltDrift)
	self.AltDriftCurrent = pos.z
	self.AltDriftTarget  = pos.z + 600   -- climb 600 u after ignition

	-- Ignition flash effect
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetScale(2)
	util.Effect("HelicopterMegaBomb", ed, true, true)
	sound.Play("ambient/explosions/exp_smoke.wav", pos, 95, 110, 0.9)
end

-- ============================================================
-- THINK
-- ============================================================

function ENT:Think()
	if not self.DieTime or not self.SpawnTime then
		self:NextThink(CurTime() + 0.1)
		return true
	end

	local ct = CurTime()
	if ct >= self.DieTime then self:Remove() return end

	local dt = FrameTime()
	if dt <= 0 then dt = 0.015 end

	-- --------------------------------------------------------
	-- FREEFALL PHASE
	-- --------------------------------------------------------
	if self.Phase == "freefall" then
		self:UpdateFreefall(dt)
		self:NextThink(ct + 0.015)
		return true
	end

	-- --------------------------------------------------------
	-- ORBIT / DIVE PHASE  (identical to standalone GBU-53)
	-- --------------------------------------------------------
	if not IsValid(self.PhysObj) then
		self.PhysObj = self:GetPhysicsObject()
	end
	local phys = self.PhysObj
	if IsValid(phys) and phys:IsAsleep() then phys:Wake() end

	-- Explode timer for shot-down state
	if self.Destroyed then
		if self.ExplodeTimer and ct >= self.ExplodeTimer and not self.ExplodedAlready then
			self:CrashExplode(self:GetPos())
		end
		if self.Diving then self:UpdateDive(ct) end
		self:NextThink(ct + 0.05)
		return true
	end

	local elapsed = ct - self.SpawnTime
	if elapsed >= self.WeaponWindow and not self.Diving then
		self:HandleWeaponWindow(ct)
	end

	if self.Diving then
		self:UpdateDive(ct)
		self:NextThink(ct + 0.01)
		return true
	end

	self:UpdateOrbit(ct, phys)
	self:NextThink(ct + 0.01)
	return true
end

-- ============================================================
-- ORBIT
-- ============================================================

function ENT:UpdateOrbit(ct, phys)
	local dt = FrameTime()
	if dt <= 0 then dt = 0.01 end

	-- Sky evasion probe
	local fwdProbe = self:GetForward() * self.SkyProbeDist
	local skyTr = util.TraceLine({
		start  = self:GetPos(),
		endpos = self:GetPos() + fwdProbe,
		filter = self,
		mask   = MASK_SKY,
	})
	if skyTr.Hit and (ct - self.SkyProbeLastHit) > 2.0 then
		self.SkyProbeLastHit = ct
		self.SkyYawBias = self.OrbitDir * math.Rand(0.3, 0.7)
	end
	self.SkyYawBias = self.SkyYawBias * 0.97

	-- Obstacle evasion
	if ct >= self.ObsLastEval + 0.3 then
		self.ObsLastEval = ct
		local probeDist  = math.max(800, self.Speed * 3)
		local hits       = 0
		local probeAngles = { 0, 15, -15, 30, -30 }
		for _, yawOff in ipairs(probeAngles) do
			local probeDir = Angle(0, self.ang.y + yawOff, 0):Forward() * probeDist
			local obsTr    = util.TraceLine({
				start  = self:GetPos(),
				endpos = self:GetPos() + probeDir,
				filter = self,
				mask   = MASK_SOLID_BRUSHONLY,
			})
			if obsTr.Hit then hits = hits + 1 end
		end
		if hits > 0 then
			self.ObsConsecHits = self.ObsConsecHits + 1
			local biasMag = math.Clamp(self.ObsConsecHits * 0.15, 0.1, 0.8)
			self.ObsYawBias = self.OrbitDir * biasMag
			self.ObsAltBias = 80
		else
			self.ObsConsecHits = math.max(0, self.ObsConsecHits - 1)
			self.ObsYawBias    = self.ObsYawBias * 0.93
			self.ObsAltBias    = self.ObsAltBias * 0.95
		end
	end

	local totalBias = self.SkyYawBias + self.ObsYawBias
	self.OrbitAngle = self.OrbitAngle + (self.OrbitAngSpeed + totalBias) * dt

	local cx = self.BaseCenterPos.x + math.sin(ct * self.WanderRateX + self.WanderPhaseX) * self.WanderAmp
	local cy = self.BaseCenterPos.y + math.sin(ct * self.WanderRateY + self.WanderPhaseY) * self.WanderAmp
	self.CenterPos = Vector(cx, cy, self.CenterPos.z)

	local desiredX = cx + math.cos(self.OrbitAngle) * self.OrbitRadius
	local desiredY = cy + math.sin(self.OrbitAngle) * self.OrbitRadius

	-- Altitude bleed (glide loses height constantly)
	self.sky = self.sky - self.GlideBleedRate * dt
	self.sky = math.max(self.sky, self.GroundZ + GROUND_DETONATE_DIST + 50)

	if ct >= self.AltDriftNextPick then
		local halfRange = self.AltDriftRange * 0.3
		self.AltDriftTarget   = self.sky + math.Rand(-halfRange, halfRange)
		self.AltDriftNextPick = ct + math.Rand(8, 20)
	end
	self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

	local jitter  =  math.sin(ct * self.JitterRate1 * math.pi * 2 + self.JitterPhase)  * self.JitterAmp1
	             +  math.sin(ct * self.JitterRate2 * math.pi * 2 + self.JitterPhase2) * self.JitterAmp2
	local liveAlt = self.AltDriftCurrent + jitter + self.ObsAltBias

	-- Ground proximity detonation
	if not self.ExplodedAlready then
		local heightAboveGround = liveAlt - self.GroundZ
		if heightAboveGround <= GROUND_DETONATE_DIST then
			self:Debug("Altitude bleed reached ground — impact detonation")
			local impactPos = Vector(self:GetPos().x, self:GetPos().y, self.GroundZ + 10)
			self:DiveExplode(impactPos)
			return
		end
	end

	local pos    = self:GetPos()
	local posErr = Vector(desiredX - pos.x, desiredY - pos.y, 0)
	local vel    = self:GetForward() * self.Speed
	if posErr:LengthSqr() > 400 then
		vel = vel + posErr:GetNormalized() * 80
	end

	self:SetPos(Vector(pos.x, pos.y, liveAlt))

	self.ang.y = math.atan2(desiredY - pos.y, desiredX - pos.x) * (180 / math.pi)

	local rawYawDelta = math.NormalizeAngle(self.ang.y - (self.PrevYaw or self.ang.y))
	self.PrevYaw = self.ang.y

	local targetRoll = math.Clamp(rawYawDelta * -25, -30, 30)
	local glideSway  = math.sin(ct * self.GlideRollRate + self.GlideRollPhase) * self.GlideRollAmp
	self.SmoothedRoll = Lerp(rawYawDelta ~= 0 and 0.15 or 0.05, self.SmoothedRoll, targetRoll + glideSway)

	local physVel      = IsValid(phys) and phys:GetVelocity() or Vector(0,0,0)
	local forwardSpeed = physVel:Dot(self:GetForward())
	local speedRatio   = math.Clamp(forwardSpeed / self.Speed, 0, 1)
	local targetPitch  = math.Clamp(speedRatio * 10, -15, 15)
	self.SmoothedPitch = Lerp(0.04, self.SmoothedPitch, targetPitch)

	self.ang.p = self.SmoothedPitch
	self.ang.r = self.SmoothedRoll
	self:SetAngles(self.ang)

	if IsValid(phys) then phys:SetVelocity(vel) end

	if not self:IsInWorld() then
		self:Debug("Out of world — center recovery")
		local safePos = Vector(self.BaseCenterPos.x, self.BaseCenterPos.y, self.sky)
		self:SetPos(safePos)
		if IsValid(phys) then phys:SetVelocity(Vector(0,0,0)) end
		self.OrbitAngle = math.atan2(safePos.y - self.CenterPos.y, safePos.x - self.CenterPos.x)
	end
end

-- ============================================================
-- GROUND FINDER
-- ============================================================

function ENT:FindGround(pos)
	local tr = util.TraceLine({
		start  = Vector(pos.x, pos.y, pos.z + 100),
		endpos = Vector(pos.x, pos.y, pos.z - 32768),
		mask   = MASK_SOLID_BRUSHONLY,
	})
	if tr.Hit then return tr.HitPos.z end
	return -1
end

-- ============================================================
-- TARGET
-- ============================================================

function ENT:GetPrimaryTarget()
	local closest, closestDist = nil, math.huge
	for _, ply in ipairs(player.GetAll()) do
		if not IsValid(ply) or not ply:Alive() then continue end
		local d = ply:GetPos():DistToSqr(self.CenterPos)
		if d < closestDist then closestDist = d; closest = ply end
	end
	return closest
end

-- ============================================================
-- WEAPON WINDOW
-- ============================================================

function ENT:HandleWeaponWindow(ct)
	if not self.CurrentWeapon or ct >= self.WeaponWindowEnd then
		self:PickNewWeapon(ct)
	end
	if self.CurrentWeapon == "dive" then
		self:InitDive(ct)
	end
end

function ENT:PickNewWeapon(ct)
	local roll = math.random(1, 3)
	if roll == 1 then
		self.CurrentWeapon = "peaceful_1"
	elseif roll == 2 then
		self.CurrentWeapon = "peaceful_2"
	else
		self.CurrentWeapon = "dive"
	end
	self.WeaponWindowEnd = ct + self.WeaponWindow
	self:Debug("Behavior slot: " .. self.CurrentWeapon)
end

-- ============================================================
-- DIVE
-- ============================================================

function ENT:InitDive(ct)
	if self.Diving then return end

	if not self.DiveCommitTime then
		self.DiveCommitTime = ct + 1.0
		self:Debug("DIVE: locking target in 1s...")
		return
	end

	local commitFraction    = math.Clamp((ct - (self.DiveCommitTime - 1.0)) / 1.0, 0, 1)
	self.DivePitchTelegraph = commitFraction * -60
	self:SetAngles(Angle(self.DivePitchTelegraph, self.ang.y, self.SmoothedRoll))

	if ct < self.DiveCommitTime then return end

	local target = self:GetPrimaryTarget()
	if not IsValid(target) then
		self.CurrentWeapon      = nil
		self.DiveCommitTime     = nil
		self.DivePitchTelegraph = 0
		return
	end

	self.Diving             = true
	self.DiveTarget         = target
	self.DiveTargetPos      = target:GetPos()
	self.DiveNextTrack      = ct
	self.DiveExploded       = false
	self.DiveCommitTime     = nil
	self.DivePitchTelegraph = 0

	self.DiveWobblePhase  = 0
	self.DiveWobblePhaseV = math.Rand(0, math.pi * 2)
	self.DiveSpeedCurrent = self.DiveSpeedMin

	self.DiveAimOffset = Vector(
		math.Rand(-400, 400),
		math.Rand(-400, 400),
		0
	)

	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:SetSolid(SOLID_VPHYSICS)
	if IsValid(self.PhysObj) then
		self.PhysObj:EnableGravity(false)
	end

	self:Debug("DIVE: committed — aim offset " .. tostring(self.DiveAimOffset))
end

function ENT:UpdateDive(ct)
	if self.DiveExploded then return end

	if ct >= self.DiveNextTrack then
		if not self:IsDestroyed() then
			if IsValid(self.DiveTarget) and self.DiveTarget:Alive() then
				self.DiveTargetPos = self.DiveTarget:GetPos() + Vector(
					math.Rand(-120,120), math.Rand(-120,120), 0)
				end
			end
		self.DiveNextTrack = ct + self.DIVE_TrackInterval
	end

	if not self.DiveTargetPos then
		local t = self:GetPrimaryTarget()
		if IsValid(t) then
			self.DiveTargetPos = t:GetPos()
		else
			self:Remove()
			return
		end
	end

	local aimPos = self.DiveTargetPos + self.DiveAimOffset
	local myPos  = self:GetPos()
	local dir    = aimPos - myPos
	local dist   = dir:Length()

	if dist < 120 then
		if self:IsDestroyed() then
			self:CrashExplode(myPos)
		else
			self:DiveExplode(myPos)
		end
		return
	end

	dir:Normalize()
	if self:IsDestroyed() then return end

	self.DiveSpeedCurrent = Lerp(self.DiveSpeedLerp, self.DiveSpeedCurrent, self.DIVE_Speed)

	local dt = FrameTime()
	self.DiveWobblePhase  = self.DiveWobblePhase  + self.DiveWobbleSpeed  * dt
	self.DiveWobblePhaseV = self.DiveWobblePhaseV + self.DiveWobbleSpeedV * dt

	local flatRight = Vector(-dir.y, dir.x, 0)
	if flatRight:LengthSqr() < 0.01 then flatRight = Vector(1, 0, 0) end
	flatRight:Normalize()
	local worldUp = Vector(0, 0, 1)
	local upPerp  = worldUp - dir * dir:Dot(worldUp)
	if upPerp:LengthSqr() < 0.01 then upPerp = Vector(0, 1, 0) end
	upPerp:Normalize()

	local wobbleScale = math.Clamp(dist / 400, 0, 1)
	local wobbleVel   =
		flatRight * math.sin(self.DiveWobblePhase)  * self.DiveWobbleAmp  * wobbleScale +
		upPerp    * math.sin(self.DiveWobblePhaseV) * self.DiveWobbleAmpV * wobbleScale

	local totalVel = dir * self.DiveSpeedCurrent + wobbleVel

	if totalVel:LengthSqr() > 0.01 then
		local faceAng = totalVel:GetNormalized():Angle()
		faceAng.r = 0
		self:SetAngles(faceAng)
		self.ang = faceAng
	end

	local nextPos = myPos + totalVel * dt
	local tr = util.TraceLine({
		start  = myPos,
		endpos = nextPos,
		filter = self,
		mask   = MASK_SOLID,
	})
	if tr.Hit then self:DiveExplode(tr.HitPos) return end

	if IsValid(self.PhysObj) then
		self.PhysObj:SetVelocity(totalVel)
	end
end

-- ============================================================
-- DAMAGE
-- ============================================================

function ENT:IsDestroyed()
	return self.Destroyed == true
end

function ENT:SpawnDebrisShards()
	local count   = math.random(1, 2)
	local origin  = self:GetPos()
	local baseVel = self:GetVelocity()
	for i = 1, count do
		local shard = ents.Create("prop_physics")
		if not IsValid(shard) then continue end
		shard:SetModel(SHARD_MODEL)
		shard:SetPos(origin + Vector(math.Rand(-30,30), math.Rand(-30,30), math.Rand(-20,20)))
		shard:SetAngles(Angle(math.Rand(0,360), math.Rand(0,360), math.Rand(0,360)))
		shard:Spawn()
		shard:Activate()
		shard:SetColor(Color(15, 10, 10, 255))
		shard:SetMaterial("models/debug/debugwhite")
		local phys = shard:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:SetVelocity(baseVel * 0.3 + Vector(
				math.Rand(-300,300), math.Rand(-300,300), math.Rand(50,250)))
			phys:AddAngleVelocity(Vector(
				math.Rand(-200,200), math.Rand(-200,200), math.Rand(-200,200)))
		end
		shard:Ignite(SHARD_LIFE, 0)
		timer.Simple(SHARD_LIFE, function()
			if IsValid(shard) then shard:Remove() end
		end)
	end
end

function ENT:SetDestroyed()
	if self.Destroyed then return end
	self.Destroyed = true
	self:SetNWBool("Destroyed", true)
	self.DestroyedTime = CurTime()

	BroadcastTier(self, 3)

	if IsValid(self.PhysObj) then
		self.TumbleAngVel = self.PhysObj:GetAngleVelocity() + Vector(
			math.Rand(-120,120), math.Rand(-120,120), math.Rand(-120,120))
		self.PhysObj:EnableGravity(true)
		self.PhysObj:AddAngleVelocity(self.TumbleAngVel)
	end

	self:Ignite(20, 0)
	self:SpawnDebrisShards()

	local altAboveGround = self:GetPos().z - (self.sky - self.SkyHeightAdd)
	local delay = math.Clamp(altAboveGround / 600, 3, 12)
	self.ExplodeTimer = CurTime() + delay

	if not self.Diving then self.CurrentWeapon = nil end
	self:Debug("DESTROYED — boom in " .. math.Round(delay,1) .. "s")
end

function ENT:OnTakeDamage(dmginfo)
	if self.ExplodedAlready then return end
	if self.Destroyed       then return end
	if dmginfo:IsDamageType(DMG_CRUSH) then return end

	local hp = self:GetNWInt("HP", self.MaxHP or 200)
	hp = hp - dmginfo:GetDamage()
	self:SetNWInt("HP", hp)

	local newTier = CalcTier(math.max(hp, 0), self.MaxHP)
	if newTier ~= self.DamageTier then
		self.DamageTier = newTier
		BroadcastTier(self, newTier)
	end

	if hp <= 0 and not self:IsDestroyed() then
		self:Debug("Shot down!")
		self:SetDestroyed()
	end
end

-- ============================================================
-- EXPLOSIONS
-- ============================================================

function ENT:DiveExplode(pos)
	if self.DiveExploded then return end
	self.DiveExploded    = true
	self.ExplodedAlready = true
	self:Debug("DIVE/IMPACT: exploding at " .. tostring(pos))

	local ed1 = EffectData()
	ed1:SetOrigin(pos)
	ed1:SetScale(8) ed1:SetMagnitude(8) ed1:SetRadius(800)
	util.Effect("HelicopterMegaBomb", ed1, true, true)

	local ed2 = EffectData()
	ed2:SetOrigin(pos)
	ed2:SetScale(6) ed2:SetMagnitude(6) ed2:SetRadius(700)
	util.Effect("500lb_air", ed2, true, true)

	local ed3 = EffectData()
	ed3:SetOrigin(pos + Vector(0,0,80))
	ed3:SetScale(5) ed3:SetMagnitude(5) ed3:SetRadius(600)
	util.Effect("500lb_air", ed3, true, true)

	local ed4 = EffectData()
	ed4:SetOrigin(pos + Vector(0,0,-20))
	ed4:SetScale(4) ed4:SetMagnitude(4) ed4:SetRadius(500)
	util.Effect("HelicopterMegaBomb", ed4, true, true)

	sound.Play("weapon_AWP.Single",               pos,                155, 55, 1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos,                150, 80, 1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos + Vector(0,0,50), 145, 95, 0.8)

	util.BlastDamage(self, self, pos, self.DIVE_ExplosionRadius, self.DIVE_ExplosionDamage)
	self:Remove()
end

function ENT:CrashExplode(pos)
	if self.ExplodedAlready then return end
	self.ExplodedAlready = true
	self:Debug("CRASH: exploding at " .. tostring(pos))

	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetScale(4) ed:SetMagnitude(4) ed:SetRadius(400)
	util.Effect("HelicopterMegaBomb", ed, true, true)

	local ed2 = EffectData()
	ed2:SetOrigin(pos)
	ed2:SetScale(3) ed2:SetMagnitude(3) ed2:SetRadius(300)
	util.Effect("500lb_air", ed2, true, true)

	sound.Play("ambient/explosions/explode_8.wav", pos, 140, 78, 1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos, 135, 92, 0.7)

	local crashDmg = self.DIVE_ExplosionDamage * 0.3
	local crashRad = self.DIVE_ExplosionRadius * 0.6
	util.BlastDamage(self, self, pos, crashRad, crashDmg)
	self:Remove()
end

-- ============================================================
-- REMOVE
-- ============================================================

function ENT:OnRemove()
	-- Audio cleanup handled by cl_init.lua
end
