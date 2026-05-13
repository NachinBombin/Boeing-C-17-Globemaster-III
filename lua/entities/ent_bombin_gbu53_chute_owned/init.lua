-- ============================================================
-- ent_bombin_gbu53_chute_owned  --  SERVER
-- Palette / chute / 4x visual munition combo for C-17 GBU-53.
--
-- Visual fire damage system mirrors single GBU (ent_bombin_gbu53_owned):
--   CalcPalletTier / CalcChuteTier -> BroadcastPalletTier / BroadcastChuteTier
--   broadcast net msgs on every HP change -> client drives CreateParticleSystem.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

util.AddNetworkString("bombin_gbu53chute_damage_tier")
util.AddNetworkString("bombin_gbu53chute_pallet_tier")
util.AddNetworkString("bombin_gbu53chute_chute_tier")

local ROOT_MODEL     = "models/hunter/blocks/cube1x1x1.mdl"
local PALLET_MODEL   = "models/props_phx/construct/metal_wire1x1x2.mdl"
local MUNITION_MODEL = "models/sw/usa/bombs/guided/gbu53.mdl"
local CHUTE_MODEL    = "models/v92/parachutez/flying.mdl"

local PALLET_SCALE    = 1.0
local MUNITION_SCALE  = 1.0
local CHUTE_SCALE     = 2.2
local ROOT_PHYS_SCALE = 1.6

local CHUTE_ABOVE_PALETTE   = Vector(0, 0, 90)
local PALETTE_ABOVE_MISSILE = Vector(0, 0, 110)

local MUNITION_OFFSETS = {
	Vector( 30,  18, 2),
	Vector( 30, -18, 2),
	Vector(-30,  18, 2),
	Vector(-30, -18, 2),
}
local MUNITION_YAW_OFFSETS = { 0, 0, 180, 180 }

local HP_CHUTE  = 100
local HP_PALLET = 50

local SPAWN_IMMUNITY = 1.8

local CHUTE_DRAG_K           = 0.074
local CHUTE_TERMINAL_VEL     = -90
local FREEFALL_TERMINAL_VEL  = -1800

local GROUND_DETONATE_DIST   = 80
local GBU_EXPLODE_DAMAGE     = 600
local GBU_EXPLODE_RADIUS     = 800
local GBU_EXPLODE_STEP_DELAY = 0.18

local PALLET_EXPLODE_DAMAGE  = 300
local PALLET_EXPLODE_RADIUS  = 600

local SWAY_AMP   = 3.0
local SWAY_RATE  = 0.8

local THINK_DT           = 1 / 20
local CHILD_NOCLIP_HOLD  = 1.8
local DEBRIS_LIFETIME    = 14
local RELEASE_STEP_DELAY = 0.5

local function CalcPalletTier(hp, maxHP)
	local frac = hp / maxHP
	if frac > 0.66 then return 0 end
	if frac > 0.33 then return 1 end
	if hp   > 0    then return 2 end
	return 3
end

local function CalcChuteTier(hp, maxHP)
	local frac = hp / maxHP
	if frac > 0.5  then return 0 end
	if hp   > 0    then return 1 end
	return 2
end

local function BroadcastPalletTier(ent, tier)
	net.Start("bombin_gbu53chute_pallet_tier")
		net.WriteUInt(ent:EntIndex(), 16)
		net.WriteUInt(tier, 2)
	net.Broadcast()
end

local function BroadcastChuteTier(ent, tier)
	net.Start("bombin_gbu53chute_chute_tier")
		net.WriteUInt(ent:EntIndex(), 16)
		net.WriteUInt(tier, 2)
	net.Broadcast()
end

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

function ENT:Initialize()
	self:SetModel(ROOT_MODEL)
	self:SetModelScale(ROOT_PHYS_SCALE, 0)
	self:SetRenderMode(RENDERMODE_NONE)
	self:DrawShadow(false)

	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_NONE)

	self.SwayClock    = math.Rand(0, math.pi * 2)
	self.MunitionEnts = {}
	self.PalletVisual = nil
	self.ChuteEnt     = nil
	self.ChuteHitbox  = nil
	self.PalletHitbox = nil
	self.ChuteClone   = nil
	self.Detached     = false
	self.ChuteDead    = false
	self.PalletDead   = false
	self.HP_Chute     = HP_CHUTE
	self.HP_Pallet    = HP_PALLET
	self.PalletTier   = 0
	self.ChuteTier    = 0
	self.SpawnTime    = CurTime()
	self.PhysVz       = -10

	self:SetNWInt("HP_Pallet", HP_PALLET)
	self:SetNWInt("HP_Chute",  HP_CHUTE)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableGravity(false)
		phys:SetDamping(0, 0)
		phys:SetVelocity(Vector(0, 0, -10))
	end

	timer.Simple(0, function()
		if not IsValid(self) then return end
		self:SpawnChildren()
		self:RegisterDamageHook()
	end)

	self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
	self:NextThink(CurTime() + THINK_DT)
