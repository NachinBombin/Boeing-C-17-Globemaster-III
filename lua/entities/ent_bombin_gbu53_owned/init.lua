-- ============================================================
-- ent_bombin_gbu53_owned  —  SERVER
-- GBU-53/B StormBreaker owned variant.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_trailsystem.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- LOCAL CONSTANTS
-- ============================================================
local MODEL_YAW_OFFSET     = 0

local SHARD_MODEL          = "models/props_c17/FurnitureDrawer001a_Shard01.mdl"
local GRAVITY_MULT         = 1.1
local SHARD_LIFE           = 8

local GLIDE_BLEED_RATE     = 8.0
local GROUND_DETONATE_DIST = 80

local FREEFALL_GRAVITY     = 600
local TERMINAL_VEL         = -320
local HORIZ_GLIDE_MAX      = 380
local HORIZ_GLIDE_RAMP     = 1.4

local IGNITION_ALT_FRAC    = 0.35
local ORBIT_ALT_RISE       = 600

local SALVO_COUNT          = 4
local SALVO_DELAY_BASE     = 0.6
local SALVO_DELAY_JITTER   = 0.3

ENT.WeaponWindow  = 8
ENT.FadeDuration  = 0.0

ENT.DIVE_Speed         = 1800
ENT.DIVE_TrackInterval = 0.1

util.AddNetworkString("bombin_gbu53owned_damage_tier")

-- ============================================================
-- FIRE EFFECT HELPER  (mirrors JASSM FireEffect exactly)
-- Using util.Effect with EffectData scale/magnitude/radius set
-- prevents the index-buffer crash that raw HelicopterMegaBomb
-- calls caused when the effect had too many indices.
-- ============================================================
local function FireEffect(origin, effect, scale)
	local ed = EffectData()
	ed:SetOrigin(origin)
	ed:SetScale(scale)
	ed:SetMagnitude(scale)
	ed:SetRadius(scale * 100)
	util.Effect(effect, ed, true, true)
end

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
	print("[Npc C-17 Globemaster] " .. tostring(msg))
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

	self.SalvoIndex   = self:GetVar("SalvoIndex", 1)
	self.IsSalvoChild = self:GetVar("IsSalvoChild", false)

	self.MaxHP = 200

	if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
	self.CallDir.z = 0
	self.CallDir:Normalize()

	local ground = self:FindGround(self.CenterPos)
	if ground == -1 then self:Debug("FindGround failed") self:Remove() return end
	self.GroundZ = ground

	local altVar = self.SkyHeightAdd * 0.25
	self.sky = ground + self.SkyHeightAdd + math.Rand(-altVar, altVar)

	local ignBase = ground + (self.SkyHeightAdd * IGNITION_ALT_FRAC)
	local ignVar  = self.SkyHeightAdd * IGNITION_ALT_FRAC * 0.25
	self.IgnitionAlt = ignBase + math.Rand(-ignVar, ignVar)
	self.OrbitAlt    = self.IgnitionAlt + ORBIT_ALT_RISE

	self.DieTime   = CurTime() + self.Lifetime
	self.SpawnTime = CurTime()

	self.Phase             = "freefall"
	self.FreefallVelZ      = 0
	self.FreefallHorizT    = 0
	self.FreefallHorizSpeed = 0

	local baseRadius = self:GetVar("OrbitRadius", 2500)
	local baseSpeed  = self:GetVar("Speed",        250)
	self.OrbitRadius = baseRadius * math.Rand(0.82, 1.18)
	self.Speed       = baseSpeed  * math.Rand(0.85, 1.15)
	self.OrbitDir    = (math.random(0,1) == 0) and 1 or -1

	local spawnPos
	if self.SpawnedFromPlane then
		spawnPos = self:GetPos()
	else
		local tailOffset = self.CallDir * -200
		spawnPos = Vector(
			self.CenterPos.x + tailOffset.x,
			self.CenterPos.y + tailOffset.y,
			self.sky
		)
	end

	if not util.IsInWorld(spawnPos) then
		spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
	end
	if not util.IsInWorld(spawnPos) then
		self:Debug("Spawn position out of world") self:Remove() return
	end

	self:SetModel("models/sw/usa/bombs/guided/gbu53.mdl")
	self:SetModelScale(1.0, 0)
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_NONE)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:SetPos(spawnPos)
	self:SetRenderMode(RENDERMODE_NORMAL)
	self:SetBodygroup(1, 0)

	self:SetNWInt("HP",    self.MaxHP)
	self:SetNWInt("MaxHP", self.MaxHP)
	self:SetNWBool("Destroyed",  false)
	self:SetNWBool("EngineOn",   false)

	local faceAng = self.CallDir:Angle()
	self:SetAngles(Angle(0, faceAng.y, 0))
	self.ang = self:GetAngles()

	self.SmoothedRoll  = 0
	self.SmoothedPitch = 0
	self.PrevYaw       = self.ang.y

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

	self.AltDriftCurrent  = self.OrbitAlt
	self.AltDriftTarget   = self.OrbitAlt
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

	if not self.IsSalvoChild then
		timer.Simple(0, function()
			if not IsValid(self) then return end
			self:SpawnChute()
		end)
	end

	self:Debug("Spawned [salvo " .. self.SalvoIndex .. "] at " .. tostring(spawnPos))
