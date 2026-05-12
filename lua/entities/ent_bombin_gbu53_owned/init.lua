-- ============================================================
-- ent_bombin_gbu53_owned  —  SERVER
-- GBU-53/B StormBreaker owned variant.
-- ============================================================

AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "cl_trailsystem.lua" )
AddCSLuaFile( "shared.lua" )
include( "shared.lua" )

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
local SALVO_DELAY_BASE     = 1.0
local SALVO_DELAY_JITTER   = 0.0

local IGNITION_EFFECT_NAME        = "MuzzleFlash"
local IGNITION_EFFECT_SCALE       = 6
local IGNITION_EFFECT_NAME_LARGE  = "NPC_Shield_Impact"
local IGNITION_EFFECT_SCALE_LARGE = 1.8

-- Fix: minimum freefall duration before ignition is allowed.
local FREEFALL_MIN_TIME = 0.35

-- Pallet bay offsets on the C-17 (local space, scale=1.8).
local SALVO_PALLET_OFFSETS = {
	Vector(-180,   60, -60),
	Vector(-180,  -60, -60),
	Vector(-180,    0, -140),
}

-- Dead constants kept for reference; not used by runtime logic.
-- ENT.WeaponWindow  = 8   -- was never read; weapon interval is math.Rand(4,9)
-- ENT.FadeDuration  = 0.0 -- unused

ENT.DIVE_Speed         = 1800
ENT.DIVE_TrackInterval = 0.1

util.AddNetworkString( "bombin_gbu53owned_damage_tier" )

-- ============================================================
-- CARGO DOOR HELPER
-- Tells the parent C-17 plane to open or close its cargo doors.
-- Safe to call even when no plane reference exists.
-- ============================================================
local function C17_SetCargoDoor( missile, open )
	local plane = missile:GetVar( "ParentPlane", nil )
	if not IsValid( plane ) then return end
	plane:SetNWBool( "CargoDoorOpen", open )
end

-- ============================================================
-- HELPERS
-- ============================================================
local function FireEffect( origin, effect, scale )
	local ed = EffectData()
	ed:SetOrigin( origin )
	ed:SetScale( scale )
	ed:SetMagnitude( scale )
	ed:SetRadius( scale * 100 )
	util.Effect( effect, ed, true, true )
end

-- Returns a valid attacker for util.BlastDamage.
-- Falls back to the entity itself so the C function never receives NULL.
local function SafeAttacker( ent )
	local owner = ent:GetOwner()
	return IsValid( owner ) and owner or ent
end

local function CalcTier( hp, maxHP )
	local frac = hp / maxHP
	if frac > 0.66 then return 0 end
	if frac > 0.33 then return 1 end
	if hp   > 0    then return 2 end
	return 3
end

local function BroadcastTier( ent, tier )
	net.Start( "bombin_gbu53owned_damage_tier" )
		net.WriteUInt( ent:EntIndex(), 16 )
		net.WriteUInt( tier, 2 )
	net.Broadcast()
end