end

function ENT:RegisterDamageHook()
	local comboRef = self
	local hookName = "GBU53Chute_Damage_" .. self:EntIndex()

	hook.Add("EntityTakeDamage", hookName, function(target, dmginfo)
		if not IsValid(comboRef) then
			hook.Remove("EntityTakeDamage", hookName)
			return
		end
		if target == comboRef.ChuteHitbox then
			comboRef:TakeChuteHit(dmginfo:GetDamage())
			dmginfo:SetDamage(0)
		elseif target == comboRef.PalletHitbox then
			comboRef:TakePalletHit(dmginfo:GetDamage())
			dmginfo:SetDamage(0)
		end
	end)

	self.DamageHookName = hookName
end

function ENT:SpawnChildren()
	local missile  = self:GetOwner()
	local launcher = IsValid(missile) and missile.Launcher or nil
	local basePos  = self:GetPos()
	local baseAng  = self:GetAngles()

	local palVis = ents.Create("prop_physics")
	if IsValid(palVis) then
		palVis:SetModel(PALLET_MODEL)
		palVis:SetPos(basePos)
		palVis:SetAngles(baseAng)
		palVis:Spawn()
		palVis:Activate()
		palVis:SetModelScale(PALLET_SCALE, 0)
		palVis:SetMoveType(MOVETYPE_NONE)
		palVis:SetSolid(SOLID_NONE)
		palVis:SetCollisionGroup(COLLISION_GROUP_NONE)
		palVis:DrawShadow(false)
		palVis:SetParent(self)
		palVis:SetLocalPos(Vector(0, 0, 0))
		palVis:SetLocalAngles(Angle(0, 0, 0))
		self.PalletVisual = palVis
	end

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

	local cHitbox = ents.Create("prop_physics")
	if IsValid(cHitbox) then
		cHitbox:SetModel("models/hunter/misc/sphere075x075.mdl")
		cHitbox:SetPos(basePos + CHUTE_ABOVE_PALETTE)
		cHitbox:SetAngles(Angle(0, 0, 0))
		cHitbox:PhysicsInit(SOLID_VPHYSICS)
		cHitbox:Spawn()
		cHitbox:Activate()
		cHitbox:SetModelScale(3.5, 0)
		cHitbox:SetMoveType(MOVETYPE_NONE)
		cHitbox:SetSolid(SOLID_VPHYSICS)
		cHitbox:SetCollisionGroup(COLLISION_GROUP_NONE)
		cHitbox:SetRenderMode(RENDERMODE_NONE)
		cHitbox:DrawShadow(false)
		cHitbox:SetParent(self)
		cHitbox:SetLocalPos(CHUTE_ABOVE_PALETTE)
		cHitbox:SetLocalAngles(Angle(0, 0, 0))
		self.ChuteHitbox = cHitbox

		if IsValid(launcher) then
			constraint.NoCollide(cHitbox, launcher, 0, 0)
			local ref = cHitbox
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(ref) then constraint.RemoveConstraints(ref, "NoCollide") end
			end)
		end
	end

	local pHitbox = ents.Create("prop_physics")
	if IsValid(pHitbox) then
		pHitbox:SetModel("models/hunter/blocks/cube075x075x075.mdl")
		pHitbox:SetPos(basePos + Vector(0, 0, 8))
		pHitbox:SetAngles(Angle(0, 0, 0))
		pHitbox:PhysicsInit(SOLID_VPHYSICS)
		pHitbox:Spawn()
		pHitbox:Activate()
		pHitbox:SetModelScale(2.2, 0)
		pHitbox:SetMoveType(MOVETYPE_NONE)
		pHitbox:SetSolid(SOLID_VPHYSICS)
		pHitbox:SetCollisionGroup(COLLISION_GROUP_NONE)
		pHitbox:SetRenderMode(RENDERMODE_NONE)
		pHitbox:DrawShadow(false)
		pHitbox:SetParent(self)
		pHitbox:SetLocalPos(Vector(0, 0, 8))
		pHitbox:SetLocalAngles(Angle(0, 0, 0))
		self.PalletHitbox = pHitbox

		if IsValid(launcher) then
			constraint.NoCollide(pHitbox, launcher, 0, 0)
			local ref = pHitbox
			timer.Simple(CHILD_NOCLIP_HOLD, function()
				if IsValid(ref) then constraint.RemoveConstraints(ref, "NoCollide") end
			end)
		end
	end

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

