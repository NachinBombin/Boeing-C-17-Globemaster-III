-- ============================================================
-- ent_bombin_gbu53_chute_owned  --  SERVER
-- Palette / chute / 4x visual munition combo for C-17 GBU-53.
--
-- Physics model (post-fix):
--   The palette root is MOVETYPE_VPHYSICS with gravity enabled.
--   A quadratic drag force is applied every PhysicsUpdate tick to
--   simulate chute deceleration, targeting ~90 u/s terminal velocity.
--   This gives Source Engine real velocity data for interpolation on
--   clients, eliminating the choppy MOVETYPE_NONE + SetPos teleport.
--
--   Munitions are SetParent children with fixed local offsets, so
--   they follow the palette with zero per-tick math.
--
--   The chute visual model is also a SetParent child (unchanged).
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
	Vector( 30,  18, 8),
	Vector( 30, -18, 8),
	Vector(-30,  18, 8),
	Vector(-30, -18, 8),
}
local MUNITION_YAW_OFFSETS = { 0, 0, 180, 180 }

-- Chute drag tuning.
-- Terminal velocity target: ~90 u/s downward.
-- F_drag = CHUTE_DRAG_K * v^2  (opposes velocity direction)
-- At terminal: F_drag = gravity_force  =>  k = g / v_t^2
-- GMod default gravity ~600 u/s^2, v_t = 90 u/s  => k = 600/8100 ~= 0.074
-- Physobj mass is ~50 kg (prop_physics default); engine multiplies force
-- by mass internally via ApplyForceCenter, so we pass acceleration directly.
local CHUTE_DRAG_K       = 0.074
local CHUTE_GRAVITY      = 600
local CHUTE_TERMINAL_VEL = -90   -- negative = downward

-- Sway: angular oscillation driven via AddAngleVelocity so the engine
-- can interpolate it on clients (unlike SetAngles teleport).
local SWAY_AMP        = 2.8   -- degrees peak
local SWAY_RATE       = 1.1   -- rad/s
local THINK_DT        = 1 / 20  -- Think tick for non-physics bookkeeping

local CHILD_NOCLIP_HOLD  = 1.8
local DEBRIS_LIFETIME    = 14
local RELEASE_STEP_DELAY = 0.5

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
	self:SetModel(PALETTE_MODEL)
	self:SetModelScale(PALETTE_SCALE, 0)

	-- Physics-based fall: vphysics + gravity so Source interpolates movement.
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)
	self:DrawShadow(false)

	self.SwayClock    = math.Rand(0, math.pi * 2)
	self.MunitionEnts = {}
	self.ChuteEnt     = nil
	self.ChuteClone   = nil
	self.Detached     = false

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableGravity(true)
		-- Seed with a small downward velocity so drag kicks in immediately.
		phys:SetVelocity(Vector(0, 0, -10))
		-- Disable angular damping so our sway drive is not fought by the engine.
		phys:SetDamping(0.05, 0.8)
	end

	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChildren()
	end)

	self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
end

-- ============================================================
-- CHILDREN
-- ============================================================
function ENT:SpawnChildren()
	local missile  = self:GetOwner()
	local launcher = IsValid(missile) and missile.Launcher or nil
	local basePos  = self:GetPos()
	local baseAng  = self:GetAngles()

	-- Chute: cosmetic child, parented so it follows vphysics interpolation.
	local chute = ents.Create("prop_physics")
	if IsValid(chute) then
		chute:SetModel(CHUTE_MODEL)
		chute:SetPos(basePos + CHUTE_ABOVE_PALETTE)
		chute:SetAngles(baseAng)
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

	-- Munitions: parented children with fixed local offsets.
	-- SetParent keeps them rigidly attached to the palette without any
	-- per-tick world-space math, and they inherit the physics interpolation.
	for i = 1, 4 do
		local mun = ents.Create("prop_physics")
		if not IsValid(mun) then continue end

		local off = MUNITION_OFFSETS[i]

		mun:SetModel(MUNITION_MODEL)
		mun:SetPos(basePos + off)
		mun:SetAngles(Angle(0, baseAng.y + MUNITION_YAW_OFFSETS[i], 0))
		mun:Spawn()
		mun:Activate()
		mun:SetModelScale(MUNITION_SCALE, 0)
		mun:SetMoveType(MOVETYPE_NONE)
		mun:SetSolid(SOLID_NONE)
		mun:SetCollisionGroup(COLLISION_GROUP_NONE)
		mun:DrawShadow(false)

		-- Parent to palette so munitions move with it for free.
		mun:SetParent(self)
		mun:SetLocalPos(off)
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

-- ============================================================
-- PHYSICS UPDATE  (called every physics tick, ~66Hz)
-- Applies chute drag and sway angle velocity.
-- Source Engine uses the velocity set here for client interpolation,
-- which is what eliminates the choppy visual.
-- ============================================================
function ENT:PhysicsUpdate(phys, dt)
	if self.Detached then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then return end
	if missile:GetNWBool("EngineOn", false) then
		self:Detach()
		return
	end

	if phys:IsAsleep() then phys:Wake() end

	local vel = phys:GetVelocity()

	-- Lock XY to follow the missile horizontally (palette hangs directly below).
	-- Only the Z axis is free (controlled by drag).
	local missilePos = missile:GetPos()
	local targetXY   = missilePos + PALETTE_ABOVE_MISSILE
	local curPos     = self:GetPos()
	local xyCorrect  = Vector(
		(targetXY.x - curPos.x) * 12,
		(targetXY.y - curPos.y) * 12,
		0
	)

	-- Vertical drag: F = k * vz^2, opposing motion.
	local vz     = vel.z
	local dragZ  = CHUTE_DRAG_K * vz * vz
	if vz < 0 then dragZ = dragZ end   -- drag opposes downward vel: +Z force
	if vz > 0 then dragZ = -dragZ end  -- drag opposes upward vel:   -Z force

	-- Clamp to terminal velocity.
	local newVz = math.max(vz - CHUTE_GRAVITY * dt + dragZ * dt, CHUTE_TERMINAL_VEL)

	phys:SetVelocity(Vector(xyCorrect.x, xyCorrect.y, newVz))

	-- Sway: oscillate pitch via angular velocity so Source interpolates it.
	self.SwayClock = (self.SwayClock or 0) + SWAY_RATE * dt
	local targetPitch = math.sin(self.SwayClock) * SWAY_AMP
	local curAng      = self:GetAngles()
	local missileAng  = missile:GetAngles()
	local desiredAng  = Angle(targetPitch, missileAng.y, 0)
	local angDiff     = desiredAng - curAng
	-- Drive towards desired angle via angular velocity (interpolation-friendly).
	phys:AddAngleVelocity(Vector(angDiff.p * 8, angDiff.y * 8, angDiff.r * 8))
