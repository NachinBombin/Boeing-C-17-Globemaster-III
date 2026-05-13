include( "shared.lua" )
include( "cl_trailsystem.lua" )

-- Engine sound managed client-side. "sound/" prefix must NOT be used with CreateSound.
local ENGINE_LOOP_SOUND = "b52/b52.wav"

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
local DOOR_SPEED        = 28
local DOOR_THRESHOLD    = 1.0
local DOOR_TARGETS_OPEN = { 28, 28, 100 }
local DOOR_BONES = {
	"c17.ramp_2_move",
	"c17.ramp_1_move",
	"c17.ramp_1b_move",
}

-- ============================================================
-- CARGO LIGHT CONSTANTS
-- ============================================================
local CARGO_LIGHT_LOCAL    = Vector( -200, 0, -80 )
local CARGO_LIGHT_RADIUS   = 1400
local CARGO_LIGHT_DECAY    = 1200
local CARGO_LIGHT_MIN_BRIG = 0.35
local CARGO_LIGHT_MAX_BRIG = 1.0
local CARGO_LIGHT_PULSE_HZ = 0.6

-- ============================================================
-- NAV / STROBE LIGHT CONSTANTS
-- ============================================================
local NAV_BLINK_ON   = 0.12
local NAV_BLINK_OFF  = 0.85
local NAV_RADIUS     = 80
local NAV_BRIGHTNESS = 14
local NAV_DECAY      = 600

local NAV_LIGHTS = {
	{ Vector(   0, -570, -15 ), 255,   0,   0, 0, 0.00 },
	{ Vector(   0,  570, -15 ),   0, 255,   0, 1, 0.32 },
	{ Vector( 350,    0, 120 ), 255, 255, 255, 2, 0.64 },
	{ Vector(-350,    0, -55 ), 255,   0,   0, 3, 0.16 },
}

-- ============================================================
-- CONDENSATION VAPOR CONSTANTS
-- ============================================================
local VAPOR_DURATION   = 1.5
local VAPOR_LOCAL      = Vector( -200, 0, -90 )
local VAPOR_PER_FRAME  = 6
local VAPOR_LIFETIME   = 0.9
local VAPOR_SIZE_START = 18
local VAPOR_SIZE_END   = 55
local VAPOR_SPEED      = 90
local VAPOR_SPRITE     = "particle/particle_smokegrenade"

function ENT:Initialize()
	self:SetBodygroup( 1, 1 )
	self._FanAngle = 0

	self._DoorAngles  = { 0, 0, 0 }
	self._DoorStage   = 0
	self._DoorWasOpen = false

	self._VaporEmitter = nil
	self._VaporUntil   = 0

	-- Client-side engine sound state
	self._EngineSound   = nil
	self._EnginePlaying = false
end

-- ============================================================
-- CARGO DOOR ANIMATOR
-- ============================================================
function ENT:UpdateCargoDoors( dt )
	local wantOpen = self:GetNWBool( "CargoDoorOpen", false )

	if wantOpen and not self._DoorWasOpen then
		self._DoorWasOpen = true
		if self._DoorStage == 0 then
			self._DoorStage = 1
		elseif self._DoorStage < 0 then
			self._DoorStage = math.abs( self._DoorStage )
		end
		self:StartVapor()
	end

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
	end

	if self._DoorStage == 0 or self._DoorStage == 4 then return end

	local step = DOOR_SPEED * dt
	if self._DoorStage > 0 then
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
function ENT:UpdateCargoLight()
	if not self:GetNWBool( "CargoDoorOpen", false ) then return end

	local dl = DynamicLight( self:EntIndex() + 4096 )
	if not dl then return end

	local t      = CurTime() * CARGO_LIGHT_PULSE_HZ * math.pi * 2
	local frac   = ( math.sin( t ) + 1 ) * 0.5
	local bright = CARGO_LIGHT_MIN_BRIG + frac * ( CARGO_LIGHT_MAX_BRIG - CARGO_LIGHT_MIN_BRIG )

	local worldPos = self:LocalToWorld( CARGO_LIGHT_LOCAL )
	dl.pos        = worldPos
	dl.r          = 255
	dl.g          = 20
	dl.b          = 10
	dl.brightness = bright * 10
	dl.decay      = CARGO_LIGHT_DECAY
	dl.size       = CARGO_LIGHT_RADIUS
	dl.dietime    = CurTime() + 0.1
end