end

-- ============================================================
-- CHUTE SPAWN
-- ============================================================

function ENT:SpawnChute()
	if IsValid(self.ChuteEnt) then return end
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
-- SALVO SPAWN
-- ============================================================

function ENT:SpawnSalvo()
	for i = 2, SALVO_COUNT do
		local delay = (i - 1) * SALVO_DELAY_BASE + math.Rand(0, SALVO_DELAY_JITTER)
		local idx   = i
		timer.Simple(delay, function()
			if not IsValid(self) then return end

			local child = ents.Create("ent_bombin_gbu53_owned")
			if not IsValid(child) then return end

			child:SetVar("CenterPos",            self.BaseCenterPos)
			child:SetVar("CallDir",              self.CallDir)
			child:SetVar("Lifetime",             self.Lifetime)
			child:SetVar("SkyHeightAdd",         self.SkyHeightAdd)
			child:SetVar("OrbitRadius",          self:GetVar("OrbitRadius", 2500))
			child:SetVar("Speed",                self:GetVar("Speed",        250))
			child:SetVar("DIVE_ExplosionDamage", self.DIVE_ExplosionDamage)
			child:SetVar("DIVE_ExplosionRadius", self.DIVE_ExplosionRadius)
			child:SetVar("SalvoIndex",           idx)
			child:SetVar("IsSalvoChild",         true)

			local scatter = Vector(math.Rand(-120, 120), math.Rand(-120, 120), 0)
			child:SetPos(Vector(
				self.BaseCenterPos.x + scatter.x,
				self.BaseCenterPos.y + scatter.y,
				self.IgnitionAlt
			))
			child:Spawn()
			child:Activate()
			child:IgniteEngine()
			self:Debug("Salvo child " .. idx .. " ignited")
		end)
	end
end

-- ============================================================
-- FREEFALL PHYSICS
-- ============================================================

