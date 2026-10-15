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


Nothing to install: the game uses only Ruby's standard library. The exceptions are the desktop window,
which needs the `scarpe` gem, and the plaque at the end of a game, which needs an XSLT processor: the
`nokogiri` gem if you have it, or else the `xsltproc` command.

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
   everything behind them is your haul. The haul needs both an egg and a living Quail. If a developed egg is
   in it, it hatches and **you win**. If only yolk eggs are, the adventure is over. Without an egg or a Quail,
   step off the plate and back on to lift the bars and try again.

You lose if your hit points run out.

However it ends, a game played without `--god` or `--level` earns an ASCII art plaque on the **wall of fallen
heroes**, with the name you gave at the start.

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
things share a small state machine, `Dungeon::DoorLock`.
