-- ============================================================
-- ent_bombin_pallet_staged  --  SERVER
--
-- Lifecycle:
--   1. Initialize()  - SetParent to plane, SetLocalPos to staging
--                      position inside cargo bay.  Spawns children.
--   2. SlideToExit() - Called by C-17 when cargo door is fully open.
--                      Lerps SetLocalPos aft along LOCAL +Y to the
--                      ramp-lip exit position.
--   3. Release()     - Fires when slide completes.  Unparents
--                      everything, seeds aircraft velocity, then
--                      enables physics.  Arming is deferred 0.3s
--                      so bombs clear the fuselage before fusing.
--
-- AXIS NOTE:
--   The C-17 entity uses MODEL_YAW_OFFSET = -90, which means the
--   entity's local +X points 90 deg LEFT of the flight direction.
--   Entity local +Y  = flight-forward (nose direction).
--   Entity local -Y  = aft (tail / cargo ramp direction).
--   Entity local -Z  = down through the belly.
--   All staging vectors use this convention.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- CONSTANTS
-- ============================================================
local PALLET_MODEL  = "models/props/de_prodigy/wood_pallet_01.mdl"
local CHUTE_MODEL   = "models/v92/parachutez/flying.mdl"
local CHUTE_SCALE   = 2.2

-- Duration (seconds) for the pallet to slide from rest to exit.
local SLIDE_DURATION = 2.4

-- LOCAL SPACE positions on the C-17 entity (scale = 1.8 model).
-- +Y  = nose/forward   -Y = tail/aft   -Z = belly-down
--
-- Interior rest: on the cargo floor, aft of CG.
local PALLET_STAGE_LOCAL = Vector(0, -160, -55)
-- Cargo-ramp lip: where the pallet tips off and falls clear.
local PALLET_EXIT_LOCAL  = Vector(0, -420, -68)
-- Offset of chute visual above the pallet (local to pallet).
local CHUTE_LOCAL_ABOVE  = Vector(0, 0, 110)

local CG_STAGED  = COLLISION_GROUP_NONE
local CG_RELEASE = COLLISION_GROUP_DEBRIS_TRIGGER

-- Seconds after release before arming dumb bombs.
-- Gives them time to fly clear of the fuselage.
local ARM_DELAY    = 0.35
local DEBRIS_LIFE  = 22

-- Scatter applied to released physics objects (world units/s).
local SCATTER_H = 60
local SCATTER_V = 25

-- Stagger between cosmetic prop physics enables.
local COSMETIC_STAGGER = 0.15

-- ============================================================
-- WEAPON TYPE CONFIGS
-- ============================================================
local WEAPON_CONFIGS = {
    gbu53 = {
        munitionClass   = "ent_bombin_gbu53_owned",
        munitionCount   = 1,
        cosmetic        = true,
        cosmeticCount   = 4,
        cosmeticModel   = "models/sw/usa/bombs/guided/gbu53.mdl",
        cosmeticScale   = 1.0,
        -- Local offsets relative to pallet (pallet-local space, not plane-local).
        cosmeticOffsets = {
            Vector( 18,  30, 8),
            Vector(-18,  30, 8),
            Vector( 18, -30, 8),
            Vector(-18, -30, 8),
        },
        hasChute      = true,
        smartMunition = true,   -- runs its own Think(); don't give physics on release
    },
    jassm = {
        munitionClass = "ent_bombin_jassm_owned",
        munitionCount = 1,
        cosmetic      = false,
        hasChute      = true,
        chuteClass    = "ent_bombin_jassm_chute_owned",
        smartMunition = true,
    },
    heavy = {
        munitionClass = nil,    -- bomb attached externally via AttachBombToPallet
        munitionCount = 0,
        cosmetic      = false,
        hasChute      = false,
        smartMunition = false,
    },
    retarded = {
        munitionClass = nil,
        munitionCount = 0,
        cosmetic      = false,
        hasChute      = false,
        smartMunition = false,
    },
}

-- ============================================================
-- HELPERS
-- ============================================================
local function SafeRemove(e)
    if IsValid(e) then e:Remove() end
end

