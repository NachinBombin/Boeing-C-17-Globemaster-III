AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- CONFIGURATION
-- ============================================================
local WP_MODEL        = "models/props_junk/PropaneCanister001a.mdl"
-- Placeholder chute disc parented above the canister.
-- Replace with a dedicated parachute model if available.
local WP_CHUTE_MODEL  = "models/props_vehicles/apc_tire.mdl"

local WP_IGNITE_DELAY = 4.5    -- seconds after spawn before ignition sequence
local WP_SPARK_PERIOD = 0.08   -- spark effect interval during ignition phase
local WP_IGNITE_DUR   = 2.5    -- duration of ignition spark phase
local WP_BURN_LIFE    = 45     -- seconds of full WP burn
local WP_DRAG_K       = 0.32   -- drag constant: F = k * v^2 (upward, resists fall)
                               -- terminal velocity ~= sqrt(580/0.32) ~= 42 u/s
local WP_CHUTE_OFFSET = Vector(0, 0, 90)  -- chute prop offset above canister

-- State constants
local STATE_FALLING  = 0
local STATE_IGNITING = 1
local STATE_BURNING  = 2
local STATE_DEAD     = 3

util.AddNetworkString("bombin_wp_state")

local function BroadcastState(ent, state)
    net.Start("bombin_wp_state")
    net.WriteUInt(ent:EntIndex(), 16)
    net.WriteUInt(state, 2)
    net.Broadcast()
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
    self:SetModel(WP_MODEL)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
    self:Spawn()
    self:Activate()

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(true)
        phys:SetMass(80)
        -- Initial kick matching the aircraft's horizontal velocity
        phys:SetVelocity(Vector(math.Rand(-20,20), math.Rand(-20,20), -100))
    end

    self.WP_State    = STATE_FALLING
    self.WP_IgniteAt = CurTime() + WP_IGNITE_DELAY
    self.WP_IgniteEnd = self.WP_IgniteAt + WP_IGNITE_DUR
    self.WP_NextSpark = 0
    self.WP_BurnUntil = 0
    self.WP_SoundTime = 0
    self.WP_ChuteEnt  = nil

    -- Spawn visual chute prop parented to this entity
    timer.Simple(0, function()
        if not IsValid(self) then return end
        local chute = ents.Create("prop_dynamic")
        if not IsValid(chute) then return end
        chute:SetModel(WP_CHUTE_MODEL)
        chute:SetPos(self:GetPos() + WP_CHUTE_OFFSET)
        chute:SetSolid(SOLID_NONE)
        chute:SetMoveType(MOVETYPE_NONE)
        chute:SetCollisionGroup(COLLISION_GROUP_NONE)
        chute:Spawn()
        chute:Activate()
        chute:SetParent(self)
        chute:SetLocalPos(WP_CHUTE_OFFSET)
        chute:SetLocalAngles(Angle(0,0,0))
        self.WP_ChuteEnt = chute
    end)

    BroadcastState(self, STATE_FALLING)
    self:NextThink(CurTime() + 0.05)
end

-- ============================================================
-- PHYSICS: upward drag simulating parachute resistance
-- ============================================================
function ENT:PhysicsUpdate(phys)
    local vel = phys:GetVelocity()

    -- Apply upward drag only against downward motion
    if vel.z < 0 then
        local dragMag = WP_DRAG_K * vel.z * vel.z   -- always positive
        phys:ApplyForceCenter(Vector(0, 0, dragMag * phys:GetMass()))
    end

    -- Gentle horizontal damping (pendulum settling)
    phys:ApplyForceCenter(Vector(-vel.x * 0.06, -vel.y * 0.06, 0))
end