-- ============================================================
-- DEBUG
-- ============================================================
function ENT:Debug( msg )
	print( "[Npc C-17 Globemaster] " .. tostring( msg ) )
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
	self.CenterPos    = self:GetVar( "CenterPos",    self:GetPos() )
	self.CallDir      = self:GetVar( "CallDir",      Vector(1,0,0) )
	self.Lifetime     = self:GetVar( "Lifetime",     60 )
	self.SkyHeightAdd = self:GetVar( "SkyHeightAdd", 2500 )

	self.DIVE_ExplosionDamage = self:GetVar( "DIVE_ExplosionDamage", 700 )
	self.DIVE_ExplosionRadius = self:GetVar( "DIVE_ExplosionRadius", 900 )

	self.SalvoIndex   = self:GetVar( "SalvoIndex",   1 )
	self.IsSalvoChild = self:GetVar( "IsSalvoChild", false )

	self.MaxHP = 200

	if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
	self.CallDir.z = 0
	self.CallDir:Normalize()

	local ground = self:FindGround( self.CenterPos )
	if ground == -1 then self:Debug( "FindGround failed" ) self:Remove() return end
	self.GroundZ = ground

	local altVar = self.SkyHeightAdd * 0.25
	self.sky = ground + self.SkyHeightAdd + math.Rand( -altVar, altVar )

	local ignBase = ground + ( self.SkyHeightAdd * IGNITION_ALT_FRAC )
	local ignVar  = self.SkyHeightAdd * IGNITION_ALT_FRAC * 0.25
	self.IgnitionAlt = ignBase + math.Rand( -ignVar, ignVar )
	self.OrbitAlt    = self.IgnitionAlt + ORBIT_ALT_RISE

	self.DieTime   = CurTime() + self.Lifetime
	self.SpawnTime = CurTime()

	self.Phase              = "freefall"
	self.FreefallVelZ       = 0
	self.FreefallHorizT     = 0
	self.FreefallHorizSpeed = 0

	local baseRadius = self:GetVar( "OrbitRadius", 2500 )
	local baseSpeed  = self:GetVar( "Speed",        250 )
	self.OrbitRadius = baseRadius * math.Rand( 0.82, 1.18 )
	self.Speed       = baseSpeed  * math.Rand( 0.85, 1.15 )
	self.OrbitDir    = ( math.random(0,1) == 0 ) and 1 or -1

	local spawnPos
	if self.IsSalvoChild then
		local rel = self:GetVar( "ReleasePos", nil )
		if rel then
			spawnPos = rel
		else
			local tailOffset = self.CallDir * -200
			local scatter    = Vector( math.Rand(-120,120), math.Rand(-120,120), 0 )
			spawnPos = Vector(
				self.CenterPos.x + tailOffset.x + scatter.x,
				self.CenterPos.y + tailOffset.y + scatter.y,
				self.sky
			)
		end
	elseif self.SpawnedFromPlane then
		spawnPos = self:GetPos()
	else
		local tailOffset = self.CallDir * -200
		spawnPos = Vector(
			self.CenterPos.x + tailOffset.x,
			self.CenterPos.y + tailOffset.y,
			self.sky
		)
	end

	if not util.IsInWorld( spawnPos ) then
		spawnPos = Vector( self.CenterPos.x, self.CenterPos.y, self.sky )
	end
	if not util.IsInWorld( spawnPos ) then
		self:Debug( "Spawn position out of world" ) self:Remove() return
	end

	self:SetModel( "models/sw/usa/bombs/guided/gbu53.mdl" )
	self:SetModelScale( 1.0, 0 )
	self:SetMoveType( MOVETYPE_NONE )
	self:SetSolid( SOLID_NONE )
	self:SetCollisionGroup( COLLISION_GROUP_NONE )
	self:SetPos( spawnPos )
	self:SetBodygroup( 1, 0 )

	if not self.IsSalvoChild then
		self:SetRenderMode( RENDERMODE_NONE )
	else
		self:SetRenderMode( RENDERMODE_NORMAL )
	end

	self:SetNWInt(  "HP",        self.MaxHP )
	self:SetNWInt(  "MaxHP",     self.MaxHP )
	self:SetNWBool( "Destroyed", false )
	self:SetNWBool( "EngineOn",  false )

	local faceAng = self.CallDir:Angle()
	self:SetAngles( Angle( 0, faceAng.y, 0 ) )
	self.ang = self:GetAngles()

	self.SmoothedRoll  = 0
	self.SmoothedPitch = 0
	self.PrevYaw       = self.ang.y

	self.OrbitAngle    = 0
	self.OrbitAngSpeed = 0

	self.JitterPhase  = math.Rand( 0, math.pi * 2 )
	self.JitterPhase2 = math.Rand( 0, math.pi * 2 )
	self.JitterAmp1   = math.Rand( 40,  80 )
	self.JitterAmp2   = math.Rand( 90, 180 )
	self.JitterRate1  = math.Rand( 0.040, 0.090 )
	self.JitterRate2  = math.Rand( 0.012, 0.025 )

	self.GlideRollPhase = math.Rand( 0, math.pi * 2 )
	self.GlideRollAmp   = math.Rand( 18, 38 )
	self.GlideRollRate  = math.Rand( 0.8, 1.6 )

	self.GlideBleedRate = GLIDE_BLEED_RATE

	self.AltDriftCurrent  = self.OrbitAlt
	self.AltDriftTarget   = self.OrbitAlt
	self.AltDriftNextPick = CurTime() + math.Rand( 8, 20 )
	self.AltDriftRange    = 700
	self.AltDriftLerp     = 0.003

	self.BaseCenterPos = Vector( self.CenterPos.x, self.CenterPos.y, self.CenterPos.z )
	self.WanderPhaseX  = math.Rand( 0, math.pi * 2 )
	self.WanderPhaseY  = math.Rand( 0, math.pi * 2 )
	self.WanderAmp     = math.Rand( 60, 160 )
	self.WanderRateX   = math.Rand( 0.004, 0.010 )
	self.WanderRateY   = math.Rand( 0.003, 0.009 )

	self.CurrentWeapon   = nil
	-- WeaponWindowEnd: wall-clock time at which the current peaceful lapse ends.
	-- While ct < WeaponWindowEnd the doors stay open (the window is "active").
	self.WeaponWindowEnd = 0
	self.WeaponWindowOpen = false   -- tracks whether we already signalled Open

	self.Diving        = false
	self.DiveTarget    = nil
	self.DiveTargetPos = nil
	self.DiveNextTrack = 0
	self.DiveExploded  = false
	self.DiveAimOffset = Vector(0,0,0)

	self.DiveWobblePhase  = 0
	self.DiveWobbleAmp    = 180
	self.DiveWobbleSpeed  = 4.5
	self.DiveWobblePhaseV = math.Rand( 0, math.pi * 2 )
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
	self.SkyProbeDist    = math.max( 1200, self.Speed * 6 )
	self.SkyProbeLastHit = 0

	self.ObsLastEval   = 0
	self.ObsYawBias    = 0
	self.ObsAltBias    = 0
	self.ObsConsecHits = 0

	if not self.IsSalvoChild then
		timer.Simple( 0, function()
			if not IsValid( self ) then return end
			self:SpawnChute()
		end )
	end

	self:Debug( "Spawned [salvo " .. self.SalvoIndex .. "] at " .. tostring(spawnPos) )
