include( "shared.lua" )
include( "cl_trailsystem.lua" )

-- ============================================================
-- CONSTANTS
-- ============================================================
local ROLL_MAX        = 22.0
local FLAP_RETRACTED  = -28
local FLAP_EXTENDED   =  38
local FAN_RPM         = 900

-- ============================================================
-- CARGO DOOR CONSTANTS
-- ============================================================
-- Open order:  ramp_2 (28°) → ramp_1 (28°) → ramp_1b (100°)
-- Close order: ramp_1b (0°) → ramp_1 (0°)  → ramp_2  (0°)
--
-- _DoorStage encoding:
--   0          = fully closed / idle
--   1, 2, 3    = opening bone index 1..3
--   4          = fully open / holding
--  -1,-2,-3    = closing bone index 1..3 (stored as negative)
--
-- DOOR_SPEED: degrees per second for each bone.
-- Stage transitions happen when the current bone reaches its target
-- within DOOR_THRESHOLD degrees.
-- ============================================================
local DOOR_SPEED     = 28          -- deg/s  (full travel ~1 s for ramp_2/1, ~3.6 s for ramp_1b)
local DOOR_THRESHOLD = 1.0         -- degrees — close enough to snap and advance stage

local DOOR_TARGETS_OPEN = { 28, 28, 100 }   -- ramp_2, ramp_1, ramp_1b open targets

local DOOR_BONES = {
	"c17.ramp_2_move",
	"c17.ramp_1_move",
	"c17.ramp_1b_move",
}

-- ============================================================
-- CARGO LIGHT CONSTANTS
-- ============================================================
-- A bright red DynamicLight sits at the ramp opening.
-- It pulses slowly using a sine wave to simulate the interior
-- warning lamp seen through the open cargo bay.
local CARGO_LIGHT_LOCAL    = Vector( -200, 0, -80 )   -- local offset: rear belly of the plane
local CARGO_LIGHT_RADIUS   = 800                       -- source radius in units
local CARGO_LIGHT_DECAY    = 1200                      -- falloff rate
local CARGO_LIGHT_MIN_BRIG = 0.35                      -- brightness floor (0-1)
local CARGO_LIGHT_MAX_BRIG = 1.0                       -- brightness ceiling (0-1)
local CARGO_LIGHT_PULSE_HZ = 0.6                       -- pulse cycles per second

-- ============================================================
-- CONDENSATION VAPOR CONSTANTS
-- ============================================================
-- When the cargo door starts opening, a cold-air condensation
-- cloud erupts from the ramp area for VAPOR_DURATION seconds.
-- We emit one smoke particle burst per Draw() frame during that window.
local VAPOR_DURATION    = 1.5     -- seconds the vapor lasts after door-open trigger
local VAPOR_LOCAL       = Vector( -200, 0, -90 )   -- local offset: ramp mouth
local VAPOR_EMIT_RATE   = 0.055   -- min seconds between individual puffs

function ENT:Initialize()
	self:SetBodygroup( 1, 1 )
	self._FanAngle = 0

	-- Cargo door state
	self._DoorAngles  = { 0, 0, 0 }
	self._DoorStage   = 0
	self._DoorWasOpen = false

	-- Cargo light
	self._CargoLightIdx = nil   -- allocated lazily

	-- Condensation vapor
	self._VaporUntil    = 0     -- CurTime() deadline; 0 = inactive
	self._VaporNextPuff = 0     -- throttle: CurTime() of next allowed puff
end

