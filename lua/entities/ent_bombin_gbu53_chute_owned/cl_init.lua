include("shared.lua")

-- ============================================================
-- CLIENT  --  ent_bombin_gbu53_chute_owned
-- Pallet tier (0-3) -> fire particles on the root entity.
-- Chute  tier (0-2) -> smoke/fire particles on chute child
--                      (offset 90u above root via CP1).
--
-- FIX: Use PATTACH_ABSORIGIN_FOLLOW (not PATTACH_POINT_FOLLOW).
--   PATTACH_POINT_FOLLOW requires named model attachment points;
--   the root uses cube1x1x1.mdl which has none, causing silent NULL.
--   PATTACH_ABSORIGIN_FOLLOW tracks the entity origin automatically.
--   The local offset is fed to the particle via SetControlPoint(1, ...)
--   so it emits at the correct world position as the entity moves.
-- ============================================================

local PALLET_TIER_FX = {
	[1] = { name = "fire_small_01b",   offset = Vector(0, 0,  8) },
	[2] = { name = "fire_medium_base", offset = Vector(0, 0, 12) },
	[3] = { name = "burning_gib_01",   offset = Vector(0, 0, 18) },
}

local CHUTE_TIER_FX = {
	[1] = { name = "smoke_small_01b",  offset = Vector(0, 0, 90) },
	[2] = { name = "fire_small_01b",   offset = Vector(0, 0, 90) },
}

local function StopParticle(ps)
	if IsValid(ps) then
		ps:StopEmission()
	end
end

-- ============================================================
-- PALLET FIRE TIER
-- ============================================================
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

	-- PATTACH_ABSORIGIN_FOLLOW: particle tracks ent:GetPos() automatically.
	-- CP0 is set to the entity itself (origin follower).
	-- CP1 is a static local-space offset so the emitter sits above the pallet.
	local ps = CreateParticleSystem(ent, cfg.name, PATTACH_ABSORIGIN_FOLLOW, 0)
	if IsValid(ps) then
		ps:SetControlPointEntity(0, ent)
		ps:SetControlPoint(1, cfg.offset)   -- local offset from entity origin
		ps:SetSortOrigin(ent:GetPos())
		ent.GBU53C_PalletPS = ps
	end
end)

-- ============================================================
-- CHUTE SMOKE / FIRE TIER
-- Root entity index is sent.  The chute visual is parented to root
-- at +90u Z, so we pass that offset via CP1 to the particle system.
-- ============================================================
net.Receive("bombin_gbu53chute_chute_tier", function()
	local entIdx = net.ReadUInt(16)
	local tier   = net.ReadUInt(2)

	local ent = Entity(entIdx)
	if not IsValid(ent) then return end

	StopParticle(ent.GBU53C_ChutePS)
	ent.GBU53C_ChutePS = nil

	if tier == 0 then return end

	local cfg = CHUTE_TIER_FX[tier]
	if not cfg then return end

	-- Prefer to attach directly to the chute child entity if it still exists,
	-- so the particle position is exact even after any root offset drift.
	-- Fall back to root + offset if chute entity is gone.
	local attachEnt    = ent
	local attachOffset = cfg.offset

	if IsValid(ent.GBU53C_ChuteEnt) then
		attachEnt    = ent.GBU53C_ChuteEnt
		attachOffset = Vector(0, 0, 0)
	end

	local ps = CreateParticleSystem(attachEnt, cfg.name, PATTACH_ABSORIGIN_FOLLOW, 0)
	if IsValid(ps) then
		ps:SetControlPointEntity(0, attachEnt)
		ps:SetControlPoint(1, attachOffset)
		ps:SetSortOrigin(attachEnt:GetPos())
		ent.GBU53C_ChutePS = ps
	end
end)

function ENT:Initialize()
	self.GBU53C_PalletPS  = nil
	self.GBU53C_ChutePS   = nil
	self.GBU53C_ChuteEnt  = nil   -- populated via NW when chute child spawns
end

function ENT:Draw()
	self:DrawModel()
end

function ENT:Think()
	-- Cache a reference to the chute child so the net handler can
	-- attach particles to it directly. Walk children each tick only
	-- if we haven't found it yet (one-time discovery).
	if not IsValid(self.GBU53C_ChuteEnt) then
		for _, child in ipairs(self:GetChildren()) do
			if IsValid(child) and child:GetModel() and
			   string.find(child:GetModel(), "parachutez", 1, true) then
				self.GBU53C_ChuteEnt = child
				break
			end
		end
	end
	self:NextThink(CurTime() + 0.5)
	return true
end

function ENT:OnRemove()
	StopParticle(self.GBU53C_PalletPS)
	StopParticle(self.GBU53C_ChutePS)
	self.GBU53C_PalletPS = nil
	self.GBU53C_ChutePS  = nil
	self.GBU53C_ChuteEnt = nil
end
