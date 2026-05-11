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

-- Bone names indexed to match DOOR_TARGETS_OPEN.
local DOOR_BONES = {
	"c17.ramp_2_move",
	"c17.ramp_1_move",
	"c17.ramp_1b_move",
}

function ENT:Initialize()
	self:SetBodygroup( 1, 1 )
	self._FanAngle = 0

	-- _DoorAngles[i]: current Y angle of bone i
	-- _DoorStage:     which bone is currently animating (see encoding above)
	-- _DoorWasOpen:   previous wantOpen value, used to detect transitions
	self._DoorAngles  = { 0, 0, 0 }
	self._DoorStage   = 0
	self._DoorWasOpen = false
end

-- ============================================================
-- CARGO DOOR ANIMATOR
-- Called every Draw() frame with dt = FrameTime().
-- ============================================================
function ENT:UpdateCargoDoors( dt )
	local wantOpen = self:GetNWBool( "CargoDoorOpen", false )

	-- ── Transition: closed/closing → opening ────────────────
	if wantOpen and not self._DoorWasOpen then
		self._DoorWasOpen = true

		if self._DoorStage == 0 then
			-- Fully closed: start from bone 1.
			self._DoorStage = 1
		elseif self._DoorStage < 0 then
			-- Mid-close: resume opening from the bone that is currently moving.
			-- math.abs converts e.g. -2 → 2 so we continue from that bone.
			self._DoorStage = math.abs( self._DoorStage )
		end
		-- If _DoorStage > 0 we were already opening; leave it as-is.
	end

	-- ── Transition: opening/open → closing ──────────────────
	if not wantOpen and self._DoorWasOpen then
		self._DoorWasOpen = false

		if self._DoorStage == 4 or self._DoorStage > 0 then
			-- Find the highest bone that is not already at 0 and start closing from there.
			local startClose = 0
			for i = 3, 1, -1 do
				if self._DoorAngles[i] > DOOR_THRESHOLD then
					startClose = -i
					break
				end
			end
			self._DoorStage = startClose  -- 0 if all bones already at rest
		end
		-- If _DoorStage < 0 we were already closing; leave it as-is.
	end

	-- Nothing to animate when fully closed or fully open.
	if self._DoorStage == 0 or self._DoorStage == 4 then return end

	local step = DOOR_SPEED * dt

	if self._DoorStage > 0 then
		-- ── OPENING ─────────────────────────────────────────────
		local i      = self._DoorStage
		local target = DOOR_TARGETS_OPEN[i]
		local cur    = self._DoorAngles[i]
		local diff   = target - cur

		if diff <= DOOR_THRESHOLD then
			-- Snap to target and advance to next stage.
			self._DoorAngles[i] = target
			self._DoorStage     = ( i < 3 ) and ( i + 1 ) or 4
		else
			self._DoorAngles[i] = cur + math.min( step, diff )
		end

	else
		-- ── CLOSING ─────────────────────────────────────────────
		local i   = math.abs( self._DoorStage )   -- 3, 2, or 1
		local cur = self._DoorAngles[i]

		if cur <= DOOR_THRESHOLD then
			-- Snap to 0 and advance to the previous bone.
			self._DoorAngles[i] = 0
			self._DoorStage     = ( i > 1 ) and -( i - 1 ) or 0
		else
			self._DoorAngles[i] = cur - math.min( step, cur )
		end
	end
end

function ENT:Draw()
	-- --------------------------------------------------------
	-- Roll sign fix: server encodes Angle( -SmoothedRoll, yaw+offset, -SmoothedPitch )
	-- so .p == -SmoothedRoll already.  No second negation.
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
	-- Cargo door animation
	-- --------------------------------------------------------
	self:UpdateCargoDoors( FrameTime() )

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
