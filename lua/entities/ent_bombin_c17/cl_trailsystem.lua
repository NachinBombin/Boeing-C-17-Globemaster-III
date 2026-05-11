-- ============================================================
-- CONTRAIL SYSTEM  --  ent_bombin_c17
-- Trail offsets are scaled to match MODEL_SCALE = 1.8.
-- Original unscaled offsets (1.0x):
--   inner pods ~+/-120 HU, outer pods ~+/-230 HU
-- Scaled 1.8x:
--   inner pods ~+/-216 HU, outer pods ~+/-414 HU
-- Trail ribbon sizes also scaled: startSize 28->50, endSize 8->14.
-- ============================================================

local TRAIL_MATERIAL = Material( "trails/smoke" )
local SAMPLE_RATE    = 0.025

-- X = wingspan offset, Y = rear of engine pod, Z = slight up
-- All values multiplied by 1.8 to match the scaled model.
local TRAIL_OFFSETS = {
    Vector(  414, -108,  0 ),   -- outer-right engine pod pair  (230 * 1.8)
    Vector(  216, -108,  0 ),   -- inner-right engine pod pair  (120 * 1.8)
    Vector( -216, -108,  0 ),   -- inner-left  engine pod pair
    Vector( -414, -108,  0 ),   -- outer-left  engine pod pair
    Vector(    0, -144,  0 ),   -- fuselage center              ( 80 * 1.8)
}

local CONTRAIL_CFG = {
    r = 255, g = 255, b = 255, a = 120,
    -- startSize / endSize scaled 1.8x for the larger model.
    startSize = 50, endSize = 14, lifetime = 8,
}

local C17Trails = {}

local function EnsureRegistered( entIndex )
    if C17Trails[entIndex] then return end
    local streams = {}
    for i = 1, #TRAIL_OFFSETS do
        -- FIX (BUG-5): expiry is now handled in the Think sampler, not in
        -- DrawBeam.  The 'lastExpiry' field is unused but kept as a sentinel
        -- so the structure is self-documenting.
        streams[i] = { nextSample = 0, positions = {} }
    end
    C17Trails[entIndex] = streams
end

-- FIX (BUG-5): DrawBeam is now read-only; it never mutates positions.
-- Expiry is handled once per SAMPLE_RATE in the Think hook below.
local function DrawBeam( positions, cfg )
    local n = #positions
    if n < 2 then return end
    local Time = CurTime()
    local lt   = cfg.lifetime
    render.SetMaterial( TRAIL_MATERIAL )
    render.StartBeam( n )
    for _, pd in ipairs( positions ) do
        local Scale = math.Clamp( (pd.time + lt - Time) / lt, 0, 1 )
        local size  = cfg.startSize * Scale + cfg.endSize * (1 - Scale)
        render.AddBeam( pd.pos, size, pd.time * 50,
            Color( cfg.r, cfg.g, cfg.b, cfg.a * Scale * Scale ) )
    end
    render.EndBeam()
end

hook.Add( "Think", "bombin_c17_contrail_update", function()
    local Time = CurTime()
    for _, ent in ipairs( ents.FindByClass( "ent_bombin_c17" ) ) do
        EnsureRegistered( ent:EntIndex() )
    end
    for entIndex, streams in pairs( C17Trails ) do
        local ent = Entity( entIndex )
        if not IsValid( ent ) then C17Trails[entIndex] = nil continue end
        local pos = ent:GetPos()
        local ang = ent:GetAngles()
        for i, stream in ipairs( streams ) do
            if Time < stream.nextSample then continue end
            stream.nextSample = Time + SAMPLE_RATE

            -- FIX (BUG-4): insert newest entry at index 1 so the list is
            -- always newest-first without any sort pass.  The old code
            -- appended to the tail and then called table.sort() O(n log n)
            -- every 25 ms per stream -- wasted CPU on an already-sorted list.
            local wpos = LocalToWorld( TRAIL_OFFSETS[i], Angle(0,0,0), pos, ang )
            table.insert( stream.positions, 1, { time = Time, pos = wpos } )

            -- FIX (BUG-5): expire old entries here, once per sample tick,
            -- rather than inside DrawBeam which runs every render frame.
            -- Positions are newest-first so we can break as soon as we hit
            -- the first non-expired entry (from the tail).
            local lt       = CONTRAIL_CFG.lifetime
            local tbl      = stream.positions
            local cutoff   = Time - lt
            for j = #tbl, 1, -1 do
                if tbl[j].time < cutoff then
                    table.remove( tbl, j )
                else
                    break   -- all older entries are at higher indices; done
                end
            end
        end
    end
end )

hook.Add( "PostDrawTranslucentRenderables", "bombin_c17_contrail_draw", function( bDepth, bSkybox )
    if bSkybox then return end
    for _, streams in pairs( C17Trails ) do
        for _, stream in ipairs( streams ) do
            DrawBeam( stream.positions, CONTRAIL_CFG )
        end
    end
end )
