include("shared.lua")
include("cl_trailsystem.lua")

-- ============================================================
-- CLIENT  —  ent_bombin_gbu53_owned
-- Identical to ent_bombin_gbu53 client, namespaced for the
-- Owned variant so trails / sounds don't cross-pollinate.
-- ============================================================

local ENGINE_LOOP_SOUND = "ambient/wind/wind_atlas_loop1.wav"

local TIER_PARTICLES = {
	[1] = { name = "fire_medium_01",  offset = Vector(0, -30,  5), scale = 0.6 },
	[2] = { name = "fire_large_01",   offset = Vector(0, -30, 10), scale = 1.0 },
	[3] = { name = "fire_large_02",   offset = Vector(0, -20, 15), scale = 1.4 },
}

net.Receive("bombin_gbu53owned_damage_tier", function()
	local entIdx = net.ReadUInt(16)
	local tier   = net.ReadUInt(2)

	local ent = Entity(entIdx)
	if not IsValid(ent) then return end

	local prev = ent.GBU53O_ActiveParticle
	if IsValid(prev) then prev:StopEmission() end

	if tier == 0 then
		ent.GBU53O_ActiveParticle = nil
		return
	end

	local cfg = TIER_PARTICLES[tier]
	if not cfg then return end

	local ps = CreateParticleSystem(ent, cfg.name, PATTACH_POINT_FOLLOW, 0)
	if IsValid(ps) then
		ps:SetControlPoint(0, ent:GetPos() + cfg.offset)
		ps:SetSortOrigin(ent:GetPos())
		ent.GBU53O_ActiveParticle = ps
	end
end)

function ENT:Initialize()
	GBU53OwnedTrail_Register(self)

	-- Engine sound only starts after EngineOn NWBool is set
	self.GBU53O_EngineSound   = nil
	self.GBU53O_EnginePlaying = false
end

function ENT:Think()
	local engineOn = self:GetNWBool("EngineOn", false)

	if engineOn and not self.GBU53O_EnginePlaying then
		self.GBU53O_EngineSound = CreateSound(self, ENGINE_LOOP_SOUND)
		if self.GBU53O_EngineSound then
			self.GBU53O_EngineSound:SetSoundLevel(80)
			self.GBU53O_EngineSound:ChangePitch(92, 0)
			self.GBU53O_EngineSound:ChangeVolume(0.90, 0)
			self.GBU53O_EngineSound:Play()
		end
		self.GBU53O_EnginePlaying = true
	end

	if self.GBU53O_EngineSound and not self.GBU53O_EngineSound:IsPlaying() and self.GBU53O_EnginePlaying then
		self.GBU53O_EngineSound:Play()
	end
end

function ENT:OnRemove()
	GBU53OwnedTrail_Unregister(self)

	if self.GBU53O_EngineSound then
		self.GBU53O_EngineSound:FadeOut(0.5)
		self.GBU53O_EngineSound = nil
	end

	if IsValid(self.GBU53O_ActiveParticle) then
		self.GBU53O_ActiveParticle:StopEmission()
		self.GBU53O_ActiveParticle = nil
	end
end

function ENT:Draw()
	self:DrawModel()
end