end

-- ============================================================
-- CHUTE SPAWN
-- ============================================================
function ENT:SpawnChute()
	if IsValid( self.ChuteEnt ) then return end
	local chute = ents.Create( "ent_bombin_gbu53_chute_owned" )
	if not IsValid( chute ) then
		self:Debug( "Failed to create chute entity" )
		return
	end
	chute:SetOwner( self )
	chute:SetPos( self:GetPos() + Vector(0,0,105) )
	chute:SetAngles( self:GetAngles() )
	chute:Spawn()
	chute:Activate()
	self.ChuteEnt = chute
end

-- ============================================================
-- SALVO SPAWN
-- Fix: each child reads the pallet's LIVE world position at the moment
-- its timer fires.  The pallet (ChuteEnt, an ent_bombin_gbu53_chute_owned)
-- is in freefall and moves continuously, so computing releasePos up-front
-- (or via planeEnt:LocalToWorld at callback time) gives the wrong origin
-- for munitions 2-4.  Reading self.ChuteEnt:GetPos() inside the callback
-- guarantees every munition starts from the pallet's current position.
-- ============================================================
function ENT:SpawnSalvo( planeEnt )
	for i = 2, SALVO_COUNT do
		local delay     = (i - 1) * SALVO_DELAY_BASE + math.Rand( 0, SALVO_DELAY_JITTER )
		local capturedI = i
		timer.Simple( delay, function()
			if not IsValid( self ) then return end

			-- Read the pallet's live position at the moment this timer fires.
			-- The pallet is still falling, so this is always the correct origin.
			local releasePos
			if IsValid( self.ChuteEnt ) then
				releasePos = self.ChuteEnt:GetPos()
			else
				-- Fallback: pallet already gone (early ignition edge-case).
				-- Use the missile's own current position.
				releasePos = self:GetPos()
			end

			local child = ents.Create( "ent_bombin_gbu53_owned" )
			if not IsValid( child ) then return end

			child:SetVar( "IsSalvoChild",        true )
			child:SetVar( "SalvoIndex",           capturedI )
			child:SetVar( "ReleasePos",           releasePos )
			child:SetVar( "CenterPos",            self.BaseCenterPos )
			child:SetVar( "CallDir",              self.CallDir )
			child:SetVar( "Lifetime",             self.Lifetime )
			child:SetVar( "SkyHeightAdd",         self.SkyHeightAdd )
			child:SetVar( "OrbitRadius",          self.OrbitRadius )
			child:SetVar( "Speed",                self.Speed )
			child:SetVar( "DIVE_ExplosionDamage", self.DIVE_ExplosionDamage )
			child:SetVar( "DIVE_ExplosionRadius", self.DIVE_ExplosionRadius )
			-- Propagate parent plane reference so salvo children can also
			-- control the cargo doors during their own dives.
			child:SetVar( "ParentPlane",          self:GetVar("ParentPlane", nil) )

			child:SetPos( releasePos )
			child:Spawn()
			child:Activate()
			child:IgniteEngine()
			self:Debug( "Salvo child " .. capturedI .. " ignited at " .. tostring(releasePos) )
		end )
	end
