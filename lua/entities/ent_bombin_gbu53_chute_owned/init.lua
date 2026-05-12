-- ============================================================
-- ent_bombin_gbu53_chute_owned  --  SERVER
-- Palette / chute / 4x visual munition combo for C-17 GBU-53.
--
-- Destruction model (INDEPENDENT HP pools):
--   HP_CHUTE  = 100  : player shoots the chute region (ChuteEnt or
--                      ChuteHitbox).  Chute visual removed, drag
--                      disabled.  Palette + GBUs free-fall under raw
--                      gravity.  Each GBU detonates on ground contact.
--
--   HP_PALLET = 50   : player shoots the palette / GBU region
--                      (PalletHitbox, munition props, or this entity).
--                      Mid-air explosion.  Chute falls as debris.
--                      GBUs scatter.  Can happen WITHOUT the chute
--                      having been damaged at all.
--
--   The two pools are COMPLETELY independent.  No overflow.  No
--   sequential dependency.  Which pool gets hit depends entirely on
--   what the player's bullet hits.
--
-- Spawn immunity: no damage is processed for SPAWN_IMMUNITY seconds
-- after Initialize() so the cargo door proximity never kills the combo
-- right as it leaves the plane.
--
-- Physics model:
--   MOVETYPE_VPHYSICS + EnableGravity(true) on the palette root.
--   Quadratic drag in PhysicsUpdate counters gravity to ~90 u/s
--   terminal velocity while chute is intact.
--   Children (chute visual, munitions) are SetParent -- zero per-tick
--   position math on children.
--   Sway via AddAngleVelocity so Source interpolates on clients.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

util.AddNetworkString("bombin_gbu53chute_damage_tier")

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

-- HP pools -- completely independent, each shot by aiming at the
-- respective part of the combo.
local HP_CHUTE  = 100
local HP_PALLET = 50

-- Spawn immunity window.
local SPAWN_IMMUNITY = 1.8

-- Chute drag tuning.
-- At terminal: k * vt^2 == g  =>  k = 600 / (90^2) ~= 0.074
local CHUTE_DRAG_K       = 0.074
local CHUTE_TERMINAL_VEL = -90

-- Free-fall terminal (chute dead).
local FREEFALL_TERMINAL_VEL = -1800

-- Ground detonation.
local GROUND_DETONATE_DIST   = 80
local GBU_EXPLODE_DAMAGE     = 600
local GBU_EXPLODE_RADIUS     = 800
local GBU_EXPLODE_STEP_DELAY = 0.18

-- Pallet midair explosion.
local PALLET_EXPLODE_DAMAGE = 300
local PALLET_EXPLODE_RADIUS = 600

-- Sway.
local SWAY_AMP  = 2.8
local SWAY_RATE = 1.1

local THINK_DT           = 1 / 20
local CHILD_NOCLIP_HOLD  = 1.8
local DEBRIS_LIFETIME    = 14
local RELEASE_STEP_DELAY = 0.5

-- ============================================================
-- HELPERS
-- ============================================================
local function SafeAttacker(ent)
	local owner = ent:GetOwner()
	return IsValid(owner) and owner or ent
end

local function FireExplosionEffect(pos, scale)
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetScale(scale)
	util.Effect("Explosion", ed, true, true)
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
	self:SetModel(PALETTE_MODEL)
	self:SetModelScale(PALETTE_SCALE, 0)

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
	self.ChuteDead    = false
	self.PalletDead   = false

	-- HP pools are independent.
	self.HP_Chute  = HP_CHUTE
	self.HP_Pallet = HP_PALLET
	self.SpawnTime = CurTime()

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableGravity(true)
		phys:SetVelocity(Vector(0, 0, -10))
		phys:SetDamping(0.05, 0.8)
	end

	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChildren()
	end)

	self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
	self:NextThink(CurTime() + THINK_DT)
end

