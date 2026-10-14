# Quail on the Run

A mad scientist has framed you for the demise of a large flightless quail species, and blackmailed you to return a
viable family of the endangered, useless critters, which seem to lack a survival instinct.

A fun, one-file roguelike game platform. Go down into the dungeon, find a Quail's nest, take the eggs, and get them
caged with you before the dark (or your blood sugar) gets you.

```
ruby rogue.rb
```

That opens a DOS box window like this, using the same technology as the original Rogue "Tunnels of Doom."
The one where classically you had to get an "Amulet of Yendor" in the 1980s.

```

HP 15/15  AC 15  Weapon fists  Blood sugar 100  Gold 0  Sandwiches 0  Load 0/60 lb  Depth 1
Knapsack: empty
? lists the keys
f: tap right
x: Throw ____ right?
g: Give ____ right?
▒▒▒▒▒▒▒▒▒▒▒▒▒                                              
▒▒▒▒▒▒▒▒▒▒▒▒▒                                              
▒▒▒▒▒▒▒▒▒▒▒▒▒                                              
▒▒▒▒▒▒▒▒▒▒▒▒▒                                              
▒▒▒·······▒▒▒                                              
▒▒▒·······▒▒▒                                              
▒▒▒···@···▒▒▒                                              
▒▒▒·······▒▒▒                                              
▒▒▒▒▒▒▒▒▒▒▒▒▒                                              
▒▒▒▒▒▒·▒▒▒▒▒▒                                              
▒▒▒▒▒▒·▒▒▒▒▒▒                                              
▒▒▒▒▒▒·▒▒▒▒▒▒                                              
▒▒▒▒▒········

You descend into the dark. Find the stairs (>).

? for the keys
```


Nothing to install: the game uses only Ruby's standard library. The only exception is the desktop window,
which needs the `scarpe` gem.

## Ways to play

| Command                          | Where it plays                                                                                  |
| -------------------------------- | ----------------------------------------------------------------------------------------------- |
| `ruby rogue.rb` or `--dos`       | Right in your terminal, styled after the original PC Rogue: ANSI screen, code page 437 glyphs, Rogue's keys |
| `ruby rogue.rb --web [port]`     | In a browser at `http://localhost:4567/` (or the port you give, 1–65535)                         |
| add `--level N`                  | Start at depth N (1–99). It's a cheat, so it also turns on god mode; New game starts there too   |
| add `--god`                      | God mode: you take no damage, everything else still can                                          |
| `ruby rogue.rb --help`           | Lists all of the above                                                                          |

All three front ends draw the same `Dungeon`. The game logic knows nothing about the screens, so a turn plays
the same everywhere.

## How to win

1. **Go down.** Find the stairs (`>`) on each level. Going deeper doesn't make you tougher; experience does.
2. **Find a Quail.** From depth 6 there's always at least one. From depth 8, one of them nests in a room of its
   own with one to three eggs.
3. **Take the eggs.** Walk onto the nest to gather them. The nesting Quail stirs and follows its eggs.
4. **Hold them to the light.** Candling an egg tells you whether it has legs, wings, and a beak, or is just
   yolk. Deeper nests hold more developed eggs.
5. **Spring the cage.** From depth 5, every level has a cage room. Stepping on its plate drops bars, and
   everything behind them is your haul. If a developed egg is in the haul, it hatches and **you win**. If only
   yolk eggs are, the adventure is over. With no egg at all, step off the plate and back on to lift the bars
   and try again.

You lose if your hit points run out.

## What you'll meet

- **Rats**: they attack on sight.
- **Squirrels**: curious. They come up and tap you, harmlessly, until you hit one; then it bites.
- **Coyotes, goblins, orcs, trolls**: they leave you alone until you hit them.
- **Potions of sleep**: drink one, or throw it at a monster, and the drinker sleeps 3d4 rounds while everything
  else carries on. Half of them go about disguised as a creature, and hurl themselves at you once you're within 3
  squares.
