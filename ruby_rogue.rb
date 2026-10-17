# Run with: ruby ruby_rogue.rb, which plays in the console like the original PC Rogue (the same as --dos)
# Or in a browser: ruby ruby_rogue.rb --web [port], e.g. --web 8080, then open http://localhost:8080/ (default port 4567)
# Or in a desktop window, drawn by Scarpe: ruby ruby_rogue.rb --scarpe
# Add --god to any of them for god mode, where the player takes no damage; --help lists all of these

require 'socket'
require 'uri'
require 'rexml/document'

# The game knows nothing about Scarpe; the app below only draws it and pushes buttons
# The one stream of input events every state table reads: what the player, or prey a hunter sees, does to a
# creature, a piece of furniture, or the cage's plate, and what turns a lock
module StateEvent
  TAP      = :tap
  PUSH     = :push
  HIT      = :hit
  SEE_PREY = :see_prey
  CALM     = :calm # a hunter's prey is gone, or the player paid off a piece of furniture
  FLEE     = :flee # pushed or hit in a tight spot, with a brain to mind it
  SAFE     = :safe # out of the tight spot it fled
  STEP_ON  = :step_on # someone steps onto it, as onto any trap

  # A lock's: a door's, or a sandwich's wrapping
  KEY        = :key        # the key goes in
  REMOVE_KEY = :remove_key # it comes out
  TIMER      = :timer      # the turn it takes runs out
end