-- ============================================================
-- CARGO DOOR ANIMATOR
-- ============================================================
function ENT:UpdateCargoDoors( dt )
	local wantOpen = self:GetNWBool( "CargoDoorOpen", false )

	-- ── Transition: closed/closing → opening ─────────────────
	if wantOpen and not self._DoorWasOpen then
		self._DoorWasOpen = true

		if self._DoorStage == 0 then
			self._DoorStage = 1
		elseif self._DoorStage < 0 then
			-- Mid-close: resume the correct bone instead of restarting.
			self._DoorStage = math.abs( self._DoorStage )
		end
		-- If _DoorStage > 0 we were already opening — leave it.

		-- Trigger condensation vapor burst on every door-open event.
		self._VaporUntil    = CurTime() + VAPOR_DURATION
		self._VaporNextPuff = 0
	end

	-- ── Transition: opening/open → closing ───────────────────
	if not wantOpen and self._DoorWasOpen then
		self._DoorWasOpen = false

		if self._DoorStage == 4 or self._DoorStage > 0 then
			local startClose = 0
			for i = 3, 1, -1 do
				if self._DoorAngles[i] > DOOR_THRESHOLD then
					startClose = -i
					break
				end
			end
			self._DoorStage = startClose
		end
		-- If _DoorStage < 0 we were already closing — leave it.
	end

	-- Nothing to animate when fully closed or fully open.
	if self._DoorStage == 0 or self._DoorStage == 4 then return end

	local step = DOOR_SPEED * dt

	if self._DoorStage > 0 then
		-- ── OPENING ──────────────────────────────────────────
		local i      = self._DoorStage
		local target = DOOR_TARGETS_OPEN[i]
		local cur    = self._DoorAngles[i]
		local diff   = target - cur

		if diff <= DOOR_THRESHOLD then
			self._DoorAngles[i] = target
			self._DoorStage     = ( i < 3 ) and ( i + 1 ) or 4
		else
			self._DoorAngles[i] = cur + math.min( step, diff )
		end
	else
		-- ── CLOSING ──────────────────────────────────────────
		local i   = math.abs( self._DoorStage )
		local cur = self._DoorAngles[i]

		if cur <= DOOR_THRESHOLD then
			self._DoorAngles[i] = 0
			self._DoorStage     = ( i > 1 ) and -( i - 1 ) or 0
		else
			self._DoorAngles[i] = cur - math.min( step, cur )
		end
	end
end

-- ============================================================
-- RED CARGO BAY LIGHT
-- ============================================================
-- Emits a bright pulsing red DynamicLight at the ramp mouth.
-- Only active while CargoDoorOpen is true.
-- DynamicLight() must be called every frame to keep the light alive;
-- it self-expires after one frame if not refreshed.
function ENT:UpdateCargoLight()
	if not self:GetNWBool( "CargoDoorOpen", false ) then return end

	local dl = DynamicLight( self:EntIndex() + 4096 )
	if not dl then return end

	-- Pulse brightness: smooth sine oscillation between MIN and MAX.
	local t       = CurTime() * CARGO_LIGHT_PULSE_HZ * math.pi * 2
	local frac    = ( math.sin( t ) + 1 ) * 0.5   -- 0..1
	local bright  = CARGO_LIGHT_MIN_BRIG + frac * ( CARGO_LIGHT_MAX_BRIG - CARGO_LIGHT_MIN_BRIG )

	local worldPos = self:LocalToWorld( CARGO_LIGHT_LOCAL )

	dl.pos     = worldPos
	dl.r       = 255
	dl.g       = 20
	dl.b       = 10
	dl.brightness = bright * 6    -- DynamicLight brightness is > 1 for intensity
	dl.decay   = CARGO_LIGHT_DECAY
	dl.size    = CARGO_LIGHT_RADIUS
	dl.dietime = CurTime() + 0.1  -- refresh next frame; expires if not called
end

-- ============================================================
-- CONDENSATION VAPOR
-- ============================================================
-- Emits a smoke/steam particle effect from the ramp mouth for
-- VAPOR_DURATION seconds after the door-open event fires.
-- We use the built-in "steam" or "smokestack" particle because
-- they are guaranteed present in any GMod install.
function ENT:UpdateVapor()
	local ct = CurTime()
	if ct >= self._VaporUntil then return end
	if ct < self._VaporNextPuff then return end

	self._VaporNextPuff = ct + VAPOR_EMIT_RATE

	local worldPos = self:LocalToWorld( VAPOR_LOCAL )

	-- EffectData: origin at ramp, normal pointing backward+down so
	-- the puff drifts away from the tail and hangs in the slipstream.
	local ed = EffectData()
	ed:SetOrigin( worldPos )
	ed:SetNormal( ( self:LocalToWorldAngles( Angle(20, 180, 0) ) ):Forward() )
	ed:SetScale( 1.4 )
	ed:SetMagnitude( 1.0 )
	ed:SetRadius( 28 )
	util.Effect( "steam", ed )