function ENT:UpdateFreefall(dt)
	local k = FREEFALL_GRAVITY / math.abs(TERMINAL_VEL)
	self.FreefallVelZ = self.FreefallVelZ - FREEFALL_GRAVITY * dt
	local drag = k * math.abs(self.FreefallVelZ)
	self.FreefallVelZ = self.FreefallVelZ + drag * dt
	self.FreefallVelZ = math.max(self.FreefallVelZ, TERMINAL_VEL)

	self.FreefallHorizT = math.min(self.FreefallHorizT + dt, HORIZ_GLIDE_RAMP)
	self.FreefallHorizSpeed = (self.FreefallHorizT / HORIZ_GLIDE_RAMP) * HORIZ_GLIDE_MAX

	local pos = self:GetPos()
	local newPos = Vector(
		pos.x + self.CallDir.x * self.FreefallHorizSpeed * dt,
		pos.y + self.CallDir.y * self.FreefallHorizSpeed * dt,
		pos.z + self.FreefallVelZ * dt
	)

	local speedFrac = math.abs(self.FreefallVelZ) / math.abs(TERMINAL_VEL)
	local targetPitch = -25 * speedFrac
	self.SmoothedPitch = Lerp(0.06, self.SmoothedPitch, targetPitch)
	local faceAng = self.CallDir:Angle()
	self.ang.y = faceAng.y
	self.ang.p = self.SmoothedPitch
	self.ang.r = 0
	self:SetAngles(self.ang)
	self:SetPos(newPos)

	if newPos.z <= self.IgnitionAlt then
		newPos.z = self.IgnitionAlt
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

	self:Debug("Engine ignited [salvo " .. self.SalvoIndex .. "] at Z=" .. math.Round(self:GetPos().z))

	self:SetNWBool("EngineOn", true)
	self:SetBodygroup(1, 1)

	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)

	self.PhysObj = self:GetPhysicsObject()
	if IsValid(self.PhysObj) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity(false)
		local seedVel = self.CallDir * math.max(self.Speed, self.FreefallHorizSpeed)
		seedVel.z = 0
		self.PhysObj:SetVelocity(seedVel)
	end

	local pos = self:GetPos()
	self.OrbitAngle = math.atan2(
		pos.y - self.CenterPos.y,
		pos.x - self.CenterPos.x
	)
	self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDir

	self.AltDriftCurrent  = self.OrbitAlt
	self.AltDriftTarget   = self.OrbitAlt
	self.AltDriftNextPick = CurTime() + math.Rand(8, 20)

	-- Ignition burst: match JASSM sounds exactly
	FireEffect(pos + self:GetForward() * -40, "HelicopterMegaBomb", 2)
	sound.Play("ambient/fire/gas_burst1.wav",       pos, 100, math.random(90, 110), 1.0)
	sound.Play("ambient/fire/fire_large_loop1.wav", pos,  85, 130,                  0.6)

	if not self.IsSalvoChild then
		self:SpawnSalvo()
	end
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

	if self.Phase == "freefall" then
		self:UpdateFreefall(dt)
		self:NextThink(ct + 0.015)
		return true
	end

	if not IsValid(self.PhysObj) then
		self.PhysObj = self:GetPhysicsObject()
	end
	local phys = self.PhysObj
	if IsValid(phys) and phys:IsAsleep() then phys:Wake() end

	if self.Destroyed then
		if self.ExplodeTimer and ct >= self.ExplodeTimer and not self.ExplodedAlready then
			self:CrashExplode(self:GetPos())
		end
		if self.Diving then self:UpdateDive(ct) end
		self:NextThink(ct + 0.05)
		return true
	end

	if ct >= self.AltDriftNextPick then
		self.AltDriftNextPick = ct + math.Rand(8, 20)
		self.AltDriftTarget   = self.OrbitAlt + math.Rand(-self.AltDriftRange, self.AltDriftRange)
	end
	self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

	self.WanderPhaseX = self.WanderPhaseX + self.WanderRateX
	self.WanderPhaseY = self.WanderPhaseY + self.WanderRateY
	self.CenterPos.x  = self.BaseCenterPos.x + math.sin(self.WanderPhaseX) * self.WanderAmp
	self.CenterPos.y  = self.BaseCenterPos.y + math.cos(self.WanderPhaseY) * self.WanderAmp

	if not self.Diving then
		self:UpdateOrbit(ct, dt, phys)
		self:UpdateWeaponLogic(ct)
	else
		self:UpdateDive(ct)
	end

	self:NextThink(ct + 0.015)
	return true
end

-- ============================================================
-- ORBIT PHYSICS
-- ============================================================

