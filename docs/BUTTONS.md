# What a json GUI button needs

Everything below is checked against the installed game, with the file and line
it came from. Three versions have been spent on "the buttons dont work" and each
fix was a real bug that turned out not to be the whole story, so this file
separates **confirmed** from **not yet known**, and says how the unknown parts
get settled.

Run `/guitest` in game — four times — to settle them. See the end of this file.

---

## Confirmed: the widget tree

Taken from `Data/Gui/JsonGuis/PopUp_YN.gui`, which is the engine's own working
yes/no dialog, and matched property for property.

**The root**

```lua
{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
  Anchor = "Center", InheritsPick = true,
  NeedKey = false, NeedMouse = false,
  x = 0, y = 0, width = W, height = H, Childs = { ... } }
```

- `Anchor = "Center"` is the only anchor value that works. `"TopRight"` is not
  accepted — to place a panel in a corner, size the root to the canvas and put
  the content inside it, or move the root (see *Coordinates* below).
- `InheritsPick = true` and `NeedMouse = false` on the root are what let clicks
  reach the children. Vanilla sets both.

**A button**

```lua
{ Name = "Yes", Type = "Button", Skin = "PrimaryButton",
  Caption = "YES", FontName = "SM_ButtonLarge", TextAlign = "Center",
  NeedKey = true, NeedMouse = true,
  x = 66, y = 248, width = 100, height = 34, Childs = {} }
```

- `Type` must be exactly `"Button"`.
- `NeedKey` and `NeedMouse` must both be **true**. A decorative rectangle behind
  the buttons must have them **false**, or it eats the clicks.
- `Childs = {}` must exist even when empty. Vanilla writes it on every widget.

**Skins that exist** (verified in `Data/Gui/`): `PrimaryButton`,
`SecondaryButton`, `StyledButtonLarge`, `UpgradeButton`, `PanelEmpty`,
`WhiteSkin`, `TextBox`, `BackgroundPromptNarrow`, `EditBoxEmpty`.

`UpgradeButton` is a **progress bar**. Give it a Caption and it silently draws
none — it reads as a broken widget rather than a styling mistake. Measured from
a screenshot: two host menu entries were there and clickable but unlabelled.

**Fonts** must exist *and* cover every letter in the caption. A name that does
not exist still draws, via fallback, and logs a MyGUI error plus a full Lua
traceback **on every redraw**. See the font section of `CLAUDE.md`.

---

## Confirmed: the callback

```lua
button.onClick = "cl_onSomething"        -- a method NAME, as a string
button.onClickData = { action = "city" } -- optional
root.onClose = "cl_onSomethingClosed"    -- optional, on the ROOT only
```

**The signature depends on whether `onClickData` is set.**

| | signature | vanilla example |
|---|---|---|
| without `onClickData` | `( self, widgetName )` | `ElectricEngine.cl_onBearingSettingClick`, line 580 |
| with `onClickData` | `( self, widgetName, data )` | `HideoutTrader.cl_selectTrade`, line 1536 |

Getting this wrong hands the handler the widget's **name** where it expects the
data table, so `data.action` is always nil and no branch ever matches. That was a
real bug here.

`onClose` fires when the panel goes away — including when *we* close it. Its
handler must **only drop the handle**. Vanilla:

```lua
function ElectricEngine.cl_onBearingSettingsClose( self )
    self.bearingModeGui = nil          -- and nothing else
end
```

---

## Confirmed: the lifecycle

```lua
gui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
gui:render( tree )      -- render() IS the show
gui:close()             -- close() IS the hide
```

There is no `open()` and no `destroy()`. Measured twice, as
`Unknown member 'destroy' in userdata` and then `Unknown member 'open'` — and the
second one threw on every render, which is what shut the panel again on every
click.

Re-render to update: build a new tree and `render()` it into the same GUI.
Closing and recreating on every click throws the panel away and flickers.

---

## Confirmed, and the one that cost the most: **never close from inside a callback**

```lua
function Game.cl_onMenuClick( self, widgetName, data )
    self:cl_closeMenu()                                  -- destroys the widget
    self.network:sendToServer( "sv_n_menuOpen", ... )    -- NEVER RUNS
end
```

