# Run with: ruby rogue.rb
# Or in a browser: ruby rogue.rb --web [port], e.g. --web 8080, then open http://localhost:8080/ (default port 4567)
# Or in the console, like the original PC Rogue: ruby rogue.rb --dos
# Add --god to any of them for god mode, where the player takes no damage; --help lists all of these

require 'socket'
require 'uri'

# The game knows nothing about Scarpe; the app below only draws it and pushes buttons
class Dungeon

  # cr (challenge rating) is the first depth a kind turns up on, and na (number appearing) caps how many of it
  # one level holds. na: 1 makes a kind unique and out-of-band: random spawning skips it, so it only turns up
  # where the game places it on purpose. out_of_band does the same for a kind with an na above 1.
  # A fractional pacifist is the chance each one spawns pacifist; greedy is the chance a coin will buy it.
  # Only an aggressive kind chases and strikes from the start; every other kind starts neutral, minding its
  # own business until the player hits it. A door is a pacifist that turns aggressive on the second hit. An eats
  # kind is a creature with blood sugar, which runs down once it wakes and which a sandwich fills again

  THINGAGES = [
    { glyph: "@", name: "Ego", na: 1, cr: 1, hp: 15, ac: 15, str: 15, dex: 15, con: 11, int: 15, wis: 15, cha: 14,  hit: 1..8 },
    { glyph: "🗡", # light sword
      name: "weapon", na: 1, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.66 },
    { glyph: "༺", # shield causes no damage and target wants to go where it nudges
      name: "weapon", na: 1, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.75 },
    { glyph: "𓆩", # light shield causes d6 damage + str or dex or int benefits, one damage event per round is halved
      name: "light shield", na: 10, cr: 3, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.66, packable: 3 },
    { glyph: "༒",  #  double-damage to anyone who is currently aggressive to Ego
      name: "weapon", na: 10, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.65 },
    { glyph: "༻", # shield causes damage yet doubles your protection
      name: "shield", na: 10, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 18, con: 18, int: 10, wis:  1, cha: 10,  pacifist: 0.5, packable: 6 },
    { glyph: "R", name: "rat",      na:  8, cr: 1, hp:  3, hit: 1..2, ac: 10, str:  7, dex: 15, con: 11, int:  2, wis: 10, cha:  4, aggressive: true, eats: true },
    { glyph: "C", name: "coyote",   na:  5, cr: 3, hp:  3, hit: 1..2, ac: 10, str: 17, dex: 15, con: 11, int: 16, wis: 15, cha: 14, aggressive: false, eats: true },
    { glyph: "G", name: "goblin",   na:  8, cr: 2, hp:  6, hit: 1..4, ac: 10, str:  8, dex: 17, con: 10, int: 13, wis: 15, cha: 10, greedy: 0.5, eats: true },
    { glyph: "O", name: "orc",      na:  5, cr: 4, hp: 10, hit: 2..6, ac: 15, str: 14, dex: 12, con: 17, int: 15, wis: 10, cha: 10, eats: true },
    { glyph: "T", name: "troll",    na:  2, cr: 5, hp: 18, hit: 3..8, ac: 15, str: 16, dex: 10, con: 18, int: 10, wis: 10, cha: 10, eats: true },
    { glyph: "#", name: "wall",     na: 17, cr: 1, hp:  3, hit: 0..0, ac: 10, str: 18, dex:  0, con: 18, int:  0, wis:  0, cha:  0, pacifist: true },
    { glyph: "#", name: "door",     na:  4, cr: 1, hp: 30, hit: 1..4, ac: 10, str: 18, dex:  0, con: 18, int:  0, wis:  0, cha:  0, pacifist: true, out_of_band: true },
    { glyph: "$", name: "gold",     na: 15, cr: 2, hp:  3, hit: 0..0, ac: 18, str: 18, dex:  0, con: 18, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.02 },
    { glyph: "=", name: "ring of peace",     na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1 },
    { glyph: "=", name: "ring of strength",     na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1 },
    { glyph: "=", name: "ring of protection",   na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1 },
    { glyph: "i", name: "candle",   na: 10, cr: 3, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 1 },
    { glyph: "¡", name: "potion",   na: 10, cr: 3, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.5 },
    { glyph: "?", name: "scroll of mapping", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.1 },
    { glyph: "!", name: "slow potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5 },
    { glyph: "!", name: "healing potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5 },
    { glyph: "!", name: "empty potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5 },
    { glyph: "~", name: "sandwich",   na: 20, cr: 4, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 1 },
    { glyph: "?", name: "scroll of 3 potions", na:  1, cr: 6, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1 },
    { glyph: "A", name: "Axebeak",    na:  1, cr: 5, hp: 28, hit: 4..9, ac: 15, str: 18, dex: 17, con: 16, int: 15, wis: 14, cha: 13, pacifist: false, eats: true },
    { glyph: "Q", name: "Quail",    na:  1, cr: 5, hp: 28, hit: 4..9, ac: 15, str: 18, dex: 17, con: 16, int: 15, wis: 14, cha: 13, pacifist: true, eats: true }
  ]

  # The creatures, by name, that have blood sugar
  EATERS = THINGAGES.select { |k| k[:eats] }.map { |k| k[:name] }.freeze

  #⚔️🛡️ 🏹
#  ⚔⊹ ࣪ ˖༺𓆩༒︎𓆪༻⋆༺𓆩⚔𓆪༻⋆꧁⎝ 𓆩༺✧༻𓆪 ⎠꧂༺𓆩༒︎𓆪༻
  #  ⚔⊹ ࣪ ˖⚔⊹ ࣪ ˖⚔⊹ ࣪ ˖
  # ability to wield a weapon
  # na number appearing
  # hp  hit points str dex con int wis cha
  # test that the name shows up
  # hit with current weapon
  # make the teleportation traps less frequent and make them sessile thingables
  #  add sessile motile as a primary attribute

  #  ability to request another life spawned on the current level
  #  test that going down a level boosts your life level and those
  #   of every follower

  #  potion of out of focusness - Rs become Qs, Qs become Plants, potted plants become quails, Ts become Cs, Cs become
  #  dead bodies stay there until Milda cleans them up

  #  potion of cursed reckless speed thrown at energized enemy enrages them against your nemesis for you
  #  potion of cursed reckless taken by Ego fails all wisdom use checks for energy conservation against Constitution

  #  a goblin, coyote, or rat assistant makes possible a large following.
  #  otherwise they just slow you down

  # orcs cannot be bribed not to hunt axebeaks - they pass the bribes along to axe beak hunting crews
  #  coyotes and axe beaks are each other's nemesis and cannot be bribed
  # not to hunt each other
  # as the cage room rises it stops on each level of the
  #
  #these characters plant trees. they may infinitely pack into the trap room
  #𓁟 — U+1305F, Gardiner C3 — Thoth, the ibis-headed god associated with writing, knowledge, and scribes.
#𓏞 — U+133DE, Gardiner Y3 — scribe's palette, a very recognizable writing/scribe sign.
#𓏛 — U+133DB, Gardiner Y1 — papyrus roll/book, used in writing-related contexts.
#𓏠 — U+133E0, Gardiner Y4 — another writing implement/palette-related sign.
#𓀀 — this guy reads the tablet and plants the tree

  #let the user select ability to remember a level and return to it as
  #  a next level robo-predator controlled by a remote human on FPV

  #  axe beaks feed on quail eggs and are very fast on roads
  #
  #  add a mischievous Raccoon who tries to own the Quail
  #
  #  ability to arise on the same level
  #
  # grabbing a stopped weapon wields it - add wield to the top line with the weapon in hand
  #
  # Gold and sandwiches (%) found on the floor go straight into the knapsack.
  # Eating a sandwich refills blood sugar, not hit points

  #  traveling two steps rests you one point

  #  all monsters also rest

  # A Quail is a pacifist that follows the player without striking; once hit it is spurned and stays put,
  # still blocking the way, and when slain it explodes into 1-5 sandwiches

  #  giving food to a monster makes it stop attacking you and giving it 1 coin of gold makes it guard you to get more

  #  the second level lets you pick up a weapon

  #  make aggressive things attack the TODO weapon and the mobile wall

  # Blood sugar starts full and drops by one each round, the player's from the start and a creature's from the
  # round it wakes and first acts. At zero they're hungry, drawn in HUNGRY_COLOR, and lose a hit point every
  # STARVE_ROUNDS rounds until a sandwich fills them up again
  VIEWPORT_WIDTH  = (48 * 1.3).to_i
  VIEWPORT_HEIGHT = (18 * 1.3).to_i
  SIGHT  = 6
  MAX_BLOOD_SUGAR = 100
  STARVE_ROUNDS = 150
  HUNGRY_COLOR = "#e8a33d"

  # fed counts down the turns a goblin stays friendly after a sandwich; an ally keeps the coins it pockets.
  # sugar is a creature's blood sugar, nil until it wakes, and starving counts its rounds at zero.
  # The six ability scores come from the kind's THINGAGES row: str adds to every blow it lands, and con to the
  # hit points it spawns with. dex, int, wis and cha are carried along but nothing reads them yet.
  # slowed counts down the rounds a potion of slowness lasts, and lagging marks the rounds it sits out
  Thingage = Struct.new(:x, :y, :glyph, :name, :hp, :hit, :str, :dex, :con, :int, :wis, :cha, :pacifist, :spurned, :greedy, :fed, :ally, :coins, :aggressive,
                        :hasted, :gaseous, :farsighted, :nesting, :sugar, :starving, :slowed, :lagging)
  ABILITIES = %i[str dex con int wis cha].freeze

  # The D&D ability modifier: 10 and 11 give +0, and every two points up or down moves it by one.
  # A missing score counts as an average 10
  def self.modifier(score)
    ((score || 10) - 10).div(2)
  end

  # How many turns one sandwich keeps a goblin friendly
  FULL_TURNS = 30

  # What the player swings, and for how much, until they seize something better
  BARE_HANDS = "fists"
  BARE_HANDS_HIT = 2..6
  FISTS = { name: BARE_HANDS, glyph: nil, hit: BARE_HANDS_HIT }.freeze

  # Each weapon that spawns is one of these; its THINGAGES row only sets how often, how tough, and how peaceful.
  # A pair is two blades wielded together, so its name is already plural. A ranged weapon is never grabbed into
  # empty hands on defeating it; it goes into the knapsack, to wield when the player chooses
  WEAPONS = [
    { name: "dagger", glyph: "🗡️", hit: 3..7, packable: 1 },
    { name: "swords", glyph: "⚔️", hit: 4..10, pair: true, packable: 6 },
    { name: "bow",    glyph: "🏹", hit: 2..9, packable: 2, ranged: true },
    { name: "axe",    glyph: "🪓", hit: 5..12, packable: 4 },
  ].freeze

  # The kinds of shield, by their THINGAGES rows' names. Defeating one packs it; nothing uses a packed one yet
  SHIELDS = ["shield", "light shield"].freeze

  # The hero's armor class: unarmored, as in D&D. Nothing reads it in combat yet
  HERO_AC = 10

  attr_reader :hp, :max_hp, :ac, :blood_sugar, :knapsack, :depth, :log, :wielded, :ring

  # In god mode the player takes no damage; everything else still can
  def initialize(god: false)
    @god = god
    @max_hp = 20
    @ac = HERO_AC
    @hp = @max_hp
    @blood_sugar = MAX_BLOOD_SUGAR
    @starving = 0
    @wielded = FISTS
    @knapsack = { gold: 0, sandwiches: 0, potions: 0, speed_potions: 0, gas_potions: 0, slow_potions: 0, healing_potions: 0,
                  empty_potions: 0, scrolls: 0, mapping_scrolls: 0, peace_rings: 0, strength_rings: 0, protection_rings: 0,
                  candles: 0, laced_potions: 0, laced_speed_potions: 0, laced_gas_potions: 0, laced_slow_potions: 0,
                  laced_healing_potions: 0, laced_empty_potions: 0, eggs: [], weapons: [], shields: [] }
    @ring = nil
    @hasted = 0
    @slowed = 0
    @gaseous = 0
    @quick = false
    @won = false
    @trapped = false
    @depth = 1
    @log = ["You descend into the dark. Find the stairs (>)."]
    return build_level()
  end

  # The game ends when the player dies, or springs the cage's trap on themselves and whatever else is inside;
  # it's a win if an egg in that haul hatches
  def over?
    @hp <= 0 || @trapped
  end

  def won? = @won

  # How the game ended, for the banner: "YOU WON", "ADVENTURE OVER" for a haul with nothing hatching, or "" while
  # it goes on
  def outcome
    return "YOU WON" if @won
    return "ADVENTURE OVER" if @trapped

    ""
  end

  # From this depth on, every level has a cage room: a CAGE_ROOM-sized room whose far TRAP_DEPTH rows or columns,
  # at an end with no way in, are the cage. An unseen line runs across the room in front of them, and an o plate
  # lies in the middle of the back row; stepping onto the plate drops bars along the line, trapping everything
  # behind it
  CAGE_DEPTH = 5
  CAGE_ROOM = { w: 12, h: 15 }.freeze
  TRAP_DEPTH = 4

  # Teleport plates lie on room floors, like gold. Stepping onto a cage plate lands the player in the cage room, so
  # one turns up only on a level that has one. Anyone, player or monster, stepping onto a random plate lands in a
  # random room, where the cage room is CAGE_ODDS times as likely as any other. The elevator room isn't built yet
  CAGE_PLATE = "_"
  RANDOM_PLATE = "ṯ"
  CAGE_ODDS = 5.0 / 3

  # An egg is developed, with legs, wings, and a beak, or just yolk; candled once it's been held up to the light
  Egg = Struct.new(:developed, :candled)

  # The first depth where a Quail always turns up; shallower than this, from the Quail's cr, it's a coin toss.
  # From here on, every two levels deeper add one more
  QUAIL_DEPTH = 6

  # From this depth on, one of the level's Quails nests in a hatchery: a room of its own with a nest of eggs
  HATCHERY_DEPTH = 8

  def god?
    @god
  end

  # The wielded weapon as the banner shows it, e.g. "🗡️ dagger", or just "fists"
  def weapon
    label(@wielded)
  end

  def weapon_hit
    @wielded[:hit]
  end

  def gold
    @knapsack[:gold]
  end

  def sandwiches
    @knapsack[:sandwiches]
  end

  def potions
    @knapsack[:potions]
  end

  def scrolls
    @knapsack[:scrolls]
  end

  # Rounds the player has left of each timed potion; a round is one turn of everyone else's
  def hasted? = @hasted.positive?
  def slowed? = @slowed.positive?
  def gaseous? = @gaseous.positive?

  # The timed potion effects for the banner, e.g. "Hasted 12   Gaseous 3", or "" when none
  def effects
    [("Hasted #{@hasted}" if hasted?), ("Slowed #{@slowed}" if slowed?), ("Gaseous #{@gaseous}" if gaseous?)].compact.join("   ")
  end

  # Each kind of potion by knapsack slot: the THINGAGES row it spawns from, its full name, and its glyph.
  # Quaffing one gives the drinker its power, and so does throwing it at a character close by
  POTIONS = {
    potions:         { row: "potion",         name: "potion of sight",        glyph: "¡" },
    speed_potions:   { row: "speed potion",   name: "potion of speed",        glyph: "!", packable: 0.5 },
    gas_potions:     { row: "gas potion",     name: "potion of gaseous form", glyph: "~", packable: 0.5 },
    slow_potions:    { row: "slow potion",    name: "potion of slowness",     glyph: "!" },
    healing_potions: { row: "healing potion", name: "potion of healing",      glyph: "!" },
    empty_potions:   { row: "empty potion",   name: "empty potion",           glyph: "!" },
  }.freeze

  # A potion of speed gives two actions for everyone else's one for this many rounds; slowness gives everyone else
  # two for the drinker's one for SLOW_ROUNDS; gaseous form leaves nothing able to touch, or be touched by, the
  # drinker for GAS_ROUNDS. Healing restores the player to full, and a monster, which has no full, by HEAL_HP
  SPEED_ROUNDS = 30
  SLOW_ROUNDS = 20
  GAS_ROUNDS = 10
  HEAL_HP = 10

  # Each kind of scroll by knapsack slot: the THINGAGES row it spawns from, its full name, and its glyph.
  # Reading one uses it up
  SCROLLS = {
    scrolls:         { row: "scroll of 3 potions", name: "scroll of potion finding", glyph: "?" },
    mapping_scrolls: { row: "scroll of mapping",   name: "scroll of mapping",        glyph: "?" },
  }.freeze

  # Each kind of ring by knapsack slot: the THINGAGES row it spawns from, its full name, and its glyph.
  # Wearing one slips it on; only one fits at a time
  RINGS = {
    peace_rings:      { row: "ring of peace",      name: "ring of peace",      glyph: "=" },
    strength_rings:   { row: "ring of strength",   name: "ring of strength",   glyph: "=" },
    protection_rings: { row: "ring of protection", name: "ring of protection", glyph: "=" },
  }.freeze

  # Candles pack like the other items. Pouring a potion into one makes a laced candle, kept in the LACED slot for
  # that potion; thrown up to THROW_RANGE or kicked up to KICK_RANGE, it bursts where it stops and gives its
  # potion's power to everyone in a BURST by BURST square area: four 5-foot squares a side, 20 by 20 feet
  CANDLES = { candles: { row: "candle", name: "candle", glyph: "i" } }.freeze
  LACED = POTIONS.keys.to_h { |slot| [:"laced_#{slot}", slot] }.freeze
  BURST = 4
  KICK_RANGE = 3

  # Thingages that walking into packs instead of attacks, with the knapsack slot each goes in and its full name
  ITEMS = POTIONS.merge(SCROLLS).merge(RINGS).merge(CANDLES).freeze
  PACKABLE = ITEMS.to_h { |slot, i| [i[:row], slot] }.freeze
  ITEM_NAMES = ITEMS.transform_values { |i| i[:name] }.freeze

  # How far, in squares each way, a scroll of potion finding or of mapping reaches
  SCROLL_RANGE = 20

  # What one press of each give button hands over, keyed by its knapsack slot
  GIFTS = { gold: "a coin", sandwiches: "a sandwich" }.freeze

  # The most the knapsack holds, in pounds. What's wielded is in hand and what's worn is on a finger, so neither
  # counts. Each thing's weight is the packable on the line that builds it: its THINGAGES row, its WEAPONS entry,
  # or, for a potion with no row of its own, its POTIONS entry. A Quail egg has no line, so it weighs EGG_POUNDS
  ENCUMBRANCE = 60
  EGG_POUNDS = 0.5

  # A weight as an exact fraction, so that, say, 3,000 coins at 0.02 pounds weigh 60 pounds even
  def self.pounds(weight) = Rational(weight.to_s)

  def self.packable(name) = THINGAGES.find { |k| k[:name] == name }&.dig(:packable)

  # Pounds one thing from a knapsack slot weighs; a laced candle is its candle and its potion together
  def pounds(slot)
    return pounds(:candles) + pounds(LACED[slot]) if LACED.key?(slot)

    Dungeon.pounds(case slot
                   when :gold then Dungeon.packable("gold")
                   when :sandwiches then Dungeon.packable("sandwich")
                   else ITEMS.fetch(slot)[:packable] || Dungeon.packable(ITEMS.fetch(slot)[:row])
                   end)
  end

  # Pounds a weapon weighs, packed: its WEAPONS entry's packable
  def weapon_pounds(w) = Dungeon.pounds(WEAPONS.find { |k| k[:name] == w[:name] }&.dig(:packable) || 0)

  # Pounds in the knapsack now
  def load
    counted = @knapsack.sum { |slot, n| n.is_a?(Integer) ? n * pounds(slot) : 0 }
    counted + @knapsack[:eggs].size * Dungeon.pounds(EGG_POUNDS) + @knapsack[:weapons].sum { |w| weapon_pounds(w) } +
      @knapsack[:shields].sum { |s| Dungeon.pounds(Dungeon.packable(s[:name])) }
  end

  def room_for?(weight) = load + weight <= ENCUMBRANCE

  # How many of count things, each weighing that much, the knapsack has room for
  def fitting(count, each) = [count, ((ENCUMBRANCE - load) / each).floor].min.clamp(0..)

  # The load for the banner, e.g. "Load 12.5/60 lb"
  def load_text
    shown = load.round(1)
    "Load #{shown.denominator == 1 ? shown.to_i : shown.to_f}/#{ENCUMBRANCE} lb"
  end

  # Readies a gift from the knapsack; the next arrow hands it that way instead of moving, and rest cancels it,
  # except that resting on a sandwich eats it yourself
  def offer(item)
    over? and return
    @throwable = nil
    @knapsack[item].zero? and return say("You have no #{item} to give.")

    @offering = item
    say "Give #{GIFTS[item]} which way?#{" Rest to eat it yourself." if item == :sandwiches}"
  end

  # The knapsack as [text, slot] pairs, e.g. ["3 🪓 axes", "axe"], with weapons grouped by kind in
  # packing order. The slot is :gold or :sandwiches, which give, :eggs, which candles, a POTIONS slot, which quaffs
  # or throws, a SCROLLS slot, which reads, a RINGS slot, which wears, :candles and :shields, which wait, or a
  # weapon name, which wields
  def contents
    packed = []
    packed << ["#{gold} gold", :gold] if gold.positive?
    packed << ["#{sandwiches} #{sandwiches == 1 ? "sandwich" : "sandwiches"}", :sandwiches] if sandwiches.positive?
    packed << [egg_count(@knapsack[:eggs]), :eggs] if @knapsack[:eggs].any?
    POTIONS.each do |slot, p|
      n = @knapsack[slot]
      packed << [n == 1 ? "#{p[:glyph]} #{p[:name]}" : "#{n} #{p[:glyph]} #{p[:name].sub("potion", "potions")}", slot] if n.positive?
    end
    SCROLLS.each do |slot, s|
      n = @knapsack[slot]
      packed << [n == 1 ? "#{s[:glyph]} #{s[:name]}" : "#{n} #{s[:glyph]} #{s[:name].sub("scroll", "scrolls")}", slot] if n.positive?
    end
    RINGS.each do |slot, r|
      n = @knapsack[slot]
      packed << [n == 1 ? "#{r[:glyph]} #{r[:name]}" : "#{n} #{r[:glyph]} #{r[:name].sub("ring", "rings")}", slot] if n.positive?
    end
    n = @knapsack[:candles]
    packed << [n == 1 ? "i candle" : "#{n} i candles", :candles] if n.positive?
    LACED.each do |slot, potion|
      n = @knapsack[slot]
      packed << ["#{n == 1 ? "i candle" : "#{n} i candles"} laced with #{POTIONS[potion][:name]}", slot] if n.positive?
    end
    @knapsack[:weapons].group_by { |w| w[:name] }.each do |name, kind|
      many = pair?(name) ? "#{kind.size} pairs of #{label(kind.first)}" : "#{kind.size} #{label(kind.first)}s"
      packed << [kind.size == 1 ? label(kind.first) : many, name]
    end
    @knapsack[:shields].group_by { |s| s[:name] }.each_value do |kind|
      packed << [kind.size == 1 ? label(kind.first) : "#{kind.size} #{label(kind.first)}s", :shields]
    end
    packed
  end

  # Lists the knapsack in the log; looking takes no turn and leaves any readied gift waiting
  def inventory
    packed = contents.map(&:first)
    return say("Your knapsack is empty.") if packed.empty?

    say "Your knapsack holds #{and_list(packed)}."
  end

  # Drinks a potion from the knapsack. Sight reveals the whole level; speed gives two actions for everyone
  # else's one for SPEED_ROUNDS; gaseous form makes the player untouchable, and unable to touch, for GAS_ROUNDS.
  # Drinking takes a turn, so anything beside you gets its swing
  def quaff(slot = :potions)
    over? and return
    @throwable = nil
    (potion = POTIONS[slot]) or return
    @knapsack[slot].zero? and return say(slot == :potions ? "You have no potion to drink." : "You have no #{potion[:name]} to drink.")

    @knapsack[slot] -= 1
    say "You quaff the #{potion[:name]}. #{take_effect(slot)}"
    end_turn
  end

  # Gives the player a potion's power, drunk or splashed over them, and says what it does
  def take_effect(slot)
    case slot
    when :potions
      @seen = Array.new(VIEWPORT_HEIGHT) { Array.new(VIEWPORT_WIDTH, true) }
      "The whole level is revealed!"
    when :speed_potions
      @hasted = SPEED_ROUNDS
      @quick = false
      "Everything else slows to half your pace!"
    when :gas_potions
      @gaseous = GAS_ROUNDS
      "You turn to mist. Nothing can touch you, and you can touch nothing."
    when :slow_potions
      @slowed = SLOW_ROUNDS
      "Everything else speeds up to twice your pace!"
    when :healing_potions
      @hp = @max_hp
      "You feel whole again!"
    when :empty_potions
      "It's empty. Nothing happens."
    end
  end

  # Pours a potion into a candle from the knapsack, making a laced candle to throw or kick; pouring takes a turn
  def pour(slot)
    over? and return
    @throwable = nil
    (potion = POTIONS[slot]) or return
    @knapsack[slot].zero? and return say("You have no #{potion[:name]} to pour.")
    @knapsack[:candles].zero? and return say("You have no candle to pour it into.")

    @knapsack[slot] -= 1
    @knapsack[:candles] -= 1
    @knapsack[:"laced_#{slot}"] += 1
    say "You pour the #{potion[:name]} into a candle."
    end_turn
  end

  # Readies a laced candle to throw or kick (how is :throw or :kick); the next arrow sends it that way, and rest
  # cancels it
  def fling(slot, how)
    over? and return
    @throwable = nil
    (potion = LACED[slot]) && %i[throw kick].include?(how) or return
    @knapsack[slot].zero? and return say("You have no candle laced with #{POTIONS[potion][:name]}.")

    @offering = slot
    @flinging = how
    say "#{how.to_s.capitalize} the candle laced with #{POTIONS[potion][:name]} which way?"
  end

  # Readies a potion to throw; the next arrow throws it that way instead of moving, and rest cancels it
  def aim(slot)
    over? and return
    @throwable = nil
    (potion = POTIONS[slot]) or return
    @knapsack[slot].zero? and return say("You have no #{potion[:name]} to throw.")

    @offering = slot
    say "Throw the #{potion[:name]} which way?"
  end

  # "3 eggs", and once candled, what the light showed, e.g. "3 eggs (1 developed, 1 yolk, 1 unknown)"
  def egg_count(eggs)
    text = "#{eggs.size} #{eggs.size == 1 ? "egg" : "eggs"}"
    candled = eggs.select(&:candled)
    return text if candled.empty?

    developed = candled.count(&:developed)
    seen = ["#{developed} developed", "#{candled.size - developed} yolk", "#{eggs.size - candled.size} unknown"]
    "#{text} (#{seen.reject { |s| s.start_with?("0 ") }.join(", ")})"
  end

  # Holds every egg in the knapsack up to the light, showing which are just yolk and which have grown legs, wings,
  # and a beak; it takes a turn
  def candle
    over? and return
    @throwable = nil
    eggs = @knapsack[:eggs]
    eggs.empty? and return say("You have no eggs to hold up to the light.")

    eggs.each { |e| e.candled = true }
    developed = eggs.count(&:developed)
    yolk = eggs.size - developed
    if eggs.size == 1
      say "You hold the egg up to the light. #{developed == 1 ? "You can see legs, wings, and a beak" : "It's just yolk"}."
    else
      seen = []
      seen << "#{yolk == 1 ? "one is" : "#{yolk} are"} just yolk" if yolk.positive?
      seen << "in #{developed == 1 ? "one" : developed} you can see legs, wings, and a beak" if developed.positive?
      say "You hold #{eggs.size} eggs up to the light: #{seen.join("; ")}."
    end
    end_turn
  end

  # Reads a scroll from the knapsack. Potion finding marks every potion of sight within SCROLL_RANGE on the map
  # for the rest of the level, however far or unseen, and the log says which way each lies; mapping reveals every
  # square within SCROLL_RANGE. Reading takes a turn
  def read(slot = :scrolls)
    over? and return
    @throwable = nil
    (scroll = SCROLLS[slot]) or return
    @knapsack[slot].zero? and return say(slot == :scrolls ? "You have no scroll to read." : "You have no #{scroll[:name]} to read.")

    @knapsack[slot] -= 1
    case slot
    when :scrolls
      found = @monsters.select do |m|
        m.name == "potion" && (m.x - @px).abs <= SCROLL_RANGE && (m.y - @py).abs <= SCROLL_RANGE
      end

      @detected.concat(found)
      shown = found.empty? ? "no potions of sight nearby" :
        "#{found.size == 1 ? "a potion" : "#{found.size} potions"} of sight: #{found.map { |m| bearing(m.x, m.y) }.join("; ")}"
      say "You read the scroll of potion finding. It shows #{shown}."
    when :mapping_scrolls
      @seen.each_with_index do |row, y|
        row.each_index { |x| row[x] = true if (x - @px).abs <= SCROLL_RANGE && (y - @py).abs <= SCROLL_RANGE }
      end
      say "You read the scroll of mapping. The level within #{SCROLL_RANGE} squares is revealed!"
    end
    end_turn
  end

  # Slips a ring from the knapsack onto a finger, packing any ring already worn. Nothing reads the worn ring
  # yet. Swapping takes a turn
  def wear(slot)
    over? and return
    @throwable = nil
    (ring = RINGS[slot]) or return
    @knapsack[slot].zero? and return say("You have no #{ring[:name]} to wear.")

    @knapsack[slot] -= 1
    @knapsack[@ring] += 1 if @ring
    @ring = slot
    say "You slip on the #{ring[:name]}."
    end_turn
  end

  # Swaps the first knapsack weapon, or the first of the named kind, into hand, packing the old one at the
  # back, so repeated wields cycle through them all; fists aren't packed. Swapping takes a turn
  def wield(name = nil)
    over? and return
    @throwable = nil
    weapons = @knapsack[:weapons]
    at = name ? weapons.index { |w| w[:name] == name } : 0

    (drawn = at && weapons.delete_at(at)) or
      return say(name ? "You have no #{name} in your knapsack." : "You have no weapon in your knapsack to wield.")

    unless @wielded == FISTS || room_for?(weapon_pounds(@wielded))
      weapons.insert(at, drawn)
      return say("Your knapsack is too full to hold your #{@wielded[:name]} in place of the #{drawn[:name]}.")
    end
    @knapsack[:weapons] << @wielded unless @wielded == FISTS
    @wielded = drawn
    say "You now wield #{weapon}."
    end_turn
  end

  # How far a thrown gift can fly
  THROW_RANGE = SIGHT

  # True right after a gift found no one to take it, when the throw button applies
  def can_hurl?
    !@throwable.nil?
  end

  # Throws that gift on the same way: the first thing within range catches it, else it lands on the
  # last open floor before a wall, for anyone to pick up. Throwing takes a turn; any other action forgets the gift
  def hurl
    over? and return
    @throwable or return say("There's nothing to throw.")

    item, dx, dy = @throwable
    @throwable = nil
    x, y = @px, @py
    THROW_RANGE.times do
      break if wall?(x + dx, y + dy)

      x += dx
      y += dy
      next unless (catcher = monster_at(x, y)) && !mist?(catcher) # a gift sails through a misty thing

      say "You throw #{GIFTS[item]} and the #{catcher.name} catches it. It #{receive(catcher, item)}."
      return end_turn
    end
    [x, y] == [@px, @py] and return say("A wall is in the way. You keep it.")

    @knapsack[item] -= 1
    floor = item == :gold ? @treasure : @sandwiches
    floor[[x, y]] = floor.fetch([x, y], 0) + 1
    say "You throw #{GIFTS[item]} and it lands on the floor."
    end_turn
  end

  # Walking into a monster attacks it; walking onto > goes deeper
  def move(dx, dy)
    over? and return
    @throwable = nil
    if (item = @offering)
      return fling_candle(item, dx, dy) if LACED.key?(item)

      return POTIONS.key?(item) ? throw_potion(item, dx, dy) : give(item, dx, dy)
    end

    nx = @px + dx
    ny = @py + dy
    wall?(nx, ny) and return say("You bump the wall.")

    if (foe = monster_at(nx, ny))
      gaseous? and return say("You drift against the #{foe.name}, but you can't touch it.")

      if mist?(foe)
        say "Your blow passes right through the misty #{foe.name}."
      else
        (slot = PACKABLE[foe.name]) ? pack(foe, slot) : attack(foe)
      end
    else
      @px, @py = nx, ny
      pick_up
      [@px, @py] == @cage&.dig(:plate) and return spring_trap
      @map[@py][@px] == ">" and return descend
      ride_plate
    end

    end_turn
    reveal
  end

  def rest
    over? and return
    @throwable = nil
    if @offering
      item = @offering
      @offering = nil
      return item == :sandwiches ? eat : say("You keep it.")
    end

    @hp = [@hp + 1, @max_hp].min
    found = beside.map { |m| a_name(m.name) }
    say "You catch your breath and find #{found.empty? ? "nothing" : and_list(found)} beside you."
    end_turn
  end

  # Eating a sandwich from the knapsack takes a turn, at the end of which the player's blood sugar is full again
  def eat
    @knapsack[:sandwiches] -= 1
    end_turn
    return if over?

    @blood_sugar = MAX_BLOOD_SUGAR
    @starving = 0
    say "You eat a sandwich. Your blood sugar is back to #{MAX_BLOOD_SUGAR}."
  end

  def hungry? = @blood_sugar.zero?

  # The map as rows of [glyph, hungry] squares, for a front end that draws it a square at a time
  def cells
    Array.new(VIEWPORT_HEIGHT) { |y| Array.new(VIEWPORT_WIDTH) { |x| [glyph_at(x, y), hungry_at?(x, y)] } }
  end

  # The map as rows of [text, hungry] runs: the glyphs, split where a hungry creature is drawn, so a front end
  # can color those in HUNGRY_COLOR
  def map_runs
    cells.map do |row|
      row.chunk_while { |a, b| a[1] == b[1] }.map { |run| [run.map(&:first).join, run.first[1]] }
    end
  end

  # Everything alive or magic in the eight squares around the player: what resting searches out,
  # disguised walls and gold included
  def beside
    @monsters.select { |m| (m.x - @px).abs <= 1 && (m.y - @py).abs <= 1 }
  end

  def alive_nearby?
    beside.any?
  end

  def rows
    Array.new(VIEWPORT_HEIGHT) do |y|
      Array.new(VIEWPORT_WIDTH) { |x| glyph_at(x, y) }.join
    end
  end

  private

  # Builds a fresh level at the current depth, with a cage room from CAGE_DEPTH on
  def build_level
    @map = Array.new(VIEWPORT_HEIGHT) { Array.new(VIEWPORT_WIDTH, "#") }
    @seen = Array.new(VIEWPORT_HEIGHT) { Array.new(VIEWPORT_WIDTH, false) }
    @rooms = []
    @cage = nil
    @cage_room = nil
    @eggs = {}
    @nest = nil

    caged = @depth >= CAGE_DEPTH
    if caged
      @cage_room = { x: rand(1..VIEWPORT_WIDTH - CAGE_ROOM[:w] - 2), y: rand(1..VIEWPORT_HEIGHT - CAGE_ROOM[:h] - 2), **CAGE_ROOM }
      carve_room(@cage_room)
      @rooms << @cage_room
    end

    40.times do
      w = rand(5..11)
      h = rand(3..5)

      if w && h
        room = { x: rand(1..VIEWPORT_WIDTH - w - 2), y: rand(1..VIEWPORT_HEIGHT - h - 2), w: w, h: h }

        next if @rooms.any? { |r| overlap?(r, room) }

        carve_room(room)
        tunnel(center(@rooms.last), center(room)) if @rooms.any?
        @rooms << room
      end

      break if @rooms.size >= 8
    end
    # The tunnels must leave the cage room an end with no way in; on the rare level where they don't, start over
    if caged
      @cage = set_trap(@cage_room) or return build_level
    end
    # Carved first so it fits, the cage room moves second, so the player doesn't start in it
    @rooms.insert(1, @rooms.shift) if caged && @rooms.size >= 3

    @px, @py = center(@rooms.first)
    sx, sy = center(@rooms.last)
    @map[sy][sx] = ">"

    @treasure = {}
    @sandwiches = {}
    @monsters = []
    @detected = []
    @population = Hash.new(0)
    # Plates go down first, so nothing else lands on one: a random plate in about one room in four past the first,
    # and a cage plate in one room that's neither the first nor the cage room
    @plates = {}
    @rooms.drop(1).each { |room| @plates[free_spot(room)] = RANDOM_PLATE if rand(4).zero? }
    plated = (@rooms.drop(1) - [@cage_room]).sample if @cage_room
    @plates[free_spot(plated)] = CAGE_PLATE if plated
    @rooms.drop(1).each do |room|
      rand(0..2).times { @treasure[free_spot(room)] = rand(5..20) * @depth }
      @sandwiches[free_spot(room)] = 1 if rand(3).zero?
      rand(0..2).times { spawn_monster(room) }
    end

    # A potion of sight turns up on about half the levels, whatever its place in the depth ladder
    room = @rooms.drop(1).sample
    spawn_monster(room, THINGAGES.find { |k| k[:name] == "potion" }) if room && rand(2).zero?

    # The Quail is unique, so random spawning skips it; on its cr level one lands about half the time, from
    # QUAIL_DEPTH on every level has one more for each two levels deeper, and from HATCHERY_DEPTH on one of
    # them nests in a hatchery
    quail = THINGAGES.find { |k| k[:name] == "Quail" }
    quails = if @depth >= QUAIL_DEPTH then (@depth - QUAIL_DEPTH) / 2 + 1
             elsif @depth >= quail[:cr] then rand(2)
             else 0
             end
    if quails.positive? && @depth >= HATCHERY_DEPTH
      nest_quail(quail)
      quails -= 1
    end
    quails.times { spawn_monster(@rooms.drop(1).sample || @rooms.first, quail) }

    # A few doors, living walls, stand at the ends of hallways where a tunnel meets a room; food or a coin opens one
    door = THINGAGES.find { |k| k[:name] == "door" }
    hallway_ends.sample(rand(2..door[:na])).each { |spot| spawn_monster(nil, door, at: spot) }

    reveal
  end

  # The cage at one end of room r with no way in: its far TRAP_DEPTH rows or columns, the line across the room
  # just in front of them where the bars will drop, and the plate in the middle of the back row. Of the ends whose
  # cage would have no opening beside it, even a diagonal one, a random one; nil when every end has one
  def set_trap(r)
    xs = r[:x]...r[:x] + r[:w]
    ys = r[:y]...r[:y] + r[:h]
    mid_x = r[:x] + r[:w] / 2
    mid_y = r[:y] + r[:h] / 2
    ends = [
      { xs: xs, ys: ys.first...ys.first + TRAP_DEPTH, line: [xs, ys.first + TRAP_DEPTH], plate: [mid_x, ys.first] },
      { xs: xs, ys: ys.last - TRAP_DEPTH...ys.last, line: [xs, ys.last - TRAP_DEPTH - 1], plate: [mid_x, ys.last - 1] },
      { xs: xs.first...xs.first + TRAP_DEPTH, ys: ys, line: [xs.first + TRAP_DEPTH, ys], plate: [xs.first, mid_y] },
      { xs: xs.last - TRAP_DEPTH...xs.last, ys: ys, line: [xs.last - TRAP_DEPTH - 1, ys], plate: [xs.last - 1, mid_y] },
    ]
    sealed = ends.select do |e|
      e[:xs].to_a.product(e[:ys].to_a).all? do |cx, cy|
        [-1, 0, 1].product([-1, 0, 1]).all? { |dx, dy| xs.cover?(cx + dx) && ys.cover?(cy + dy) || @map[cy + dy][cx + dx] == "#" }
      end
    end
    (chosen = sealed.sample) and chosen.merge(state: :arrangeSet)
  end

  # Inside the cage, behind the line
  def in_trap?(x, y)
    @cage && @cage[:xs].cover?(x) && @cage[:ys].cover?(y)
  end

  # The line's squares, which are bars once the trap is sprung
  def bar?(x, y)
    return false unless @cage&.dig(:state) == :sprung

    lx, ly = @cage[:line]
    (lx.is_a?(Range) ? lx.cover?(x) : lx == x) && (ly.is_a?(Range) ? ly.cover?(y) : ly == y)
  end

  # Stepping onto the plate drops the bars along the line, ending the adventure: everything behind them, the
  # player and their knapsack included, is the haul. Every developed egg in it hatches, and a chick is a win
  def spring_trap
    @cage[:state] = :sprung
    @trapped = true
    caught = @monsters.select { |m| in_trap?(m.x, m.y) }
    floor = ->(items) { items.sum { |spot, n| in_trap?(*spot) ? n : 0 } }
    eggs = @knapsack[:eggs] + @eggs.select { |spot, _| in_trap?(*spot) }.values.flatten
    coins = gold + floor.(@treasure)
    food = sandwiches + floor.(@sandwiches)
    haul = caught.map { |m| a_name(m.name) }
    haul << egg_count(eggs).sub(/ \(.*/, "") if eggs.any?
    haul << "#{coins} gold" if coins.positive?
    haul << "#{food} #{food == 1 ? "sandwich" : "sandwiches"}" if food.positive?
    say "The bars slam down behind you. Your haul: #{haul.empty? ? "nothing but yourself" : and_list(haul)}."

    hatched = eggs.count(&:developed)
    @won = hatched.positive?
    return say("No egg in your haul hatches. The adventure is over.") unless @won

    say "#{hatched == 1 ? "An egg hatches" : "#{hatched} eggs hatch"}, and Quail chicks peep in the cage. You won!"
  end

  # The chance a newly laid egg is developed: a third at HATCHERY_DEPTH, and a ninth more each level deeper,
  # up to 0.9
  def developed_chance = [(@depth - HATCHERY_DEPTH + 3) / 9.0, 0.9].min

  def lay_egg = Egg.new(rand < developed_chance, false)

  # A nest of 1-3 eggs in a room of its own, with a nesting Quail beside it that won't leave while its eggs lie there
  def nest_quail(quail)
    room = (@rooms.drop(1) - [@cage_room]).sample || @rooms.first
    @nest = free_spot(room)
    @eggs[@nest] = Array.new(rand(1..3)) { lay_egg }
    spawn_monster(room, quail)
    @monsters.last.nesting = true
  end

  # Corridor squares, outside every room, that open straight onto a room's floor
  def hallway_ends
    in_room = ->(x, y) { @rooms.any? { |r| x.between?(r[:x], r[:x] + r[:w] - 1) && y.between?(r[:y], r[:y] + r[:h] - 1) } }
    (0...VIEWPORT_HEIGHT).flat_map { |y| (0...VIEWPORT_WIDTH).map { |x| [x, y] } }.select do |x, y|
      @map[y][x] == "." && !in_room.(x, y) && !monster_at(x, y) &&
        [[1, 0], [-1, 0], [0, 1], [0, -1]].any? { |dx, dy| in_room.(x + dx, y + dy) }
    end
  end

  def overlap?(a, b)
    a[:x] - 1 <= b[:x] + b[:w] && b[:x] - 1 <= a[:x] + a[:w] &&
      a[:y] - 1 <= b[:y] + b[:h] && b[:y] - 1 <= a[:y] + a[:h]
  end

  def carve_room(r)
    (r[:y]...r[:y] + r[:h]).each { |y| (r[:x]...r[:x] + r[:w]).each { |x| @map[y][x] = "." } }
  end

  def center(r)
    [r[:x] + r[:w] / 2, r[:y] + r[:h] / 2]
  end

  # L-shaped tunnel, randomly horizontal-first or vertical-first
  def tunnel((x1, y1), (x2, y2))
    if rand(2).zero?
      dig_h(x1, x2, y1)
      dig_v(y1, y2, x2)
    else
      dig_v(y1, y2, x1)
      dig_h(x1, x2, y2)
    end
  end

  def dig_h(x1, x2, y)
    return ([x1, x2].min..[x1, x2].max).each { |x| @map[y][x] = "." if @map[y][x] == "#" }
  end

  def dig_v(y1, y2, x)
    return ([y1, y2].min..[y1, y2].max).each { |y| @map[y][x] = "." if @map[y][x] == "#" }
  end

  def free_spot(room)
    loop do
      spot = [rand(room[:x]...room[:x] + room[:w]), rand(room[:y]...room[:y] + room[:h])]
      next if spot == [@px, @py] || @map[spot[1]][spot[0]] == ">" || spot == @cage&.dig(:plate)
      next if @treasure.key?(spot) || @sandwiches.key?(spot) || @plates.key?(spot) || monster_at(*spot)

      return spot
    end
  end

  # The Ego row describes the player, the only Ego there is, so it never spawns as a monster
  PLAYER_KIND = "Ego"

  # Picks a kind whose cr this depth has reached and whose na this level hasn't filled, skipping the unique
  # (na: 1) and out_of_band kinds; when none is left, nothing spawns. Naming a kind places it regardless, uniques
  # included, though it still counts toward its na; the Ego alone never spawns. It lands on a free spot in the
  # room, or exactly at the given spot
  def spawn_monster(room, kind = nil, at: nil)
    kind ||= THINGAGES.select { |k| k[:na] > 1 && !k[:out_of_band] && k[:cr] <= @depth && @population[k[:name]] < k[:na] }.sample
    (kind && kind[:name] != PLAYER_KIND) or return

    @population[kind[:name]] += 1
    x, y = at || free_spot(room)
    pacifist = kind[:pacifist].is_a?(Float) ? rand < kind[:pacifist] : kind[:pacifist]
    look = kind[:name] == "weapon" ? WEAPONS.sample : kind
    greedy = kind[:greedy] && rand < kind[:greedy]
    hp = [kind[:hp] + @depth + Dungeon.modifier(kind[:con]), 1].max
    @monsters << Thingage.new(x, y, look[:glyph], look[:name], hp, look[:hit], *kind.values_at(*ABILITIES), pacifist, nil, greedy)
                         .tap { |t| t.aggressive = kind[:aggressive] == true }
  end

  # One blow from a thingage: its hit roll plus its strength modifier. A blow that can land at all does at
  # least 1, however weak the striker; a zero or empty hit range (a pacifist's) still does nothing
  def blow(m)
    roll = rand(m.hit).to_i
    return roll unless m.hit&.max.to_i.positive?

    [roll + Dungeon.modifier(m.str), 1].max
  end

  # Walls and the edge of the map block the way
  def wall?(x, y)
    return x.negative? || y.negative? || x >= VIEWPORT_WIDTH || y >= VIEWPORT_HEIGHT || @map[y][x] == "#"
  end

  def monster_at(x, y) return @monsters.find { |m| m.x == x && m.y == y } end

  # The first hit on a pacifist also spurns it; the second on a door makes it give up its pacifism and fight
  def attack(foe)
    dmg = rand(weapon_hit)
    foe.hp -= dmg
    provoked = !foe.pacifist && !foe.aggressive
    foe.aggressive = true unless foe.pacifist
    if foe.hp <= 0
      @monsters.delete(foe)
      return seize(foe) if WEAPONS.any? { |w| w[:name] == foe.name }
      return stow(foe) if SHIELDS.include?(foe.name) || PACKABLE.key?(foe.name)

      say "You defeat the #{foe.name}!"
      explode(foe) if foe.name == "Quail"
    elsif foe.pacifist && !foe.spurned
      foe.spurned = true
      say "You hit the #{foe.name} for #{dmg}.#{" It stops following you." if follower?(foe)}"
    elsif foe.pacifist && foe.name == "door"
      foe.pacifist = false
      foe.spurned = false
      foe.aggressive = true
      say "You hit the door for #{dmg}. It turns on you!"
    else
      say "You hit the #{foe.name} for #{dmg}.#{" It turns on you!" if provoked}"
    end
  end

  # Hands one of the offered item to whatever stands one step dx, dy away; giving takes a turn.
  # Offering to empty floor doesn't, and readies the throw button for that item and direction instead
  def give(item, dx, dy)
    @offering = nil
    taker = monster_at(@px + dx, @py + dy)
    
    unless taker
      @throwable = [item, dx, dy]
      return say("There's no one there to take it.")
    end
    (gaseous? || mist?(taker)) and return say("#{GIFTS[item].capitalize} passes right through the #{taker.name}. You keep it.")

    say "You give the #{taker.name} #{GIFTS[item]}. It #{receive(taker, item)}."
    end_turn
  end

  # Throws a potion up to THROW_RANGE that way: the first touchable character in its path catches it and gains
  # its power; with no one there it shatters. Throwing takes a turn
  def throw_potion(slot, dx, dy)
    @offering = nil
    @knapsack[slot] -= 1
    name = POTIONS[slot][:name]
    x, y = @px, @py
    THROW_RANGE.times do
      break if wall?(x + dx, y + dy)

      x += dx
      y += dy
      next unless (target = monster_at(x, y)) && !mist?(target)

      say "You throw the #{name} at the #{target.name}. #{empower(target, slot)}"
      return end_turn
    end
    say "You throw the #{name} and it shatters on the floor."
    end_turn
  end

  # Sends a laced candle that way, thrown up to THROW_RANGE or kicked up to KICK_RANGE: it stops at the first
  # touchable character in its path, or against a wall, and bursts there. Flinging takes a turn
  def fling_candle(slot, dx, dy)
    how = @flinging
    @offering = @flinging = nil
    @knapsack[slot] -= 1
    x, y = @px, @py
    (how == :kick ? KICK_RANGE : THROW_RANGE).times do
      break if wall?(x + dx, y + dy)

      x += dx
      y += dy
      break if (target = monster_at(x, y)) && !mist?(target)
    end
    burst(x, y, LACED[slot], how == :kick ? "kick" : "throw")
    end_turn
  end

  # The squares a candle bursting at x, y splashes: BURST a side, as near centered on it as an even width allows
  def burst_area(x, y)
    half = BURST / 2
    (x - half...x - half + BURST).to_a.product((y - half...y - half + BURST).to_a)
  end

  # What a burst candle's potion does to the characters it splashes, said once for them all
  BURST_EFFECTS = {
    potions:       "Their eyes blaze: they can see you from anywhere now.",
    speed_potions: "They speed up to two actions for your one!",
    gas_potions:   "They turn to mist!",
    slow_potions:    "They slow to half your pace!",
    healing_potions: "They look healthier.",
    empty_potions:   "Nothing happens. It was empty.",
  }.freeze

  # A laced candle bursts at x, y, and its potion's power washes over every character in the burst area, the
  # player included
  def burst(x, y, potion, verb)
    area = burst_area(x, y)
    caught = @monsters.select { |m| area.include?([m.x, m.y]) }
    splashed = area.include?([@px, @py])
    names = caught.map { |m| "the #{m.name}" } + (splashed ? ["you"] : [])
    say "You #{verb} the candle laced with #{POTIONS[potion][:name]}, and it bursts over " \
        "#{names.empty? ? "empty floor" : and_list(names)}."
    caught.each { |m| empower(m, potion) }
    say BURST_EFFECTS[potion] if caught.any?
    say take_effect(potion) if splashed
  end

  # Gives a thingage a thrown potion's power and says what it does
  def empower(m, slot)
    case slot
    when :potions
      m.farsighted = true
      "Its eyes blaze: it can see you from anywhere now."
    when :speed_potions
      m.hasted = SPEED_ROUNDS
      "It speeds up to two actions for your one!"
    when :gas_potions
      m.gaseous = GAS_ROUNDS
      "It turns to mist!"
    when :slow_potions
      m.slowed = SLOW_ROUNDS
      "It slows to half your pace!"
    when :healing_potions
      m.hp += HEAL_HP
      "It looks healthier."
    when :empty_potions
      "Nothing happens. It was empty."
    end
  end

  # Takes the gift out of the knapsack and says what the taker does with it. A goblin eats a sandwich and stays
  # friendly until hungry again, and any other creature just eats it, either way filling its blood sugar; a
  # pacifist, an ally, or a greedy goblin pockets a coin for good and becomes an
  # ally hoping for more, and a nesting Quail leaves its eggs to follow you; a rat pockets a coin and disengages,
  # staying put and leaving you be; a door takes either
  # and swings open, gone from the hallway. Anyone else just keeps it
  def receive(taker, item)
    @knapsack[item] -= 1
    if taker.name == "door"
      @monsters.delete(taker)
      "#{item == :gold ? "pockets" : "eats"} it and swings open"
    elsif item == :sandwiches && taker.name == "goblin"
      taker.fed = FULL_TURNS
      refill(taker)
      "eats it and likes you, for now"
    elsif item == :sandwiches && eater?(taker)
      refill(taker)
      "eats it"
    elsif item == :gold && (taker.pacifist || taker.ally || (taker.name == "goblin" && taker.greedy))
      taker.coins = taker.coins.to_i + 1
      taker.ally = true
      taker.spurned = false
      taker.nesting = false
      "pockets it and sides with you, hoping for more"
    elsif item == :gold && taker.name == "rat"
      taker.coins = taker.coins.to_i + 1
      taker.spurned = true
      "pockets it and stops fighting you"
    else
      "keeps it"
    end
  end

  def eater?(m) = EATERS.include?(m.name)

  # A sandwich fills a creature's blood sugar back up; one still asleep is full anyway
  def refill(m)
    m.sugar &&= MAX_BLOOD_SUGAR
    m.starving = 0
  end

  # Whether a hungry creature is what's drawn at x, y: the player, or a monster shown there
  def hungry_at?(x, y)
    return hungry? if [x, y] == [@px, @py]
    return false unless (m = monster_at(x, y)) && m.sugar&.zero?

    glyph_at(x, y) == m.glyph
  end

  # Each round the player's blood sugar, and every awake creature's, drops by one; at zero, every STARVE_ROUNDS
  # rounds cost a hit point, which can starve them to death
  def hunger
    if hungry?
      if (@starving += 1) % STARVE_ROUNDS == 0 && !god?
        @hp -= 1
        say "You're starving and lose a hit point."
        say "You starve to death on depth #{@depth} with #{gold} gold." if @hp <= 0
      end
    else
      @blood_sugar -= 1
    end

    @monsters.dup.each do |m|
      next unless m.sugar
      if m.sugar.positive?
        m.sugar -= 1
        next
      end
      next unless ((m.starving = m.starving.to_i + 1) % STARVE_ROUNDS).zero?

      m.hp -= 1
      next if m.hp.positive?

      @monsters.delete(m)
      say "The #{m.name} starves to death."
    end
  end

  # Defeating a shield, or a potion or any other packable thing, packs it into the knapsack, room allowing; with no
  # room, it's left behind
  def stow(foe)
    shield = SHIELDS.include?(foe.name)
    weight = shield ? Dungeon.pounds(Dungeon.packable(foe.name)) : pounds(PACKABLE[foe.name])
    room_for?(weight) or
      return say("You defeat the #{foe.name}, but your knapsack is too full to carry it, so you leave it behind.")

    if shield
      @knapsack[:shields] << { name: foe.name, glyph: foe.glyph }
    else
      @knapsack[PACKABLE[foe.name]] += 1
    end
    say "You defeat the #{foe.name} and pack it into your knapsack."
  end

  # Defeating a weapon seizes it. Empty hands wield it: it shows in the banner and its hit range becomes the player's.
  # A player already wielding one, or seizing a ranged one, packs it into the knapsack instead, room allowing; it
  # keeps the packable weight and ranged flag from its WEAPONS entry
  def seize(foe)
    found = { name: foe.name, glyph: foe.glyph, hit: foe.hit }.merge(WEAPONS.find { |w| w[:name] == foe.name }&.slice(:packable, :ranged) || {})
    if @wielded != FISTS || found[:ranged]
      them = pair?(foe.name) ? "them" : "it"
      room_for?(weapon_pounds(found)) or
        return say("You defeat the #{foe.name}, but your knapsack is too full to carry #{them}, so you leave #{them} behind.")

      @knapsack[:weapons] << found
      return say("You defeat the #{foe.name} and pack #{pair?(foe.name) ? "them" : "it"} into your knapsack.")
    end

    @wielded = found
    say "You defeat the #{foe.name} and seize #{pair?(foe.name) ? "them" : "it"}! You now wield #{weapon}."
  end

  def a_name(name)
    return "a pair of #{name}" if pair?(name)

    "#{name.match?(/\A[aeiou]/i) ? "an" : "a"} #{name}"
  end

  # "a", "a and b", or "a, b, and c"
  def and_list(items)
    items.size < 3 ? items.join(" and ") : "#{items[0...-1].join(", ")}, and #{items.last}"
  end

  def pair?(name)
    WEAPONS.any? { |w| w[:name] == name && w[:pair] }
  end

  # A weapon's glyph and name, e.g. "🪓 axe"; fists have no glyph
  def label(w)
    [w[:glyph], w[:name]].compact.join(" ")
  end

  # Walking into a potion, a scroll, or a ring packs it into the knapsack instead of attacking it; quaff, read, or wear uses it later
  def pack(thing, slot)
    room_for?(pounds(slot)) or return say("Your knapsack is too full for the #{ITEM_NAMES[slot]}.")

    @monsters.delete(thing)
    @knapsack[slot] += 1
    say "You pack #{a_name(ITEM_NAMES[slot])} into your knapsack."
  end

  # Where x, y lies from the player in compass steps, e.g. "12 east and 3 north"
  def bearing(x, y)
    dx, dy = x - @px, y - @py
    steps = []
    steps << "#{dx.abs} #{dx.positive? ? "east" : "west"}" unless dx.zero?
    steps << "#{dy.abs} #{dy.positive? ? "south" : "north"}" unless dy.zero?
    steps.join(" and ")
  end

  # Strews the sandwiches over open floor around where the Quail fell, piling any extras on its own spot
  def explode(foe)
    around = [-1, 0, 1].product([-1, 0, 1]).map { |dx, dy| [foe.x + dx, foe.y + dy] }
    spots = around.reject { |x, y| wall?(x, y) || [x, y] == [@px, @py] || @treasure.key?([x, y]) || monster_at(x, y) }.shuffle
    count = rand(1..5)
    count.times do |i|
      spot = spots[i] || [foe.x, foe.y]
      @sandwiches[spot] = @sandwiches.fetch(spot, 0) + 1
    end
    say "The #{foe.name} explodes into #{count} #{count == 1 ? "sandwich" : "sandwiches"}!"
  end

  # Standing on a teleport plate carries the player off to where it leads, and the new spot comes into view
  def ride_plate
    (plate = @plates[[@px, @py]]) or return

    @px, @py = landing(plate)
    reveal
    say(plate == CAGE_PLATE ? "The plate flashes, and you land in the cage room." :
                               "The plate flashes, and you land somewhere else in the dungeon.")
  end

  # A free spot in the cage room for a cage plate; for a random plate, in a random room, the cage room weighing
  # CAGE_ODDS against every other room's 1
  def landing(plate)
    return free_spot(@cage_room) if plate == CAGE_PLATE

    weights = @rooms.map { |r| r.equal?(@cage_room) ? CAGE_ODDS : 1 }
    pick = rand * weights.sum
    free_spot(@rooms.zip(weights).find { |_, w| (pick -= w).negative? }&.first || @rooms.last)
  end

  # Takes what lies here into the knapsack, as much as it has room for; the rest stays where it lies
  def pick_up
    spot = [@px, @py]
    if (coins = @treasure.delete(spot))
      taken = fitting(coins, pounds(:gold))
      @knapsack[:gold] += taken
      @treasure[spot] = coins - taken if taken < coins
      say taken == coins ? "You find #{coins} gold!" : "You find #{coins} gold, but your knapsack has room for only #{taken}."
    end
    if (count = @sandwiches.delete(spot))
      taken = fitting(count, pounds(:sandwiches))
      @knapsack[:sandwiches] += taken
      @sandwiches[spot] = count - taken if taken < count
      say taken == count ? "You pack #{count == 1 ? "a sandwich" : "#{count} sandwiches"} into your knapsack." :
                           "Your knapsack has room for only #{taken} of the #{count} sandwiches here."
    end
    return unless (laid = @eggs.delete(spot))

    taken = fitting(laid.size, Dungeon.pounds(EGG_POUNDS))
    @eggs[spot] = laid.drop(taken) if taken < laid.size
    return say("Your knapsack is too full for the #{laid.size == 1 ? "egg" : "eggs"}.") if taken.zero?

    @knapsack[:eggs].concat(laid.first(taken))
    left = laid.size - taken
    say "You gather #{taken == 1 ? "an egg" : "#{taken} eggs"} from the nest#{", leaving #{left} for want of room" if left.positive?}."
    nesters = @monsters.select(&:nesting)
    nesters.each { |m| m.nesting = false }
    say "The nesting Quail stirs and follows its eggs!" if nesters.any?
  end

  # Everyone on the player's side in the stairs' room comes down with them, landing in the new level's first room
  def descend
    party = side_in_room
    @depth += 1
    @max_hp += 2
    @hp = [@hp + 5, @max_hp].min
    say "You take the stairs down to depth #{@depth}."
    build_level
    bring_down(party)
  end

  # The player's side: allies, goblins still full from a sandwich, and a Quail following along, unspurned and off
  # its nest. Only those in the same room as the player count
  def side_in_room
    room = @rooms.find { |r| in_room?(r, @px, @py) } or return []
    @monsters.select do |m|
      m.hp.positive? && in_room?(room, m.x, m.y) && (friend?(m) || (follower?(m) && !m.spurned && !m.nesting))
    end
  end

  def in_room?(r, x, y)
    x.between?(r[:x], r[:x] + r[:w] - 1) && y.between?(r[:y], r[:y] + r[:h] - 1)
  end

  def bring_down(party)
    return if party.empty?

    party.each do |m|
      m.x, m.y = free_spot(@rooms.first)
      @monsters << m
    end
    names = and_list(party.map { |m| "the #{m.name}" })
    say "#{names[0].upcase}#{names[1..]} #{party.size == 1 ? "follows" : "follow"} you down."
  end

  # Ends one player action. A hasted player gets two actions per round, so only every second one lets
  # everyone else act, and a slowed one gets one for two rounds, so everyone else acts twice; each round that
  # passes wears down the timed potions
  def end_turn
    return if hasted? && (@quick = !@quick) # the first of a hasted pair: the dungeon waits

    (slowed? ? 2 : 1).times do
      monsters_act
      round_passes
      break if over?
    end
  end

  def round_passes
    if hasted? && (@hasted -= 1).zero?
      @quick = false
      say "You slow back down."
    end
    say "You speed back up." if slowed? && (@slowed -= 1).zero?
    say "You become solid again." if gaseous? && (@gaseous -= 1).zero?
    @monsters.each do |m|
      m.hasted -= 1 if m.hasted.to_i.positive?
      m.slowed -= 1 if m.slowed.to_i.positive?
      m.gaseous -= 1 if m.gaseous.to_i.positive?
    end
    hunger
  end

  # Every monster takes its turn, a hasted one two, and a slowed one only every other round
  def monsters_act
    @monsters.dup.each do |m|
      next if m.hp <= 0 # slain by an ally earlier this turn

      if m.fed.to_i.positive?
        m.fed -= 1
        say "The #{m.name} is hungry again." if m.fed.zero?
      end
      next if m.slowed.to_i.positive? && (m.lagging = !m.lagging) # the round a slowed one sits out
      (m.hasted.to_i.positive? ? 2 : 1).times do
        act(m)
        return if over?
      end
    end
  end

  # Monsters within sight, or anywhere for a farsighted one, chase the player and strike when adjacent. Friends
  # (allies, and goblins still full from a sandwich) follow without striking the player, and an ally strikes a
  # hostile monster beside it instead. Nothing touches a misty thing or a gaseous player, nor wants to
  def act(m)
    return if m.hp <= 0 || m.spurned || m.nesting
    # A neutral thingage stays put and never strikes; friends and the Quail follow, and only the aggressive fight
    return unless m.aggressive || friend?(m) || follower?(m)

    dx = @px - m.x
    dy = @py - m.y
    return if (dx.abs > SIGHT || dy.abs > SIGHT) && !m.farsighted

    m.sugar ||= MAX_BLOOD_SUGAR if eater?(m) # its first act wakes it, and its blood sugar starts running down

    if m.ally && !mist?(m) && (enemy = hostile_beside(m))
      ally_strike(m, enemy)
    elsif dx.abs + dy.abs == 1
      return if m.pacifist || friend?(m) || mist?(m) || gaseous?

      dmg = blow(m)
      return say("The #{m.name} hits you for #{dmg}, but you take no damage.") if god?

      @hp -= dmg
      say "The #{m.name} hits you for #{dmg}."
      say("You die on depth #{@depth} with #{gold} gold.") if over?
    else
      return if gaseous? && !friend?(m) && !follower?(m) # nothing hostile bothers chasing mist
      return if m.name == "door" # an angry door strikes from its hallway but never leaves it

      step = dx.abs >= dy.abs ? [dx <=> 0, 0] : [0, dy <=> 0]
      nx, ny = (follower?(m) && path_step(m)) || [m.x + step[0], m.y + step[1]]
      return if wall?(nx, ny) || monster_at(nx, ny) || [nx, ny] == [@px, @py]

      m.x, m.y = nx, ny
      return unless @plates[[nx, ny]] == RANDOM_PLATE

      say "The #{m.name} steps on a plate and vanishes!" if (nx - @px).abs <= SIGHT && (ny - @py).abs <= SIGHT
      m.x, m.y = landing(RANDOM_PLATE)
    end
  end

  # The first square of the shortest walk from m to beside the player, around walls and other thingages, or nil
  # when no walk gets there. Everything else steps straight at the player and gets stuck behind corners; only
  # the Quail is clever enough to find its way round
  def path_step(m)
    start = [m.x, m.y]
    first = { start => nil } # each square reached, mapped to the first step taken toward it
    queue = [start]
    until queue.empty?
      spot = queue.shift
      [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
        nxt = [spot[0] + dx, spot[1] + dy]
        next if first.key?(nxt) || wall?(*nxt)
        return first[spot] if nxt == [@px, @py]
        next if monster_at(*nxt)

        first[nxt] = first[spot] || nxt
        queue << nxt
      end
    end
    nil
  end

  # A thingage turned to mist by a thrown potion of gaseous form
  def mist?(m)
    m.gaseous.to_i.positive?
  end

  def friend?(m)
    m.ally || m.fed.to_i.positive?
  end

  # The Quail trails the player whatever its mood, until a hit spurns it
  def follower?(m)
    m.name == "Quail"
  end

  # A monster next to m that would fight the player: aggressive, not a pacifist and not a friend. A wall alone
  # comprehends that a paid-off rat has stopped fighting, and spares it; every other ally still strikes it
  def hostile_beside(m)
    @monsters.find do |o|
      next false if m.name == "wall" && paid_off?(o)
      next false if mist?(o)

      !o.equal?(m) && o.hp.positive? && o.aggressive && !o.pacifist && !friend?(o) && (o.x - m.x).abs + (o.y - m.y).abs == 1
    end
  end

  def paid_off?(m)
    m.name == "rat" && m.coins.to_i.positive?
  end

  def ally_strike(ally, enemy)
    dmg = blow(ally)
    enemy.hp -= dmg
    return say("Your #{ally.name} hits the #{enemy.name} for #{dmg}.") if enemy.hp.positive?

    @monsters.delete(enemy)
    say "Your #{ally.name} slays the #{enemy.name}!"
  end

  def reveal
    (@py - SIGHT..@py + SIGHT).each do |y|
      (@px - SIGHT..@px + SIGHT).each do |x|
        @seen[y][x] = true if x.between?(0, VIEWPORT_WIDTH - 1) && y.between?(0, VIEWPORT_HEIGHT - 1)
      end
    end
  end

  def glyph_at(x, y)
    return "@" if [x, y] == [@px, @py]
    marked = monster_at(x, y)
    return marked.glyph if marked && @detected.any? { |d| d.equal?(marked) } # shown by a scroll, near or far
    return " " unless @seen[y][x]

    near = (x - @px).abs <= SIGHT && (y - @py).abs <= SIGHT
    if near && (m = monster_at(x, y)) then m.glyph
    elsif bar?(x, y) then "|"
    elsif @eggs.key?([x, y]) then "0"
    elsif [x, y] == @nest then "&"
    elsif @treasure.key?([x, y]) then "$"
    elsif @sandwiches.key?([x, y]) then "%"
    elsif @plates.key?([x, y]) then @plates[[x, y]]
    elsif [x, y] == @cage&.dig(:plate) then "o"
    else @map[y][x]
    end
  end

  def say(msg)
    @log = (@log + [msg]).last(4)
    nil
  end
end

# The movement pad both front ends draw: label, dx, dy, and the browser keys that press it
PAD = [
  [["↖", -1, -1, "y 7 Home"], ["↑", 0, -1, "k 8 ArrowUp"],  ["↗", 1, -1, "u 9 PageUp"]],
  [["←", -1,  0, "h 4 ArrowLeft"], ["rest", 0,  0, ". 5 Clear"], ["→", 1,  0, "l 6 ArrowRight"]],
  [["↙", -1,  1, "b 1 End"], ["↓", 0,  1, "j 2 ArrowDown"], ["↘", 1,  1, "n 3 PageDown"]],
]

# Serves one shared Dungeon over plain HTTP; each button is a form that POSTs, then redirects back
class WebGame
  attr_reader :game

  def initialize(god: false)
    @god = god
    @game = Dungeon.new(god: @god)
  end

  def serve(port)
    server = begin
      TCPServer.new(port)
    rescue Errno::EADDRINUSE
      abort "Can't start Quail on the Run: port #{port} is already in use. " \
            "Stop whatever is using it (see: lsof -i :#{port}) or choose a different port."
    end
    puts "Quail on the Run at http://localhost:#{port}/"
    loop do
      client = server.accept
      begin
        handle(client)
      rescue StandardError => e
        warn "#{e.class}: #{e.message}"
      ensure
        client.close
      end
    end
  end

  # Returns [status, headers, body]; redirecting after each POST keeps a reload from repeating the move
  def respond(method, target)
    path, query = target.to_s.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h

    if method == "POST"
      case path
      when "/move" then @game.move(params["dx"].to_i.clamp(-1, 1), params["dy"].to_i.clamp(-1, 1))
      when "/rest" then @game.rest
      when "/give"
        item = params["item"].to_s.to_sym
        Dungeon::GIFTS.key?(item) or return [404, {}, "Not found"]
        @game.offer(item)
      when "/inventory" then @game.inventory
      when "/quaff", "/aim"
        item = (params["item"] || "potions").to_sym
        Dungeon::POTIONS.key?(item) or return [404, {}, "Not found"]
        path == "/quaff" ? @game.quaff(item) : @game.aim(item)
      when "/read"
        item = (params["item"] || "scrolls").to_sym
        Dungeon::SCROLLS.key?(item) or return [404, {}, "Not found"]
        @game.read(item)
      when "/wear"
        item = params["item"].to_s.to_sym
        Dungeon::RINGS.key?(item) or return [404, {}, "Not found"]
        @game.wear(item)
      when "/candle" then @game.candle
      when "/pour"
        item = params["item"].to_s.to_sym
        Dungeon::POTIONS.key?(item) or return [404, {}, "Not found"]
        @game.pour(item)
      when "/fling"
        item = params["item"].to_s.to_sym
        how = params["how"].to_s.to_sym
        Dungeon::LACED.key?(item) && %i[throw kick].include?(how) or return [404, {}, "Not found"]
        @game.fling(item, how)
      when "/wield" then @game.wield(params["name"])
      when "/throw" then @game.hurl
      when "/new"  then @game = Dungeon.new(god: @god)
      else return [404, {}, "Not found"]
      end
      return [303, { "Location" => "/" }, ""]
    end

    return [404, {}, "Not found"] unless method == "GET" && path == "/"

    [200, { "Content-Type" => "text/html; charset=utf-8" }, page]
  end

  private

  def handle(client)
    method, target = client.gets.to_s.split
    length = 0
    while (line = client.gets) && line != "\r\n"
      length = line.split(":", 2).last.to_i if line.match?(/\Acontent-length:/i)
    end
    client.read(length) if length.positive?

    status, headers, body = respond(method, target)
    reason = { 200 => "OK", 303 => "See Other", 404 => "Not Found" }[status]
    head = headers.merge("Content-Length" => body.bytesize, "Connection" => "close")
    client.write "HTTP/1.1 #{status} #{reason}\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}"
  end

  def h(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end

  # The map's rows, with each hungry creature wrapped in a span that colors it
  def map_html
    @game.map_runs.map do |runs|
      runs.map { |text, hungry| hungry ? %(<span class="hungry">#{h text}</span>) : h(text) }.join
    end.join("\n")
  end

  def page
    buttons = PAD.flatten(1).map do |label, dx, dy, keys|
      action = dx.zero? && dy.zero? ? "/rest" : "/move?dx=#{dx}&amp;dy=#{dy}"
      # The rest button is underlined while something alive or magic is beside the player, worth searching
      lit = action == "/rest" && @game.alive_nearby?
      %(<form method="post" action="#{action}"><button data-keys="#{h keys}"#{' style="text-decoration: underline"' if lit}>#{label}</button></form>)
    end

    # One button per knapsack entry: gold and sandwiches ready a gift, eggs are held up to the light, a potion
    # quaffs (with throw and pour-into-a-candle buttons beside it), a laced candle is thrown (with a kick button
    # beside it), a scroll reads, a ring is worn, and a weapon kind wields one of them. Plain candles just wait
    packed = @game.contents.map do |text, slot|
      next %(<span>#{h text}</span>) if %i[candles shields].include?(slot)

      if Dungeon::LACED.key?(slot)
        thrower = %(<form method="post" action="/fling?item=#{slot}&amp;how=throw"><button style="width: auto">#{h text}</button></form>)
        kicker = %(<form method="post" action="/fling?item=#{slot}&amp;how=kick"><button style="width: auto">kick</button></form>)
        next %(<div style="display: flex; gap: 4px;">#{thrower}#{kicker}</div>)
      end

      action = if Dungeon::POTIONS.key?(slot) then "/quaff?item=#{slot}"
               elsif Dungeon::SCROLLS.key?(slot) then "/read?item=#{slot}"
               elsif Dungeon::RINGS.key?(slot) then "/wear?item=#{slot}"
               elsif slot == :eggs then "/candle"
               elsif slot.is_a?(Symbol) then "/give?item=#{slot}"
               else "/wield?name=#{URI.encode_www_form_component(slot)}"
               end
      entry = %(<form method="post" action="#{h action}"><button style="width: auto">#{h text}</button></form>)
      next entry unless Dungeon::POTIONS.key?(slot)

      thrower = %(<form method="post" action="/aim?item=#{slot}"><button style="width: auto">throw</button></form>)
      pourer = %(<form method="post" action="/pour?item=#{slot}"><button style="width: auto">pour into candle</button></form>)
      %(<div style="display: flex; gap: 4px;">#{entry}#{thrower}#{pourer}</div>)
    end

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>Quail on the Run</title>
        <style>
          body { background: #111; color: #ddd; font-family: sans-serif; }
          pre { font-size: 15px; line-height: 1.1; overflow-x: auto; }
          .pad { display: grid; grid-template-columns: repeat(3, 60px); gap: 4px; }
          form { margin: 0; }
          button { width: 100%; }
          .below { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-start; gap: 16px; }
          .controls { display: flex; flex-direction: column; gap: 4px; }
          .panel { display: flex; flex-direction: column; gap: 4px; }
          .knapsack { display: flex; flex-direction: column; gap: 4px; margin-bottom: 8px; }
          .hungry { color: #{Dungeon::HUNGRY_COLOR}; }
        </style>
      </head>
      <body style="width: 100%;">
        <main>
        <p>#{"#{@game.outcome} &nbsp; " unless @game.outcome.empty?}#{"GOD MODE &nbsp; " if @game.god?}#{"#{h @game.effects} &nbsp; " unless @game.effects.empty?}HP #{@game.hp}/#{@game.max_hp} &nbsp; AC #{@game.ac} &nbsp; Weapon #{h @game.weapon} &nbsp; Blood sugar #{@game.blood_sugar} &nbsp; Gold #{@game.gold} &nbsp; Sandwiches #{@game.sandwiches} &nbsp; #{@game.load_text} &nbsp; Depth #{@game.depth}</p>
        <pre>#{map_html}</pre>
        <p>#{@game.log.map { |line| h line }.join("<br>")}</p>
        <!-- The map spans the page like a lintel over two posts: the move pad lower left, the knapsack lower right -->
        <div class="below">
          <div class="controls">
            #{%(<form method="post" action="/throw"><button data-keys="t" style="width: auto">throw (t)</button></form>) if @game.can_hurl?}
            <div class="pad">#{buttons.join}</div>
            <form method="post" action="/inventory"><button data-keys="i" style="width: auto">Inventory (i)</button></form>
            <form method="post" action="/wield"><button data-keys="w" style="width: auto">Wield (w)</button></form>
          </div>
          <aside class="panel">
            #{%(<div class="knapsack">Knapsack: #{packed.join}</div>) if packed.any?}
            <form method="post" action="/give?item=gold"><button data-keys="$">give coin ($)</button></form>
            <form method="post" action="/give?item=sandwiches"><button data-keys="%">give sandwich (%)</button></form>
          </aside>
        </div>
        </main>
        <script>
          document.addEventListener("keydown", e => {
            const b = [...document.querySelectorAll("[data-keys]")].find(b => b.dataset.keys.split(" ").includes(e.key))
            if (b) { e.preventDefault(); b.click() }
          })
        </script>
        <form method="post" action="/new"><button style="width: auto">New game</button></form>
      </body>
      </html>
    HTML
  end
end

# Plays the game in a text console, the way the original PC Rogue did. The screen is drawn with ANSI escape
# sequences, the driver commands MS-DOS's ANSI.SYS understood (cursor position, erase, and the 16 colors), and
# the map in the IBM PC's OEM glyphs, code page 437. Keys come in raw, one at a time, Rogue's hjklyubn included
class DosBox
  ESC = "\e"

  # The PC Rogue look: a smiley for the player, shaded walls, dotted floors, a triple bar for the stairs, and so on.
  # A glyph code page 437 has no room for, such as an emoji weapon, becomes Rogue's weapon arrow, or a shield's ]
  OEM = { "@" => "☺", "#" => "▒", "." => "·", ">" => "≡", "$" => "☼", "%" => "♣" }.freeze
  SHIELDS = %w[༺ 𓆩 ༻].freeze
  WEAPON = "↑"

  # The OEM glyphs in code page 437's low, control-code range, which a DOS console still draws rather than obeys
  LOW_GLYPHS = { "☺" => "\x01", "♣" => "\x05", "☼" => "\x0F", "↑" => "\x18" }.freeze

  # The escape sequences a terminal sends for the arrow and keypad keys, named as the browser names them, so the
  # movement PAD reads them all alike
  ESCAPES = {
    "\e[A" => "ArrowUp", "\e[B" => "ArrowDown", "\e[C" => "ArrowRight", "\e[D" => "ArrowLeft",
    "\e[H" => "Home", "\e[1~" => "Home", "\eOH" => "Home", "\e[F" => "End", "\e[4~" => "End", "\eOF" => "End",
    "\e[5~" => "PageUp", "\e[6~" => "PageDown", "\e[E" => "Clear", "\e[G" => "Clear", "\eOE" => "Clear",
    "\e" => "Escape",
  }.freeze

  # Commands that ask which knapsack entry, by its letter, before they act
  PROMPTS = {
    "a" => [:use,   "Use which item?"],
    "T" => [:throw, "Throw which item?"],
    "K" => [:kick,  "Kick which laced candle?"],
    "P" => [:pour,  "Pour which potion into a candle?"],
  }.freeze

  HELP = [
    "Keys",
    "hjklyubn, arrows,",
    "  or keypad: move",
    ". or 5: rest",
    "i: inventory",
    "w: wield",
    "a: use an item",
    "T: throw an item",
    "K: kick a candle",
    "P: pour a potion",
    "$: give a coin",
    "%: give sandwich",
    "t: throw the gift",
    "?: knapsack/keys",
    "N: new game",
    "Q: quit",
  ].freeze

  # The status line, the map, the four log lines, and the prompt
  SCREEN_ROWS = 1 + Dungeon::VIEWPORT_HEIGHT + 4 + 1

  attr_reader :game

  def initialize(god: false)
    @god = god
    @game = Dungeon.new(god: @god)
    @pending = nil
    @note = nil
    @error = nil
    @help = false
    @quit = false
  end

  def quit? = @quit

  # A map glyph as the PC drew it
  def oem(glyph)
    OEM.fetch(glyph) do
      next glyph if glyph.ascii_only?
      next "]" if SHIELDS.include?(glyph)

      glyph.encode(Encoding::IBM437) && glyph.size == 1 ? glyph : WEAPON
    rescue EncodingError
      WEAPON
    end
  end

  # The whole screen as one string of driver commands, for a console width columns wide
  def screen(width = 80)
    lines.each_with_index.map { |line, i| "#{ESC}[#{i + 1};1H#{fit(line, width)}#{ESC}[0m#{ESC}[K" }.join
  end

  # The screen's lines: the status, the map with the knapsack (or the keys) beside it, the log, and a prompt
  def lines
    panel = panel_lines
    map = @game.cells.map do |row|
      row.map { |glyph, hungry| hungry ? "#{ESC}[1;33m#{oem(glyph)}#{ESC}[0m" : oem(glyph) }.join
    end
    map = map.each_with_index.map { |row, i| panel[i] ? "#{row} #{panel[i]}" : row }
    [status] + map + Array.new(4) { |i| @game.log[i].to_s } + [prompt]
  end

  # Handles one key, as read_key names it. Once the game is over, or has broken, only y (play again) and n or Esc
  # (exit) still do anything, besides Q, N, and ?
  def handle(key)
    @note = nil
    return @quit = true if ["Q", "\x03", "\x04"].include?(key)
    return replay if key == "N"
    return answer(key) if @pending
    return @help = !@help if key == "?"
    return play_again(key) if @game.over? || @error

    case key
    when "i" then @game.inventory
    when "w" then @game.wield
    when "t" then @game.hurl
    when "$" then @game.offer(:gold)
    when "%" then @game.offer(:sandwiches)
    else
      if (command = PROMPTS[key])
        @game.contents.empty? ? @note = "Your knapsack is empty." : @pending = command.first
      elsif (pad = PAD.flatten(1).find { |_, _, _, keys| keys.split.include?(key) })
        _, dx, dy = pad
        dx.zero? && dy.zero? ? @game.rest : @game.move(dx, dy)
      end
    end
  end

  # Handles one key as handle does, except that a key that breaks the game is caught, and the player offered a
  # fresh one or a graceful exit
  def press(key)
    handle(key)
  rescue StandardError => e
    @pending = nil
    @error = e
  end

  # Plays until the player quits, then exits gracefully
  def play
    require 'io/console'
    write "#{ESC}[2J#{ESC}[?25l"
    $stdin.raw do |input|
      until quit?
        write screen(($stdout.winsize.last rescue 80))
        press(read_key(input))
      end
    end
  ensure
    write farewell
  end

  # A graceful exit leaves the last screen up, to scroll away like any other output, and puts the colors, the
  # cursor, and the shell's prompt back below it; a game that broke says how, there
  def farewell
    goodbye = "#{ESC}[0m#{ESC}[#{SCREEN_ROWS + 1};1H#{ESC}[?25h\n"
    return goodbye unless @error

    "#{goodbye}The game broke: #{@error.class}: #{@error.message}\n#{@error.backtrace.to_a.first(5).map { |l| "  #{l}\n" }.join}"
  end

  # One key from the console: a plain character, or the name of an arrow, keypad, or Escape key
  def read_key(input)
    key = input.getc or return "Q"
    return key unless key == ESC

    key += input.getc while IO.select([input], nil, nil, 0.05) && !key.match?(/\A\e(\[[\d;]*[A-Za-z~]|O[A-Za-z])\z/)
    ESCAPES.fetch(key, "Escape")
  end

  # Text for the console: as is for a UTF-8 one; for a DOS box in code page 437, glyph for glyph, the low ones
  # included; for any other, with ? for whatever it can't show
  def encode(text, encoding = $stdout.external_encoding || Encoding.default_external)
    return text if encoding == Encoding::UTF_8

    text = text.gsub(Regexp.union(LOW_GLYPHS.keys), LOW_GLYPHS) if encoding == Encoding::IBM437
    text.encode(encoding, undef: :replace, invalid: :replace, replace: "?")
  end

  private

  def write(text)
    $stdout.write(encode(text))
    $stdout.flush
  end

  def status
    g = @game
    banner = g.outcome.empty? ? "" : "#{ESC}[7m #{g.outcome} #{ESC}[0m "
    "#{banner}#{"GOD MODE  " if g.god?}#{"#{g.effects}  " unless g.effects.empty?}HP #{g.hp}/#{g.max_hp}  AC #{g.ac}  " \
      "Weapon #{g.weapon}  Blood sugar #{g.blood_sugar}  Gold #{g.gold}  Sandwiches #{g.sandwiches}  #{g.load_text}  Depth #{g.depth}"
  end

  # The knapsack, each entry lettered for the prompts, or the keys while ? shows them
  def panel_lines
    return HELP if @help

    packed = @game.contents
    return ["Knapsack: empty", "? lists the keys"] if packed.empty?

    ["Knapsack:"] + packed.each_with_index.map { |(text, _), i| "#{(97 + i).chr}) #{text}" }
  end

  def prompt
    return "#{PROMPTS.values.to_h[@pending]} (#{letters}, Esc cancels)" if @pending
    return "#{ending} Play again? (y/n)" if @error || @game.over?
    return @note if @note
    return "Then an arrow sends it that way, or . keeps it" if @game.log.last.to_s.end_with?("which way?")

    "? for the keys"
  end

  # How the game ended, for the play-again offer
  def ending
    return "The game broke (#{@error.class}: #{@error.message})." if @error
    return "You died." if @game.hp <= 0

    @game.won? ? "You won!" : "The adventure is over."
  end

  # Once the game is over: y starts a new one, and n or Esc exits gracefully
  def play_again(key)
    case key
    when "y", "Y" then replay
    when "n", "Escape" then @quit = true
    end
  end

  def replay
    @game = Dungeon.new(god: @god)
    @error = nil
    @pending = nil
  end

  def letters
    last = (96 + @game.contents.size).chr
    last == "a" ? "a" : "a-#{last}"
  end

  # The knapsack letter answers a pending prompt, which then acts as the web page's buttons do
  def answer(key)
    verb = @pending
    @pending = nil
    return if key == "Escape"

    index = key.ord - 97 if key.size == 1
    _, slot = index&.between?(0, 25) && @game.contents[index]
    slot or return @note = "No item #{key}."

    case verb
    when :use
      if Dungeon::POTIONS.key?(slot) then @game.quaff(slot)
      elsif Dungeon::SCROLLS.key?(slot) then @game.read(slot)
      elsif Dungeon::RINGS.key?(slot) then @game.wear(slot)
      elsif Dungeon::LACED.key?(slot) then @game.fling(slot, :throw)
      elsif slot == :eggs then @game.candle
      elsif slot == :candles then @note = "A candle needs a potion poured into it first: P."
      elsif slot == :shields then @note = "There's nothing to do with a shield yet."
      elsif slot.is_a?(Symbol) then @game.offer(slot)
      else @game.wield(slot)
      end
    when :throw
      if Dungeon::POTIONS.key?(slot) then @game.aim(slot)
      elsif Dungeon::LACED.key?(slot) then @game.fling(slot, :throw)
      elsif Dungeon::GIFTS.key?(slot) then @game.offer(slot)
      else @note = "You can't throw that."
      end
    when :kick
      Dungeon::LACED.key?(slot) ? @game.fling(slot, :kick) : @note = "Only a laced candle can be kicked."
    when :pour
      Dungeon::POTIONS.key?(slot) ? @game.pour(slot) : @note = "Only a potion can be poured into a candle."
    end
  end

  # Cuts a line to width visible columns, leaving its escape sequences whole
  def fit(line, width)
    shown = 0
    line.scan(/\e\[[\d;?]*[A-Za-z]|./m).take_while { |piece| piece.start_with?(ESC) || (shown += 1) <= width }.join
  end
end

# What --help prints
USAGE = <<~TEXT
  Quail on the Run, a roguelike

  Usage: ruby rogue.rb [--web [port] | --dos] [--god]
         ruby rogue.rb --help

    (no flags)    play in a desktop window, drawn by Scarpe
    --web [port]  play in a browser instead, at http://localhost:port/ (port 1-65535, default 4567)
    --dos         play right here in the console, like the original PC Rogue: ANSI driver commands, OEM glyphs,
                  and Rogue's keys (? lists them)
    --god         god mode: the player takes no damage
    -h, --help    show this help and exit
TEXT

# Guarded so the tests can require this file for Dungeon without opening a window or a port.
# Scarpe 0.5.0 has no Scarpe.app; requiring scarpe provides Shoes.app instead.
GOD = ARGV.include?("--god")

if $PROGRAM_NAME == __FILE__ && (ARGV & %w[--help -h]).any?
  puts USAGE
elsif $PROGRAM_NAME == __FILE__ && ARGV.include?("--dos")
  DosBox.new(god: GOD).play
elsif $PROGRAM_NAME == __FILE__ && ARGV.include?("--web")
  # The port is whatever follows --web, defaulting to 4567; another flag such as --god there means no port given
  arg = ARGV[ARGV.index("--web") + 1]
  arg = nil if arg&.start_with?("--")
  port = arg ? Integer(arg, exception: false) : 4567
  abort "Usage: ruby rogue.rb --web [port] [--god], where port is 1-65535 (got #{arg.inspect})" unless port&.between?(1, 65_535)

  WebGame.new(god: GOD).serve(port)
elsif $PROGRAM_NAME == __FILE__

gem 'scarpe' # '0.1.0'
require 'scarpe'
Scarpe.app(title: "Scarpe Rogue") do # , width: 560, height: 640) do
  @game = Dungeon.new(god: GOD)

  @status = stack(size: 1){}
  # Newlines become <br>, but runs of spaces still collapse, so blanks go in as non-breaking spaces
  @map = stack(family: "monospace", size: 11){}
  @log = stack(size: 10){}
  @packed = flow {}

  #  make aggressive things attack the TODO weapon and the mobile wall

  redraw = lambda do
    @status.replace "#{"#{@game.outcome}   " unless @game.outcome.empty?}#{"GOD MODE   " if @game.god?}#{"#{@game.effects}   " unless @game.effects.empty?}HP #{@game.hp}/#{@game.max_hp}   AC #{@game.ac}   Weapon #{@game.weapon}   Blood sugar #{@game.blood_sugar}   Gold #{@game.gold}   Sandwiches #{@game.sandwiches}   #{@game.load_text}   Depth #{@game.depth}"
    # Hungry creatures go in as colored spans between the plain runs of the map
    pieces = @game.map_runs.each_with_index.flat_map do |runs, y|
      row = runs.map do |text, hungry|
        text = text.tr(" ", "\u00A0")
        hungry ? span(text, stroke: Dungeon::HUNGRY_COLOR) : text
      end
      y.zero? ? row : ["\n", *row]
    end
    @map.replace(*pieces)
    @log.replace @game.log.join("\n")
    # One button per knapsack entry: gold and sandwiches ready a gift, eggs are held up to the light, a weapon
    # kind wields one of them
    @packed.clear do
      @game.contents.each do |text, slot|
        next para(text) if %i[candles shields].include?(slot) # plain candles wait for a potion; shields, for rules

        if Dungeon::LACED.key?(slot)
          button(text) do
            @game.fling(slot, :throw)
            redraw.call
          end
          button("kick") do
            @game.fling(slot, :kick)
            redraw.call
          end
          next
        end

        button(text) do
          if Dungeon::POTIONS.key?(slot) then @game.quaff(slot)
          elsif Dungeon::SCROLLS.key?(slot) then @game.read(slot)
          elsif Dungeon::RINGS.key?(slot) then @game.wear(slot)
          elsif slot == :eggs then @game.candle
          elsif slot.is_a?(Symbol) then @game.offer(slot)
          else @game.wield(slot)
          end
          redraw.call
        end
        if Dungeon::POTIONS.key?(slot)
          button("throw") do
            @game.aim(slot)
            redraw.call
          end
          button("pour into candle") do
            @game.pour(slot)
            redraw.call
          end
        end
      end
    end
  end

  # Keypress isn't wired up in Scarpe 0.5.0's webview display yet, so moving is by button
  PAD.each do |line|
    flow do
      line.each do |label, dx, dy|
        button(label, width: 60) do
          dx.zero? && dy.zero? ? @game.rest : @game.move(dx, dy)
          redraw.call
        end
      end
    end
  end

  # Each give button readies its gift; the next arrow hands it over
  flow do
    button("give coin") do
      @game.offer(:gold)
      redraw.call
    end
    button("give sandwich") do
      @game.offer(:sandwiches)
      redraw.call
    end
    button("Inventory") do
      @game.inventory
      redraw.call
    end
    button("Wield") do
      @game.wield
      redraw.call
    end
    # Only does anything right after "There's no one there to take it."
    button("throw") do
      @game.hurl
      redraw.call
    end
  end

  flow do
    button("New game") do
      @game = Dungeon.new(god: GOD)
      redraw.call
    end
  end

  redraw.call
end
end