end

function ENT:Draw()
	-- --------------------------------------------------------
	-- Roll: server encodes Angle(-SmoothedRoll, yaw+offset, -SmoothedPitch).
	-- --------------------------------------------------------
	local roll = self:GetAngles().p

	-- --------------------------------------------------------
	-- Fan rotation
	-- --------------------------------------------------------
	self._FanAngle = ( self._FanAngle or 0 ) + FAN_RPM * FrameTime()
	if self._FanAngle > 360 then self._FanAngle = self._FanAngle - 360 end
	local fanZ = self._FanAngle

	-- --------------------------------------------------------
	-- Flap deflection
	-- --------------------------------------------------------
	local rollNorm  = math.Clamp( roll / ROLL_MAX, -1, 1 )
	local tLeft     = math.Clamp( -rollNorm, 0, 1 )
	local tRight    = math.Clamp(  rollNorm, 0, 1 )
	local flapLeft  = Lerp( tLeft,  FLAP_RETRACTED, FLAP_EXTENDED )
	local flapRight = Lerp( tRight, FLAP_RETRACTED, FLAP_EXTENDED )

	-- --------------------------------------------------------
	-- Cargo door animation + FX
	-- --------------------------------------------------------
	self:UpdateCargoDoors( FrameTime() )
	self:UpdateCargoLight()
	self:UpdateVapor()

	-- --------------------------------------------------------
	-- Draw model and apply bone overrides
	-- --------------------------------------------------------
	self:DrawModel()

	-- Fans
	local bLF1 = self:LookupBone( "c17.engine_fan_lf1" )
	local bLF2 = self:LookupBone( "c17.engine_fan_lf2" )
	local bRT1 = self:LookupBone( "c17.engine_fan_rt1" )
	local bRT2 = self:LookupBone( "c17.engine_fan_rt2" )

	if bLF1 then self:ManipulateBoneAngles( bLF1, Angle( 0, 0, fanZ ) ) end
	if bLF2 then self:ManipulateBoneAngles( bLF2, Angle( 0, 0, fanZ ) ) end
	if bRT1 then self:ManipulateBoneAngles( bRT1, Angle( 0, 0, fanZ ) ) end
	if bRT2 then self:ManipulateBoneAngles( bRT2, Angle( 0, 0, fanZ ) ) end

	-- Flaps
	local bFlapL = self:LookupBone( "c17.flap_lf_1c_move" )
	local bFlapR = self:LookupBone( "c17.flap_rt_1c_move" )

	if bFlapL then self:ManipulateBoneAngles( bFlapL, Angle( 0, flapLeft,  0 ) ) end
	if bFlapR then self:ManipulateBoneAngles( bFlapR, Angle( 0, flapRight, 0 ) ) end

	-- Cargo doors
	local bRamp2  = self:LookupBone( "c17.ramp_2_move"  )
	local bRamp1  = self:LookupBone( "c17.ramp_1_move"  )
	local bRamp1b = self:LookupBone( "c17.ramp_1b_move" )

	if bRamp2  then self:ManipulateBoneAngles( bRamp2,  Angle( 0, self._DoorAngles[1], 0 ) ) end
	if bRamp1  then self:ManipulateBoneAngles( bRamp1,  Angle( 0, self._DoorAngles[2], 0 ) ) end
	if bRamp1b then self:ManipulateBoneAngles( bRamp1b, Angle( 0, self._DoorAngles[3], 0 ) ) end
end

-- ============================================================
-- DAMAGE FX (unchanged)
-- ============================================================
game.AddParticles( "particles/fire_01.pcf" )
PrecacheParticleSystem( "fire_medium_02" )

local TIER_OFFSETS = {
	[1] = { Vector(0,0,0) },
	[2] = { Vector(0,0,0), Vector(70,0,-5), Vector(-70,0,-5) },
	[3] = { Vector(0,0,5), Vector(70,0,-5), Vector(-70,0,-5), Vector(0,130,-8), Vector(0,-130,-8) },
}
local TIER_BURST_DELAY = { [1]=5.0, [2]=2.5, [3]=0.9 }
local TIER_BURST_COUNT = { [1]=1,   [2]=2,   [3]=4   }
local PlaneStates = {}