-- ============================================================
-- THINK: state machine
-- ============================================================
function ENT:Think()
    local ct = CurTime()

    -- ---- FALLING: wait for ignition timer ----
    if self.WP_State == STATE_FALLING then
        if ct >= self.WP_IgniteAt then
            self.WP_State     = STATE_IGNITING
            self.WP_BurnUntil = self.WP_IgniteEnd + WP_BURN_LIFE
            self.WP_NextSpark = ct
            BroadcastState(self, STATE_IGNITING)

            -- Initial ignition pop
            local ed = EffectData()
            ed:SetOrigin(self:GetPos())
            ed:SetMagnitude(1)
            util.Effect("ElectricSpark", ed, true, true)
            sound.Play("ambient/fire/ignite.wav", self:GetPos(), 85, 100, 1.0)
        end

    -- ---- IGNITING: sparks + rising smoke ----
    elseif self.WP_State == STATE_IGNITING then
        -- Spark bursts
        if ct >= self.WP_NextSpark then
            self.WP_NextSpark = ct + WP_SPARK_PERIOD
            local sed = EffectData()
            sed:SetOrigin(self:GetPos() + Vector(math.Rand(-6,6), math.Rand(-6,6), math.Rand(2,14)))
            sed:SetScale(1)
            util.Effect("ElectricSpark", sed, true, true)
        end

        -- Rising smoke column
        local smd = EffectData()
        smd:SetOrigin(self:GetPos() + Vector(math.Rand(-4,4), math.Rand(-4,4), 8))
        smd:SetScale(0.5)
        util.Effect("smokespawner", smd, true, true)

        if ct >= self.WP_IgniteEnd then
            -- Full ignition: transition to BURNING
            self.WP_State = STATE_BURNING
            BroadcastState(self, STATE_BURNING)

            -- Ignition flash
            local fed = EffectData()
            fed:SetOrigin(self:GetPos())
            fed:SetScale(2)
            util.Effect("HelicopterMegaBomb", fed, true, true)
            sound.Play("ambient/fire/fire_large_loop1.wav", self:GetPos(), 95, 80, 1.0)
            self.WP_SoundTime = ct + 4.5
        end

    -- ---- BURNING: continuous fire + smoke, check timeout ----
    elseif self.WP_State == STATE_BURNING then
        -- Fire particles from the canister body
        local fed = EffectData()
        fed:SetOrigin(self:GetPos() + Vector(math.Rand(-5,5), math.Rand(-5,5), 10))
        fed:SetScale(1.3)
        util.Effect("smokespawner", fed, true, true)

        -- Dense white phosphorus smoke column rising above
        local smd = EffectData()
        smd:SetOrigin(self:GetPos() + Vector(math.Rand(-12,12), math.Rand(-12,12), 18))
        smd:SetScale(1.8)
        util.Effect("smokespawner", smd, true, true)

        -- Re-trigger ambient fire sound loop periodically
        if ct >= self.WP_SoundTime then
            self.WP_SoundTime = ct + 4.5
            sound.Play("ambient/fire/fire_large_loop1.wav", self:GetPos(), 80, 82, 0.85)
        end

        if ct >= self.WP_BurnUntil then
            self:WP_Die()
            return
        end

    elseif self.WP_State == STATE_DEAD then
        return
    end

    self:NextThink(ct + 0.05)
    return true
end

-- ============================================================
-- BURN-OUT
-- ============================================================
function ENT:WP_Die()
    if self.WP_State == STATE_DEAD then return end
    self.WP_State = STATE_DEAD
    BroadcastState(self, STATE_DEAD)

    if IsValid(self.WP_ChuteEnt) then
        self.WP_ChuteEnt:Remove()
        self.WP_ChuteEnt = nil
    end

    -- Dying smoke puff
    local ed = EffectData()
    ed:SetOrigin(self:GetPos())
    ed:SetScale(1)
    util.Effect("smokespawner", ed, true, true)

    timer.Simple(3.0, function()
        if IsValid(self) then self:Remove() end
    end)
end

-- ============================================================
-- GROUND IMPACT: detach chute so it stays as litter
-- ============================================================
function ENT:PhysicsCollide(data, physObj)
    if self.WP_State == STATE_DEAD then return end
    if data.Speed < 60 then return end

    if IsValid(self.WP_ChuteEnt) then
        local chute = self.WP_ChuteEnt
        self.WP_ChuteEnt = nil
        chute:SetParent(nil)      -- unparent at world position
        chute:SetMoveType(MOVETYPE_NONE)
        timer.Simple(30, function()
            if IsValid(chute) then chute:Remove() end
        end)
    end
end

function ENT:OnRemove()
    if IsValid(self.WP_ChuteEnt) then
        self.WP_ChuteEnt:Remove()
    end
    BroadcastState(self, STATE_DEAD)
end
