include("shared.lua")

-- ============================================================
-- Client: dynamic light + particle system per state
-- ============================================================
local activeParticles = {}  -- [entIdx] = particle system handle
local activeLights    = {}  -- [entIdx] = dl handle

local STATE_FALLING  = 0
local STATE_IGNITING = 1
local STATE_BURNING  = 2
local STATE_DEAD     = 3

local function StopParticle(idx)
    if activeParticles[idx] then
        pcall(function() activeParticles[idx]:StopEmission() end)
        activeParticles[idx] = nil
    end
end

local function StopLight(idx)
    if activeLights[idx] then
        activeLights[idx].dietime = 0
        activeLights[idx] = nil
    end
end

net.Receive("bombin_wp_state", function()
    local idx   = net.ReadUInt(16)
    local state = net.ReadUInt(2)
    local ent   = ents.GetByIndex(idx)

    StopParticle(idx)
    StopLight(idx)

    if not IsValid(ent) then return end

    if state == STATE_IGNITING then
        local ps = ParticleEffect("fire_small_01b", ent:GetPos(), Angle(0,0,0), ent)
        if ps then activeParticles[idx] = ps end

    elseif state == STATE_BURNING then
        -- Particle: dense white smoke + fire
        local ps = ParticleEffect("fire_medium_base", ent:GetPos(), Angle(0,0,0), ent)
        if ps then activeParticles[idx] = ps end

        -- Sustained dynamic light (warm white-yellow WP illumination)
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            local dl = DynamicLight(ent:EntIndex())
            if not dl then return end
            dl.Pos        = ent:GetPos()
            dl.r          = 255
            dl.g          = 235
            dl.b          = 160
            dl.brightness = 7
            dl.Size       = 1400
            dl.Decay      = 0
            dl.dietime    = CurTime() + 0.15
            activeLights[idx] = dl
        end)

    elseif state == STATE_DEAD then
        -- already cleaned up above
    end
end)

-- Keep burning light alive and flickering
hook.Add("Think", "bombin_wp_lightupdate", function()
    for idx, dl in pairs(activeLights) do
        local ent = ents.GetByIndex(idx)
        if IsValid(ent) and not ent:IsDormant() then
            dl.Pos     = ent:GetPos()
            dl.dietime = CurTime() + 0.15
            local t = CurTime()
            -- WP chemical flicker: slow and irregular
            dl.brightness = 6.5
                + math.sin(t * 2.9 + idx * 1.1) * 0.8
                + math.sin(t * 6.3 + idx * 0.7) * 0.4
        else
            StopLight(idx)
        end
    end
end)

function ENT:Initialize()
    self:SetRenderMode(RENDERMODE_NORMAL)
end

function ENT:Draw()
    self:DrawModel()
end

function ENT:OnRemove()
    local idx = self:EntIndex()
    StopParticle(idx)
    StopLight(idx)
end