-- ============================================================
-- CHILDREN + HITBOXES
-- Two invisible hitbox entities are spawned and SetParent'd:
--   ChuteHitbox  -- covers the chute region, routes damage to HP_Chute
--   PalletHitbox -- covers the pallet region, routes damage to HP_Pallet
-- The visual chute and munition props remain SOLID_NONE so only the
-- hitboxes (and the palette root itself for pallet hits) receive damage.
-- ============================================================
function ENT:SpawnChildren()
	local missile  = self:GetOwner()
	local launcher = IsValid(missile) and missile.Launcher or nil
	local basePos  = self:GetPos()
	local baseAng  = self:GetAngles()

	-- Visual chute (no collision -- ChuteHitbox handles damage).
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
	end

	-- Chute hitbox: invisible solid sphere in the chute region.
	-- Damage to this entity is routed to HP_Chute.
	local cHitbox = ents.Create("prop_physics")
	if IsValid(cHitbox) then
		cHitbox:SetModel("models/hunter/misc/sphere075x075.mdl")
		cHitbox:SetPos(basePos + CHUTE_ABOVE_PALETTE)
		cHitbox:SetAngles(Angle(0, 0, 0))
		cHitbox:Spawn()
		cHitbox:Activate()
		cHitbox:SetModelScale(3.5, 0)  -- covers chute canopy area
		cHitbox:SetMoveType(MOVETYPE_NONE)
		cHitbox:SetSolid(SOLID_VPHYSICS)
		cHitbox:SetCollisionGroup(COLLISION_GROUP_NONE)
		cHitbox:SetRenderMode(RENDERMODE_NONE)  -- invisible
		cHitbox:DrawShadow(false)
		cHitbox:SetParent(self)
		cHitbox:SetLocalPos(CHUTE_ABOVE_PALETTE)
		cHitbox:SetLocalAngles(Angle(0, 0, 0))
		self.ChuteHitbox = cHitbox

		-- Route damage to the chute HP pool.
		local comboRef = self
		cHitbox.OnTakeDamage = function(hb, dmginfo)
			if IsValid(comboRef) then
				comboRef:TakeChuteHit(dmginfo:GetDamage())
			end
		end

		if IsValid(launcher) then
			constraint.NoCollide(cHitbox, launcher, 0, 0)
			local ref = cHitbox
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(ref) then constraint.RemoveConstraints(ref, "NoCollide") end
			end)
		end
	end

	-- Pallet hitbox: flat box covering the palette + GBU zone.
	-- Damage routes to HP_Pallet.
	local pHitbox = ents.Create("prop_physics")
	if IsValid(pHitbox) then
		pHitbox:SetModel("models/hunter/blocks/cube075x075x075.mdl")
		pHitbox:SetPos(basePos + Vector(0, 0, 8))
		pHitbox:SetAngles(Angle(0, 0, 0))
		pHitbox:Spawn()
		pHitbox:Activate()
		pHitbox:SetModelScale(2.2, 0)  -- covers pallet footprint
		pHitbox:SetMoveType(MOVETYPE_NONE)
		pHitbox:SetSolid(SOLID_VPHYSICS)
		pHitbox:SetCollisionGroup(COLLISION_GROUP_NONE)
		pHitbox:SetRenderMode(RENDERMODE_NONE)
		pHitbox:DrawShadow(false)
		pHitbox:SetParent(self)
		pHitbox:SetLocalPos(Vector(0, 0, 8))
		pHitbox:SetLocalAngles(Angle(0, 0, 0))
		self.PalletHitbox = pHitbox

		local comboRef = self
		pHitbox.OnTakeDamage = function(hb, dmginfo)
			if IsValid(comboRef) then
				comboRef:TakePalletHit(dmginfo:GetDamage())
			end
		end

		if IsValid(launcher) then
			constraint.NoCollide(pHitbox, launcher, 0, 0)
			local ref = pHitbox
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(ref) then constraint.RemoveConstraints(ref, "NoCollide") end
			end)
		end
	end

	-- Visual munition props (SOLID_NONE, damage-less -- pallet hitbox covers them).
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
-- DAMAGE ROUTING
-- Called by hitbox OnTakeDamage callbacks and by this entity's own
-- OnTakeDamage (fallback for direct palette body hits).
-- Spawn immunity is enforced here, once, for both paths.
-- ============================================================
local function IsImmune(self)
	return (CurTime() - self.SpawnTime) < SPAWN_IMMUNITY
end

