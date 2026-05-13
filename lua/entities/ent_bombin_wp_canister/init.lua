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

-- Target terminal velocity (downward). PhysicsUpdate impulse approach.
local WP_TERM_VEL = -70    -- u/s downward

-- Sway: pendulum-like tilt driven by horizontal velocity.
local WP_SWAY_MAX     = 14     -- max tilt degrees
local WP_SWAY_LERP    = 0.04   -- lerp factor per sway tick
local WP_SWAY_OSC_AMP = 6      -- oscillation amplitude degrees
local WP_SWAY_OSC_HZ  = 0.35   -- oscillation frequency Hz

local WP_CHUTE_OFFSET = Vector(0, 0, 90)
local THINK_DT        = 0.1

local STATE_FALLING  = 0
local STATE_IGNITING = 1
local STATE_BURNING  = 2
local STATE_DEAD     = 3

util.AddNetworkString("bombin_wp_state")
util.AddNetworkString("bombin_wp_sway")

local function BroadcastState(ent, state)
    net.Start("bombin_wp_state")
        net.WriteUInt(ent:EntIndex(), 16)
        net.WriteUInt(state, 2)
    net.Broadcast()
end

local function BroadcastSway(ent, pitch, roll)
    net.Start("bombin_wp_sway")
        net.WriteUInt(ent:EntIndex(), 16)
        net.WriteInt(math.Round(pitch * 10), 16)
        net.WriteInt(math.Round(roll  * 10), 16)
    net.Broadcast()
end

-- ============================================================
-- INITIALIZE
-- DropVel is optionally set by spawner before Spawn() is called.
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
        phys:SetDamping(0.05, 0.3)
        local initVel = self.DropVel or Vector(0, 0, -60)
        phys:SetVelocity(initVel)
    end

    self.WP_State     = STATE_FALLING
    self.WP_IgniteAt  = CurTime() + WP_IGNITE_DELAY
    self.WP_IgniteEnd = self.WP_IgniteAt + WP_IGNITE_DUR
    self.WP_BurnUntil = 0
    self.WP_SoundTime = 0
    self.WP_SparkNext = 0
    self.WP_ChuteEnt  = nil
    self.WP_SwayPitch = 0
    self.WP_SwayRoll  = 0
    self.WP_SwayNext  = 0
    self.WP_SwayT0    = CurTime()

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
-- PHYSICS: drag + horizontal damping
-- Impulse approach: only damps vertical beyond terminal.
-- Horizontal decays naturally so forward drift lasts ~8s.
-- ============================================================
function ENT:PhysicsUpdate(phys)
    if self.WP_State == STATE_DEAD then return end
    local vel = phys:GetVelocity()

    -- Vertical: fractional impulse toward terminal
    if vel.z < WP_TERM_VEL then
        local dv      = WP_TERM_VEL - vel.z
        local impulse = phys:GetMass() * dv * 0.08
        phys:ApplyForceCenter(Vector(0, 0, impulse))
    end

    -- Horizontal: gentle air resistance (~220 u/s decays to <30 in ~8s)
    phys:ApplyForceCenter(Vector(-vel.x * 0.35, -vel.y * 0.35, 0))
end

-- ============================================================
-- THINK: state machine + sway (10 Hz)
-- ============================================================
function ENT:Think()
    if self.WP_State == STATE_DEAD then return end
    local ct  = CurTime()
    local pos = self:GetPos()

    -- Sway at 8 Hz
    if ct >= self.WP_SwayNext then
        self.WP_SwayNext = ct + 0.12
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            local vel    = phys:GetVelocity()
            local hspeed = math.sqrt(vel.x*vel.x + vel.y*vel.y)
            local tiltMag = math.min(hspeed / 80, 1) * WP_SWAY_MAX
            local hdir    = (hspeed > 5) and math.atan2(vel.y, vel.x) or 0
            local targetPitch = -tiltMag * math.cos(hdir)
            local targetRoll  = -tiltMag * math.sin(hdir)
            -- Pendulum oscillation, strongest when near-vertical (slow)
            local osc      = WP_SWAY_OSC_AMP * math.sin((ct - self.WP_SwayT0) * 2 * math.pi * WP_SWAY_OSC_HZ)
            local oscDecay = math.max(0, 1 - hspeed / 120)
            targetPitch = targetPitch + osc * oscDecay
            self.WP_SwayPitch = Lerp(WP_SWAY_LERP, self.WP_SwayPitch, targetPitch)
            self.WP_SwayRoll  = Lerp(WP_SWAY_LERP, self.WP_SwayRoll,  targetRoll)
            if IsValid(self.WP_ChuteEnt) then
                self.WP_ChuteEnt:SetLocalAngles(Angle(self.WP_SwayPitch, 0, self.WP_SwayRoll))
            end
            BroadcastSway(self, self.WP_SwayPitch, self.WP_SwayRoll)
        end
    end

    -- State transitions
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
            fed:SetScale(1)
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
