include("shared.lua")

-- ============================================================
-- CLIENT  --  ent_bombin_gbu53_chute_owned
-- Mirrors the single GBU fire-damage visual system:
--   Pallet tier (0-3) -> fire particles on the root entity.
--   Chute  tier (0-2) -> smoke/fire particles on chute child.
-- Both driven by net messages broadcast from server on HP change.
-- ============================================================

-- Pallet fire tiers  (same names as single GBU, anchored to root)
local PALLET_TIER_FX = {
	[1] = { name = "fire_small_01b",   offset = Vector(0, 0,  8) },
	[2] = { name = "fire_medium_base", offset = Vector(0, 0, 12) },
	[3] = { name = "burning_gib_01",   offset = Vector(0, 0, 18) },
}

-- Chute smoke/fire tiers (attached to chute child entity)
local CHUTE_TIER_FX = {
	[1] = { name = "smoke_small_01b",  offset = Vector(0, 0, 0) },
	[2] = { name = "fire_small_01b",   offset = Vector(0, 0, 0) },
}

local function StopParticle(ps)
	if IsValid(ps) then
		ps:StopEmission()
	end
end

-- ---- Pallet tier ----------------------------------------
net.Receive("bombin_gbu53chute_pallet_tier", function()
	local entIdx = net.ReadUInt(16)
	local tier   = net.ReadUInt(2)

	local ent = Entity(entIdx)
	if not IsValid(ent) then return end

	StopParticle(ent.GBU53C_PalletPS)
	ent.GBU53C_PalletPS = nil

	if tier == 0 then return end

	local cfg = PALLET_TIER_FX[tier]
	if not cfg then return end

	local ps = CreateParticleSystem(ent, cfg.name, PATTACH_POINT_FOLLOW, 0)
	if IsValid(ps) then
		ps:SetControlPoint(0, ent:GetPos() + cfg.offset)
		ps:SetSortOrigin(ent:GetPos())
		ent.GBU53C_PalletPS = ps
	end
end)

-- ---- Chute tier -----------------------------------------
net.Receive("bombin_gbu53chute_chute_tier", function()
	local entIdx  = net.ReadUInt(16)
	local tier    = net.ReadUInt(2)

	-- The net message carries the ROOT entity index.
	-- We drive the particle on the root too (chute is parented,
	-- so world-position follows automatically via offset).
	local ent = Entity(entIdx)
	if not IsValid(ent) then return end

	StopParticle(ent.GBU53C_ChutePS)
	ent.GBU53C_ChutePS = nil

	if tier == 0 then return end

	local cfg = CHUTE_TIER_FX[tier]
	if not cfg then return end

	-- Offset upward to sit at the chute position (~90u above root).
	local chuteOffset = Vector(0, 0, 90) + cfg.offset
	local ps = CreateParticleSystem(ent, cfg.name, PATTACH_POINT_FOLLOW, 0)
	if IsValid(ps) then
		ps:SetControlPoint(0, ent:GetPos() + chuteOffset)
		ps:SetSortOrigin(ent:GetPos())
		ent.GBU53C_ChutePS = ps
	end
end)

function ENT:Initialize()
	self.GBU53C_PalletPS = nil
	self.GBU53C_ChutePS  = nil
end

function ENT:Draw()
	self:DrawModel()
end

function ENT:OnRemove()
	StopParticle(self.GBU53C_PalletPS)
	StopParticle(self.GBU53C_ChutePS)
	self.GBU53C_PalletPS = nil
	self.GBU53C_ChutePS  = nil
end
