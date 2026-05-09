-- ============================================================
-- ent_bombin_gbu53_chute_owned  —  SERVER
--
-- More complex chute assembly than the JASSM version:
--
--   STRUCTURE (top to bottom, all parented to the palette):
--
--     [parachute]         -- parachutez/flying.mdl  (above palette)
--         |
--     [palette]           -- metal_wire1x1x2.mdl  (THIS entity's model)
--      /  |  |  \
--   [m1][m2][m3][m4]      -- 4x gbu53.mdl  (visual-only, SOLID_NONE)
--
-- The palette (this entity) tracks the missile position.
-- The chute is a separate prop_physics parented to the palette.
-- The 4 munition props are parented to the palette.
--
-- Detach trigger: missile:GetNWBool("EngineOn") = true
-- On detach, all parenting is cleared and everything gets
-- a random tumble velocity. The palette falls as debris.
-- COLLISION_GROUP_DEBRIS is set on the abandoned palette so
-- it cannot clip the missile (fixes known JASSM chute bug).
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- CONSTANTS
-- ============================================================

local PALETTE_MODEL  = "models/props_phx/construct/metal_wire1x1x2.mdl"
local MUNITION_MODEL = "models/sw/usa/bombs/guided/gbu53.mdl"
local CHUTE_MODEL    = "models/v92/parachutez/flying.mdl"

local PALETTE_SCALE  = 1.0
local MUNITION_SCALE = 1.0
local CHUTE_SCALE    = 2.2

-- Offset of the palette centre relative to the missile
-- (palette sits just below the chute attachment point)
local PALETTE_ABOVE_MISSILE = Vector(0, 0, 110)

-- Chute sits above the palette
local CHUTE_ABOVE_PALETTE = Vector(0, 0, 90)

-- 4 munition positions on the palette (local space, XY plane)
-- Arranged in a 2×2 rectangle matching the palette footprint.
-- Adjust these if the model scale needs tweaking.
local MUNITION_OFFSETS = {
	Vector(  18,  10, -5 ),   -- front-starboard
	Vector(  18, -10, -5 ),   -- front-port
	Vector( -18,  10, -5 ),   -- rear-starboard
	Vector( -18, -10, -5 ),   -- rear-port
}

-- Munition yaw offsets so they don't all point identically
-- (purely cosmetic — adds natural "stacked" look)
local MUNITION_YAW_OFFSETS = { 0, 0, 180, 180 }

local SWAY_AMP  = 2.8    -- degrees, palette sway amplitude
local SWAY_RATE = 1.1    -- rad/s
local THINK_DT  = 1 / 60 -- server Think throttle

-- ============================================================
-- INITIALIZE
-- ============================================================

function ENT:Initialize()
	-- Palette (this entity)
	self:SetModel(PALETTE_MODEL)
	self:SetModelScale(PALETTE_SCALE, 0)
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_NONE)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:DrawShadow(false)

	self.SwayClock   = math.Rand(0, math.pi * 2)
	self.MunitionEnts = {}
	self.ChuteEnt    = nil
	self.Detached    = false

	-- Spawn child props after one tick so the palette has a valid EntIndex
	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChildren()
	end)

	self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
end

-- ============================================================
-- SPAWN CHILDREN  (chute + 4 munitions)
-- ============================================================

function ENT:SpawnChildren()
	-- 1. Parachute above the palette --------------------------------
	local chute = ents.Create("prop_physics")
	if IsValid(chute) then
		chute:SetModel(CHUTE_MODEL)
		chute:SetPos(self:GetPos() + CHUTE_ABOVE_PALETTE)
		chute:SetAngles(self:GetAngles())
		chute:Spawn()
		chute:Activate()
		chute:SetModelScale(CHUTE_SCALE, 0)
		chute:SetMoveType(MOVETYPE_NONE)
		chute:SetSolid(SOLID_NONE)
		chute:SetCollisionGroup(COLLISION_GROUP_NONE)
		chute:DrawShadow(false)
		-- Parent to this palette entity so it moves with us
		chute:SetParent(self)
		chute:SetLocalPos(CHUTE_ABOVE_PALETTE)
		chute:SetLocalAngles(Angle(0, 0, 0))
		self.ChuteEnt = chute
	end

	-- 2. Four visual munitions on the palette ----------------------
	for i = 1, 4 do
		local mun = ents.Create("prop_physics")
		if not IsValid(mun) then continue end

		mun:SetModel(MUNITION_MODEL)
		mun:SetPos(self:GetPos() + MUNITION_OFFSETS[i])
		mun:SetAngles(Angle(0, (self:GetAngles().y + MUNITION_YAW_OFFSETS[i]), 0))
		mun:Spawn()
		mun:Activate()
		mun:SetModelScale(MUNITION_SCALE, 0)
		mun:SetMoveType(MOVETYPE_NONE)
		mun:SetSolid(SOLID_NONE)
		mun:SetCollisionGroup(COLLISION_GROUP_NONE)
		mun:DrawShadow(false)
		-- Parent to palette
		mun:SetParent(self)
		mun:SetLocalPos(MUNITION_OFFSETS[i])
		mun:SetLocalAngles(Angle(0, MUNITION_YAW_OFFSETS[i], 0))

		self.MunitionEnts[i] = mun
	end