end

-- ============================================================
-- FREEFALL PHYSICS
-- ============================================================
function ENT:UpdateFreefall( dt )
	local k = FREEFALL_GRAVITY / math.abs( TERMINAL_VEL )
	self.FreefallVelZ = self.FreefallVelZ - FREEFALL_GRAVITY * dt
	local drag = k * math.abs( self.FreefallVelZ )
	self.FreefallVelZ = self.FreefallVelZ + drag * dt
	self.FreefallVelZ = math.max( self.FreefallVelZ, TERMINAL_VEL )

	self.FreefallHorizT = math.min( self.FreefallHorizT + dt, HORIZ_GLIDE_RAMP )
	self.FreefallHorizSpeed = ( self.FreefallHorizT / HORIZ_GLIDE_RAMP ) * HORIZ_GLIDE_MAX

	local pos = self:GetPos()
	local newPos = Vector(
		pos.x + self.CallDir.x * self.FreefallHorizSpeed * dt,
		pos.y + self.CallDir.y * self.FreefallHorizSpeed * dt,
		pos.z + self.FreefallVelZ * dt
	)

	local speedFrac = math.abs( self.FreefallVelZ ) / math.abs( TERMINAL_VEL )
	self.SmoothedPitch = Lerp( 0.06, self.SmoothedPitch, -25 * speedFrac )
	local faceAng = self.CallDir:Angle()
	self.ang.y = faceAng.y
	self.ang.p = self.SmoothedPitch
	self.ang.r = 0
	self:SetAngles( self.ang )
	self:SetPos( newPos )

	local freefallAge = CurTime() - self.SpawnTime
	if newPos.z <= self.IgnitionAlt and freefallAge >= FREEFALL_MIN_TIME then
		newPos.z = self.IgnitionAlt
		self:SetPos( newPos )
		self:IgniteEngine()
	end
end