class Dungeon

  class ThingState
    def on_entry(*); end
    def on_exit(*); end
  end

  # Each state's on_entry is handed the game, the creature, and who it pursues now: a hunter's prey, :ego for
  # the player, or nil. A quiet one only remembers who that is; an enraged one goes after them
  class QuietState < ThingState
    def on_entry(_game, hunter, target)
      hunter.aggressive = false
      hunter.pursuit_target = target
    end
  end

  class EnragedState < ThingState
    def on_entry(_game, hunter, target)
      hunter.aggressive = true
      hunter.pursuit_target = target
    end
  end

  # A fleeing creature only remembers who it flees; it does nothing but get away from them
  class FleeingState < ThingState
    def on_entry(_game, creature, target)
      creature.pursuit_target = target
    end
  end

  # A tapped quiet creature turns to face the player but won't engage; pushed or hit, one in any state turns on
  # the player, giving up any prey it chased; a quiet hunter that sees its prey goes straight for it, and
  # calming walks an enraged one back to quiet. Pushed or hit in a tight spot, a creature with a brain flees
  # instead, and once it's clear, it turns on the player
  STATE_TRANSITIONS = {
    [QuietState,   StateEvent::TAP]      => QuietState,
    [QuietState,   StateEvent::PUSH]     => EnragedState,
    [QuietState,   StateEvent::HIT]      => EnragedState,
    [QuietState,   StateEvent::SEE_PREY] => EnragedState,
    [EnragedState, StateEvent::PUSH]     => EnragedState,
    [EnragedState, StateEvent::HIT]      => EnragedState,
    [EnragedState, StateEvent::CALM]     => QuietState,
    [QuietState,   StateEvent::FLEE]     => FleeingState,
    [EnragedState, StateEvent::FLEE]     => FleeingState,
    [FleeingState, StateEvent::FLEE]     => FleeingState,
    [FleeingState, StateEvent::SAFE]     => EnragedState,
  }.freeze

  # The Safe Room cage's plate, the o, is snapped or not. Snapping it, by stepping onto it or tapping it,
  # drops the bars and springs the trap; doing either again lifts them. Each state's on_entry is handed the
  # game, which does the work
  class UnsnappedState < ThingState
    def on_entry(game, _plate) = game.lift_bars
  end

  class SnappedState < ThingState
    def on_entry(game, _plate) = game.spring_trap
  end

  CAGE_TRANSITIONS = {
    [UnsnappedState, StateEvent::STEP_ON] => SnappedState,
    [UnsnappedState, StateEvent::TAP]     => SnappedState,
    [SnappedState,   StateEvent::STEP_ON] => UnsnappedState,
    [SnappedState,   StateEvent::TAP]     => UnsnappedState,
  }.freeze

  # cr (challenge rating) is the first depth a kind turns up on, and na (number appearing) caps how many of it
  # one level holds. na: 1 makes a kind unique and out-of-band: random spawning skips it, so it only turns up
  # where the game places it on purpose. out_of_band does the same for a kind with an na above 1.
  # A fractional pacifist is the chance each one spawns pacifist; greedy is the chance a coin will buy it.
  # Only an aggressive kind chases and strikes from the start; every other kind starts neutral, minding its
  # own business until the player hits it. A curious kind comes up to the player and taps them, harmlessly, until
  # the player hits it. A door is a pacifist that turns aggressive on the second hit. An eats
  # kind is a creature with blood sugar, which runs down once it wakes and which a sandwich fills again

  # A lock's Finite State Machine: a door's, and any thingage's whose row has a transitions table. Inserting the key
  # starts unlocking; pulling it out mid-turn locks up again, while waiting out the timer opens it. Once open,
  # pulling the key out leaves it open, and only inserting the key locks it. A table of [state, event] => next
  # state is the one place a machine's shape is written down: TRANSITIONS here, or a row's own transitions
  module DoorLock
    # A state's chores: on_entry as the machine enters it, on_exit as it leaves. Each is handed whatever the
    # machine's transit was, such as the game and the thingage the machine belongs to

    class LockState < ThingState; end
    class UnlockingState < ThingState; end

    # What opening was for: action, which each kind of open state overrides
    class OpenState < ThingState
      def action(*); end
    end

    # An open sandwich, unwrapped and edible. Leaving it is eating it, so on_exit runs its action: 2d6 blood sugar
    # for the eater, and one sandwich gone
    class SandwichOpenState < OpenState
      def on_exit(game, food) = action(game, food)
      def action(game, food) = game.feed(food)
    end

    TRANSITIONS = {
      [LockState,      StateEvent::KEY]        => UnlockingState,
      [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
      [UnlockingState, StateEvent::TIMER]      => OpenState,
      [OpenState,      StateEvent::KEY]        => LockState,
    }.freeze

    # Starts in its initial state, locked unless told otherwise, and moves along its table: the old state's
    # on_exit, then the new state's on_entry, each handed the transit's context. A row back to the same state
    # leaves and re-enters it. An event its state has no row for changes nothing, not even which state object
    # it holds
    class Machine
      attr_reader :state

      def initialize(transitions = TRANSITIONS, initial = LockState)
        @transitions = transitions
        @state = initial.new
      end

      def transit(event, *context)
        target = @transitions[[@state.class, event]]
        return unless target

        @state.on_exit(*context)
        @state = target.new
        @state.on_entry(*context)
      end
    end
  end
  include DoorLock

  doorLikeTransitions = {[LockState,      StateEvent::KEY]        => UnlockingState,
                  [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
                  [UnlockingState, StateEvent::TIMER]      => OpenState,
                  [OpenState,      StateEvent::KEY]        => LockState,}

  THINGAGES = [
    { glyph: "@", name: "Ego", na: 1, cr: 1, hp: 15, ac: 15, str: 15, dex: 15, con: 11, int: 15, wis: 15, cha: 14,  hit: 1..8 },
    { glyph: "🗡", # light sword
      name: "weapon", na: 1, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.66,
      transitions: doorLikeTransitions },
    { glyph: "༺", # shield causes no damage and target wants to go where it nudges
      name: "weapon", na: 1, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.75,
      transitions: doorLikeTransitions },
    { glyph: "𓆩", # light shield causes d6 damage + str or dex or int benefits, one damage event per round is halved
      name: "light shield", na: 10, cr: 3, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.66, packable: 3,
      transitions: doorLikeTransitions },
    { glyph: "༒",  #  double-damage to anyone who is currently aggressive to Ego
      name: "weapon", na: 10, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 10, con: 18, int: 18, wis: 10, cha: 10,  pacifist: 0.65,
      transitions: doorLikeTransitions },
    { glyph: "༻", # shield causes damage yet doubles your protection
      name: "shield", na: 10, cr: 1, hp: 18, hit: 2..12, ac: 20, str: 18, dex: 18, con: 18, int: 10, wis:  1, cha: 10,  pacifist: 0.5, packable: 6,
      transitions: doorLikeTransitions },
    { glyph: "R", name: "rat",      na:  8, cr: 1, hp:  3, hit: 1..2, ac: 10, str:  7, dex: 15, con: 11, int:  2, wis: 10, cha:  4, aggressive: true, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "🐿️", name: "squirrel",      na:  8, cr: 1, hp:  3, hit: 1..2, ac: 10, str:  7, dex: 15, con: 11, int:  2, wis: 10, cha:  4, curious: true, moody: true, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "C", name: "Coyote",   na:  5, cr: 3, hp:  3, hit: 1..2, ac: 10, str: 17, dex: 15, con: 11, int: 16, wis: 15, cha: 14, aggressive: false, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "G", name: "goblin",   na:  8, cr: 2, hp:  6, hit: 1..4, ac: 10, str:  8, dex: 17, con: 10, int: 13, wis: 15, cha: 10, greedy: 0.5, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "O", name: "orc",      na:  5, cr: 4, hp: 10, hit: 2..6, ac: 15, str: 14, dex: 12, con: 17, int: 15, wis: 10, cha: 10, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "T", name: "Troll",    na:  2, cr: 5, hp: 18, hit: 3..8, ac: 15, str: 16, dex: 10, con: 18, int: 10, wis: 10, cha: 10, eats: true,
      transitions: doorLikeTransitions },
    { glyph: "#", name: "wall",     na: 17, cr: 1, hp:  3, hit: 0..0, ac: 10, str: 18, dex:  0, con: 18, int:  0, wis:  0, cha:  0, pacifist: true,
      transitions: doorLikeTransitions },
    { glyph: "#", name: "door",     na:  4, cr: 1, hp: 30, hit: 1..4, ac: 10, str: 18, dex:  0, con: 18, int:  0, wis:  0, cha:  0, pacifist: true, out_of_band: true,
      transitions: doorLikeTransitions },
    { glyph: "=", name: "ring of peace",     na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1,
      transitions: doorLikeTransitions },
    { glyph: "=", name: "ring of strength",     na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1,
      transitions: doorLikeTransitions },
    { glyph: "=", name: "ring of protection",   na:  3, cr: 5, hp: 20, hit: 0..0, ac: 18, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1,
      transitions: doorLikeTransitions },
    { glyph: "i", name: "candle",   na: 10, cr: 3, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 1,
      transitions: doorLikeTransitions },
    { glyph: "¡", name: "potion",   na: 10, cr: 3, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "?", name: "scroll of mapping", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.1,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "slow potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "healing potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "sleep potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "glue potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "slip potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "!", name: "empty potion", na: 3, cr: 3, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 0.5,
      transitions: doorLikeTransitions },
    { glyph: "%", name: "sandwich",   na: 20, cr: 4, hp: 3, hit: 0..0, ac: 2, str: 2, dex: 0, con: 2, int: 0, wis: 0, cha: 0, pacifist: true, packable: 1,
      transitions: {[LockState,      StateEvent::KEY]        => UnlockingState,
                    [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
                    [UnlockingState, StateEvent::TIMER]      => SandwichOpenState,
                    [SandwichOpenState,      StateEvent::KEY]        => LockState,}
    },
    { glyph: "?", name: "scroll of 3 potions", na:  1, cr: 6, hp:  3, hit: 0..0, ac:  2, str:  2, dex:  0, con:  2, int:  0, wis:  0, cha:  0, pacifist: true, packable: 0.1,
      transitions: {[LockState,      StateEvent::KEY]        => UnlockingState,
                    [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
                    [UnlockingState, StateEvent::TIMER]      => OpenState,
                    [OpenState,      StateEvent::KEY]        => LockState,}
    },
    { glyph: "A", name: "Axebeak",    na:  1, cr: 5, hp: 28, hit: 4..9, ac: 15, str: 18, dex: 17, con: 16, int: 15, wis: 14, cha: 13, pacifist: false, eats: true,
      transitions: {[LockState,      StateEvent::KEY]        => UnlockingState,
                    [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
                    [UnlockingState, StateEvent::TIMER]      => OpenState,
                    [OpenState,      StateEvent::KEY]        => LockState,}
    },
    { glyph: "o", name: "cage plate", na: 1, cr: 5, hp: 1, hit: 0..0, ac: 10, str: 0, dex: 0, con: 0, int: 0, wis: 0, cha: 0, pacifist: true, out_of_band: true,
      transitions: CAGE_TRANSITIONS },
    { glyph: "(", name: "toolbag",  na: 2, cr: 1, hp: 3, hit: 0..0, ac: 5, str: 0, dex: 0, con: 0, int: 0, wis: 0, cha: 0, pacifist: true, packable: 2,
      transitions: doorLikeTransitions },
    { glyph: "I", name: "Imp",      na:  4, cr: 2, hp:  3, hit: 1..2, ac: 12, str:  6, dex: 16, con:  8, int:  8, wis:  8, cha:  6, pacifist: true,
      transitions: doorLikeTransitions },
    { glyph: "D", name: "Dodo",     na:  3, cr: 4, hp:  6, hit: 1..2, ac:  8, str:  8, dex:  6, con: 10, int:  2, wis:  2, cha:  6, pacifist: true,
      transitions: doorLikeTransitions },
    { glyph: "Q", name: "Quail",    na:  1, cr: 5, hp: 28, hit: 4..9, ac: 15, str: 18, dex: 17, con: 16, int: 15, wis: 14, cha: 13, pacifist: true, eats: true,
      transitions: {[LockState,      StateEvent::KEY]        => UnlockingState,
        [UnlockingState, StateEvent::REMOVE_KEY] => LockState,
      [UnlockingState, StateEvent::TIMER]      => OpenState,
      [OpenState,      StateEvent::KEY]        => LockState,}

    }
  ]


  # The Ego row describes the player, the only Ego there is, so it never spawns as a monster. The player's hit
  # points, armor class, bare-handed hit, and six ability scores all come from it
  PLAYER_KIND = "Ego"
  PLAYER = THINGAGES.find { |k| k[:name] == PLAYER_KIND }

  # The creatures, by name, that have blood sugar
  EATERS = THINGAGES.select { |k| k[:eats] }.map { |k| k[:name] }.freeze

  # The creatures, by name, that come up and tap the player until they're hit
  CURIOUS = THINGAGES.select { |k| k[:curious] }.map { |k| k[:name] }.freeze

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

  #  put these glyphs into the CRT simulator plz only hide them in DOSBOX mode: def test_glyphs_code_page_437_cannot_hold_become_rogues_weapon_and_armor

  #  potion of out of focusness - Rs become Qs, Qs become Plants, potted plants become quails, Ts become Cs, Cs become
  #  dead bodies stay there until Milda cleans them up

  #  potion of cursed reckless speed thrown at energized enemy enrages them against your nemesis for you
  #  potion of cursed reckless taken by Ego fails all wisdom use checks for energy conservation against Constitution

  #  a goblin, Coyote, or rat assistant makes possible a large following.
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

  # Blood sugar starts full and drops by one every SUGAR_ROUNDS rounds, the player's from the start and a
  # creature's from the round it wakes and first acts. At zero they're hungry, drawn in HUNGRY_COLOR. Running out
  # kills the player outright, unless they're a god; a creature loses a hit point every STARVE_ROUNDS rounds
  # until a sandwich fills it up again
  VIEWPORT_WIDTH  = (48 * 1.3).to_i
  VIEWPORT_HEIGHT = (18 * 1.3).to_i
  SIGHT  = 6
  MAX_BLOOD_SUGAR = 100
  STARVE_ROUNDS = 150
  SUGAR_ROUNDS = 10
  HUNGRY_COLOR = "#e8a33d"

  # fed counts down the turns a goblin stays friendly after a sandwich; an ally keeps the coins it pockets.
  # sugar is a creature's blood sugar, nil until it wakes, and starving counts its rounds at zero.
  # The six ability scores come from the kind's THINGAGES row: str adds to every blow it lands, and con to the
  # hit points it spawns with. dex, int, wis and cha are carried along but nothing reads them yet.
  # slowed counts down the rounds a potion of slowness lasts, and lagging marks the rounds it sits out.
  # weapon is the WEAPONS entry a cloaked weapon-thingage wields, under its cloak's glyph, name, and scores.
  # locked marks a door that tapping won't open, and machine is a sandwich's lock, its wrapping.
  # plate_bound is the random plate a Quail saw the player ride, which it heads for until it steps on.
  # met lists who has met a Quail: :ego for the player, else a thingage's object_id. asleep counts down the rounds a
  # potion of sleep keeps it from acting, and disguised_potion is the POTIONS slot of a potion posing as a creature.
  # state is the STATE_TRANSITIONS machine of a hunter or a piece of furniture, kept apart from machine, a door's
  # lock. pursuit_target is who its state has it after: a hunter's prey, :ego for the player, or nil. devoted marks
  # a Dodo born to follow the player. max_hp is the most hit points resting brings it back to, and struck marks a
  # round it attacked someone, and touched one someone tapped, unwrapped, or hit it, so either way it didn't rest.
  # jammed marks a door a Toolbag failed on, stuck shut until it's bashed through. unhurt counts its rounds in a
  # row without losing a hit point, last_hp being what it had at the end of the last one

  Thingage = Struct.new(:x, :y, :glyph, :name, :hp, :hit, :str, :dex, :con, :int, :wis, :cha, :pacifist, :spurned, :greedy, :fed, :ally, :coins, :aggressive,
                        :hasted, :gaseous, :farsighted, :nesting, :sugar, :starving, :slowed, :lagging, :weapon, :locked, :machine, :plate_bound, :met, :asleep, :stuck,
                        :disguised_potion, :pursuit_target, :state, :devoted, :max_hp, :struck, :touched, :jammed,
                        :unhurt, :last_hp)
  ABILITIES = %i[str dex con int wis cha].freeze

  # The D&D ability modifier: 10 and 11 give +0, and every two points up or down moves it by one.
  # A missing score counts as an average 10
  def self.modifier(score)
    ((score || 10) - 10).div(2)
  end

  # How many turns one sandwich keeps a goblin friendly
  FULL_TURNS = 30

  # What the player swings, and for how much, until they seize something better: the Ego row's hit
  BARE_HANDS = "fists"
  BARE_HANDS_HIT = PLAYER[:hit]
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

  # A ranged weapon is strung while wielded and unstrung in the knapsack. Marching it strung wears the string: the
  # first STRUNG_STEPS steps are safe, and after that each step has a SNAP_CHANCE of snapping it, ruining the bow
  STRUNG_STEPS = 50
  SNAP_CHANCE = 0.05

  # The kinds of shield, by their THINGAGES rows' names. Defeating one packs it; nothing uses a packed one yet
  SHIELDS = ["shield", "light shield"].freeze

  # The hero's armor class: the Ego row's. Nothing reads it in combat yet
  HERO_AC = PLAYER[:ac]

  attr_reader :hp, :max_hp, :ac, :abilities, :blood_sugar, :knapsack, :depth, :log, :wielded, :ring, :experience_points, :hero_level
  # The name the hero gave, for their plaque; nil when the front end never asked
  attr_accessor :hero_name

  # In god mode the player takes no damage; everything else still can. Like a monster's from its row, the
  # player's hit points are the Ego row's plus its con modifier, though never fewer than 1. A game can start at a
  # deeper level, though the player is no tougher for it; only experience raises their level
  def initialize(godMode: false, level: 1)
    @godMode = godMode
    @abilities = PLAYER.slice(*ABILITIES).freeze
    @max_hp = [PLAYER[:hp] + Dungeon.modifier(@abilities[:con]), 1].max
    @ac = HERO_AC
    @hp = @max_hp
    @blood_sugar = MAX_BLOOD_SUGAR
    @sugar_clock = 0
    @wielded = FISTS
    @strung_steps = 0
    @facing = [1, 0]
    @knapsack = { gold: 0, sandwiches: 0, potions: 0, speed_potions: 0, gas_potions: 0, slow_potions: 0, healing_potions: 0,
                  sleep_potions: 0, glue_potions: 0, slip_potions: 0, empty_potions: 0, scrolls: 0, mapping_scrolls: 0, peace_rings: 0, strength_rings: 0, protection_rings: 0,
                  candles: 0, laced_potions: 0, laced_speed_potions: 0, laced_gas_potions: 0, laced_slow_potions: 0,
                  laced_healing_potions: 0, laced_sleep_potions: 0, laced_glue_potions: 0, laced_slip_potions: 0, laced_empty_potions: 0, eggs: [], weapons: [], shields: [], wands: [],
                  slip_wands: [], toolbags: 0 }
    @ring = nil
    @hasted = 0
    @slowed = 0
    @stuck = 0
    @gaseous = 0
    @quick = false
    @won = false
    @trapped = false
    @depth = level
    @start_depth = level
    @caged = { eggs: 0, critters: [] }
    @levels = {}
    @experience_points = 0
    @hero_level = 1
    @log = ["You descend into the dark#{" to depth #{level}" if level > 1}. Find the stairs (>)."]
    build_level
    take_stock
  end

  # The opening story, on the console's splash screen before a hero's first game: wrapped by hand to fit 80 columns
  PREFACE = [
    "        9",
    "      (}       The Situation",
    "     /|",
    "    / )",
    "     /",
    "  ~~~~\\~~~",
    "\n",
    "A rival mad scientist has framed you for the demise of a large flightless quail",
    "species; blackmailing you to return a viable family of the endangered, useless",
    "critters, which seem to lack a survival instinct. The only known specimens now",
    "shelter in bunkers below an illegal genetic research facility during World War 4.5.",
    "Owing to a direct hit to the control bunker, all surviving humans have evacuated",
    "the premises and are unaware of your endeavors, and they have the only passcards.",
    "\n",
    "Your task is to acquire lab resources to improvise a way into the bunkers, obtain",
    "one quail egg and one viable adult, and get them to this ring: o. Step on that ring",
    "to activate the Safe Room with the specimens inside it. On the way you will",
    "encounter drugged & sleeping genetic experiments, and armed security doors. Do not,",
    "under any circumstances, consume their experimental food supplements, infiltrate",
    "locked areas, or abuse the subjects' experimental emergency restraint systems.",
  ].freeze

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

  # Floor traps lie unseen until someone treads on one. A potion of poison breaks underfoot for 2d2 damage and
  # stays a trap, a broken potion on the floor. A wand of slowness slows whoever treads on it for 2d2 rounds, a
  # charge each time; the player picks it up to zap later. A wand holds WAND_CHARGES, refilled on each level
  # the player enters. Each level has a potion of poison on POISON_CHANCE of them, and a wand on WAND_CHANCE
  POISON_CHANCE = 0.5
  WAND_CHANCE = 0.3
  WAND_CHARGES = 3
  BROKEN_POTION = ","
  WAND = "/"

  # A shattered potion of glue leaves glue on the floor, seen by all, which sticks whoever treads in it in place
  # for 2d2 rounds; the glue stays put after
  GLUE = ":"

  # A potion or wand of slipperiness, used on an area, leaves slippery floor, seen by all. Every d3 rounds whoever
  # stands on a slippery square slips off it, as if pushed. Slipperiness and glue cancel: either one landing on the
  # other leaves the floor clean, and frees anyone stuck there. A wand of slipperiness lies about like a wand of
  # slowness, on SLIP_WAND_CHANCE of the levels; treading on one with a charge left slicks the floor around it
  SLIPPERY = "≈"
  SLIP_WAND_CHANCE = 0.3
  OPPOSITE = { glue: :slippery, slippery: :glue }.freeze
  def self.d3 = rand(1..3)

  # Each kind of wand by knapsack slot: the floor trap it lies about as, and what it does. A packed wand is its
  # charges left
  WANDS = {
    wands:      { kind: :wand,      name: "wand of slowness" },
    slip_wands: { kind: :slip_wand, name: "wand of slipperiness" },
  }.freeze

  # The one roller every dice helper calls: count dice of sides faces each, summed, as a d2x2 is two d2
  def self.dice(count, sides) = Array.new(count) { rand(1..sides) }.sum

  def self.d2x2 = dice(2, 2)
  def self.d3x3 = dice(3, 3)

  # The chance a level has a random plate, a teleportation trap; it never has more than one, so fewer than one a
  # level on average
  TELEPORT_CHANCE = 0.5

  # An egg is developed, with legs, wings, and a beak, or just yolk; candled once it's been held up to the light,
  # which also shows a Dodo's egg for what it is
  Egg = Struct.new(:developed, :candled, :dodo)

  # The first depth where a Quail always turns up; shallower than this, from the Quail's cr, it's a coin toss.
  # From here on, every two levels deeper add one more
  QUAIL_DEPTH = 6

  # From this depth on, one of the level's Quails nests in a hatchery: a room of its own with a nest of eggs
  HATCHERY_DEPTH = 8

  def godMode?
    @godMode
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
  def stuck? = @stuck.to_i.positive?
  def gaseous? = @gaseous.positive?

  # The timed potion effects for the banner, e.g. "Hasted 12   Gaseous 3", or "" when none
  def effects
    [("Hasted #{@hasted}" if hasted?), ("Slowed #{@slowed}" if slowed?), ("Stuck #{@stuck}" if stuck?), ("Gaseous #{@gaseous}" if gaseous?)].compact.join("   ")
  end

  # Each kind of potion by knapsack slot: the THINGAGES row it spawns from, its full name, and its glyph.
  # Quaffing one gives the drinker its power, and so does throwing it at a character close by
  POTIONS = {
    potions:         { row: "potion",         name: "potion of sight",        glyph: "¡" },
    speed_potions:   { row: "speed potion",   name: "potion of speed",        glyph: "!", packable: 0.5 },
    gas_potions:     { row: "gas potion",     name: "potion of gaseous form", glyph: "~", packable: 0.5 },
    slow_potions:    { row: "slow potion",    name: "potion of slowness",     glyph: "!" },
    healing_potions: { row: "healing potion", name: "potion of healing",      glyph: "!" },
    sleep_potions:   { row: "sleep potion",   name: "potion of sleep",        glyph: "!" },
    glue_potions:    { row: "glue potion",    name: "potion of glue",         glyph: "!" },
    slip_potions:    { row: "slip potion",    name: "potion of slipperiness", glyph: "!" },
    empty_potions:   { row: "empty potion",   name: "empty potion",           glyph: "!" },
  }.freeze

  # A potion of speed gives two actions for everyone else's one for this many rounds; slowness gives everyone else
  # two for the drinker's one for SLOW_ROUNDS; gaseous form leaves nothing able to touch, or be touched by, the
  # drinker for GAS_ROUNDS. Healing restores the player to full, and a monster, which has no full, by HEAL_HP
  SPEED_ROUNDS = 10
  SLOW_ROUNDS = 20

  # A potion of sleep puts its drinker, or whoever it's thrown at, to sleep for 3d4 rounds while everyone else
  # carries on. Half the potions of sleep that spawn are disguised as a creature, the cloak a weapon would wear,
  # and hurl themselves at the player once within DISGUISE_RANGE
  DISGUISED_SLEEP_CHANCE = 0.5
  DISGUISE_RANGE = 3
  def self.d4x3 = dice(3, 4)

  # A potion of glue, drunk, slows its drinker for SLOW_ROUNDS like slowness. Thrown, it sticks whoever catches it
  # in place for 2d2 rounds. A potion of slipperiness frees its drinker, or whoever catches it, from glue. Wherever
  # either shatters, or a wand of slipperiness strikes, it covers SPLASH_SPOTS squares of floor
  SPLASH_SPOTS = 1..3

  # Drunk, the two potions undo each other: slipperiness cures glue's slowness, and otherwise hastes its drinker
  # for SLIP_HASTE_ROUNDS, longer than a potion of speed; glue drunk while hasted ends the haste and burns for d6,
  # but leaves at least GLUE_BURN_FLOOR hit points
  SLIP_HASTE_ROUNDS = 30
  GLUE_BURN_FLOOR = 3
  def self.d6 = rand(1..6)
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

  # A Toolbag, lying about like any item, works the lock of a locked door the player stands beside
  TOOLS = { toolbags: { row: "toolbag", name: "Toolbag", glyph: "(" } }.freeze
  LACED = POTIONS.keys.to_h { |slot| [:"laced_#{slot}", slot] }.freeze
  BURST = 4
  KICK_RANGE = 3

  # Thingages that walking into packs instead of attacks, with the knapsack slot each goes in and its full name
  ITEMS = POTIONS.merge(SCROLLS).merge(RINGS).merge(CANDLES).merge(TOOLS).freeze
  PACKABLE = ITEMS.to_h { |slot, i| [i[:row], slot] }.freeze
  ITEM_NAMES = ITEMS.transform_values { |i| i[:name] }.freeze

  # How far, in squares each way, a scroll of potion finding or of mapping reaches
  SCROLL_RANGE = 20

  # What one press of each give button hands over, keyed by its knapsack slot
  GIFTS = { gold: "a coin", sandwiches: "a sandwich" }.freeze

  # The most the knapsack holds, in pounds. What's wielded is in hand and what's worn is on a finger, so neither
  # counts. Each thing's weight is the packable on the line that builds it: its THINGAGES row, its WEAPONS entry,
  # or, for a potion with no row of its own, its POTIONS entry. A Quail egg has no line, so it weighs EGG_POUNDS,
  # and gold, which lies about only as @treasure piles, weighs GOLD_POUNDS a coin
  ENCUMBRANCE = 60
  EGG_POUNDS = 0.5
  GOLD_POUNDS = 0.02

  # A weight as an exact fraction, so that, say, 3,000 coins at 0.02 pounds weigh 60 pounds even
  def self.pounds(weight) = Rational(weight.to_s)

  def self.packable(name) = THINGAGES.find { |k| k[:name] == name }&.dig(:packable)

  # Pounds one thing from a knapsack slot weighs; a laced candle is its candle and its potion together
  def pounds(slot)
    return pounds(:candles) + pounds(LACED[slot]) if LACED.key?(slot)

    Dungeon.pounds(case slot
                   when :gold then GOLD_POUNDS
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
    n = @knapsack[:toolbags]
    packed << [n == 1 ? "( Toolbag" : "#{n} ( Toolbags", :toolbags] if n.positive?
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
    WANDS.each do |slot, wand|
      wands = @knapsack[slot]
      next if wands.empty?

      charges = wands.sum
      packed << ["#{wands.size == 1 ? "#{WAND} wand" : "#{wands.size} #{WAND} wands"} #{wand[:name].delete_prefix("wand ")} " \
                 "(#{charges} #{charges == 1 ? "charge" : "charges"})", slot]
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
    when :sleep_potions
      @asleep = Dungeon.d4x3
      "You fall asleep!"
    when :glue_potions
      return ungum_haste if hasted?

      @slowed = SLOW_ROUNDS
      "Your limbs go gummy. Everything else speeds up to twice your pace!"
    when :slip_potions
      freed = "You slip free of the glue! " if stuck?
      @stuck = 0
      if slowed?
        @slowed = 0
        "#{freed}Your limbs loosen, and you're back to your own pace."
      else
        @hasted = SLIP_HASTE_ROUNDS
        @quick = false
        "#{freed}You feel slick all over, and everything else slows to half your pace!"
      end
    when :empty_potions
      "It's empty. Nothing happens."
    end
  end

  # Glue taken while hasted ends the haste instead of slowing, and burns going down: d6 damage, though never
  # enough to leave fewer than GLUE_BURN_FLOOR hit points
  def ungum_haste
    @hasted = 0
    @quick = false
    burn = [Dungeon.d6, @hp - GLUE_BURN_FLOOR].min.clamp(0..)
    slowed = "The glue gums up your speed, and you slow back down."
    return "#{slowed} It burns going down, but you take no damage." if godMode? || burn.zero?

    hurt(burn)
    "#{slowed} It burns going down for #{burn} damage."
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

  # Readies a wand to zap, from that slot, or else the first kind with a charge left; the next arrow zaps it that
  # way, and rest cancels it
  def zap(slot = nil)
    over? and return
    @throwable = nil
    slot ||= WANDS.keys.find { |s| @knapsack[s].any?(&:positive?) } || WANDS.keys.find { |s| @knapsack[s].any? }
    slot && @knapsack[slot].any? or return say("You have no wand to zap.")
    name = WANDS[slot][:name]
    @knapsack[slot].any?(&:positive?) or return say("Your #{name} has no charges left on this level.")

    @offering = WANDS[slot][:kind]
    say "Zap the #{name} which way?"
  end

  # Eggs by whose they are, as gathering tells them apart: "a Quail egg", or "2 Quail eggs and a Dodo egg"
  def egg_kinds(eggs)
    dodos = eggs.count(&:dodo)
    kinds = [["Quail", eggs.size - dodos], ["Dodo", dodos]].select { |_, n| n.positive? }
    and_list(kinds.map { |kind, n| n == 1 ? "a #{kind} egg" : "#{n} #{kind} eggs" })
  end

  # "3 eggs", and once candled, what the light showed, e.g. "3 eggs (1 developed, 1 yolk, 1 unknown)"
  def egg_count(eggs)
    text = "#{eggs.size} #{eggs.size == 1 ? "egg" : "eggs"}"
    candled = eggs.select(&:candled)
    return text if candled.empty?

    developed = candled.count(&:developed)
    seen = ["#{developed} developed", "#{candled.size - developed} yolk", "#{eggs.size - candled.size} unknown",
            "#{candled.count(&:dodo)} Dodo"]
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
    dodos = eggs.count(&:dodo)
    say(eggs.size == 1 ? "It's a Dodo's egg." : "#{dodos == 1 ? "One is" : "#{dodos} are"} a Dodo's.") if dodos.positive?
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
    @strung_steps = 0 # a bow strings fresh as it comes out, and unstrings as it goes in
    say "You now wield #{weapon}."
    end_turn
  end

  # Steps marched with a ranged weapon strung, wearing its string
  attr_reader :strung_steps

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

  # Chooses a knapsack entry, by the slot contents gives it, for the Throw and Give buttons, without using it, as
  # its radio button does; choosing takes no turn. A slot the knapsack doesn't hold chooses nothing
  def choose(slot)
    @chosen = contents.any? { |_, s| s == slot } ? slot : nil
  end

  # The chosen entry's slot, while the knapsack still holds one of it
  def chosen
    @chosen = nil unless contents.any? { |_, s| s == @chosen }
    @chosen
  end

  # What one of a slot's things is called, e.g. "egg", "dagger", or "candle laced with potion of speed"
  def item_noun(slot)
    case slot
    when :gold then "coin"
    when :sandwiches then "sandwich"
    when :eggs then "egg"
    when :candles then "candle"
    when :shields then @knapsack[:shields].first[:name]
    when String then slot
    else LACED.key?(slot) ? "candle laced with #{POTIONS[LACED[slot]][:name]}" : ITEM_NAMES[slot]
    end
  end

  # The Throw and Give buttons' full names, e.g. "Throw egg left?", blank until something's chosen
  def throw_label = "Throw #{chosen ? item_noun(chosen) : "____"} #{DIRECTIONS[@facing]}?"
  def give_label = "Give #{chosen ? item_noun(chosen) : "____"} #{DIRECTIONS[@facing]}?"

  # Throws the chosen thing the way the player faces. A potion, a laced candle, a coin, or a sandwich flies as its
  # own throw always has; anything else is tossed
  def throw_chosen
    over? and return
    @throwable = nil
    slot = chosen or return say("Choose something by its radio button in the knapsack first.")
    dx, dy = @facing
    if POTIONS.key?(slot) then throw_potion(slot, dx, dy)
    elsif LACED.key?(slot)
      @flinging = :throw
      fling_candle(slot, dx, dy)
    elsif GIFTS.key?(slot)
      @throwable = [slot, dx, dy]
      hurl
    else toss(slot, dx, dy)
    end
  end

  # Gives the chosen thing to whoever stands the way the player faces. A coin or a sandwich is taken as giving one
  # always has been; anything else, a creature keeps, wielding a weapon, though a door has no use for it. Giving
  # takes a turn
  def give_chosen
    over? and return
    @throwable = nil
    slot = chosen or return say("Choose something by its radio button in the knapsack first.")
    dx, dy = @facing
    return give(slot, dx, dy) if GIFTS.key?(slot)

    taker = monster_at(@px + dx, @py + dy) or return say("There's no one there to take it.")
    noun = item_noun(slot)
    (gaseous? || mist?(taker)) and return say("The #{noun} passes right through the #{taker.name}. You keep it.")
    taker.name == "door" and return say("The door has no use for #{a_name(noun)}.")

    thing = take_out(slot)
    say "You give the #{taker.name} #{a_name(noun)}. It #{keep(taker, thing)}."
    end_turn
  end

  # The chance a door at a hallway's end spawns locked, so that tapping it won't open it; a gift still will
  DOOR_LOCKED_CHANCE = 0.5

  # Each step's direction, as the tap button names it
  DIRECTIONS = {
    [0, -1] => "up", [0, 1] => "down", [-1, 0] => "left", [1, 0] => "right",
    [-1, -1] => "up-left", [1, -1] => "up-right", [-1, 1] => "down-left", [1, 1] => "down-right",
  }.freeze

  # The way the player last moved, bumped, hit, gave, or threw toward, as [dx, dy]; a new game faces right
  attr_reader :facing

  # The tap button's full name, e.g. "tap left"
  def tap_label = "tap #{DIRECTIONS[@facing]}"

  # The give coin button's full name, e.g. "give coin ($) right"
  def give_coin_label = "give coin ($) #{DIRECTIONS[@facing]}"

  # Hands a coin straight to whoever stands the way the player faces, no asking which way. With no one there it
  # lands on that square, starting a pile of gold there or adding to one. Giving takes a turn; a coin kept, because
  # of a wall or mist, doesn't
  def give_coin
    over? and return
    @throwable = nil
    @offering = nil
    gold.zero? and return say("You have no gold to give.")

    x = @px + @facing[0]
    y = @py + @facing[1]
    if (taker = monster_at(x, y))
      (gaseous? || mist?(taker)) and return say("A coin passes right through the #{taker.name}. You keep it.")

      say "You give the #{taker.name} a coin. It #{receive(taker, :gold)}."
    else
      wall?(x, y) and return say("A wall is in the way. You keep the coin.")

      @knapsack[:gold] -= 1
      @treasure[[x, y]] = @treasure.fetch([x, y], 0) + 1
      say "No one is there, so the coin lands on the floor."
    end
    end_turn
  end

  # The chance the tools in a Toolbag open a locked door; otherwise they jam it shut for good, until it's bashed
  # through
  TOOLS_CHANCE = 0.5

  # A locked door, not yet jammed, in one of the eight squares around the player, when there's a Toolbag in the
  # knapsack to work it with
  def tools_door
    @knapsack[:toolbags].positive? or return nil
    @monsters.find { |m| m.name == "door" && m.locked && !m.jammed && (m.x - @px).abs <= 1 && (m.y - @py).abs <= 1 }
  end

  # Whether there's a locked door beside the player for their Toolbag, for a front end to offer it
  def tools_ready? = !over? && !tools_door.nil?

  # Works the tools in the Toolbag on the locked door beside the player: half the time the lock gives and the door
  # swings open, and half the time the tools jam it shut. Either way it takes a turn, and the Toolbag is kept
  def use_tools
    over? and return
    (door = tools_door) or return say("There's no locked door beside you for the Toolbag.")

    door.touched = true
    if rand < TOOLS_CHANCE
      @monsters.delete(door)
      say "You use the tools in the Toolbag, the lock gives, and the door swings open."
    else
      door.jammed = true
      say "The tools slip and jam the lock. The door is stuck shut; you'll have to bash through it."
    end
    end_turn
  end

  # Taps whatever lies the way the player faces, without violence; tapping takes a turn. An unlocked door swings
  # open, a locked one only rattles, and anyone else just feels the tap
  def tap
    over? and return
    @throwable = nil
    @stairs_question = nil
    @offering = nil
    x = @px + @facing[0]
    y = @py + @facing[1]
    if (m = monster_at(x, y))
      m.touched = true unless gaseous? || mist?(m)
      if gaseous? || mist?(m)
        say "Your tap passes right through the #{m.name}."
      elsif m.name == "door" && m.jammed
        say "You tap the door. It's jammed shut; you'll have to bash through it."
      elsif m.name == "door" && !door_machine(m).state.is_a?(OpenState)
        say "You tap the door. It rattles, but it's locked."
      elsif m.name == "door"
        @monsters.delete(m)
        say "You tap the door, and it swings open."
      elsif m.name == "sandwich"
        unwrap(m, 1)
      elsif tight_spot?(m) && !m.stuck.to_i.positive? && pushable_to?(to = [x + @facing[0], y + @facing[1]])
        m.x, m.y = to
        say "You push the #{m.name}."
        brain?(m) ? scare(m) : provoke_hunter(m, StateEvent::PUSH)
        tread(m)
      else
        say "You tap the #{m.name}."
        provoke_hunter(m, StateEvent::TAP)
      end
    elsif [x, y] == @cage&.dig(:plate)
      press_plate(StateEvent::TAP)
      return if cage_sprung?
    else
      return # tapping a wall or empty air is a bad keystroke: it just disappears, no message and no turn
    end
    end_turn
  end

  # A thingage is in a tight spot, as in a hallway or a corner, when walls close in on all but two of its sides at
  # most, so a tap against it pushes it on a square instead
  def tight_spot?(m) = [[1, 0], [-1, 0], [0, 1], [0, -1]].count { |dx, dy| !wall?(m.x + dx, m.y + dy) } <= 2

  # Whether a thingage has a brain to be scared with: any intelligence at all, unlike a wall, a door, or an item
  def brain?(m) = m.int.to_i.positive?

  def fleeing?(m) = m.state&.state.is_a?(FleeingState)

  # Pushed or hit in a tight spot, a creature with a brain flees the player
  def scare(m)
    state_machine(m).transit(StateEvent::FLEE, self, m, :ego)
    say "The #{m.name} panics and flees!" if (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
  end

  # A fleeing creature steps to whichever open square takes it furthest from the player, until it's out of the
  # tight spot; then it's safe, and turns on the player. Cornered, with nowhere further to go, it stays put
  def flee(m)
    return state_machine(m).transit(StateEvent::SAFE, self, m, :ego) unless tight_spot?(m)
    return if m.stuck.to_i.positive?

    away = ->(x, y) { (x - @px).abs + (y - @py).abs }
    spot = [[1, 0], [-1, 0], [0, 1], [0, -1]].map { |dx, dy| [m.x + dx, m.y + dy] }
                                              .select { |s| pushable_to?(s) && away.(*s) > away.(m.x, m.y) }
                                              .max_by { |s| away.(*s) } or return
    m.x, m.y = spot
    tread(m)
  end

  # Open floor, with no one on it, that a push can move a thingage onto
  def pushable_to?(spot) = !wall?(*spot) && !monster_at(*spot) && spot != [@px, @py]

  # The stairs, by their glyph, and the way each goes. Stepping onto one asks whether to take it
  STAIRS = { ">" => "down", "<" => "up" }.freeze

  # "down" or "up" while the player stands on stairs they've just been asked about, else nil
  attr_reader :stairs_question

  # Answers the stairs question: yes takes the stairs, and no stays put; either way the question is gone. Taking
  # the stairs is the step that reached them, so answering takes no turn of its own
  def take_stairs(yes)
    over? and return
    way = @stairs_question or return
    @stairs_question = nil
    return say("You stay where you are.") unless yes

    way == "down" ? descend : ascend
  end

  # Walking into a monster attacks it; walking onto stairs asks whether to take them
  def move(dx, dy)
    over? and return
    @throwable = nil
    @stairs_question = nil
    @facing = [dx, dy] unless dx.zero? && dy.zero?
    if (item = @offering)
      return fling_candle(item, dx, dy) if LACED.key?(item)
      return zap_wand(dx, dy) if item == :wand
      return zap_slip_wand(dx, dy) if item == :slip_wand

      return POTIONS.key?(item) ? throw_potion(item, dx, dy) : give(item, dx, dy)
    end

    nx = @px + dx
    ny = @py + dy
    # A bad keystroke just disappears: bumping a wall turns the player to face it, and nothing else, not even a turn
    return if wall?(nx, ny)

    if (foe = monster_at(nx, ny))
      gaseous? and return say("You drift against the #{foe.name}, but you can't touch it.")

      if mist?(foe)
        say "Your blow passes right through the misty #{foe.name}."
      elsif (slot = PACKABLE[foe.name])
        pack(foe, slot) or return # a full knapsack says so, and costs no turn
      elsif foe.name == "Quail" && first_meeting?(foe, :ego)
        say "You tap the Quail. It looks you over."
      else
        attack(foe)
      end
    elsif stuck?
      say "You're stuck in the glue."
    else
      @px, @py = nx, ny
      march
      pick_up
      tread_player
      over? and return
      if [@px, @py] == @cage&.dig(:plate)
        press_plate(StateEvent::STEP_ON)
        return if cage_sprung? # springing ends the turn at once
      end
      if (way = STAIRS[@map[@py][@px]])
        @stairs_question = way
        say "You want to go #{way}?"
      end
      ride_plate
    end

    end_turn
    reveal
  end

  def rest
    over? and return
    @throwable = nil
    @stairs_question = nil
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

  # Eating a sandwich from the knapsack wants low blood sugar; a refusal takes no turn. A packed sandwich counts
  # as open, so eating takes a turn and then does what leaving SandwichOpenState does: its action
  def eat
    peckish? or return say("Your blood sugar isn't low enough to want a sandwich.")

    end_turn
    return if over?

    SandwichOpenState.new.action(self, nil)
  end

  # Below this, the player wants a sandwich
  LOW_BLOOD_SUGAR = 50

  def peckish? = @blood_sugar < LOW_BLOOD_SUGAR

  # A sandwich eaten, as SandwichOpenState's action has it: 2d6 blood sugar, up to the most there is, and that
  # sandwich gone, from the floor or, with none given, from the knapsack
  def feed(food)
    gain = rand(1..6) + rand(1..6)
    @blood_sugar = [@blood_sugar + gain, MAX_BLOOD_SUGAR].min
    food ? @monsters.delete(food) : @knapsack[:sandwiches] -= 1
    say "You eat the sandwich. Your blood sugar rises by #{gain}, to #{@blood_sugar}."
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
    @gas = {}
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

    # The player starts on the < that climbs back up, on every level but the first
    @px, @py = center(@rooms.first)
    @upstairs = [@px, @py]
    @map[@py][@px] = "<" if @depth > 1
    sx, sy = center(@rooms.last)
    @map[sy][sx] = ">"
    @downstairs = [sx, sy]

    @treasure = {}
    @sandwiches = {}
    @monsters = []
    @detected = []
    @population = Hash.new(0)
    # Plates go down first, so nothing else lands on one: on TELEPORT_CHANCE of the levels, a random plate in one room
    # past the first, and a cage plate in one room that's neither the first nor the cage room
    @plates = {}
    teleported = @rooms.drop(1).sample if rand < TELEPORT_CHANCE
    @plates[free_spot(teleported)] = RANDOM_PLATE if teleported
    plated = (@rooms.drop(1) - [@cage_room]).sample if @cage_room
    @plates[free_spot(plated)] = CAGE_PLATE if plated
    @traps = {}
    poisoned = @rooms.drop(1).sample if rand < POISON_CHANCE
    @traps[free_spot(poisoned)] = { kind: :poison, seen: false } if poisoned
    wanded = @rooms.drop(1).sample if rand < WAND_CHANCE
    @traps[free_spot(wanded)] = { kind: :wand, seen: false, charges: WAND_CHARGES } if wanded
    slicker = @rooms.drop(1).sample if rand < SLIP_WAND_CHANCE
    @traps[free_spot(slicker)] = { kind: :slip_wand, seen: false, charges: WAND_CHARGES } if slicker
    @rooms.drop(1).each do |room|
      rand(0..2).times { @treasure[free_spot(room)] = rand(5..20) * @depth }
      @sandwiches[free_spot(room)] = 1 if rand < ROOM_SANDWICH_CHANCE * sandwich_odds
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
    hallway_ends.sample(rand(2..door[:na])).each do |spot|
      spawn_monster(nil, door, at: spot)
      @monsters.last.locked = rand < DOOR_LOCKED_CHANCE
    end

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
    sealed.sample
  end

  # Inside the cage, behind the line
  def in_trap?(x, y)
    @cage && @cage[:xs].cover?(x) && @cage[:ys].cover?(y)
  end

  # The cage's plate, a Thingage of its own, built the first time it's wanted, unsnapped, on its CAGE_TRANSITIONS
  CAGE_PLATE_ROW = THINGAGES.find { |k| k[:name] == "cage plate" }

  def cage_plate
    @cage[:arrange_thing] ||= Thingage.new(*@cage[:plate], CAGE_PLATE_ROW[:glyph], CAGE_PLATE_ROW[:name], CAGE_PLATE_ROW[:hp], CAGE_PLATE_ROW[:hit],
                                           *CAGE_PLATE_ROW.values_at(*ABILITIES), true)
                                      .tap { |t| t.machine = Machine.new(CAGE_PLATE_ROW[:transitions], UnsnappedState) }
  end

  def cage_sprung? = !!@cage && cage_plate.machine.state.is_a?(SnappedState)

  # Stepping onto or tapping the plate moves it along its table, unless a threat loose in the unsnapped cage
  # keeps it from budging
  def press_plate(event)
    if !cage_sprung? && (threat = cage_threat)
      return say("The plate won't budge with #{a_name(threat.name)} loose in the cage. Deal with it, then step back on.")
    end

    cage_plate.machine.transit(event, self, cage_plate)
  end

  # The line's squares, which are bars once the trap is sprung
  def bar?(x, y)
    return false unless cage_sprung?

    lx, ly = @cage[:line]
    (lx.is_a?(Range) ? lx.cover?(x) : lx == x) && (ly.is_a?(Range) ? ly.cover?(y) : ly == y)
  end

  # Stepping onto the plate drops the bars along the line: everything behind them, the player and their knapsack
  # included, is the haul. A haul without both an egg and a living Quail is only a practice run, so the adventure
  # goes on behind the bars until the player steps off the plate and back on. Otherwise it ends: every developed
  # egg hatches, and a Quail chick, with a Quail to raise it, is a win
  def spring_trap
    caught = @monsters.select { |m| in_trap?(m.x, m.y) }
    floor = ->(items) { items.sum { |spot, n| in_trap?(*spot) ? n : 0 } }
    eggs = @knapsack[:eggs] + @eggs.select { |spot, _| in_trap?(*spot) }.values.flatten
    coins = gold + floor.(@treasure)
    food = sandwiches + floor.(@sandwiches)
    @caged = { eggs: eggs.size, critters: caught.select { |m| critter?(m) }.map(&:name) }
    haul = caught.map { |m| a_name(m.name) }
    haul << egg_count(eggs).sub(/ \(.*/, "") if eggs.any?
    haul << "#{coins} gold" if coins.positive?
    haul << "#{food} #{food == 1 ? "sandwich" : "sandwiches"}" if food.positive?
    say "The bars slam down behind you. Your haul: #{haul.empty? ? "nothing but yourself" : and_list(haul)}."
    quail = caught.any? { |m| m.name == "Quail" && m.hp.positive? }
    missing = [("an egg" if eggs.empty?), ("a Quail" unless quail)].compact
    return say("Without #{missing.join(" and ")}, step off the plate and back on to lift the bars.") if missing.any?

    @trapped = true
    hatched = eggs.count { |e| e.developed && !e.dodo }
    dodos = eggs.count { |e| e.developed && e.dodo }
    @won = hatched.positive?
    return say("No egg in your haul hatches. The adventure is over.") if (hatched + dodos).zero?
    return say("#{dodos == 1 ? "An egg hatches" : "#{dodos} eggs hatch"}, but only Dodo chicks peep in the Safe Room. " \
               "The adventure is over.") unless @won

    @chicks = hatched
    say "#{hatched == 1 ? "An egg hatches" : "#{hatched} eggs hatch"}, and Quail chicks peep in the Safe Room" \
        "#{", with Dodo chicks among them" if dodos.positive?}. You won!"
    record_hero
  end

  # A winner's final score: SCORE_PER_CHICK for each Quail chick hatched, SCORE_PER_DEPTH for each level down,
  # and a point for each piece of gold carried and each point of experience
  SCORE_PER_CHICK = 100
  SCORE_PER_DEPTH = 50

  def final_score = @chicks.to_i * SCORE_PER_CHICK + @depth * SCORE_PER_DEPTH + gold + @experience_points
  public :final_score

  # A win that earns a plaque also puts the hero's name and final score in heroes.xml; a hall that can't be
  # written to just goes without
  def record_hero
    (@won && plaque?) or return

    Heroes.record(@hero_name.to_s.empty? ? "an unknown hero" : @hero_name, final_score)
  rescue SystemCallError
    nil
  end

  # A danger inside the cage's perimeter that keeps its plate from springing: any troll, or a Coyote in its
  # enraged state, until the player neutralizes it, killing it, winning it over, feeding it, or putting it to sleep
  def cage_threat
    @monsters.find do |m|
      in_trap?(m.x, m.y) && m.hp.positive? && !friend?(m) && !m.asleep.to_i.positive? &&
        (m.name == "Troll" || (m.name == "Coyote" && m.state&.state.is_a?(EnragedState)))
    end
  end

  # A living creature, rather than furniture, an item, or a weapon or shield lying about
  def critter?(m)
    !(FURNITURE + SHIELDS + %w[weapon sandwich]).include?(m.name) && !PACKABLE.key?(m.name) && !m.weapon && !m.disguised_potion
  end

  # A finished game earns a plaque on the wall of fallen heroes, unless it was played as a god or started deep
  def plaque? = over? && !godMode? && @start_depth == 1

  # The plaque's data, for plaque.xslt to fluff: the hero's name and final score, how many eggs and Quails were in the cage when its bars last
  # slammed down, and how many of each other critter, by name. A cage never sprung held nothing
  def plaque_xml
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new("1.0", "UTF-8")
    plaque = doc.add_element("plaque")
    plaque.add_element("name").text = @hero_name.to_s
    plaque.add_element("score").text = final_score.to_s
    quails, others = @caged[:critters].partition { |name| name == "Quail" }
    plaque.add_element("eggs").text = @caged[:eggs].to_s
    plaque.add_element("quails").text = quails.size.to_s
    others.tally.sort.each { |name, count| plaque.add_element("critter", "name" => name).text = count.to_s }
    doc.to_s
  end
  public :plaque?, :plaque_xml # the front ends ask for the plaque, from down here among the private helpers

  # Stepping back onto the plate of a cage sprung without an egg lifts the bars, setting the trap again
  def lift_bars
    say "The bars lift, and the trap is set again."
  end
  public :spring_trap, :lift_bars # the plate's states call these

  # The chance a newly laid egg is developed: a third at HATCHERY_DEPTH, and a ninth more each level deeper,
  # up to 0.9
  def developed_chance = [(@depth - HATCHERY_DEPTH + 3) / 9.0, 0.9].min

  # The chance an egg in a Quail's nest was slipped there by a Dodo
  NEST_DODO_CHANCE = 0.25

  def lay_egg = Egg.new(rand < developed_chance, false, (true if rand < NEST_DODO_CHANCE))

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
      next if spot == [@px, @py] || STAIRS.key?(@map[spot[1]][spot[0]]) || spot == @cage&.dig(:plate)
      next if @treasure.key?(spot) || @sandwiches.key?(spot) || @plates.key?(spot) || @traps&.key?(spot) || monster_at(*spot)

      return spot
    end
  end

  # Picks a kind whose cr this depth has reached and whose na this level hasn't filled, skipping the unique
  # (na: 1) and out_of_band kinds; when none is left, nothing spawns. Naming a kind places it regardless, uniques
  # included, though it still counts toward its na; the Ego alone never spawns. It lands on a free spot in the
  # room, or exactly at the given spot.
  # A weapon row spawns one of the WEAPONS, cloaked as a creature of this depth: it shows that creature's glyph and
  # name, has its hit points, scores, and temper, and wields the weapon, hitting for its range. It lies dormant
  # until woken, then fights as that creature, weapon in hand; defeating it drops the weapon
  def spawn_monster(room, kind = nil, at: nil)
    chosen = kind
    kind ||= THINGAGES.select { |k| k[:na] > 1 && !k[:out_of_band] && k[:cr] <= @depth && @population[k[:name]] < k[:na] }.sample
    (kind && kind[:name] != PLAYER_KIND) or return
    return if !chosen && kind[:name] == "sandwich" && rand >= sandwich_odds # deeper, a sandwich turns up less

    @population[kind[:name]] += 1
    x, y = at || free_spot(room)
    weapon = WEAPONS.sample if kind[:name] == "weapon"
    disguised = :sleep_potions if kind[:name] == "sleep potion" && rand < DISGUISED_SLEEP_CHANCE
    body = weapon || disguised ? cloak_for(@depth) : kind
    pacifist = weapon || disguised ? false : kind[:pacifist].is_a?(Float) ? rand < kind[:pacifist] : kind[:pacifist]
    greedy = body[:greedy] && rand < body[:greedy]
    hp = [body[:hp] + @depth + Dungeon.modifier(body[:con]), 1].max
    @monsters << Thingage.new(x, y, body[:glyph], body[:name], hp, (weapon || body)[:hit], *body.values_at(*ABILITIES), pacifist, nil, greedy)
                         .tap { |t| t.aggressive = body[:aggressive] == true }
                         .tap { |t| t.weapon = weapon }
                         .tap { |t| t.disguised_potion = disguised }
                         .tap { |t| t.devoted = rand < DODO_DEVOTED_CHANCE if t.name == "Dodo" }
                         .tap { |t| t.max_hp = t.hp }
  end

  # The creatures a dormant weapon cloaks itself as
  # TODO  make this work:  CLOAKS = %w[rat 🐿 wren Coyote goblin troll axebeak].freeze
  CLOAKS = %w[rat squirrel wren Coyote goblin Troll Axebeak].freeze

  # The cloak of the appropriate challenge rating for a depth: the toughest whose cr the depth has reached, or,
  # shallower than all of t4hem, the mildest
  def cloak_for(depth)
    cloaks = THINGAGES.select { |k| CLOAKS.include?(k[:name]) }
    cloaks.select { |k| k[:cr] <= depth }.max_by { |k| k[:cr] } || cloaks.min_by { |k| k[:cr] }
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
    return x.negative? || y.negative? || x >= VIEWPORT_WIDTH || y >= VIEWPORT_HEIGHT || @map[y][x] == "#" || bar?(x, y)
  end

  def monster_at(x, y) return @monsters.find { |m| m.x == x && m.y == y } end

  # The first hit on a pacifist also spurns it; the second on a piece of furniture enrages it, giving up its
  # pacifism to fight
  def attack(foe)
    dmg = rand(weapon_hit)
    foe.touched = true
    return unwrap(foe, dmg) if foe.name == "sandwich"
    return capture(foe) if foe.ally && useful?(foe)

    foe.hp -= dmg
    ouch(dmg)
    provoked = !foe.pacifist && !foe.aggressive
    foe.aggressive = true unless foe.pacifist
    cornered = foe.hp.positive? && brain?(foe) && tight_spot?(foe) # before any knock back moves it
    if foe.hp <= 0
      @monsters.delete(foe)
      return say("The #{foe.name} shatters: it was a #{POTIONS[foe.disguised_potion][:name]} in disguise!") if foe.disguised_potion
      return seize(foe) if armed?(foe)
      return stow(foe) if SHIELDS.include?(foe.name) || PACKABLE.key?(foe.name)

      say "You defeat the #{foe.name}!"
      explode(foe) if foe.name == "Quail"
      drop_dodo_sandwich(foe) if foe.name == "Dodo"
    elsif foe.pacifist && !foe.spurned
      foe.spurned = true
      say "You hit the #{foe.name} for #{dmg}.#{" It stops following you." if follower?(foe)}"
      knock_back(foe, foe.x - @px, foe.y - @py) if foe.name == "Quail"
    elsif foe.pacifist && FURNITURE.include?(foe.name)
      foe.pacifist = false
      foe.spurned = false
      state_machine(foe).transit(StateEvent::HIT, self, foe, :ego)
      say "You hit the #{foe.name} for #{dmg}. It turns on you!"
    else
      say "You hit the #{foe.name} for #{dmg}.#{" It turns on you!" if provoked && !cornered}"
      knock_back(foe, foe.x - @px, foe.y - @py) if foe.name == "Quail"
    end
    return unless foe.hp.positive?

    cornered ? scare(foe) : provoke_hunter(foe, StateEvent::HIT)
  end

  # A potion disguised as a creature, once the player is within DISGUISE_RANGE, drops the disguise and hurls itself
  # at them, shattering. False when it isn't a disguised potion or the player is out of range
  def hurl_self(m)
    (slot = m.disguised_potion) or return false
    return false if gaseous? || (m.x - @px).abs > DISGUISE_RANGE || (m.y - @py).abs > DISGUISE_RANGE

    @monsters.delete(m)
    say "The #{m.name} is a #{POTIONS[slot][:name]} in disguise! It hurls itself at you and shatters. #{take_effect(slot)}"
    true
  end

  # Whether this is who's first meeting with a Quail, who being :ego or a thingage; it's remembered either way
  def first_meeting?(quail, who)
    id = who == :ego ? :ego : who.object_id
    quail.met ||= []
    return false if quail.met.include?(id)

    quail.met << id
    true
  end

  # A hit Quail is knocked back a square, away from whoever struck it, and any Quails lined up behind it are
  # knocked back with it; a wall, or anyone else, at the end of the line holds them all in place
  def knock_back(quail, dx, dy)
    line = [quail]
    while (behind = monster_at(line.last.x + dx, line.last.y + dy)) && behind.name == "Quail"
      line << behind
    end
    pushable_to?([line.last.x + dx, line.last.y + dy]) or return
    return if line.any? { |q| q.stuck.to_i.positive? } # glue holds the line in place

    line.reverse_each { |q| q.x += dx; q.y += dy }
    line.each { |q| tread(q) }
    seen = (quail.x - @px).abs <= SIGHT && (quail.y - @py).abs <= SIGHT
    say(line.size == 1 ? "The Quail is knocked back." : "The Quails are knocked back.") if seen
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

  # Takes one thing out of a knapsack slot and returns it: an egg, a weapon, or a shield as itself, and anything
  # counted as its slot
  def take_out(slot)
    case slot
    when :eggs then @knapsack[:eggs].shift
    when :shields then @knapsack[:shields].shift
    when String then @knapsack[:weapons].delete_at(@knapsack[:weapons].index { |w| w[:name] == slot })
    else
      @knapsack[slot] -= 1
      slot
    end
  end

  # A creature keeps what it's given or catches. A weapon it wields from then on, hitting for its range, and
  # drops when defeated
  def keep(taker, thing)
    return "keeps it" unless thing.is_a?(Hash) && thing[:hit]

    taker.weapon = thing
    taker.hit = thing[:hit]
    "wields it"
  end

  # Tosses anything with no throw of its own up to THROW_RANGE that way. The first touchable creature in its path
  # catches and keeps it, wielding a weapon; a wall or a door stops it short. Landing, an egg breaks, and anything
  # else lies there as itself, to pack again, or, a weapon or a shield, to defeat and take again. Tossing takes a
  # turn
  def toss(slot, dx, dy)
    noun = item_noun(slot)
    x, y = @px, @py
    landing = nil
    catcher = nil
    THROW_RANGE.times do
      ahead = monster_at(x + dx, y + dy)
      break if wall?(x + dx, y + dy) || ahead&.name == "door"

      x += dx
      y += dy
      break if (catcher = ahead) && !mist?(ahead)

      catcher = nil
      landing = [x, y] unless ahead # nothing lands on a misty thing it sails through
    end
    return say("Something is in the way. You keep the #{noun}.") if catcher.nil? && landing.nil?

    thing = take_out(slot)
    if catcher
      say "You throw #{a_name(noun)}, and the #{catcher.name} catches it. It #{keep(catcher, thing)}."
    elsif slot == :eggs
      say "You throw an egg, and it breaks on the floor."
    else
      drop(thing, slot, *landing)
      say "You throw #{a_name(noun)}, and it lands on the floor."
    end
    end_turn
  end

  # A tossed thing lying at x, y, as a thingage of its own: walking into it packs it again, or, for a weapon or a
  # shield, strikes it, and defeating it seizes or stows it
  def drop(thing, slot, x, y)
    name, glyph, hit =
      case slot
      when String, :shields then [thing[:name], thing[:glyph], thing[:hit] || (0..0)]
      else [ITEMS[slot][:row], ITEMS[slot][:glyph], 0..0]
      end
    row = THINGAGES.find { |k| k[:name] == name } || THINGAGES.find { |k| k[:name] == "weapon" }
    @monsters << Thingage.new(x, y, glyph, name, 1, hit, *row.values_at(*ABILITIES), true)
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
      say "It shatters, #{splash_words(SPLASHES[slot], *spread(SPLASHES[slot], x, y))}." if SPLASHES.key?(slot)
      return end_turn
    end
    if SPLASHES.key?(slot)
      say "You throw the #{name} and it shatters, #{splash_words(SPLASHES[slot], *spread(SPLASHES[slot], x, y))}."
    elsif slot == :sleep_potions
      n = gas_cloud(x, y)
      say "You throw the #{name} and it shatters, leaving sleeping gas over #{n} #{n == 1 ? "square" : "squares"}."
    else
      say "You throw the #{name} and it shatters on the floor."
    end
    end_turn
  end

  # A potion of sleep shattering on the floor leaves a cloud of sleeping gas, drawn as SLEEP_GAS, over d3 squares
  # for SLEEP_GAS_ROUNDS rounds. Anyone starting a turn in it makes a Constitution check, a d20 plus their con
  # modifier against SLEEP_GAS_DC, or sleeps for 2d2 rounds
  SLEEP_GAS = "░"
  SLEEP_GAS_ROUNDS = 20
  SLEEP_GAS_DC = 12

  # Where the potion shattered, then its open neighbors, up to d3 squares in all; returns how many
  def gas_cloud(x, y)
    near = [[1, 0], [-1, 0], [0, 1], [0, -1]].map { |dx, dy| [x + dx, y + dy] }.shuffle
    spots = ([[x, y]] + near).reject { |s| wall?(*s) }.first(Dungeon.d3)
    spots.each { |s| @gas[s] = SLEEP_GAS_ROUNDS }
    spots.size
  end

  def con_check(con) = rand(1..20) + Dungeon.modifier(con) >= SLEEP_GAS_DC

  # A monster starting its turn in the gas that fails its check falls asleep, and loses the turn
  def gassed?(m)
    @gas&.key?([m.x, m.y]) && !mist?(m) or return false
    con_check(m.con) and return false

    m.asleep = Dungeon.d2x2
    say "The #{m.name} breathes the sleeping gas and falls asleep." if (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
    true
  end

  # The player, starting their turn in the gas, sleeps through 2d2 rounds each time they fail the check
  def breathe_gas
    while !over? && !gaseous? && @gas&.key?([@px, @py]) && !con_check(@abilities[:con])
      @asleep = Dungeon.d2x2
      say "You breathe the sleeping gas and fall asleep."
      doze
    end
  end

  # Each round the gas thins, and after SLEEP_GAS_ROUNDS it's gone
  def thin_gas
    @gas&.transform_values! { |rounds| rounds - 1 }
    @gas&.delete_if { |_, rounds| rounds <= 0 }
  end

  # The potions that, shattering, leave something on the floor, and what
  SPLASHES = { glue_potions: :glue, slip_potions: :slippery }.freeze

  # Glue or slipperiness lands at x, y and covers SPLASH_SPOTS squares of floor: that one, then its open
  # neighbors. It never covers a plate or any other trap, and where it meets its opposite the two cancel, leaving
  # clean floor and freeing anyone stuck there. Returns how many squares it covered, and how many it cleaned
  def spread(kind, x, y)
    @traps ||= {}
    near = [[1, 0], [-1, 0], [0, 1], [0, -1]].map { |dx, dy| [x + dx, y + dy] }.shuffle
    spots = ([[x, y]] + near).reject { |s| wall?(*s) || @plates.key?(s) || (@traps.key?(s) && !OPPOSITE.key?(@traps[s][:kind])) }
    spots = spots.first(rand(SPLASH_SPOTS))
    cleaned = spots.select { |s| @traps[s]&.dig(:kind) == OPPOSITE[kind] }
    cleaned.each do |s|
      @traps.delete(s)
      @stuck = 0 if s == [@px, @py]
      monster_at(*s)&.stuck = 0
    end
    (spots - cleaned).each { |s| @traps[s] = { kind: kind, seen: true }.merge(kind == :slippery ? { slip_in: Dungeon.d3 } : {}) }
    [spots.size - cleaned.size, cleaned.size]
  end

  # What a splash of glue or slipperiness did to the floor, e.g. "gluing 2 squares of floor and cleaning 1 square
  # of slippery floor"
  def splash_words(kind, covered, cleaned)
    squares = ->(n) { "#{n} #{n == 1 ? "square" : "squares"}" }
    covering = "#{kind == :glue ? "gluing" : "slicking"} #{squares.(covered)} of floor"
    return covering if cleaned.zero?

    cleaning = "cleaning #{squares.(cleaned)} of #{kind == :glue ? "slippery floor" : "glue"}"
    covered.zero? ? cleaning : "#{covering} and #{cleaning}"
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
    sleep_potions:   "They fall asleep!",
    glue_potions:    "They're stuck fast!",
    slip_potions:    "Any glue lets go of them.",
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
    when :sleep_potions
      m.asleep = Dungeon.d4x3
      "It falls asleep!"
    when :glue_potions
      m.stuck = Dungeon.d2x2
      "It's stuck fast!"
    when :slip_potions
      freed = m.stuck.to_i.positive?
      m.stuck = 0
      freed ? "It slips free of the glue!" : "It looks slick for a moment."
    when :empty_potions
      "Nothing happens. It was empty."
    end
  end

  # Takes the gift out of the knapsack and says what the taker does with it. A goblin eats a sandwich and stays
  # friendly until hungry again, and any other creature just eats it, either way filling its blood sugar; a
  # pacifist, an ally, or a greedy goblin pockets a coin for good and becomes an
  # ally hoping for more, and a nesting Quail leaves its eggs to follow you; a rat pockets a coin and disengages,
  # staying put and leaving you be; a door takes either
  # and swings open, gone from the hallway. Enraged furniture takes a coin to calm down, and throws a sandwich
  # back. Anyone else just keeps it
  def receive(taker, item)
    @knapsack[item] -= 1
    return appease(taker, item) if FURNITURE.include?(taker.name) && state_machine(taker).state.is_a?(EnragedState)
    return win_over(taker) if item == :gold && useful?(taker) && agitated?(taker)

    if taker.name == "door" && taker.jammed
      @knapsack[item] += 1
      return "won't take it, being jammed shut, so you keep it"
    end
    return coin_lock(taker) if taker.name == "door" && item == :gold && taker.locked
    return imp_opens(taker) if taker.name == "door" && item == :sandwiches && taker.locked

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
    elsif item == :gold && taker.name == "squirrel" && state_machine(taker).state.is_a?(EnragedState)
      taker.coins = taker.coins.to_i + 1
      state_machine(taker).transit(StateEvent::CALM, self, taker, nil)
      "pockets it and calms down, curious again"
    elsif item == :gold && taker.name == "rat"
      taker.coins = taker.coins.to_i + 1
      taker.spurned = true
      "pockets it and stops fighting you"
    else
      "keeps it"
    end
  end

  def eater?(m) = EATERS.include?(m.name)

  # The chance a coin opens a locked door, and, when it doesn't, that the door won't take it, so the player keeps
  # it; otherwise the door pockets the coin and stays locked
  COIN_LOCK_CHANCE = 0.25
  COIN_KEPT_CHANCE = 0.5

  def coin_lock(door)
    if rand < COIN_LOCK_CHANCE
      @monsters.delete(door)
      return "pockets it, the lock clicks, and the door swings open"
    end
    return "pockets it, but the lock holds" unless rand < COIN_KEPT_CHANCE

    @knapsack[:gold] += 1
    "won't take it, and the lock holds, so you keep your coin"
  end

  # The chance a locked door, offered a sandwich, draws an Imp to it
  IMP_CHANCE = 0.25

  # A locked door has no mouth for a sandwich, but now and then an Imp, one within sight of the door or a new one
  # beside it, sets upon the sandwich, and the door swings open. Otherwise the player keeps the sandwich
  def imp_opens(door)
    unless rand < IMP_CHANCE
      @knapsack[:sandwiches] += 1
      return "won't take it while it's locked, so you keep it"
    end

    @monsters.delete(door)
    beside = [[1, 0], [-1, 0], [0, 1], [0, -1]].map { |dx, dy| [door.x + dx, door.y + dy] }.select { |s| pushable_to?(s) }
    spot = beside.first || [door.x, door.y]
    near = ->(m) { (m.x - door.x).abs <= SIGHT && (m.y - door.y).abs <= SIGHT }
    if (imp = @monsters.find { |m| m.name == "Imp" && m.hp.positive? && near.(m) })
      imp.x, imp.y = spot unless beside.empty?
    else
      spawn_monster(nil, THINGAGES.find { |k| k[:name] == "Imp" }, at: spot)
    end
    "draws an Imp, which sets upon the sandwich, and the door swings open"
  end

  # The # kinds, a wall and a door, whose states a hit enrages and a coin walks back
  FURNITURE = THINGAGES.select { |k| k[:glyph] == "#" }.map { |k| k[:name] }.freeze

  # The chance a sandwich enraged furniture throws back lands still fit to eat
  SOILED_EDIBLE_CHANCE = 0.5

  # Enraged furniture, given a coin, calms back to quiet and spurned, a pacifist again that a second coin can
  # win over. Given a sandwich, it throws it back: sometimes it lands at the player's feet, soiled but edible,
  # and sometimes it's ruined
  def appease(taker, item)
    if item == :gold
      state_machine(taker).transit(StateEvent::CALM, self, taker, nil)
      taker.pacifist = true
      taker.spurned = true
      return "pockets it and calms down, though it's still sore"
    end
    return "throws it back at you, and it splats, ruined" unless rand < SOILED_EDIBLE_CHANCE

    @sandwiches[[@px, @py]] = @sandwiches.fetch([@px, @py], 0) + 1
    "throws it back at you, and it lands at your feet, soiled but still edible"
  end

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

  # Every SUGAR_ROUNDS rounds the player's blood sugar, and every awake creature's, drops by one; at zero, every
  # STARVE_ROUNDS rounds cost a creature a hit point, which can starve it to death
  def hunger
    drain = ((@sugar_clock = @sugar_clock.to_i + 1) % SUGAR_ROUNDS).zero?
    sugar_drops if drain && @blood_sugar.positive?

    @monsters.dup.each do |m|
      next unless m.sugar
      if m.sugar.positive?
        m.sugar -= 1 if drain
        next
      end
      next unless ((m.starving = m.starving.to_i + 1) % STARVE_ROUNDS).zero?

      m.hp -= 1
      next if m.hp.positive?

      @monsters.delete(m)
      say "The #{m.name} starves to death."
    end
  end

  # The player's blood sugar drops a point, sounding the same alarms as hit points do at 3, 2, 1, and 0.
  # Running out kills them, unless they're a god
  def sugar_drops
    @blood_sugar -= 1
    alarm(@blood_sugar)
    return unless hungry? && !godMode?

    @hp = 0
    say "You run out of blood sugar and die on depth #{@depth} with #{gold} gold."
  end

  # One step marched. With a ranged weapon strung in hand, it wears the string, which past STRUNG_STEPS may snap
  # at random, ruining the weapon and leaving the player bare-handed
  def march
    return unless @wielded[:ranged]

    @strung_steps += 1
    return unless @strung_steps > STRUNG_STEPS && rand < SNAP_CHANCE

    name = @wielded[:name]
    @wielded = FISTS
    @strung_steps = 0
    say "Strung too long on the march, your #{name}'s string snaps, and the #{name} breaks! You're down to your fists."
  end

  # A door's lock, built from its row's transitions table. A door that spawned unlocked has already had its key
  # turned and its timer run out, so its machine stands open; a locked one stays locked
  def door_machine(door)
    door.machine ||= Machine.new(THINGAGES.find { |k| k[:name] == "door" }[:transitions]).tap do |machine|
      unless door.locked
        machine.transit(StateEvent::KEY)
        machine.transit(StateEvent::TIMER)
      end
    end
  end

  # A sandwich lying about has a lock for its wrapping, built from its row's transitions table
  def food_machine(food)
    food.machine ||= Machine.new(THINGAGES.find { |k| k[:name] == "sandwich" }[:transitions])
  end

  # Taps and blows wear a sandwich's wrapping down along its table. The first touch starts unwrapping it (KEY),
  # every touch takes that much of its hit points, and with none left it's open, and edible (TIMER). Touching an
  # open sandwich is eating it, when the player is peckish: KEY again, leaving SandwichOpenState for the lock, so
  # its on_exit runs its action
  def unwrap(food, damage)
    food.touched = true
    machine = food_machine(food)
    if machine.state.is_a?(OpenState)
      peckish? or return say("The sandwich is open and edible, but your blood sugar isn't low enough to want it.")

      return machine.transit(StateEvent::KEY, self, food)
    end

    machine.transit(StateEvent::KEY, self, food) if machine.state.is_a?(LockState)
    food.hp -= damage
    return say("You work at the sandwich's wrapping.") if food.hp.positive?

    machine.transit(StateEvent::TIMER, self, food)
    say "The sandwich's wrapping gives way. It's open, and edible."
  end

  # Defeating a shield, or a potion or any other packable thing, packs it into the knapsack, room allowing; with no
  # room, it's left behind
  def stow(foe, how = "defeat")
    shield = SHIELDS.include?(foe.name)
    weight = shield ? Dungeon.pounds(Dungeon.packable(foe.name)) : pounds(PACKABLE[foe.name])
    room_for?(weight) or
      return say("You #{how} the #{foe.name}, but your knapsack is too full to carry it, so you leave it behind.")

    if shield
      @knapsack[:shields] << { name: foe.name, glyph: foe.glyph }
    else
      @knapsack[PACKABLE[foe.name]] += 1
    end
    say "You #{how} the #{foe.name} and pack it into your knapsack."
  end

  # A weapon, or something wielding one, that defeating or capturing seizes
  def armed?(m) = m.weapon || WEAPONS.any? { |w| w[:name] == m.name }

  # A useful obstacle: a live weapon or shield, or anything else the knapsack can hold
  def useful?(m) = armed?(m) || SHIELDS.include?(m.name) || PACKABLE.key?(m.name)

  # A grumpy useful obstacle, given a coin, comes over to the player's side
  def win_over(taker)
    taker.coins = taker.coins.to_i + 1
    taker.ally = true
    taker.aggressive = false
    taker.spurned = false
    "pockets it and comes over to your side"
  end

  # Hitting a useful obstacle on the player's side captures it into the knapsack, whatever its hit points
  def capture(foe)
    @monsters.delete(foe)
    armed?(foe) ? seize(foe, "capture", pack: true) : stow(foe, "capture")
  end

  # Defeating a weapon seizes it, and defeating a cloaked one seizes the weapon it wielded. Empty hands wield it: it
  # shows in the banner and its hit range becomes the player's. A player already wielding one, or seizing a ranged
  # one, packs it into the knapsack instead, room allowing; it keeps the packable weight and ranged flag from its
  # WEAPONS entry
  def seize(foe, how = "defeat", pack: false)
    held = foe.weapon || { name: foe.name, glyph: foe.glyph, hit: foe.hit }
    found = held.slice(:name, :glyph, :hit).merge(WEAPONS.find { |w| w[:name] == held[:name] }&.slice(:packable, :ranged) || {})
    them = pair?(found[:name]) ? "them" : "it"
    what = foe.weapon ? "its #{found[:name]}" : them
    if pack || @wielded != FISTS || found[:ranged]
      room_for?(weapon_pounds(found)) or
        return say("You #{how} the #{foe.name}, but your knapsack is too full to carry #{what}, so you leave #{them} behind.")

      @knapsack[:weapons] << found
      return say("You #{how} the #{foe.name} and pack #{what} into your knapsack.")
    end

    @wielded = found
    say "You #{how} the #{foe.name} and seize #{what}! You now wield #{weapon}."
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
  # Packs it, room allowing; true when it did, so a refusal can cost no turn
  def pack(thing, slot)
    unless room_for?(pounds(slot))
      say "Your knapsack is too full for the #{ITEM_NAMES[slot]}."
      return false
    end

    @monsters.delete(thing)
    @knapsack[slot] += 1
    say "You pack #{a_name(ITEM_NAMES[slot])} into your knapsack."
    true
  end

  # Where x, y lies from the player in compass steps, e.g. "12 east and 3 north"
  def bearing(x, y)
    dx, dy = x - @px, y - @py
    steps = []
    steps << "#{dx.abs} #{dx.positive? ? "east" : "west"}" unless dx.zero?
    steps << "#{dy.abs} #{dy.positive? ? "south" : "north"}" unless dy.zero?
    steps.join(" and ")
  end

  # The chance a room past the first has a sandwich lying in it, on the first level; deeper, sandwich_odds cuts
  # it, and a randomly spawned wrapped sandwich, by SANDWICH_DEPTH_FACTOR for each level down
  ROOM_SANDWICH_CHANCE = 1 / 3.0
  SANDWICH_DEPTH_FACTOR = 0.9

  def sandwich_odds = SANDWICH_DEPTH_FACTOR**(@depth - 1)

  # The chance a Dodo the player kills leaves a sandwich where it fell
  DODO_SANDWICH_CHANCE = 1 / 3.0

  def drop_dodo_sandwich(dodo)
    rand < DODO_SANDWICH_CHANCE or return

    @sandwiches[[dodo.x, dodo.y]] = @sandwiches.fetch([dodo.x, dodo.y], 0) + 1
    say "The Dodo leaves a sandwich behind."
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

  # Standing on a teleport plate carries the player off to where it leads, and the new spot comes into view.
  # A Quail that sees the player ride a random plate goes after them through it
  def ride_plate
    (plate = @plates[[@px, @py]]) or return

    if plate == RANDOM_PLATE
      @monsters.each do |m|
        next unless follower?(m) && m.hp.positive? && !m.spurned && !m.nesting
        next unless (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT

        m.plate_bound = [@px, @py]
      end
    end
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

    gathered = laid.first(taken)
    @knapsack[:eggs].concat(gathered)
    left = laid.size - taken
    say "You gather #{egg_kinds(gathered)}#{" from the nest" unless laid.all?(&:dodo)}#{", leaving #{left} for want of room" if left.positive?}."
    nesters = @monsters.select(&:nesting)
    nesters.each { |m| m.nesting = false }
    say "The nesting Quail stirs and follows its eggs!" if nesters.any?
  end

  # Everyone on the player's side in the stairs' room comes down with them, landing in the new level's first room
  # Everything that makes a level that level, kept in @levels by depth while the player is elsewhere
  LEVEL_STATE = %i[@map @seen @rooms @cage @cage_room @eggs @nest @treasure @sandwiches @monsters @detected
                   @population @plates @traps @gas @upstairs @downstairs].freeze

  # Leaves the current level as it stands, minus whoever comes along, to be found again on coming back
  def remember_level(party)
    party.each { |m| @monsters.delete(m) } # in place, so the level keeps its very own list
    @levels[@depth] = LEVEL_STATE.to_h { |ivar| [ivar, instance_variable_get(ivar)] }
  end

  # Arrives at the current depth: the level as the player left it, if they've been here, else a new one. Either
  # way the player stands on the stairs they came by: the < coming down, the > going up
  def enter_level(way)
    if (left = @levels.delete(@depth))
      left.each { |ivar, value| instance_variable_set(ivar, value) }
    else
      build_level
    end
    @px, @py = (way == "up" ? @downstairs : @upstairs) || [@px, @py]
    refill_wands
    reveal
    take_stock
  end

  # Every wand, in the knapsack or lying on the level, holds WAND_CHARGES again
  def refill_wands
    WANDS.each_key { |slot| @knapsack[slot].map! { WAND_CHARGES } }
    @traps&.each_value { |t| t[:charges] = WAND_CHARGES if t.key?(:charges) }
  end

  # A level already visited is the one the player left
  def descend
    party = side_in_room
    chasers = in_hot_pursuit
    remember_level(party + chasers)
    @depth += 1
    say "You take the stairs down to depth #{@depth}."
    enter_level("down")
    bring_along(party, @rooms.first, "down")
    bring_chasers(chasers, @rooms.first, "down")
  end

  # Climbing the < returns to the level one up as the player left it, or builds it new if they never saw it, as
  # after starting deep with --level, and the player arrives on its > stairs, their side coming along
  def ascend
    party = side_in_room
    chasers = in_hot_pursuit
    remember_level(party + chasers)
    @depth -= 1
    say "You climb the stairs up to depth #{@depth}."
    enter_level("up")
    bring_along(party, @rooms.last, "up")
    bring_chasers(chasers, @rooms.last, "up")
  end

  # The chance each creature in hot pursuit follows the player up or down the stairs
  PURSUIT_CHANCE = 0.75

  # Taking the stairs no longer always shakes off a pursuer: of those agitated and within sight, able to move and
  # no fixture like a wall or a door, each gives chase on PURSUIT_CHANCE
  def in_hot_pursuit
    agitated_nearby.select { |m| !FURNITURE.include?(m.name) && !m.stuck.to_i.positive? && gives_chase? }
  end

  def gives_chase? = rand < PURSUIT_CHANCE

  # The chasers land in that room of the new level, near the player, still out to get them
  def bring_chasers(chasers, room, way)
    return if chasers.empty?

    chasers.each do |m|
      m.x, m.y = free_spot(room)
      m.plate_bound = nil
      @monsters << m
    end
    names = and_list(chasers.map { |m| "the #{m.name}" })
    say "#{names[0].upcase}#{names[1..]} #{chasers.size == 1 ? "chases" : "chase"} you #{way} the stairs!"
    take_stock
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

  # The party lands in that room of the new level, beside wherever the player arrived
  def bring_along(party, room, way)
    return if party.empty?

    party.each do |m|
      m.x, m.y = free_spot(room)
      m.plate_bound = nil # the plate it was heading for is on the level left behind
      @monsters << m
    end
    names = and_list(party.map { |m| "the #{m.name}" })
    say "#{names[0].upcase}#{names[1..]} #{party.size == 1 ? "follows" : "follow"} you #{way}."
  end

  # Ends one player action. A hasted player gets two actions per round, so only every second one lets
  # everyone else act, and a slowed one gets one for two rounds, so everyone else acts twice; each round that
  # passes wears down the timed potions
  def end_turn
    earn_xp
    return take_stock if hasted? && (@quick = !@quick) # the first of a hasted pair: the dungeon waits

    (slowed? ? 2 : 1).times do
      monsters_act
      round_passes
      break if over?
    end
    doze
    breathe_gas
    take_stock
  end

  # Notes who's agitated nearby, for the player's next move to earn XP by calming or defeating them
  def take_stock = @agitated = [@depth, agitated_nearby]

  # The experience each nearby obstacle earns the player, calmed or defeated, and how much more each level takes
  XP_PER_CALMING = 10
  XP_PER_LEVEL = 50

  # Whether a thingage is agitated: out to fight the player, not spurned, paid off, fed, asleep, fleeing, or
  # defeated
  def agitated?(m)
    m.hp.positive? && m.aggressive && !m.pacifist && !m.spurned && !friend?(m) && !m.asleep.to_i.positive? && !fleeing?(m)
  end

  # The agitated thingages within SIGHT of the player
  def agitated_nearby
    @monsters.select { |m| agitated?(m) && (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT }
  end

  # What the player just did earns XP_PER_CALMING for each agitated thingage that was nearby at the last
  # take_stock, on this same level, and is now passive or gone. Every XP_PER_LEVEL raises the hero a level, and
  # recharges every wand
  def earn_xp
    depth, was = @agitated
    @agitated = nil
    depth == @depth or return

    calmed = was.count { |m| !@monsters.include?(m) || !agitated?(m) }
    calmed.positive? or return

    @experience_points += calmed * XP_PER_CALMING
    while @experience_points >= @hero_level * XP_PER_LEVEL
      @hero_level += 1
      refill_wands
      say(rand < 0.5 ? "Welcome to level #{@hero_level}!" :
                       "Welcome to level #{@hero_level}; your new proficiency bonus is #{@hero_level / 2}.")
    end
  end

  # A sleeping player sleeps on, a round at a time, while everyone else carries on, then wakes
  def doze
    @asleep.to_i.positive? or return
    while @asleep.positive? && !over?
      @asleep -= 1
      monsters_act
      round_passes
    end
    say "You wake up." unless over?
  end

  def round_passes
    if hasted? && (@hasted -= 1).zero?
      @quick = false
      say "You slow back down."
    end
    say "You speed back up." if slowed? && (@slowed -= 1).zero?
    say "You become solid again." if gaseous? && (@gaseous -= 1).zero?
    say "You pull free of the glue." if stuck? && (@stuck -= 1).zero?
    @monsters.each do |m|
      m.hasted -= 1 if m.hasted.to_i.positive?
      m.slowed -= 1 if m.slowed.to_i.positive?
      m.gaseous -= 1 if m.gaseous.to_i.positive?
      m.stuck -= 1 if m.stuck.to_i.positive?
      next unless m.asleep.to_i.positive? && (m.asleep -= 1).zero?

      say "The #{m.name} wakes up." if (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
    end
    slip
    thin_gas
    recover
    hunger
  end

  # Each slippery square counts down to its next slip, d3 rounds apart; then whoever stands on it slips off
  def slip
    (@traps || {}).to_a.each do |spot, trap|
      next unless trap[:kind] == :slippery && @traps[spot].equal?(trap) && (trap[:slip_in] -= 1) <= 0

      trap[:slip_in] = Dungeon.d3
      slide_off(spot)
      break if over?
    end
  end

  # Whoever stands on a slippery square slides off it, as if pushed, onto open floor beside it that isn't slippery
  # too; with nowhere like that to go, or nothing solid to slip, they keep their footing
  def slide_off(spot)
    (who = spot == [@px, @py] ? :ego : monster_at(*spot)) or return
    return if who == :ego ? gaseous? : mist?(who)

    off = [[1, 0], [-1, 0], [0, 1], [0, -1]].map { |dx, dy| [spot[0] + dx, spot[1] + dy] }
                                            .select { |s| pushable_to?(s) && !@plates.key?(s) && s != @cage&.dig(:plate) }
                                            .reject { |s| @traps[s]&.dig(:kind) == :slippery }.sample or return
    if who == :ego
      @px, @py = off
      say "You slip and slide off the slippery floor!"
      pick_up
      tread_player
    else
      who.x, who.y = off
      say "The #{who.name} slips and slides off the slippery floor!" if (who.x - @px).abs <= SIGHT && (who.y - @py).abs <= SIGHT
      tread(who)
    end
  end

  # Every monster takes its turn, a hasted one two, and a slowed one only every other round
  def monsters_act
    @monsters.each { |m| m.max_hp ||= m.hp; m.struck = false }
    stood = @monsters.to_h { |m| [m, [m.x, m.y]] }.compare_by_identity
    @monsters.dup.each do |m|
      next if m.hp <= 0 # slain by an ally earlier this turn
      next if m.asleep.to_i.positive?
      next if gassed?(m)

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
    rest_monsters(stood)
  end

  # Every RECOVERY_STEPS rounds in a row without losing a hit point, the hero and every critter quietly recover a
  # d2 of them, never past their most. Losing any, however, starts the count over
  RECOVERY_STEPS = 7

  def recover
    @unhurt = @last_hp && @hp < @last_hp ? 0 : @unhurt.to_i + 1
    @hp = [@hp + Dungeon.dice(1, 2), @max_hp].min if @hp.positive? && @unhurt.positive? && (@unhurt % RECOVERY_STEPS).zero?
    @last_hp = @hp
    @monsters.each do |m|
      next unless m.hp.positive?

      m.max_hp ||= m.hp
      m.unhurt = m.last_hp && m.hp < m.last_hp ? 0 : m.unhurt.to_i + 1
      m.hp = [m.hp + Dungeon.dice(1, 2), m.max_hp].min if m.unhurt.positive? && (m.unhurt % RECOVERY_STEPS).zero?
      m.last_hp = m.hp
    end
  end

  # When you rest, they rest: anyone still standing where they stood when the round began, having attacked no one
  # and been touched by no one, asleep, glued, or just biding its time, recovers a hit point, up to its max_hp.
  # Then the round's touches are forgotten
  def rest_monsters(stood)
    @monsters.each do |m|
      next unless stood.key?(m) && stood[m] == [m.x, m.y] && !m.struck && !m.touched
      next unless m.hp.positive? && m.max_hp && m.hp < m.max_hp

      m.hp += 1
    end
    @monsters.each { |m| m.touched = false }
  end

  # Monsters within sight, or anywhere for a farsighted one, chase the player and strike when adjacent. Friends
  # (allies, and goblins still full from a sandwich) follow without striking the player, and an ally strikes a
  # hostile monster beside it instead. Nothing touches a misty thing or a gaseous player, nor wants to
  def act(m)
    return dodo_act(m) if m.name == "Dodo" && m.hp.positive? && !mist?(m)
    return flee(m) if m.hp.positive? && fleeing?(m)
    return if m.hp <= 0 || m.spurned || m.nesting
    return board_plate(m) if m.plate_bound
    return if hurl_self(m)
    return if hunt_prey(m)
    return if lead_over_trap(m)
    # A neutral thingage stays put and never strikes; friends and the Quail follow, and only the aggressive fight
    return unless m.aggressive || friend?(m) || follower?(m) || curious?(m)

    dx = @px - m.x
    dy = @py - m.y
    return if (dx.abs > SIGHT || dy.abs > SIGHT) && !m.farsighted
    return if follower?(m) && [dx.abs, dy.abs].max == 1 # a Quail beside the player, diagonally too, stays put

    m.sugar ||= MAX_BLOOD_SUGAR if eater?(m) # its first act wakes it, and its blood sugar starts running down

    if m.ally && !mist?(m) && (enemy = hostile_beside(m))
      ally_strike(m, enemy)
    elsif dx.abs + dy.abs == 1
      return say("The #{m.name} taps you.") if curious?(m) && !mist?(m) && !gaseous?
      return if m.pacifist || friend?(m) || mist?(m) || gaseous?

      m.struck = true
      dmg = blow(m)
      with = " with its #{m.weapon[:name]}" if m.weapon
      return say("The #{m.name} hits you#{with} for #{dmg}, but you take no damage.") if godMode?

      hurt(dmg)
      say "The #{m.name} hits you#{with} for #{dmg}."
      say("You die on depth #{@depth} with #{gold} gold.") if over?
    else
      return if gaseous? && !friend?(m) && !follower?(m) # nothing hostile bothers chasing mist
      return if FURNITURE.include?(m.name) # angry furniture strikes from where it stands but never leaves it
      return if m.stuck.to_i.positive? # glued in place: it strikes from where it stands, too

      step = dx.abs >= dy.abs ? [dx <=> 0, 0] : [0, dy <=> 0]
      nx, ny = (follower?(m) && path_step(m, diagonal: true)) || [m.x + step[0], m.y + step[1]]
      return if wall?(nx, ny) || monster_at(nx, ny) || [nx, ny] == [@px, @py]

      m.x, m.y = nx, ny
      tread(m) or return
      return unless @plates[[nx, ny]] == RANDOM_PLATE

      say "The #{m.name} steps on a plate and vanishes!" if (nx - @px).abs <= SIGHT && (ny - @py).abs <= SIGHT
      m.x, m.y = landing(RANDOM_PLATE)
    end
  end

  # The player treads on a trap where they stand: poison hurts, glue sticks them in place, a wand of slowness slows
  # them and a wand of slipperiness slicks the floor round them, either then going in the knapsack, and slippery
  # floor waits its turn to trip them
  def tread_player
    (trap = @traps&.[]([@px, @py])) or return
    trap[:seen] = true
    if trap[:kind] == :slippery
      nil # it trips its stander up in its own time
    elsif trap[:kind] == :glue
      @stuck = Dungeon.d2x2
      say "You step in glue and stick fast!"
    elsif trap[:kind] == :slip_wand
      @traps.delete([@px, @py])
      if trap[:charges].positive?
        trap[:charges] -= 1
        say "You step on a wand of slipperiness, and it zaps the floor, #{splash_words(:slippery, *spread(:slippery, @px, @py))}."
      end
      @knapsack[:slip_wands] << trap[:charges]
      say "You pick up the wand of slipperiness (#{trap[:charges]} #{trap[:charges] == 1 ? "charge" : "charges"} left)."
    elsif trap[:kind] == :poison
      dmg = Dungeon.d2x2
      return say("You step on a potion of poison and it breaks, but you take no damage.") if godMode?

      hurt(dmg)
      say "You step on a potion of poison and it breaks. You take #{dmg} damage."
      say("You die on depth #{@depth} with #{gold} gold.") if over?
    else
      if trap[:charges].positive?
        trap[:charges] -= 1
        @slowed += Dungeon.d2x2
        say "You step on a wand of slowness, and it zaps you. Everything else speeds up!"
      end
      @traps.delete([@px, @py])
      @knapsack[:wands] << trap[:charges]
      say "You pick up the wand of slowness (#{trap[:charges]} #{trap[:charges] == 1 ? "charge" : "charges"} left)."
    end
  end

  # A monster treads on a trap where it stands: poison hurts it, glue sticks it in place, and a wand with a charge
  # left slows it, or slicks the floor round it. False when the poison kills it
  def tread(m)
    (trap = @traps&.[]([m.x, m.y])) or return true
    seen = (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
    trap[:seen] ||= seen
    if trap[:kind] == :glue
      m.stuck = Dungeon.d2x2
      say "The #{m.name} steps in glue and sticks fast!" if seen
    elsif trap[:kind] == :slip_wand
      if trap[:charges].positive?
        trap[:charges] -= 1
        spread(:slippery, m.x, m.y)
        say "The #{m.name} steps on a wand of slipperiness, and the floor around it turns slick!" if seen
      end
    elsif trap[:kind] == :poison
      dmg = Dungeon.d2x2
      m.hp -= dmg
      ouch(dmg)
      unless m.hp.positive?
        @monsters.delete(m)
        say "The #{m.name} steps on a potion of poison, and it kills the #{m.name}!" if seen
        return false
      end
      say "The #{m.name} steps on a potion of poison and takes #{dmg} damage." if seen
    elsif trap[:kind] == :wand && trap[:charges].positive?
      trap[:charges] -= 1
      m.slowed = m.slowed.to_i + Dungeon.d2x2
      say "The #{m.name} steps on a wand of slowness and slows down!" if seen
    end
    true
  end

  # Zaps a charge that way: the first thingage within THROW_RANGE slows for 2d2 rounds. Zapping takes a turn
  def zap_wand(dx, dy)
    @offering = nil
    at = @knapsack[:wands].index(&:positive?) or return say("Your wand of slowness has no charges left on this level.")
    @knapsack[:wands][at] -= 1
    target = (1..THROW_RANGE).lazy.map { |i| [@px + dx * i, @py + dy * i] }
                             .take_while { |x, y| !wall?(x, y) }.map { |x, y| monster_at(x, y) }.find(&:itself)
    if target
      target.slowed = target.slowed.to_i + Dungeon.d2x2
      say "You zap the wand of slowness. The #{target.name} slows down!"
    else
      say "You zap the wand of slowness, and it fizzles out."
    end
    end_turn
  end

  # Zaps a charge of slipperiness that way: it flies up to THROW_RANGE, stopping at the first thingage or before a
  # wall, and slicks the floor there. Zapping takes a turn
  def zap_slip_wand(dx, dy)
    @offering = nil
    at = @knapsack[:slip_wands].index(&:positive?) or return say("Your wand of slipperiness has no charges left on this level.")
    @knapsack[:slip_wands][at] -= 1
    x, y = @px, @py
    THROW_RANGE.times do
      break if wall?(x + dx, y + dy)

      x += dx
      y += dy
      break if monster_at(x, y)
    end
    say "You zap the wand of slipperiness, #{splash_words(:slippery, *spread(:slippery, x, y))}."
    end_turn
  end

  # Who a rat or an Axebeak leads: a rat leads the player; an Axebeak leads the nearest Coyote, or the player once
  # it's been provoked
  def lure_target(m)
    case m.name
    when "rat" then m.aggressive ? [@px, @py] : nil
    when "Axebeak"
      coyote = @monsters.select { |c| c.name == "Coyote" && c.hp.positive? }.min_by { |c| (c.x - m.x).abs + (c.y - m.y).abs }
      coyote ? [coyote.x, coyote.y] : (m.aggressive ? [@px, @py] : nil)
    end
  end

  # A rat or an Axebeak knows where the unseen traps lie. With its target in sight and an unseen trap near it, it
  # runs to stand just behind the trap, the trap between them, so a target chasing it treads on the trap, and
  # waits there, never treading on one itself. False when there's no target or no trap to lead it over
  def lead_over_trap(m)
    return false if mist?(m) || m.weapon || m.disguised_potion
    (tx, ty = lure_target(m)) or return false
    return false if (tx - m.x).abs > SIGHT || (ty - m.y).abs > SIGHT
    return false if (tx - m.x).abs + (ty - m.y).abs == 1 # caught: it fights, or flees, as it would anyway

    lures = (@traps || {}).filter_map do |(x, y), trap|
      next if trap[:seen] || (x - m.x).abs > SIGHT || (y - m.y).abs > SIGHT

      dx, dy = x - tx, y - ty
      step = dx.abs >= dy.abs ? [dx <=> 0, 0] : [0, dy <=> 0]
      next if step == [0, 0]

      spot = [x + step[0], y + step[1]]
      spot unless wall?(*spot) || @traps.key?(spot) || spot == [tx, ty]
    end
    (lure = lures.min_by { |x, y| (x - m.x).abs + (y - m.y).abs }) or return false
    return true if [m.x, m.y] == lure # in place: wait for the target

    if (nx, ny = path_step(m, lure, wary: true)) && !monster_at(nx, ny) && [nx, ny] != [@px, @py]
      m.x, m.y = nx, ny
    end
    true
  end

  # The committee's decision on who is whose relative prey: no row's own business, but a ruling between kinds. A
  # rat goes after a squirrel, a living Quail horrifies a troll, an Axebeak is a Coyote's nemesis, and a Dodo, the
  # opposite of every instinct, goes after the troll. Anyone not on it hunts nothing
  PREY = {
    "rat" => "squirrel",
    "Troll" => "Quail",
    "Coyote" => "Axebeak",
    "Dodo" => "Troll" }.freeze

  def prey_of(m) = PREY[m.name]

  # The alarms as the player's hit points or blood sugar run out, each sound of a list playing at once: three
  # overlapping errors at 3, two at 2, a bat at 1, and one error at 0
  ALARMS = { 3 => %w[error error error], 2 => %w[error error], 1 => %w[bat_chirp], 0 => %w[error] }.freeze

  # Sounds the alarm for a count, if it has one
  def alarm(count) = ALARMS.fetch(count, []).each { |name| sound name }

  # The player loses n hit points, with HERO_HIT_SOUND, then sounds the alarm for the lowest count they fall to;
  # a blow that falls past several sounds only the last, and dying below zero sounds as 0
  def hurt(n)
    @hp -= n
    return unless n.positive?

    sound HERO_HIT_SOUND
    alarm([@hp, 0].max)
  end

  # Anyone else taking a blow, or a trap's damage, chirps a short burst of bat; a blow of nothing is silent
  def ouch(dmg) = dmg.positive? && sound(NPC_HIT_SOUND)

  # The sound a hunter makes eating its prey, from the sounds folder
  EATING_SOUND = "wolf"

  # The sounds of a blow landing: on the hero, and on anyone else
  HERO_HIT_SOUND = "error"
  NPC_HIT_SOUND = "bat_hit"

  # Plays a named sound, when a front end has said how; nil, as in the tests, keeps the game silent
  class << self
    attr_accessor :sound_player
  end

  def sound(name) = Dungeon.sound_player&.call(name)

  # A hunter's or a piece of furniture's state, starting quiet
  def state_machine(m)
    m.state ||= Machine.new(STATE_TRANSITIONS, QuietState)
  end

  # What the player does to a hunter, or to a moody kind like the squirrel, whose row says so, so a coin can
  # calm an angry one back to curious, moves its state along, pointing it at the player
  def provoke_hunter(m, event)
    return if m.pacifist # a Dodo hunts trolls, but nothing the player does ever turns it on them

    moody = prey_of(m) || THINGAGES.find { |k| k[:name] == m.name }&.dig(:moody)
    state_machine(m).transit(event, self, m, :ego) if moody
  end

  # The prey a hunter is after, if any. A hunter whose prey is gone calms down, and a quiet one that sees its
  # kind of prey, within SIGHT of it, goes for the nearest; a hunter after the player hunts no prey at all
  def hunted(m)
    machine = state_machine(m)
    prey = m.pursuit_target
    machine.transit(StateEvent::CALM, self, m, nil) if prey.is_a?(Thingage) && !(prey.hp.positive? && @monsters.include?(prey))
    if machine.state.is_a?(QuietState)
      near = ->(q) { (q.x - m.x).abs <= SIGHT && (q.y - m.y).abs <= SIGHT }
      seen = @monsters.select { |q| q.name == prey_of(m) && q.hp.positive? && near.(q) }
      (prey = seen.min_by { |q| (q.x - m.x).abs + (q.y - m.y).abs }) and machine.transit(StateEvent::SEE_PREY, self, m, prey)
    end
    m.pursuit_target if m.pursuit_target.is_a?(Thingage)
  end

  # A hunter leaves everything else to hunt down the prey its state has it after, finding its way round walls like
  # the Quail does, and eats it. False when there's no prey to hunt
  def hunt_prey(m)
    prey_of(m) && !mist?(m) or return false

    prey = hunted(m)
    return false unless prey

    seen = ->(x, y) { (x - @px).abs <= SIGHT && (y - @py).abs <= SIGHT }
    if (prey.x - m.x).abs + (prey.y - m.y).abs == 1
      prey.touched = true
      if prey.name == "Quail" && first_meeting?(prey, m)
        say "The #{m.name} taps the Quail." if seen.(prey.x, prey.y)
        return true
      end
      m.struck = true
      dmg = blow(m)
      prey.hp -= dmg
      ouch(dmg)
      if prey.hp.positive?
        say "The #{m.name} hits the #{prey.name} for #{dmg}." if seen.(prey.x, prey.y)
        knock_back(prey, prey.x - m.x, prey.y - m.y) if prey.name == "Quail"
      else
        @monsters.delete(prey)
        if seen.(prey.x, prey.y)
          say "The #{m.name} eats the #{prey.name}!"
          sound EATING_SOUND
        end
      end
    elsif (nx, ny = path_step(m, [prey.x, prey.y])) && !monster_at(nx, ny) && [nx, ny] != [@px, @py]
      m.x, m.y = nx, ny
      tread(m)
    end
    true
  end

  # Every other critter's survival instincts, and the Dodo's opposite of each, in the order it looks for a
  # chance. Prey keeps clear of an enraged hunter, so a Dodo strikes the hunter, whose HIT turns it on the Dodo
  # instead. The trap-wise steer round traps, so a Dodo walks onto the nearest one. Anything not spoiling for a
  # fight keeps its distance from the player, so a devoted Dodo, one born to follow, walks up and stands beside
  # them, by the Quail's own diagonal pursuit; the rest never come. Hitting a Dodo only spurns it, and it carries
  # on regardless
  def dodo_act(m)
    dodo_lay(m)
    near = ->(x, y) { (x - m.x).abs <= SIGHT && (y - m.y).abs <= SIGHT }
    far = ->(x, y) { (x - m.x).abs + (y - m.y).abs }
    hunter = @monsters.select do |h|
      h.name == prey_of(m) && h.hp.positive? && near.(h.x, h.y) && h.pursuit_target.is_a?(Thingage) &&
        !h.pursuit_target.equal?(m) && state_machine(h).state.is_a?(EnragedState)
    end.min_by { |h| far.(h.x, h.y) }
    return dodo_strike(m, hunter) if hunter && far.(hunter.x, hunter.y) == 1
    return dodo_step(m, [hunter.x, hunter.y]) if hunter

    trap = @traps.to_h.keys.select { |spot| near.(*spot) && spot != [m.x, m.y] }.min_by { |spot| far.(*spot) }
    return dodo_step(m, trap) if trap

    dx, dy = (@px - m.x).abs, (@py - m.y).abs
    dodo_step(m, diagonal: true) if m.devoted && dx <= SIGHT && dy <= SIGHT && [dx, dy].max > 1
  end

  # The chance, each time it acts, that a Dodo lays an egg, and that a Dodo's egg is developed
  DODO_LAY_CHANCE = 0.01
  DODO_DEVELOPED_CHANCE = 0.5

  # The chance a Dodo is born devoted, following the player
  DODO_DEVOTED_CHANCE = 0.5

  # Now and then, where a Quail would guard a nest, a Dodo drops an egg wherever it happens to stand, and
  # wanders off. It won't lay on top of another egg
  def dodo_lay(m)
    return if @eggs.key?([m.x, m.y]) || rand >= DODO_LAY_CHANCE

    @eggs[[m.x, m.y]] = [Egg.new(rand < DODO_DEVELOPED_CHANCE, false, true)]
    say "The Dodo lays an egg and wanders off." if (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
  end

  # A Dodo pecks a hunter, which turns from its prey to the Dodo, unless the peck finishes it
  def dodo_strike(m, hunter)
    m.struck = true
    seen = (hunter.x - @px).abs <= SIGHT && (hunter.y - @py).abs <= SIGHT
    dmg = blow(m)
    hunter.hp -= dmg
    hunter.touched = true
    ouch(dmg)
    if hunter.hp.positive?
      state_machine(hunter).transit(StateEvent::HIT, self, hunter, m)
      say "The Dodo pecks the #{hunter.name} for #{dmg}, and the #{hunter.name} turns on the Dodo!" if seen
    else
      @monsters.delete(hunter)
      say "The Dodo pecks the #{hunter.name} to death!" if seen
    end
  end

  # A Dodo's step toward a goal square, or toward beside the player, finding its way round walls, then treading
  # on whatever lies there
  def dodo_step(m, goal = nil, diagonal: false)
    (nx, ny = path_step(m, goal, diagonal: diagonal)) or return
    return if monster_at(nx, ny) || [nx, ny] == [@px, @py]

    m.x, m.y = nx, ny
    tread(m)
  end

  # A Quail walks to the plate it saw the player ride, one action per square, steps onto it as an action of its
  # own, and rides it on the next, landing in a random room like any rider. It gives up if no walk gets there
  def board_plate(m)
    plate = m.plate_bound
    if [m.x, m.y] == plate
      m.plate_bound = nil
      m.x, m.y = landing(RANDOM_PLATE)
      return say("The #{m.name} pops out of thin air, following you!") if (m.x - @px).abs <= SIGHT && (m.y - @py).abs <= SIGHT
      return
    end

    return if m.stuck.to_i.positive?
    (nx, ny = path_step(m, plate, diagonal: true)) or return m.plate_bound = nil
    return if monster_at(nx, ny) || [nx, ny] == [@px, @py]

    m.x, m.y = nx, ny
    tread(m)
  end

  # The first square of the shortest walk from m to beside the player, around walls and other thingages, or nil
  # when no walk gets there. Everything else steps straight at the player and gets stuck behind corners; only
  # the Quail is clever enough to find its way round. Given a goal square instead, the walk ends on it. A
  # diagonal walk, the Quail's alone, steps to any of the eight squares around, and peeks one square round a
  # corner by cutting it diagonally where everyone else must go the long way
  STEPS = [[1, 0], [-1, 0], [0, 1], [0, -1]].freeze
  DIAGONAL_STEPS = (STEPS + [[1, 1], [1, -1], [-1, 1], [-1, -1]]).freeze

  def path_step(m, goal = nil, wary: false, diagonal: false)
    return if m.stuck.to_i.positive? # glued in place, it goes nowhere
    start = [m.x, m.y]
    first = { start => nil } # each square reached, mapped to the first step taken toward it
    queue = [start]
    until queue.empty?
      spot = queue.shift
      (diagonal ? DIAGONAL_STEPS : STEPS).each do |dx, dy|
        nxt = [spot[0] + dx, spot[1] + dy]
        next if first.key?(nxt) || wall?(*nxt)
        next if wary && @traps&.key?(nxt)
        return first[spot] || nxt if nxt == goal
        next if goal && nxt == [@px, @py]
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

  # A curious creature, not yet hit and no weapon in disguise, comes up to the player to tap them
  def curious?(m)
    !m.aggressive && !m.weapon && !m.disguised_potion && CURIOUS.include?(m.name)
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
    ally.struck = true
    dmg = blow(ally)
    enemy.hp -= dmg
    enemy.touched = true
    ouch(dmg)
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
    elsif @gas&.key?([x, y]) then SLEEP_GAS
    elsif @eggs.key?([x, y]) then "0"
    elsif [x, y] == @nest then "&"
    elsif @treasure.key?([x, y]) then "$"
    elsif @sandwiches.key?([x, y]) then "%"
    elsif @plates.key?([x, y]) then @plates[[x, y]]
    elsif @traps&.dig([x, y], :seen) then { poison: BROKEN_POTION, glue: GLUE, slippery: SLIPPERY }.fetch(@traps[[x, y]][:kind], WAND)
    elsif [x, y] == @cage&.dig(:plate) then cage_plate.glyph
    else @map[y][x]
    end
  end

  # say counts every message in @said, so a press can tell which messages it caused, though the log keeps only four
  def say(msg)
    @log = (@log + [msg]).last(4)
    @said = @said.to_i + 1
    nil
  end

  # Remembers a press of a repeatable key, counting how many times in a row it's been the same one, and the
  # messages it caused
  def note_press(press)
    @streak = press == @last_press ? @streak.to_i + 1 : 1
    @last_press = press
  end

  def messages_since(said) = @log.last([@said.to_i - said, @log.size].min)

  # What the player would notice around them: who's in sight and who's beside them (and how a lock beside them
  # stands), their hit points and hunger, a stairs question, what's in hand, and whether the game is over
  def situation
    within = ->(r) { @monsters.select { |m| (m.x - @px).abs <= r && (m.y - @py).abs <= r } }
    [within.(SIGHT).map(&:object_id).sort, within.(1).map { |m| [m.object_id, m.machine&.state&.class&.name] }.sort,
     @hp, hungry?, @stairs_question, @wielded, over?]
  end

  # Presses the last repeated key up to REPEATS more times, stopping at any change of local situation: someone
  # comes into sight or beside the player, or leaves; hit points or hunger change; a stairs question comes up; a
  # press says something other than what the last one said (numbers aside, so blow after blow still counts as the
  # same); or a press does nothing at all
  def repeat_last
    name, args = @last_press
    REPEATS.times do
      before = situation
      spot = [@px, @py]
      heard = @press_said
      public_send(name, *args)
      news = @press_said
      break if over? || situation != before || news.map { |m| m.gsub(/\d+/, "#") } != heard.map { |m| m.gsub(/\d+/, "#") }
      break if news.empty? && [@px, @py] == spot
    end
  end

  # After the same key three times running, the rest key presses it for you again, up to three more times; see
  # repeat_last. Moves (and the attacks and throws an arrow makes), taps, and coins repeat; any other action ends the
  # run of presses
  REPEAT_AFTER = 3
  REPEATS = 3

  module Repeating
    REPEATABLE = %i[move tap give_coin].freeze
    BREAKERS = %i[offer inventory quaff pour fling aim candle read wear wield hurl choose throw_chosen give_chosen
                  take_stairs].freeze

    REPEATABLE.each do |name|
      define_method(name) do |*args|
        note_press([name, args])
        said = @said.to_i
        result = super(*args)
        @press_said = messages_since(said)
        result
      end
    end

    BREAKERS.each do |name|
      define_method(name) do |*args, &block|
        @streak = 0
        super(*args, &block)
      end
    end

    # The rest key repeats the last key when it's been pressed three times running, unless a gift is readied, when
    # resting still keeps or eats it
    def rest
      return repeat_last if repeat_ready?

      @streak = 0
      super
    end

    # Whether the rest key will repeat the last key, for a front end to say so
    def repeat_ready? = @streak.to_i >= REPEAT_AFTER && !@offering && !over?
  end
  prepend Repeating
end

# The movement pad both front ends draw: label, dx, dy, and the browser keys that press it
PAD = [
  [["↖", -1, -1, "y 7 Home"], ["↑", 0, -1, "k 8 ArrowUp"],  ["↗", 1, -1, "u 9 PageUp"]],
  [["←", -1,  0, "h 4 ArrowLeft"], ["rest", 0,  0, ". 5 Clear"], ["→", 1,  0, "l 6 ArrowRight"]],
  [["↙", -1,  1, "b 1 End"], ["↓", 0,  1, "j 2 ArrowDown"], ["↘", 1,  1, "n 3 PageDown"]],
]

# Serves one shared Dungeon over plain HTTP; each button is a form that POSTs, then redirects back
# The winners: heroes.xml, each winner's name and final score, best first. It's kept fewer than 20 long by
# dropping the lowest scores, so the newest winner always gets on. The tests point it somewhere else
module Heroes
  FILE = File.join(__dir__, "heroes.xml")
  LIMIT = 19

  class << self
    attr_writer :file

    def file = @file || FILE
  end

  # Every hero on file, as [name, score], best first
  def self.all
    File.exist?(file) or return []
    heroes = REXML::XPath.match(REXML::Document.new(File.read(file)), "/heroes/hero")
    heroes.map { |h| [h.attributes["name"].to_s, h.attributes["score"].to_i] }.sort_by { |_, score| -score }
  rescue REXML::ParseException
    []
  end

  # Adds a winner, first dropping the lowest scores already there to leave room for them
  def self.record(name, score)
    heroes = (all.first(LIMIT - 1) + [[name, score]]).sort_by { |_, s| -s }
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new("1.0", "UTF-8")
    hall = doc.add_element("heroes")
    heroes.each { |n, s| hall.add_element("hero", "name" => n, "score" => s.to_s) }
    File.write(file, doc.to_s)
  end
end

# Fluffs a plaque's XML into XHTML with plaque.xslt, server-side. Ruby's standard library has no XSLT, so this
# uses the nokogiri gem when it's installed, and the xsltproc command otherwise
module Plaque
  XSLT = File.join(__dir__, "plaque.xslt")
  XHTML = "http://www.w3.org/1999/xhtml"

  # Every plaque earned in the console, oldest first, as one XML file; the last hero on it is the name offered
  # next time. The tests point it somewhere else
  WALL = File.join(__dir__, "wall_of_fallen_heroes.xml")
  class << self
    attr_writer :wall

    def wall = @wall || WALL
  end

  # A name fits the plaque's line between its bars
  NAME_LENGTH = 28

  # A typed name, without control characters or the spaces around it, cut to NAME_LENGTH
  def self.clean_name(text) = text.to_s.gsub(/[[:cntrl:]]/, "").strip[0, NAME_LENGTH]

  # Hangs a plaque's XML on the wall, starting the wall if there's none yet
  def self.record(xml)
    doc = File.exist?(wall) ? REXML::Document.new(File.read(wall)) : REXML::Document.new.tap { |d| d << REXML::XMLDecl.new("1.0", "UTF-8") }
    (doc.root || doc.add_element("wall")).add_element(REXML::Document.new(xml).root)
    File.write(wall, doc.to_s)
  end

  # The name on the wall's newest plaque, or nil
  def self.last_name
    File.exist?(wall) or return nil
    name = REXML::XPath.match(REXML::Document.new(File.read(wall)), "/wall/plaque/name").last&.text
    name unless name.to_s.empty?
  rescue REXML::ParseException
    nil
  end

  # :nokogiri, :xsltproc, or nil when neither is around
  def self.processor
    return @processor if defined?(@processor)

    @processor = begin
      require 'nokogiri'
      :nokogiri
    rescue LoadError
      :xsltproc if system("command -v xsltproc > /dev/null 2>&1")
    end
  end

  def self.xhtml(xml)
    case processor
    when :nokogiri then Nokogiri::XSLT(File.read(XSLT)).apply_to(Nokogiri::XML(xml))
    when :xsltproc
      require 'open3'
      out, status = Open3.capture2("xsltproc", XSLT, "-", stdin_data: xml)
      status.success? or raise "xsltproc couldn't fluff the plaque"
      out
    else raise "No XSLT processor for the plaque: install the nokogiri gem or xsltproc"
    end
  end

  # Quick and dirty: the plaque as plain console text straight from the XML, no XSLT needed
  def self.text(xml)
    doc = REXML::Document.new(xml)
    name = doc.elements["plaque/name"]&.text.to_s
    rows = [["Eggs", doc.elements["plaque/eggs"].text], ["Quails", doc.elements["plaque/quails"].text]] +
           doc.get_elements("plaque/critter").map { |c| [c.attributes["name"], c.text] }
    lines = ["WALL OF FALLEN HEROES", "Here lies #{name.empty? ? "an unknown hero" : name}",
             "Final score: #{doc.elements["plaque/score"]&.text.to_i}", "In the cage when the end came:"] +
            rows.map { |label, count| "  #{label} #{"." * [31 - label.size - count.size, 0].max} #{count}" }
    lines.map { |line| "#{line}\n" }.join
  end

  # Just the ASCII art, out of the XHTML's pre, for a console
  def self.ascii(xml)
    REXML::XPath.first(REXML::Document.new(xhtml(xml)), "//x:pre", "x" => XHTML).text
  end
end

class WebGame
  attr_reader :game

  def initialize(godMode: false, level: 1)
    @godMode = godMode
    @level = level
    @game = Dungeon.new(godMode: @godMode, level: @level)
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
      when "/tap" then @game.tap
      when "/zap" then @game.zap
      when "/use_tools" then @game.use_tools
      when "/give_coin" then @game.give_coin
      when "/choose"
        slot = @game.contents.map(&:last).find { |s| s.to_s == params["item"] } or return [404, {}, "Not found"]
        @game.choose(slot)
      when "/throw_chosen" then @game.throw_chosen
      when "/give_chosen" then @game.give_chosen
      when "/stairs" then @game.take_stairs(params["answer"] == "yes")
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
      when "/new"  then @game = Dungeon.new(godMode: @godMode, level: @level)
      else return [404, {}, "Not found"]
      end
      return [303, { "Location" => "/" }, ""]
    end

    if method == "GET" && path == "/plaque"
      return [404, {}, "Not found"] unless @game.plaque?

      begin
        return [200, { "Content-Type" => "application/xhtml+xml; charset=utf-8" }, Plaque.xhtml(@game.plaque_xml)]
      rescue StandardError => e
        return [500, { "Content-Type" => "text/plain; charset=utf-8" }, "No plaque: #{e.message}"]
      end
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
    reason = { 200 => "OK", 303 => "See Other", 404 => "Not Found", 500 => "Internal Server Error" }[status]
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
      # The rest button is underlined while something alive or magic is beside the player, worth searching, and the
      # arrow the player faces is highlighted, the way tap, Throw, and Give go
      lit = action == "/rest" && @game.alive_nearby?
      facing = [dx, dy] == @game.facing
      label = "again" if action == "/rest" && @game.repeat_ready? # after three of a key, rest repeats it
      %(<form method="post" action="#{action}"><button data-keys="#{h keys}"#{' class="facing" aria-pressed="true"' if facing}) +
        %(#{' style="text-decoration: underline"' if lit}>#{label}</button></form>)
    end

    # One button per knapsack entry: gold and sandwiches ready a gift, eggs are held up to the light, a potion
    # quaffs (with throw and pour-into-a-candle buttons beside it), a laced candle is thrown (with a kick button
    # beside it), a scroll reads, a ring is worn, and a weapon kind wields one of them. Plain candles just wait
    entry_for = lambda do |text, slot|
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

    # Each entry's radio button chooses it for the Throw and Give buttons without using it
    packed = @game.contents.map do |text, slot|
      chooser = %(<form method="post" action="/choose?item=#{URI.encode_www_form_component(slot.to_s)}">) +
                %(<input type="radio" name="chosen" aria-label="choose #{h text}" onchange="this.form.submit()") +
                %(#{" checked" if @game.chosen == slot}></form>)
      %(<div style="display: flex; gap: 4px; align-items: center;">#{chooser}#{entry_for.(text, slot)}</div>)
    end

    # Standing on stairs, the question and its answers come before the pad, so that y and n answer it
    stairs = if (way = @game.stairs_question)
               %(<div class="stairs">You want to go #{way}? ) +
                 %(<form method="post" action="/stairs?answer=yes"><button data-keys="y" style="width: auto">Yes (y)</button></form>) +
                 %(<form method="post" action="/stairs?answer=no"><button data-keys="n" style="width: auto">No (n)</button></form></div>)
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
          .pad-row { display: flex; align-items: center; gap: 8px; }
          .pad button.facing { background: #{Dungeon::HUNGRY_COLOR}; color: #111; font-weight: bold; }
          .stairs { display: flex; align-items: center; gap: 4px; }
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
        <p>#{"#{@game.outcome} &nbsp; " unless @game.outcome.empty?}#{"GOD MODE &nbsp; " if @game.godMode?}#{"#{h @game.effects} &nbsp; " unless @game.effects.empty?}HP #{@game.hp}/#{@game.max_hp} &nbsp; AC #{@game.ac} &nbsp; Weapon #{h @game.weapon} &nbsp; Blood sugar #{@game.blood_sugar} &nbsp; Gold #{@game.gold} &nbsp; Sandwiches #{@game.sandwiches} &nbsp; #{@game.load_text} &nbsp; Depth #{@game.depth}</p>
        <pre>#{map_html}</pre>
        <p>#{@game.log.map { |line| h line }.join("<br>")}</p>
        #{%(<iframe src="/plaque" title="Wall of Fallen Heroes" style="border: 0; width: 100%; height: 22em;"></iframe>) if @game.plaque?}
        <!-- The map spans the page like a lintel over two posts: the move pad lower left, the knapsack lower right -->
        <div class="below">
          <div class="controls">
            #{%(<form method="post" action="/throw"><button data-keys="t" style="width: auto">throw (t)</button></form>) if @game.can_hurl?}
            #{stairs}
            <div class="pad-row">
              <div class="pad">#{buttons.join}</div>
              <div class="controls">
                <form method="post" action="/tap"><button data-keys="f" style="width: auto">#{h @game.tap_label} (f)</button></form>
                <form method="post" action="/zap"><button data-keys="z" style="width: auto">Zap wand (z)</button></form>
                #{%(<form method="post" action="/use_tools"><button data-keys="o" style="width: auto">Use the tools in the Toolbag to open the door (o)</button></form>) if @game.tools_ready?}
                <form method="post" action="/throw_chosen"><button data-keys="x" style="width: auto">#{h @game.throw_label} (x)</button></form>
                <form method="post" action="/give_chosen"><button data-keys="g" style="width: auto">#{h @game.give_label} (g)</button></form>
              </div>
            </div>
            <form method="post" action="/inventory"><button data-keys="i" style="width: auto">Inventory (i)</button></form>
            <form method="post" action="/wield"><button data-keys="w" style="width: auto">Wield (w)</button></form>
          </div>
          <aside class="panel">
            #{%(<div class="knapsack">Knapsack: #{packed.join}</div>) if packed.any?}
            <form method="post" action="/give_coin"><button data-keys="$">#{h @game.give_coin_label}</button></form>
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
  OEM = { # "@" => "☺",
          "#" => "▒", "." => "·", ">" => "≡", "$" => "☼", "%" => "♣", "🐿️" => "s", "🐿" => "s" }.freeze
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
    "s" => [:choose, "Select which item to throw or give?"],
  }.freeze

  HELP = [
    "Keys",
    "hjklyubn, arrows,",
    "  or keypad: move",
    "R or r: rest",
    "i: inventory",
    "w: wield",
    "a: use an item",
    "T: throw an item",
    "K: kick a candle",
    "P: pour a potion",
    "$: give coin",
    "%: give sandwich",
    "t: throw the gift",
    "f: tap",
    "z: zap the wand",
    "o: open with Toolbag",
    "s: select an item",
    "x: throw selected",
    "g: give selected",
    "?: knapsack/keys",
    "N: new game",
    "Q: quit",
  ].freeze

  # The status line, the map, the four log lines, and the prompt; the knapsack panel stacks above the map, so a
  # screen runs this many rows plus the panel's
  SCREEN_ROWS = 1 + Dungeon::VIEWPORT_HEIGHT + 4 + 1

  attr_reader :game

  def initialize(godMode: false, level: 1)
    @godMode = godMode
    @level = level
    @game = Dungeon.new(godMode: @godMode, level: @level)
    @game.hero_name = @name = Plaque.last_name
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

  # The screen's lines: the status, the map with the knapsack (or the keys) beside it, the log, any plaque the
  # finished game earned, and a prompt
  def lines
    panel = panel_lines
    map = @game.cells.map do |row|
      row.map { |glyph, hungry| hungry ? "#{ESC}[1;33m#{oem(glyph)}#{ESC}[0m" : oem(glyph) }.join
    end
    [status] + panel + map + Array.new(4) { |i| @game.log[i].to_s } + plaque_lines + [prompt]
  end

  # The finished game's plaque, made once per game and hung on the wall: the stylesheet's ASCII art, or, with
  # no XSLT processor around, Plaque.text's plain lines. None until the game is over, or for a game that earns none
  def plaque_lines
    @game.plaque? or return []
    return @plaque.last if @plaque&.first.equal?(@game)

    xml = @game.plaque_xml
    begin
      Plaque.record(xml)
    rescue SystemCallError
      # a wall that can't be written to just goes without this plaque
    end
    text = Plaque.processor ? Plaque.ascii(xml) : Plaque.text(xml)
    (@plaque = [@game, text.lines.map(&:chomp)]).last
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
    return @game.take_stairs(%w[y Y].include?(key)) if @game.stairs_question && %w[y Y n].include?(key)

    case key
    when "i" then @game.inventory
    when "w" then @game.wield
    when "t" then @game.hurl
    when "f" then @game.tap
    when "z" then @game.zap
    when "o" then @game.use_tools
    when "R", "r" then @game.rest # the console's rest key, either case; . and 5 still rest too, as the keypad's middle
    when "x" then @game.throw_chosen
    when "g" then @game.give_chosen
    when "$" then @game.give_coin
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
    splash
    @game.hero_name = ask_name($stdin)
    write "#{ESC}[2J#{ESC}[?25l" # only now does the game's own screen take over
    $stdin.raw do |input|
      @input = input
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
    rows = (lines.size rescue SCREEN_ROWS)
    goodbye = "#{ESC}[0m#{ESC}[#{rows + 1};1H#{ESC}[?25h\n"
    return goodbye unless @error

    "#{goodbye}The game broke: #{@error.class}: #{@error.message}\n#{@error.backtrace.to_a.first(5).map { |l| "  #{l}\n" }.join}"
  end

  # The opening story, a page of plain command-line text, as if by puts, before the name prompt; the game's own
  # screen takes over only after both
  def splash
    `figlet Quail on the Run`
    write "\n#{Dungeon::PREFACE.map { |line| "#{line}\n" }.join}\n"
  end

  # Asks the hero's name, offering the last one, as ['Johnson']: _, which Enter keeps. At the start it's a plain
  # command-line prompt; playing again, it first clears the game's screen
  def ask_name(input, clear: false)
    write "#{ESC}[2J#{ESC}[H#{ESC}[?25h" if clear # playing again: off the game's screen, the cursor back
    write "What is your name, hero?#{" ['#{@name}']" if @name}: "
    given = Plaque.clean_name(input.gets)
    @name = given unless given.empty?
    @name
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
    "#{banner}#{"GOD MODE  " if g.godMode?}#{"#{g.effects}  " unless g.effects.empty?}HP #{g.hp}/#{g.max_hp}  AC #{g.ac}  " \
      "Weapon #{g.weapon}  Blood sugar #{g.blood_sugar}  Gold #{g.gold}  Sandwiches #{g.sandwiches}  #{g.load_text}  Depth #{g.depth}"
  end

  # The knapsack, each entry lettered for the prompts, or the keys while ? shows them, the tap key named for the
  # way the player faces
  def panel_lines
    if @help
      named = { "f: tap" => "f: #{@game.tap_label}", "$: give coin" => "$: coin #{Dungeon::DIRECTIONS[@game.facing]}" }
      return HELP.map { |line| named.fetch(line, line) }
    end

    # The tap, Throw, and Give keys are always on show, as the other views always show their buttons
    buttons = ["f: #{@game.tap_label}", "x: #{@game.throw_label}", "g: #{@game.give_label}"]
    packed = @game.contents
    return ["Knapsack: empty", "? lists the keys"] + buttons if packed.empty?

    ["Knapsack:"] + packed.each_with_index.map do |(text, slot), i|
      "#{(97 + i).chr}) #{"(*) " if @game.chosen == slot}#{text}"
    end + buttons
  end

  def prompt
    return "#{PROMPTS.values.to_h[@pending]} (#{letters}, Esc cancels)" if @pending
    return "#{ending} Play again? (y/n)" if @error || @game.over?
    return "You want to go #{@game.stairs_question}? (y/n)" if @game.stairs_question
    return @note if @note
    return "Then an arrow sends it that way, or R keeps it" if @game.log.last.to_s.end_with?("which way?")
    return "o: use the tools in the Toolbag to open the door" if @game.tools_ready?

    @game.repeat_ready? ? "R repeats that key" : "? for the keys"
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
    @game = Dungeon.new(godMode: @godMode, level: @level)
    @game.hero_name = @input ? @input.cooked { ask_name(@input, clear: true) } : @name
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
      elsif Dungeon::WANDS.key?(slot) then @game.zap(slot)
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
    when :choose then @game.choose(slot)
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

  Usage: ruby ruby_rogue.rb [--dos | --web [port] | --scarpe] [--level N] [--god]
         ruby ruby_rogue.rb --help

    --dos         play right here in the console, like the original PC Rogue: ANSI driver commands, OEM glyphs,
                  and Rogue's keys (? lists them). This is the default, with no front end named
    --web [port]  play in a browser instead, at http://localhost:port/ (port 1-65535, default 4567)
    --scarpe      play in a desktop window, drawn by Scarpe
    --level N     start at depth N (1-99), a cheat that also turns on god mode; New game starts there too
    --god         god mode: the player takes no damage
    -h, --help    show this help and exit
TEXT

# The depth --level asks to start at, 1 without it; anything but a whole number from 1 to 99 stops with the usage
def cli_level
  at = ARGV.index("--level") or return 1
  level = Integer(ARGV[at + 1].to_s, exception: false)
  return level if level&.between?(1, 99)

  abort "Usage: ruby ruby_rogue.rb --level N, where N is a depth from 1 to 99 (got #{ARGV[at + 1].inspect})"
end

# Guarded so the tests can require this file for Dungeon without opening a window or a port.
# Scarpe 0.5.0 has no Scarpe.app; requiring scarpe provides Shoes.app instead.
# Starting deeper with --level is a cheat, so it plays in god mode too
GOD = (ARGV & %w[--god --level]).any?

# Plays sounds/<name>.wav through whichever player this machine has, without waiting for it to finish
def Dungeon.speakers
  sound_app = %w[paplay pw-play aplay].find { |p| system("command -v #{p} > /dev/null 2>&1") }
  lambda do |name|
    file = File.join(__dir__, "sounds", "#{name}.wav")
    sound_app && File.exist?(file) and Process.detach(spawn(sound_app, file, %i[out err] => File::NULL))
  end
end

# The front ends play the game's sounds out loud
Dungeon.sound_player = Dungeon.speakers if $PROGRAM_NAME == __FILE__

if $PROGRAM_NAME == __FILE__ && (ARGV & %w[--help -h]).any?
  puts USAGE
elsif $PROGRAM_NAME == __FILE__ && (ARGV.include?("--dos") || (ARGV & %w[--web --scarpe]).empty?)
  # The console is the default: --dos, or no front end named at all
  DosBox.new(godMode: GOD, level: cli_level).play
elsif $PROGRAM_NAME == __FILE__ && ARGV.include?("--web")
  # The port is whatever follows --web, defaulting to 4567; another flag such as --god there means no port given
  arg = ARGV[ARGV.index("--web") + 1]
  arg = nil if arg&.start_with?("--")
  port = arg ? Integer(arg, exception: false) : 4567
  abort "Usage: ruby ruby_rogue.rb --web [port] [--god], where port is 1-65535 (got #{arg.inspect})" unless port&.between?(1, 65_535)

  WebGame.new(godMode: GOD, level: cli_level).serve(port)
elsif $PROGRAM_NAME == __FILE__

LEVEL = cli_level
gem 'scarpe' # '0.1.0'
require 'scarpe'
Scarpe.app(title: "Scarpe Rogue") do # , width: 560, height: 640) do
  @game = Dungeon.new(godMode: GOD, level: LEVEL)

  @status = stack(size: 1){}
  # Newlines become <br>, but runs of spaces still collapse, so blanks go in as non-breaking spaces
  @map = stack(family: "monospace", size: 11){}
  @log = stack(size: 10){}
  @packed = flow {}

  #  make aggressive things attack the TODO weapon and the mobile wall

  redraw = lambda do
    PAD.zip(@arrows.to_a).each do |line, slot|
      slot&.clear do
        line.each do |label, dx, dy|
          label = "again" if dx.zero? && dy.zero? && @game.repeat_ready? # after three of a key, rest repeats it
          button([dx, dy] == @game.facing ? "[#{label}]" : label, width: 60) do
            dx.zero? && dy.zero? ? @game.rest : @game.move(dx, dy)
            redraw.call
          end
        end
      end
    end
    # Beside the arrows: the stairs question while it's asked, then tap, Throw, and Give, each named afresh
    @tap&.clear do
      if (way = @game.stairs_question)
        para "You want to go #{way}?"
        button("Yes") do
          @game.take_stairs(true)
          redraw.call
        end
        button("No") do
          @game.take_stairs(false)
          redraw.call
        end
      end
      button(@game.tap_label) do
        @game.tap
        redraw.call
      end
      button(@game.throw_label) do
        @game.throw_chosen
        redraw.call
      end
      button(@game.give_label) do
        @game.give_chosen
        redraw.call
      end
    end
    @give_coin&.clear do
      button(@game.give_coin_label) do
        @game.give_coin
        redraw.call
      end
    end
    @status.replace "#{"#{@game.outcome}   " unless @game.outcome.empty?}#{"GOD MODE   " if @game.godMode?}#{"#{@game.effects}   " unless @game.effects.empty?}HP #{@game.hp}/#{@game.max_hp}   AC #{@game.ac}   Weapon #{@game.weapon}   Blood sugar #{@game.blood_sugar}   Gold #{@game.gold}   Sandwiches #{@game.sandwiches}   #{@game.load_text}   Depth #{@game.depth}"
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
        # A radio button of sorts: it chooses the entry for Throw and Give without using it
        button(@game.chosen == slot ? "(•)" : "( )") do
          @game.choose(slot)
          redraw.call
        end
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
          elsif Dungeon::WANDS.key?(slot) then @game.zap(slot)
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
  # Each row of arrows sits in a slot redraw refills, so the arrow the player faces can be marked, [→]. The tap
  # button sits to the right of their middle row, in a slot redraw also refills, since its name follows that way too
  @arrows = []
  PAD.each_with_index do |_, row|
    flow do
      @arrows << flow {}
      @tap = flow(width: 240) {} if row == 1
    end
  end

  # The give coin button gives straight away, the way the player faces, so redraw renames it; the give sandwich
  # button readies its gift, and the next arrow hands it over
  flow do
    @give_coin = flow {}
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
      @game = Dungeon.new(godMode: GOD, level: LEVEL)
      redraw.call
    end
  end

  redraw.call
end
end
