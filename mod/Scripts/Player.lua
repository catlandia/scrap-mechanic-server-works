dofile( "$GAME_DATA/Scripts/game/CreativePlayer.lua" )

-- Nothing custom yet. It exists because config.json requires a playerScript, and
-- because subclassing CreativePlayer now means later additions inherit the base
-- behaviour instead of replacing it -- the same mistake that leaves managers nil
-- in Game.lua applies here.
Player = class( CreativePlayer )