end

-- ============================================================
-- THINK  (60 Hz)
-- ============================================================

function ENT:Think()
	if self.Detached then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then
		self:FullRemove()
		return
	end

	-- Check ignition signal — same NWBool as JASSM chute
	if missile:GetNWBool("EngineOn", false) then
		self:Detach()
		return
	end

	-- Track missile, add sway
	self.SwayClock = self.SwayClock + SWAY_RATE * THINK_DT
	local sway      = math.sin(self.SwayClock) * SWAY_AMP
	local missileAng = missile:GetAngles()

	self:SetPos(missile:GetPos() + PALETTE_ABOVE_MISSILE)
	self:SetAngles(Angle(sway, missileAng.y, 0))

	self:NextThink(CurTime() + THINK_DT)
	return true
end

-- ============================================================
-- DETACH  (called when missile engine ignites)
-- ============================================================

function ENT:Detach()
	if self.Detached then return end
	self.Detached = true

	local pos = self:GetPos()
	local ang = self:GetAngles()

	-- Unparent all children so they tumble freely
	if IsValid(self.ChuteEnt) then
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:SetPos(pos + CHUTE_ABOVE_PALETTE)
		self.ChuteEnt:SetAngles(ang)
	end

	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		if IsValid(mun) then
			mun:SetParent(nil)
			mun:SetPos(pos + MUNITION_OFFSETS[i])
			mun:SetAngles(Angle(0, ang.y + MUNITION_YAW_OFFSETS[i], 0))
		end
	end

	-- Convert palette to falling debris
	-- BUG FIX: use COLLISION_GROUP_DEBRIS so it cannot collide with
	-- the missile that just ignited below it.
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:Wake()
		palPhys:SetVelocity(Vector(
			math.Rand(-60, 60),
			math.Rand(-60, 60),
			math.Rand(-30, 10)
		))
		palPhys:AddAngleVelocity(Vector(
			math.Rand(-40, 40),
			math.Rand(-40, 40),
			math.Rand(-20, 20)
		))
	end

	-- Chute tumbles
	if IsValid(self.ChuteEnt) then
		self.ChuteEnt:SetMoveType(MOVETYPE_VPHYSICS)
		self.ChuteEnt:SetSolid(SOLID_VPHYSICS)
		self.ChuteEnt:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		local cPhys = self.ChuteEnt:GetPhysicsObject()
		if IsValid(cPhys) then
			cPhys:Wake()
			cPhys:SetVelocity(Vector(
				math.Rand(-80, 80),
				math.Rand(-80, 80),
				math.Rand(-20, 30)
			))
			cPhys:AddAngleVelocity(Vector(
				math.Rand(-60, 60),
				math.Rand(-60, 60),
				math.Rand(-30, 30)
			))
		end
	end

	-- Munitions scatter off the palette
	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		if not IsValid(mun) then continue end
		mun:SetMoveType(MOVETYPE_VPHYSICS)
		mun:SetSolid(SOLID_VPHYSICS)
		mun:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		local mPhys = mun:GetPhysicsObject()
		if IsValid(mPhys) then
			mPhys:Wake()
			-- Each munition gets a unique outward scatter direction
			local scatter = MUNITION_OFFSETS[i]:GetNormalized() * math.Rand(40, 100)
			mPhys:SetVelocity(Vector(
				scatter.x + math.Rand(-30, 30),
				scatter.y + math.Rand(-30, 30),
				math.Rand(-20, 20)
			))
			mPhys:AddAngleVelocity(Vector(
				math.Rand(-80, 80),
				math.Rand(-80, 80),
				math.Rand(-50, 50)
			))
		end
	end

	sound.Play("npc/combine_soldier/zipline_clip2.wav", pos, 82, math.random(93, 110), 1.0)

	-- Auto-remove all debris after 14 seconds
	local allEnts = { self, self.ChuteEnt }
	for i = 1, 4 do allEnts[#allEnts + 1] = self.MunitionEnts[i] end

	timer.Simple(14, function()
		for _, e in ipairs(allEnts) do
			if IsValid(e) then e:Remove() end
		end
	end)
end

-- ============================================================
-- FULL REMOVE  (missile died before ignition)
-- ============================================================

function ENT:FullRemove()
	if IsValid(self.ChuteEnt) then self.ChuteEnt:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
	end
	self:Remove()
end

-- ============================================================
-- REMOVE
-- ============================================================

function ENT:OnRemove()
	-- Children are cleaned up by FullRemove or the 14s timer.
	-- If somehow we get here without that, clean up stragglers.
	if self.Detached then return end
	if IsValid(self.ChuteEnt) then self.ChuteEnt:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
	end
end
