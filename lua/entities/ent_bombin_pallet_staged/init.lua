-- ============================================================
-- ent_bombin_pallet_staged  --  SERVER
--
-- A palletized cargo assembly that lives INSIDE the C-17 fuselage.
-- It is parented to the plane via SetParent / SetLocalPos so it
-- rides every bank, pitch, and altitude change automatically.
--
-- Lifecycle:
--   1. Initialize()   - spawn pallet + munitions + chute as
--                       MOVETYPE_NONE children; parent to plane.
--   2. SlideToExit()  - called by the C-17 once the cargo door is
--                       fully open.  Lerps SetLocalPos from the
--                       interior rest position to the door exit
--                       offset over SLIDE_DURATION seconds.
--   3. Release()      - called automatically when the slide
--                       completes.  Unparents, gives every piece
--                       the plane's current velocity, then lets
--                       physics take over.  Munition-specific
--                       post-release logic (chute deployment,
--                       engine ignition) is handled here.
-- ============================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================
-- CONSTANTS
-- ============================================================
local PALLET_MODEL       = "models/props/de_prodigy/wood_pallet_01.mdl"
local CHUTE_MODEL        = "models/v92/parachutez/flying.mdl"
local CHUTE_SCALE        = 2.2
local CHUTE_ABOVE_PALLET = Vector(0, 0, 100)

-- How long (seconds) the pallet slides from the rest position
-- to the door exit.  Keep >= 1.5 so players can see movement.
local SLIDE_DURATION = 2.2

-- Interior rest position (local to plane, scale=1.8 model).
-- X is forward (+) / aft (-) in local space.  Tune to sit the
-- pallet on the cargo-floor centreline behind the CG.
local PALLET_STAGE_LOCAL = Vector(200, 0, -55)

-- Local position at the cargo-door lip -- where the pallet falls off.
local PALLET_EXIT_LOCAL  = Vector(-340, 0, -68)

-- Collision group while parented (no interaction needed).
local CG_STAGED  = COLLISION_GROUP_NONE
-- Collision group after release.
local CG_RELEASE = COLLISION_GROUP_DEBRIS_TRIGGER

-- Seconds to wait after release before removing debris.
local DEBRIS_LIFE = 22

-- NoCollide hold between the freshly-released pallet and the plane.
local NC_HOLD = 2.0

-- Per-munition scatter on release (source units / second).
local RELEASE_SCATTER_H = 80   -- horizontal
local RELEASE_SCATTER_V = 30   -- vertical

-- Stagger between munition physics-enable on release.
local MUNITION_RELEASE_STAGGER = 0.18

-- ============================================================
-- WEAPON-TYPE CHILD CONFIGS
-- Each entry describes what child entities/props to build on
-- the pallet for a given weapon type.
-- ============================================================
local WEAPON_CONFIGS = {

    -- GBU-53 cluster: pallet carries a JASSM-style loitering missile
    -- (ent_bombin_gbu53_owned) as the "brain", plus cosmetic GBU53
    -- models.  The chute deploys on release.  The missile ignites
    -- once it falls past IgnitionAlt handled inside gbu53_owned.
    gbu53 = {
        munitionClass  = "ent_bombin_gbu53_owned",
        munitionModel  = "models/sw/usa/bombs/guided/gbu53.mdl",
        munitionScale  = 1.0,
        munitionCount  = 1,         -- the "brain" entity
        cosmetic       = true,      -- also spawn visual prop copies
        cosmeticCount  = 4,
        cosmeticModel  = "models/sw/usa/bombs/guided/gbu53.mdl",
        cosmeticScale  = 1.0,
        cosmeticOffsets = {
            Vector( 30,  18, 8),
            Vector( 30, -18, 8),
            Vector(-30,  18, 8),
            Vector(-30, -18, 8),
        },
        cosmeticYaws   = { 0, 0, 180, 180 },
        hasChute       = true,
        releaseIgnite  = false,     -- gbu53_owned ignites itself
    },

    -- JASSM: single loitering missile entity.
    -- The jassm_chute_owned entity is created as a child too.
    jassm = {
        munitionClass  = "ent_bombin_jassm_owned",
        munitionModel  = nil,       -- entity uses its own model
        munitionScale  = 1.0,
        munitionCount  = 1,
        cosmetic       = false,
        hasChute       = true,
        chuteClass     = "ent_bombin_jassm_chute_owned",
        releaseIgnite  = false,     -- jassm_owned manages itself
    },

    -- Heavy GP / penetrator: single dumb bomb prop.
    heavy = {
        munitionClass  = nil,       -- spawned externally, pallet is cosmetic
        munitionModel  = nil,
        munitionCount  = 0,
        cosmetic       = false,
        hasChute       = false,
        releaseIgnite  = false,
    },

    -- Retarded / parachute bombs: single dumb bomb prop.
    retarded = {
        munitionClass  = nil,
        munitionModel  = nil,
        munitionCount  = 0,
        cosmetic       = false,
        hasChute       = false,
        releaseIgnite  = false,
    },
}

