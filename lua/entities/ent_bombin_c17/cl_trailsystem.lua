-- ============================================================
-- CONTRAIL SYSTEM  --  ent_bombin_c17
-- Trail offsets are scaled to match MODEL_SCALE = 1.8.
-- C-17 has 4 engines (2 per wing).
-- Offsets approximate the C-17 under-wing engine pod positions.
-- Original unscaled offsets (1.0x):
--   inner pods ~+/-90 HU, outer pods ~+/-190 HU
-- Scaled 1.8x:
--   inner pods ~+/-162 HU, outer pods ~+/-342 HU
-- Trail ribbon sizes also scaled: startSize 28->50, endSize 8->14.
-- ============================================================

local TRAIL_MATERIAL = Material( "trails/smoke" )
local SAMPLE_RATE    = 0.025

-- X = wingspan offset, Y = rear of engine pod, Z = slight up
-- All values scaled to match the C-17 model geometry.
local TRAIL_OFFSETS = {
    Vector(  342, -108,  0 ),   -- outer-right engine pod  (190 * 1.8)
    Vector(  162, -108,  0 ),   -- inner-right engine pod  ( 90 * 1.8)
    Vector( -162, -108,  0 ),   -- inner-left  engine pod
    Vector( -342, -108,  0 ),   -- outer-left  engine pod
}

local CONTRAIL_CFG = {
    r = 255, g = 255, b = 255, a = 120,
    startSize = 50, endSize = 14, lifetime = 8,
}

local C17Trails = {}

local function EnsureRegistered( entIndex )
    if C17Trails[entIndex] then return end
    local streams = {}
    for i = 1, #TRAIL_OFFSETS do
        streams[i] = { nextSample = 0, positions = {} }
    end
    C17Trails[entIndex] = streams
end

local function DrawBeam( positions, cfg )
    local n = #positions
    if n < 2 then return end
    local Time = CurTime()
    local lt   = cfg.lifetime
    for i = n, 1, -1 do
        if Time - positions[i].time > lt then table.remove( positions, i ) end
    end
    n = #positions
    if n < 2 then return end
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
            local wpos = LocalToWorld( TRAIL_OFFSETS[i], Angle(0,0,0), pos, ang )
            table.insert( stream.positions, { time = Time, pos = wpos } )
            table.sort( stream.positions, function(a,b) return a.time > b.time end )
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