local function EnablePhysics(ent, baseVel, scH, scV)
    if not IsValid(ent) then return end
    ent:SetMoveType(MOVETYPE_VPHYSICS)
    ent:SetSolid(SOLID_VPHYSICS)
    ent:SetCollisionGroup(CG_RELEASE)
    local ph = ent:GetPhysicsObject()
    if IsValid(ph) then
        ph:Wake()
        ph:SetVelocity(Vector(
            baseVel.x + math.Rand(-scH, scH),
            baseVel.y + math.Rand(-scH, scH),
            baseVel.z + math.Rand(-scV, scV)
        ))
        ph:AddAngleVelocity(Vector(
            math.Rand(-50, 50),
            math.Rand(-50, 50),
            math.Rand(-25, 25)
        ))
    end
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
    self.PlaneEnt   = self.PlaneEnt   or nil
    self.WeaponType = self.WeaponType or "heavy"
    self.ExtraData  = self.ExtraData  or {}

    self.Sliding      = false
    self.SlideStart   = 0
    self.Released     = false
    self.MunitionEnts = {}
    self.CosmeticEnts = {}
    self.ExternalBomb = nil   -- set by AttachBombToPallet
    self.ChuteEnt     = nil

    self:SetModel(PALLET_MODEL)
    self:SetModelScale(1.0, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(CG_STAGED)
    self:SetRenderMode(RENDERMODE_NORMAL)
    self:SetColor(Color(255, 255, 255, 255))
    self:DrawShadow(true)

    if IsValid(self.PlaneEnt) then
        self:SetParent(self.PlaneEnt)
        self:SetLocalPos(PALLET_STAGE_LOCAL)
        self:SetLocalAngles(Angle(0, 0, 0))
    end

    -- Defer child creation one tick so the parent transform is committed.
    timer.Simple(0, function()
        if not IsValid(self) then return end
        self:SpawnChildren()
    end)
end

-- ============================================================
-- SPAWN CHILDREN
-- ============================================================
function ENT:SpawnChildren()
    if not IsValid(self) then return end
    local cfg = WEAPON_CONFIGS[self.WeaponType]
    if not cfg then return end

    local plane = self.PlaneEnt

    -- Helper: spawn an entity parented to self at a local offset.
    local function SpawnChildAt(class, localOffset, localAng, extraSetup)
        local e = ents.Create(class)
        if not IsValid(e) then return nil end
        -- Place at our current world position first so Spawn() gets a
        -- valid position (some entities read GetPos() in Initialize).
        e:SetPos(self:LocalToWorld(localOffset))
        e:SetAngles(self:LocalToWorldAngles(localAng or Angle(0,0,0)))
        if extraSetup then extraSetup(e) end
        e:Spawn()
        e:Activate()
        -- Force staged state AFTER Spawn/Activate (some ents reset these).
        e:SetMoveType(MOVETYPE_NONE)
        e:SetSolid(SOLID_NONE)
        e:SetCollisionGroup(CG_STAGED)
        e:SetParent(self)
        e:SetLocalPos(localOffset)
        e:SetLocalAngles(localAng or Angle(0, 0, 0))
        return e
    end

    -- ── Chute ──────────────────────────────────────────────
    if cfg.hasChute then
        local chuteClass = cfg.chuteClass or "prop_physics"
        local chute = SpawnChildAt(chuteClass, CHUTE_LOCAL_ABOVE, Angle(0,0,0), function(e)
            if not cfg.chuteClass then
                e:SetModel(CHUTE_MODEL)
                e:SetModelScale(CHUTE_SCALE, 0)
            end
        end)
        if IsValid(chute) then
            self.ChuteEnt = chute
        end
    end

    -- ── Primary munition (smart loitering entity) ──────────
    if cfg.munitionClass and cfg.munitionCount > 0 then
        local m = SpawnChildAt(cfg.munitionClass, Vector(0, 0, 0), Angle(0, 0, 0), function(e)
            for k, v in pairs(self.ExtraData) do
                e:SetVar(k, v)
            end
            e.SpawnedFromPlane = true
            e.IsOnPlane        = true
            e.Launcher         = plane
            e:SetOwner(self)
            if IsValid(plane) then e:SetVar("ParentPlane", plane) end
        end)
        if IsValid(m) then
            -- Keep invisible while staged so only the pallet is seen.
            m:SetRenderMode(RENDERMODE_NONE)
            self.MunitionEnts[#self.MunitionEnts + 1] = m
        end
    end

    -- ── Cosmetic visual copies ──────────────────────────────
    if cfg.cosmetic and cfg.cosmeticModel then
        for i = 1, cfg.cosmeticCount do
            local off = cfg.cosmeticOffsets and cfg.cosmeticOffsets[i] or Vector(0,0,0)
            local cp = SpawnChildAt("prop_physics", off, Angle(0, 0, 0), function(e)
                e:SetModel(cfg.cosmeticModel)
                if cfg.cosmeticScale and cfg.cosmeticScale ~= 1.0 then
                    e:SetModelScale(cfg.cosmeticScale, 0)
                end
                e:DrawShadow(false)
            end)
            if IsValid(cp) then
                self.CosmeticEnts[#self.CosmeticEnts + 1] = cp
            end
        end
    end
end

-- ============================================================
-- SLIDE TO EXIT  (called by C-17 after door-open delay)
-- ============================================================
function ENT:SlideToExit(ct)
    if self.Released or self.Sliding then return end
    self.Sliding    = true
    self.SlideStart = ct
    self:EmitSound("physics/wood/wood_box_scrape_rough_loop1.wav", 70, 105, 0.7)
end

-- ============================================================
-- THINK  (drives slide)
-- ============================================================
function ENT:Think()
    if self.Released then return end

    local ct = CurTime()

    if not self.Sliding then
        self:NextThink(ct + 0.05)
        return true
    end

    if not IsValid(self.PlaneEnt) then
        self:Release()
        return
    end

    local t = math.Clamp((ct - self.SlideStart) / SLIDE_DURATION, 0, 1)
    self:SetLocalPos(LerpVector(t, PALLET_STAGE_LOCAL, PALLET_EXIT_LOCAL))

    if t >= 1.0 then
        self:Release()
        return
    end

    self:NextThink(ct + (1 / 66))
    return true
end

-- ============================================================
-- RELEASE
-- ============================================================
function ENT:Release()
    if self.Released then return end
    self.Released = true
    self.Sliding  = false

    local plane   = self.PlaneEnt
    local baseVel = IsValid(plane) and plane:GetVelocity() or Vector(0, 0, 0)

    -- Capture world pos/ang BEFORE unparenting (SetParent(nil) will
    -- teleport to last local-space position if we don't lock it first).
    local worldPos = self:GetPos()
    local worldAng = self:GetAngles()

    -- ── Unparent and physics-enable the pallet ─────────────
    self:SetParent(nil)
    self:SetPos(worldPos)
    self:SetAngles(worldAng)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(CG_RELEASE)
    local palPhys = self:GetPhysicsObject()
    if IsValid(palPhys) then
        palPhys:Wake()
        palPhys:SetVelocity(baseVel + Vector(
            math.Rand(-30, 30),
            math.Rand(-30, 30),
            math.Rand(-20, 5)
        ))
        palPhys:AddAngleVelocity(Vector(
            math.Rand(-20, 20),
            math.Rand(-20, 20),
            math.Rand(-15, 15)
        ))
    end
    -- NoCollide with plane now that both have physics.
    if IsValid(plane) then
        local nc = constraint.NoCollide(self, plane, 0, 0)
        timer.Simple(2.0, function() if IsValid(nc) then nc:Remove() end end)
    end

    -- ── Release chute ───────────────────────────────────────
    if IsValid(self.ChuteEnt) then
        local chute    = self.ChuteEnt
        local chutePos = chute:GetPos()
        local chuteAng = chute:GetAngles()
        chute:SetParent(nil)
        chute:SetPos(chutePos)
        chute:SetAngles(chuteAng)
        local cfg = WEAPON_CONFIGS[self.WeaponType] or {}
        if not cfg.chuteClass then
            -- Plain prop chute -- give it physics.
            chute:PhysicsInit(SOLID_VPHYSICS)
            EnablePhysics(chute, baseVel, 50, 20)
        else
            -- Smart chute entity -- wake its physics if it has one.
            local cp = chute:GetPhysicsObject()
            if IsValid(cp) then
                cp:Wake()
                cp:SetVelocity(baseVel + Vector(
                    math.Rand(-50, 50),
                    math.Rand(-50, 50),
                    math.Rand(-30, -5)
                ))
            end
        end
        self.ChuteEnt = nil
    end

    -- ── Release smart munitions (gbu53, jassm) ──────────────
    -- These run their own Think()-based physics; just restore
    -- MOVETYPE_NONE and make them visible so their freefall loop
    -- takes over from here.
    local cfg = WEAPON_CONFIGS[self.WeaponType] or {}
    for _, m in ipairs(self.MunitionEnts) do
        if IsValid(m) then
            local mPos = m:GetPos()
            local mAng = m:GetAngles()
            m:SetParent(nil)
            m:SetPos(mPos)
            m:SetAngles(mAng)
            m:SetMoveType(MOVETYPE_NONE)
            m:SetSolid(SOLID_NONE)
            m:SetCollisionGroup(COLLISION_GROUP_NONE)
            m:SetRenderMode(RENDERMODE_NORMAL)
        end
    end

    -- ── Release external bomb (heavy / retarded) ────────────
    -- Arming is deferred so the bomb flies clear before fusing.
    if IsValid(self.ExternalBomb) then
        local bomb    = self.ExternalBomb
        local bombPos = bomb:GetPos()
        local bombAng = bomb:GetAngles()
        bomb:SetParent(nil)
        bomb:SetPos(bombPos)
        bomb:SetAngles(bombAng)
        bomb:SetMoveType(MOVETYPE_VPHYSICS)
        bomb:SetSolid(SOLID_VPHYSICS)
        bomb:SetCollisionGroup(CG_RELEASE)
        local bp = bomb:GetPhysicsObject()
        if IsValid(bp) then
            bp:Wake()
            bp:SetVelocity(baseVel + Vector(
                math.Rand(-SCATTER_H, SCATTER_H),
                math.Rand(-SCATTER_H, SCATTER_H),
                math.Rand(-SCATTER_V, SCATTER_V)
            ))
        end
        if IsValid(plane) then
            local nc2 = constraint.NoCollide(bomb, plane, 0, 0)
            timer.Simple(2.0, function() if IsValid(nc2) then nc2:Remove() end end)
        end
        -- Deferred arming.
        timer.Simple(ARM_DELAY, function()
            if not IsValid(bomb) then return end
            if bomb.Arm then bomb:Arm()
            elseif bomb.Armed ~= nil then bomb.Armed = true end
        end)
        self.ExternalBomb = nil
    end

    -- ── Release cosmetic props (staggered) ──────────────────
    for i, cp in ipairs(self.CosmeticEnts) do
        local ref = cp
        timer.Simple((i - 1) * COSMETIC_STAGGER, function()
            if not IsValid(ref) then return end
            local cPos = ref:GetPos()
            local cAng = ref:GetAngles()
            ref:SetParent(nil)
            ref:SetPos(cPos)
            ref:SetAngles(cAng)
            ref:PhysicsInit(SOLID_VPHYSICS)
            EnablePhysics(ref, baseVel, SCATTER_H, SCATTER_V)
        end)
    end

    sound.Play("physics/wood/wood_crate_impact_hard1.wav", worldPos, 82, math.random(90, 110), 1.0)

    -- Schedule debris cleanup.
    local refs = { self }
    for _, e in ipairs(self.CosmeticEnts) do refs[#refs + 1] = e end
    timer.Simple(DEBRIS_LIFE, function()
        for _, e in ipairs(refs) do SafeRemove(e) end
    end)
end

-- ============================================================
-- CLEANUP
-- ============================================================
function ENT:OnRemove()
    SafeRemove(self.ChuteEnt)
    for _, e in ipairs(self.MunitionEnts)  do SafeRemove(e) end
    for _, e in ipairs(self.CosmeticEnts)  do SafeRemove(e) end
    -- ExternalBomb is owned by C-17 logic; don't remove it on pallet cleanup.
end
