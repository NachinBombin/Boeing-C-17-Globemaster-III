-- ============================================================
-- ent_bombin_gbu53_chute_owned  --  SERVER
-- Palette / chute / 4x visual munition combo for C-17 GBU-53.
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

local SWAY_AMP  = 2.8
local SWAY_RATE = 1.1
local THINK_DT  = 1 / 60
local CHILD_NOCLIP_HOLD  = 1.8
local DEBRIS_LIFETIME    = 14
local RELEASE_STEP_DELAY = 0.5

-- ============================================================
-- INITIALIZE
-- ============================================================
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
	self.ChuteClone   = nil   -- track detach-phase clone to prevent leaks
	self.Detached     = false

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

	-- Chute: purely cosmetic MOVETYPE_NONE child, parented for position.
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

	-- Munitions: world-space manual tracking in Think(), no SetParent.
	local cosY = math.cos(math.rad(baseAng.y))
	local sinY = math.sin(math.rad(baseAng.y))
	for i = 1, 4 do
		local mun = ents.Create("prop_physics")
		if not IsValid(mun) then continue end

		local off = MUNITION_OFFSETS[i]
		local wx  = off.x * cosY - off.y * sinY
		local wy  = off.x * sinY + off.y * cosY

		mun:SetModel(MUNITION_MODEL)
		mun:SetPos(Vector(basePos.x + wx, basePos.y + wy, basePos.z + off.z))
		mun:SetAngles(Angle(0, baseAng.y + MUNITION_YAW_OFFSETS[i], 0))
		mun:Spawn()
		mun:Activate()
		mun:SetModelScale(MUNITION_SCALE, 0)
		mun:SetMoveType(MOVETYPE_NONE)
		mun:SetSolid(SOLID_NONE)
		mun:SetCollisionGroup(COLLISION_GROUP_NONE)
		mun:DrawShadow(false)
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
-- THINK  (freefall tracking)
-- ============================================================
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

	local missilePos = missile:GetPos()

	-- Fix: if the missile has drifted outside the world (skybox boundary
	-- on small maps, or the orbit radius carrying it past map edges),
	-- the entire combo would be teleported out-of-bounds and silently
	-- removed by the engine, leaving orphaned siblings.  Detect this
	-- early and cleanly remove the whole combo instead.
	if not util.IsInWorld(missilePos) then
		self:FullRemove()
		return
	end

	self.SwayClock = self.SwayClock + SWAY_RATE * THINK_DT
	local sway      = math.sin(self.SwayClock) * SWAY_AMP
	local missileAng = missile:GetAngles()
	local palettePos = missilePos + PALETTE_ABOVE_MISSILE
	local paletteYaw = missileAng.y

	self:SetPos(palettePos)
	self:SetAngles(Angle(sway, paletteYaw, 0))

	local cosY = math.cos(math.rad(paletteYaw))
	local sinY = math.sin(math.rad(paletteYaw))
	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		if not IsValid(mun) then continue end
		local off = MUNITION_OFFSETS[i]
		local wx  = off.x * cosY - off.y * sinY
		local wy  = off.x * sinY + off.y * cosY
		mun:SetPos(Vector(palettePos.x + wx, palettePos.y + wy, palettePos.z + off.z))
		mun:SetAngles(Angle(sway, paletteYaw + MUNITION_YAW_OFFSETS[i], 0))
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
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	-- Spawn a physics-enabled chute clone that falls away.
	-- Store reference so OnRemove can clean it up if the combo is
	-- removed before the debris lifetime timer fires.
	local chuteClone = ents.Create("prop_physics")
	if IsValid(chuteClone) then
		chuteClone:SetModel(CHUTE_MODEL)
		chuteClone:SetPos(chutePos)
		chuteClone:SetAngles(ang)
		chuteClone:Spawn()
		chuteClone:Activate()
		chuteClone:SetModelScale(CHUTE_SCALE, 0)
		-- Fix: same collision group correction as munitions.
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

	-- Palette itself becomes physics debris.
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)

	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:Wake()
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

	-- Lifetime cleanup: remove all debris after it has settled.
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
	-- Guard: FullRemove is only called from Think (non-Detached path).
	-- Setting Detached = true first prevents OnRemove from attempting a
	-- second removal of the same child entities.
	self.Detached = true

	if IsValid(self.ChuteEnt)   then self.ChuteEnt:Remove()   self.ChuteEnt   = nil end
	if IsValid(self.ChuteClone) then self.ChuteClone:Remove() self.ChuteClone = nil end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then
			self.MunitionEnts[i]:Remove()
			self.MunitionEnts[i] = nil
		end
	end
	self:Remove()
end

function ENT:OnRemove()
	-- Detach() sets self.Detached = true and schedules its own timer-based
	-- cleanup, so we only need to act here for the non-detached path
	-- (e.g. missile removed before engine ignition, or FullRemove called).
	if self.Detached then return end

	if IsValid(self.ChuteEnt)   then self.ChuteEnt:Remove()   end
	if IsValid(self.ChuteClone) then self.ChuteClone:Remove() end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
	end
end