-- ============================================================
-- HELPERS
-- ============================================================
local function SafeRemove(e)
    if IsValid(e) then e:Remove() end
end

local function MakeStaticProp(model, pos, ang, scale)
    local p = ents.Create("prop_physics")
    if not IsValid(p) then return nil end
    p:SetModel(model)
    p:SetPos(pos)
    p:SetAngles(ang)
    p:Spawn()
    p:Activate()
    if scale and scale ~= 1.0 then p:SetModelScale(scale, 0) end
    p:SetMoveType(MOVETYPE_NONE)
    p:SetSolid(SOLID_NONE)
    p:SetCollisionGroup(CG_STAGED)
    p:DrawShadow(false)
    return p
end

local function ReleasePhysics(ent, baseVel, scatterH, scatterV)
    if not IsValid(ent) then return end
    ent:SetMoveType(MOVETYPE_VPHYSICS)
    ent:SetSolid(SOLID_VPHYSICS)
    ent:SetCollisionGroup(CG_RELEASE)
    local ph = ent:GetPhysicsObject()
    if IsValid(ph) then
        ph:Wake()
        ph:SetVelocity(Vector(
            baseVel.x + math.Rand(-scatterH, scatterH),
            baseVel.y + math.Rand(-scatterH, scatterH),
            baseVel.z + math.Rand(-scatterV, scatterV)
        ))
        ph:AddAngleVelocity(Vector(
            math.Rand(-60, 60),
            math.Rand(-60, 60),
            math.Rand(-30, 30)
        ))
    end
end

