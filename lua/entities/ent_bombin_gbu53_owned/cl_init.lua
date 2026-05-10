include("shared.lua")
include("cl_trailsystem.lua")

-- ============================================================
-- CLIENT  —  ent_bombin_gbu53_owned
-- ============================================================

local ENGINE_LOOP_SOUND = "ambient/wind/wind_atlas_loop1.wav"

-- Vanilla GMod particle systems — guaranteed to exist without addons.
local TIER_PARTICLES = {
	[1] = { name = "fire_small_01b",  offset = Vector(0, -30,  5) },
	[2] = { name = "fire_medium_base", offset = Vector(0, -30, 10) },
	[3] = { name = "burning_gib_01",  offset = Vector(0, -20, 15) },
}

net.Receive("bombin_gbu53owned_damage_tier", function()
	local entIdx = net.ReadUInt(16)
	local tier   = net.ReadUInt(2)

	local ent = Entity(entIdx)
	if not IsValid(ent) then return end

	local prev = ent.GBU53O_ActiveParticle
	if IsValid(prev) then prev:StopEmission() end
	ent.GBU53O_ActiveParticle = nil

	if tier == 0 then return end

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
