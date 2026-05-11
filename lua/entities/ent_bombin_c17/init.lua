-- ============================================================
-- ent_bombin_c17  --  SERVER
-- Manages the CargoDoorOpen NWBool that drives the client-side
-- cargo door bone animation.
-- ============================================================

AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "cl_trailsystem.lua" )
AddCSLuaFile( "shared.lua" )
include( "shared.lua" )

util.AddNetworkString( "bombin_c17_cargo_door" )

function ENT:Initialize()
	self:SetNWBool( "CargoDoorOpen", false )
end

-- Net receiver: GBU-53 tells this plane to open or close its doors.
-- Message carries: UInt(16) plane EntIndex, Bool open/close.
net.Receive( "bombin_c17_cargo_door", function( len, ply )
	-- This message is sent server->server via net.SendToServer from within
	-- the GBU-53 server code, so ply will be nil.  We re-use the same
	-- net string for the server-internal call pattern: the GBU-53 init.lua
	-- calls the helper C17_SetCargoDoor( planeEnt, bool ) directly instead
	-- of going through the network, so this receiver is a safety fallback
	-- and is not used in the primary path.
end )

function ENT:OnRemove()
	-- Nothing to clean up; NW vars are removed with the entity.
end