end

-- ============================================================
-- THINK  (low-frequency bookkeeping)
-- ============================================================
function ENT:Think()
	if self.Detached then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then
		self:FullRemove()
		return
	end

	-- Out-of-world guard (unchanged from original).
	if not util.IsInWorld(missile:GetPos()) then
		self:FullRemove()
		return
	end

	self:NextThink(CurTime() + THINK_DT)
	return true
end

-- ============================================================
-- DEBRIS RELEASE
-- Fix: COLLISION_GROUP_INTERACTIVE_DEBRIS does not collide with
-- world brushes in GMod's Source fork.  COLLISION_GROUP_DEBRIS_TRIGGER
-- collides with world/static props but ignores players and other
-- debris, which is the correct behaviour for falling prop junk.
-- ============================================================
local function ReleaseMunition(mun, scatterDir)
	if not IsValid(mun) then return end
	mun:SetParent(nil)   -- detach from palette before going physics
	mun:SetMoveType(MOVETYPE_VPHYSICS)
	mun:SetSolid(SOLID_VPHYSICS)
	mun:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	local mPhys = mun:GetPhysicsObject()
	if IsValid(mPhys) then
		mPhys:Wake()
		local scatter = scatterDir * math.Rand(40, 100)
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

-- ============================================================
-- DETACH  (missile engine ignited)
-- ============================================================
function ENT:Detach()
	if self.Detached then return end
	self.Detached = true

	local pos = self:GetPos()
	local ang = self:GetAngles()

	local chutePos = pos + CHUTE_ABOVE_PALETTE
	if IsValid(self.ChuteEnt) then
		chutePos = self.ChuteEnt:GetPos()
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	-- Spawn a physics-enabled chute clone that falls away.
	local chuteClone = ents.Create("prop_physics")
	if IsValid(chuteClone) then
		chuteClone:SetModel(CHUTE_MODEL)
		chuteClone:SetPos(chutePos)
		chuteClone:SetAngles(ang)
		chuteClone:Spawn()
		chuteClone:Activate()
		chuteClone:SetModelScale(CHUTE_SCALE, 0)
		chuteClone:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
		local cPhys = chuteClone:GetPhysicsObject()
		if IsValid(cPhys) then
			cPhys:Wake()
			cPhys:SetVelocity(Vector(
				math.Rand(-80, 80),
				math.Rand(-80, 80),
				math.Rand(-60, -20)
			))
			cPhys:AddAngleVelocity(Vector(
				math.Rand(-60, 60),
				math.Rand(-60, 60),
				math.Rand(-30, 30)
			))
		end
		self.ChuteClone = chuteClone
	end

	-- Palette itself becomes physics debris (already vphysics, just flip group).
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:Wake()
		palPhys:EnableGravity(true)
		palPhys:SetDamping(0, 0)
		palPhys:SetVelocity(Vector(math.Rand(-60, 60), math.Rand(-60, 60), math.Rand(-30, 10)))
		palPhys:AddAngleVelocity(Vector(math.Rand(-40, 40), math.Rand(-40, 40), math.Rand(-20, 20)))
	end

	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		local scatterDir = MUNITION_OFFSETS[i]:GetNormalized()
		timer.Simple((i - 1) * RELEASE_STEP_DELAY, function()
			ReleaseMunition(mun, scatterDir)
		end)
	end

	sound.Play("npc/combine_soldier/zipline_clip2.wav", pos, 82, math.random(93, 110), 1.0)

	-- Lifetime cleanup.
	local debrisRefs = { self, chuteClone }
	for i = 1, 4 do debrisRefs[#debrisRefs + 1] = self.MunitionEnts[i] end
	timer.Simple(DEBRIS_LIFETIME + ((#self.MunitionEnts - 1) * RELEASE_STEP_DELAY), function()
		for _, e in ipairs(debrisRefs) do
			if IsValid(e) then e:Remove() end
		end
	end)
end

-- ============================================================
-- CLEANUP
-- ============================================================
function ENT:FullRemove()
	self.Detached = true

	if IsValid(self.ChuteEnt) then
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end
	if IsValid(self.ChuteClone) then self.ChuteClone:Remove() self.ChuteClone = nil end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then
			self.MunitionEnts[i]:SetParent(nil)
			self.MunitionEnts[i]:Remove()
			self.MunitionEnts[i] = nil
		end
	end
	self:Remove()
end

function ENT:OnRemove()
	if self.Detached then return end

	if IsValid(self.ChuteEnt) then
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
	end
	if IsValid(self.ChuteClone) then self.ChuteClone:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then
			self.MunitionEnts[i]:SetParent(nil)
			self.MunitionEnts[i]:Remove()
		end
	end
end