local function IsImmune(ent)
	return (CurTime() - (ent.SpawnTime or 0)) < SPAWN_IMMUNITY
end

function ENT:TakeChuteHit(dmg)
	if IsImmune(self) or self.ChuteDead or self.PalletDead then return end
	self.HP_Chute = self.HP_Chute - dmg
	self:SetNWInt("HP_Chute", math.max(0, self.HP_Chute))

	local tier = CalcChuteTier(math.max(0, self.HP_Chute), HP_CHUTE)
	if tier ~= self.ChuteTier then
		self.ChuteTier = tier
		BroadcastChuteTier(self, tier)
	end

	if self.HP_Chute <= 0 then self:DestroyChute() end
end

function ENT:TakePalletHit(dmg)
	if IsImmune(self) or self.PalletDead then return end
	self.HP_Pallet = self.HP_Pallet - dmg
	self:SetNWInt("HP_Pallet", math.max(0, self.HP_Pallet))

	local tier = CalcPalletTier(math.max(0, self.HP_Pallet), HP_PALLET)
	if tier ~= self.PalletTier then
		self.PalletTier = tier
		BroadcastPalletTier(self, tier)
	end

	if self.HP_Pallet <= 0 then self:DestroyPallet() end
end

function ENT:DestroyChute()
	if self.ChuteDead then return end
	self.ChuteDead = true

	BroadcastChuteTier(self, 0)

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

	local pos = self:GetPos()
	sound.Play("physics/metal/metal_canister_impact_hard" .. math.random(1,3) .. ".wav", pos, 85, math.random(80, 100), 1.0)
end

function ENT:DestroyPallet()
	if self.PalletDead then return end
	self.PalletDead  = true
	self.Detached    = true
	self.MunitionEnts = self.MunitionEnts or {}

	BroadcastPalletTier(self, 0)
	BroadcastChuteTier(self, 0)

	local pos = self:GetPos()
	local ang = self:GetAngles()

	util.BlastDamage(self, SafeAttacker(self), pos, PALLET_EXPLODE_RADIUS, PALLET_EXPLODE_DAMAGE)
	FireExplosionEffect(pos, 2.2)
	sound.Play("ambient/explosions/explode_" .. math.random(1, 5) .. ".wav", pos, 140, math.random(88, 102), 1.0)

	for _, field in ipairs({"ChuteHitbox", "PalletHitbox", "PalletVisual"}) do
		if IsValid(self[field]) then
			self[field]:SetParent(nil)
			self[field]:Remove()
			self[field] = nil
		end
	end

	local chutePos = pos + CHUTE_ABOVE_PALETTE
	if IsValid(self.ChuteEnt) then
		chutePos = self.ChuteEnt:GetPos()
		self.ChuteEnt:SetParent(nil)
		self.ChuteEnt:Remove()
		self.ChuteEnt = nil
	end

	if not self.ChuteDead then
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
			timer.Simple(DEBRIS_LIFETIME, function()
				if IsValid(chuteClone) then chuteClone:Remove() end
			end)
		end
	end

	for i = 1, 4 do
		local mun        = self.MunitionEnts[i]
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
				mPhys:AddAngleVelocity(Vector(math.Rand(-80,80), math.Rand(-80,80), math.Rand(-50,50)))
			end
		end)
	end

	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	local palPhys = self:GetPhysicsObject()
	if IsValid(palPhys) then
		palPhys:EnableGravity(true)
		palPhys:SetDamping(0, 0)
		palPhys:Wake()
		palPhys:SetVelocity(Vector(math.Rand(-80,80), math.Rand(-80,80), math.Rand(-40,20)))
		palPhys:AddAngleVelocity(Vector(math.Rand(-50,50), math.Rand(-50,50), math.Rand(-30,30)))
	end

	timer.Simple(DEBRIS_LIFETIME + (4 * RELEASE_STEP_DELAY), function()
		for i = 1, 4 do
			if IsValid(self.MunitionEnts[i]) then self.MunitionEnts[i]:Remove() end
		end
		if IsValid(self) then self:Remove() end
	end)
