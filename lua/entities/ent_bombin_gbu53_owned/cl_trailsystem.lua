-- ============================================================
-- GBU-53 OWNED TRAIL SYSTEM
-- Identical geometry to ent_bombin_gbu53, but namespaced so
-- the owned and standalone variants never share trail tables.
-- Three beam contrails: centre-rear + two fin-tips.
-- Runs entirely client-side; no net messages needed.
-- Only active after EngineOn NWBool is true.
-- ============================================================

local TRAIL_LIFETIME  = 5
local SAMPLE_RATE     = 0.025
local TRAIL_WIDTH_CTR = 6
local TRAIL_WIDTH_TIP = 3
local TRAIL_ALPHA     = 180
local TRAIL_TEX       = "trails/smoke"

local TRAIL_OFFSETS = {
	Vector( -60,  20,  0 ),
	Vector( -50,   0,  0 ),
	Vector( -60, -20,  0 ),
}

local GBU53OwnedTrails = {}

hook.Add("Think", "bombin_gbu53owned_trail_sample", function()
	local now = CurTime()
	for entIdx, trailData in pairs(GBU53OwnedTrails) do
		local ent = Entity(entIdx)
		if not IsValid(ent) then
			GBU53OwnedTrails[entIdx] = nil
			continue
		end

		-- Only sample when engine is live
		if not ent:GetNWBool("EngineOn", false) then continue end

		if (trailData.nextSample or 0) > now then continue end
		trailData.nextSample = now + SAMPLE_RATE

		local pos = ent:GetPos()
		local ang = ent:GetAngles()
		for i = 1, 3 do
			local worldOffset = LocalToWorld(TRAIL_OFFSETS[i], Angle(0,0,0), pos, ang)
			table.insert(trailData[i], { pos = worldOffset, t = now })
		end
	end
end)

hook.Add("PostDrawTranslucentRenderables", "bombin_gbu53owned_trail_draw", function()
	local now = CurTime()
	for entIdx, trailData in pairs(GBU53OwnedTrails) do
		local ent = Entity(entIdx)
		if not IsValid(ent) then continue end

		for i = 1, 3 do
			local samples = trailData[i]
			while samples[1] and (now - samples[1].t) > TRAIL_LIFETIME do
				table.remove(samples, 1)
			end
			if #samples < 2 then continue end

			local width = (i == 1) and TRAIL_WIDTH_CTR or TRAIL_WIDTH_TIP
			render.SetMaterial(Material(TRAIL_TEX))
			render.StartBeam(#samples)
			for j, s in ipairs(samples) do
				local age   = now - s.t
				local frac  = 1 - (age / TRAIL_LIFETIME)
				local alpha = frac * frac * TRAIL_ALPHA
				render.AddBeam(s.pos, width * frac, j / #samples, ColorAlpha(color_white, alpha))
			end
			render.EndBeam()
		end
	end
end)

function GBU53OwnedTrail_Register(ent)
	if not IsValid(ent) then return end
	local idx = ent:EntIndex()
	if GBU53OwnedTrails[idx] then return end
	GBU53OwnedTrails[idx] = {
		[1] = {}, [2] = {}, [3] = {},
		nextSample = CurTime(),
	}
end

function GBU53OwnedTrail_Unregister(ent)
	if not IsValid(ent) then return end
	GBU53OwnedTrails[ent:EntIndex()] = nil
end
