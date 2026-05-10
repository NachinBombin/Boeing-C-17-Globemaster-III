-- ============================================================
-- ent_bombin_gbu53_chute_owned  —  SERVER
--
-- Palette/chute/4x visual munition combo used by the C-17 GBU-53 drop.
-- Critical fixes:
-- 1) Children are spawned with temporary NoCollide against the launcher plane.
-- 2) Owner remains the loitering missile entity; Think() never follows the plane.
-- 3) Combo tracks the missile cleanly, then detaches into debris on ignition.
-- 4) FIX: collision group changed from COLLISION_GROUP_WORLD to
--    COLLISION_GROUP_INTERACTIVE_DEBRIS so the chute prop does not clip
--    into world geometry on detach.
-- 5) FIX: detached debris refs gathered into a single timer to prevent prop leaks.
-- 6) FIX: chute no longer falls after ignition.
--    Root cause: Detach() was calling SetMoveType(MOVETYPE_VPHYSICS) on the
--    pre-existing parented prop_physics ChuteEnt. A reused parented prop has
--    no guaranteed gravity state and its physics object may be asleep after
--    unparenting. The Z velocity range was also -20..+30, allowing upward drift.
--    Fix: mirror the JASSM chute pattern exactly — remove the old ChuteEnt and
--    spawn a fresh prop_physics clone at its position with gravity on by default
--    and a proper downward velocity seeded.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PALETTE_MODEL  = "models/props_phx/construct/metal_wire1x1x2.mdl"
local MUNITION_MODEL = "models/sw/usa/bombs/guided/gbu53.mdl"
local CHUTE_MODEL    = "models/v92/parachutez/flying.mdl"

local PALETTE_SCALE  = 1.0
local MUNITION_SCALE = 1.0
local CHUTE_SCALE    = 2.2

local PALETTE_ABOVE_MISSILE = Vector(0, 0, 110)
local CHUTE_ABOVE_PALETTE   = Vector(0, 0, 90)

local MUNITION_OFFSETS = {
	Vector( 18,  10, -5),
	Vector( 18, -10, -5),
	Vector(-18,  10, -5),
	Vector(-18, -10, -5),
}
local MUNITION_YAW_OFFSETS = { 0, 0, 180, 180 }

local SWAY_AMP  = 2.8
local SWAY_RATE = 1.1
local THINK_DT  = 1 / 60
local CHILD_NOCLIP_HOLD  = 1.8
local DEBRIS_LIFETIME    = 14

function ENT:Initialize()
	self:SetModel(PALETTE_MODEL)
	self:SetModelScale(PALETTE_SCALE, 0)
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_NONE)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:DrawShadow(false)

	self.SwayClock    = math.Rand(0, math.pi * 2)
	self.MunitionEnts = {}
	self.ChuteEnt     = nil
	self.Detached     = false

	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChildren()
	end)

	self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
end

function ENT:SpawnChildren()
	local missile  = self:GetOwner()
	local launcher = IsValid(missile) and missile.Launcher or nil

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
		chute:SetParent(self)
		chute:SetLocalPos(CHUTE_ABOVE_PALETTE)
		chute:SetLocalAngles(Angle(0, 0, 0))
		self.ChuteEnt = chute

		if IsValid(launcher) then
			constraint.NoCollide(chute, launcher, 0, 0)
			local cRef = chute
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(cRef) then constraint.RemoveConstraints(cRef, "NoCollide") end
			end)
		end
	end

	for i = 1, 4 do
		local mun = ents.Create("prop_physics")
		if not IsValid(mun) then continue end

		mun:SetModel(MUNITION_MODEL)
		mun:SetPos(self:GetPos() + MUNITION_OFFSETS[i])
		mun:SetAngles(Angle(0, self:GetAngles().y + MUNITION_YAW_OFFSETS[i], 0))
		mun:Spawn()
		mun:Activate()
		mun:SetModelScale(MUNITION_SCALE, 0)
		mun:SetMoveType(MOVETYPE_NONE)
		mun:SetSolid(SOLID_NONE)
		mun:SetCollisionGroup(COLLISION_GROUP_NONE)
		mun:DrawShadow(false)
		mun:SetParent(self)
		mun:SetLocalPos(MUNITION_OFFSETS[i])
		mun:SetLocalAngles(Angle(0, MUNITION_YAW_OFFSETS[i], 0))
		self.MunitionEnts[i] = mun

		if IsValid(launcher) then
			constraint.NoCollide(mun, launcher, 0, 0)
			local mRef = mun
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(mRef) then constraint.RemoveConstraints(mRef, "NoCollide") end
			end)
		end
	end
end