`close()` destroys the widget whose `onClick` is **currently on the Lua stack**
and the engine tears the callback down with it. Every statement after the close
is dead code. **No Lua error is raised.** The only trace is an engine assert:

```
ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716
```

Vanilla always does the work first and closes last —
`CreativePlayer.cl_e_unstuckYes` sends to the server, *then* closes
(`Data/Scripts/game/CreativePlayer.lua:48`).

We do better than remembering: a close is **queued and drained on the next tick**
(`Game.cl_closeLater` / `cl_drainCloses`). A widget cannot be destroyed while its
own callback is running if the close happens after that callback has returned.
`dev/test_logic.py` fails if any `cl_on*` handler calls a closer directly.

---

## Coordinates

- `sm.jsonGui.getViewSize()` is the **canvas** widget coordinates are measured
  in. `sm.gui.getScreenSize()` is the window. They are not the same number and
  the mod was guessing which one panels were in.
- The game ships GUI skins for four reference resolutions — `1280x720`,
  `1920x1080`, `2560x1440`, `3840x2160` (`Data/Gui/Resolutions/`) — so the canvas
  is one of those, not the monitor's actual size.
- **A root widget's `x`/`y` is its CENTRE, measured from the centre of the
  canvas, with +y downwards.** Derived from vanilla's status panel:

  ```lua
  root.x = math.floor( -screenWidth / 2 + root.width * 0.5 )    -- flush left
  root.y = math.floor(  screenHeight / 2 - root.height * 0.5 )  -- flush bottom
  ```

  So a top-right panel with a margin is
  `x = W/2 - width/2 - margin`, `y = -H/2 + height/2 + margin`.
- A child's `x`/`y` is a normal top-left offset inside its parent.

---

## NOT YET KNOWN — and this is what `/guitest` settles

Two things about our GUIs that **no vanilla GUI does**:

1. **Our callbacks live on the Game script.** Every `onClick` in the base game
   belongs to a player script, an interactable or a character. Not one belongs to
   a Game script. A Game script is already special — it has no world — so "it
   also does not receive GUI callbacks" is exactly the sort of thing this engine
   does without saying so.

2. **Our widget trees are built in Lua.** Every vanilla jsonGui is
   `sm.json.open()`ed from a `.gui` file and then indexed. Nothing in the base
   game hands `render()` a table it built itself.

### How to settle it

Type `/guitest` in game. A small panel appears saying which test it is. Press
both buttons on it. If the panel rewrites itself to say **CLICK RECEIVED**, that
arrangement works. Then type `/guitest` again for the next test.

| test | owner | tree | what it tells us |
|---|---|---|---|
| 1 | Game script | built in Lua | exactly what the mod ships today |
| 2 | Game script | vanilla's `.gui` file | if 1 fails and 2 works, the **tree** is the problem |
| 3 | Player script | built in Lua | if 1 fails and 3 works, the **Game script** is the problem |
| 4 | Player script | vanilla's `.gui` file | fully vanilla. If this fails, nothing here works |

Each panel also prints the canvas and screen sizes, and every press is written to
`Logs/game-*.log` as `[ServerWorks] guitest: ...`.

**Test 1 also has two buttons for a reason**: one carries `onClickData` and one
does not. If only the second works, a data table is what breaks dispatch.

### Separately: the real menu is traced

Clicking anything on `/menu` now writes four lines. Whichever is the last one
printed is where it stops:

```
[ServerWorks] gui 1/4 menu click: widget=B6 data=table
[ServerWorks] gui 2/4 server got menu open: what=city host=true
[ServerWorks] gui 3/4 sending the city panel
[ServerWorks] gui 4/4 client rendering the city panel
```

- Nothing at all → the click never reached Lua. It is the widget tree or the
  owning script, and `/guitest` says which.
- 1 but not 2 → the client-to-server hop.
- 2 but not 3 → the host check, or the branch.
- 3 but not 4 → the server-to-client hop, most likely the payload.
- All four → the panel is being built and rendered, and the problem is that it
  is not visible: wrong coordinates, wrong layer, or drawn behind something.