end

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

	if not self.Detached then
		if missile:GetNWBool("EngineOn", false) then
			if not self.PalletDead then
				self:Detach()
			end
			self:NextThink(CurTime() + THINK_DT)
			return true
		end

		local vz = self.PhysVz or -10
		if not self.ChuteDead then
			local dragDelta = CHUTE_DRAG_K * vz * vz * THINK_DT
			if vz >= 0 then dragDelta = -dragDelta end
			vz = math.max(vz + dragDelta, CHUTE_TERMINAL_VEL)
		else
			vz = math.max(vz - 600 * THINK_DT, FREEFALL_TERMINAL_VEL)
		end
		self.PhysVz = vz

		local targetXY = missile:GetPos() + PALETTE_ABOVE_MISSILE
		local curPos   = self:GetPos()
		local vx = (targetXY.x - curPos.x) * 12
		local vy = (targetXY.y - curPos.y) * 12

		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			if phys:IsAsleep() then phys:Wake() end
			phys:SetVelocity(Vector(vx, vy, vz))
		else
			self:SetPos(Vector(targetXY.x, targetXY.y, curPos.z + vz * THINK_DT))
		end

		if not self.ChuteDead then
			self.SwayClock = (self.SwayClock or 0) + SWAY_RATE * THINK_DT
			local pitch    = math.sin(self.SwayClock) * SWAY_AMP
			local yaw      = missile:GetAngles().y
			self:SetAngles(Angle(pitch, yaw, 0))
		end
	end

	if self.ChuteDead and not self.Detached then
		local pos = self:GetPos()
		local tr  = util.TraceLine({
			start  = pos,
			endpos = pos + Vector(0, 0, -(GROUND_DETONATE_DIST + 10)),
			filter = function(e)
				if e == self then return false end
				local mEnts = self.MunitionEnts or {}
				for i = 1, 4 do
					if e == mEnts[i] then return false end
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
			util.BlastDamage(self, SafeAttacker(self), capturedPos, GBU_EXPLODE_RADIUS, GBU_EXPLODE_DAMAGE)
			FireExplosionEffect(capturedPos, 2.0)
			sound.Play("ambient/explosions/explode_" .. math.random(1, 5) .. ".wav", capturedPos, 140, math.random(88, 104), 1.0)
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

function ENT:Detach()
	if self.Detached then return end
	self.Detached     = true
	self.MunitionEnts = self.MunitionEnts or {}

	for _, field in ipairs({"ChuteHitbox", "PalletHitbox"}) do
		if IsValid(self[field]) then
			self[field]:SetParent(nil)
			self[field]:Remove()
			self[field] = nil
		end
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
		local mun        = self.MunitionEnts[i]
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

function ENT:OnTakeDamage( dmginfo )
	if IsImmune( self ) or self.PalletDead then return end
	local dmg = dmginfo:GetDamage()
	if dmg <= 0 then return end

	if not self.ChuteDead then
		self:TakePalletHit( dmg * 0.5 )
		if not self.PalletDead then
			self:TakeChuteHit( dmg * 0.5 )
		end
	else
		self:TakePalletHit( dmg )
	end
end

function ENT:FullRemove()
	self.Detached     = true
	self.PalletDead   = true
	self.MunitionEnts = self.MunitionEnts or {}

	for _, field in ipairs({"PalletVisual", "ChuteEnt", "ChuteHitbox", "PalletHitbox", "ChuteClone"}) do
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
	if self.DamageHookName then
		hook.Remove("EntityTakeDamage", self.DamageHookName)
	end
	self:Remove()
end

function ENT:OnRemove()
	if self.DamageHookName then
		hook.Remove("EntityTakeDamage", self.DamageHookName)
	end
	if self.Detached then return end
	for _, field in ipairs({"PalletVisual", "ChuteEnt", "ChuteHitbox", "PalletHitbox", "ChuteClone"}) do
		if IsValid(self[field]) then
			self[field]:SetParent(nil)
			self[field]:Remove()
		end
	end
	if not self.MunitionEnts then return end
	for i = 1, 4 do
		if IsValid(self.MunitionEnts[i]) then
			self.MunitionEnts[i]:SetParent(nil)
			self.MunitionEnts[i]:Remove()
		end
	end
end
