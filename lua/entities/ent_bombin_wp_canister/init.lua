AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- CONFIGURATION
-- ============================================================
local WP_MODEL       = "models/props_junk/PropaneCanister001a.mdl"
local WP_CHUTE_MODEL = "models/v92/parachutez/flying.mdl"
local WP_CHUTE_SCALE = 1.4

local WP_IGNITE_DELAY = 4.5
local WP_IGNITE_DUR   = 2.5
local WP_BURN_LIFE    = 45

-- Drag: we target terminal velocity ~70 u/s downward.
-- PhysicsUpdate applies an upward impulse each tick to clamp velocity.
-- Using impulse approach (not raw force * mass) avoids the overshoot CTD.
local WP_TERM_VEL     = -70   -- negative = downward

local WP_CHUTE_OFFSET = Vector(0, 0, 90)
local THINK_DT        = 0.1

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
-- NOTE: never call self:Spawn()/self:Activate() inside Initialize().
-- ============================================================
function ENT:Initialize()
    self:SetModel(WP_MODEL)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:EnableGravity(true)
        phys:SetMass(40)
        phys:SetDamping(0.1, 0.4)
        phys:SetVelocity(Vector(math.Rand(-20,20), math.Rand(-20,20), -60))
    end

    self.WP_State     = STATE_FALLING
    self.WP_IgniteAt  = CurTime() + WP_IGNITE_DELAY
    self.WP_IgniteEnd = self.WP_IgniteAt + WP_IGNITE_DUR
    self.WP_BurnUntil = 0
    self.WP_SoundTime = 0
    self.WP_SparkNext = 0
    self.WP_ChuteEnt  = nil

    timer.Simple(0, function()
        if not IsValid(self) then return end
        local chute = ents.Create("prop_physics")
        if not IsValid(chute) then return end
        chute:SetModel(WP_CHUTE_MODEL)
        chute:SetPos(self:GetPos() + WP_CHUTE_OFFSET)
        chute:SetAngles(self:GetAngles())
        chute:Spawn()
        chute:Activate()
        chute:SetModelScale(WP_CHUTE_SCALE, 0)
        chute:SetMoveType(MOVETYPE_NONE)
        chute:SetSolid(SOLID_NONE)
        chute:SetCollisionGroup(COLLISION_GROUP_NONE)
        chute:DrawShadow(false)
        chute:SetParent(self)
        chute:SetLocalPos(WP_CHUTE_OFFSET)
        chute:SetLocalAngles(Angle(0, 0, 0))
        self.WP_ChuteEnt = chute
    end)

    BroadcastState(self, STATE_FALLING)
    self:NextThink(CurTime() + THINK_DT)
end

-- ============================================================
-- PHYSICS: parachute drag via velocity clamping impulse
-- PhysicsUpdate fires ~66 Hz. We apply a corrective upward
-- impulse only when falling faster than terminal velocity.
-- Impulse = mass * delta_v, so it's frame-rate independent.
-- ============================================================
function ENT:PhysicsUpdate(phys)
    if self.WP_State == STATE_DEAD then return end
    local vel = phys:GetVelocity()

    if vel.z < WP_TERM_VEL then
        -- Apply impulse to bring vz back toward terminal this tick
        local dv   = WP_TERM_VEL - vel.z   -- positive upward correction needed
        local mass = phys:GetMass()
        -- Scale impulse: only apply a fraction per tick so deceleration is gradual
        local impulse = mass * dv * 0.08
        phys:ApplyForceCenter(Vector(0, 0, impulse))
    end

    -- Gentle horizontal damping (pendulum sway settling)
    phys:ApplyForceCenter(Vector(-vel.x * 0.5, -vel.y * 0.5, 0))
end

-- ============================================================
-- THINK: state machine (10 Hz)
-- ============================================================
function ENT:Think()
    if self.WP_State == STATE_DEAD then return end
    local ct  = CurTime()
    local pos = self:GetPos()

    if self.WP_State == STATE_FALLING then
        if ct >= self.WP_IgniteAt then
            self.WP_State     = STATE_IGNITING
            self.WP_BurnUntil = self.WP_IgniteEnd + WP_BURN_LIFE
            self.WP_SparkNext = ct
            BroadcastState(self, STATE_IGNITING)
            sound.Play("ambient/fire/ignite.wav", pos, 85, 100, 1.0)
        end

    elseif self.WP_State == STATE_IGNITING then
        if ct >= self.WP_SparkNext then
            self.WP_SparkNext = ct + 0.15
            local ed = EffectData()
            ed:SetOrigin(pos + Vector(math.Rand(-6,6), math.Rand(-6,6), math.Rand(2,14)))
            ed:SetScale(1)
            util.Effect("ElectricSpark", ed, true, true)
        end
        if ct >= self.WP_IgniteEnd then
            self.WP_State = STATE_BURNING
            BroadcastState(self, STATE_BURNING)
            local fed = EffectData()
            fed:SetOrigin(pos)
            fed:SetScale(2)
            util.Effect("Explosion", fed, true, true)
            sound.Play("ambient/fire/fire_large_loop1.wav", pos, 95, 80, 1.0)
            self.WP_SoundTime = ct + 4.5
        end

    elseif self.WP_State == STATE_BURNING then
        if ct >= self.WP_SoundTime then
            self.WP_SoundTime = ct + 4.5
            sound.Play("ambient/fire/fire_large_loop1.wav", pos, 80, 82, 0.85)
        end
        if ct >= self.WP_BurnUntil then
            self:WP_Die()
            return
        end
    end

    self:NextThink(ct + THINK_DT)
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
    timer.Simple(3.0, function()
        if IsValid(self) then self:Remove() end
    end)
end

-- ============================================================
-- GROUND IMPACT
-- ============================================================
function ENT:PhysicsCollide(data, physObj)
    if self.WP_State == STATE_DEAD then return end
    if data.Speed < 60 then return end
    if IsValid(self.WP_ChuteEnt) then
        local chute = self.WP_ChuteEnt
        self.WP_ChuteEnt = nil
        chute:SetParent(nil)
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