-- ============================================================
-- NAV / STROBE LIGHTS
-- ============================================================
function ENT:UpdateNavLights()
	if not self:GetNWBool( "CargoDoorOpen", false ) then return end

	local ct      = CurTime()
	local period  = NAV_BLINK_ON + NAV_BLINK_OFF
	local base    = self:EntIndex() * 10

	for _, light in ipairs( NAV_LIGHTS ) do
		local lpos, r, g, b, slot, phase = light[1], light[2], light[3], light[4], light[5], light[6]

		local t    = ( ct + phase * period ) % period
		local isOn = ( t < NAV_BLINK_ON )

		if isOn then
			local dl = DynamicLight( base + slot )
			if dl then
				dl.pos        = self:LocalToWorld( lpos )
				dl.r          = r
				dl.g          = g
				dl.b          = b
				dl.brightness = NAV_BRIGHTNESS
				dl.decay      = NAV_DECAY
				dl.size       = NAV_RADIUS
				dl.dietime    = ct + 0.2
			end
		end
	end
end

-- ============================================================
-- CONDENSATION VAPOR
-- ============================================================
function ENT:StartVapor()
	if self._VaporEmitter then
		self._VaporEmitter:Finish()
		self._VaporEmitter = nil
	end

	local worldPos     = self:LocalToWorld( VAPOR_LOCAL )
	self._VaporEmitter = ParticleEmitter( worldPos, true )
	self._VaporUntil   = CurTime() + VAPOR_DURATION
end

function ENT:UpdateVapor()
	if not self._VaporEmitter then return end

	local ct = CurTime()
	if ct >= self._VaporUntil then
		self._VaporEmitter:Finish()
		self._VaporEmitter = nil
		return
	end

	local worldPos = self:LocalToWorld( VAPOR_LOCAL )
	local rearDir  = self:LocalToWorldAngles( Angle( 5, 180, 0 ) ):Forward()

	for _ = 1, VAPOR_PER_FRAME do
		local p = self._VaporEmitter:Add( VAPOR_SPRITE, worldPos )
		if p then
			local shade = math.random( 210, 255 )
			p:SetColor( shade, shade, shade )
			p:SetStartAlpha( math.random( 160, 200 ) )
			p:SetEndAlpha( 0 )
			p:SetStartSize( VAPOR_SIZE_START + math.Rand( -4, 4 ) )
			p:SetEndSize( VAPOR_SIZE_END + math.Rand( -8, 8 ) )
			p:SetLifeTime( 0 )
			p:SetDieTime( VAPOR_LIFETIME + math.Rand( -0.2, 0.3 ) )
			p:SetLighting( false )
			local scatter = Vector(
				math.Rand( -25, 25 ),
				math.Rand( -25, 25 ),
				math.Rand(  -8, 15 )
			)
			p:SetVelocity( rearDir * VAPOR_SPEED + scatter )
			p:SetGravity( Vector( 0, 0, 18 ) )
			p:SetRoll( math.Rand( 0, 360 ) )
			p:SetRollDelta( math.Rand( -1.5, 1.5 ) )
		end
	end
end

-- ============================================================
-- ENGINE SOUND (CLIENT)
-- CreateSound path is relative to sound/ — no "sound/" prefix.
-- _EnginePlaying is only set true when CreateSound succeeds,
-- so a missing/unprecached file will retry next Think tick.
-- ============================================================
function ENT:Think()
	local destroyed = self:GetNWBool( "Destroyed", false )

	if not destroyed then
		if not self._EnginePlaying then
			local snd = CreateSound( self, ENGINE_LOOP_SOUND )
			if snd then
				snd:SetSoundLevel( 85 )
				snd:ChangePitch( 95, 0 )
				snd:ChangeVolume( 0.9, 0 )
				snd:Play()
				self._EngineSound   = snd
				self._EnginePlaying = true
			end
		end
		-- Keep-alive: CSoundPatch stops automatically when the
		-- engine goes idle; re-call Play() to keep it looping.
		if self._EngineSound and not self._EngineSound:IsPlaying() then
			self._EngineSound:Play()
		end
	else
		if self._EngineSound then
			self._EngineSound:FadeOut( 1.5 )
			self._EngineSound   = nil
			self._EnginePlaying = false
		end
	end
end

function ENT:OnRemove()
	if self._EngineSound then
		self._EngineSound:FadeOut( 0.5 )
		self._EngineSound   = nil
		self._EnginePlaying = false
	end
end

-- ============================================================
-- DRAW
-- ============================================================
function ENT:Draw()
	local roll = self:GetAngles().p

	self._FanAngle = ( self._FanAngle or 0 ) + FAN_RPM * FrameTime()
	if self._FanAngle > 360 then self._FanAngle = self._FanAngle - 360 end
	local fanZ = self._FanAngle

	local rollNorm  = math.Clamp( roll / ROLL_MAX, -1, 1 )
	local tLeft     = math.Clamp( -rollNorm, 0, 1 )
	local tRight    = math.Clamp(  rollNorm, 0, 1 )
	local flapLeft  = Lerp( tLeft,  FLAP_RETRACTED, FLAP_EXTENDED )
	local flapRight = Lerp( tRight, FLAP_RETRACTED, FLAP_EXTENDED )

	self:UpdateCargoDoors( FrameTime() )
	self:UpdateCargoLight()
	self:UpdateNavLights()
	self:UpdateVapor()

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