-- ============================================================
-- INITIALIZE
-- ============================================================
function ENT:Initialize()
    -- Plane and weapon type are set by the C-17 before Spawn().
    self.PlaneEnt    = self.PlaneEnt   or nil
    self.WeaponType  = self.WeaponType or "heavy"
    -- ExtraData carries weapon-specific fields set by the C-17
    -- (e.g. CenterPos, CallDir, Lifetime, SHA, OrbitRadius, etc.).
    self.ExtraData   = self.ExtraData  or {}

    -- Runtime state.
    self.Sliding      = false
    self.SlideStart   = 0
    self.Released     = false
    self.MunitionEnts = {}   -- live entity children (not cosmetic)
    self.CosmeticEnts = {}   -- visual-only props
    self.ChuteEnt     = nil
    self.BombEnt      = nil  -- for heavy/retarded, the actual bomb entity

    -- Set up pallet model.
    self:SetModel(PALLET_MODEL)
    self:SetModelScale(1.0, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(CG_STAGED)
    self:DrawShadow(false)

    -- Parent to the plane immediately so we move with it.
    if IsValid(self.PlaneEnt) then
        self:SetParent(self.PlaneEnt)
        self:SetLocalPos(PALLET_STAGE_LOCAL)
        self:SetLocalAngles(Angle(0, 0, 0))
    end

    -- Defer child spawning one tick so the parent transform is set.
    timer.Simple(0, function()
        if not IsValid(self) then return end
        self:SpawnChildren()
    end)

    self:EmitSound("npc/combine_soldier/zipline_clip1.wav", 75, 108, 0.85)
end

-- ============================================================
-- SPAWN CHILDREN
-- ============================================================
function ENT:SpawnChildren()
    if not IsValid(self) then return end
    local cfg = WEAPON_CONFIGS[self.WeaponType]
    if not cfg then return end

    local worldPos = self:GetPos()
    local worldAng = self:GetAngles()
    local plane    = self.PlaneEnt

    -- ── Chute ───────────────────────────────────────────────
    if cfg.hasChute then
        local chuteClass = cfg.chuteClass
        local chute
        if chuteClass then
            chute = ents.Create(chuteClass)
        else
            chute = ents.Create("prop_physics")
            if IsValid(chute) then
                chute:SetModel(CHUTE_MODEL)
            end
        end
        if IsValid(chute) then
            chute:SetPos(worldPos + CHUTE_ABOVE_PALLET)
            chute:SetAngles(worldAng)
            chute:Spawn()
            chute:Activate()
            if not chuteClass then
                -- plain prop chute
                chute:SetModelScale(CHUTE_SCALE, 0)
                chute:SetMoveType(MOVETYPE_NONE)
                chute:SetSolid(SOLID_NONE)
                chute:SetCollisionGroup(CG_STAGED)
                chute:DrawShadow(false)
            end
            chute:SetParent(self)
            chute:SetLocalPos(CHUTE_ABOVE_PALLET)
            chute:SetLocalAngles(Angle(0, 0, 0))
            self.ChuteEnt = chute
            if IsValid(plane) then
                local nc = constraint.NoCollide(chute, plane, 0, 0)
                timer.Simple(NC_HOLD, function()
                    if IsValid(nc) then nc:Remove() end
                end)
            end
        end
    end

    -- ── Primary munition entity ─────────────────────────────
    if cfg.munitionClass and cfg.munitionCount > 0 then
        local m = ents.Create(cfg.munitionClass)
        if IsValid(m) then
            -- Propagate all extra data fields.
            for k, v in pairs(self.ExtraData) do
                m:SetVar(k, v)
            end
            m.SpawnedFromPlane = true
            m.IsOnPlane        = true
            m.Launcher         = plane
            m:SetOwner(self)
            if IsValid(plane) then m:SetVar("ParentPlane", plane) end

            m:SetPos(worldPos)
            m:SetAngles(worldAng)
            m:Spawn()
            m:Activate()

            if cfg.munitionModel then
                m:SetModel(cfg.munitionModel)
            end
            if cfg.munitionScale and cfg.munitionScale ~= 1.0 then
                m:SetModelScale(cfg.munitionScale, 0)
            end

            m:SetMoveType(MOVETYPE_NONE)
            m:SetSolid(SOLID_NONE)
            m:SetCollisionGroup(CG_STAGED)

            m:SetParent(self)
            m:SetLocalPos(Vector(0, 0, 0))
            m:SetLocalAngles(Angle(0, 0, 0))

            self.MunitionEnts[#self.MunitionEnts + 1] = m
            self.BombEnt = m

            if IsValid(plane) then
                local nc = constraint.NoCollide(m, plane, 0, 0)
                timer.Simple(NC_HOLD, function()
                    if IsValid(nc) then nc:Remove() end
                end)
            end
        end
    end

    -- ── Cosmetic visual copies ──────────────────────────────
    if cfg.cosmetic then
        local cosY = math.cos(math.rad(worldAng.y))
        local sinY = math.sin(math.rad(worldAng.y))
        for i = 1, cfg.cosmeticCount do
            local off = cfg.cosmeticOffsets[i]
            if not off then continue end
            local wx = off.x * cosY - off.y * sinY
            local wy = off.x * sinY + off.y * cosY
            local cpos = Vector(worldPos.x + wx, worldPos.y + wy, worldPos.z + off.z)
            local yang = (cfg.cosmeticYaws and cfg.cosmeticYaws[i]) or 0
            local cp = MakeStaticProp(
                cfg.cosmeticModel,
                cpos,
                Angle(0, worldAng.y + yang, 0),
                cfg.cosmeticScale
            )
            if IsValid(cp) then
                cp:SetParent(self)
                cp:SetLocalPos(Vector(
                    off.x,
                    off.y,
                    off.z
                ))
                cp:SetLocalAngles(Angle(0, yang, 0))
                self.CosmeticEnts[#self.CosmeticEnts + 1] = cp
                if IsValid(plane) then
                    local nc = constraint.NoCollide(cp, plane, 0, 0)
                    timer.Simple(NC_HOLD, function()
                        if IsValid(nc) then nc:Remove() end
                    end)
                end
            end
        end
    end
end

-- ============================================================
-- SLIDE TO EXIT
-- Called by the C-17 after the cargo door animation finishes.
-- ============================================================
function ENT:SlideToExit(ct)
    if self.Released or self.Sliding then return end
    self.Sliding    = true
    self.SlideStart = ct
    self:EmitSound("physics/wood/wood_box_scrape_rough_loop1.wav", 70, 110, 0.6)
end

-- ============================================================
-- THINK  (drives the slide)
-- ============================================================
function ENT:Think()
    if self.Released then return end

    local ct = CurTime()

    if not self.Sliding then
        self:NextThink(ct + 0.05)
        return true
    end

    -- Safety: if the plane is gone, release immediately.
    if not IsValid(self.PlaneEnt) then
        self:Release()
        return
    end

    local t = math.Clamp((ct - self.SlideStart) / SLIDE_DURATION, 0, 1)
    local localPos = LerpVector(t, PALLET_STAGE_LOCAL, PALLET_EXIT_LOCAL)
    self:SetLocalPos(localPos)

    if t >= 1.0 then
        self:Release()
        return
    end

    self:NextThink(ct + (1 / 60))
    return true
end

-- ============================================================
-- RELEASE
-- Unparent and let physics take over for everything.
-- ============================================================
function ENT:Release()
    if self.Released then return end
    self.Released = true
    self.Sliding  = false

    local plane    = self.PlaneEnt
    local baseVel  = IsValid(plane) and plane:GetVelocity() or Vector(0, 0, 0)

    -- ── Unparent pallet ─────────────────────────────────────
    self:SetParent(nil)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(CG_RELEASE)
    local palPhys = self:GetPhysicsObject()
    if IsValid(palPhys) then
        palPhys:Wake()
        palPhys:SetVelocity(baseVel + Vector(
            math.Rand(-40, 40),
            math.Rand(-40, 40),
            math.Rand(-20, 10)
        ))
        palPhys:AddAngleVelocity(Vector(
            math.Rand(-30, 30),
            math.Rand(-30, 30),
            math.Rand(-20, 20)
        ))
    end
    if IsValid(plane) then
        local nc = constraint.NoCollide(self, plane, 0, 0)
        timer.Simple(NC_HOLD, function()
            if IsValid(nc) then nc:Remove() end
        end)
    end

    -- ── Release chute ────────────────────────────────────────
    if IsValid(self.ChuteEnt) then
        local chute = self.ChuteEnt
        chute:SetParent(nil)
        local cfg = WEAPON_CONFIGS[self.WeaponType] or {}
        if cfg.chuteClass then
            -- it's a full entity (e.g. ent_bombin_jassm_chute_owned)
            -- it manages itself; just give it the base velocity
            local cp = chute:GetPhysicsObject()
            if IsValid(cp) then
                cp:Wake()
                cp:SetVelocity(baseVel + Vector(
                    math.Rand(-60, 60),
                    math.Rand(-60, 60),
                    math.Rand(-40, -10)
                ))
            end
        else
            -- plain prop chute
            chute:SetMoveType(MOVETYPE_VPHYSICS)
            chute:SetSolid(SOLID_VPHYSICS)
            chute:SetCollisionGroup(CG_RELEASE)
            local cp = chute:GetPhysicsObject()
            if IsValid(cp) then
                cp:Wake()
                cp:SetVelocity(baseVel + Vector(
                    math.Rand(-60, 60),
                    math.Rand(-60, 60),
                    math.Rand(-40, -10)
                ))
            end
        end
        self.ChuteEnt = nil
    end

    -- ── Release primary munition entities ────────────────────
    for _, m in ipairs(self.MunitionEnts) do
        if IsValid(m) then
            m:SetParent(nil)
            -- For smart entities (gbu53, jassm) restore MOVETYPE_NONE
            -- freefall so they run their own physics in Think().
            local cfg = WEAPON_CONFIGS[self.WeaponType] or {}
            if cfg.releaseIgnite then
                -- Dumb bomb -- give it physics directly.
                m:SetMoveType(MOVETYPE_VPHYSICS)
                m:SetSolid(SOLID_VPHYSICS)
                m:SetCollisionGroup(CG_RELEASE)
                local mp = m:GetPhysicsObject()
                if IsValid(mp) then
                    mp:Wake()
                    mp:SetVelocity(baseVel + Vector(
                        math.Rand(-RELEASE_SCATTER_H, RELEASE_SCATTER_H),
                        math.Rand(-RELEASE_SCATTER_H, RELEASE_SCATTER_H),
                        math.Rand(-RELEASE_SCATTER_V, RELEASE_SCATTER_V)
                    ))
                end
                if m.Arm then m:Arm()
                elseif m.Armed ~= nil then m.Armed = true end
            else
                -- Smart loitering entity: restore its freefall MOVETYPE_NONE
                -- and let its own Think() drive it from here.
                m:SetMoveType(MOVETYPE_NONE)
                m:SetSolid(SOLID_NONE)
                m:SetCollisionGroup(COLLISION_GROUP_NONE)
                -- Seed the position so freefall starts at the door exit.
                -- The entity's own UpdateFreefall() / orbit logic handles
                -- everything from here.
                m:SetRenderMode(RENDERMODE_NORMAL)
            end
        end
    end

    -- ── Release cosmetic props (staggered) ───────────────────
    for i, cp in ipairs(self.CosmeticEnts) do
        local ref = cp
        timer.Simple((i - 1) * MUNITION_RELEASE_STAGGER, function()
            if not IsValid(ref) then return end
            ref:SetParent(nil)
            ReleasePhysics(ref, baseVel, RELEASE_SCATTER_H, RELEASE_SCATTER_V)
        end)
    end

    sound.Play("physics/wood/wood_crate_impact_hard1.wav", self:GetPos(), 82, math.random(90, 108), 1.0)

    -- ── Schedule debris cleanup ──────────────────────────────
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
    if IsValid(self.ChuteEnt) then self.ChuteEnt:Remove() end
    for _, e in ipairs(self.MunitionEnts)  do SafeRemove(e) end
    for _, e in ipairs(self.CosmeticEnts)  do SafeRemove(e) end
end
