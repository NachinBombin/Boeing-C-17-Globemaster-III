include("shared.lua")

-- ============================================================
-- Dynamic light table: [entIdx] = dl handle
-- ============================================================
local activeLights = {}

-- ============================================================
-- Net: state change
-- ============================================================
net.Receive("bombin_wp_state", function()
    local idx   = net.ReadUInt(16)
    local state = net.ReadUInt(2)
    local ent   = ents.GetByIndex(idx)

    -- Kill previous light for this entity
    if activeLights[idx] then
        activeLights[idx].dietime = 0
        activeLights[idx] = nil
    end

    if state == 2 then
        -- BURNING: create sustained omnidirectional dynamic light
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            local dl = DynamicLight(ent:EntIndex())
            if not dl then return end
            dl.Pos        = ent:GetPos()
            dl.r          = 255
            dl.g          = 220
            dl.b          = 130
            dl.brightness = 6
            dl.Size       = 1200
            dl.Decay      = 0
            dl.dietime    = CurTime() + 0.1   -- sustained via Think
            activeLights[idx] = dl
        end)
    end
end)

-- ============================================================
-- Per-frame: keep light alive and positioned, with WP flicker
-- ============================================================
hook.Add("Think", "bombin_wp_lightupdate", function()
    for idx, dl in pairs(activeLights) do
        local ent = ents.GetByIndex(idx)
        if IsValid(ent) and not ent:IsDormant() then
            dl.Pos        = ent:GetPos()
            dl.dietime    = CurTime() + 0.1
            -- Chemical burn flicker: slow, irregular brightness variation
            local t = CurTime()
            dl.brightness = 5.5 + math.sin(t * 3.7 + idx * 0.9) * 0.7
                                + math.sin(t * 7.1 + idx * 1.3) * 0.3
        else
            dl.dietime = 0
            activeLights[idx] = nil
        end
    end
end)

-- ============================================================
-- ENT hooks
-- ============================================================
function ENT:Initialize()
    self:SetRenderMode(RENDERMODE_NORMAL)
end

function ENT:Draw()
    self:DrawModel()
end

function ENT:OnRemove()
    local idx = self:EntIndex()
    if activeLights[idx] then
        activeLights[idx].dietime = 0
        activeLights[idx] = nil
    end
end
