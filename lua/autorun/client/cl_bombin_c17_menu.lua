-- ============================================================
--  C-17 Globemaster III Control Panel
-- ============================================================

if not CLIENT then return end

local col_bg_panel      = Color(0,   0,   0,   255)
local col_section_title = Color(210, 210, 210, 255)
local col_accent        = Color(0,   180, 255, 255)  -- blue for C-17

local SECTION_COLORS = {
    ["NPC Call Settings"] = Color(60,  120, 200, 120),
    ["C-17 Behaviour"]    = Color(30,  100, 180, 120),
    ["Debug"]             = Color(100, 100, 110, 120),
    ["Manual Spawn"]      = Color(140, 80,  200, 120),
}

local function AddColoredCategory(panel, text)
    local bgColor = SECTION_COLORS[text]
    if not bgColor then panel:Help(text) return end
    local cat = vgui.Create("DPanel", panel)
    cat:SetTall(24)
    cat:Dock(TOP)
    cat:DockMargin(0, 8, 0, 4)
    cat.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, bgColor)
        surface.SetDrawColor(0, 0, 0, 35)
        surface.DrawOutlinedRect(0, 0, w, h)
        local textColor = (bgColor.r + bgColor.g + bgColor.b < 200)
            and Color(255,255,255,255) or Color(0,0,0,255)
        draw.SimpleText(text, "DermaDefaultBold", 8, h/2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    panel:AddItem(cat)
end

concommand.Add("bombin_spawnc17", function()
    if not IsValid(LocalPlayer()) then return end
    net.Start("BombinC17_ManualSpawn")
    net.SendToServer()
end)

hook.Add("AddToolMenuTabs", "BombinC17_Tab", function()
    spawnmenu.AddToolTab("Bombin Support", "Bombin Support", "icon16/bomb.png")
end)

hook.Add("AddToolMenuCategories", "BombinC17_Categories", function()
    spawnmenu.AddToolCategory("Bombin Support", "C-17 Globemaster III", "C-17 Globemaster III")
end)

hook.Add("PopulateToolMenu", "BombinC17_ToolMenu", function()
    spawnmenu.AddToolMenuOption(
        "Bombin Support",
        "C-17 Globemaster III",
        "bombin_c17_settings",
        "C-17 Globemaster III Settings",
        "", "",
        function(panel)
            panel:ClearControls()

            local header = vgui.Create("DPanel", panel)
            header:SetTall(32)
            header:Dock(TOP)
            header:DockMargin(0, 0, 0, 8)
            header.Paint = function(self, w, h)
                draw.RoundedBox(4, 0, 0, w, h, col_bg_panel)
                surface.SetDrawColor(col_accent)
                surface.DrawRect(0, h-2, w, 2)
                draw.SimpleText("C-17 Globemaster III Controller", "DermaLarge",
                    8, h/2, col_section_title, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            panel:AddItem(header)

            -- NPC Call Settings
            AddColoredCategory(panel, "NPC Call Settings")
            panel:CheckBox("Enable NPC calls",           "npc_bombinc17_enabled")
            panel:NumSlider("Call chance (per check)",   "npc_bombinc17_chance",   0,    1,    2)
            panel:NumSlider("Check interval (seconds)",  "npc_bombinc17_interval", 1,    60,   0)
            panel:NumSlider("NPC cooldown (seconds)",    "npc_bombinc17_cooldown", 10,   300,  0)
            panel:NumSlider("Min call distance (HU)",    "npc_bombinc17_min_dist", 100,  1000, 0)
            panel:NumSlider("Max call distance (HU)",    "npc_bombinc17_max_dist", 500,  8000, 0)
            panel:NumSlider("Flare -> arrival delay (s)", "npc_bombinc17_delay",    1,    30,   0)

            -- C-17 Behaviour
            AddColoredCategory(panel, "C-17 Behaviour")
            panel:NumSlider("Lifetime (seconds)",         "npc_bombinc17_lifetime", 10,   600,  0)
            panel:NumSlider("Forward speed (HU/s)",       "npc_bombinc17_speed",    50,   800,  0)
            panel:NumSlider("Orbit radius (HU)",          "npc_bombinc17_radius",   500,  20000, 0)
            panel:NumSlider("Altitude above ground (HU)", "npc_bombinc17_height",   1000, 30000, 0)

            -- Debug
            AddColoredCategory(panel, "Debug")
            panel:CheckBox("Enable debug prints", "npc_bombinc17_announce")

            -- Manual Spawn
            AddColoredCategory(panel, "Manual Spawn")
            panel:Button("Spawn C-17 now", "bombin_spawnc17")
        end
    )
end)