-- ============================================================
-- ENGINE IGNITION
-- ============================================================
function ENT:IgniteEngine()
	if self.Phase == "orbit" then return end
	self.Phase = "orbit"

	self:Debug( "Engine ignited [salvo " .. self.SalvoIndex .. "] at Z=" .. math.Round(self:GetPos().z) )

	self:SetRenderMode( RENDERMODE_NORMAL )
	self:SetNWBool( "EngineOn", true )
	self:SetBodygroup( 1, 1 )

	self:PhysicsInit( SOLID_VPHYSICS )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )

	-- Fix: COLLISION_GROUP_DEBRIS_TRIGGER collides with world/static props
	-- but ignores players and other missiles — correct for loitering altitude.
	-- Upgraded to COLLISION_GROUP_NONE on StartDive().
	self:SetCollisionGroup( COLLISION_GROUP_DEBRIS_TRIGGER )

	self.PhysObj = self:GetPhysicsObject()
	if IsValid( self.PhysObj ) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity( false )
		local seedVel = self.CallDir * math.max( self.Speed, self.FreefallHorizSpeed )
		seedVel.z = 0
		self.PhysObj:SetVelocity( seedVel )
	end

	local pos = self:GetPos()

	self.OrbitAngle = math.atan2(
		pos.y - self.CenterPos.y,
		pos.x - self.CenterPos.x
	)
	self.OrbitAngSpeed = ( self.Speed / self.OrbitRadius ) * self.OrbitDir

	self.AltDriftCurrent  = self.OrbitAlt
	self.AltDriftTarget   = self.OrbitAlt
	self.AltDriftNextPick = CurTime() + math.Rand( 8, 20 )

	local fwd      = self:GetForward()
	local ignitePt = pos + fwd * -18
	FireEffect( ignitePt,            IGNITION_EFFECT_NAME,        IGNITION_EFFECT_SCALE )
	FireEffect( ignitePt + fwd * -30, IGNITION_EFFECT_NAME_LARGE, IGNITION_EFFECT_SCALE_LARGE )

	sound.Play( "ambient/fire/gas_burst1.wav",  pos, 105, math.random(95,  108), 1.0 )
	sound.Play( "ambient/explosions/exp1.wav",  pos,  90, math.random(115, 130), 0.55 )
	sound.Play( "ambient/fire/fire_small1.wav", pos,  82, 120, 0.45 )

	if not self.IsSalvoChild then
		local planeRef = self:GetVar( "ParentPlane", nil )
		self:SpawnSalvo( IsValid(planeRef) and planeRef or nil )
	end
end

-- ============================================================
-- THINK
-- ============================================================
function ENT:Think()
	if not self.DieTime or not self.SpawnTime then
		self:NextThink( CurTime() + 0.1 )
		return true
	end

	local ct = CurTime()
	if ct >= self.DieTime then self:Remove() return end

	local dt = FrameTime()
	if dt <= 0 then dt = 0.015 end

	if self.Phase == "freefall" then
		self:UpdateFreefall( dt )
		self:NextThink( ct + 0.015 )
		return true
	end

	if not IsValid( self.PhysObj ) then
		self.PhysObj = self:GetPhysicsObject()
	end
	local phys = self.PhysObj
	if IsValid( phys ) and phys:IsAsleep() then phys:Wake() end

	if self.Destroyed then
		if self.ExplodeTimer and ct >= self.ExplodeTimer and not self.ExplodedAlready then
			self:CrashExplode( self:GetPos() )
		end
		if self.Diving then self:UpdateDive( ct ) end
		self:NextThink( ct + 0.05 )
		return true
	end

	if ct >= self.AltDriftNextPick then
		self.AltDriftNextPick = ct + math.Rand( 8, 20 )
		self.AltDriftTarget   = self.OrbitAlt + math.Rand( -self.AltDriftRange, self.AltDriftRange )
	end
	self.AltDriftCurrent = Lerp( self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget )

	self.WanderPhaseX = self.WanderPhaseX + self.WanderRateX
	self.WanderPhaseY = self.WanderPhaseY + self.WanderRateY
	self.CenterPos.x  = self.BaseCenterPos.x + math.sin( self.WanderPhaseX ) * self.WanderAmp
	self.CenterPos.y  = self.BaseCenterPos.y + math.cos( self.WanderPhaseY ) * self.WanderAmp

	if not self.Diving then
		self:UpdateOrbit( ct, dt, phys )
		self:UpdateWeaponLogic( ct )
	else
		self:UpdateDive( ct )
	end

	self:NextThink( ct + 0.015 )
	return true