function ENT:Think()
	if self.Detached then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then
		self:FullRemove()
		return
	end

	if missile:GetNWBool("EngineOn", false) then
		self:Detach()
		return
	end

	self.SwayClock = self.SwayClock + SWAY_RATE * THINK_DT
	local sway = math.sin(self.SwayClock) * SWAY_AMP
	local missileAng = missile:GetAngles()

	self:SetPos(missile:GetPos() + PALETTE_ABOVE_MISSILE)
	self:SetAngles(Angle(sway, missileAng.y, 0))

	self:NextThink(CurTime() + THINK_DT)
	return true
end

function ENT:Detach()
	if self.Detached then return end
	self.Detached = true

	local pos = self:GetPos()
	local ang = self:GetAngles()

	-- --------------------------------------------------------
	-- CHUTE: mirror the JASSM pattern.
	-- Remove the old parented ChuteEnt and spawn a fresh prop_physics
	-- clone in its place. A brand-new prop_physics always initialises
	-- with gravity on by default, guaranteeing it will fall. Reusing the
	-- parented prop via SetMoveType was unreliable: the physics object
	-- could be asleep after unparenting and gravity state was undefined.
	-- --------------------------------------------------------
	local chutePos = pos + CHUTE_ABOVE_PALETTE
	if IsValid(self.ChuteEnt) then
		chutePos = self.ChuteEnt:GetPos()  -- use actual world pos in case of drift
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	local chuteClone = ents.Create("prop_physics")
	if IsValid(chuteClone) then
		chuteClone:SetModel(CHUTE_MODEL)
		chuteClone:SetPos(chutePos)
		chuteClone:SetAngles(ang)
		chuteClone:Spawn()
		chuteClone:Activate()
		chuteClone:SetModelScale(CHUTE_SCALE, 0)
		chuteClone:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
		local cPhys = chuteClone:GetPhysicsObject()
		if IsValid(cPhys) then
			cPhys:Wake()
			-- Seed a convincing cinematic drift: lateral scatter + downward fall
			cPhys:SetVelocity(Vector(
				math.Rand(-80, 80),
				math.Rand(-80, 80),
				math.Rand(-60, -20)   -- always downward, matching JASSM feel
			))
			cPhys:AddAngleVelocity(Vector(
				math.Rand(-60, 60),
				math.Rand(-60, 60),
				math.Rand(-30, 30)
			))
		end
	end

	-- --------------------------------------------------------
	-- PALETTE + MUNITIONS: switch to live physics normally.
	-- --------------------------------------------------------
	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		if IsValid(mun) then
			mun:SetParent(nil)
			mun:SetPos(pos + MUNITION_OFFSETS[i])
			mun:SetAngles(Angle(0, ang.y + MUNITION_YAW_OFFSETS[i], 0))
		end
	end

	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)

	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:Wake()
		palPhys:SetVelocity(Vector(math.Rand(-60, 60), math.Rand(-60, 60), math.Rand(-30, 10)))
		palPhys:AddAngleVelocity(Vector(math.Rand(-40, 40), math.Rand(-40, 40), math.Rand(-20, 20)))
	end

	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		if not IsValid(mun) then continue end
		mun:SetMoveType(MOVETYPE_VPHYSICS)
		mun:SetSolid(SOLID_VPHYSICS)
		mun:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
		local mPhys = mun:GetPhysicsObject()
		if IsValid(mPhys) then
			mPhys:Wake()
			local scatter = MUNITION_OFFSETS[i]:GetNormalized() * math.Rand(40, 100)
			mPhys:SetVelocity(Vector(
				scatter.x + math.Rand(-30, 30),
				scatter.y + math.Rand(-30, 30),
				math.Rand(-20, 20)
			))
			mPhys:AddAngleVelocity(Vector(math.Rand(-80, 80), math.Rand(-80, 80), math.Rand(-50, 50)))
		end
	end

	sound.Play("npc/combine_soldier/zipline_clip2.wav", pos, 82, math.random(93, 110), 1.0)

	-- Collect all debris for the cleanup timer.
	local debrisRefs = { self, chuteClone }
	for i = 1, 4 do debrisRefs[#debrisRefs + 1] = self.MunitionEnts[i] end
	timer.Simple(DEBRIS_LIFETIME, function()
		for _, e in ipairs(debrisRefs) do
			if IsValid(e) then e:Remove() end
		end
	end)
end

function ENT:FullRemove()
	if IsValid(self.ChuteEnt) then self.ChuteEnt:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
	end
	self:Remove()
end

function ENT:OnRemove()
	if self.Detached then return end
	if IsValid(self.ChuteEnt) then self.ChuteEnt:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
	end
end
