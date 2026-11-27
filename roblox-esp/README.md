# Roblox ESP Overlay

A configurable ESP overlay **for your own Roblox experience**. Use it for admin
and moderator tools, spectator or killcam views, team awareness, a "scan"
ability, or objective and NPC markers. It's built from standard engine APIs
(ScreenGui frames, `Highlight`, `Camera:WorldToViewportPoint`) and runs as a
normal LocalScript. A server script decides who gets it.

## Features

| | |
|---|---|
| **Boxes** | Corner or full, 1px outline, optional fill. Humanoid boxes stay upright, face the camera and ignore accessories, so they don't wobble or balloon. |
| **Labels** | Display name / username / both, distance (studs or meters), held tool. |
| **Health bar** | Smoothly animated, green → yellow → red, with a numeric readout when damaged. |
| **Skeleton** | R15 (14 bones) and R6 (10 bones). Follows scaled rigs. |
| **Tracers** | From the bottom, center, top or mouse. |
| **Chams** | `Highlight`-based, visible through walls or occluded. The closest targets get the engine's 31 Highlight slots. |
| **Off-screen arrows** | A compass ring around the crosshair for targets you can't see on screen. |
| **Line of sight** | Throttled raycasts dim targets that are behind walls. |
| **Distance fade** | Visuals fade out toward `MaxDistance`. |
| **Team logic** | Hide teammates, use team colors, color friends separately. |
| **Tagged targets** | Any Model or BasePart tagged `ESPTarget` (NPCs, bosses, objectives, loot). |
| **Settings menu** | Draggable and animated, with toggles, choices and sliders. Changes apply live. Touch devices get a floating button. |

### Performance

- One `BindToRenderStep` callback, bound right after the camera, so the overlay never lags a frame behind.
- Every GUI object is created once per target and reused. Setters skip writes when the value hasn't changed.
- Part lookups, bounds and tool names refresh at 2 Hz. Visibility rays run at about 8 Hz per target, and the chams/draw-order pass at 4 Hz.
- Each target updates inside a `pcall`, so one bad model can't break the whole overlay.
- Handles respawns, players leaving and StreamingEnabled. Characters are also re-checked once a second.

## Install

### With Rojo

```bash
rojo serve      # in this folder, then connect from the Rojo Studio plugin
```

### By hand in Studio

Build this hierarchy and paste each file's contents in:

```
StarterPlayer
└─ StarterPlayerScripts
   └─ ESPClient          (LocalScript)  ← src/client/ESPClient/init.client.luau
      ├─ Config          (ModuleScript) ← Config.luau
      ├─ Controller      (ModuleScript) ← Controller.luau
      ├─ Draw            (ModuleScript) ← Draw.luau
      ├─ Menu            (ModuleScript) ← Menu.luau
      ├─ Rig             (ModuleScript) ← Rig.luau
      └─ Target          (ModuleScript) ← Target.luau
ServerScriptService
└─ ESPPermissions        (Script)       ← src/server/ESPPermissions.server.luau
```

Module names must match exactly, because the scripts `require` them by name.

## Who gets the overlay

`ESPPermissions` sets a `ESPAllowed` attribute on each player. The client
starts or stops the overlay whenever that attribute changes. By default the
following players get it:

- everyone during **Studio playtests** (`AllowInStudio`)
- the **experience owner** (`AllowOwner`)
- group members at rank **254 or higher** when the experience is group-owned (`Group`)
- any accounts listed in `UserIds`

Set `AllowEveryone = true` to give it to everyone, which suits a game where ESP
is part of normal gameplay. Any server code can also grant or revoke it at
runtime:

```lua
player:SetAttribute("ESPAllowed", true)  -- e.g. became a spectator, used a scan ability
player:SetAttribute("ESPAllowed", false)
```

> This is a UX gate, not anti-cheat. Replicated character positions already
> exist on every client; the gate only controls who sees this overlay.

## Controls

| Input | Action |
|---|---|
| `RightControl` | Open or close the settings menu |
| `F4` | Turn the overlay on or off |
| Touch: **ESP** button | Open or close the settings menu |

Keys are set in `Config.MenuKey` and `Config.ToggleKey`. Avoid the Shift keys,
because Roblox binds both of them to Shift Lock.

## Tagging NPCs and objects

Tag any Model or BasePart with **`ESPTarget`** (the tag is set in `Config.Tag`)
using the Tag Editor or code:

```lua
local CollectionService = game:GetService("CollectionService")
CollectionService:AddTag(workspace.Boss, "ESPTarget")

-- optional customisation
workspace.Boss:SetAttribute("ESPName", "The Warden")
workspace.Boss:SetAttribute("ESPColor", Color3.fromRGB(255, 120, 40))

-- non-Humanoid targets can show a health bar too
workspace.Generator:SetAttribute("Health", 350)
workspace.Generator:SetAttribute("MaxHealth", 500)
```

Models with a Humanoid get the full treatment: body box, skeleton and health
bar. Other models use their real bounding box.

## Configuration

Everything lives in `Config.luau` and can be changed at runtime. The menu
writes straight into the same table. After changing values from your own code,
call `controller:Apply()`. The main options are:

| Key | Default | Notes |
|---|---|---|
| `MaxDistance` | `1500` | Studs. Targets farther away aren't drawn. |
| `TeamCheck` / `UseTeamColors` | `false` / `true` | |
| `Box.Style` | `"Corner"` | `"Corner"` or `"Full"` |
| `Name.Mode` | `"DisplayName"` | `"DisplayName"`, `"Username"` or `"Both"` |
| `Distance.Unit` | `"Studs"` | `"Studs"` or `"Meters"` (1 stud = 0.28 m) |
| `Tracer.Origin` | `"Bottom"` | `"Bottom"`, `"Center"`, `"Top"` or `"Mouse"` |
| `Chams.MaxCount` | `31` | Roblox renders at most 31 Highlights per client. Lower it if your game uses its own. |
| `Visibility.Interval` | `0.12` | Seconds between line-of-sight rays per target |
| `Colors.*` | | Enemy, ally, friend, tagged, text, health gradient |

## Notes and limits

- Highlights are client-side children of the target model and are never replicated.
- The 31-Highlight cap is shared with any Highlights your game already uses.
- Hundreds of tagged objects work, but each one costs projection work every frame. Tag what matters.
