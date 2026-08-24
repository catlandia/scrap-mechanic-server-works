# What a json GUI button needs

Everything below is checked against the installed game, with the file and line
it came from. Three versions have been spent on "the buttons dont work" and each
fix was a real bug that turned out not to be the whole story, so this file
is the checklist to work through before touching a panel.

**They work.** Settled in game on 2026-08-24 — see *SETTLED* below for what was
actually wrong. `/guitest` is still in the mod for re-checking after a game
update.

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

## There are TWO gui systems, and they are not interchangeable

This was found late and it may be the whole answer.

| | `sm.jsonGui.createGui` | `sm.gui.createGuiFromLayout` |
|---|---|---|
| content | a widget **tree**, built in Lua or read from a `.gui` file | a MyGUI **`.layout`** file |
| show | `render( tree )` | `open()` |
| hide | `close()` | `close()` |
| buttons | `widget.onClick = "name"` | `gui:setButtonCallback( "Yes", "name" )` |
| callback | `( self, widgetName )`, or `( self, widgetName, data )` with `onClickData` | `( self, buttonName )` |
| text | set `Caption` in the tree, re-render | `gui:setText( "Title", "..." )` |
| close hook | `root.onClose = "name"` | `gui:setOnCloseCallback( "name" )` |
| used by a **Game script** in vanilla | never | **yes** — `CreativeGame.lua:283` |

Vanilla's creative "clear everything?" dialog is the second kind, owned by a Game
script, and its buttons work:

```lua
self.cl.confirmClearGui = sm.gui.createGuiFromLayout(
    "$GAME_DATA/Gui/Layouts/PopUp/PopUp_YN.layout" )
self.cl.confirmClearGui:setButtonCallback( "Yes", "cl_onClearConfirmButtonClick" )
self.cl.confirmClearGui:setText( "Title", "#{MENU_YN_TITLE_ARE_YOU_SURE}" )
self.cl.confirmClearGui:open()
```

`setButtonCallback` is used 37 times across the base game. `sm.jsonGui` is the
newer and much freer system — an arbitrary widget tree instead of a fixed layout
file, which is what makes a live city map possible — but **whether it dispatches
clicks to a Game script has never been established.** That is `/guitest` test 5.

Note that `CreativeGame.cl_onClearConfirmButtonClick` closes its GUI and *then*
sends to the server, which is the opposite of the jsonGui rule below. The two
systems do not have to behave the same way here, and only the jsonGui behaviour
has been measured.

## Confirmed: ONE interactive GUI per script, re-rendered

A json GUI has **no `destroy()`**. `close()` hides it; the object stays forever.
So making one per panel means every panel you ever open adds another live
interactive GUI to the same script — and nothing in the base game ever does that.
Vanilla creates **one** and re-renders it when the content changes
(`HideoutTrader.lua:1242` rebuilds its entire item list that way).

This mod had six: menu, city, settings, event, my plot, confirm.

That maps exactly onto what was reported. With a screenshot of the menu: *"these
buttons dont work for no reason. I am the host."* The three entries in the shot
— EVENT CLOCK, CITY LAYOUT, SERVER SETTINGS — are the only ones that open **a
second panel**. The four above them (MY PLOT aside) answer in the **chat log**,
and those always worked. The host check was never involved: the menu hides host
entries from guests, so a visible button means the check already passed.

Everything now renders into `Game.cl_showPanel( name, tree )`. Switching panels
is one render call — no close, no gap, and no moment when two interactive GUIs
are both alive. `dev/test_logic.py` fails if a second one appears.

**Corollary: never queue a close on a click that is about to open something.**
The close lands a tick later and can shut the panel that just arrived. Only a
real CLOSE button closes; BACK, a cancelled confirmation and every menu entry
that opens a panel leave the GUI alone and let the reply render into it.

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

## What YOU have to do for a panel to open

Nothing clever — but there are real preconditions, and any of them will make a
panel look broken from the outside.

1. **The mouse cursor has to appear.** A panel is created with
   `needsCursor = true`, and the moment it opens the game should release the
   mouse and show a pointer. **If the panel appears and there is no cursor, your
   clicks are going to the world, not to the panel** — that is a different fault
   from a dead button and it is the first thing to look at.
2. **Nothing else can own the mouse.** Close the inventory (Tab), the handbook,
   the pause menu, and the lift's blueprint window before opening a panel. Only
   one thing gets the cursor.
3. **Get out of the seat.** A seat captures input. Same for anything you are
   driving or controlling.
4. **Be on the ground, in the world.** Not on the loading screen, not mid
   teleport.
5. **Be the host, for host-only panels** — CITY LAYOUT, SERVER SETTINGS, EVENT
   CLOCK. The menu hides those from guests, so **if you can see the button, you
   are the host** and that is not the problem.
6. **The chat has to be closed.** Typing `/menu` and pressing Enter closes it for
   you, so this is usually automatic.
7. **Restart the game after a `--sync`.** Scripts are read at world load. A mod
   updated while the game is running does nothing until you load the world again.

None of these are things you can get wrong quietly except the first one, so the
question worth answering is: **when the panel is up, do you get a mouse cursor?**

---

## SETTLED — 2026-08-24, in game

Both of the open questions are answered, and the answer to both is **yes, it
works**:

- **A Game script DOES receive jsonGui clicks.** It was never the owner.
- **A widget tree built in Lua is fine.** It was never the tree.

What was actually wrong was four separate things, each of which alone was enough
to make every button look dead, and each of which hid the next:

1. `UpgradeButton` drew no caption, so two host entries looked like broken
   widgets rather than buttons. *(V26)*
2. Three fonts were glyph-limited or did not exist, so captions lost letters and
   the HUD logged a traceback every second. *(V29)*
3. The hub menu closed its own GUI **inside the click callback**, which kills the
   rest of the callback — so the request was never sent. Every host feature is
   reached through the hub. *(V30)*
4. Each panel made **its own** interactive GUI. A json GUI has no `destroy()`, so
   opening a second panel meant two live interactive GUIs on one script, and the
   second one never appeared. *(V32)*

The tell that finally cracked it was a screenshot: the entries that failed were
exactly the ones that opened a **second panel**, and the ones that worked were
the ones that answered in **chat**. Not the host check — the menu hides host
entries from guests, so a visible button means that check already passed.

`/guitest` stays in the mod. It is five tests of owner × API × tree shape, it is
client-only, and it is the fastest way to re-establish the ground truth after a
game update.

### How to settle it### How to settle it

Type `/guitest` in game. A small panel appears saying which test it is. Press
both buttons on it. If the panel rewrites itself to say **CLICK RECEIVED**, that
arrangement works. Then type `/guitest` again for the next test.

| test | owner | how | what it tells us |
|---|---|---|---|
| 1 | Game script | jsonGui, tree built in Lua | exactly what the mod ships today |
| 2 | Game script | jsonGui, vanilla's `.gui` file | if 1 fails and 2 works, the **tree** is the problem |
| 3 | Player script | jsonGui, tree built in Lua | if 1 fails and 3 works, the **Game script** is the problem |
| 4 | Player script | jsonGui, vanilla's `.gui` file | the fully vanilla jsonGui arrangement |
| 5 | Game script | **createGuiFromLayout** | the other api. Vanilla's own creative CLEAR dialog is exactly this |

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