function ENT:UpdateOrbit(ct, dt, phys)
	if not IsValid(phys) then return end

	self.OrbitAngle = self.OrbitAngle + self.OrbitAngSpeed * dt

	local desX = self.CenterPos.x + math.cos(self.OrbitAngle) * self.OrbitRadius
	local desY = self.CenterPos.y + math.sin(self.OrbitAngle) * self.OrbitRadius
	local desZ = self.AltDriftCurrent

	self.JitterPhase  = self.JitterPhase  + self.JitterRate1
	self.JitterPhase2 = self.JitterPhase2 + self.JitterRate2
	local jitter = math.sin(self.JitterPhase) * self.JitterAmp1 + math.sin(self.JitterPhase2) * self.JitterAmp2

	local pos  = self:GetPos()
	local velZ = math.Clamp((desZ - pos.z) * 8, -120, 120)

	if ct - self.SkyProbeLastHit > 0.4 then
		local fwd = self:GetForward()
		local tr  = util.TraceLine({
			start  = pos,
			endpos = pos + fwd * self.SkyProbeDist,
			filter = function(e) return e ~= self end,
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit then
			self.SkyYawBias   = self.SkyYawBias + (25 * self.OrbitDir * dt)
			self.SkyProbeLastHit = ct
		else
			self.SkyYawBias = self.SkyYawBias * (1 - dt * 0.25)
		end
	end

	local desiredYaw = math.deg(self.OrbitAngle + (math.pi / 2) * self.OrbitDir) + self.SkyYawBias
	local prevYaw    = self.ang.y - MODEL_YAW_OFFSET

	local yawDelta  = math.NormalizeAngle(desiredYaw - prevYaw)

	self.GlideRollPhase = self.GlideRollPhase + self.GlideRollRate * dt
	local glideRoll = math.sin(self.GlideRollPhase) * self.GlideRollAmp
	self.SmoothedRoll  = Lerp(0.05, self.SmoothedRoll,  glideRoll)
	self.SmoothedPitch = Lerp(0.04, self.SmoothedPitch, 0)

	local curVel  = phys:GetVelocity()
	local desVelX = math.cos(math.rad(desiredYaw)) * self.Speed + math.cos(math.rad(desiredYaw + 90)) * jitter * 0.005
	local desVelY = math.sin(math.rad(desiredYaw)) * self.Speed + math.sin(math.rad(desiredYaw + 90)) * jitter * 0.005
	local newVel  = Vector(
		Lerp(0.10, curVel.x, desVelX),
		Lerp(0.10, curVel.y, desVelY),
		velZ
	)
	phys:SetVelocity(newVel)

	self.ang = Angle(-self.SmoothedRoll, desiredYaw + MODEL_YAW_OFFSET, -self.SmoothedPitch)
	self:SetAngles(self.ang)
end

-- ============================================================
-- WEAPON LOGIC
-- ============================================================

function ENT:UpdateWeaponLogic(ct)
	if ct < self.WeaponWindowEnd then return end

	local roll = math.random(1, 3)
	if roll == 3 then
		self:StartDive(ct)
	else
		self.WeaponWindowEnd = ct + math.Rand(4, 9)
	end
end

-- ============================================================
-- DIVE ATTACK
-- ============================================================

function ENT:StartDive(ct)
	self.Diving = true
	self.DiveAimOffset = Vector(math.Rand(-400, 400), math.Rand(-400, 400), 0)
	self.DiveSpeedCurrent = self.DiveSpeedMin
	self.DiveWobblePhase  = 0

	local closest, closestDist = nil, math.huge
	for _, ply in ipairs(player.GetAll()) do
		if not IsValid(ply) or not ply:Alive() then continue end
		local d = ply:GetPos():DistToSqr(self.CenterPos)
		if d < closestDist then closestDist = d; closest = ply end
	end
	self.DiveTarget    = closest
	self.DiveTargetPos = IsValid(closest) and closest:GetPos() or self.CenterPos
	self.DiveNextTrack = ct + self.DIVE_TrackInterval

	self:Debug("Dive initiated [salvo " .. self.SalvoIndex .. "]")
end

function ENT:UpdateDive(ct)
	if not IsValid(self.PhysObj) then
		self.PhysObj = self:GetPhysicsObject()
	end
	local phys = self.PhysObj
	if not IsValid(phys) then return end

	if ct >= self.DiveNextTrack then
		self.DiveNextTrack = ct + self.DIVE_TrackInterval
		if IsValid(self.DiveTarget) and self.DiveTarget:Alive() then
			self.DiveTargetPos = self.DiveTarget:GetPos()
		end
	end

	local pos    = self:GetPos()
	local aim    = self.DiveTargetPos + self.DiveAimOffset
	local toAim  = (aim - pos):GetNormalized()

	self.DiveWobblePhase  = self.DiveWobblePhase  + self.DiveWobbleSpeed  * FrameTime()
	self.DiveWobblePhaseV = self.DiveWobblePhaseV + self.DiveWobbleSpeedV * FrameTime()
	local right = self:GetRight()
	local up    = self:GetUp()
	local wobble = right * math.sin(self.DiveWobblePhase)  * self.DiveWobbleAmp
	           + up    * math.sin(self.DiveWobblePhaseV) * self.DiveWobbleAmpV

	self.DiveSpeedCurrent = Lerp(self.DiveSpeedLerp, self.DiveSpeedCurrent, self.DIVE_Speed)

	local vel = toAim * self.DiveSpeedCurrent + wobble
	phys:SetVelocity(vel)

	local lookAng = vel:Angle()
	self.ang = Angle(lookAng.p, lookAng.y, math.sin(self.DiveWobblePhase) * 25)
	self:SetAngles(self.ang)

	local distToAim   = pos:Distance(aim)
	local groundZ     = self.GroundZ or (pos.z - 5000)
	local aboveGround = pos.z - groundZ

	if distToAim < 120 or aboveGround < GROUND_DETONATE_DIST then
		self:DiveExplode(pos)
	end
end

-- ============================================================
-- EXPLODE  —  mirrors JASSM FireEffect pattern exactly
-- FIX: util.BlastDamage attacker is now self (not GetOwner()).
--      GetOwner() returns the chute entity, which is already
--      removed by the time DiveExplode fires.  NULL entity as
--      the attacker arg crashes BlastDamage at [C]:-1.
-- ============================================================

function ENT:DiveExplode(pos)
	if self.DiveExploded then return end
	self.DiveExploded    = true
	self.ExplodedAlready = true

	FireEffect(pos,                   "HelicopterMegaBomb", 8)
	FireEffect(pos,                   "500lb_air",          7)
	FireEffect(pos + Vector(0,0, 80), "500lb_air",          6)
	FireEffect(pos + Vector(0,0,160), "500lb_air",          5)
	FireEffect(pos + Vector(0,0, 20), "HelicopterMegaBomb", 6)

	sound.Play("weapon_AWP.Single",                pos,                155, 52,  1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos,                150, 78,  1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos+Vector(0,0,40), 145, 85,  0.9)

	util.BlastDamage(self, self, pos, self.DIVE_ExplosionRadius, self.DIVE_ExplosionDamage)

	timer.Simple(0.05, function()
		if IsValid(self) then self:Remove() end
	end)
end

function ENT:CrashExplode(pos)
	if self.ExplodedAlready then return end
	self.ExplodedAlready = true

	FireEffect(pos,                  "HelicopterMegaBomb", 5)
	FireEffect(pos,                  "500lb_air",          4)
	FireEffect(pos + Vector(0,0,60), "500lb_air",          3)

	sound.Play("ambient/explosions/explode_8.wav", pos, 145, 72, 1.0)
	sound.Play("ambient/explosions/explode_8.wav", pos, 140, 88, 0.8)

	util.BlastDamage(self, self, pos, self.DIVE_ExplosionRadius * 0.6, self.DIVE_ExplosionDamage * 0.3)

	timer.Simple(0.05, function()
		if IsValid(self) then self:Remove() end
	end)
end

-- ============================================================
-- DAMAGE
-- ============================================================

function ENT:OnTakeDamage(dmginfo)
	if self.Destroyed then return end
	local dmg = dmginfo:GetDamage()
	self.HP = math.max((self.HP or self.MaxHP) - dmg, 0)
	self:SetNWInt("HP", self.HP)

	local tier = CalcTier(self.HP, self.MaxHP)
	if tier ~= self.DamageTier then
		self.DamageTier = tier
		BroadcastTier(self, tier)
	end

	if self.HP <= 0 and not self.Destroyed then
		self.Destroyed     = true
		self.DestroyedTime = CurTime()
		self.ExplodeTimer  = CurTime() + math.Rand(0.3, 1.2)
		self:SetNWBool("Destroyed", true)
		BroadcastTier(self, 3)
		self.TumbleAngVel = Vector(math.Rand(-120, 120), math.Rand(-120, 120), math.Rand(-80, 80))
		if IsValid(self.PhysObj) then
			self.PhysObj:EnableGravity(true)
			self.PhysObj:AddAngleVelocity(self.TumbleAngVel)
		end
	end
end

-- ============================================================
-- REMOVE
-- ============================================================

function ENT:OnRemove()
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
-- SETVAR / GETVAR
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
