include("shared.lua")

-- ============================================================
-- Client: smoke trail + ignition sparks + WP burn light + sway
-- ============================================================

local STATE_FALLING  = 0
local STATE_IGNITING = 1
local STATE_BURNING  = 2
local STATE_DEAD     = 3

local wpState  = {}   -- [entIdx] = state
local wpSway   = {}   -- [entIdx] = {pitch, roll}
local activeDL = {}   -- [entIdx] = DynamicLight handle

local function KillLight(idx)
    if activeDL[idx] then
        activeDL[idx].dietime = 0
        activeDL[idx] = nil
    end
end

-- ============================================================
-- Net: state transitions
-- ============================================================
net.Receive("bombin_wp_state", function()
    local idx   = net.ReadUInt(16)
    local state = net.ReadUInt(2)
    wpState[idx] = state

    if state == STATE_DEAD then
        KillLight(idx)
        wpState[idx] = nil
        wpSway[idx]  = nil
        return
    end

    local ent = ents.GetByIndex(idx)
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
-- Net: sway angles from server (8 Hz)
-- ============================================================
net.Receive("bombin_wp_sway", function()
    local idx   = net.ReadUInt(16)
    local pitch = net.ReadInt(16) / 10
    local roll  = net.ReadInt(16) / 10
    wpSway[idx] = { pitch = pitch, roll = roll }
    -- Apply immediately to the chute child if already cached
    local ent = ents.GetByIndex(idx)
    if IsValid(ent) and IsValid(ent.WP_ChuteEntCL) then
        ent.WP_ChuteEntCL:SetLocalAngles(Angle(pitch, 0, roll))
    end
end)

-- ============================================================
-- Global Think: keep DynamicLight alive + flicker while burning
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
    wpSway[self:EntIndex()]  = { pitch = 0, roll = 0 }
    self.WP_LastSmoke  = 0
    self.WP_LastFire   = 0
    self.WP_LastSpark  = 0
    self.WP_ChuteEntCL = nil
end

function ENT:Draw()
    self:DrawModel()
end

function ENT:Think()
    local idx   = self:EntIndex()
    local state = wpState[idx] or STATE_FALLING
    if state == STATE_DEAD then return end

    local pos = self:GetPos()
    local t   = CurTime()

    -- Cache reference to chute child entity
    if not IsValid(self.WP_ChuteEntCL) then
        for _, child in ipairs(self:GetChildren()) do
            if IsValid(child) then
                self.WP_ChuteEntCL = child
                break
            end
        end
    end

    -- Apply latest sway to chute child
    local sw = wpSway[idx]
    if sw and IsValid(self.WP_ChuteEntCL) then
        self.WP_ChuteEntCL:SetLocalAngles(Angle(sw.pitch, 0, sw.roll))
    end

    -- ---- Constant white smoke trail ----
    if t - self.WP_LastSmoke > 0.08 then
        self.WP_LastSmoke = t
        local ed = EffectData()
        ed:SetOrigin(pos + Vector(math.Rand(-3,3), math.Rand(-3,3), math.Rand(2,10)))
        ed:SetScale(0.65)
        ed:SetMagnitude(0.45)
        util.Effect("cball_bounce", ed)
    end

    -- ---- Igniting: client-side spark flash ----
    if state == STATE_IGNITING then
        if t - self.WP_LastSpark > 0.1 then
            self.WP_LastSpark = t
            local ed = EffectData()
            ed:SetOrigin(pos + Vector(math.Rand(-5,5), math.Rand(-5,5), math.Rand(2,12)))
            ed:SetScale(0.5)
            util.Effect("ElectricSpark", ed)
        end
    end

    -- ---- Burning: small proportionate fire puffs ----
    -- MuzzleEffect at scale=0.4, magnitude=0.3 for a hand-canister-sized flame.
    -- Replaces HelicopterMegaBomb which produced an oversized fireball.
    if state == STATE_BURNING then
        if t - self.WP_LastFire > 0.09 then
            self.WP_LastFire = t
            local ed = EffectData()
            ed:SetOrigin(pos + Vector(math.Rand(-4,4), math.Rand(-4,4), math.Rand(3,14)))
            ed:SetNormal(Vector(0,0,1))
            ed:SetScale(0.4)
            ed:SetMagnitude(0.3)
            util.Effect("MuzzleEffect", ed)
        end
    end
end

function ENT:OnRemove()
    local idx = self:EntIndex()
    KillLight(idx)
    wpState[idx] = nil
    wpSway[idx]  = nil
end