function ENT:TakeChuteHit(dmg)
	if IsImmune(self) or self.ChuteDead or self.PalletDead then return end

	self.HP_Chute = self.HP_Chute - dmg
	if self.HP_Chute <= 0 then
		self:DestroyChute()
	end
end

function ENT:TakePalletHit(dmg)
	if IsImmune(self) or self.PalletDead then return end

	self.HP_Pallet = self.HP_Pallet - dmg
	if self.HP_Pallet <= 0 then
		self:DestroyPallet()
	end
end

-- Fallback: direct hits on the palette root entity itself (not a
-- hitbox child) are treated as pallet hits.
function ENT:OnTakeDamage(dmginfo)
	self:TakePalletHit(dmginfo:GetDamage())
end

-- ============================================================
-- CHUTE DESTROYED (HP_Chute <= 0)
-- Chute visual + hitbox removed.  Drag disabled.  Palette tumbles
-- into free-fall.  Ground contact triggers GBU detonations.
-- ============================================================
function ENT:DestroyChute()
	if self.ChuteDead then return end
	self.ChuteDead = true

	if IsValid(self.ChuteHitbox) then
		self.ChuteHitbox:SetParent(nil)
		self.ChuteHitbox:Remove()
		self.ChuteHitbox = nil
	end
	if IsValid(self.ChuteEnt) then
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetDamping(0, 0)
		phys:AddAngleVelocity(Vector(
			math.Rand(-60, 60),
			math.Rand(-60, 60),
			math.Rand(-40, 40)
		))
	end

	FireExplosionEffect(self:GetPos() + CHUTE_ABOVE_PALETTE, 1.0)
	sound.Play("ambient/explosions/explode_" .. math.random(1, 5) .. ".wav",
		self:GetPos(), 110, math.random(100, 118), 0.8)
end