- **Floor traps**: unseen until someone treads on one. A potion of poison breaks underfoot for 2d2 damage and
  stays a trap (`,`). A wand of slowness (`/`) slows whoever treads on it for 2d2 rounds; you pick it up and
  zap it with `z` and an arrow. It holds 3 charges, refilled on every level you enter.
- **Rats and Axebeaks** know where the unseen traps are. A rat runs behind one so you chase it over the trap;
  an Axebeak does the same to a hunting coyote.
- **Trolls and Quails, coyotes and Axebeaks**: a living Quail horrifies a troll, and an Axebeak is a coyote's
  nemesis. A quiet hunter that sees its prey is enraged and hunts it down and eats it, with a howl
  (`sounds/wolf.wav`) if you're close enough to see. Hit or push a hunter and it drops its prey to come after
  you. Tap a quiet one and it marks you, but leaves you be.
- **Goblins** like sandwiches (they'll be friendly for a while) and some will take a coin and fight for you.
- **Doors and walls** (`#`): tap a door to open it, but a locked one only rattles. A coin or a sandwich opens it
  too. Hit a door or a wall twice and it's enraged, hitting back from where it stands. An enraged one throws a
  sandwich back at you: sometimes it lands at your feet still edible, and sometimes it's ruined. A coin calms
  it back down, and a second coin wins it over as before.
- **The Quail** (`Q`): a pacifist that follows you without striking. Hit it and it sulks and stays put. Kill it
  and it explodes into sandwiches. Its cousin the **Axebeak** (`A`) is just as tough but no pacifist, so think
  twice before you hit it.
- **Weapons and shields**: some of these are alive, so beat one to wield or pack it. Daggers, swords, an axe,
  and a bow, whose string wears out if you march too far with it strung.

## Staying alive

- **Alarms**: as your hit points or blood sugar run down, three error sounds go off at once at 3, two at 2, a
  bat chirps at 1, and an error sounds at 0.
- **Experience**: each nearby foe you calm down or defeat while it's out to get you is worth 10 XP. Every 50 XP
  takes you up a level, with a new proficiency bonus of half your level, and recharges your wands.

- **Blood sugar** drops one point every ten rounds. Run out and you die, unless you're in god mode, so eat a
  sandwich (`~`) before then.
- **The knapsack** holds 60 pounds. Gold is light, swords are not, and an egg weighs half a pound.
- **Potions**: sight, speed, slowness, gaseous form, healing. Drink one, throw it at someone nearby, or pour it
  into a candle. A laced candle can be thrown or kicked and bursts over a 20-by-20-foot area.
- **Scrolls** of mapping and of potion finding, and **rings** of peace, strength, and protection (one at a
  time).
- **Teleport plates**: `_` drops you in the cage room. `ṯ` sends you to a random room, though the cage room is
  the likeliest.

## Terminal keys

Press `?` in the game for the full list.

| Key                           | Does                         |
| ----------------------------- | ---------------------------- |
| `hjklyubn`, arrows, or keypad | move (walk into something to attack it) |
| `.` or `5`                    | rest                         |
| `f`                           | tap whatever you're facing; in a hallway or corner, push it a square |
| `i`                           | inventory                    |
| `w`                           | wield                        |
| `a`                           | use an item                  |
| `T` / `K` / `P`               | throw an item / kick a candle / pour a potion |
| `$` / `%`                     | give a coin / give a sandwich |
| `s`, then `x` or `g`          | select an item, then throw or give it |
| `t`                           | throw the gift nobody took   |
| `N` / `Q`                     | new game / quit              |

## Developing

```
rake test                    # run test_rogue.rb (Minitest)
rake ship your message here  # run the tests; only if they pass, commit everything and push
rake claude                  # open Claude Code here; words after it become the first prompt
```

`rogue.rb` holds the game (`Dungeon`) and its front ends (`DosBox` and `WebGame`). Every kind of creature and 
item is one row of `Dungeon::THINGAGES`: its glyph, D&D-style ability scores, challenge rating 
(the first depth it turns up on), and how peaceful it is. Doors, sandwiches, and the other locked 
things share a small state machine, `Dungeon::DoorLock`. The quiet and enraged states of hunters and of
the `#` furniture are one more table there, `STATE_TRANSITIONS`.
