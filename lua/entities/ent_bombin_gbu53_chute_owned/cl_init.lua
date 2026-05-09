include("shared.lua")

-- ============================================================
-- CLIENT  —  ent_bombin_gbu53_chute_owned
-- All geometry is server-side (SetParent handles replication).
-- Nothing special needed here beyond basic draw.
-- ============================================================

function ENT:Initialize()
end

function ENT:Draw()
	self:DrawModel()
end

function ENT:OnRemove()
end