-- ============================================================
-- PALLET DESTROYED (HP_Pallet <= 0)
-- Mid-air explosion.  Chute falls as debris.  GBUs scatter.
-- This can happen at any time regardless of chute state.
-- ============================================================
function ENT:DestroyPallet()
	if self.PalletDead then return end
	self.PalletDead = true
	self.Detached   = true

	local pos = self:GetPos()
	local ang = self:GetAngles()

	util.BlastDamage(self, SafeAttacker(self), pos, PALLET_EXPLODE_RADIUS, PALLET_EXPLODE_DAMAGE)
	FireExplosionEffect(pos, 2.2)
	sound.Play("ambient/explosions/explode_" .. math.random(1, 5) .. ".wav",
		pos, 140, math.random(88, 102), 1.0)

	-- Remove hitboxes so they stop accepting damage.
	if IsValid(self.ChuteHitbox) then
		self.ChuteHitbox:SetParent(nil)
		self.ChuteHitbox:Remove()
		self.ChuteHitbox = nil
	end
	if IsValid(self.PalletHitbox) then
		self.PalletHitbox:SetParent(nil)
		self.PalletHitbox:Remove()
		self.PalletHitbox = nil
	end

	-- Chute falls as debris (only if it hasn't already been destroyed).
	local chutePos = pos + CHUTE_ABOVE_PALETTE
	if IsValid(self.ChuteEnt) then
		chutePos = self.ChuteEnt:GetPos()
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	if not self.ChuteDead then
		-- Spawn chute debris clone (same as normal detach path).
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
			timer.Simple(DEBRIS_LIFETIME, function()
				if IsValid(chuteClone) then chuteClone:Remove() end
			end)
		end
	end

	-- Release GBUs as scatter debris.
	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		local scatterDir = MUNITION_OFFSETS[i]:GetNormalized()
		timer.Simple((i - 1) * RELEASE_STEP_DELAY, function()
			if not IsValid(mun) then return end
			mun:SetParent(nil)
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
		end)
	end

	-- Palette becomes debris.
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:SetDamping(0, 0)
		palPhys:Wake()
		palPhys:SetVelocity(Vector(math.Rand(-80, 80), math.Rand(-80, 80), math.Rand(-40, 20)))
		palPhys:AddAngleVelocity(Vector(math.Rand(-50, 50), math.Rand(-50, 50), math.Rand(-30, 30)))
	end

	timer.Simple(DEBRIS_LIFETIME + (4 * RELEASE_STEP_DELAY), function()
		for i = 1, 4 do
			if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
		end
		if IsValid(self) then self:Remove() end
	end)
end

-- ============================================================
-- PHYSICS UPDATE (~66 Hz)
-- ============================================================
function ENT:PhysicsUpdate(phys, dt)
	if self.Detached or self.PalletDead then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then return end
	if missile:GetNWBool("EngineOn", false) then
		self:Detach()
		return
	end

	if phys:IsAsleep() then phys:Wake() end

	local vel        = phys:GetVelocity()
	local vz         = vel.z
	local missilePos = missile:GetPos()
	local targetXY   = missilePos + PALETTE_ABOVE_MISSILE
	local curPos     = self:GetPos()
	local vxCorrect  = (targetXY.x - curPos.x) * 12
	local vyCorrect  = (targetXY.y - curPos.y) * 12

	local newVz
	if not self.ChuteDead then
		local dragDelta = CHUTE_DRAG_K * vz * vz * dt
		if vz >= 0 then dragDelta = -dragDelta end
		newVz = math.max(vz + dragDelta, CHUTE_TERMINAL_VEL)
	else
		newVz = math.max(vz, FREEFALL_TERMINAL_VEL)
	end

	phys:SetVelocity(Vector(vxCorrect, vyCorrect, newVz))

	if not self.ChuteDead then
		self.SwayClock = (self.SwayClock or 0) + SWAY_RATE * dt
		local targetPitch = math.sin(self.SwayClock) * SWAY_AMP
		local curAng      = self:GetAngles()
		local missileAng  = missile:GetAngles()
		local desiredAng  = Angle(targetPitch, missileAng.y, 0)
		local angDiff     = desiredAng - curAng
		phys:AddAngleVelocity(Vector(angDiff.p * 8, angDiff.y * 8, angDiff.r * 8))
	end
end

-- ============================================================
-- THINK (1/20 s)
-- ============================================================
function ENT:Think()
	if self.PalletDead then return end

	local missile = self:GetOwner()
	if not IsValid(missile) then
		self:FullRemove()
		return
	end

	if not util.IsInWorld(missile:GetPos()) then
		self:FullRemove()
		return
	end

	-- Ground-contact detonation while free-falling (chute dead, not yet detached).
	if self.ChuteDead and not self.Detached then
		local pos = self:GetPos()
		local tr  = util.TraceLine({
			start  = pos,
			endpos = pos + Vector(0, 0, -(GROUND_DETONATE_DIST + 10)),
			filter = function(e)
				if e == self then return false end
				for i = 1, 4 do
					if e == self.MunitionEnts[i] then return false end
				end
				if e == self.PalletHitbox then return false end
				return true
			end,
			mask = MASK_SOLID,
		})
		if tr.Hit then
			self:GroundDetonation()
			return
		end
	end

	self:NextThink(CurTime() + THINK_DT)
	return true
end

-- ============================================================
-- GROUND DETONATION
-- ============================================================
function ENT:GroundDetonation()
	if self.PalletDead then return end
	self.PalletDead = true
	self.Detached   = true

	if IsValid(self.PalletHitbox) then
		self.PalletHitbox:SetParent(nil)
		self.PalletHitbox:Remove()
		self.PalletHitbox = nil
	end

	local basePos = self:GetPos()

	for i = 1, 4 do
		local mun         = self.MunitionEnts[i]
		local capturedPos = IsValid(mun) and mun:GetPos() or (basePos + MUNITION_OFFSETS[i])
		timer.Simple((i - 1) * GBU_EXPLODE_STEP_DELAY, function()
			util.BlastDamage(self, SafeAttacker(self), capturedPos,
				GBU_EXPLODE_RADIUS, GBU_EXPLODE_DAMAGE)
			FireExplosionEffect(capturedPos, 2.0)
			sound.Play("ambient/explosions/explode_" .. math.random(1, 5) .. ".wav",
				capturedPos, 140, math.random(88, 104), 1.0)
			if IsValid(mun) then
				mun:SetParent(nil)
				mun:Remove()
			end
		end)
	end

	timer.Simple(4 * GBU_EXPLODE_STEP_DELAY + 0.1, function()
		if IsValid(self) then self:Remove() end
	end)
end

-- ============================================================
-- DETACH (missile engine ignited -- normal release path)
-- ============================================================
function ENT:Detach()
	if self.Detached then return end
	self.Detached = true

	-- Remove hitboxes: combo is no longer a valid target.
	if IsValid(self.ChuteHitbox) then
		self.ChuteHitbox:SetParent(nil)
		self.ChuteHitbox:Remove()
		self.ChuteHitbox = nil
	end
	if IsValid(self.PalletHitbox) then
		self.PalletHitbox:SetParent(nil)
		self.PalletHitbox:Remove()
		self.PalletHitbox = nil
	end

	local pos = self:GetPos()
	local ang = self:GetAngles()

	local chutePos = pos + CHUTE_ABOVE_PALETTE
	if IsValid(self.ChuteEnt) then
		chutePos = self.ChuteEnt:GetPos()
		self.ChuteEnt:SetParent(nil)
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
		chuteClone:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
		local cPhys = chuteClone:GetPhysicsObject()
		if IsValid(cPhys) then
			cPhys:Wake()
			cPhys:SetVelocity(Vector(math.Rand(-80,80), math.Rand(-80,80), math.Rand(-60,-20)))
			cPhys:AddAngleVelocity(Vector(math.Rand(-60,60), math.Rand(-60,60), math.Rand(-30,30)))
		end
		self.ChuteClone = chuteClone
	end

	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:Wake()
		palPhys:EnableGravity(true)
		palPhys:SetDamping(0, 0)
		palPhys:SetVelocity(Vector(math.Rand(-60,60), math.Rand(-60,60), math.Rand(-30,10)))
		palPhys:AddAngleVelocity(Vector(math.Rand(-40,40), math.Rand(-40,40), math.Rand(-20,20)))
	end

	for i = 1, 4 do
		local mun = self.MunitionEnts[i]
		local scatterDir = MUNITION_OFFSETS[i]:GetNormalized()
		timer.Simple((i - 1) * RELEASE_STEP_DELAY, function()
			if not IsValid(mun) then return end
			mun:SetParent(nil)
			mun:SetMoveType(MOVETYPE_VPHYSICS)
			mun:SetSolid(SOLID_VPHYSICS)
			mun:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
			local mPhys = mun:GetPhysicsObject()
			if IsValid(mPhys) then
				mPhys:Wake()
				local scatter = scatterDir * math.Rand(40, 100)
				mPhys:SetVelocity(Vector(
					scatter.x + math.Rand(-30,30),
					scatter.y + math.Rand(-30,30),
					math.Rand(-20,20)
				))
				mPhys:AddAngleVelocity(Vector(math.Rand(-80,80), math.Rand(-80,80), math.Rand(-50,50)))
			end
		end)
	end

	sound.Play("npc/combine_soldier/zipline_clip2.wav", pos, 82, math.random(93,110), 1.0)

	local debrisRefs = { self, chuteClone }
	for i = 1, 4 do debrisRefs[#debrisRefs + 1] = self.MunitionEnts[i] end
	timer.Simple(DEBRIS_LIFETIME + (4 * RELEASE_STEP_DELAY), function()
		for _, e in ipairs(debrisRefs) do
			if IsValid(e) then e:Remove() end
		end
	end)
end

-- ============================================================
-- CLEANUP
-- ============================================================
function ENT:FullRemove()
	self.Detached   = true
	self.PalletDead = true

	for _, field in ipairs({"ChuteEnt", "ChuteHitbox", "PalletHitbox", "ChuteClone"}) do
		if IsValid(self[field]) then
			self[field]:SetParent(nil)
			self[field]:Remove()
			self[field] = nil
		end
	end
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
	for _, field in ipairs({"ChuteEnt", "ChuteHitbox", "PalletHitbox", "ChuteClone"}) do
		if IsValid(self[field]) then
			self[field]:SetParent(nil)
			self[field]:Remove()
		end
	end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then
			self.MunitionEnts[i]:SetParent(nil)
			self.MunitionEnts[i]:Remove()
		end
	end
end