end

-- ============================================================
-- ORBIT PHYSICS
-- ============================================================
function ENT:UpdateOrbit( ct, dt, phys )
	if not IsValid( phys ) then return end

	self.OrbitAngle = self.OrbitAngle + self.OrbitAngSpeed * dt

	local desX = self.CenterPos.x + math.cos( self.OrbitAngle ) * self.OrbitRadius
	local desY = self.CenterPos.y + math.sin( self.OrbitAngle ) * self.OrbitRadius
	local desZ = self.AltDriftCurrent

	self.JitterPhase  = self.JitterPhase  + self.JitterRate1
	self.JitterPhase2 = self.JitterPhase2 + self.JitterRate2
	local jitter = math.sin(self.JitterPhase) * self.JitterAmp1 + math.sin(self.JitterPhase2) * self.JitterAmp2

	local pos  = self:GetPos()
	local velZ = math.Clamp( (desZ - pos.z) * 8, -120, 120 )

	if ct - self.SkyProbeLastHit > 0.4 then
		local fwd = self:GetForward()
		local tr  = util.TraceLine({
			start  = pos,
			endpos = pos + fwd * self.SkyProbeDist,
			filter = function(e) return e ~= self end,
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit then
			self.SkyYawBias      = self.SkyYawBias + (25 * self.OrbitDir * dt)
			self.SkyProbeLastHit = ct
		else
			self.SkyYawBias = self.SkyYawBias * (1 - dt * 0.25)
		end
	end

	local desiredYaw = math.deg( self.OrbitAngle + (math.pi / 2) * self.OrbitDir ) + self.SkyYawBias
	local yawDelta   = math.NormalizeAngle( desiredYaw - (self.ang.y - MODEL_YAW_OFFSET) )

	self.GlideRollPhase = self.GlideRollPhase + self.GlideRollRate * dt
	local glideRoll = math.sin( self.GlideRollPhase ) * self.GlideRollAmp
	self.SmoothedRoll  = Lerp( 0.05, self.SmoothedRoll,  glideRoll )
	self.SmoothedPitch = Lerp( 0.04, self.SmoothedPitch, 0 )

	local curVel  = phys:GetVelocity()
	local desVelX = math.cos(math.rad(desiredYaw)) * self.Speed + math.cos(math.rad(desiredYaw + 90)) * jitter * 0.005
	local desVelY = math.sin(math.rad(desiredYaw)) * self.Speed + math.sin(math.rad(desiredYaw + 90)) * jitter * 0.005
	phys:SetVelocity( Vector(
		Lerp( 0.10, curVel.x, desVelX ),
		Lerp( 0.10, curVel.y, desVelY ),
		velZ
	) )

	self.ang = Angle( -self.SmoothedRoll, desiredYaw + MODEL_YAW_OFFSET, -self.SmoothedPitch )
	self:SetAngles( self.ang )
end

-- ============================================================
-- WEAPON LOGIC
-- ============================================================
-- A "weapon window" is the period between when UpdateWeaponLogic picks
-- a peaceful-lapse roll and when the next roll fires (or the missile
-- transitions to a dive).  The cargo doors are OPEN for the entire
-- window — including during the dive itself — and close only once
-- the missile is no longer in an active window (peaceful lapse expired
-- without a follow-up window or dive).
--
-- Timeline per cycle:
--   1. WeaponWindowEnd expires  →  roll dice
--   2a. Roll == 3  →  StartDive()  →  doors OPEN (stay open through dive)
--   2b. Roll != 3  →  set new WeaponWindowEnd (peaceful lapse) → doors CLOSE
--       When WeaponWindowEnd expires again → back to step 1
-- ============================================================
function ENT:UpdateWeaponLogic( ct )
	if ct < self.WeaponWindowEnd then
		-- Still inside the current peaceful lapse window — doors are already
		-- open (set when the window was created); nothing to do.
		return
	end

	-- Window has expired.  Roll the dice.
	local roll = math.random( 1, 3 )
	if roll == 3 then
		-- ── DIVE: open doors and begin attack. ──────────────────
		-- Fix (BUG 3): set WeaponWindowEnd so that if Diving is ever
		-- reset externally the logic won't immediately re-enter StartDive.
		self.WeaponWindowEnd = ct + 30   -- generous hold; dive removes entity anyway
		C17_SetCargoDoor( self, true )
		self:StartDive( ct )
	else
		-- ── PEACEFUL LAPSE: doors open while we wait for next roll. ──
		self.WeaponWindowEnd = ct + math.Rand( 4, 9 )
		C17_SetCargoDoor( self, true )
	end
end

-- ============================================================
-- DIVE ATTACK
-- ============================================================
function ENT:StartDive( ct )
	self.Diving = true
	self.DiveAimOffset    = Vector( math.Rand(-400,400), math.Rand(-400,400), 0 )
	self.DiveSpeedCurrent = self.DiveSpeedMin
	self.DiveWobblePhase  = 0

	-- Full collision on dive so the missile can't pass through the ground.
	self:SetCollisionGroup( COLLISION_GROUP_NONE )

	local closest, closestDist = nil, math.huge
	for _, ply in ipairs( player.GetAll() ) do
		if not IsValid(ply) or not ply:Alive() then continue end
		local d = ply:GetPos():DistToSqr( self.CenterPos )
		if d < closestDist then closestDist = d; closest = ply end
	end
	self.DiveTarget    = closest
	self.DiveTargetPos = IsValid(closest) and closest:GetPos() or self.CenterPos
	self.DiveNextTrack = ct + self.DIVE_TrackInterval

	self:Debug( "Dive initiated [salvo " .. self.SalvoIndex .. "]" )
end

function ENT:UpdateDive( ct )
	if not IsValid( self.PhysObj ) then
		self.PhysObj = self:GetPhysicsObject()
	end
	local phys = self.PhysObj
	if not IsValid( phys ) then return end

	if ct >= self.DiveNextTrack then
		self.DiveNextTrack = ct + self.DIVE_TrackInterval
		if IsValid(self.DiveTarget) and self.DiveTarget:Alive() then
			self.DiveTargetPos = self.DiveTarget:GetPos()
		end
	end

	local pos   = self:GetPos()
	local aim   = self.DiveTargetPos + self.DiveAimOffset
	local toAim = (aim - pos):GetNormalized()

	self.DiveWobblePhase  = self.DiveWobblePhase  + self.DiveWobbleSpeed  * FrameTime()
	self.DiveWobblePhaseV = self.DiveWobblePhaseV + self.DiveWobbleSpeedV * FrameTime()
	local right  = self:GetRight()
	local up     = self:GetUp()
	local wobble = right * math.sin(self.DiveWobblePhase)  * self.DiveWobbleAmp
			   + up    * math.sin(self.DiveWobblePhaseV) * self.DiveWobbleAmpV

	self.DiveSpeedCurrent = Lerp( self.DiveSpeedLerp, self.DiveSpeedCurrent, self.DIVE_Speed )

	local vel = toAim * self.DiveSpeedCurrent + wobble
	phys:SetVelocity( vel )

	local lookAng = vel:Angle()
	self.ang = Angle( lookAng.p, lookAng.y, math.sin(self.DiveWobblePhase) * 25 )
	self:SetAngles( self.ang )

	local groundZ     = self.GroundZ or (pos.z - 5000)
	local aboveGround = pos.z - groundZ

	if pos:Distance(aim) < 120 or aboveGround < GROUND_DETONATE_DIST then
		self:DiveExplode( pos )
	end
end

-- ============================================================
-- EXPLODE
-- ============================================================
function ENT:DiveExplode( pos )
	if self.DiveExploded then return end
	self.DiveExploded = true

	-- Fix: SafeAttacker() ensures util.BlastDamage never receives NULL.
	util.BlastDamage( self, SafeAttacker(self), pos, self.DIVE_ExplosionRadius, self.DIVE_ExplosionDamage )

	local ed = EffectData()
	ed:SetOrigin( pos )
	ed:SetScale( 2.5 )
	util.Effect( "Explosion", ed, true, true )

	sound.Play( "ambient/explosions/explode_" .. math.random(1,5) .. ".wav", pos, 145, math.random(85,100), 1.0 )

	-- Close doors: this missile is gone, no further window events from it.
	C17_SetCargoDoor( self, false )

	if IsValid( self.ChuteEnt ) then self.ChuteEnt:Remove() end
	self:Remove()
end

function ENT:CrashExplode( pos )
	if self.ExplodedAlready then return end
	self.ExplodedAlready = true

	util.BlastDamage( self, SafeAttacker(self), pos, self.DIVE_ExplosionRadius * 0.5, self.DIVE_ExplosionDamage * 0.3 )

	local ed = EffectData()
	ed:SetOrigin( pos )
	ed:SetScale( 1.2 )
	util.Effect( "Explosion", ed, true, true )

	sound.Play( "ambient/explosions/explode_" .. math.random(1,5) .. ".wav", pos, 120, math.random(90,110), 0.7 )

	-- Close doors on crash too.
	C17_SetCargoDoor( self, false )

	if IsValid( self.ChuteEnt ) then self.ChuteEnt:Remove() end
	self:Remove()
end

-- ============================================================
-- DAMAGE / DESTRUCTION
-- ============================================================
function ENT:OnTakeDamage( dmginfo )
	if self.Destroyed then return end

	local dmg = dmginfo:GetDamage()
	self.HP = (self.HP or self.MaxHP) - dmg
	self:SetNWInt( "HP", math.max(0, self.HP) )

	local tier = CalcTier( math.max(0, self.HP), self.MaxHP )
	if tier ~= self.DamageTier then
		self.DamageTier = tier
		BroadcastTier( self, tier )
	end

	if self.HP <= 0 then
		self:Destroy()
	end
end

function ENT:Destroy()
	self.Destroyed     = true
	self.DestroyedTime = CurTime()
	self.ExplodeTimer  = CurTime() + math.Rand( 0.4, 1.2 )

	self:SetNWBool( "Destroyed", true )

	self.TumbleAngVel = Vector(
		math.Rand(-120, 120),
		math.Rand(-120, 120),
		math.Rand( -80,  80)
	)

	if IsValid( self.PhysObj ) then
		self.PhysObj:EnableGravity( true )
	end

	-- Close doors: missile is destroyed and will no longer fight.
	C17_SetCargoDoor( self, false )

	if IsValid( self.ChuteEnt ) then self.ChuteEnt:Remove() end
end

function ENT:OnRemove()
	-- Catch any removal path not covered by Destroy/DiveExplode/CrashExplode.
	C17_SetCargoDoor( self, false )
end

-- ============================================================
-- GROUND FINDER
-- ============================================================
function ENT:FindGround( pos )
	local tr = util.TraceLine({
		start  = Vector( pos.x, pos.y, pos.z + 100 ),
		endpos  = Vector( pos.x, pos.y, pos.z - 32000 ),
		filter = self,
		mask   = MASK_SOLID_BRUSHONLY,
	})
	return tr.Hit and tr.HitPos.z or -1
end

-- ============================================================
-- GENERIC VAR HELPERS
-- ============================================================
function ENT:SetVar( key, val ) self["_var_" .. key] = val end
function ENT:GetVar( key, default )
	local v = self["_var_" .. key]
	return (v ~= nil) and v or default
end
