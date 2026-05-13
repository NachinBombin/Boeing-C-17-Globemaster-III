include("shared.lua")

-- ============================================================
-- Client: smoke trail + ignition sparks + WP burn light
-- ============================================================

local STATE_FALLING  = 0
local STATE_IGNITING = 1
local STATE_BURNING  = 2
local STATE_DEAD     = 3

local wpState  = {}   -- [entIdx] = current state
local activeDL = {}   -- [entIdx] = DynamicLight handle

local function KillLight(idx)
    if activeDL[idx] then
        activeDL[idx].dietime = 0
        activeDL[idx] = nil
    end
end

-- ============================================================
-- Net receive: state transitions from server
-- ============================================================
net.Receive("bombin_wp_state", function()
    local idx   = net.ReadUInt(16)
    local state = net.ReadUInt(2)
    local ent   = ents.GetByIndex(idx)

    wpState[idx] = state

    if state == STATE_DEAD then
        KillLight(idx)
        wpState[idx] = nil
        return
    end

    if state == STATE_BURNING then
        if not IsValid(ent) then return end
        local dl = DynamicLight(ent:EntIndex())
        if not dl then return end
        dl.Pos        = ent:GetPos()
        dl.r          = 255
        dl.g          = 248
        dl.b          = 200
        dl.brightness = 12
        dl.Size       = 2200
        dl.Decay      = 0
        dl.dietime    = CurTime() + 0.2
        activeDL[idx] = dl
    else
        KillLight(idx)
    end
end)

-- ============================================================
-- Global Think: keep light alive + flicker
-- ============================================================
hook.Add("Think", "bombin_wp_light_think", function()
    local t = CurTime()
    for idx, dl in pairs(activeDL) do
        local ent = ents.GetByIndex(idx)
        if IsValid(ent) and not ent:IsDormant() then
            dl.Pos     = ent:GetPos()
            dl.dietime = t + 0.2
            dl.brightness = 11
                + math.sin(t * 1.8 + idx * 0.9) * 1.5
                + math.sin(t * 4.1 + idx * 1.7) * 0.7
            dl.Size = 2000 + math.sin(t * 0.7 + idx) * 250
        else
            KillLight(idx)
        end
    end
end)

-- ============================================================
-- ENT hooks
-- ============================================================
function ENT:Initialize()
    self:SetRenderMode(RENDERMODE_NORMAL)
    wpState[self:EntIndex()] = STATE_FALLING
    -- Reset per-entity timers
    self.WP_LastSmoke = 0
    self.WP_LastFire  = 0
    self.WP_LastSpark = 0
end

function ENT:Draw()
    self:DrawModel()
end

-- Client Think: runs every frame for each visible entity.
-- Drives the constant white smoke trail and per-state fire/spark effects.
-- All util.Effect calls here omit the broadcast flags (no args = local only).
function ENT:Think()
    local idx   = self:EntIndex()
    local state = wpState[idx] or STATE_FALLING
    if state == STATE_DEAD then return end

    local pos = self:GetPos()
    local t   = CurTime()

    -- ---- Constant white smoke trail (all states while alive) ----
    -- Rate: ~12 puffs/sec. "cball_bounce" emits a reliable white smoke cloud.
    if t - (self.WP_LastSmoke or 0) > 0.08 then
        self.WP_LastSmoke = t
        local ed = EffectData()
        ed:SetOrigin(pos + Vector(math.Rand(-3,3), math.Rand(-3,3), math.Rand(2,10)))
        ed:SetScale(0.7)
        ed:SetMagnitude(0.5)
        util.Effect("cball_bounce", ed)
    end

    -- ---- Igniting: extra client-side spark flash ----
    if state == STATE_IGNITING then
        if t - (self.WP_LastSpark or 0) > 0.1 then
            self.WP_LastSpark = t
            local ed = EffectData()
            ed:SetOrigin(pos + Vector(math.Rand(-5,5), math.Rand(-5,5), math.Rand(2,12)))
            ed:SetScale(0.5)
            util.Effect("ElectricSpark", ed)
        end
    end

    -- ---- Burning: fire puffs around the canister ----
    if state == STATE_BURNING then
        if t - (self.WP_LastFire or 0) > 0.07 then
            self.WP_LastFire = t
            local ed = EffectData()
            ed:SetOrigin(pos + Vector(math.Rand(-6,6), math.Rand(-6,6), math.Rand(4,16)))
            ed:SetScale(1.0)
            util.Effect("HelicopterMegaBomb", ed)
        end
    end
end

function ENT:OnRemove()
    local idx = self:EntIndex()
    KillLight(idx)
    wpState[idx] = nil
end