local function BurstAt( wPos, tier )
	local ed = EffectData() ed:SetOrigin(wPos) ed:SetScale(tier==3 and math.Rand(0.8,1.4) or math.Rand(0.4,0.9)) ed:SetMagnitude(1) ed:SetRadius(tier*20) util.Effect("Explosion",ed)
	local ed2 = EffectData() ed2:SetOrigin(wPos) ed2:SetNormal(Vector(0,0,1)) ed2:SetScale(tier*0.3) ed2:SetMagnitude(tier*0.4) ed2:SetRadius(18) util.Effect("ManhackSparks",ed2)
	if tier>=2 then local ed3=EffectData() ed3:SetOrigin(wPos) ed3:SetNormal(VectorRand()) ed3:SetScale(0.6) util.Effect("ElectricSpark",ed3) end
end

local function SpawnBurstFX( ent, count, tier )
	if not IsValid(ent) then return end
	local pos, ang = ent:GetPos(), ent:GetAngles()
	for _ = 1, count do
		local wPos = LocalToWorld(Vector(math.Rand(-80,80), math.Rand(-140,60), math.Rand(-10,20)), Angle(0,0,0), pos, ang)
		BurstAt(wPos, tier)
	end
	if tier == 3 then
		for _, side in ipairs({Vector(0,130,-8), Vector(0,-130,-8)}) do
			local wPos = LocalToWorld(side, Angle(0,0,0), pos, ang)
			local ed = EffectData() ed:SetOrigin(wPos) ed:SetScale(0.7) ed:SetMagnitude(1) ed:SetRadius(30) util.Effect("Explosion",ed)
		end
	end
end

local function StopParticles( state )
	if not state.particles then return end
	for _, p in ipairs(state.particles) do if IsValid(p) then p:StopEmission() end end
	state.particles = {}
end

local function ApplyFlameParticles( ent, state, tier )
	StopParticles(state) state.tier = tier
	if not IsValid(ent) or tier == 0 then return end
	for _, off in ipairs(TIER_OFFSETS[tier]) do
		local p = ent:CreateParticleEffect("fire_medium_02", PATTACH_ABSORIGIN_FOLLOW, 0)
		if IsValid(p) then p:SetControlPoint(0, ent:LocalToWorld(off)) table.insert(state.particles, p) end
	end
	state.nextBurst = CurTime() + (TIER_BURST_DELAY[tier] or 4)
end

net.Receive( "bombin_c17_damage_tier", function()
	local entIndex = net.ReadUInt(16)
	local tier     = net.ReadUInt(2)
	local ent      = Entity(entIndex)
	local state    = PlaneStates[entIndex]
	if not state then state = {tier=0, particles={}, nextBurst=0} PlaneStates[entIndex] = state end
	if state.tier == tier then return end
	if IsValid(ent) then
		ApplyFlameParticles(ent, state, tier)
		if tier > 0 then SpawnBurstFX(ent, TIER_BURST_COUNT[tier] or 1, tier) end
	else state.tier = tier state.pendingApply = true end
end )

hook.Add( "Think", "bombin_c17_damage_fx", function()
	local ct = CurTime()
	for entIndex, state in pairs(PlaneStates) do
		local ent = Entity(entIndex)
		if not IsValid(ent) then StopParticles(state) PlaneStates[entIndex] = nil
		else
			if state.pendingApply then state.pendingApply = false ApplyFlameParticles(ent, state, state.tier) end
			if state.tier > 0 then
				local pos, ang = ent:GetPos(), ent:GetAngles()
				local offsets = TIER_OFFSETS[state.tier]
				for i, p in ipairs(state.particles) do
					if IsValid(p) and offsets[i] then p:SetControlPoint(0, LocalToWorld(offsets[i], Angle(0,0,0), pos, ang)) end
				end
				if ct >= state.nextBurst then
					SpawnBurstFX(ent, TIER_BURST_COUNT[state.tier] or 1, state.tier)
					state.nextBurst = ct + (TIER_BURST_DELAY[state.tier] or 4)
				end
			end
		end
	end
end )
