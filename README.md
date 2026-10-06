# Quail on the Run

A fun, one-file roguelike game platform. Go down into the dungeon, find a Quail's nest, take the eggs, and get them
caged with you before the dark (or your blood sugar) gets you.

```
ruby rogue.rb
```

Nothing to install: the game uses only Ruby's standard library. The only exception is the desktop window,
which needs the `scarpe` gem.

## Ways to play

| Command                          | Where it plays                                                                                  |
| -------------------------------- | ----------------------------------------------------------------------------------------------- |
| `ruby rogue.rb` or `--dos`       | Right in your terminal, styled after the original PC Rogue: ANSI screen, code page 437 glyphs, Rogue's keys |
| `ruby rogue.rb --web [port]`     | In a browser at `http://localhost:4567/` (or the port you give, 1–65535)                         |
| add `--god`                      | God mode: you take no damage, everything else still can                                          |
| `ruby rogue.rb --help`           | Lists all of the above                                                                          |

All three front ends draw the same `Dungeon`. The game logic knows nothing about the screens, so a turn plays
the same everywhere.

## How to win

1. **Go down.** Find the stairs (`>`) on each level. A new deepest level raises your max HP.
2. **Find a Quail.** From depth 6 there's always at least one. From depth 8, one of them nests in a room of its
   own with one to three eggs.
3. **Take the eggs.** Walk onto the nest to gather them. The nesting Quail stirs and follows its eggs.
4. **Hold them to the light.** Candling an egg tells you whether it has legs, wings, and a beak, or is just
   yolk. Deeper nests hold more developed eggs.
5. **Spring the cage.** From depth 5, every level has a cage room. Stepping on its plate drops bars, and
   everything behind them is your haul. If a developed egg is in the haul, it hatches and **you win**. If none
   is, the adventure is over.

You lose if your hit points run out.

## What you'll meet

- **Rats, squirrels**: they attack on sight.
- **Coyotes, goblins, orcs, trolls**: they leave you alone until you hit them.
- **Goblins** like sandwiches (they'll be friendly for a while) and some will take a coin and fight for you.
- **Doors**: tap one to open it, but a locked one only rattles. A coin or a sandwich opens it too. Hit a door
  twice and it hits back.
- **The Quail** (`Q`): a pacifist that follows you without striking. Hit it and it sulks and stays put. Kill it
  and it explodes into sandwiches. Its cousin the **Axebeak** (`A`) is just as tough but no pacifist, so think
  twice before you hit it.
- **Weapons and shields**: some of these are alive, so beat one to wield or pack it. Daggers, swords, an axe,
  and a bow, whose string wears out if you march too far with it strung.

## Staying alive

- **Blood sugar** drops one point every round. At zero you're hungry: you're drawn in amber and lose HP every so
  often. Eat a sandwich (`~`).
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
| `f`                           | tap whatever you're facing   |
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
