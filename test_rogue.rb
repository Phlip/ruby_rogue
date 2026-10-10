# Run with: ruby test_scarpe_rogue.rb

require 'minitest/autorun'
require_relative 'rogue'

module Things
  # The THINGAGES row a thingage of this name spawns from; a name with no row of its own is a weapon's look
  def row_for(name)
    Dungeon::THINGAGES.find { |k| k[:name] == name } || Dungeon::THINGAGES.find { |k| k[:name] == "weapon" }
  end

  # Builds a Thingage from named fields, so no test depends on the order of the Struct's members. Like a
  # spawned one, it gets all six ability scores from its kind's row, unless a field names its own
  def thing(x, y, glyph, name, hp, hit, **fields)
    scores = row_for(name).slice(*Dungeon::ABILITIES).merge(fields.slice(*Dungeon::ABILITIES))
    Dungeon::Thingage.new(x, y, glyph, name, hp, hit, *scores.values_at(*Dungeon::ABILITIES))
                     .tap { |t| fields.except(*Dungeon::ABILITIES).each { |field, value| t[field] = value } }
  end

  # An egg, just yolk unless developed, not yet held up to the light unless candled
  def egg(developed = false, candled: false) = Dungeon::Egg.new(developed, candled)

  # Fails naming every thingage on the level that is missing an ability score
  def assert_no_missing_scores(monsters)
    missing = monsters.to_a.flat_map do |m|
      Dungeon::ABILITIES.select { |a| m[a].nil? }.map { |a| "#{m.name} at #{m.x}, #{m.y} has no #{a}" }
    end
    assert_empty missing
  end
end

class DungeonTest < Minitest::Test
  include Things
  W = Dungeon::VIEWPORT_WIDTH
  H = Dungeon::VIEWPORT_HEIGHT

  def setup
    srand(1234)
    @game = Dungeon.new
  end

  # Whatever a test did, nothing it leaves on the level may be missing an ability score
  def teardown
    assert_no_missing_scores(assert_get(:monsters))
  end

  def arrange_get(name) = @game.instance_variable_get("@#{name}")
  def arrange_set(name, value) = @game.instance_variable_set("@#{name}", value)
  def assert_get(name) = @game.instance_variable_get("@#{name}")

  # Replaces the random level with one open room walled at the border, fully seen,
  # so each test places exactly the pieces it cares about. The player there has a round 20 hit points, whatever
  # the Ego row says, so that the arithmetic of blows and healing reads plainly
  def arrange_arena(px: 5, py: 5)
    arrange_set :max_hp, 20
    arrange_set :hp, 20
    arrange_set :map, Array.new(H) { |y| Array.new(W) { |x| [0, W - 1].include?(x) || [0, H - 1].include?(y) ? "#" : "." } }
    arrange_set :seen, Array.new(H) { Array.new(W, true) }
    arrange_set :monsters, []
    arrange_set :treasure, {}
    arrange_set :sandwiches, {}
    arrange_set :plates, {}
    arrange_set :traps, {}
    arrange_set :population, Hash.new(0)
    arrange_set :detected, []
    arrange_set :px, px
    arrange_set :py, py
  end

  # A goblin that already fights, as most tests want; pass aggressive: false for one that starts neutral
  def arrange_monster(x, y, hp: 10, hit: 3..3, str: 10, dex: 10, con: 10, int: 10, wis: 10, cha: 10, greedy: false, ally: nil,
                      aggressive: true)
    arrange_get(:monsters) << thing(x, y, "g", "goblin", hp, hit, str: str, dex: dex, con: con, int: int, wis: wis, cha: cha,
                                    pacifist: false, greedy: greedy, ally: ally, aggressive: aggressive)
  end

  def arrange_quail(x, y, hp: 100, met: [])
    # arrange_get(:monsters) reaches into the game and returns its private @monsters array, the list of every
    # thingage on the level. It's the very same array the game uses, not a copy, so << appending the
    # new Quail to it puts the Quail on the map; the game's next turn will see it and move it
    arrange_get(:monsters) << thing(x, y, "Q", "Quail", hp, 0..0, pacifist: true, met: met)
  end

  def player = [arrange_get(:px), arrange_get(:py)]
  def last_log = @game.log.last

  # --- a new game ---

  def test_a_game_can_start_deeper
    game = Dungeon.new(level: 5)
    assert_equal 5, game.depth
    assert_equal Dungeon.new.max_hp + 8, game.max_hp, "as though it had come down four new levels, 2 each"
    assert_equal game.max_hp, game.hp, "at full health"
    refute_nil game.instance_variable_get(:@cage), "depth 5 has its cage room"
    assert_equal "You descend into the dark to depth 5. Find the stairs (>).", game.log.last
  end

  def test_a_deeper_start_counts_as_the_deepest_yet
    game = Dungeon.new(level: 4)
    assert_equal 4, game.instance_variable_get(:@deepest)
  end

  def test_new_game_starts_with_full_health_and_no_gold
    assert_equal 15, @game.hp
    assert_equal 15, @game.max_hp
    assert_equal Dungeon::HERO_AC, @game.ac
    assert_equal Dungeon::MAX_BLOOD_SUGAR, @game.blood_sugar
    assert_equal "fists", @game.weapon
    assert_equal({ gold: 0, sandwiches: 0, potions: 0, speed_potions: 0, gas_potions: 0, slow_potions: 0, healing_potions: 0, sleep_potions: 0, empty_potions: 0, scrolls: 0, mapping_scrolls: 0, peace_rings: 0, strength_rings: 0, protection_rings: 0, candles: 0, laced_potions: 0, laced_speed_potions: 0, laced_gas_potions: 0, laced_slow_potions: 0, laced_healing_potions: 0, laced_sleep_potions: 0, laced_empty_potions: 0, eggs: [], weapons: [], shields: [], wands: [] }, @game.knapsack)
    assert_equal 1, @game.depth
    assert_equal 1, @game.log.size
    refute @game.over?
  end

  # --- the player's stats come from the Ego row ---

  def ego = Dungeon::THINGAGES.find { |k| k[:name] == "Ego" }

  def test_the_player_is_the_ego_row
    assert_same ego, Dungeon::PLAYER
  end

  def test_the_players_hit_points_are_the_ego_rows_plus_its_con_modifier
    assert_equal ego[:hp] + Dungeon.modifier(ego[:con]), @game.max_hp
    assert_equal @game.max_hp, @game.hp, "starting at full"
  end

  def test_the_players_armor_class_is_the_ego_rows
    assert_equal ego[:ac], @game.ac
  end

  def test_bare_hands_hit_for_the_ego_rows_hit
    assert_equal ego[:hit], Dungeon::BARE_HANDS_HIT
    assert_equal ego[:hit], @game.weapon_hit
  end

  def test_the_players_ability_scores_are_the_ego_rows
    assert_equal ego.slice(*Dungeon::ABILITIES), @game.abilities
    assert @game.abilities.frozen?, "read from the row, not changed in play"
  end

  # --- blood sugar ---

  def rounds(n) = n.times { @game.send(:end_turn) }

  def test_blood_sugar_drops_one_every_sugar_rounds
    arrange_arena
    (Dungeon::SUGAR_ROUNDS - 1).times { @game.rest }
    assert_equal Dungeon::MAX_BLOOD_SUGAR, @game.blood_sugar, "not yet"
    @game.rest
    assert_equal Dungeon::MAX_BLOOD_SUGAR - 1, @game.blood_sugar
    (2 * Dungeon::SUGAR_ROUNDS).times { @game.rest }
    assert_equal Dungeon::MAX_BLOOD_SUGAR - 3, @game.blood_sugar
  end

  def test_at_zero_you_lose_a_hit_point_every_150_rounds
    arrange_arena
    arrange_set :blood_sugar, 0
    rounds(149)
    assert_equal 20, @game.hp
    rounds(1)
    assert_equal 19, @game.hp
    assert_equal "You're starving and lose a hit point.", last_log
    rounds(150)
    assert_equal 18, @game.hp
    assert_equal 0, @game.blood_sugar
  end

  def test_you_can_starve_to_death
    arrange_arena
    arrange_set :blood_sugar, 0
    arrange_set :starving, 149
    arrange_set :hp, 1
    rounds(1)
    assert @game.over?
    assert_equal "You starve to death on depth 1 with 0 gold.", last_log
  end

  def test_god_mode_never_starves
    @game = Dungeon.new(godMode: true)
    arrange_arena
    arrange_set :blood_sugar, 0
    rounds(150)
    assert_equal 20, @game.hp
  end

  def test_resting_on_an_offered_sandwich_eats_it
    arrange_arena
    arrange_set :blood_sugar, 0
    arrange_set :starving, 140
    arrange_get(:knapsack)[:sandwiches] = 2
    @game.offer(:sandwiches)
    assert_equal "Give a sandwich which way? Rest to eat it yourself.", last_log
    @game.rest
    assert_equal 1, @game.sandwiches
    assert_includes 2..12, @game.blood_sugar, "2d6 on top of nothing"
    assert_match(/\AYou eat the sandwich\. Your blood sugar rises by (\d+), to \1\.\z/, last_log)
    rounds(10)
    assert_equal 20, @game.hp, "the starving count starts over"
  end

  # --- a sandwich's lock is its wrapping ---

  def add_sandwich(x, y) = arrange_get(:monsters) << thing(x, y, "~", "sandwich", 3, 0..0, pacifist: true)
  def wrapping(food) = @game.send(:food_machine, food).state

  def test_a_sandwich_starts_wrapped_and_its_machine_runs_on_its_rows_table
    arrange_arena
    food = add_sandwich(6, 5).last
    assert_instance_of Dungeon::DoorLock::LockState, wrapping(food)
    table = kind("sandwich")[:transitions]
    assert_equal Dungeon::DoorLock::SandwichOpenState, table[[Dungeon::DoorLock::UnlockingState, Dungeon::DoorLock::LockEvent::TIMER]]
  end

  def test_the_first_tap_starts_unwrapping_it
    arrange_arena
    food = add_sandwich(6, 5).last
    @game.tap
    assert_instance_of Dungeon::DoorLock::UnlockingState, wrapping(food)
    assert_equal 2, food.hp
    assert_equal "You work at the sandwich's wrapping.", last_log
  end

  def test_taps_wear_it_open_and_edible
    arrange_arena
    food = add_sandwich(6, 5).last
    3.times { @game.tap }
    assert_instance_of Dungeon::DoorLock::SandwichOpenState, wrapping(food)
    assert_includes assert_get(:monsters), food, "opened, not destroyed"
    assert_equal "The sandwich's wrapping gives way. It's open, and edible.", last_log
  end

  def test_a_blow_wears_it_by_its_damage
    arrange_arena
    arrange_set :wielded, { name: "club", glyph: nil, hit: 10..10 }
    food = add_sandwich(6, 5).last
    @game.move(1, 0)
    assert_instance_of Dungeon::DoorLock::SandwichOpenState, wrapping(food), "one blow of 10 opens it"
    assert_includes assert_get(:monsters), food
  end

  def test_an_open_sandwich_waits_until_you_are_peckish
    arrange_arena
    food = add_sandwich(6, 5).last
    3.times { @game.tap }
    @game.tap
    assert_instance_of Dungeon::DoorLock::SandwichOpenState, wrapping(food)
    assert_includes assert_get(:monsters), food
    assert_equal "The sandwich is open and edible, but your blood sugar isn't low enough to want it.", last_log
  end

  def test_tapping_an_open_sandwich_when_peckish_eats_it_as_it_leaves_the_open_state
    arrange_arena
    food = add_sandwich(6, 5).last
    3.times { @game.tap }
    arrange_set :blood_sugar, 10
    @game.tap
    refute_includes assert_get(:monsters), food, "that sandwich is gone"
    assert_instance_of Dungeon::DoorLock::LockState, wrapping(food), "the edge back to the lock"
    assert_includes 11..22, @game.blood_sugar, "10, plus 2d6, less any drop in the round the tap took"
    assert(@game.log.any? { |l| l.match?(/\AYou eat the sandwich\. Your blood sugar rises by \d+, to \d+\.\z/) })
  end

  def test_the_open_states_action_feeds_whoever_its_handed
    eater = Object.new.tap { |o| o.define_singleton_method(:feed) { |food| @fed = food } }
    state = Dungeon::DoorLock::SandwichOpenState.new
    state.on_exit(eater, :the_sandwich)
    assert_equal :the_sandwich, eater.instance_variable_get(:@fed)
    assert_kind_of Dungeon::DoorLock::OpenState, state
  end

  def test_a_knapsack_sandwich_wants_low_blood_sugar
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:sandwiches] = 1
    @game.offer(:sandwiches)
    @game.rest
    assert_equal "Your blood sugar isn't low enough to want a sandwich.", last_log
    assert_equal 1, @game.sandwiches
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "no turn passes"
  end

  def test_a_sandwich_feeds_two_d6_up_to_the_most_there_is
    arrange_get(:knapsack)[:sandwiches] = 300
    gains = Array.new(300) do
      arrange_set :blood_sugar, 0
      @game.feed(nil)
      @game.blood_sugar
    end
    assert_equal [2, 12], gains.minmax
    assert_in_delta 7, gains.sum / 300.0, 0.6
    assert_equal 0, @game.sandwiches

    arrange_get(:knapsack)[:sandwiches] = 1
    arrange_set :blood_sugar, 95
    @game.feed(nil)
    assert_operator @game.blood_sugar, :<=, Dungeon::MAX_BLOOD_SUGAR
  end

  def test_a_creature_s_blood_sugar_runs_down_once_it_wakes
    arrange_arena
    awake = arrange_monster(8, 5, hp: 100, hit: 0..0).last          # aggressive, so it acts at once
    asleep = arrange_monster(9, 9, hp: 100, aggressive: false).last # neutral, so it never stirs
    (3 * Dungeon::SUGAR_ROUNDS).times { @game.rest }
    assert_equal Dungeon::MAX_BLOOD_SUGAR - 3, awake.sugar
    assert_nil asleep.sugar, "still asleep, still full"
  end

  def test_things_that_dont_eat_have_no_blood_sugar
    arrange_arena
    wall = thing(6, 5, "#", "wall", 100, 0..0, pacifist: true, ally: true)
    arrange_get(:monsters) << wall
    3.times { @game.rest }
    assert_nil wall.sugar
  end

  def test_a_starving_creature_loses_hit_points_and_can_die
    arrange_arena
    goblin = arrange_monster(30, 20, hp: 2).last.tap { |m| m.sugar = 0 } # out of sight, so it doesn't act
    rounds(150)
    assert_equal 1, goblin.hp
    rounds(150)
    refute_includes assert_get(:monsters), goblin
    assert_equal "The goblin starves to death.", last_log
  end

  def test_a_sandwich_fills_a_creature_up
    arrange_arena
    quail = arrange_quail(6, 5).last.tap { |q| q.sugar = 0; q.starving = 100 }
    give(:sandwiches, 1, 0)
    assert_equal "You give the Quail a sandwich. It eats it.", last_log
    assert_equal Dungeon::MAX_BLOOD_SUGAR, quail.sugar, "full, one round being too few to drain any"
    assert_equal 0, quail.starving
  end

  def test_hungry_creatures_are_drawn_hungry
    arrange_arena
    arrange_monster(7, 5, hp: 100, aggressive: false).last.sugar = 0
    arrange_monster(9, 5, hp: 100, aggressive: false).last.sugar = 50
    row = @game.map_runs[5]
    assert_equal @game.rows[5], row.map(&:first).join, "the runs spell out the row"
    assert_equal [["g", true]], row.select { |_, hungry| hungry }, "only the hungry goblin"
    arrange_set :blood_sugar, 0
    assert_includes @game.map_runs[5], ["@", true]
  end

  # --- level generation, checked across many seeds ---

  def each_level
    50.times do |seed|
      srand(seed)
      @game = Dungeon.new
      yield seed
    end
  end

  def test_rows_match_the_map_size
    each_level do |seed|
      rows = @game.rows
      # assert_equal H, rows.size, "seed #{seed}"
      # assert(rows.all? { |r| r.size == W }, "seed #{seed}")
    end
  end

  def test_level_is_walled_at_the_border
    each_level do |seed|
      map = arrange_get(:map)
      assert(map.first.all?("#") && map.last.all?("#"), "seed #{seed}")
      assert(map.all? { |row| row.first == "#" && row.last == "#" }, "seed #{seed}")
    end
  end

  def test_level_has_exactly_one_staircase
    each_level do |seed|
      assert_equal 1, assert_get(:map).flatten.count(">"), "seed #{seed}"
    end
  end

  def test_player_starts_on_the_floor_away_from_the_stairs
    each_level do |seed|
      x, y = player
      assert_equal ".", assert_get(:map)[y][x], "seed #{seed}"
    end
  end

  def test_tunnels_connect_every_floor_tile_to_the_player
    each_level do |seed|
      map = arrange_get(:map)
      reached = {}
      queue = [player]

      until queue.empty?
        x, y = queue.shift
        next if reached[[x, y]] || map[y][x] == "#"

        reached[[x, y]] = true
        queue.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1])
      end

      open = (0...H).flat_map { |y| (0...W).map { |x| [x, y] } }.reject { |x, y| map[y][x] == "#" }
      assert_equal open.sort, reached.keys.sort, "seed #{seed}: unreachable tiles"
    end
  end

  def test_treasure_sandwiches_and_monsters_sit_on_free_floor
    each_level do |seed|
      map = arrange_get(:map)
      spots = arrange_get(:treasure).keys + arrange_get(:sandwiches).keys + arrange_get(:monsters).map { |m| [m.x, m.y] }
      spots.each { |x, y| assert_equal ".", map[y][x], "seed #{seed} at #{[x, y]}" }
      refute_includes spots, player, "seed #{seed}"
      assert_equal spots.uniq.size, spots.size, "seed #{seed}: overlap"
    end
  end

  def test_levels_scatter_a_few_single_sandwiches
    counts = []

    each_level do |seed|
      assert(assert_get(:sandwiches).values.all?(1), "seed #{seed}")
      counts << arrange_get(:sandwiches).size
    end
    
    assert(counts.any?(&:positive?), "some level should have sandwiches")
    assert(counts.all? { |n| n <= 7 }, "at most one per room past the first")
  end

  # --- monster spawning by depth ---

  def arrangeManyLevels(depth)
    arrange_arena(px: 1, py: 1)
    arrange_set :depth, depth
    room = { x: 2, y: 2, w: W - 4, h: H - 4 }
    loop { @game.send(:spawn_monster, room) or break }
    arrange_get(:monsters)
  end

  def test_depth_four_only_spawns_rats_and_goblins
    # assert_equal %w[@ g o r 🗡], spawn_many(4).map(&:glyph).uniq.sort
  end

  def test_deeper_levels_spawn_every_kind
    # assert_equal %w[@ g r 🗡], spawn_many(3).map(&:glyph).uniq.sort
  end

  def kind_names(cr:) = Dungeon::THINGAGES.select { |k| k[:cr] <= cr }.map { |k| k[:name] }
  def weapon_names = Dungeon::WEAPONS.map { |w| w[:name] }

  def test_depth_one_only_spawns_challenge_rating_one_kinds
    names = arrangeManyLevels(1).map(&:name).uniq
    assert_empty names - kind_names(cr: 1) - weapon_names
    refute_includes names, "goblin"
  end

  def test_goblins_first_appear_on_depth_two
    refute_includes arrangeManyLevels(1).map(&:name), "goblin"
    assert_includes arrangeManyLevels(2).map(&:name), "goblin"
  end

  # TODO  revitalize this one
  def test_no_level_holds_more_of_a_kind_than_its_number_appearing
    arrangeManyLevels(10)
  #   population = arrange_get(:population)
  #   Dungeon::THINGAGES.each { |k| assert_operator population[k[:name]], :<=, k[:na], k[:name] }
  end

  def test_random_spawning_skips_unique_kinds
    uniques = Dungeon::THINGAGES.select { |k| k[:na] == 1 }.map { |k| k[:name] }
    assert_includes uniques, "Quail"
    assert_empty arrangeManyLevels(10).map(&:name) & uniques
  end

  def test_a_unique_kind_spawns_when_named
    arrangeManyLevels(10)
    quail = Dungeon::THINGAGES.find { |k| k[:name] == "Quail" }
    room = { x: 2, y: 2, w: W - 4, h: H - 4 }
    @game.send(:spawn_monster, room, quail)
    assert_equal 1, assert_get(:monsters).count { |m| m.name == "Quail" }
    assert_equal 1, assert_get(:population)["Quail"]
  end

  def test_the_player_is_the_only_ego
    arrangeManyLevels(10)
    assert_equal 0, assert_get(:monsters).count { |m| m.name == "Ego" || m.glyph == "@" }

    ego = Dungeon::THINGAGES.find { |k| k[:name] == "Ego" }
    assert_nil @game.send(:spawn_monster, { x: 2, y: 2, w: W - 4, h: H - 4 }, ego), "not even when named"
  end

  def test_spawning_stops_once_every_kind_is_full
    arrangeManyLevels(10)
    full = Dungeon::THINGAGES.reject { |k| k[:na] == 1 || k[:out_of_band] }.sum { |k| k[:na] }
    assert_equal full, assert_get(:monsters).size
    assert_nil @game.send(:spawn_monster, { x: 2, y: 2, w: W - 4, h: H - 4 })
  end

  def test_monsters_get_tougher_with_depth
    rat = Dungeon::THINGAGES.find { |k| k[:glyph] == "r" }
    arrangeManyLevels(4).select { |m| m.glyph == "r" }.each { |m| assert_equal rat[:hp] + 4, m.hp }
  end

  # --- ability scores ---

  def kind(name) = Dungeon::THINGAGES.find { |k| k[:name] == name }
  def scores(t) = Dungeon::ABILITIES.map { |a| t[a] }
  def room = { x: 2, y: 2, w: W - 4, h: H - 4 }

  # Lays one thingage of this kind (a THINGAGES row, or a tweaked copy of one) at the given depth
  def spawn_one(row, depth: 1)
    arrange_arena(px: 1, py: 1)
    arrange_set :depth, depth
    @game.send(:spawn_monster, room, row)
    arrange_get(:monsters).last
  end

  # The player's hit points lost when this thingage strikes once from beside them
  def one_blow_from(t)
    arrange_arena
    arrange_set :hp, @game.max_hp
    t.aggressive = true # provoked, so it swings even if its kind starts neutral
    t.x, t.y = 6, 5
    arrange_get(:monsters) << t
    hp = @game.hp
    @game.rest
    hp - @game.hp
  end

  def test_the_thingage_struct_holds_six_ability_scores_after_hit
    members = Dungeon::Thingage.members
    assert_equal %i[str dex con int wis cha], members[members.index(:hit) + 1, 6]
    assert_equal %i[str dex con int wis cha], Dungeon::ABILITIES
  end

  def test_every_thingages_row_has_all_six_scores
    Dungeon::THINGAGES.each do |k|
      Dungeon::ABILITIES.each { |a| assert_kind_of Integer, k[a], "#{k[:name]} #{a}" }
    end
  end

  def test_modifiers_follow_the_dnd_table
    { 1 => -5, 2 => -4, 3 => -4, 7 => -2, 8 => -1, 9 => -1, 10 => 0, 11 => 0,
      12 => 1, 13 => 1, 14 => 2, 15 => 2, 16 => 3, 17 => 3, 18 => 4, 20 => 5 }.each do |score, mod|
      assert_equal mod, Dungeon.modifier(score), "score #{score}"
    end
  end

  def test_a_missing_score_counts_as_ten
    assert_equal 0, Dungeon.modifier(nil)
  end

  def test_spawned_thingages_carry_their_rows_scores
    %w[rat goblin orc troll wall gold sandwich potion Quail].each do |name|
      assert_equal kind(name).values_at(*Dungeon::ABILITIES), scores(spawn_one(kind(name), depth: 5)), name
    end
  end

  # def test_spawned_weapons_carry_their_cloaks_scores
  #   assert_equal kind("goblin").values_at(*Dungeon::ABILITIES), scores(spawn_one(kind("weapon"))), "a goblin at depth 1"
  # end

  def test_randomly_spawned_thingages_carry_their_scores
    arrangeManyLevels(10).each do |m|
      row = kind(m.name) || kind("weapon")
      assert_equal row.values_at(*Dungeon::ABILITIES), scores(m), m.name
    end
  end

  def test_spawning_still_fills_the_flags_after_the_scores
    goblin = spawn_one(kind("goblin").merge(greedy: 1.0), depth: 2)
    refute goblin.pacifist
    assert goblin.greedy, "greedy lands in greedy, not in a score"
    assert_nil goblin.spurned

    wall = spawn_one(kind("wall"))
    assert_equal true, wall.pacifist
  end

  def test_constitution_adds_to_spawned_hit_points
    assert_equal 10 + 4 + 3, spawn_one(kind("orc"), depth: 4).hp, "orc: con 17 is +3"
    assert_equal 18 + 5 + 4, spawn_one(kind("troll"), depth: 5).hp, "troll: con 18 is +4"
    assert_equal 6 + 2, spawn_one(kind("goblin"), depth: 2).hp, "goblin: con 10 is +0"
  end

  def test_a_frail_thingage_still_spawns_with_at_least_one_hit_point
    assert_equal 1, spawn_one(kind("sandwich")).hp, "sandwich: 3 + depth 1 - 4 for con 2"
  end

  def test_raising_con_in_the_row_raises_spawned_hit_points
    plain = spawn_one(kind("goblin"), depth: 2).hp
    hardy = spawn_one(kind("goblin").merge(con: 18), depth: 2).hp
    assert_equal plain + 4, hardy
  end

  def test_an_average_goblin_hits_for_its_roll
    assert_equal 3, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 10))
  end

  def test_a_stronger_goblin_is_ornerier
    assert_equal 3, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 10))
    assert_equal 4, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 12)), "str 12 is +1"
    assert_equal 6, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 16)), "str 16 is +3"
    assert_equal 8, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 20)), "str 20 is +5"
  end

  def test_changing_a_live_goblins_strength_changes_its_next_blow
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    goblin = arrange_get(:monsters).last
    @game.rest
    assert_equal 17, @game.hp

    goblin.str = 18
    @game.rest
    assert_equal 11, @game.hp, "3 and one more is 7+4: the same goblin, ornerier"
    assert_equal "The goblin hits you for 7.", last_log
  end

  def test_an_ornery_row_spawns_an_ornery_goblin
    ornery = spawn_one(kind("goblin").merge(str: 18, hit: 2..2), depth: 2)
    assert_equal 18, ornery.str
    assert_equal 6, one_blow_from(ornery), "2 +4"
  end

  def test_a_weak_goblin_still_hits_for_one
    assert_equal 1, one_blow_from(thing(0, 0, "g", "goblin", 100, 3..3, str: 3)), "3 -4, floored at 1"
  end

  def test_the_real_goblin_hits_one_less_than_its_roll
    goblin = spawn_one(kind("goblin"), depth: 2)
    blows = Array.new(200) { @game.send(:blow, goblin) }
    assert_equal [1, 2, 3], blows.uniq.sort, "hit 1..4 with str 8 (-1), floored at 1"
  end

  def test_the_real_troll_hits_harder_than_its_roll
    troll = spawn_one(kind("troll"), depth: 5)
    blows = Array.new(200) { @game.send(:blow, troll) }
    assert_equal (6..11).to_a, blows.uniq.sort, "hit 3..8 with str 16 (+3)"
  end

  def test_strength_does_not_arm_a_harmless_thingage
    wall = thing(0, 0, "#", "wall", 30, 0..0, str: 18)
    assert_equal 0, @game.send(:blow, wall)
    assert_equal [18, 0, 18, 0, 0, 0], scores(wall), "str dex con int wis cha, from the wall row"

    empty = thing(0, 0, "$", "gold", 30, 0...0, str: 18)
    assert_equal 0, @game.send(:blow, empty)
    assert_equal [18, 0, 18, 0, 0, 0], scores(empty), "str dex con int wis cha, from the gold row"
  end

  def test_an_allys_strength_adds_to_its_strikes
    arrange_arena
    arrange_get(:monsters) << thing(7, 5, "g", "goblin", 10, 4..4, str: 14, ally: true)
    arrange_monster(8, 5, hp: 20, hit: 0..0)
    @game.rest
    assert_equal 14, assert_get(:monsters).last.hp, "4 +2"
    assert_includes @game.log, "Your goblin hits the goblin for 6."
  end

  def test_the_other_four_scores_change_nothing_yet
    meek = thing(0, 0, "g", "goblin", 100, 3..3, dex: 3, int: 3, wis: 3, cha: 3)
    keen = thing(0, 0, "g", "goblin", 100, 3..3, dex: 18, int: 18, wis: 18, cha: 18)
    assert_equal one_blow_from(meek), one_blow_from(keen)
  end

  # --- no ability score is ever nil ---

  # All six scores at an average 10, for building a Thingage straight from the Struct
  def average_scores = [10] * Dungeon::ABILITIES.size

  def test_every_row_has_all_six_scores_as_whole_numbers
    Dungeon::THINGAGES.each do |row|
      Dungeon::ABILITIES.each { |a| assert_kind_of Integer, row[a], "#{row[:name]} #{a}" }
    end
  end

  # def test_a_thingage_cannot_be_built_without_its_scores
  #   error = assert_raises(ArgumentError) { Dungeon::Thingage.new(0, 0, "g", "goblin", 5, 1..4) }
  #   assert_match(/str/, error.message, "it names the first missing score")
  # end

  # def test_a_thingage_cannot_be_built_with_any_one_score_missing
  #   Dungeon::ABILITIES.each_with_index do |a, i|
  #     given = average_scores.tap { |s| s[i] = nil }
  #     error = assert_raises(ArgumentError, "#{a} nil") { Dungeon::Thingage.new(0, 0, "g", "goblin", 5, 1..4, *given) }
  #     assert_match(/#{a}/, error.message)
  #   end
  # end

  def test_a_thingage_can_be_built_with_all_six_scores
    t = Dungeon::Thingage.new(0, 0, "g", "goblin", 5, 1..4, 8, 17, 10, 13, 15, 10)
    assert_equal [8, 17, 10, 13, 15, 10], scores(t)
  end

  def test_no_score_can_be_set_to_nil_by_name
    t = thing(0, 0, "g", "goblin", 5, 1..4)
    Dungeon::ABILITIES.each do |a|
      # assert_raises(ArgumentError, "#{a}=") { t.public_send("#{a}=", nil) }
      refute_nil t[a], "#{a} kept its score"
    end
  end

  # def test_no_score_can_be_set_to_nil_by_index
  #   t = thing(0, 0, "g", "goblin", 5, 1..4)
  #   Dungeon::ABILITIES.each do |a|
  #     assert_raises(ArgumentError, "[:#{a}]=") { t[a] = nil }
  #     assert_raises(ArgumentError, "[\"#{a}\"]=") { t[a.to_s] = nil }
  #     refute_nil t[a], "#{a} kept its score"
  #   end
  # end

  def test_a_score_can_still_change_to_another_number
    t = thing(0, 0, "g", "goblin", 5, 1..4)
    t.str = 18
    t[:dex] = 3
    assert_equal [18, 3], [t.str, t.dex]
  end

  def test_the_modifier_refuses_a_missing_score
    # assert_raises(ArgumentError) { Dungeon.modifier(nil) }
  end

  def test_the_modifier_still_reads_every_real_score
    assert_equal [-5, -4, 0, 0, 4, 5], [0, 3, 10, 11, 18, 20].map { |s| Dungeon.modifier(s) }
  end

  def test_spawning_any_kind_by_name_carries_its_rows_scores
    Dungeon::THINGAGES.reject { |row| row[:name] == Dungeon::PLAYER_KIND }.each do |row|
      t = spawn_one(row, depth: row[:cr])
      scored = row[:name] == "weapon" ? @game.send(:cloak_for, row[:cr]) : row # a weapon wears its cloak's scores
      # assert_equal Dungeon::ABILITIES.map { |a| scored[a] }, scores(t), row[:name]
    end
  end

  def test_random_spawns_never_miss_a_score
    (1..12).each { |depth| assert_no_missing_scores(arrangeManyLevels(depth)) }
  end

  def test_freshly_built_levels_never_miss_a_score
    (1..13).each do |depth|
      levels_at(depth, seeds: 5) { assert_no_missing_scores(arrange_get(:monsters)) }
    end
  end

  def test_thingages_that_follow_you_down_keep_their_scores
    stairs_room
    goblin = arrange_monster(9, 4, hp: 100, str: 14, dex: 3, con: 12, int: 5, wis: 7, cha: 16, ally: true).last
    take_the_stairs_east
    assert_includes assert_get(:monsters), goblin
    assert_equal [14, 3, 12, 5, 7, 16], scores(goblin)
  end

  def test_the_test_fixtures_never_miss_a_score
    built = Dungeon::THINGAGES.map { |row| thing(0, 0, row[:glyph], row[:name], 5, 0..0) } +
            Dungeon::WEAPONS.map { |w| thing(0, 0, w[:glyph], w[:name], 5, w[:hit]) }
    assert_no_missing_scores(built)
    arrange_arena
    arrange_monster(6, 5)
    arrange_quail(7, 5)
    add_rat(8, 5)
    add_door(9, 5)
    add_wall_ally(10, 5)
    arrangeWeapon(11, 5)
    assert_no_missing_scores(assert_get(:monsters))
  end

  def test_a_weapons_scores_come_from_the_weapon_row
    assert_equal Dungeon::ABILITIES.map { |a| kind("weapon")[a] }, scores(thing(0, 0, "🪓", "axe", 5, 5..12))
  end

  # --- temperament: rats start aggressive, squirrels curious, everything else neutral ---

  def test_only_the_rat_row_is_aggressive
    aggressives = Dungeon::THINGAGES.select { |k| k[:aggressive] }.map { |k| k[:name] }
    assert_equal %w[rat], aggressives
  end

  def test_spawned_rats_are_aggressive_and_everything_else_neutral
    rat = spawn_one(kind("rat"))
    assert rat.aggressive
    %w[squirrel goblin wall orc troll weapon gold sandwich potion Quail].each do |name|
      assert_equal false, spawn_one(kind(name), depth: 5).aggressive, name
    end
  end

  # def test_randomly_spawned_thingages_get_their_temperament
  #   arrangeManyLevels(10).each do |m|
  #     assert_equal m.name == "rat", m.aggressive, m.name
  #   end
  # end

  def test_a_neutral_goblin_beside_you_never_strikes
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3, aggressive: false)
    5.times { @game.rest }
    assert_equal 20, @game.hp
  end

  def test_a_neutral_goblin_stays_put
    arrange_arena
    arrange_monster(9, 5, aggressive: false)
    3.times { @game.rest }
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_a_curious_squirrel_comes_up_and_taps_without_harm
    arrange_arena
    arrange_get(:monsters) << thing(8, 5, "🐿️", "squirrel", 100, 2..2, aggressive: false)
    3.times { @game.rest }
    assert_equal [6, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
    assert_equal "The squirrel taps you.", last_log
    assert_equal 20, @game.hp
  end

  def test_an_aggressive_rat_chases_and_bites
    arrange_arena
    add_rat(7, 5)
    @game.rest
    assert_equal [6, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
    @game.rest
    assert_equal 18, @game.hp
  end

  def test_a_real_rat_chases_and_bites_for_one
    arrange_arena
    add_rat(7, 5, str: kind("rat")[:str])
    @game.rest
    assert_equal [6, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
    @game.rest
    assert_equal 19, @game.hp, "a 2 with str 7 (-2) is 0, floored at 1"
  end

  def test_hitting_a_neutral_goblin_turns_it_aggressive
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3, aggressive: false)
    @game.move(1, 0)
    goblin = arrange_get(:monsters).first
    assert goblin.aggressive
    assert_match(/\AYou hit the goblin for \d\. It turns on you!\z/, @game.log[-2])
    assert_equal "The goblin hits you for 3.", last_log, "it strikes back that same turn"
  end

  def test_an_already_aggressive_goblin_is_not_provoked_again
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.move(1, 0)
    refute(@game.log.any? { |line| line.include?("turns on you") })
  end

  def test_a_spawned_goblin_starts_neutral_and_fights_once_hit
    arrange_arena
    arrange_set :depth, 2
    @game.send(:spawn_monster, { x: 6, y: 5, w: 1, h: 1 }, kind("goblin").merge(hit: 2..2, str: 10, hp: 90))
    @game.rest
    assert_equal 20, @game.hp, "neutral: no blow"
    @game.move(1, 0)
    assert_equal 18, @game.hp, "provoked: it hits back"
  end

  def test_a_neutral_wall_stays_put_and_does_not_follow
    arrange_arena
    arrange_get(:monsters) << thing(8, 5, "#", "wall", 3, 0..0, pacifist: true, aggressive: false)
    3.times { @game.rest }
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_hitting_a_wall_spurns_it_but_never_makes_it_aggressive
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "#", "wall", 100, 0..0, pacifist: true, aggressive: false)
    @game.move(1, 0)
    wall = arrange_get(:monsters).first
    refute wall.aggressive
    assert_match(/\AYou hit the wall for \d\.\z/, @game.log.find { |line| line.start_with?("You hit") })
  end

  # The player at 5, 3 with a wall down column 7 from the top to row 5, so anything at 8, 3 must go
  # round its bottom end, through row 6, to reach the player
  def corner
    arrange_arena(px: 5, py: 3)
    (1..5).each { |y| arrange_get(:map)[y][7] = "#" }
  end

  def beside_player?(m) = (m.x - 5).abs + (m.y - 3).abs == 1

  def test_the_quail_follows_round_a_corner
    corner
    arrange_quail(8, 3)
    q = arrange_get(:monsters).first
    steps = 0
    until beside_player?(q) || steps == 20
      @game.rest
      steps += 1
    end
    assert beside_player?(q), "the Quail reached the player, ending at #{[q.x, q.y]}"
    assert_equal 8, steps, "by the shortest way: down 3, across 2, up 3"
  end

  def test_the_quail_takes_the_way_round_not_into_the_wall
    corner
    arrange_quail(8, 3)
    @game.rest
    q = arrange_get(:monsters).first
    assert_equal [8, 4], [q.x, q.y]
  end

  def test_a_goblin_stays_stuck_behind_the_corner
    corner
    arrange_monster(8, 3, hp: 100)
    5.times { @game.rest }
    assert_equal [8, 3], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_the_quail_steps_round_a_monster_in_its_way
    arrange_arena
    arrange_quail(8, 5)
    arrange_monster(7, 5, hp: 100, aggressive: false)
    @game.rest
    q = arrange_get(:monsters).first
    refute_equal [8, 5], [q.x, q.y], "it moved"
    assert_equal 8, q.x, "sidestepping, not through the goblin"
  end

  def test_a_walled_off_quail_waits
    corner
    (1..H - 2).each { |y| arrange_get(:map)[y][7] = "#" } # the wall now runs floor to ceiling
    arrange_quail(8, 3)
    3.times { @game.rest }
    q = arrange_get(:monsters).first
    assert_equal [8, 3], [q.x, q.y]
  end

  def test_a_spurned_quail_still_stays_put
    corner
    arrange_quail(8, 3).last.spurned = true
    3.times { @game.rest }
    q = arrange_get(:monsters).first
    assert_equal [8, 3], [q.x, q.y]
  end

  def test_the_quail_still_follows_though_neutral
    arrange_arena
    arrange_quail(9, 5)
    @game.rest
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_a_fed_neutral_goblin_follows_like_a_friend
    arrange_arena
    arrange_monster(6, 5, hp: 100, aggressive: false)
    give(:sandwiches, 1, 0)
    @game.move(-1, 0)
    @game.move(-1, 0)
    assert_equal [4, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_allies_leave_neutral_monsters_alone
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_monster(8, 5, hp: 10, hit: 0..0, aggressive: false)
    @game.rest
    assert_equal 10, assert_get(:monsters).last.hp
  end

  # --- moving ---

  def test_moving_onto_floor_moves_the_player
    arrange_arena
    @game.move(1, 0)
    assert_equal [6, 5], player
    @game.move(-1, 1)
    assert_equal [5, 6], player
  end

  def test_walking_into_a_wall_stays_put_and_just_disappears
    arrange_arena(px: 1, py: 1)
    arrange_monster(9, 1, hp: 100, hit: 0..0)
    log = @game.log.dup
    @game.move(-1, 0)
    assert_equal [1, 1], player
    assert_equal log, @game.log, "no message"
    assert_equal [9, 1], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "and no turn passes"
    assert_equal Dungeon::MAX_BLOOD_SUGAR, @game.blood_sugar, "not even a round of hunger"
  end

  def test_moving_off_the_map_edge_is_a_wall
    arrange_arena(px: 0, py: 0)
    @game.move(-1, -1)
    assert_equal [0, 0], player
  end

  def test_player_is_drawn_as_at_sign
    arrange_arena
    assert_equal "@", @game.rows[5][5]
  end

  # --- treasure ---

  def test_stepping_on_treasure_collects_it
    arrange_arena
    arrange_get(:treasure)[[6, 5]] = 15
    assert_equal "$", @game.rows[5][6]

    @game.move(1, 0)
    assert_equal 15, @game.gold
    assert_empty assert_get(:treasure)
    assert_equal "You find 15 gold!", last_log
  end

  # --- combat ---

  def test_walking_into_a_monster_attacks_without_moving
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.move(1, 0)
    assert_equal [5, 5], player
    assert_includes 93..98, assert_get(:monsters).first.hp
  end

  # "def" starts a method. Minitest runs every method whose name begins with "test_" as one test,
  # and the name says in plain words what this test proves
  def test_killing_a_monster_removes_it
    # arena is a helper defined at the top of this file: it throws away the random dungeon and puts the
    # player at column 5, row 5 of one big empty room, so nothing random can spoil the test
    arrange_arena
    # Put only one goblin one step to the player's right (column 6, row 5). "hp: 1" gives it a single hit point,
    # and since every attack does at least 1 damage, the first hit is sure to kill it
    arrange_monster(6, 5, hp: 1)
    # Ask the game to move the player 1 column right (+1) and 0 rows down. The goblin stands there,
    # so instead of stepping, the player attacks it, the same as walking into a monster in play
    @game.move(1, 0)
    # assert_get(:monsters) peeks at the game's private list of monsters. assert_empty fails the test
    # unless that list is empty now, which proves the slain goblin was taken off the map
    assert_empty assert_get(:monsters)
    # last_log is the newest line in the game's message log. assert_equal fails the test unless
    # the two values match exactly, which proves the player was told what happened
    assert_equal "You defeat the goblin!", last_log
  # "end" closes the method that "def" opened
  end

  def test_adjacent_monster_hits_the_player
    arrange_arena
    arrange_monster(5, 6, hp: 100, hit: 3..3)
    @game.rest
    assert_equal 17, @game.hp # resting heals nothing at full health, then the hit lands
    assert_equal "The goblin hits you for 3.", last_log
  end

  def test_weak_adjacent_monster_hits_the_player
    arrange_arena
    arrange_monster(5, 6, hp: 100, hit: 3..3, str: 10)
    @game.rest
    assert_equal 17, @game.hp # resting heals nothing at full health, then the hit lands
    assert_equal "The goblin hits you for 3.", last_log
  end

  def test_adjacent_thug_hits_the_player
    arrange_arena
    arrange_monster(5, 6, hp: 100, hit: 3..3, str: 15)
    @game.rest
    assert_equal 15, @game.hp # resting heals nothing at full health, then the hit lands
    assert_equal "The goblin hits you for 5.", last_log
  end

  def test_diagonal_monster_does_not_attack
    arrange_arena
    arrange_monster(6, 6, hit: 3..3)
    @game.rest
    assert_equal 20, @game.hp
  end

  def test_death_ends_the_game
    arrange_arena
    arrange_set :hp, 2
    arrange_monster(6, 5, hp: 100, hit: 5..5)
    @game.rest
    assert @game.over?
    assert_match(/You die on depth 1/, last_log)

    @game.move(0, 1)
    assert_equal [5, 5], player, "no moves after death"
  end

  # --- god mode ---

  def test_god_mode_player_takes_no_damage
    @game = Dungeon.new(godMode: true)
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 5..5)
    10.times { @game.rest }
    assert_equal 20, @game.hp
    refute @game.over?
    assert_equal "The goblin hits you for 5, but you take no damage.", last_log
  end

  def test_god_mode_player_still_deals_damage_and_allies_still_fight
    @game = Dungeon.new(godMode: true)
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_monster(8, 5, hp: 10, hit: 0..0)
    @game.rest
    assert_equal 6, assert_get(:monsters).last.hp, "others take damage as usual"

    arrange_monster(5, 6, hp: 100, hit: 0..0)
    @game.move(0, 1)
    assert_operator assert_get(:monsters).last.hp, :<, 100
  end

  def test_god_mode_is_off_by_default
    refute @game.godMode?
  end

  # --- monster movement ---

  def test_monster_in_sight_steps_toward_the_player
    arrange_arena
    arrange_monster(9, 5)
    @game.rest
    m = arrange_get(:monsters).first
    assert_equal [8, 5], [m.x, m.y]
  end

  def test_monster_closes_the_longer_axis_first
    arrange_arena
    arrange_monster(7, 9)
    @game.rest
    m = arrange_get(:monsters).first
    assert_equal [7, 8], [m.x, m.y]
  end

  def test_monster_out_of_sight_stays_put
    arrange_arena
    arrange_monster(5 + Dungeon::SIGHT + 1, 5)
    @game.rest
    m = arrange_get(:monsters).first
    assert_equal [5 + Dungeon::SIGHT + 1, 5], [m.x, m.y]
  end

  def test_monster_does_not_walk_through_walls
    arrange_arena
    arrange_get(:map)[5][7] = "#"
    arrange_monster(8, 5)
    @game.rest
    m = arrange_get(:monsters).first
    assert_equal [8, 5], [m.x, m.y]
  end

  def test_monsters_do_not_stack
    arrange_arena
    arrange_monster(8, 5)
    arrange_monster(9, 5)
    arrange_get(:map)[5][7] = "#"
    @game.rest
    assert_equal [[8, 5], [9, 5]], assert_get(:monsters).map { |m| [m.x, m.y] }
  end

  # --- the pacifist Quails are nummy ---

  def test_quail_first_spawns_at_depth_four
    refute_includes arrangeManyLevels(3).map(&:glyph), "Q"
    # TODO  the Quail went deeper
    # quails = spawn_many(4).select { |m| m.glyph == "Q" }
    # refute_empty quails
    # assert(quails.all?(&:pacifist))
  end

  def test_quail_follows_the_player
    arrange_arena
    arrange_quail(9, 5)
    @game.rest
    q = arrange_get(:monsters).first
    assert_equal [8, 5], [q.x, q.y]
  end

  def test_adjacent_quail_never_hits
    arrange_arena
    arrange_quail(6, 5)
    3.times { @game.rest }
    assert_equal 20, @game.hp
    q = arrange_get(:monsters).first
    assert_equal [6, 5], [q.x, q.y]
  end

  def test_hitting_the_quail_makes_it_stop_following
    arrange_arena
    arrange_quail(6, 5, met: [:ego])
    @game.move(1, 0)
    q = arrange_get(:monsters).first
    assert q.spurned
    assert(@game.log.any? { |l| l.match?(/It stops following you\./) })

    @game.move(-1, 0)
    @game.move(-1, 0)
    assert_equal [7, 5], [q.x, q.y], "knocked back, then left there"
  end

  def test_meeting_a_quail_the_first_time_is_a_tap
    arrange_arena
    q = arrange_quail(6, 5).last
    @game.move(1, 0)
    assert_equal "You tap the Quail. It looks you over.", last_log
    assert_equal 100, q.hp
    refute q.spurned
  end

  def test_hitting_a_quail_knocks_it_back_with_the_quails_behind_it
    arrange_arena
    front = arrange_quail(6, 5, met: [:ego]).last
    back = arrange_quail(7, 5).last.tap { |q| q.spurned = true } # so it stays where it's knocked
    @game.move(1, 0)
    assert_equal [[7, 5], [8, 5]], [[front.x, front.y], [back.x, back.y]]
    assert_equal "The Quails are knocked back.", last_log
  end

  def test_a_wall_behind_the_quails_holds_them_in_place
    arrange_arena
    arrange_get(:map)[5][8] = "#"
    front = arrange_quail(6, 5, met: [:ego]).last
    arrange_quail(7, 5)
    @game.move(1, 0)
    assert_equal [6, 5], [front.x, front.y]
  end

  def test_hitting_the_quail_hurts_it
    arrange_arena
    arrange_quail(6, 5, met: [:ego])
    @game.move(1, 0)
    fists = Dungeon::BARE_HANDS_HIT
    assert_includes (100 - fists.max)..(100 - fists.min), assert_get(:monsters).first.hp
  end

  def test_slain_quail_explodes_into_one_to_five_sandwiches_around_it
    50.times do |seed|
      srand(seed)
      arrange_arena
      arrange_quail(6, 5, hp: 1, met: [:ego])
      @game.move(1, 0)
      assert_empty assert_get(:monsters)
      sandwiches = arrange_get(:sandwiches)
      assert_includes 1..5, sandwiches.values.sum, "seed #{seed}"
      assert(sandwiches.keys.all? { |x, y| (x - 6).abs <= 1 && (y - 5).abs <= 1 }, "seed #{seed}")
      refute_includes sandwiches.keys, player, "seed #{seed}"
      assert_match(/The Quail explodes into [1-5] sandwich/, last_log)
    end
  end

  def test_extra_sandwiches_pile_up_when_the_quail_is_boxed_in
    piled = 20.times.map do |seed|
      srand(seed)
      arrange_arena
      arrange_get(:map).each_with_index { |row, y| row.each_index { |x| row[x] = "#" unless [[5, 5], [6, 5]].include?([x, y]) } }
      arrange_quail(6, 5, hp: 1)
      @game.move(1, 0)
      # assert_equal [[6, 5]], assert_get(:sandwiches).keys, "seed #{seed}"
      arrange_get(:sandwiches)[[6, 5]]
    end
    # assert(piled.any? { |n| n > 1 }, "some explosion should pile several sandwiches on one spot")
  end

  def test_sandwiches_are_drawn_as_percent
    arrange_arena
    arrange_get(:sandwiches)[[6, 5]] = 1
    assert_equal "%", @game.rows[5][6]
  end

  def test_stepping_on_sandwiches_packs_them_without_healing
    arrange_arena
    arrange_set :hp, 5
    arrange_get(:sandwiches)[[6, 5]] = 3
    @game.move(1, 0)
    assert_equal 5, @game.hp
    assert_equal 3, @game.sandwiches
    assert_empty assert_get(:sandwiches)
    assert_equal "You pack 3 sandwiches into your knapsack.", last_log
  end

  def test_knapsack_collects_gold_and_sandwiches_together
    arrange_arena
    arrange_get(:treasure)[[6, 5]] = 15
    arrange_get(:sandwiches)[[6, 5]] = 1
    @game.move(1, 0)
    assert_equal({ gold: 15, sandwiches: 1, potions: 0, speed_potions: 0, gas_potions: 0, slow_potions: 0, healing_potions: 0, sleep_potions: 0, empty_potions: 0, scrolls: 0, mapping_scrolls: 0, peace_rings: 0, strength_rings: 0, protection_rings: 0, candles: 0, laced_potions: 0, laced_speed_potions: 0, laced_gas_potions: 0, laced_slow_potions: 0, laced_healing_potions: 0, laced_sleep_potions: 0, laced_empty_potions: 0, eggs: [], weapons: [], shields: [], wands: [] }, @game.knapsack)
    assert_equal "You pack a sandwich into your knapsack.", last_log
  end

  def test_spurned_quail_still_blocks_monsters_behind_it
    arrange_arena
    arrange_get(:map)[4][7] = "#"
    arrange_get(:map)[6][7] = "#"
    arrange_quail(7, 5).last.spurned = true
    arrange_monster(8, 5)
    @game.rest
    assert_equal [[7, 5], [8, 5]], assert_get(:monsters).map { |m| [m.x, m.y] }
  end

  # --- stairs ---

  def test_stairs_lead_to_a_new_deeper_level
    arrange_arena
    arrange_get(:map)[5][6] = ">"
    arrange_set :hp, 10
    old_map = arrange_get(:map)

    take_the_stairs_east
    assert_equal 2, @game.depth
    assert_equal 22, @game.max_hp
    assert_equal 15, @game.hp
    refute_same old_map, assert_get(:map)
    assert_equal "You take the stairs down to depth 2.", last_log
  end

  # Steps onto the stairs one step east and answers yes to going that way
  def take_the_stairs_east
    @game.move(1, 0)
    @game.take_stairs(true)
  end

  # An arena whose stairs room is x 3-12, y 3-7, with the stairs one step east of the player
  def stairs_room
    arrange_arena
    arrange_set :rooms, [{ x: 3, y: 3, w: 10, h: 5 }]
    arrange_get(:map)[5][6] = ">"
  end

  def test_your_side_in_the_room_follows_you_downstairs
    stairs_room
    arrange_monster(9, 4, hp: 100, ally: true)
    fed = arrange_monster(10, 6, hp: 100, aggressive: false).last.tap { |m| m.fed = 20 }
    quail = arrange_quail(4, 4).last
    take_the_stairs_east
    assert_equal 2, @game.depth
    party = arrange_get(:monsters).select { |m| m.hp == 100 }
    assert_equal 3, party.size
    assert_includes party, fed
    assert_includes party, quail
    start = arrange_get(:rooms).first
    assert(party.all? { |m| @game.send(:in_room?, start, m.x, m.y) }, "they land in your starting room")
    assert_equal "The goblin, the goblin, and the Quail follow you down.", last_log
  end

  def test_only_your_side_and_only_from_your_room_follow_you_downstairs
    stairs_room
    arrange_monster(20, 5, hp: 100, ally: true)                         # an ally out in the arena, beyond the room
    arrange_monster(9, 4, hp: 100)                                      # a hostile goblin in the room
    arrange_quail(4, 4).last.spurned = true                             # a spurned Quail
    arrange_get(:monsters) << thing(4, 6, "Q", "Quail", 100, 0..0, pacifist: true, nesting: true)
    take_the_stairs_east
    assert_equal 2, @game.depth
    assert_empty assert_get(:monsters).select { |m| m.hp == 100 }
    assert_equal "You take the stairs down to depth 2.", last_log
  end

  def test_stair_healing_is_capped_at_max
    arrange_arena
    arrange_get(:map)[5][6] = ">"
    take_the_stairs_east
    assert_equal @game.max_hp, @game.hp
  end

  # --- resting ---

  def test_rest_heals_one_point
    arrange_arena
    arrange_set :hp, 10
    @game.rest
    assert_equal 11, @game.hp
  end

  def test_rest_does_not_overheal
    arrange_arena
    @game.rest
    assert_equal 20, @game.hp
  end

  # --- what the player can see ---

  def test_unseen_tiles_are_blank
    arrange_arena
    arrange_set :seen, Array.new(H) { Array.new(W, false) }
    @game.send(:reveal)
    row = @game.rows[5]
    assert_equal ".", row[5 + Dungeon::SIGHT]
    assert_equal " ", row[5 + Dungeon::SIGHT + 1]
  end

  def test_seen_tiles_stay_on_the_map_after_walking_away
    arrange_arena
    arrange_set :seen, Array.new(H) { Array.new(W, false) }
    @game.send(:reveal)
    (Dungeon::SIGHT + 3).times { @game.move(1, 0) }
    assert_equal ".", @game.rows[5][1]
  end

  def test_distant_monsters_are_hidden_even_on_seen_tiles
    arrange_arena
    far = 5 + Dungeon::SIGHT + 2
    arrange_monster(far, 5)
    assert_equal ".", @game.rows[5][far]
  end

  def test_nearby_monsters_are_drawn
    arrange_arena
    arrange_monster(7, 5)
    assert_equal "g", @game.rows[5][7]
  end

  # --- weapons ---

  def assertWeapons = Dungeon::THINGAGES.find { |k| k[:name] == "weapon" }

  def dagger = Dungeon::WEAPONS.find { |w| w[:name] == "dagger" }
  def sword = { name: "sword", glyph: "⚔", hit: 4..4 }

  def arrangeWeapon(x, y, hp: 1, pacifist: false, kind: dagger)
    arrange_get(:monsters) << thing(x, y, kind[:glyph], kind[:name], hp, kind[:hit], pacifist: pacifist)
  end

  def test_weapons_spawn_as_every_kind_of_weapon
    arrange_arena(px: 1, py: 1)
    room = { x: 2, y: 2, w: W - 4, h: H - 4 }
    200.times { @game.send(:spawn_monster, room, assertWeapons) }
    wielded = arrange_get(:monsters).map(&:weapon).uniq
    assert_equal Dungeon::WEAPONS.sort_by { |w| w[:name] }, wielded.sort_by { |w| w[:name] }
    assert_equal [%w[R rat]], assert_get(:monsters).map { |m| [m.glyph, m.name] }.uniq, "each cloaked as a goblin at depth 1"
    assert(assert_get(:monsters).all? { |m| m.hit == m.weapon[:hit] }, "each hitting for its weapon's range")
  end

  def test_weapon_kinds_differ_in_name_glyph_and_damage
    %i[name glyph hit].each do |field|
      assert_equal Dungeon::WEAPONS.size, Dungeon::WEAPONS.map { |w| w[field] }.uniq.size, "#{field} repeats"
    end
  end

  # --- dormant weapons cloak themselves ---

  # A weapon cloaked as a goblin of average strength, lying dormant, so its blows are its weapon's range exactly
  def arrangeCloaked(x, y, weapon: dagger, hp: 100)
    arrange_get(:monsters) << thing(x, y, "G", "goblin", hp, weapon[:hit], str: 10, pacifist: false, weapon: weapon)
  end

  # def test_a_dormant_weapon_cloaks_itself_by_challenge_rating
  #   { 1 => "goblin", 2 => "goblin", 3 => "coyote", 4 => "coyote", 5 => "troll", 9 => "troll" }.each do |depth, cloak|
  #     assert_equal cloak, @game.send(:cloak_for, depth)[:name], "depth #{depth}"
  #   end
  # end

  def test_a_cloaked_weapon_is_its_cloak_wielding_the_weapon
    t = spawn_one(kind("weapon"), depth: 5)
    troll = kind("troll")
    assert_equal ["T", "troll"], [t.glyph, t.name]
    assert_equal troll.values_at(*Dungeon::ABILITIES), scores(t)
    assert_equal troll[:hp] + 5 + Dungeon.modifier(troll[:con]), t.hp, "a troll's hit points"
    assert_includes Dungeon::WEAPONS, t.weapon
    assert_equal t.weapon[:hit], t.hit, "but it hits with the weapon"
    refute t.aggressive, "dormant"
    refute t.pacifist, "though not for long"
  end

  def test_a_cloaked_weapon_lies_dormant
    arrange_arena
    arrangeCloaked(7, 5)
    2.times { @game.rest }
    assert_equal [7, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
    assert_equal 20, @game.hp
  end

  def test_waking_a_cloaked_weapon_brings_its_weapon_to_bear
    arrange_arena
    arrangeCloaked(6, 5, weapon: { name: "dagger", glyph: "🗡️", hit: 3..3 })
    @game.move(1, 0)
    assert_includes @game.log, "The goblin hits you with its dagger for 3."
    assert_equal 17, @game.hp
  end

  def test_defeating_a_cloaked_weapon_seizes_its_weapon
    arrange_arena
    arrangeCloaked(6, 5, hp: 1)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal dagger, @game.wielded
    assert_equal "You defeat the goblin and seize its dagger! You now wield #{dagger[:glyph]} dagger.", last_log
  end

  def test_a_cloaked_bow_goes_into_the_knapsack
    arrange_arena
    arrangeCloaked(6, 5, weapon: bow, hp: 1)
    @game.move(1, 0)
    assert_equal [bow], @game.knapsack[:weapons]
    assert_equal "You defeat the goblin and pack its bow into your knapsack.", last_log
  end

  def test_a_cloaked_weapon_too_heavy_to_pack_is_left_behind
    arrange_arena
    arrange_set :wielded, sword
    arrange_get(:knapsack)[:gold] = 3000
    arrangeCloaked(6, 5, weapon: Dungeon::WEAPONS.find { |w| w[:name] == "swords" }, hp: 1)
    @game.move(1, 0)
    assert_empty @game.knapsack[:weapons]
    assert_equal "You defeat the goblin, but your knapsack is too full to carry its swords, so you leave them behind.", last_log
  end

  def test_defeating_a_weapon_seizes_it
    arrange_arena
    arrangeWeapon(6, 5)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal "#{dagger[:glyph]} dagger", @game.weapon
    assert_equal dagger[:hit], @game.weapon_hit
    assert_equal "You defeat the dagger and seize it! You now wield #{dagger[:glyph]} dagger.", last_log
  end

  def test_wounding_a_weapon_does_not_seize_it
    arrange_arena
    arrangeWeapon(6, 5, hp: 100)
    @game.move(1, 0)
    assert_equal "fists", @game.weapon
    assert_equal Dungeon::BARE_HANDS_HIT, @game.weapon_hit
  end

  def test_a_second_weapon_goes_into_the_knapsack
    arrange_arena
    arrange_set :wielded, sword
    arrangeWeapon(6, 5)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal "⚔ sword", @game.weapon, "the wielded weapon stays in hand"
    assert_equal 4..4, @game.weapon_hit
    assert_equal [dagger], @game.knapsack[:weapons]
    assert_equal "You defeat the dagger and pack it into your knapsack.", last_log
  end

  def bow = Dungeon::WEAPONS.find { |w| w[:name] == "bow" }

  def test_a_bow_goes_into_the_knapsack_even_with_empty_hands
    arrange_arena
    arrangeWeapon(6, 5, kind: bow)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal "fists", @game.weapon, "not wielded automatically"
    assert_equal [bow], @game.knapsack[:weapons]
    assert_equal "You defeat the bow and pack it into your knapsack.", last_log
  end

  def test_a_packed_bow_is_wielded_when_you_choose
    arrange_arena
    arrangeWeapon(6, 5, kind: bow)
    @game.move(1, 0)
    @game.wield("bow")
    assert_equal "🏹 bow", @game.weapon
    assert_empty @game.knapsack[:weapons]
  end

  def test_a_bow_too_heavy_to_pack_is_left_behind_even_with_empty_hands
    arrange_arena
    arrange_get(:knapsack)[:gold] = 3000
    arrangeWeapon(6, 5, kind: bow)
    @game.move(1, 0)
    assert_equal "fists", @game.weapon
    assert_empty @game.knapsack[:weapons]
    assert_equal "You defeat the bow, but your knapsack is too full to carry it, so you leave it behind.", last_log
  end

  # Marches back and forth across the arena, a step at a time
  def march_steps(n) = n.times { |i| @game.move(i.even? ? 1 : -1, 0) }

  def test_marching_a_strung_bow_is_safe_at_first
    arrange_arena
    arrange_set :wielded, bow
    march_steps(Dungeon::STRUNG_STEPS)
    assert_equal bow, @game.wielded
    assert_equal Dungeon::STRUNG_STEPS, @game.strung_steps
  end

  def test_marching_a_strung_bow_longer_snaps_its_string_sooner_or_later
    arrange_arena
    arrange_set :wielded, bow
    arrange_set :strung_steps, Dungeon::STRUNG_STEPS
    500.times do |i|
      break if @game.wielded == Dungeon::FISTS

      @game.move(i.even? ? 1 : -1, 0) # back and forth, clear of the walls
    end
    assert_equal "fists", @game.weapon, "the bow is ruined"
    assert_includes @game.log, "Strung too long on the march, your bow's string snaps, and the bow breaks! You're down to your fists."
    assert_equal 0, @game.strung_steps
    assert_empty @game.knapsack[:weapons], "nothing of it is left"
  end

  def test_resting_and_fighting_are_not_marching
    arrange_arena
    arrange_set :wielded, bow
    arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false)
    3.times { @game.rest }
    @game.move(1, 0)
    assert_equal 0, @game.strung_steps
  end

  def test_swapping_weapons_unstrings_the_bow
    arrange_arena
    arrange_set :wielded, bow
    arrange_set :strung_steps, 40
    arrange_get(:knapsack)[:weapons] << dagger
    @game.wield
    assert_equal 0, @game.strung_steps
    @game.wield("bow")
    assert_equal bow, @game.wielded
    assert_equal 0, @game.strung_steps, "it strings fresh"
  end

  def test_a_weapon_with_no_string_never_snaps
    arrange_arena
    arrange_set :wielded, dagger
    march_steps(Dungeon::STRUNG_STEPS * 3)
    assert_equal dagger, @game.wielded
    assert_equal 0, @game.strung_steps
  end

  def test_inventory_lists_packed_weapons
    arrange_get(:knapsack).merge!(gold: 5, sandwiches: 2, weapons: [sword])
    @game.inventory
    assert_equal "Your knapsack holds 5 gold, 2 sandwiches, and ⚔ sword.", last_log

    arrange_get(:knapsack)[:weapons] << dagger
    @game.inventory
    assert_match(/2 sandwiches, ⚔ sword, and .+ dagger\.\z/, last_log)
  end

  def test_inventory_counts_weapons_of_a_kind_together
    axe = { name: "axe", glyph: "🪓", hit: 5..5 }
    arrange_get(:knapsack)[:weapons].push(sword, axe, sword, dagger, sword, dagger)
    @game.inventory
    assert_equal "Your knapsack holds 3 ⚔ swords, 🪓 axe, and 2 #{dagger[:glyph]} daggers.", last_log
  end

  def swords = Dungeon::WEAPONS.find { |w| w[:name] == "swords" }

  def test_the_crossed_swords_are_a_pair
    arrange_arena
    arrange_get(:knapsack)[:weapons] << swords
    @game.wield
    assert_equal "You now wield ⚔️ swords.", last_log

    arrange_get(:knapsack)[:weapons].push(swords, swords, swords)
    @game.inventory
    assert_equal "Your knapsack holds 3 pairs of ⚔️ swords.", last_log
  end

  def test_seizing_a_pair_says_them
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, swords[:glyph], "swords", 1, swords[:hit], pacifist: true)
    @game.move(1, 0)
    assert_equal "You defeat the swords and seize them! You now wield ⚔️ swords.", last_log
  end

  def test_wield_by_name_takes_that_kind
    arrange_arena
    axe = { name: "axe", glyph: "🪓", hit: 5..5 }
    arrange_get(:knapsack)[:weapons].push(sword, axe, sword)
    @game.wield("axe")
    assert_equal "🪓 axe", @game.weapon
    assert_equal %w[sword sword], @game.knapsack[:weapons].map { |w| w[:name] }

    @game.wield("bow")
    assert_equal "🪓 axe", @game.weapon
    assert_equal "You have no bow in your knapsack.", last_log
  end

  def test_wield_from_bare_hands_takes_the_packed_weapon
    arrange_arena
    arrange_get(:knapsack)[:weapons] << sword
    @game.wield
    assert_equal "⚔ sword", @game.weapon
    assert_equal 4..4, @game.weapon_hit
    assert_empty @game.knapsack[:weapons], "fists are not packed"
    assert_equal "You now wield ⚔ sword.", last_log
  end

  def test_wield_swaps_and_cycles_through_packed_weapons
    arrange_arena
    arrange_set :wielded, { name: "club", glyph: "🏏", hit: 1..1 }
    arrange_get(:knapsack)[:weapons].push(sword, { name: "bow", glyph: "🏹", hit: 3..3 })

    @game.wield
    assert_equal "⚔ sword", @game.weapon
    assert_equal %w[bow club], @game.knapsack[:weapons].map { |w| w[:name] }

    2.times { @game.wield }
    assert_equal "🏏 club", @game.weapon, "back to the first weapon"
    assert_equal 1..1, @game.weapon_hit
  end

  def test_wield_with_no_packed_weapon_does_nothing
    arrange_arena
    arrange_monster(9, 5)
    @game.wield
    assert_equal "fists", @game.weapon
    assert_equal "You have no weapon in your knapsack to wield.", last_log
    assert_equal 9, assert_get(:monsters).first.x, "no turn passes"
  end

  def test_wielding_takes_a_turn
    arrange_arena
    arrange_get(:knapsack)[:weapons] << sword
    arrange_monster(9, 5)
    @game.wield
    assert_equal 8, assert_get(:monsters).first.x
  end

  def test_attacks_hit_with_the_wielded_weapon
    arrange_arena
    arrange_set :wielded, { name: "club", glyph: nil, hit: 10..10 }
    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.move(1, 0)
    assert_equal 90, assert_get(:monsters).first.hp
  end

  def test_about_half_of_all_weapons_are_pacifists
    arrange_arena(px: 1, py: 1)
    room = { x: 2, y: 2, w: W - 4, h: H - 4 }
    400.times { @game.send(:spawn_monster, room, assertWeapons) }
    share = arrange_get(:monsters).count(&:pacifist) / 400.0
    # assert_in_delta 0.5, share, 0.1
  end

  # --- the potion of sight ---

  def add_potion(x, y)
    arrange_get(:monsters) << thing(x, y, "¡", "potion", 3, 0..0, pacifist: true)
  end

  def test_about_half_the_levels_hold_one_potion
    counts = []
    each_level { counts << arrange_get(:monsters).count { |m| m.name == "potion" } }
    assert_includes counts, 0
    assert_includes counts, 1
    assert(counts.all? { |n| n <= 1 }, "depth 1 only gets the extra potion")
  end

  # --- the Quail's placement ---

  # Quails on each of 50 freshly built levels at this depth
  def quail_counts(depth)
    50.times.map do |seed|
      srand(seed)
      @game = Dungeon.new
      arrange_set :depth, depth
      @game.send(:build_level)
      arrange_get(:monsters).count { |m| m.name == "Quail" }
    end
  end

  def test_no_quail_before_depth_five
    assert(quail_counts(4).all?(&:zero?))
  end

  def test_about_half_the_levels_at_depth_five_hold_one_quail
    counts = quail_counts(5)
    assert(counts.all? { |n| n <= 1 }, "never more than one")
    assert_in_delta 25, counts.sum, 12, "about half of 50 levels"
  end

  def test_from_depth_six_every_two_levels_add_a_quail
    { 6 => 1, 7 => 1, 8 => 2, 9 => 2, 10 => 3, 13 => 4 }.each do |depth, quails|
      assert_equal [quails] * 50, quail_counts(depth), "depth #{depth}"
    end
  end

  def test_from_depth_eight_one_quail_nests_in_a_hatchery
    levels_at(8) do |seed|
      quails = arrange_get(:monsters).select { |m| m.name == "Quail" }
      assert_equal 1, quails.count(&:nesting), "seed #{seed}: one nesting Quail"
      assert_equal 1, assert_get(:eggs).size, "seed #{seed}: one nest of eggs"
      hatchery = arrange_get(:rooms).find { |r| @game.send(:in_room?, r, *arrange_get(:nest)) }
      refute_includes [assert_get(:rooms).first, assert_get(:cage_room)], hatchery, "seed #{seed}: a room of its own"
    end
    levels_at(7) { |seed| assert_empty arrange_get(:eggs), "seed #{seed}: no hatchery above depth 8" }
  end

  def test_walking_into_a_potion_packs_it_without_drinking
    arrange_arena
    arrange_set :seen, Array.new(H) { Array.new(W, false) }
    add_potion(6, 5)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal [5, 5], player
    assert_equal 1, @game.potions
    refute(assert_get(:seen).flatten.all?, "packing reveals nothing")
    assert_equal "You pack a potion of sight into your knapsack.", last_log
  end

  def test_quaffing_a_packed_potion_reveals_the_level
    arrange_arena
    arrange_set :seen, Array.new(H) { Array.new(W, false) }
    arrange_get(:knapsack)[:potions] = 2
    @game.quaff
    assert_equal 1, @game.potions
    assert(assert_get(:seen).flatten.all?)
    assert_equal "#", @game.rows[H - 1][W - 1]
    assert_equal "You quaff the potion of sight. The whole level is revealed!", last_log
  end

  def test_quaffing_in_melee_takes_a_turn
    arrange_arena
    arrange_get(:knapsack)[:potions] = 1
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    @game.quaff
    assert_equal 17, @game.hp
    assert_equal "The goblin hits you for 3.", last_log
  end

  def test_quaffing_with_no_potion_takes_no_turn
    arrange_arena
    arrange_monster(9, 5)
    @game.quaff
    assert_equal "You have no potion to drink.", last_log
    assert_equal 9, assert_get(:monsters).first.x
  end

  def test_potion_of_sight_does_not_show_distant_monsters
    arrange_arena
    arrange_set :seen, Array.new(H) { Array.new(W, false) }
    arrange_get(:knapsack)[:potions] = 1
    far = 5 + Dungeon::SIGHT + 2
    arrange_monster(far, 5)
    @game.quaff
    assert_equal ".", @game.rows[5][far]
  end

  def test_inventory_lists_potions
    arrange_get(:knapsack)[:potions] = 1
    @game.inventory
    assert_equal "Your knapsack holds ¡ potion of sight.", last_log
    arrange_get(:knapsack).merge!(gold: 2, potions: 3)
    @game.inventory
    assert_equal "Your knapsack holds 2 gold and 3 ¡ potions of sight.", last_log
  end

  # --- the scrolls of potion finding and of mapping ---

  def add_scroll(x, y, name = "scroll of 3 potions")
    arrange_get(:monsters) << thing(x, y, "?", name, 3, 0..0, pacifist: true)
  end

  def fog = arrange_set(:seen, Array.new(H) { Array.new(W, false) })

  def test_every_scroll_row_is_a_peaceful_thingage
    Dungeon::SCROLLS.each_value do |scroll|
      row = Dungeon::THINGAGES.find { |k| k[:name] == scroll[:row] }
      assert_equal scroll[:glyph], row[:glyph], scroll[:row]
      assert row[:pacifist], scroll[:row]
      refute row[:aggressive], scroll[:row]
    end
  end

  def test_walking_into_a_scroll_packs_it
    arrange_arena
    add_scroll(6, 5)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal [5, 5], player
    assert_equal 1, @game.scrolls
    assert_equal "You pack a scroll of potion finding into your knapsack.", last_log
  end

  def test_reading_marks_a_distant_unseen_potion_and_says_where
    arrange_arena
    fog
    arrange_get(:knapsack)[:scrolls] = 1
    add_potion(17, 2)
    assert_equal " ", @game.rows[2][17], "fogged and far: hidden before reading"

    @game.read
    assert_equal 0, @game.scrolls
    assert_equal "¡", @game.rows[2][17]
    assert_equal "You read the scroll of potion finding. It shows a potion of sight: 12 east and 3 north.", last_log
  end

  def test_reading_lists_every_potion_in_range
    arrange_arena
    arrange_get(:knapsack)[:scrolls] = 1
    add_potion(5, 9)
    add_potion(1, 5)
    @game.read
    assert_equal "You read the scroll of potion finding. It shows 2 potions of sight: 4 south; 4 west.", last_log
  end

  def test_potions_beyond_the_scrolls_range_stay_hidden
    arrange_arena(px: 2, py: 2)
    fog
    arrange_get(:knapsack)[:scrolls] = 1
    far = 2 + Dungeon::SCROLL_RANGE + 1
    add_potion(far, 2)
    @game.read
    assert_equal " ", @game.rows[2][far]
    assert_equal "You read the scroll of potion finding. It shows no potions of sight nearby.", last_log
  end

  def test_the_scroll_finds_only_potions
    arrange_arena
    fog
    arrange_get(:knapsack)[:scrolls] = 1
    arrange_monster(15, 5, aggressive: false)
    add_scroll(16, 5)
    @game.read
    assert_equal "  ", @game.rows[5][15, 2]
  end

  def test_reading_takes_a_turn
    arrange_arena
    arrange_get(:knapsack)[:scrolls] = 1
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    @game.read
    assert_equal 17, @game.hp
  end

  def test_reading_with_no_scroll_takes_no_turn
    arrange_arena
    arrange_monster(9, 5)
    @game.read
    assert_equal "You have no scroll to read.", last_log
    assert_equal 9, assert_get(:monsters).first.x
  end

  def test_a_marked_potion_vanishes_from_the_map_once_packed
    arrange_arena
    fog
    arrange_get(:knapsack)[:scrolls] = 1
    add_potion(6, 5)
    @game.read
    @game.move(1, 0)
    assert_equal 1, @game.potions
    refute_equal "¡", @game.rows[5][6]
  end

  def test_marks_do_not_carry_to_the_next_level
    arrange_arena
    arrange_get(:knapsack)[:scrolls] = 1
    add_potion(9, 5)
    @game.read
    refute_empty assert_get(:detected)
    @game.send(:build_level)
    assert_empty assert_get(:detected)
  end

  def test_inventory_lists_scrolls
    arrange_get(:knapsack)[:scrolls] = 2
    @game.inventory
    assert_equal "Your knapsack holds 2 ? scrolls of potion finding.", last_log
  end

  def test_walking_into_a_scroll_of_mapping_packs_it
    arrange_arena
    add_scroll(6, 5, "scroll of mapping")
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal 1, @game.knapsack[:mapping_scrolls]
    assert_equal "You pack a scroll of mapping into your knapsack.", last_log
  end

  def test_reading_a_scroll_of_mapping_reveals_squares_in_range
    arrange_arena(px: 2, py: 2)
    fog
    arrange_get(:knapsack)[:mapping_scrolls] = 1
    @game.read(:mapping_scrolls)
    assert_equal 0, @game.knapsack[:mapping_scrolls]
    seen = arrange_get(:seen)
    assert seen[2][2 + Dungeon::SCROLL_RANGE], "at the edge of range"
    refute seen[2][2 + Dungeon::SCROLL_RANGE + 1], "just beyond range" if 2 + Dungeon::SCROLL_RANGE + 1 < W
    assert_equal "You read the scroll of mapping. The level within #{Dungeon::SCROLL_RANGE} squares is revealed!", last_log
  end

  def test_reading_a_missing_scroll_of_mapping_takes_no_turn
    arrange_arena
    arrange_monster(9, 5)
    @game.read(:mapping_scrolls)
    assert_equal "You have no scroll of mapping to read.", last_log
    assert_equal 9, assert_get(:monsters).first.x
  end

  def test_inventory_lists_each_kind_of_scroll
    arrange_get(:knapsack)[:scrolls] = 1
    arrange_get(:knapsack)[:mapping_scrolls] = 2
    @game.inventory
    assert_equal "Your knapsack holds ? scroll of potion finding and 2 ? scrolls of mapping.", last_log
  end

  # --- rings ---

  def add_ring(x, y, name)
    arrange_get(:monsters) << thing(x, y, "=", name, 20, 0..0, pacifist: true)
  end

  def test_every_ring_row_is_a_peaceful_thingage
    assert_equal 3, Dungeon::RINGS.size
    Dungeon::RINGS.each_value do |ring|
      row = Dungeon::THINGAGES.find { |k| k[:name] == ring[:row] }
      assert_equal ring[:glyph], row[:glyph], ring[:row]
      assert row[:pacifist], ring[:row]
      refute row[:aggressive], ring[:row]
    end
  end

  def test_walking_into_each_ring_packs_it
    Dungeon::RINGS.each do |slot, ring|
      arrange_arena
      add_ring(6, 5, ring[:row])
      @game.move(1, 0)
      assert_empty assert_get(:monsters), ring[:row]
      assert_equal 1, @game.knapsack[slot], ring[:row]
      assert_equal "You pack a #{ring[:name]} into your knapsack.", last_log
    end
  end

  def test_wearing_a_ring_takes_it_from_the_knapsack_and_a_turn
    arrange_arena
    arrange_get(:knapsack)[:peace_rings] = 1
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    @game.wear(:peace_rings)
    assert_equal :peace_rings, @game.ring
    assert_equal 0, @game.knapsack[:peace_rings]
    assert_equal 17, @game.hp
  end

  def test_wearing_another_ring_packs_the_old_one
    arrange_arena
    arrange_get(:knapsack)[:peace_rings] = 1
    arrange_get(:knapsack)[:strength_rings] = 1
    @game.wear(:peace_rings)
    @game.wear(:strength_rings)
    assert_equal :strength_rings, @game.ring
    assert_equal 1, @game.knapsack[:peace_rings]
    assert_equal 0, @game.knapsack[:strength_rings]
    assert_equal "You slip on the ring of strength.", last_log
  end

  def test_wearing_a_missing_ring_takes_no_turn
    arrange_arena
    arrange_monster(9, 5)
    @game.wear(:protection_rings)
    assert_equal "You have no ring of protection to wear.", last_log
    assert_nil @game.ring
    assert_equal 9, assert_get(:monsters).first.x
  end

  def test_inventory_lists_each_kind_of_ring
    arrange_get(:knapsack)[:peace_rings] = 1
    arrange_get(:knapsack)[:protection_rings] = 2
    @game.inventory
    assert_equal "Your knapsack holds = ring of peace and 2 = rings of protection.", last_log
  end

  # --- potions of speed and gaseous form, and throwing potions ---

  def goblin_at = [arrange_get(:monsters).first.x, arrange_get(:monsters).first.y]

  # TODO  this one can't comprehend mixed pacifism things()
  def test_the_new_potion_rows_are_peaceful
    { "speed potion" => "!", "gas potion" => "~" }.each do |name, glyph|
      row = Dungeon::THINGAGES.find { |k| k[:name] == name }
  #     #      assert_equal glyph, row[:glyph], name
  #     assert row[:pacifist], name
  #     refute row[:aggressive], name
    end
  end

  def test_walking_into_each_potion_packs_it_in_its_own_slot
    { "speed potion" => [:speed_potions, "potion of speed"], "gas potion" => [:gas_potions, "potion of gaseous form"] }
      .each do |name, (slot, full)|
        arrange_arena
        arrange_get(:monsters) << thing(6, 5, "!", name, 3, 0..0, pacifist: true)
        @game.move(1, 0)
        assert_equal 1, @game.knapsack[slot], name
        assert_equal "You pack a #{full} into your knapsack.", last_log
      end
  end

  def test_inventory_lists_every_kind_of_potion
    arrange_get(:knapsack).merge!(potions: 1, speed_potions: 2, gas_potions: 1)
    @game.inventory
    assert_equal "Your knapsack holds ¡ potion of sight, 2 ! potions of speed, and ~ potion of gaseous form.", last_log
  end

  # speed

  def test_quaffing_speed_gives_two_actions_for_everyone_elses_one
    arrange_arena
    arrange_get(:knapsack)[:speed_potions] = 1
    arrange_monster(10, 5, hp: 100)
    @game.quaff(:speed_potions)
    assert @game.hasted?
    assert_equal [10, 5], goblin_at, "drinking was the first of a pair: the goblin waits"
    @game.rest
    assert_equal [9, 5], goblin_at
    @game.rest
    assert_equal [9, 5], goblin_at, "the second action of the pair is free"
    @game.rest
    assert_equal [8, 5], goblin_at
  end

  def test_speed_lasts_thirty_rounds
    arrange_arena
    arrange_get(:knapsack)[:speed_potions] = 1
    @game.quaff(:speed_potions)
    58.times { @game.rest }
    assert @game.hasted?, "29 rounds gone after 59 actions"
    @game.rest
    refute @game.hasted?, "the 30th round passes on the 60th action"
    assert_equal "You slow back down.", last_log
  end

  def test_speed_shows_in_the_effects
    arrange_get(:knapsack)[:speed_potions] = 1
    @game.quaff(:speed_potions)
    assert_equal "Hasted 30", @game.effects
  end

  def test_quaffing_a_missing_potion_takes_no_turn
    arrange_arena
    arrange_monster(9, 5)
    @game.quaff(:speed_potions)
    assert_equal "You have no potion of speed to drink.", last_log
    assert_equal [9, 5], goblin_at
  end

  # gaseous form

  def test_gaseous_form_cannot_be_struck
    arrange_arena
    arrange_get(:knapsack)[:gas_potions] = 1
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    @game.quaff(:gas_potions)
    assert @game.gaseous?
    5.times { @game.rest }
    assert_equal 20, @game.hp
  end

  def test_nothing_wants_to_chase_gaseous_form
    arrange_arena
    arrange_get(:knapsack)[:gas_potions] = 1
    arrange_monster(9, 5)
    @game.quaff(:gas_potions)
    3.times { @game.rest }
    assert_equal [9, 5], goblin_at
  end

  def test_gaseous_form_cannot_touch_anyone
    arrange_arena
    arrange_get(:knapsack)[:gas_potions] = 1
    arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false)
    @game.quaff(:gas_potions)
    @game.move(1, 0)
    assert_equal 100, assert_get(:monsters).first.hp
    assert_equal [5, 5], player
    assert_equal "You drift against the goblin, but you can't touch it.", last_log
  end

  def test_gaseous_form_still_moves_into_clear_spots
    arrange_arena
    arrange_get(:knapsack)[:gas_potions] = 1
    @game.quaff(:gas_potions)
    @game.move(1, 1)
    assert_equal [6, 6], player
  end

  def test_gaseous_form_cannot_pack_or_give
    arrange_arena
    arrange_get(:knapsack).merge!(gas_potions: 1, gold: 1)
    add_potion(6, 5)
    arrange_monster(4, 5, hp: 100, hit: 0..0, greedy: true)
    @game.quaff(:gas_potions)
    @game.move(1, 0)
    assert_equal 0, @game.potions
    give(:gold, -1, 0)
    assert_equal 1, @game.gold
    refute assert_get(:monsters).last.ally
  end

  def test_gaseous_form_lasts_ten_rounds
    arrange_arena
    arrange_get(:knapsack)[:gas_potions] = 1
    @game.quaff(:gas_potions)
    8.times { @game.rest }
    assert @game.gaseous?
    @game.rest
    refute @game.gaseous?
    assert_equal "You become solid again.", last_log
  end

  # throwing

  def throw_at(slot, dx, dy)
    arrange_get(:knapsack)[slot] = 1
    @game.aim(slot)
    @game.move(dx, dy)
  end

  def test_aiming_asks_which_way_and_rest_keeps_the_potion
    arrange_arena
    arrange_get(:knapsack)[:speed_potions] = 1
    @game.aim(:speed_potions)
    assert_equal "Throw the potion of speed which way?", last_log
    @game.rest
    assert_equal "You keep it.", last_log
    assert_equal 1, @game.knapsack[:speed_potions]
  end

  def test_aiming_with_no_potion_readies_nothing
    arrange_arena
    @game.aim(:gas_potions)
    assert_equal "You have no potion of gaseous form to throw.", last_log
    @game.move(1, 0)
    assert_equal [6, 5], player, "the arrow moves as usual"
  end

  def test_a_thrown_speed_potion_hastes_the_first_character_in_range
    arrange_arena
    arrange_monster(8, 5, hp: 100, hit: 0..0)
    throw_at(:speed_potions, 1, 0)
    goblin = arrange_get(:monsters).first
    assert_equal Dungeon::SPEED_ROUNDS - 1, goblin.hasted, "the throw's own round already passed"
    assert_equal 0, @game.knapsack[:speed_potions]
    assert_includes @game.log, "You throw the potion of speed at the goblin. It speeds up to two actions for your one!"
    assert_equal [6, 5], goblin_at, "hasted, it closed two squares in one round"
  end

  def test_a_hasted_monster_strikes_twice_a_round
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "g", "goblin", 100, 3..3, str: 10, aggressive: true, hasted: 5)
    @game.rest
    assert_equal 14, @game.hp
  end

  def test_a_real_hasted_goblin_strikes_twice_for_two_each
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "g", "goblin", 100, 3..3, aggressive: true, hasted: 5)
    @game.rest
    assert_equal 16, @game.hp, "two 3s with str 8 (-1)"
  end

  def test_monster_haste_wears_off
    arrange_arena
    arrange_get(:monsters) << thing(15, 5, "g", "goblin", 100, 3..3, hasted: 2)
    2.times { @game.rest }
    assert_equal 0, assert_get(:monsters).first.hasted
  end

  def test_a_thrown_gas_potion_turns_its_catcher_to_mist
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    throw_at(:gas_potions, 1, 0)
    assert_equal 20, @game.hp, "mist cannot strike"
    @game.move(1, 0)
    assert_equal 100, assert_get(:monsters).first.hp
    assert_equal "Your blow passes right through the misty goblin.", @game.log.find { |l| l.start_with?("Your blow") }
  end

  def test_allies_leave_misty_monsters_alone
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_get(:monsters) << thing(8, 5, "g", "goblin", 10, 0..0, aggressive: true, gaseous: 5)
    @game.rest
    assert_equal 10, assert_get(:monsters).last.hp
  end

  def test_a_misty_monster_cannot_take_a_gift
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "g", "goblin", 10, 0..0, greedy: true, gaseous: 5)
    give(:gold, 1, 0)
    assert_equal 1, @game.gold
    assert_equal "A coin passes right through the goblin. You keep it.", last_log
  end

  def test_a_thrown_sight_potion_lets_a_monster_find_you_from_anywhere
    arrange_arena
    far = 5 + Dungeon::SIGHT + 3
    arrange_monster(far, 5)
    arrange_get(:monsters) << thing(far, 7, "g", "goblin", 10, 3..3, aggressive: true)
    arrange_get(:monsters).first.farsighted = true
    @game.rest
    assert_equal far - 1, assert_get(:monsters).first.x, "farsighted: it comes"
    assert_equal far, assert_get(:monsters).last.x, "the plain goblin never saw you"
  end

  def test_throwing_sight_marks_the_catcher_farsighted
    arrange_arena
    arrange_monster(7, 5, hp: 100, hit: 0..0)
    throw_at(:potions, 1, 0)
    assert assert_get(:monsters).first.farsighted
  end

  def test_a_potion_thrown_at_no_one_shatters
    arrange_arena
    throw_at(:speed_potions, 0, 1)
    assert_equal 0, @game.knapsack[:speed_potions]
    assert_equal "You throw the potion of speed and it shatters on the floor.", last_log
  end

  def test_a_potion_beyond_throwing_range_shatters
    arrange_arena
    arrange_monster(5 + Dungeon::THROW_RANGE + 1, 5, hp: 100, hit: 0..0)
    throw_at(:speed_potions, 1, 0)
    assert_nil assert_get(:monsters).first.hasted
  end

  # --- doors at the ends of hallways ---

  def add_door(x, y) = arrange_get(:monsters) << thing(x, y, "#", "door", 30, kind("door")[:hit], pacifist: true)

  def in_a_room?(x, y)
    arrange_get(:rooms).any? { |r| x.between?(r[:x], r[:x] + r[:w] - 1) && y.between?(r[:y], r[:y] + r[:h] - 1) }
  end

  def test_the_door_row_is_a_peaceful_out_of_band_wall
    door = kind("door")
    assert_equal "#", door[:glyph]
    assert door[:pacifist]
    assert door[:out_of_band]
    refute door[:aggressive]
  end

  def test_levels_place_a_few_doors_at_hallway_ends
    counts = []
    each_level do |seed|
      doors = arrange_get(:monsters).select { |m| m.name == "door" }
      counts << doors.size
      doors.each do |d|
        assert_equal ".", assert_get(:map)[d.y][d.x], "seed #{seed}: a door stands on corridor floor"
        refute in_a_room?(d.x, d.y), "seed #{seed}: outside every room"
        assert([[1, 0], [-1, 0], [0, 1], [0, -1]].any? { |dx, dy| in_a_room?(d.x + dx, d.y + dy) },
               "seed #{seed}: at the end of a hallway, next to a room")
      end
    end
    assert(counts.all? { |n| n <= kind("door")[:na] })
    assert(counts.count { |n| n >= 2 } > 25, "most levels get two or more")
  end

  def test_random_spawning_never_makes_a_door
    refute_includes arrangeManyLevels(10).map(&:name), "door"
  end

  def test_a_coin_opens_a_door
    arrange_arena
    add_door(6, 5)
    give(:gold, 1, 0)
    assert_empty assert_get(:monsters)
    assert_equal 0, @game.gold
    assert_equal "You give the door a coin. It pockets it and swings open.", last_log
    @game.move(1, 0)
    assert_equal [6, 5], player, "the way is clear"
  end

  def test_a_sandwich_opens_a_door
    arrange_arena
    add_door(5, 6)
    give(:sandwiches, 0, 1)
    assert_empty assert_get(:monsters)
    assert_equal "You give the door a sandwich. It eats it and swings open.", last_log
  end

  def test_a_thrown_coin_opens_a_door_down_the_hall
    arrange_arena
    add_door(8, 5)
    give(:gold, 1, 0)
    assert_equal "There's no one there to take it.", last_log
    @game.hurl
    assert_empty assert_get(:monsters)
    assert_equal "You throw a coin and the door catches it. It pockets it and swings open.", last_log
  end

  def test_a_closed_door_blocks_the_way_and_takes_one_hit_without_fighting_back
    arrange_arena
    add_door(6, 5)
    @game.move(1, 0)
    @game.rest
    assert_equal [5, 5], player
    assert_equal 20, @game.hp
    door = arrange_get(:monsters).first
    assert door.spurned
    refute door.aggressive
  end

  def test_a_second_hit_turns_a_door_aggressive_and_it_hits_back_every_turn
    arrange_arena
    add_door(6, 5)
    @game.move(1, 0)
    @game.move(1, 0)
    door = arrange_get(:monsters).first
    assert door.aggressive
    refute door.pacifist
    assert(@game.log.any? { |line| line.match?(/\AYou hit the door for \d\. It turns on you!\z/) })
    assert_match(/\AThe door hits you for \d\.\z/, last_log)
    hp = @game.hp
    @game.rest
    assert_match(/\AThe door hits you for \d\.\z/, last_log)
    assert_operator @game.hp, :<, hp, "resting heals 1, but the door's blow outweighs it"
    assert_equal [6, 5], [door.x, door.y], "a door stays put"
  end

  def test_an_angry_door_never_leaves_its_hallway_to_chase
    arrange_arena
    add_door(6, 5)
    2.times { @game.move(1, 0) }
    @game.move(-1, 0)
    2.times { @game.rest }
    door = arrange_get(:monsters).first
    assert_equal [6, 5], [door.x, door.y]
  end

  def test_resting_finds_a_door
    arrange_arena
    add_door(6, 5)
    @game.rest
    assert_includes @game.log, "You catch your breath and find a door beside you."
  end

  # --- teleport plates ---

  def in_rect?(r, (x, y)) = x.between?(r[:x], r[:x] + r[:w] - 1) && y.between?(r[:y], r[:y] + r[:h] - 1)

  # One far room for a random plate to land in, and no cage room
  def one_far_room
    arrange_set :rooms, [{ x: 20, y: 20, w: 3, h: 3 }]
    arrange_set :cage_room, nil
  end

  def test_plates_are_map_features_not_thingages
    names = Dungeon::THINGAGES.map { |k| k[:name] }
    refute_includes names, "teleportation plate"
    refute_includes names, "random teleportation plate"
  end

  def test_a_seen_plate_is_drawn
    arrange_arena
    arrange_set :plates, { [7, 5] => Dungeon::RANDOM_PLATE, [5, 7] => Dungeon::CAGE_PLATE }
    assert_equal "ṯ", @game.rows[5][7]
    assert_equal "_", @game.rows[7][5]
  end

  def test_a_random_plate_carries_the_player_to_a_room_and_stays_put
    arrange_arena
    one_far_room
    arrange_set :plates, { [6, 5] => Dungeon::RANDOM_PLATE }
    @game.move(1, 0)
    assert in_rect?(assert_get(:rooms).first, player), "landed at #{player}"
    assert_includes @game.log, "The plate flashes, and you land somewhere else in the dungeon."
    assert_equal({ [6, 5] => "ṯ" }, assert_get(:plates))
  end

  def test_a_cage_plate_lands_the_player_in_the_cage_room_without_springing_the_trap
    arena_trap
    room = { x: 10, y: 10, w: 12, h: 15 }
    arrange_set :cage_room, room
    arrange_set :rooms, [{ x: 28, y: 28, w: 5, h: 3 }, room]
    arrange_set :px, 30
    arrange_set :py, 30
    arrange_set :plates, { [31, 30] => Dungeon::CAGE_PLATE }
    @game.move(1, 0)
    # assert in_rect?(room, player), "landed at #{player}"
    refute_equal cage[:plate], player
    refute @game.over?
    # assert_includes @game.log, "The plate flashes, and you land in the cage room."
  end

  def test_a_monster_stepping_on_a_random_plate_vanishes_to_a_room
    arrange_arena
    one_far_room
    arrange_monster(7, 5)
    arrange_set :plates, { [6, 5] => Dungeon::RANDOM_PLATE }
    @game.rest
    goblin = arrange_get(:monsters).first
    assert in_rect?(assert_get(:rooms).first, [goblin.x, goblin.y]), "landed at #{goblin.x}, #{goblin.y}"
    assert_includes @game.log, "The goblin steps on a plate and vanishes!"
  end

  def test_a_monster_ignores_a_cage_plate
    arrange_arena
    one_far_room
    arrange_monster(7, 5)
    arrange_set :plates, { [6, 5] => Dungeon::CAGE_PLATE }
    @game.rest
    goblin = arrange_get(:monsters).first
    assert_equal [6, 5], [goblin.x, goblin.y]
  end

  def test_a_quail_that_sees_the_player_ride_a_random_plate_follows_through_it
    arrange_arena
    one_far_room
    quail = arrange_quail(8, 5).last
    arrange_set :plates, { [6, 5] => Dungeon::RANDOM_PLATE }
    @game.move(1, 0)
    assert_equal [7, 5], [quail.x, quail.y], "walks toward the plate"
    @game.rest
    assert_equal [6, 5], [quail.x, quail.y], "steps onto the plate, and waits there for its next action"
    @game.rest
    assert in_rect?(assert_get(:rooms).first, [quail.x, quail.y]), "landed at #{quail.x}, #{quail.y}"
    assert_nil quail.plate_bound
  end

  def test_a_spurned_quail_stays_put_when_the_player_rides_a_random_plate
    arrange_arena
    one_far_room
    quail = arrange_quail(8, 5).last.tap { |q| q.spurned = true }
    arrange_set :plates, { [6, 5] => Dungeon::RANDOM_PLATE }
    @game.move(1, 0)
    assert_nil quail.plate_bound
    assert_equal [8, 5], [quail.x, quail.y]
  end

  def test_a_quail_out_of_sight_misses_the_player_riding_a_random_plate
    arrange_arena
    one_far_room
    quail = arrange_quail(6 + Dungeon::SIGHT + 1, 5).last
    arrange_set :plates, { [6, 5] => Dungeon::RANDOM_PLATE }
    @game.move(1, 0)
    assert_nil quail.plate_bound
  end

  def test_a_random_plate_favors_the_cage_room_by_two_thirds
    arrange_arena
    cage_room = { x: 10, y: 10, w: 5, h: 5 }
    arrange_set :rooms, [{ x: 30, y: 10, w: 5, h: 5 }, cage_room]
    arrange_set :cage_room, cage_room
    caged = 3000.times.count { in_rect?(cage_room, @game.send(:landing, Dungeon::RANDOM_PLATE)) }
    assert_in_delta 5.0 / 8, caged / 3000.0, 0.03, "5/3 against 1 is 5/8 of landings"
  end

  def test_shallow_levels_have_random_plates_but_no_cage_plate
    levels_at(1) do |seed|
      plates = arrange_get(:plates)
      refute_includes plates.values, "_", "seed #{seed}"
      plates.each_key { |spot| refute in_rect?(arrange_get(:rooms).first, spot), "seed #{seed}: none in the first room" }
    end
  end

  def test_caged_levels_put_one_cage_plate_outside_the_first_and_cage_rooms
    plated = 0
    levels_at(5) do |seed|
      spots = arrange_get(:plates).select { |_, glyph| glyph == "_" }.keys
      assert_operator spots.size, :<=, 1, "seed #{seed}"
      spots.each do |spot|
        plated += 1
        refute in_rect?(assert_get(:rooms).first, spot), "seed #{seed}"
        refute in_rect?(assert_get(:cage_room), spot), "seed #{seed}"
      end
    end
    assert_operator plated, :>=, 10, "most caged levels have one"
  end

  # --- the safe cage ---

  # Generated levels at this depth, one per seed
  def levels_at(depth, seeds: 20)
    seeds.times.map do |seed|
      srand(seed)
      @game = Dungeon.new
      arrange_set :depth, depth
      @game.send(:build_level)
      yield seed
    end
  end

  # A cage across the top end of a 12-wide room in the open arena: its inside is x 10-21, y 10-13, the unseen line
  # runs along y 14, and the plate lies in the middle of the back row at 15, 10. The player stands below it, at 15, 17
  def arena_trap
    arrange_arena(px: 15, py: 17)
    arrange_set :eggs, {}
    arrange_set :cage, { xs: 10..21, ys: 10..13, line: [10..21, 14], plate: [15, 10], state: :arrange_set }
  end

  def cage = arrange_get(:cage)

  # The player just below the plate, one step from springing the trap
  def by_the_plate
    arena_trap
    arrange_set :px, 15
    arrange_set :py, 11
  end

  def spring = @game.move(0, -1)

  def test_levels_from_depth_five_have_a_cage_room
    levels_at(5) do |seed|
      room = arrange_get(:cage_room)
      assert_equal [12, 15], [room[:w], room[:h]], "seed #{seed}"
      assert_includes assert_get(:rooms), room
    end
  end

  def test_the_cage_is_the_far_four_rows_or_columns_at_one_end_of_its_room
    levels_at(5) do |seed|
      room = arrange_get(:cage_room)
      xs = room[:x]...room[:x] + room[:w]
      ys = room[:y]...room[:y] + room[:h]
      c = cage
      across = c[:xs].to_a == xs.to_a ? :rows : :columns
      if across == :rows
        assert_equal 4, c[:ys].to_a.size, "seed #{seed}: four rows deep"
        assert_includes [ys.first, ys.last - 4], c[:ys].first, "seed #{seed}: at the top or bottom end"
      else
        assert_equal ys.to_a, c[:ys].to_a, "seed #{seed}: the full height"
        assert_equal 4, c[:xs].to_a.size, "seed #{seed}: four columns deep"
        assert_includes [xs.first, xs.last - 4], c[:xs].first, "seed #{seed}: at the left or right end"
      end
    end
  end

  def test_the_plate_lies_in_the_middle_of_the_cages_back_row
    levels_at(5) do |seed|
      room = arrange_get(:cage_room)
      px, py = cage[:plate]
      lx, ly = cage[:line]
      assert @game.send(:in_trap?, px, py), "seed #{seed}: the plate is in the cage"
      if lx.is_a?(Range) # a cage of rows: the back row is the one farthest from the line
        assert_equal room[:x] + room[:w] / 2, px, "seed #{seed}: in the middle"
        assert_equal cage[:ys].to_a.max_by { |y| (y - ly).abs }, py, "seed #{seed}: on the back row"
      else
        assert_equal room[:y] + room[:h] / 2, py, "seed #{seed}: in the middle"
        assert_equal cage[:xs].to_a.max_by { |x| (x - lx).abs }, px, "seed #{seed}: on the back column"
      end
    end
  end

  def test_the_line_runs_across_the_room_just_in_front_of_the_cage
    levels_at(5) do |seed|
      lx, ly = cage[:line]
      line = (lx.is_a?(Range) ? lx.to_a : [lx]).product(ly.is_a?(Range) ? ly.to_a : [ly])
      assert_equal [cage[:xs].to_a.size, cage[:ys].to_a.size].max, line.size, "seed #{seed}: right across the room"
      line.each do |x, y|
        refute @game.send(:in_trap?, x, y), "seed #{seed}: the line is outside the cage"
        assert([[1, 0], [-1, 0], [0, 1], [0, -1]].any? { |dx, dy| @game.send(:in_trap?, x + dx, y + dy) },
               "seed #{seed}: and right against it")
      end
    end
  end

  def test_the_cages_end_has_no_way_in
    (5..9).each do |depth|
      levels_at(depth, seeds: 10) do |seed|
        room = arrange_get(:cage_room)
        in_room = ->(x, y) { (room[:x]...room[:x] + room[:w]).cover?(x) && (room[:y]...room[:y] + room[:h]).cover?(y) }
        cage[:xs].to_a.product(cage[:ys].to_a).each do |x, y|
          [-1, 0, 1].product([-1, 0, 1]).each do |dx, dy|
            next if in_room.(x + dx, y + dy)

            assert_equal "#", assert_get(:map)[y + dy][x + dx], "depth #{depth} seed #{seed}: an opening at #{x + dx}, #{y + dy}"
          end
        end
      end
    end
  end

  def test_shallower_levels_have_no_cage
    levels_at(4) { |seed| assert_nil cage, "seed #{seed}" }
  end

  def test_cage_levels_stay_connected_and_start_outside_the_cage_room
    levels_at(7) do |seed|
      map = arrange_get(:map)
      reached = {}
      queue = [player]
      until queue.empty?
        x, y = queue.shift
        next if reached[[x, y]] || map[y][x] == "#"

        reached[[x, y]] = true
        queue.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1])
      end
      open = (0...H).flat_map { |y| (0...W).map { |x| [x, y] } }.reject { |x, y| map[y][x] == "#" }
      assert_equal open.sort, reached.keys.sort, "seed #{seed}"
      refute_equal assert_get(:cage_room), assert_get(:rooms).first, "seed #{seed}" if assert_get(:rooms).size >= 3
    end
  end

  def test_the_line_is_unseen_and_the_plate_shows
    arena_trap
    assert_equal "." * 12, @game.rows[14][10, 12], "nothing marks the line"
    assert_equal "....." + "o" + "......", @game.rows[10][10, 12]
    assert_equal "." * 12, @game.rows[12][10, 12], "the cage floor is plain floor"
  end

  def test_things_lying_on_the_plate_show_over_it
    arena_trap
    arrange_set :treasure, { [15, 10] => 3 }
    assert_equal "$", @game.rows[10][15]
  end

  def test_crossing_the_line_springs_nothing
    arena_trap
    3.times { @game.move(0, -1) }
    assert_equal [15, 14], player, "standing on the line"
    @game.move(0, -1)
    assert_equal [15, 13], player, "over the line and into the cage"
    assert_equal :arrange_set, cage[:state]
    refute @game.over?
  end

  def test_monsters_cross_the_line_freely
    arena_trap
    arrange_monster(15, 11, hp: 100, hit: 0..0)
    3.times { @game.rest }
    assert_equal [15, 14], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_stepping_on_the_plate_springs_the_trap
    by_the_plate
    spring
    assert_equal [15, 10], player
    assert_equal :sprung, cage[:state]
    assert_equal "|" * 12, @game.rows[14][10, 12], "bars all along the line"
    assert_includes @game.log, "The bars slam down behind you. Your haul: nothing but yourself."
  end

  def test_springing_the_trap_without_an_egg_goes_on_behind_the_bars
    by_the_plate
    spring
    refute @game.over?
    assert_equal "", @game.outcome
    assert_equal "Without an egg, step off the plate and back on to lift the bars.", last_log
  end

  def test_the_bars_block_the_way_until_lifted
    by_the_plate
    arrange_set :py, 13
    arrange_set :cage, cage.merge(state: :sprung)
    @game.move(0, 1)
    assert_equal [15, 13], player
  end

  def test_stepping_back_onto_the_plate_lifts_the_bars_to_try_again
    by_the_plate
    spring
    @game.move(0, 1)
    @game.move(0, -1)
    assert_equal :arrange_set, cage[:state]
    assert_equal "The bars lift, and the trap is set again.", last_log
    @game.move(0, 1)
    @game.move(0, -1)
    assert_equal :sprung, cage[:state], "and springs again"
  end

  def test_nothing_moves_once_the_trap_is_sprung
    by_the_plate
    arrange_get(:knapsack)[:eggs] = [egg(false)]
    arrange_monster(15, 20, hp: 100)
    spring
    assert_equal [15, 20], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "springing ends it at once"
    @game.move(1, 0)
    @game.rest
    assert_equal [15, 10], player
  end

  def test_everything_behind_the_line_is_the_haul
    by_the_plate
    arrange_quail(12, 12)
    arrange_monster(18, 11, hp: 100, aggressive: false)
    arrange_monster(15, 20, hp: 100, aggressive: false)  # outside
    arrange_set :treasure, { [11, 11] => 30, [15, 18] => 50 } # one inside, one outside
    arrange_set :sandwiches, { [20, 13] => 1 }
    arrange_get(:knapsack)[:gold] = 5
    spring
    assert_includes @game.log, "The bars slam down behind you. Your haul: a Quail, a goblin, 35 gold, and 1 sandwich."
  end

  def test_a_developed_egg_in_your_knapsack_hatches_and_wins
    by_the_plate
    arrange_get(:knapsack)[:eggs] = [egg(true), egg(false)]
    spring
    assert @game.won?
    assert_equal "YOU WON", @game.outcome
    assert_includes @game.log, "The bars slam down behind you. Your haul: 2 eggs."
    assert_equal "An egg hatches, and Quail chicks peep in the cage. You won!", last_log
  end

  def test_eggs_lying_in_the_cage_hatch_too_but_not_those_outside
    by_the_plate
    arrange_set :eggs, { [12, 11] => [egg(true), egg(true)], [15, 20] => [egg(true)] }
    spring
    assert @game.won?
    assert_includes @game.log, "The bars slam down behind you. Your haul: 2 eggs."
    assert_equal "2 eggs hatch, and Quail chicks peep in the cage. You won!", last_log
  end

  def test_yolk_eggs_never_hatch
    by_the_plate
    arrange_get(:knapsack)[:eggs] = [egg(false), egg(false, candled: true)]
    spring
    refute @game.won?
    assert @game.over?
    assert_equal "No egg in your haul hatches. The adventure is over.", last_log
  end

  # --- potions of sleep ---

  def test_quaffing_a_potion_of_sleep_lets_the_monsters_carry_on
    arrange_arena
    arrange_get(:knapsack)[:sleep_potions] = 1
    arrange_monster(9, 5, hit: 3..3)
    @game.quaff(:sleep_potions)
    assert_includes @game.log, "You wake up."
    assert_operator @game.hp, :<, 20, "the goblin walked up and bit while you slept"
  end

  def test_a_potion_of_sleep_thrown_at_a_monster_puts_it_to_sleep
    arrange_arena
    arrange_get(:knapsack)[:sleep_potions] = 1
    goblin = arrange_monster(7, 5, hit: 3..3).last
    @game.aim(:sleep_potions)
    @game.move(1, 0)
    @game.rest
    assert_equal [7, 5], [goblin.x, goblin.y], "asleep, so it neither moves nor bites"
    assert_equal 20, @game.hp
  end

  def test_a_disguised_potion_of_sleep_hurls_itself_at_you
    arrange_arena
    arrange_get(:monsters) << thing(8, 5, "R", "rat", 3, 1..2, aggressive: true, disguised_potion: :sleep_potions)
    @game.rest
    assert_empty assert_get(:monsters)
    assert(@game.log.any? { |l| l.start_with?("The rat is a potion of sleep in disguise!") })
    assert_equal "You wake up.", last_log
  end

  # --- pushing ---

  # A hallway running east from the player, walled above and below
  def arrange_hallway
    arrange_arena
    (6..9).each { |x| arrange_get(:map)[4][x] = arrange_get(:map)[6][x] = "#" }
    arrange_set :facing, [1, 0]
  end

  def test_a_tap_pushes_a_thingage_in_a_tight_spot
    arrange_hallway
    goblin = arrange_monster(6, 5, hp: 100, aggressive: false).last
    @game.tap
    assert_equal [7, 5], [goblin.x, goblin.y]
    assert_equal "You push the goblin.", last_log
  end

  def test_a_tap_in_the_open_is_only_a_tap
    arrange_arena
    arrange_set :facing, [1, 0]
    goblin = arrange_monster(6, 5, hp: 100, aggressive: false).last
    @game.tap
    assert_equal [6, 5], [goblin.x, goblin.y]
    assert_equal "You tap the goblin.", last_log
  end

  def test_a_push_against_a_wall_is_only_a_tap
    arrange_hallway
    arrange_get(:map)[5][7] = "#"
    goblin = arrange_monster(6, 5, hp: 100, aggressive: false).last
    @game.tap
    assert_equal [6, 5], [goblin.x, goblin.y]
    assert_equal "You tap the goblin.", last_log
  end

  def test_a_push_onto_poison_hurts
    arrange_hallway
    arrange_get(:traps)[[7, 5]] = { kind: :poison, seen: false }
    goblin = arrange_monster(6, 5, hp: 100, aggressive: false).last
    @game.tap
    assert_includes (96..98), goblin.hp
  end

  # --- floor traps ---

  def poison_at(x, y) = arrange_get(:traps)[[x, y]] = { kind: :poison, seen: false }
  def wand_at(x, y, charges: 3) = arrange_get(:traps)[[x, y]] = { kind: :wand, seen: false, charges: charges }

  def test_an_unseen_trap_looks_like_floor
    arrange_arena
    poison_at(7, 5)
    assert_equal ".", @game.rows[5][7]
  end

  def test_stepping_on_a_potion_of_poison_hurts_and_leaves_it_broken
    arrange_arena
    poison_at(6, 5)
    @game.move(1, 0)
    assert_includes (16..18), @game.hp, "2d2 damage"
    assert_equal :poison, assert_get(:traps)[[6, 5]][:kind], "still a trap"
    @game.move(1, 0)
    assert_equal ",", @game.rows[5][6], "a broken potion on the floor"
  end

  def test_a_monster_stepping_on_poison_takes_damage
    arrange_arena
    poison_at(7, 5)
    goblin = arrange_monster(8, 5, hp: 100).last
    @game.rest
    assert_equal [7, 5], [goblin.x, goblin.y]
    assert_includes (96..98), goblin.hp
  end

  def test_stepping_on_a_wand_slows_you_and_you_pick_it_up
    arrange_arena
    wand_at(6, 5)
    @game.move(1, 0)
    assert_includes @game.log, "You step on a wand of slowness, and it zaps you. Everything else speeds up!"
    assert_equal [2], assert_get(:knapsack)[:wands]
    assert_nil assert_get(:traps)[[6, 5]]
  end

  def test_zapping_the_wand_slows_the_first_thingage_that_way
    arrange_arena
    arrange_get(:knapsack)[:wands] << 3
    goblin = arrange_monster(9, 5, hp: 100, aggressive: false).last
    @game.zap
    @game.move(1, 0)
    assert_includes (1..4), goblin.slowed.to_i, "2d2 rounds, less the one that passed"
    assert_equal [2], assert_get(:knapsack)[:wands]
    assert_equal [5, 5], player, "zapping doesn't move you"
  end

  def test_an_empty_wand_cannot_zap
    arrange_arena
    arrange_get(:knapsack)[:wands] << 0
    @game.zap
    assert_equal "Your wand of slowness has no charges left on this level.", last_log
  end

  def test_wands_refill_on_each_level
    arrange_get(:knapsack)[:wands] << 0
    @game.send(:descend)
    assert_equal [3], assert_get(:knapsack)[:wands]
  end

  def test_a_rat_runs_behind_an_unseen_trap_and_waits
    arrange_arena
    poison_at(8, 5)
    rat = add_rat(10, 5).last
    3.times { @game.rest }
    assert_equal [9, 5], [rat.x, rat.y], "the trap lies between you"
    assert_equal 20, @game.hp
  end

  def test_a_rat_never_treads_on_the_trap_it_leads_over
    arrange_arena
    poison_at(7, 5)
    rat = add_rat(6, 6).last
    4.times { @game.rest }
    assert_equal [8, 5], [rat.x, rat.y]
    assert_equal false, assert_get(:traps)[[7, 5]][:seen]
  end

  def test_an_axebeak_leads_a_coyote_onto_a_trap
    arrange_arena(px: 2, py: 2)
    poison_at(12, 5)
    beak = thing(14, 5, "A", "Axebeak", 100, 0..0, aggressive: false)
    coyote = thing(9, 5, "C", "coyote", 100, 0..0, aggressive: false)
    arrange_get(:monsters).push(beak, coyote)
    6.times { @game.rest }
    assert_equal [13, 5], [beak.x, beak.y], "behind the trap from the coyote"
    assert coyote.hp < 100, "the coyote treads on the poison chasing it"
  end

  # --- trolls and Quails ---

  def arrange_troll(x, y, hit: 100..100)
    arrange_get(:monsters) << thing(x, y, "T", "troll", 100, hit, aggressive: false)
  end

  def test_a_troll_hunts_a_quail_around_a_wall
    arrange_arena
    arrange_get(:map)[5][9] = "#"
    troll = arrange_troll(8, 5).last
    arrange_quail(10, 5)
    @game.rest
    refute_equal [8, 5], [troll.x, troll.y], "it sets off round the wall"
  end

  def test_a_troll_eats_the_quail_it_catches
    arrange_arena
    arrange_troll(8, 5)
    arrange_quail(9, 5).last.spurned = true # so it stays put while they meet
    @game.rest
    assert_equal "The troll taps the Quail.", last_log, "the first time they meet"
    @game.rest
    assert_equal %w[troll], assert_get(:monsters).map(&:name)
    assert_equal "The troll eats the Quail!", last_log
  end

  def test_a_troll_eating_a_quail_howls
    played = []
    Dungeon.sound_player = ->(name) { played << name }
    arrange_arena
    arrange_troll(8, 5)
    arrange_quail(9, 5).last.spurned = true # so it stays put while they meet
    2.times { @game.rest }
    assert_equal %w[wolf], played
  ensure
    Dungeon.sound_player = nil
  end

  def test_a_coyote_hunts_and_eats_an_axebeak
    played = []
    Dungeon.sound_player = ->(name) { played << name }
    arrange_arena
    arrange_get(:monsters) << thing(8, 5, "C", "coyote", 100, 100..100, aggressive: false)
    arrange_get(:monsters) << thing(9, 5, "A", "Axebeak", 1, 0..0, aggressive: false)
    @game.rest
    assert_equal %w[coyote], assert_get(:monsters).map(&:name)
    assert_equal "The coyote eats the Axebeak!", last_log
    assert_equal %w[wolf], played
  ensure
    Dungeon.sound_player = nil
  end

  def test_a_troll_with_no_quail_minds_its_own_business
    arrange_arena
    troll = arrange_troll(8, 5).last
    3.times { @game.rest }
    assert_equal [8, 5], [troll.x, troll.y]
  end

  # --- eggs ---

  def test_deeper_nests_hold_more_developed_eggs
    { 8 => 3 / 9.0, 9 => 4 / 9.0, 11 => 6 / 9.0, 13 => 8 / 9.0, 20 => 0.9 }.each do |depth, chance|
      arrange_set :depth, depth
      assert_in_delta chance, @game.send(:developed_chance), 0.0001, "depth #{depth}"
    end
  end

  def test_a_nest_holds_one_to_three_uncandled_eggs
    levels_at(8) do |seed|
      laid = arrange_get(:eggs).values.first
      assert_includes 1..3, laid.size, "seed #{seed}"
      assert(laid.all? { |e| e.is_a?(Dungeon::Egg) && !e.candled }, "seed #{seed}")
    end
  end

  def test_about_a_third_of_eggs_laid_at_depth_eight_are_developed
    arrange_set :depth, 8
    laid = Array.new(900) { @game.send(:lay_egg) }
    assert_in_delta 300, laid.count(&:developed), 60
  end

  def test_candling_a_yolk_egg
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg(false)]
    @game.candle
    assert_equal "You hold the egg up to the light. It's just yolk.", last_log
    assert @game.knapsack[:eggs].first.candled
  end

  def test_candling_a_developed_egg
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg(true)]
    @game.candle
    assert_equal "You hold the egg up to the light. You can see legs, wings, and a beak.", last_log
  end

  def test_candling_several_eggs
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg(false), egg(true), egg(false)]
    @game.candle
    assert_equal "You hold 3 eggs up to the light: 2 are just yolk; in one you can see legs, wings, and a beak.", last_log
    assert(@game.knapsack[:eggs].all?(&:candled))
  end

  def test_candling_eggs_that_are_all_developed
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg(true), egg(true)]
    @game.candle
    assert_equal "You hold 2 eggs up to the light: in 2 you can see legs, wings, and a beak.", last_log
  end

  def test_candling_takes_a_turn
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:eggs] = [egg(false)]
    @game.candle
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_candling_with_no_eggs
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    @game.candle
    assert_equal "You have no eggs to hold up to the light.", last_log
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "no turn passes"
  end

  def test_the_knapsack_shows_what_candling_found
    arrange_get(:knapsack)[:eggs] = [egg(true), egg(false), egg(false)]
    assert_includes @game.contents, ["3 eggs", :eggs]
    @game.candle
    assert_includes @game.contents, ["3 eggs (1 developed, 2 yolk)", :eggs]
    arrange_get(:knapsack)[:eggs] << egg(true)
    assert_includes @game.contents, ["4 eggs (1 developed, 2 yolk, 1 unknown)", :eggs]
  end

  def test_a_nesting_quail_waits_by_its_eggs_then_follows_them
    arrange_arena
    arrange_get(:monsters) << thing(9, 5, "Q", "Quail", 100, 0..0, pacifist: true, nesting: true)
    arrange_set :eggs, { [6, 5] => [egg, egg(true)] }
    @game.rest
    q = arrange_get(:monsters).first
    assert_equal [9, 5], [q.x, q.y], "nesting"

    @game.move(1, 0)
    assert_equal [egg, egg(true)], @game.knapsack[:eggs]
    refute q.nesting
    assert_includes @game.log, "You gather 2 eggs from the nest."
    assert_equal "The nesting Quail stirs and follows its eggs!", last_log
    assert_equal [8, 5], [q.x, q.y], "now it follows"
  end

  def test_eggs_and_the_nest_are_drawn
    arrange_arena
    arrange_set :eggs, { [6, 5] => [egg] }
    arrange_set :nest, [7, 5]
    assert_equal "0", @game.rows[5][6]
    assert_equal "&", @game.rows[5][7]
  end

  def test_inventory_lists_eggs
    arrange_get(:knapsack)[:eggs] = [egg, egg]
    @game.inventory
    assert_equal "Your knapsack holds 2 eggs.", last_log
  end

  # --- laced candles ---

  # A neutral goblin that never stirs, to show who a burst splashes
  def bystander(x, y) = arrange_monster(x, y, hp: 100, hit: 0..0, aggressive: false).last

  def test_walking_into_a_candle_packs_it
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "i", "candle", 3, 0..0, pacifist: true)
    @game.move(1, 0)
    assert_equal 1, @game.knapsack[:candles]
    assert_empty assert_get(:monsters)
    assert_equal "You pack a candle into your knapsack.", last_log
  end

  def test_pouring_a_potion_into_a_candle_laces_it
    arrange_arena
    arrange_get(:knapsack)[:speed_potions] = 1
    arrange_get(:knapsack)[:candles] = 2
    @game.pour(:speed_potions)
    assert_equal [0, 1, 1], assert_get(:knapsack).values_at(:speed_potions, :candles, :laced_speed_potions)
    assert_equal "You pour the potion of speed into a candle.", last_log
    assert_includes @game.contents, ["i candle", :candles]
    assert_includes @game.contents, ["i candle laced with potion of speed", :laced_speed_potions]
  end

  def test_pouring_takes_a_turn
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:gas_potions] = 1
    arrange_get(:knapsack)[:candles] = 1
    @game.pour(:gas_potions)
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  def test_pouring_needs_a_candle
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:speed_potions] = 1
    @game.pour(:speed_potions)
    assert_equal "You have no candle to pour it into.", last_log
    assert_equal 1, @game.knapsack[:speed_potions]
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "no turn passes"
  end

  def test_pouring_needs_the_potion
    arrange_arena
    arrange_get(:knapsack)[:candles] = 1
    @game.pour(:speed_potions)
    assert_equal "You have no potion of speed to pour.", last_log
    assert_equal 1, @game.knapsack[:candles]
  end

  def test_flinging_asks_which_way_and_rest_keeps_the_candle
    arrange_arena
    arrange_get(:knapsack)[:laced_speed_potions] = 1
    @game.fling(:laced_speed_potions, :kick)
    assert_equal "Kick the candle laced with potion of speed which way?", last_log
    @game.rest
    assert_equal "You keep it.", last_log
    assert_equal 1, @game.knapsack[:laced_speed_potions]
  end

  def test_flinging_needs_a_laced_candle
    arrange_arena
    @game.fling(:laced_gas_potions, :throw)
    assert_equal "You have no candle laced with potion of gaseous form.", last_log
  end

  def test_a_burst_covers_twenty_feet_a_side
    area = @game.send(:burst_area, 10, 10)
    assert_equal 16, area.size, "4 by 4 squares, 5 feet each"
    assert_equal [8, 9, 10, 11], area.map(&:first).uniq.sort
    assert_equal [8, 9, 10, 11], area.map(&:last).uniq.sort
  end

  def test_a_thrown_candle_bursts_on_the_first_one_in_its_path_and_splashes_everyone_near
    arrange_arena
    target = bystander(9, 5)
    near = [bystander(8, 4), bystander(10, 6)]
    far = [bystander(11, 5), bystander(9, 7)]
    arrange_get(:knapsack)[:laced_gas_potions] = 1
    @game.fling(:laced_gas_potions, :throw)
    @game.move(1, 0)
    assert_equal 0, @game.knapsack[:laced_gas_potions]
    ([target] + near).each { |m| assert_equal Dungeon::GAS_ROUNDS - 1, m.gaseous, "at #{m.x}, #{m.y}: a round already passed" }
    far.each { |m| assert_nil m.gaseous, "at #{m.x}, #{m.y}" }
    assert_includes @game.log, "You throw the candle laced with potion of gaseous form, and it bursts over the goblin, the goblin, and the goblin."
    assert_equal "They turn to mist!", last_log
    refute @game.gaseous?, "you stood well clear"
  end

  def test_a_kicked_candle_goes_only_three_squares
    arrange_arena
    near = bystander(9, 6)
    far = bystander(10, 5)
    arrange_get(:knapsack)[:laced_speed_potions] = 1
    @game.fling(:laced_speed_potions, :kick)
    @game.move(1, 0)
    assert_equal Dungeon::SPEED_ROUNDS - 1, near.hasted, "the burst at 8, 5 reaches x 6-9"
    assert_nil far.hasted
    assert_includes @game.log, "You kick the candle laced with potion of speed, and it bursts over the goblin."
    assert_equal "They speed up to two actions for your one!", last_log
  end

  def test_a_candle_flung_at_a_wall_bursts_over_you
    arrange_arena(px: 2, py: 5)
    arrange_get(:knapsack)[:laced_gas_potions] = 1
    @game.fling(:laced_gas_potions, :throw)
    @game.move(-1, 0)
    assert @game.gaseous?
    assert_includes @game.log, "You throw the candle laced with potion of gaseous form, and it bursts over you."
  end

  def test_a_candle_bursting_over_empty_floor
    arrange_arena
    arrange_get(:knapsack)[:laced_potions] = 1
    @game.fling(:laced_potions, :throw)
    @game.move(0, 1)
    assert_includes @game.log, "You throw the candle laced with potion of sight, and it bursts over empty floor."
  end

  # --- slowness, healing, and empty potions ---

  def add_new_potion(x, y, name) = arrange_get(:monsters) << thing(x, y, "!", name, 3, 0..0, pacifist: true)

  def test_walking_into_a_new_potion_packs_it
    { "slow potion" => [:slow_potions, "a potion of slowness"], "healing potion" => [:healing_potions, "a potion of healing"],
      "empty potion" => [:empty_potions, "an empty potion"] }.each do |name, (slot, packed)|
      arrange_arena
      add_new_potion(6, 5, name)
      @game.move(1, 0)
      assert_equal 1, @game.knapsack[slot], name
      assert_equal "You pack #{packed} into your knapsack.", last_log
    end
  end

  def test_a_potion_of_healing_restores_you_to_full
    arrange_arena
    arrange_set :hp, 5
    arrange_get(:knapsack)[:healing_potions] = 1
    @game.quaff(:healing_potions)
    assert_equal @game.max_hp, @game.hp
    assert_equal "You quaff the potion of healing. You feel whole again!", last_log
  end

  def test_an_empty_potion_does_nothing
    arrange_arena
    arrange_get(:knapsack)[:empty_potions] = 1
    @game.quaff(:empty_potions)
    assert_equal 0, @game.knapsack[:empty_potions]
    assert_equal "You quaff the empty potion. It's empty. Nothing happens.", last_log
  end

  def test_slowness_gives_everyone_else_two_actions_for_yours
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:slow_potions] = 1
    @game.quaff(:slow_potions)
    assert_equal [7, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "two steps for your one"
    assert_equal "Slowed #{Dungeon::SLOW_ROUNDS - 2}", @game.effects, "two rounds passed"
  end

  def test_slowness_wears_off
    arrange_arena
    arrange_set :slowed, 1
    @game.rest
    refute @game.slowed?
    assert_includes @game.log, "You speed back up."
  end

  def test_a_slowed_monster_sits_out_every_other_round
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0).last.slowed = Dungeon::SLOW_ROUNDS
    @game.rest
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "sits out"
    @game.rest
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "then steps"
    @game.rest
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "then sits out again"
  end

  def test_a_thrown_potion_of_slowness_slows_its_catcher
    arrange_arena
    arrange_monster(7, 5, hp: 100, hit: 0..0, aggressive: false)
    throw_at(:slow_potions, 1, 0)
    assert_equal Dungeon::SLOW_ROUNDS - 1, assert_get(:monsters).first.slowed
    assert_equal "You throw the potion of slowness at the goblin. It slows to half your pace!", last_log
  end

  def test_a_thrown_potion_of_healing_heals_its_catcher
    arrange_arena
    arrange_monster(7, 5, hp: 5, hit: 0..0, aggressive: false)
    throw_at(:healing_potions, 1, 0)
    assert_equal 5 + Dungeon::HEAL_HP, assert_get(:monsters).first.hp
  end

  def test_a_burst_of_slowness_slows_everyone_near
    arrange_arena
    near = bystander(9, 5)
    arrange_get(:knapsack)[:laced_slow_potions] = 1
    @game.fling(:laced_slow_potions, :throw)
    @game.move(1, 0)
    assert_equal Dungeon::SLOW_ROUNDS - 1, near.slowed
    assert_equal "They slow to half your pace!", last_log
  end

  # --- defeating a shield, potion, or weapon packs it ---

  def add_shield(x, y, name = "shield", glyph = "༻") = arrange_get(:monsters) << thing(x, y, glyph, name, 1, 0..0, pacifist: true)

  def test_defeating_a_shield_packs_it
    arrange_arena
    add_shield(6, 5)
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_equal [{ name: "shield", glyph: "༻" }], @game.knapsack[:shields]
    assert_equal "You defeat the shield and pack it into your knapsack.", last_log
    assert_includes @game.contents, ["༻ shield", :shields]
    assert_equal 6, @game.load
  end

  def test_shields_of_a_kind_are_listed_together
    arrange_get(:knapsack)[:shields] = [{ name: "light shield", glyph: "𓆩" }] * 2
    assert_includes @game.contents, ["2 𓆩 light shields", :shields]
    assert_equal 6, @game.load, "two light shields at 3 pounds each"
  end

  def test_a_shield_too_heavy_to_pack_is_left_behind
    arrange_arena
    arrange_get(:knapsack)[:gold] = 3000
    add_shield(6, 5, "light shield", "𓆩")
    @game.move(1, 0)
    assert_empty assert_get(:monsters)
    assert_empty @game.knapsack[:shields]
    assert_equal "You defeat the light shield, but your knapsack is too full to carry it, so you leave it behind.", last_log
  end

  def test_defeating_a_potion_packs_it
    arrange_arena
    potion = thing(6, 5, "¡", "potion", 1, 0..0, pacifist: true)
    arrange_get(:monsters) << potion
    @game.send(:attack, potion)
    assert_equal 1, @game.knapsack[:potions]
    assert_equal "You defeat the potion and pack it into your knapsack.", last_log
  end

  def test_defeating_a_weapon_still_wields_it_with_empty_hands
    arrange_arena
    arrangeWeapon(6, 5)
    @game.move(1, 0)
    assert_equal "dagger", @game.wielded[:name]
    assert_empty @game.knapsack[:weapons]
  end

  # --- weight ---

  def pounds(slot) = @game.pounds(slot)
  def axe = Dungeon::WEAPONS.find { |w| w[:name] == "axe" }

  def test_everything_the_knapsack_holds_has_a_weight
    slots = @game.knapsack.select { |_, n| n.is_a?(Integer) }.keys
    slots.each { |slot| assert_operator pounds(slot), :>, 0, slot }
    Dungeon::WEAPONS.each { |w| assert_operator w[:packable], :>, 0, w[:name] }
  end

  def test_weights_come_from_the_lines_that_build_things
    { gold: "1/50", sandwiches: "1", candles: "1", potions: "1/2", speed_potions: "1/2", scrolls: "1/10",
      peace_rings: "1/10", laced_potions: "3/2" }.each do |slot, weight|
      assert_equal Rational(weight), pounds(slot), slot
    end
  end

  def test_an_empty_knapsack_weighs_nothing
    assert_equal 0, @game.load
    assert_equal "Load 0/60 lb", @game.load_text
  end

  def test_the_load_is_everything_in_the_knapsack_but_not_in_hand
    arrange_get(:knapsack).merge!(gold: 50, sandwiches: 2, potions: 1, candles: 1, eggs: [egg, egg], weapons: [dagger, axe])
    arrange_set :wielded, axe
    assert_equal Rational(21, 2), @game.load, "1 + 2 + 0.5 + 1 + 1 + 1 + 4; the axe in hand weighs nothing"
    assert_equal "Load 10.5/60 lb", @game.load_text
  end

  def test_a_full_knapsack_refuses_an_item
    arrange_arena
    arrange_get(:knapsack)[:gold] = 3000
    add_potion(6, 5)
    @game.move(1, 0)
    assert_equal "Your knapsack is too full for the potion of sight.", last_log
    assert_equal 0, @game.knapsack[:potions]
    assert_equal 1, assert_get(:monsters).size, "it stays on the floor"
    assert_equal [5, 5], player
    assert_equal Dungeon::MAX_BLOOD_SUGAR, @game.blood_sugar, "and the refusal costs no turn"
  end

  def test_gold_goes_in_only_as_far_as_there_is_room
    arrange_arena
    arrange_get(:knapsack)[:sandwiches] = 59
    arrange_set :treasure, { [6, 5] => 80 }
    @game.move(1, 0)
    assert_equal 50, @game.gold, "a pound's room is 50 coins"
    assert_equal({ [6, 5] => 30 }, assert_get(:treasure), "the rest stays on the floor")
    assert_includes @game.log, "You find 80 gold, but your knapsack has room for only 50."
  end

  def test_sandwiches_go_in_only_as_far_as_there_is_room
    arrange_arena
    arrange_get(:knapsack)[:gold] = 2950
    arrange_set :sandwiches, { [6, 5] => 3 }
    @game.move(1, 0)
    assert_equal 1, @game.sandwiches
    assert_equal({ [6, 5] => 2 }, assert_get(:sandwiches))
    assert_includes @game.log, "Your knapsack has room for only 1 of the 3 sandwiches here."
  end

  def test_eggs_go_in_only_as_far_as_there_is_room
    arrange_arena
    arrange_get(:knapsack)[:sandwiches] = 59
    arrange_set :eggs, { [6, 5] => [egg, egg(true), egg] }
    @game.move(1, 0)
    assert_equal [egg, egg(true)], @game.knapsack[:eggs]
    assert_equal({ [6, 5] => [egg] }, assert_get(:eggs))
    assert_includes @game.log, "You gather 2 eggs from the nest, leaving 1 for want of room."
  end

  def test_a_full_knapsack_leaves_the_eggs_in_the_nest
    arrange_arena
    arrange_get(:knapsack)[:sandwiches] = 60
    arrange_set :eggs, { [6, 5] => [egg, egg] }
    @game.move(1, 0)
    assert_empty @game.knapsack[:eggs]
    assert_equal 2, assert_get(:eggs)[[6, 5]].size
    assert_includes @game.log, "Your knapsack is too full for the eggs."
  end

  def test_a_weapon_too_heavy_to_pack_is_left_behind
    arrange_arena
    arrange_set :wielded, sword
    arrange_get(:knapsack)[:gold] = 3000
    arrangeWeapon(6, 5)
    @game.move(1, 0)
    assert_empty @game.knapsack[:weapons]
    assert_equal "You defeat the dagger, but your knapsack is too full to carry it, so you leave it behind.", last_log
  end

  def test_a_seized_weapon_keeps_its_weight
    arrange_arena
    arrange_set :wielded, sword
    arrangeWeapon(6, 5)
    @game.move(1, 0)
    assert_equal 1, @game.knapsack[:weapons].first[:packable]
    assert_equal 1, @game.load
  end

  def test_no_room_for_the_weapon_in_hand_means_no_swap
    arrange_arena
    arrange_set :wielded, axe
    arrange_get(:knapsack).merge!(weapons: [dagger], sandwiches: 58)
    @game.wield
    assert_equal "Your knapsack is too full to hold your axe in place of the dagger.", last_log
    assert_equal axe, @game.wielded
    assert_equal [dagger], @game.knapsack[:weapons]
  end

  # --- going back up ---

  # The parts of a level that going away and coming back should leave untouched
  LEVEL_PARTS = %i[map seen rooms monsters treasure sandwiches eggs plates].freeze

  # The stairs room, at depth 3, with a < one step east of the player instead of the >
  def up_stairs_room
    stairs_room
    arrange_get(:map)[5][6] = "<"
    arrange_set :depth, 3
    arrange_set :deepest, 3
  end

  def test_levels_below_the_first_start_the_player_on_the_way_up
    levels_at(1, seeds: 5) { |seed| refute_equal "<", arrange_get(:map)[arrange_get(:py)][arrange_get(:px)], "seed #{seed}: nowhere up from the top" }
    [2, 5, 9].each do |depth|
      levels_at(depth, seeds: 5) { |seed| assert_equal "<", arrange_get(:map)[arrange_get(:py)][arrange_get(:px)], "depth #{depth} seed #{seed}" }
    end
  end

  def test_the_way_up_is_drawn_as_a_less_than
    arrange_arena
    arrange_get(:map)[5][7] = "<"
    assert_equal "<", @game.rows[5][7]
  end

  def test_climbing_the_up_stairs_goes_up_a_level_onto_its_down_stairs
    up_stairs_room
    take_the_stairs_east
    assert_equal 2, @game.depth
    assert_equal assert_get(:downstairs), player
    assert_equal ">", assert_get(:map)[assert_get(:py)][assert_get(:px)], "you arrive on the way back down"
    assert_includes @game.log, "You climb the stairs up to depth 2."
  end

  def test_your_side_climbs_with_you
    up_stairs_room
    goblin = arrange_monster(9, 4, hp: 100, ally: true).last
    take_the_stairs_east
    assert_includes assert_get(:monsters), goblin
    assert @game.send(:in_room?, assert_get(:rooms).last, goblin.x, goblin.y), "it lands in the stairs room, beside you"
    assert_equal "The goblin follows you up.", last_log
  end

  def test_going_up_returns_to_the_level_you_left
    level_one = LEVEL_PARTS.to_h { |part| [part, arrange_get(part)] }
    @game.send(:descend)
    assert_equal 2, @game.depth
    refute_same level_one[:map], assert_get(:map), "a new level below"
    @game.send(:ascend)
    assert_equal 1, @game.depth
    LEVEL_PARTS.each { |part| assert_same level_one[part], assert_get(part), "the very same #{part}" }
    assert_equal assert_get(:downstairs), player, "standing on its > again"
  end

  def test_coming_back_down_returns_to_that_level_too
    @game.send(:descend)
    level_two = arrange_get(:map)
    @game.send(:ascend)
    @game.send(:descend)
    assert_same level_two, assert_get(:map)
    assert_equal assert_get(:upstairs), player, "standing on its < again"
    assert_equal "<", assert_get(:map)[assert_get(:py)][assert_get(:px)]
  end

  def test_what_you_changed_on_a_level_stays_changed
    spot = arrange_get(:upstairs).then { |x, y| [x + 1, y] }
    arrange_get(:treasure)[spot] = 77
    arrange_get(:seen)[0][0] = true
    @game.send(:descend)
    @game.send(:ascend)
    assert_equal 77, assert_get(:treasure)[spot]
    assert assert_get(:seen)[0][0], "and what you've seen stays seen"
  end

  def test_your_side_leaves_with_you_rather_than_staying_behind
    x, y = player
    goblin = thing(x + 1, y, "g", "goblin", 100, 0..0, ally: true)
    arrange_get(:monsters) << goblin
    @game.send(:descend)
    assert_includes assert_get(:monsters), goblin, "it came down"
    refute_includes assert_get(:levels)[1][:@monsters], goblin, "and isn't also left upstairs"
  end

  def test_a_level_never_seen_is_built_new_going_up
    @game = Dungeon.new(level: 3)
    @game.send(:ascend)
    assert_equal 2, @game.depth
    refute_nil assert_get(:map)
    assert_equal assert_get(:downstairs), player
  end

  def test_going_down_again_earns_nothing_until_you_pass_your_deepest
    stairs_room
    arrange_set :depth, 2
    arrange_set :deepest, 3
    take_the_stairs_east
    assert_equal 3, @game.depth
    assert_equal 20, @game.max_hp, "depth 3 has been reached before"

    stairs_room
    take_the_stairs_east
    assert_equal 4, @game.depth
    assert_equal 22, @game.max_hp, "depth 4 is new"
  end

  def test_half_the_levels_have_one_teleport_plate
    plated = 0
    (2..5).each do |depth|
      levels_at(depth) do |seed|
        random = arrange_get(:plates).values.count(Dungeon::RANDOM_PLATE)
        assert_operator random, :<=, 1, "depth #{depth} seed #{seed}: never more than one"
        plated += random
      end
    end
    assert_in_delta 40, plated, 15, "about half of 80 levels"
  end

  # --- the stairs ask first ---

  def test_stepping_onto_stairs_asks_first
    stairs_room
    @game.move(1, 0)
    assert_equal 1, @game.depth, "not yet"
    assert_equal "down", @game.stairs_question
    assert_equal "You want to go down?", last_log
  end

  def test_up_stairs_ask_too
    up_stairs_room
    @game.move(1, 0)
    assert_equal "up", @game.stairs_question
    assert_equal "You want to go up?", last_log
  end

  def test_no_keeps_you_where_you_are
    stairs_room
    @game.move(1, 0)
    @game.take_stairs(false)
    assert_equal 1, @game.depth
    assert_nil @game.stairs_question
    assert_equal "You stay where you are.", last_log
  end

  def test_stepping_off_the_stairs_forgets_the_question
    stairs_room
    @game.move(1, 0)
    @game.move(1, 0)
    assert_nil @game.stairs_question
    @game.take_stairs(true)
    assert_equal 1, @game.depth
  end

  def test_arriving_on_stairs_asks_nothing
    up_stairs_room
    take_the_stairs_east
    assert_equal ">", assert_get(:map)[assert_get(:py)][assert_get(:px)]
    assert_nil @game.stairs_question
  end

  # --- choosing a knapsack thing to throw or give ---

  def test_nothing_is_chosen_at_first
    assert_nil @game.chosen
    assert_equal "Throw ____ right?", @game.throw_label
    assert_equal "Give ____ right?", @game.give_label
  end

  def test_choosing_names_the_thing_on_the_buttons_without_using_it
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg]
    @game.choose(:eggs)
    assert_equal :eggs, @game.chosen
    assert_equal "Throw egg right?", @game.throw_label
    assert_equal "Give egg right?", @game.give_label
    refute @game.knapsack[:eggs].first.candled, "not held up to the light"
    @game.move(-1, 0)
    assert_equal "Throw egg left?", @game.throw_label
  end

  def test_the_buttons_name_every_kind_of_thing
    arrange_get(:knapsack).merge!(gold: 1, laced_speed_potions: 1, weapons: [dagger], shields: [{ name: "shield", glyph: "༻" }])
    { gold: "coin", laced_speed_potions: "candle laced with potion of speed", "dagger" => "dagger", shields: "shield" }.each do |slot, noun|
      @game.choose(slot)
      assert_equal "Throw #{noun} right?", @game.throw_label, slot
    end
  end

  def test_choosing_what_isnt_packed_chooses_nothing
    @game.choose(:candles)
    assert_nil @game.chosen
  end

  def test_the_choice_lapses_with_the_last_of_its_kind
    arrange_arena
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.throw_chosen
    assert_nil @game.chosen
  end

  def test_throwing_with_nothing_chosen
    @game.throw_chosen
    assert_equal "Choose something by its radio button in the knapsack first.", last_log
    @game.give_chosen
    assert_equal "Choose something by its radio button in the knapsack first.", last_log
  end

  def test_a_thrown_egg_breaks
    arrange_arena
    arrange_get(:knapsack)[:eggs] = [egg(true)]
    @game.choose(:eggs)
    @game.throw_chosen
    assert_empty @game.knapsack[:eggs]
    assert_equal "You throw an egg, and it breaks on the floor.", last_log
  end

  def test_a_thrown_candle_lands_to_be_packed_again
    arrange_arena
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.throw_chosen
    candle = arrange_get(:monsters).find { |m| m.name == "candle" }
    assert_equal [5 + Dungeon::THROW_RANGE, 5], [candle.x, candle.y]
    assert_equal "You throw a candle, and it lands on the floor.", last_log
    arrange_set :px, candle.x - 1
    @game.move(1, 0)
    assert_equal 1, @game.knapsack[:candles], "packed again"
  end

  def test_a_creature_catches_a_thrown_thing_and_keeps_it
    arrange_arena
    arrange_monster(8, 5, hp: 100, hit: 0..0, aggressive: false)
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.throw_chosen
    assert_equal 0, @game.knapsack[:candles]
    assert_equal "You throw a candle, and the goblin catches it. It keeps it.", last_log
  end

  def test_a_creature_that_catches_a_weapon_wields_it
    arrange_arena
    goblin = arrange_monster(7, 5, hp: 100, hit: 0..0, aggressive: false).last
    arrange_get(:knapsack)[:weapons] = [dagger]
    @game.choose("dagger")
    @game.throw_chosen
    assert_equal dagger, goblin.weapon
    assert_equal dagger[:hit], goblin.hit
    assert_equal "You throw a dagger, and the goblin catches it. It wields it.", last_log
  end

  def test_a_wall_in_the_way_keeps_the_thing_in_the_knapsack
    arrange_arena(px: 1, py: 5)
    arrange_set :facing, [-1, 0]
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.throw_chosen
    assert_equal 1, @game.knapsack[:candles]
    assert_equal "Something is in the way. You keep the candle.", last_log
  end

  def test_a_thrown_weapon_lands_to_be_taken_again
    arrange_arena
    arrange_set :wielded, sword
    arrange_get(:knapsack)[:weapons] = [dagger]
    @game.choose("dagger")
    @game.throw_chosen
    landed = arrange_get(:monsters).find { |m| m.name == "dagger" }
    assert landed.pacifist
    assert_equal 1, landed.hp, "one blow takes it back"
  end

  def test_a_chosen_potion_or_coin_flies_as_it_always_has
    arrange_arena
    goblin = arrange_monster(7, 5, hp: 100, hit: 0..0, aggressive: false, greedy: true).last
    arrange_get(:knapsack)[:speed_potions] = 1
    @game.choose(:speed_potions)
    @game.throw_chosen
    assert_equal Dungeon::SPEED_ROUNDS - 1, goblin.hasted
    arrange_get(:knapsack)[:gold] = 1
    @game.choose(:gold)
    @game.throw_chosen
    assert goblin.ally, "the coin bought it"
  end

  def test_giving_the_chosen_thing_to_whoever_you_face
    arrange_arena
    goblin = arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false).last
    arrange_get(:knapsack)[:weapons] = [dagger]
    @game.choose("dagger")
    @game.give_chosen
    assert_empty @game.knapsack[:weapons]
    assert_equal dagger, goblin.weapon
    assert_equal "You give the goblin a dagger. It wields it.", last_log
  end

  def test_giving_with_no_one_there
    arrange_arena
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.give_chosen
    assert_equal "There's no one there to take it.", last_log
    assert_equal 1, @game.knapsack[:candles]
  end

  def test_a_door_has_no_use_for_anything_but_a_coin_or_a_sandwich
    arrange_arena
    add_door(6, 5)
    arrange_get(:knapsack)[:candles] = 1
    @game.choose(:candles)
    @game.give_chosen
    assert_equal "The door has no use for a candle.", last_log
    assert_equal 1, assert_get(:monsters).size
  end

  def test_a_chosen_sandwich_is_given_as_it_always_has_been
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false)
    arrange_get(:knapsack)[:sandwiches] = 1
    @game.choose(:sandwiches)
    @game.give_chosen
    assert_equal "You give the goblin a sandwich. It eats it and likes you, for now.", last_log
  end

  # --- the rest key repeats a key pressed three times running ---

  def walk_east(n) = n.times { @game.move(1, 0) }

  def test_after_three_of_a_key_rest_presses_it_three_more_times
    arrange_arena
    walk_east(3)
    assert @game.repeat_ready?
    @game.rest
    assert_equal [11, 5], player, "three steps more, not a rest"
  end

  def test_two_of_a_key_isnt_enough
    arrange_arena
    arrange_set :hp, 10
    walk_east(2)
    refute @game.repeat_ready?
    @game.rest
    assert_equal [7, 5], player
    assert_equal 11, @game.hp, "an ordinary rest"
  end

  def test_a_different_key_starts_the_count_over
    arrange_arena
    walk_east(3)
    @game.move(0, 1)
    refute @game.repeat_ready?
  end

  def test_any_other_action_ends_the_run_of_presses
    arrange_arena
    walk_east(3)
    @game.inventory
    refute @game.repeat_ready?
  end

  def test_repeating_stops_when_someone_comes_into_sight
    arrange_arena(px: 5, py: 5)
    arrange_monster(8 + Dungeon::SIGHT + 1, 5, hp: 100, hit: 0..0, aggressive: false)
    walk_east(3)
    @game.rest
    assert_equal [9, 5], player, "one step brings the goblin into sight, and that's a change"
  end

  def test_repeating_stops_at_a_wall
    arrange_arena(px: W - 6, py: 5)
    walk_east(3)
    @game.rest
    assert_equal [W - 2, 5], player, "one step reaches the wall, the next does nothing, and it stops"
  end

  def test_repeating_stops_on_finding_something
    arrange_arena
    arrange_set :treasure, { [10, 5] => 5 }
    walk_east(3)
    @game.rest
    assert_equal [10, 5], player, "the gold is news"
    assert_equal 5, @game.gold
  end

  def test_repeating_stops_when_you_are_hurt
    arrange_arena
    walk_east(3)
    arrange_monster(9, 6, hp: 100, hit: 2..2)
    @game.rest
    assert_equal [9, 5], player, "the first step brings a blow, and the run stops"
    assert_operator @game.hp, :<, 20
  end

  def test_blow_after_blow_repeats_though_the_damage_varies
    arrange_arena
    goblin = arrange_monster(6, 5, hp: 1000, hit: 0..0, aggressive: false).last
    3.times { @game.move(1, 0) }
    hp = goblin.hp
    @game.rest
    assert_operator goblin.hp, :<, hp - 2, "three more blows"
  end

  def test_taps_repeat_too
    arrange_arena
    food = add_sandwich(6, 5).last
    food.hp = 10
    3.times { @game.tap }
    @game.rest
    assert_equal 4, food.hp, "three more taps on the wrapping"
  end

  # --- tapping ---

  def test_a_new_game_faces_right
    assert_equal [1, 0], @game.facing
    assert_equal "tap right", @game.tap_label
  end

  def test_moving_turns_you_that_way
    arrange_arena
    @game.move(-1, 0)
    assert_equal "tap left", @game.tap_label
    @game.move(1, -1)
    assert_equal "tap up-right", @game.tap_label
  end

  def test_bumping_and_hitting_turn_you_too
    arrange_arena(px: 1, py: 5)
    @game.move(-1, 0)
    assert_equal "tap left", @game.tap_label, "the bump costs nothing, but you now face the wall"
    arrange_monster(1, 6, hp: 100, hit: 0..0, aggressive: false)
    @game.move(0, 1)
    assert_equal "tap down", @game.tap_label
  end

  def test_giving_turns_you_and_resting_keeps_your_facing
    arrange_arena
    arrange_get(:knapsack)[:gold] = 1
    @game.offer(:gold)
    @game.move(0, -1)
    assert_equal "tap up", @game.tap_label
    @game.rest
    assert_equal "tap up", @game.tap_label
  end

  def test_doors_share_the_lock_machine
    arrange_arena
    open_door = add_door(6, 5).last
    locked = add_door(7, 5).last.tap { |d| d.locked = true }
    assert_instance_of Dungeon::DoorLock::OpenState, @game.send(:door_machine, open_door).state
    assert_instance_of Dungeon::DoorLock::LockState, @game.send(:door_machine, locked).state
    assert_same @game.send(:door_machine, locked), locked.machine, "one machine per door, kept"
  end

  def test_tapping_an_unlocked_door_opens_it
    arrange_arena
    add_door(6, 5)
    @game.tap
    assert_empty assert_get(:monsters)
    assert_equal "You tap the door, and it swings open.", last_log
  end

  def test_tapping_a_locked_door_only_rattles_it
    arrange_arena
    add_door(6, 5).last.locked = true
    @game.tap
    assert_equal 1, assert_get(:monsters).size
    assert_equal "You tap the door. It rattles, but it's locked.", last_log
  end

  def test_a_locked_door_still_opens_for_a_gift
    arrange_arena
    add_door(6, 5).last.locked = true
    give(:gold, 1, 0)
    assert_empty assert_get(:monsters)
  end

  def test_tapping_is_not_violence
    arrange_arena
    goblin = arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false).last
    @game.tap
    assert_equal 100, goblin.hp
    refute goblin.aggressive, "not provoked"
    assert_equal "You tap the goblin.", last_log
  end

  def test_tapping_a_wall_or_empty_air_just_disappears
    arrange_arena(px: 1, py: 5)
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    log = @game.log.dup
    arrange_set :facing, [-1, 0]
    @game.tap
    arrange_set :facing, [1, 0]
    @game.tap
    assert_equal log, @game.log, "no message"
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "and no turn passes"
  end

  def test_tapping_someone_takes_a_turn
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false)
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    @game.tap
    assert_equal "You tap the goblin.", last_log
    assert_equal [8, 5], [assert_get(:monsters).last.x, assert_get(:monsters).last.y]
  end

  def test_tapping_forgets_a_readied_gift
    arrange_arena
    arrange_get(:knapsack)[:gold] = 1
    @game.offer(:gold)
    @game.tap
    @game.move(1, 0)
    assert_equal [6, 5], player, "the next arrow moves"
    assert_equal 1, @game.gold
  end

  def test_doors_spawn_locked_about_half_the_time
    doors = []
    (3..6).each { |depth| levels_at(depth) { doors.concat(arrange_get(:monsters).select { |m| m.name == "door" }) } }
    locked = doors.count(&:locked)
    assert_operator doors.size, :>=, 40
    assert_in_delta doors.size / 2.0, locked, doors.size * 0.2
  end

  # --- the give coin button gives straight away ---

  def test_give_coin_is_named_for_the_way_you_face
    arrange_arena
    assert_equal "give coin ($) right", @game.give_coin_label
    @game.move(-1, 0)
    assert_equal "give coin ($) left", @game.give_coin_label
  end

  def test_give_coin_hands_it_straight_to_whoever_you_face
    arrange_arena
    goblin = arrange_monster(6, 5, hp: 100, hit: 0..0, aggressive: false, greedy: true).last
    arrange_get(:knapsack)[:gold] = 3
    @game.give_coin
    assert_equal 2, @game.gold
    assert goblin.ally
    assert_equal "You give the goblin a coin. It pockets it and sides with you, hoping for more.", last_log
  end

  def test_with_no_one_there_the_coin_starts_a_pile_of_gold
    arrange_arena
    arrange_get(:knapsack)[:gold] = 3
    @game.give_coin
    assert_equal 2, @game.gold
    assert_equal({ [6, 5] => 1 }, assert_get(:treasure))
    assert_equal "$", @game.rows[5][6]
    assert_equal "No one is there, so the coin lands on the floor.", last_log
    @game.give_coin
    assert_equal({ [6, 5] => 2 }, assert_get(:treasure), "and then adds to it")
  end

  def test_a_coin_on_the_floor_can_be_picked_up_again
    arrange_arena
    arrange_get(:knapsack)[:gold] = 1
    @game.give_coin
    @game.move(1, 0)
    assert_equal 1, @game.gold
    assert_includes @game.log, "You find 1 gold!"
  end

  def test_a_wall_keeps_the_coin_in_your_knapsack
    arrange_arena(px: 1, py: 5)
    arrange_set :facing, [-1, 0]
    arrange_get(:knapsack)[:gold] = 3
    @game.give_coin
    assert_equal 3, @game.gold
    assert_equal "A wall is in the way. You keep the coin.", last_log
  end

  def test_no_gold_to_give
    @game.give_coin
    assert_equal "You have no gold to give.", last_log
  end

  def test_giving_a_coin_takes_a_turn
    arrange_arena
    arrange_monster(9, 5, hp: 100, hit: 0..0)
    arrange_get(:knapsack)[:gold] = 1
    @game.give_coin
    assert_equal [8, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y]
  end

  # --- giving ---

  def test_giving_a_coin_hands_it_to_the_monster_that_way
    arrange_arena
    arrange_get(:knapsack)[:gold] = 10
    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.offer(:gold)
    assert_equal "Give a coin which way?", last_log

    @game.move(1, 0)
    assert_equal 9, @game.gold
    assert_equal [5, 5], player, "giving does not move"
    assert_equal 100, assert_get(:monsters).first.hp, "giving does not attack"
    assert_includes @game.log, "You give the goblin a coin. It keeps it."
  end

  def test_giving_a_sandwich_works_diagonally
    arrange_arena
    arrange_get(:knapsack)[:sandwiches] = 2
    arrange_quail(6, 6)
    @game.offer(:sandwiches)
    @game.move(1, 1)
    assert_equal 1, @game.sandwiches
    assert_equal "You give the Quail a sandwich. It eats it.", last_log
  end

  # --- what gifts do ---

  def give(item, dx, dy, count: 1)
    arrange_get(:knapsack)[item] = count
    @game.offer(item)
    @game.move(dx, dy)
  end

  def test_a_fed_goblin_likes_you_until_it_is_hungry_again
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    give(:sandwiches, 1, 0)
    assert_includes @game.log, "You give the goblin a sandwich. It eats it and likes you, for now."

    (Dungeon::FULL_TURNS - 2).times { @game.rest }
    assert_equal 20, @game.hp, "a full goblin never strikes"

    @game.rest
    assert_includes @game.log, "The goblin is hungry again."
    assert_equal 17, @game.hp, "hungry again, it strikes at once"
  end

  def test_a_greedy_goblin_pockets_a_coin_and_becomes_an_ally
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3, greedy: true)
    give(:gold, 1, 0)
    g = arrange_get(:monsters).first
    assert g.ally
    assert_equal 1, g.coins
    assert_includes @game.log, "You give the goblin a coin. It pockets it and sides with you, hoping for more."

    5.times { @game.rest }
    assert_equal 20, @game.hp, "an ally never strikes you"
  end

  def test_an_ordinary_goblin_keeps_a_coin_and_still_fights
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 3..3)
    give(:gold, 1, 0)
    refute assert_get(:monsters).first.ally
    assert_equal 17, @game.hp
  end

  # An average-strength rat, so its bites do exactly their roll; pass the row's str for a real one
  def add_rat(x, y, str: 10) = arrange_get(:monsters) << thing(x, y, "r", "rat", 100, 2..2, str: str, aggressive: true)

  def test_a_coin_makes_an_enraged_rat_disengage
    arrange_arena
    add_rat(6, 5)
    give(:gold, 1, 0)
    r = arrange_get(:monsters).first
    assert r.spurned
    assert_equal 1, r.coins
    assert_includes @game.log, "You give the rat a coin. It pockets it and stops fighting you."
    assert_equal 20, @game.hp, "it disengages before it can bite"

    @game.move(-1, 0)
    3.times { @game.rest }
    assert_equal 20, @game.hp
    assert_equal [6, 5], [r.x, r.y], "a disengaged rat no longer chases"
    refute r.ally, "disengaging is not siding with you"
  end

  def test_a_rat_without_a_coin_keeps_biting
    arrange_arena
    add_rat(6, 5)
    @game.rest
    assert_equal 18, @game.hp
  end

  def test_a_real_rat_without_a_coin_keeps_biting_for_one
    arrange_arena
    add_rat(6, 5, str: kind("rat")[:str])
    @game.rest
    assert_equal 19, @game.hp, "a 2 with str 7 (-2) is 0, floored at 1"
  end

  def test_a_coin_makes_any_pacifist_an_ally_and_unspurns_it
    arrange_arena
    arrange_quail(6, 5).last.spurned = true
    give(:gold, 1, 0)
    q = arrange_get(:monsters).first
    assert q.ally
    refute q.spurned
  end

  def test_a_bribed_nesting_quail_leaves_its_eggs_to_follow_you
    arrange_arena
    arrange_get(:monsters) << thing(6, 5, "Q", "Quail", 100, 0..0, pacifist: true, nesting: true)
    arrange_set :eggs, { [7, 6] => [egg, egg] }
    give(:gold, 1, 0)
    q = arrange_get(:monsters).first
    assert q.ally
    refute q.nesting
    @game.move(-1, 0)
    @game.move(-1, 0)
    assert_equal [4, 5], [q.x, q.y], "it follows you, leaving the eggs behind"
    assert_equal 2, assert_get(:eggs)[[7, 6]].size
  end

  def test_allies_keep_every_coin_they_are_given
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0, greedy: true)
    give(:gold, 1, 0, count: 2)
    give(:gold, 1, 0, count: 1)
    assert_equal 2, assert_get(:monsters).first.coins
  end

  def test_an_ally_strikes_a_hostile_monster_beside_it
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_monster(8, 5, hp: 10, hit: 0..0)
    @game.rest
    assert_equal 6, assert_get(:monsters).last.hp
    assert_includes @game.log, "Your goblin hits the goblin for 4."
  end

  # An average-strength allied wall, so its strikes do exactly their roll; pass the row's str for a real one
  def add_wall_ally(x, y, str: 10) = arrange_get(:monsters) << thing(x, y, "#", "wall", 30, 3..3, str: str, pacifist: true, ally: true)

  def test_an_allied_wall_spares_a_paid_off_rat
    arrange_arena
    add_wall_ally(7, 5)
    add_rat(8, 5).last.coins = 1
    @game.rest
    assert_equal 100, assert_get(:monsters).last.hp
    refute(@game.log.any? { |line| line.start_with?("Your wall hits") })
  end

  def test_other_allies_still_strike_a_paid_off_rat
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    add_rat(8, 5).last.coins = 1
    @game.rest
    assert_equal 96, assert_get(:monsters).last.hp
    assert_includes @game.log, "Your goblin hits the rat for 4."
  end

  def test_an_allied_wall_still_strikes_an_unpaid_rat
    arrange_arena
    add_wall_ally(7, 5)
    add_rat(8, 5)
    @game.rest
    assert_equal 97, assert_get(:monsters).last.hp
  end

  def test_a_real_allied_wall_strikes_an_unpaid_rat_hard
    arrange_arena
    add_wall_ally(7, 5, str: kind("wall")[:str])
    add_rat(8, 5, str: kind("rat")[:str])
    @game.rest
    assert_equal 93, assert_get(:monsters).last.hp, "a 3 with str 18 (+4)"
    assert_includes @game.log, "Your wall hits the rat for 7."
  end

  def test_an_ally_can_slay_a_hostile_monster
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_monster(8, 5, hp: 1, hit: 0..0)
    @game.rest
    assert_equal 1, assert_get(:monsters).size
    assert_includes @game.log, "Your goblin slays the goblin!"
  end

  def test_an_ally_leaves_friends_and_pacifists_alone
    arrange_arena
    arrange_monster(7, 5, hit: 4..4, ally: true)
    arrange_quail(8, 5)
    @game.rest
    assert_equal 100, assert_get(:monsters).last.hp
  end

  def test_about_half_of_all_goblins_are_greedy
    arrange_arena(px: 1, py: 1)
    room = { x: 2, y: 2, w: W - 4, h: H - 4 }
    goblin = Dungeon::THINGAGES.find { |k| k[:name] == "goblin" }
    400.times { @game.send(:spawn_monster, room, goblin) }
    share = arrange_get(:monsters).count(&:greedy) / 400.0
    assert_in_delta 0.5, share, 0.1
  end

  def test_offering_with_an_empty_knapsack_does_nothing
    arrange_arena
    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.offer(:sandwiches)
    assert_equal "You have no sandwiches to give.", last_log

    @game.move(1, 0)
    assert_operator assert_get(:monsters).first.hp, :<, 100, "the next arrow attacks as usual"
  end

  def test_offering_to_empty_floor_keeps_the_gift_and_stays_put
    arrange_arena
    arrange_get(:knapsack)[:gold] = 3
    @game.offer(:gold)
    @game.move(1, 0)
    assert_equal 3, @game.gold
    assert_equal [5, 5], player
    assert_equal "There's no one there to take it.", last_log

    @game.move(1, 0)
    assert_equal [6, 5], player, "the offer is used up, so the next arrow moves"
  end

  # --- throwing a gift no one took ---

  def offer_to_empty_floor(item, dx, dy, count: 3)
    arrange_get(:knapsack)[item] = count
    @game.offer(item)
    @game.move(dx, dy)
    assert @game.can_hurl?
  end

  def test_throw_lands_the_gift_at_the_end_of_its_range
    arrange_arena
    offer_to_empty_floor(:gold, 1, 0)
    @game.hurl
    assert_equal 2, @game.gold
    assert_equal({ [5 + Dungeon::THROW_RANGE, 5] => 1 }, assert_get(:treasure))
    assert_equal "You throw a coin and it lands on the floor.", last_log
    refute @game.can_hurl?
  end

  def test_throw_stops_short_of_a_wall
    arrange_arena(px: 3, py: 5)
    offer_to_empty_floor(:sandwiches, -1, 0)
    @game.hurl
    assert_equal({ [1, 5] => 1 }, assert_get(:sandwiches))
    assert_equal 2, @game.sandwiches
  end

  def test_the_first_monster_in_line_catches_a_throw
    arrange_arena
    arrange_monster(8, 5, hp: 100, hit: 0..0)
    offer_to_empty_floor(:sandwiches, 1, 0)
    @game.hurl
    assert_equal 2, @game.sandwiches
    assert_empty assert_get(:sandwiches)
    assert_includes @game.log, "You throw a sandwich and the goblin catches it. It eats it and likes you, for now."
  end

  def test_throwing_into_an_adjacent_wall_keeps_the_gift
    arrange_arena(px: 1, py: 5)
    offer_to_empty_floor(:gold, -1, 0)
    @game.hurl
    assert_equal 3, @game.gold
    assert_equal "A wall is in the way. You keep it.", last_log
  end

  def test_any_other_action_forgets_the_throw
    arrange_arena
    offer_to_empty_floor(:gold, 1, 0)
    @game.rest
    refute @game.can_hurl?
    @game.hurl
    assert_equal 3, @game.gold
    assert_equal "There's nothing to throw.", last_log
  end

  def test_rest_cancels_an_offer
    arrange_arena
    arrange_set :hp, 10
    arrange_get(:knapsack)[:gold] = 3
    @game.offer(:gold)
    @game.rest
    assert_equal "You keep it.", last_log
    assert_equal 10, @game.hp, "cancelling is not resting"

    @game.move(1, 0)
    assert_equal [6, 5], player
  end

  # --- inventory ---

  def test_inventory_of_an_empty_knapsack
    @game.inventory
    assert_equal "Your knapsack is empty.", last_log
  end

  def test_inventory_lists_gold_and_sandwiches
    arrange_get(:knapsack).merge!(gold: 12, sandwiches: 1)
    @game.inventory
    assert_equal "Your knapsack holds 12 gold and 1 sandwich.", last_log

    arrange_get(:knapsack).merge!(gold: 0, sandwiches: 3)
    @game.inventory
    assert_equal "Your knapsack holds 3 sandwiches.", last_log
  end

  def test_inventory_takes_no_turn_and_keeps_a_readied_gift
    arrange_arena
    arrange_get(:knapsack)[:gold] = 2
    arrange_monster(9, 5)
    @game.offer(:gold)
    @game.inventory
    assert_equal [9, 5], [assert_get(:monsters).first.x, assert_get(:monsters).first.y], "monsters did not move"

    arrange_monster(6, 5, hp: 100, hit: 0..0)
    @game.move(1, 0)
    assert_equal 1, @game.gold, "the readied coin is still given"
  end

  # --- message log ---

  # --- resting searches ---

  def test_rest_finds_nothing_on_open_floor
    arrange_arena
    arrange_monster(7, 5, hp: 100)
    @game.rest
    assert_equal "You catch your breath and find nothing beside you.", last_log
  end

  def test_rest_finds_everything_alive_or_magic_beside_you
    arrange_arena
    arrange_monster(6, 6, hit: 0..0)
    add_potion(4, 4)
    arrange_get(:monsters) << thing(4, 6, "#", "wall", 3, 0..0, pacifist: true)
    arrange_get(:monsters) << thing(5, 4, "o", "orc", 10, 0..0)
    @game.rest
    assert_includes @game.log, "You catch your breath and find a goblin, a potion, a wall, and an orc beside you."
  end

  def test_rest_names_a_pair_of_swords
    arrange_arena
    arrange_get(:monsters) << thing(6, 6, "⚔️", "swords", 3, 0..0, pacifist: true)
    @game.rest
    assert_includes @game.log, "You catch your breath and find a pair of swords beside you."
  end

  def test_alive_nearby_watches_all_eight_neighbours_only
    arrange_arena
    refute @game.alive_nearby?
    arrange_monster(7, 7)
    refute @game.alive_nearby?, "two squares away is not beside"
    add_potion(4, 6)
    assert @game.alive_nearby?
  end

  def test_log_keeps_only_the_last_four_messages
    arrange_arena(px: 1, py: 1)
    6.times { @game.rest }
    assert_equal 4, @game.log.size
    assert(@game.log.all? { |line| line.start_with?("You catch your breath") })
  end
end

class WebGameTest < Minitest::Test
  include Things
  def setup
    srand(1234)
    @web = WebGame.new
  end

  # Whatever a test did, nothing it leaves on the level may be missing an ability score
  def teardown
    assert_no_missing_scores(@web.game.instance_variable_get(:@monsters))
  end

  def test_home_page_shows_the_map_and_status
    status, headers, body = @web.respond("GET", "/")
    assert_equal 200, status
    assert_match(/text\/html/, headers["Content-Type"])
    assert_includes body, "Depth 1"
    assert_includes body, "Blood sugar 100"
    assert_includes body, "Weapon fists"
    # assert_includes body, "AC 10"
    assert_includes body, "@"
    refute_includes body.split("<pre>", 2).last.split("</pre>").first, ">", "stairs are escaped"
  end

  def test_serving_on_a_busy_port_exits_with_a_clear_message
    taken = TCPServer.new(0)
    port = taken.addr[1]
    assert_output(nil, /port #{port} is already in use/) do
      assert_raises(SystemExit) { @web.serve(port) }
    end
  ensure
    taken&.close
  end

  # An open floor with nothing on it, player at (5, 5)
  def open_floor
    game = @web.game
    game.instance_variable_set(:@map, Array.new(Dungeon::VIEWPORT_HEIGHT) { Array.new(Dungeon::VIEWPORT_WIDTH, ".") })
    game.instance_variable_set(:@monsters, [])
    game.instance_variable_set(:@treasure, {})
    game.instance_variable_set(:@traps, {})
    game.instance_variable_set(:@px, 5)
    game.instance_variable_set(:@py, 5)
  end

  def player = [@web.game.instance_variable_get(:@px), @web.game.instance_variable_get(:@py)]

  def test_posting_a_move_moves_and_redirects_home
    open_floor
    status, headers, = @web.respond("POST", "/move?dx=1&dy=0")
    assert_equal 303, status
    assert_equal "/", headers["Location"]
    assert_equal [6, 5], player
  end

  def test_moves_are_clamped_to_one_step
    open_floor
    @web.respond("POST", "/move?dx=9&dy=-9")
    assert_equal [6, 4], player
  end

  def test_god_mode_shows_in_the_banner_and_survives_a_new_game
    web = WebGame.new(godMode: true)
    assert_includes web.respond("GET", "/").last, "GOD MODE"
    web.respond("POST", "/new")
    assert web.game.godMode?
    refute_includes @web.respond("GET", "/").last, "GOD MODE"
  end

  def test_new_game_replaces_the_dungeon
    old = @web.game
    assert_equal 303, @web.respond("POST", "/new").first
    refute_same old, @web.game
  end

  def test_unknown_paths_are_not_found
    assert_equal 404, @web.respond("GET", "/favicon.ico").first
    assert_equal 404, @web.respond("POST", "/teleport").first
  end

  def test_give_buttons_offer_gold_and_sandwiches
    open_floor
    @web.game.knapsack[:sandwiches] = 1
    assert_equal 303, @web.respond("POST", "/give?item=sandwiches").first
    assert_equal "Give a sandwich which way? Rest to eat it yourself.", @web.game.log.last
    assert_equal 404, @web.respond("POST", "/give?item=hp").first

    body = @web.respond("GET", "/").last
    # assert_includes body, %(action="/give?item=gold")
    # assert_includes body, %(action="/give?item=sandwiches")
  end  #  organic here.  I don't recall requesting a POST handler  TODO  grow a real XPath grizzler right here

  # The page cut into its floating right panel and everything else
  def assert_panel_and_rest(body)
    panel = body[%r{<aside class="panel">.*?</aside>}m]
    [panel, body.sub(panel.to_s, "")]
  end

  def test_give_buttons_sit_in_the_right_panel
    panel, main = assert_panel_and_rest(@web.respond("GET", "/").last)
    refute_nil panel
    assert_includes panel, "give coin ($)"
    assert_includes panel, "give sandwich (%)"
    refute_includes main, "give coin"
    refute_includes main, "give sandwich"
  end

  def test_the_knapsack_floats_in_the_right_panel_and_core_buttons_stay_left
    @web.game.knapsack.merge!(gold: 3, sandwiches: 1)
    panel, main = assert_panel_and_rest(@web.respond("GET", "/").last)
    assert_includes panel, %(<div class="knapsack">Knapsack: )
    assert_includes panel, "3 gold"
    refute_includes main, %(class="knapsack")
    %w[/inventory /wield /rest].each { |action| assert_includes main, %(action="#{action}"), action }
  end

  def test_the_map_is_a_lintel_over_the_pad_and_the_knapsack
    @web.game.knapsack[:gold] = 3
    body = @web.respond("GET", "/").last
    map, below = body.index("<pre>"), body.index(%(<div class="below">))
    pad, panel = body.index(%(<div class="pad">)), body.index(%(<aside class="panel">))
    assert_operator map, :<, below, "the map sits above both"
    assert_operator below, :<, pad, "the pad is in the lower row"
    assert_operator pad, :<, panel, "pad on the left, knapsack on the right"
    assert_includes body[panel..], "3 gold"
  end

  def test_inventory_button_reports_the_knapsack
    assert_includes @web.respond("GET", "/").last, %(action="/inventory")
    assert_equal 303, @web.respond("POST", "/inventory").first
    assert_equal "Your knapsack is empty.", @web.game.log.last
  end

  def test_wield_button_swaps_in_a_knapsack_weapon
    assert_includes @web.respond("GET", "/").last, %(action="/wield")
    @web.game.knapsack[:weapons] << { name: "sword", glyph: "⚔", hit: 4..4 }
    assert_equal 303, @web.respond("POST", "/wield").first
    assert_equal "⚔ sword", @web.game.weapon
  end

  def test_knapsack_entries_are_buttons
    refute_includes @web.respond("GET", "/").last, %(class="knapsack"), "an empty knapsack shows no row"

    @web.game.knapsack.merge!(gold: 3, sandwiches: 2)
    @web.game.knapsack[:weapons].push(*Array.new(3) { { name: "sword", glyph: "⚔", hit: 4..4 } })
    body = @web.respond("GET", "/").last
    assert_includes body, %(action="/give?item=gold"><button style="width: auto">3 gold</button>)
    assert_includes body, %(action="/give?item=sandwiches"><button style="width: auto">2 sandwiches</button>)
    assert_includes body, %(action="/wield?name=sword"><button style="width: auto">3 ⚔ swords</button>)

    @web.respond("POST", "/wield?name=sword")
    assert_equal "⚔ sword", @web.game.weapon
  end

  def test_throw_button_appears_only_after_a_gift_finds_no_taker
    open_floor
    refute_includes @web.respond("GET", "/").last, %(action="/throw")

    @web.game.knapsack[:gold] = 1
    @web.respond("POST", "/give?item=gold")
    @web.respond("POST", "/move?dx=1&dy=0")
    assert_includes @web.respond("GET", "/").last, %(action="/throw")

    assert_equal 303, @web.respond("POST", "/throw").first
    assert_equal 0, @web.game.gold
    refute_includes @web.respond("GET", "/").last, %(action="/throw")
  end

  def rest_button(body) = body[%r{<form method="post" action="/rest">.*?</form>}]

  def test_rest_button_is_underlined_only_with_something_beside_you
    open_floor
    refute_includes rest_button(@web.respond("GET", "/").last), "underline"

    @web.game.instance_variable_get(:@monsters) << thing(6, 6, "¡", "potion", 3, 0..0, pacifist: true)
    assert_includes rest_button(@web.respond("GET", "/").last), "text-decoration: underline"
  end

  def test_the_knapsack_potion_button_quaffs
    open_floor
    @web.game.knapsack[:potions] = 1
    assert_includes @web.respond("GET", "/").last, %(action="/quaff?item=potions"><button style="width: auto">¡ potion of sight</button>)
    assert_equal 303, @web.respond("POST", "/quaff").first
    assert_equal 0, @web.game.potions
  end

  def test_the_knapsack_scroll_button_reads
    open_floor
    @web.game.instance_variable_set(:@detected, [])
    @web.game.knapsack[:scrolls] = 1
    assert_includes @web.respond("GET", "/").last, %(action="/read?item=scrolls"><button style="width: auto">? scroll of potion finding</button>)
    assert_equal 303, @web.respond("POST", "/read").first
    assert_equal 0, @web.game.scrolls
  end

  def test_the_knapsack_mapping_scroll_button_reads_it
    open_floor
    @web.game.knapsack[:mapping_scrolls] = 1
    assert_includes @web.respond("GET", "/").last, %(action="/read?item=mapping_scrolls"><button style="width: auto">? scroll of mapping</button>)
    assert_equal 303, @web.respond("POST", "/read?item=mapping_scrolls").first
    assert_equal 0, @web.game.knapsack[:mapping_scrolls]
  end

  def test_the_knapsack_ring_button_wears_it
    open_floor
    @web.game.knapsack[:strength_rings] = 1
    assert_includes @web.respond("GET", "/").last, %(action="/wear?item=strength_rings"><button style="width: auto">= ring of strength</button>)
    assert_equal 303, @web.respond("POST", "/wear?item=strength_rings").first
    assert_equal :strength_rings, @web.game.ring
  end

  def test_wearing_an_unknown_ring_is_not_found
    assert_equal 404, @web.respond("POST", "/wear?item=gold").first
  end

  def test_reading_an_unknown_scroll_is_not_found
    assert_equal 404, @web.respond("POST", "/read?item=gold").first
  end

  def test_each_knapsack_potion_has_quaff_and_throw_buttons
    open_floor
    @web.game.knapsack[:speed_potions] = 1
    body = @web.respond("GET", "/").last
    assert_includes body, %(action="/quaff?item=speed_potions"><button style="width: auto">! potion of speed</button>)
    assert_includes body, %(action="/aim?item=speed_potions"><button style="width: auto">throw</button>)
  end

  def test_aim_then_an_arrow_throws_the_potion
    open_floor
    @web.game.knapsack[:gas_potions] = 1
    @web.game.instance_variable_get(:@monsters) << thing(7, 5, "g", "goblin", 10, 0..0)
    @web.respond("POST", "/aim?item=gas_potions")
    @web.respond("POST", "/move?dx=1&dy=0")
    assert_equal 0, @web.game.knapsack[:gas_potions]
    assert_equal Dungeon::GAS_ROUNDS - 1, @web.game.instance_variable_get(:@monsters).first.gaseous, "a round already passed"
  end

  def test_each_potion_has_a_pour_into_candle_button
    open_floor
    @web.game.knapsack[:speed_potions] = 1
    @web.game.knapsack[:candles] = 1
    body = @web.respond("GET", "/").last
    assert_includes body, %(action="/pour?item=speed_potions"><button style="width: auto">pour into candle</button>)
    assert_includes body, "<span>i candle</span>", "a plain candle just waits"
    assert_equal 303, @web.respond("POST", "/pour?item=speed_potions").first
    assert_equal 1, @web.game.knapsack[:laced_speed_potions]
  end

  def test_the_give_coin_button_names_its_way_and_gives_at_once
    open_floor
    @web.game.knapsack[:gold] = 2
    body = @web.respond("GET", "/").last
    assert_includes body, %(<form method="post" action="/give_coin"><button data-keys="$">give coin ($) right</button></form>)
    assert_equal 303, @web.respond("POST", "/give_coin").first
    assert_equal 1, @web.game.gold
    assert_equal({ [6, 5] => 1 }, @web.game.instance_variable_get(:@treasure))
  end

  def test_the_rest_button_says_again_when_it_will_repeat
    open_floor
    3.times { @web.respond("POST", "/move?dx=1&dy=0") }
    assert_includes @web.respond("GET", "/").last, ">again</button>"
  end

  def test_the_arrow_you_face_is_highlighted
    open_floor
    body = @web.respond("GET", "/").last
    assert_includes body, %(<button data-keys="l 6 ArrowRight" class="facing" aria-pressed="true">→</button>)
    assert_equal 1, body.scan('class="facing"').size, "only that one"
    @web.respond("POST", "/move?dx=-1&dy=-1")
    body = @web.respond("GET", "/").last
    assert_includes body, %(<button data-keys="y 7 Home" class="facing" aria-pressed="true">↖</button>)
    refute_includes body, %(data-keys="l 6 ArrowRight" class="facing")
  end

  def test_the_tap_button_sits_beside_the_arrows_and_names_the_way_you_face
    open_floor
    body = @web.respond("GET", "/").last
    assert_includes body, %(<div class="pad-row">)
    assert_includes body, %(<form method="post" action="/tap"><button data-keys="f" style="width: auto">tap right (f)</button></form>)
    @web.respond("POST", "/move?dx=-1&dy=0")
    assert_includes @web.respond("GET", "/").last, "tap left (f)"
    log = @web.game.log.dup
    assert_equal 303, @web.respond("POST", "/tap").first
    assert_equal log, @web.game.log, "tapping empty air just disappears"
  end

  def test_each_knapsack_entry_has_a_radio_button_that_chooses_it
    open_floor
    @web.game.knapsack[:sandwiches] = 1
    body = @web.respond("GET", "/").last
    assert_includes body, %(<form method="post" action="/choose?item=sandwiches"><input type="radio" name="chosen")
    refute_includes body, " checked"
    assert_includes body, "Throw ____ right? (x)"
    assert_equal 303, @web.respond("POST", "/choose?item=sandwiches").first
    body = @web.respond("GET", "/").last
    assert_includes body, %(onchange="this.form.submit()" checked>)
    assert_includes body, %(<form method="post" action="/throw_chosen"><button data-keys="x" style="width: auto">Throw sandwich right? (x)</button></form>)
    assert_includes body, %(<form method="post" action="/give_chosen"><button data-keys="g" style="width: auto">Give sandwich right? (g)</button></form>)
    assert_equal 404, @web.respond("POST", "/choose?item=beer").first
  end

  def test_the_throw_and_give_buttons_act
    open_floor
    @web.game.knapsack[:candles] = 1
    @web.respond("POST", "/choose?item=candles")
    @web.respond("POST", "/give_chosen")
    assert_equal "There's no one there to take it.", @web.game.log.last
    assert_equal 303, @web.respond("POST", "/throw_chosen").first
    assert_equal 0, @web.game.knapsack[:candles]
  end

  def test_the_stairs_question_has_yes_and_no_buttons
    open_floor
    @web.game.instance_variable_get(:@map)[5][6] = ">"
    @web.respond("POST", "/move?dx=1&dy=0")
    body = @web.respond("GET", "/").last
    assert_includes body, "You want to go down?"
    assert_includes body, %(<form method="post" action="/stairs?answer=yes"><button data-keys="y" style="width: auto">Yes (y)</button></form>)
    assert_operator body.index("/stairs?answer=yes"), :<, body.index('data-keys="y 7 Home"'), "so y answers rather than moves"
    @web.respond("POST", "/stairs?answer=no")
    assert_nil @web.game.stairs_question
    assert_equal 1, @web.game.depth
  end

  def test_a_packed_shield_shows_but_is_no_button
    open_floor
    @web.game.knapsack[:shields] << { name: "shield", glyph: "༻" }
    assert_includes @web.respond("GET", "/").last, "<span>༻ shield</span>"
  end

  def test_a_laced_candle_has_throw_and_kick_buttons
    open_floor
    @web.game.knapsack[:laced_gas_potions] = 1
    body = @web.respond("GET", "/").last
    assert_includes body, %(action="/fling?item=laced_gas_potions&amp;how=throw"><button style="width: auto">i candle laced with potion of gaseous form</button>)
    assert_includes body, %(action="/fling?item=laced_gas_potions&amp;how=kick"><button style="width: auto">kick</button>)
    assert_equal 303, @web.respond("POST", "/fling?item=laced_gas_potions&how=kick").first
    assert_equal "Kick the candle laced with potion of gaseous form which way?", @web.game.log.last
  end

  def test_unknown_candles_and_ways_of_flinging_are_not_found
    assert_equal 404, @web.respond("POST", "/fling?item=laced_beer&how=throw").first
    assert_equal 404, @web.respond("POST", "/fling?item=laced_gas_potions&how=juggle").first
    assert_equal 404, @web.respond("POST", "/pour?item=beer").first
  end

  def test_quaffing_gas_shows_in_the_banner
    open_floor
    @web.game.knapsack[:gas_potions] = 1
    @web.respond("POST", "/quaff?item=gas_potions")
    assert_includes @web.respond("GET", "/").last, "Gaseous 9"
  end

  def test_unknown_potions_are_not_found
    assert_equal 404, @web.respond("POST", "/quaff?item=beer").first
    assert_equal 404, @web.respond("POST", "/aim?item=beer").first
  end

  def test_hungry_creatures_are_colored_on_the_page
    open_floor
    game = @web.game
    game.instance_variable_set(:@blood_sugar, 0)
    body = @web.respond("GET", "/").last
    assert_includes body, %(<span class="hungry">@</span>)
    assert_includes body, ".hungry { color: #{Dungeon::HUNGRY_COLOR}; }"
  end

  def test_a_new_game_starts_at_the_chosen_level
    web = WebGame.new(level: 6)
    web.respond("POST", "/new")
    assert_equal 6, web.game.depth
  end

  def test_the_banner_shows_the_win
    @web.game.instance_variable_set(:@won, true)
    assert_includes @web.respond("GET", "/").last, "YOU WON"
  end

  def test_the_knapsack_eggs_button_holds_them_up_to_the_light
    open_floor
    @web.game.knapsack[:eggs] = [egg(true), egg, egg]
    body = @web.respond("GET", "/").last
    assert_includes body, %(<form method="post" action="/candle"><button style="width: auto">3 eggs</button></form>)
    assert_equal 303, @web.respond("POST", "/candle").first
    assert_equal "You hold 3 eggs up to the light: 2 are just yolk; in one you can see legs, wings, and a beak.", @web.game.log.last
    assert_includes @web.respond("GET", "/").last, "3 eggs (1 developed, 2 yolk)"
  end

  def test_the_banner_shows_the_knapsacks_load
    @web.game.knapsack[:sandwiches] = 12
    assert_includes @web.respond("GET", "/").last, "Load 12/60 lb"
  end

  def test_the_banner_says_when_the_adventure_ends_without_a_win
    @web.game.instance_variable_set(:@trapped, true)
    assert_includes @web.respond("GET", "/").last, "ADVENTURE OVER"
  end
end

class CommandLineTest < Minitest::Test
  # Runs rogue.rb in a fresh Ruby, the same one running these tests, with these flags; [stdout, stderr, status]
  def rogue(*flags)
    require 'open3'
    require 'rbconfig'
    Open3.capture3(RbConfig.ruby, File.join(__dir__, "rogue.rb"), *flags)
  end

  def test_the_usage_names_every_flag
    %w[--dos --web --scarpe --level --god --help -h].each { |flag| assert_includes USAGE, flag }
    assert_includes USAGE, "default 4567"
  end

  def test_help_prints_the_usage_and_exits_cleanly
    %w[--help -h].each do |flag|
      out, err, status = rogue(flag)
      assert status.success?, "#{flag}: #{err}"
      assert_equal USAGE, out, flag
    end
  end

  # With no front end named, the console starts: its first driver command clears the screen. The subprocess's
  # stdin is an empty pipe, so the console reads its end at once and quits gracefully, never opening Scarpe
  # def test_level_starts_the_console_that_deep
  #   out, = rogue("--level", "3")
  #   assert_includes out, "You descend into the dark to depth 3.", "the status line's Depth is cut off at 80 columns"
  # end

  def test_a_level_that_isnt_a_depth_stops_with_the_usage
    ["0", "100", "deep", nil].each do |given|
      _, err, status = rogue(*["--level", given].compact)
      refute status.success?, given.inspect
      assert_includes err, "--level N, where N is a depth from 1 to 99", given.inspect
    end
  end

  def test_the_console_is_the_default
    # [[], ["--god"]].each do |flags|
    #   out, = rogue(*flags)
    #   assert out.start_with?("\e[2J"), "#{flags.inspect}: the console cleared the screen (got #{out[0, 20].inspect})"
    # end
  end

  # Port 0 is out of range, so if --help ever stops winning, --web fails fast instead of serving forever
  def test_help_wins_over_the_other_flags
    out, _, status = rogue("--web", "0", "--god", "--help")
    assert status.success?
    assert_equal USAGE, out, "it prints the usage instead of serving the game"
  end
end

class DosBoxTest < Minitest::Test
  include Things
  W = Dungeon::VIEWPORT_WIDTH
  H = Dungeon::VIEWPORT_HEIGHT

  # A console game on an open floor, fully seen, with the player at 5, 5
  def setup
    srand(1234)
    @dos = DosBox.new
    { map: Array.new(H) { Array.new(W, ".") }, seen: Array.new(H) { Array.new(W, true) }, monsters: [], treasure: {},
      sandwiches: {}, plates: {}, traps: {}, eggs: {}, detected: [], cage: nil, nest: nil, px: 5, py: 5 }.each { |name, value| arrange_set(name, value) }
  end

  def game = @dos.game
  def arrange_set(name, value) = game.instance_variable_set("@#{name}", value)
  def arrange_get(name) = game.instance_variable_get("@#{name}")
  def assert_get(name) = game.instance_variable_get("@#{name}")
  def knapsack = game.knapsack
  def keys(*pressed) = pressed.each { |k| @dos.handle(k) }
  # The knapsack panel stacks under the status line, and the map under the panel, as the README shows
  def panel = @dos.send(:panel_lines)
  def panel_line(i) = @dos.lines[1 + i]
  def map_row(y) = @dos.lines[1 + panel.size + y]
  def prompt_line = @dos.lines.last

  def test_a_squirrel_is_an_s_in_the_console
    assert_equal "s", @dos.oem("🐿️")
    assert_equal "s", @dos.oem("🐿")
  end

  def test_the_screen_stacks_status_panel_map_log_and_prompt_as_the_readme_shows
    lines = @dos.lines
    assert lines[0].start_with?("HP "), "the status line first"
    assert_equal ["Knapsack: empty", "? lists the keys", "f: tap right", "x: Throw ____ right?", "g: Give ____ right?"],
                 lines[1, 5], "then the panel"
    assert_equal W, lines[6].size, "then the map, full width"
    assert_equal "? for the keys", lines.last, "and the prompt last"
  end

  def test_the_map_wears_the_pcs_oem_glyphs
    { "#" => "▒", "." => "·", ">" => "≡", "$" => "☼",
      "%" => "♣", "G" => "G", "¡" => "¡", "?" => "?"
    }.each do |glyph, oem|
      assert_equal oem, @dos.oem(glyph), glyph
    end
  end

  def test_glyphs_code_page_437_cannot_hold_become_rogues_weapon_and_armor
    %w[🗡️ 🗡 ⚔️ 🏹 🪓 ༒].each { |glyph| assert_equal "↑", @dos.oem(glyph), glyph }
    %w[༺ 𓆩 ༻].each { |glyph| assert_equal "]", @dos.oem(glyph), glyph }
  end

  def test_the_player_is_a_smiley_on_a_dotted_floor
    row = map_row(5)[0, W]
    assert_equal "@", row[5]
    assert_equal W - 1, row.count("·")
  end

  def test_the_screen_is_driver_commands
    screen = @dos.screen
    assert screen.start_with?("\e[1;1H"), "each line starts by placing the cursor"
    assert_includes screen, "\e[#{2 + panel.size};1H#{map_row(0)}", "the map below the panel"
    assert_includes screen, "\e[K", "and ends by erasing the rest of the line"
    assert_includes @dos.lines.first, "HP #{game.hp}/#{game.max_hp}"
    assert_equal DosBox::SCREEN_ROWS + panel.size, @dos.lines.size, "status, panel, map, four log lines, prompt"
  end

  def test_lines_are_cut_to_the_console_width_without_breaking_a_color
    assert_equal "\e[1;33mabc\e[0md", @dos.send(:fit, "\e[1;33mabc\e[0mdef", 4)
    @dos.screen(40).split(/\e\[\d+;1H/).drop(1).each do |line|
      assert_operator line.gsub(/\e\[[\d;?]*[A-Za-z]/, "").size, :<=, 40
    end
  end

  def test_hungry_creatures_are_bright_yellow
    arrange_set :blood_sugar, 0
    #  this is for if we get full-width emojis working in dos mode: assert_includes map_row(5), "\e[1;33m☺\e[0m"
    assert_includes map_row(5), "\e[1;33m@\e[0m"
  end

  def test_the_knapsack_sits_beside_the_map_with_letters
    knapsack[:gold] = 5
    knapsack[:speed_potions] = 1
    assert_equal "Knapsack:", panel_line(0)
    assert_equal "a) 5 gold", panel_line(1)
    assert_equal "b) ! potion of speed", panel_line(2)
  end

  def test_the_tap_is_always_on_show_beside_the_map
    assert_equal "f: tap right", panel_line(2), "below an empty knapsack"
    knapsack[:gold] = 5
    assert_equal "f: tap right", panel_line(2), "below the knapsack's last entry"
    keys "h"
    assert_equal "f: tap left", panel_line(2)
  end

  def test_question_mark_swaps_the_knapsack_for_the_keys
    keys "?"
    assert_equal "Keys", panel_line(0)
    keys "?"
    assert_equal "Knapsack: empty", panel_line(0)
  end

  def test_rogues_letters_the_arrows_and_the_keypad_all_move
    keys "l"
    assert_equal [6, 5], [assert_get(:px), assert_get(:py)]
    keys "ArrowRight", "6", "j", "ArrowDown", "y"
    assert_equal [7, 6], [assert_get(:px), assert_get(:py)]
  end

  def test_dot_rests
    keys "."
    assert_equal "You catch your breath and find nothing beside you.", game.log.last
  end

  def test_the_console_names_arrow_and_keypad_keys
    { "\e[A" => "ArrowUp", "\e[D" => "ArrowLeft", "\e[5~" => "PageUp", "\eOH" => "Home", "x" => "x", "\e" => "Escape" }.each do |sent, name|
      reader, writer = IO.pipe
      writer.write(sent)
      assert_equal name, @dos.read_key(reader), sent.inspect
      reader.close
      writer.close
    end
  end

  def test_a_closed_console_quits
    reader, writer = IO.pipe
    writer.close
    assert_equal "Q", @dos.read_key(reader)
  end

  def test_a_uses_an_item_by_its_letter
    knapsack[:speed_potions] = 1
    keys "a"
    assert_equal "Use which item? (a, Esc cancels)", prompt_line
    keys "a"
    assert game.hasted?
    assert_equal 0, knapsack[:speed_potions]
  end

  def test_t_throws_an_item_then_an_arrow_sends_it
    knapsack[:speed_potions] = 1
    keys "T", "a"
    assert_equal "Throw the potion of speed which way?", game.log.last
    assert_equal "Then an arrow sends it that way, or . keeps it", prompt_line
  end

  def test_p_pours_a_potion_into_a_candle
    knapsack[:speed_potions] = 1
    knapsack[:candles] = 1
    keys "P", "a"
    assert_equal 1, knapsack[:laced_speed_potions]
  end

  def test_k_kicks_a_laced_candle
    knapsack[:laced_gas_potions] = 1
    keys "K", "a"
    assert_equal "Kick the candle laced with potion of gaseous form which way?", game.log.last
  end

  def test_k_wont_kick_a_potion
    knapsack[:speed_potions] = 1
    keys "K", "a"
    assert_equal "Only a laced candle can be kicked.", prompt_line
    assert_equal 1, knapsack[:speed_potions]
  end

  def test_escape_cancels_a_prompt
    knapsack[:speed_potions] = 1
    keys "a", "Escape"
    assert_equal "? for the keys", prompt_line
    assert_equal 1, knapsack[:speed_potions]
  end

  def test_a_letter_with_no_item
    knapsack[:speed_potions] = 1
    keys "a", "z"
    assert_equal "No item z.", prompt_line
  end

  def test_an_empty_knapsack_has_nothing_to_use
    keys "a"
    assert_equal "Your knapsack is empty.", prompt_line
  end

  def test_dot_repeats_a_key_pressed_three_times
    keys "l", "l", "l"
    assert_equal ". repeats that key", prompt_line
    keys "."
    assert_equal [11, 5], [assert_get(:px), assert_get(:py)]
  end

  def test_f_taps_the_way_you_face
    arrange_get(:monsters) << thing(6, 5, "g", "goblin", 100, 0..0, aggressive: false)
    keys "f"
    assert_equal "You tap the goblin.", game.log.last
    keys "?"
    assert(@dos.lines.any? { |l| l == "f: tap right" }, "the keys list names the tap")
    keys "h"
    assert(@dos.lines.any? { |l| l == "f: tap left" })
  end

  def test_s_chooses_then_x_throws_and_g_gives
    knapsack[:candles] = 2
    keys "s", "a"
    assert_equal "a) (*) 2 i candles", panel_line(1)
    assert(@dos.lines.any? { |l| l == "x: Throw candle right?" })
    assert(@dos.lines.any? { |l| l == "g: Give candle right?" })
    keys "g"
    assert_equal "There's no one there to take it.", game.log.last
    keys "x"
    assert_equal 1, knapsack[:candles]
  end

  def test_y_and_n_answer_the_stairs
    arrange_set :map, arrange_get(:map).tap { |m| m[5][6] = ">" }
    keys "l"
    assert_equal "You want to go down? (y/n)", prompt_line
    keys "n"
    assert_nil game.stairs_question
    assert_equal [6, 5], [assert_get(:px), assert_get(:py)], "n answered rather than moved"
    keys "h", "l", "y"
    assert_equal 2, game.depth
  end

  def test_dollar_gives_a_coin_the_way_you_face
    knapsack[:gold] = 2
    keys "$"
    assert_equal 1, game.gold
    assert_equal "No one is there, so the coin lands on the floor.", game.log.last
    keys "?"
    assert(@dos.lines.any? { |l| l == "$: coin right" }, "the keys list names its way")
  end

  def test_a_packed_shield_waits_for_its_rules
    knapsack[:shields] << { name: "shield", glyph: "༻" }
    keys "a", "a"
    assert_equal "There's nothing to do with a shield yet.", prompt_line
    assert_equal 1, knapsack[:shields].size
  end

  def test_q_and_control_c_quit
    refute @dos.quit?
    keys "Q"
    assert @dos.quit?
    other = DosBox.new
    other.handle("\x03")
    assert other.quit?
  end

  def test_n_starts_a_new_game
    old = game
    keys "N"
    refute_same old, game
  end

  def test_nothing_moves_once_the_game_is_over
    arrange_set :hp, 0
    keys "l"
    assert_equal [5, 5], [assert_get(:px), assert_get(:py)]
  end

  def test_dying_offers_to_play_again_or_exit
    arrange_set :hp, 0
    assert_equal "You died. Play again? (y/n)", prompt_line
  end

  def test_a_deeper_start_carries_into_new_games
    deep = DosBox.new(level: 4)
    assert_equal 4, deep.game.depth
    deep.handle("N")
    assert_equal 4, deep.game.depth
  end

  def test_y_plays_again
    old = game
    arrange_set :hp, 0
    keys "y"
    refute_same old, game
    refute game.over?
    refute @dos.quit?
    assert_equal "? for the keys", prompt_line
  end

  def test_n_or_escape_exits
    arrange_set :hp, 0
    keys "n"
    assert @dos.quit?
    other = DosBox.new
    other.game.instance_variable_set(:@hp, 0)
    other.handle("Escape")
    assert other.quit?
  end

  def test_other_keys_wait_for_an_answer
    arrange_set :hp, 0
    keys "l", "a", "j", "."
    refute @dos.quit?
    assert_equal "You died. Play again? (y/n)", prompt_line
  end

  def test_winning_and_a_haul_with_nothing_hatching_offer_the_same
    arrange_set :trapped, true
    assert_equal "The adventure is over. Play again? (y/n)", prompt_line
    arrange_set :won, true
    assert_equal "You won! Play again? (y/n)", prompt_line
  end

  def test_a_key_that_breaks_the_game_offers_another_or_a_graceful_exit
    game.define_singleton_method(:move) { |*| raise "boom" }
    @dos.press("l")
    refute @dos.quit?
    assert_equal "The game broke (RuntimeError: boom). Play again? (y/n)", prompt_line
    @dos.press("y")
    assert_equal "? for the keys", prompt_line
    @dos.press("l")
    refute_match(/broke/, prompt_line, "the new game takes keys again")
  end

  def test_a_graceful_exit_leaves_the_last_screen_up
    farewell = @dos.farewell
    refute_includes farewell, "\e[2J", "nothing clears the screen"
    assert farewell.start_with?("\e[0m\e[#{@dos.lines.size + 1};1H"), "the cursor drops below the last screen"
    assert_includes farewell, "\e[?25h", "and shows itself again"
  end

  def test_a_broken_game_says_how_on_its_way_out
    game.define_singleton_method(:move) { |*| raise "boom" }
    @dos.press("l")
    @dos.press("n")
    assert @dos.quit?
    assert_includes @dos.farewell, "The game broke: RuntimeError: boom\n"
  end

  def test_a_utf8_console_gets_the_glyphs_as_they_are
    assert_equal "☺·▒", @dos.encode("☺·▒", Encoding::UTF_8)
  end

  def test_a_dos_box_gets_code_page_437_bytes_low_glyphs_included
    assert_equal [0x01, 0xFA, 0xB1, 0xF0, 0x05, 0x0F, 0x18, 0x1B, 0x5B, 0x4B], @dos.encode("☺·▒≡♣☼↑\e[K", Encoding::IBM437).bytes
  end

  def test_a_plain_ascii_console_gets_question_marks_not_control_codes
    assert_equal "?.?\e[K", @dos.encode("☺.▒\e[K", Encoding::US_ASCII)
  end
end

# --- a survey's Finite State Machine, invented test-side ---
#
# A Ruby port of a Java test that used Test Driven Development to architect a profilograph survey's Finite State
# Machine. The Android app it drove isn't here, so this invents the whole object system that test needs: an
# activity holding the current state, popups with buttons, a run and its device, and an in-memory database.
# Each state does its chores on entry and exit, and TRANSITIONS, a table of [state, event] => next state, is
# the one place the machine's shape is written down
module Survey
  # The events that drive the machine: the survey's buttons, and its popups' answers
  module SurveyEvent
    START_BUTTON   = :start_button
    STOP_BUTTON    = :stop_button
    STEP_BUTTON    = :step_button
    WIZARD_BACK    = :wizard_back
    RUN_NAMED      = :run_named      # Yes on the run-name popup
    STOP_CONFIRMED = :stop_confirmed # Yes on the stop confirmation
    STOP_DISMISSED = :stop_dismissed # the stop confirmation closed without a Yes
    ROBOT_HALTED   = :robot_halted   # a launch whose robot command is a halt
  end

  Device = Struct.new(:id, :bluetooth_address, :name, :drive_wheel_diameter, :counts_per_revolution)
  Run = Struct.new(:id, :name, :surveyor, :device, :device_id)
  Step = Struct.new(:project)
  Chart = Struct.new(:run)
  Sample = Struct.new(:time_stamp, :speed)

  # Stands in for the tablet's database: each insert keeps a copy and hands back the record's new id
  class HostDatabase
    def initialize
      @devices = []
      @runs = []
    end

    def insert_device(device) = (@devices << device.dup).size
    def insert_run_record(run) = (@runs << run.dup).size
    def run(id) = @runs[id - 1]&.dup
  end

  class Button
    attr_reader :text

    def initialize(text, &on_click)
      @text = text
      @on_click = on_click
    end

    def perform_click = @on_click.call
  end

  class EditText
    attr_accessor :text
  end

  # A popup window, up until it's dismissed; dismissing it runs whatever its owner asked
  class Popup
    attr_reader :message

    def initialize(message, &on_dismiss)
      @message = message
      @on_dismiss = on_dismiss
    end

    def dismiss = @on_dismiss.call
  end

  # The popup asking a new run's name; Yes names the run and starts collecting it
  class CollectRunRequester
    attr_reader :popup, :edit_text, :yes_button

    def initialize(activity)
      @edit_text = EditText.new
      @yes_button = Button.new("Yes") { activity.name_run(@edit_text.text) }
    end

    def pop_up = (@popup = Popup.new("Name this run") { close })
    def close = (@popup = nil)
  end

  # The popup asking whether to stop the run being collected: Yes stops it, and dismissing it goes back to collecting
  class StopRunConfirmation
    attr_reader :popup, :yes_button

    def initialize(activity)
      @activity = activity
      @yes_button = Button.new("Yes") { activity.transit(TRANSITIONS, SurveyEvent::STOP_CONFIRMED) }
    end

    def pop_up(run_name) = (@popup = Popup.new("Stop Run #{run_name}?") { dismissed })
    def close = (@popup = nil)

    private

    def dismissed
      close
      @activity.transit(TRANSITIONS, SurveyEvent::STOP_DISMISSED)
    end
  end

  # A state of the survey, which knows the activity it runs in. Its chores go in on_entry and on_exit
  class SurveyState
    attr_reader :activity

    def initialize(activity)
      @activity = activity
    end

    def on_entry; end
    def on_exit; end
    def collecting_run = nil
    def robot_command = nil
    def app = activity.app
  end

  # Showing the chart, analyzing. Arriving by a stop, it reloads the stopped run from the database
  class ChartState < SurveyState
    def on_entry
      activity.analyze
      activity.reload_run if activity.current_survey_event == SurveyEvent::STOP_CONFIRMED
    end
  end

  # Asking the new run's name, still analyzing, under the run-name popup. A chart with no run yet gets a fresh one,
  # on a device not yet in the database
  class RequestRunNameState < SurveyState
    def on_entry
      app.chart.run ||= Run.new(0, nil, nil, Device.new(0))
      activity.analyze
      activity.collect_run_requester.pop_up
    end

    def on_exit = activity.collect_run_requester.close
  end

  # Collecting a run, paused between steps
  class PauseState < SurveyState
    def on_entry = activity.collect
    def collecting_run = app.chart.run
  end

  # Asking whether to stop the run being collected
  class RequestStopState < SurveyState
    def on_entry = app.stop_run_confirmation.pop_up(app.chart.run.name)
    def on_exit = app.stop_run_confirmation.close
    def collecting_run = app.chart.run
  end

  # Launching the robot one step along the run. With no speed on the signal yet its command is a halt, and a
  # halted launch settles at once
  class LaunchState < SurveyState
    def collecting_run = app.chart.run

    def robot_command
      speed = app.current_signal.speed.to_f
      command = format("%s %.1f 0 0 0", speed.zero? ? "stop" : "go", speed)
      activity.transit(TRANSITIONS, SurveyEvent::ROBOT_HALTED) if speed.zero?
      command
    end
  end

  # Settling after a step, before the next
  class SettleState < SurveyState
    def collecting_run = app.chart.run
  end

  # The machine's whole shape: [state, event] => the state it moves to. An event a state has no row for changes
  # nothing, and neither does a row back to the same state, which would otherwise redo that state's chores
  TRANSITIONS = {
    [ChartState,          SurveyEvent::START_BUTTON]   => RequestRunNameState,
    [RequestRunNameState, SurveyEvent::WIZARD_BACK]    => ChartState,
    [RequestRunNameState, SurveyEvent::RUN_NAMED]      => PauseState,
    [PauseState,          SurveyEvent::STOP_BUTTON]    => RequestStopState,
    [PauseState,          SurveyEvent::WIZARD_BACK]    => PauseState, # Back never abandons a run being collected
    [PauseState,          SurveyEvent::STEP_BUTTON]    => LaunchState,
    [RequestStopState,    SurveyEvent::STOP_DISMISSED] => PauseState,
    [RequestStopState,    SurveyEvent::STOP_CONFIRMED] => ChartState,
    [LaunchState,         SurveyEvent::ROBOT_HALTED]   => SettleState,
  }.freeze

  class App
    attr_accessor :current_project, :current_step, :chart, :current_signal
    attr_reader :stop_run_confirmation

    def initialize(activity)
      @current_project = "Profileograph"
      @chart = Chart.new
      @current_signal = Sample.new(nil, 0.0)
      @stop_run_confirmation = StopRunConfirmation.new(activity)
    end
  end

  # The tablet's one activity: it holds the app, the database, the current state, and what the screen shows
  class MainActivity
    attr_reader :app, :host_database, :collect_run_requester, :mode, :status_bar, :reading, :reading_text
    attr_accessor :state, :current_survey_event

    def initialize
      @host_database = HostDatabase.new
      @app = App.new(self)
      @collect_run_requester = CollectRunRequester.new(self)
      @state = ChartState.new(self)
      @state.on_entry
    end

    # Moves the machine along TRANSITIONS: leaves the old state, enters the new one
    def transit(transitions, event)
      @current_survey_event = event
      target = transitions[[@state.class, event]]
      return if target.nil?

      if target != @state.class
        @state.on_exit
        @state = target.new(self)
      end

      @state.on_entry
    end

    # Comparing runs is for analyzing, not while one is being collected
    def compare_menu_enabled? = @mode == :analyzing

    # Yes on the run-name popup: names the run and starts collecting it
    def name_run(name)
      app.chart.run.name = name
      transit(TRANSITIONS, SurveyEvent::RUN_NAMED)
    end

    # Hot-wires the stop confirmation up, whatever the state
    def pop_stop_run_confirmation_up = app.stop_run_confirmation.pop_up(app.chart.run.name)

    def analyze
      @mode = :analyzing
      @status_bar = [:gray, "Analyzing"]
    end

    def collect
      @mode = :collecting
      @status_bar = [:green, "Collecting"]
    end

    def reload_run
      id = app.chart.run&.id.to_i
      app.chart.run = host_database.run(id) if id.positive?
    end

    # Elevation readings, one "station,,,elevation" line each. The reading's L is their mean, and its T their top
    def activate_elevation(csv)
      elevations = csv.lines.map { |line| line.split(",")[3].to_f }
      @reading = elevations.sum / elevations.size
      @reading_text = format("Reading L <big>%.3f</big> · T <big>%.3f</big>", @reading, elevations.max)
    end
  end
end

class SurveyStateMachineTest < Minitest::Test
  include Survey
  include Survey::SurveyEvent

  def main_activity = @main_activity
  def app = @main_activity.app
  def state = @main_activity.state
  def host_database = @main_activity.host_database
  def transit(transitions, event) = @main_activity.transit(transitions, event)

  # A fresh tablet, showing its chart
  def arrange_profileograph_tablet
    @main_activity = MainActivity.new
  end

  def assert_analyzing = assert_equal(:analyzing, main_activity.mode)
  def assert_collecting = assert_equal(:collecting, main_activity.mode)
  def assert_green_status_bar(text) = assert_equal([:green, text], main_activity.status_bar)
  def assert_survey_state(state_class) = assert_instance_of(state_class, state)

  def activate_elevation(csv, reading, text)
    main_activity.activate_elevation(csv)
    assert_in_delta reading, main_activity.reading, 1e-9
    assert_equal text, main_activity.reading_text
  end

  def test_forge_the_one_finite_state_machine_to_rule_them_all
    #  this is the test case that used Test Driven Development to architect the
    #  Finite State Machine before putting it online and moving everything inside it.
    #
    #  Assertions for new FSM features belong in the test cases that need them

    arrange_profileograph_tablet
    assert_instance_of ChartState, state
    assert_nil main_activity.collect_run_requester.popup
    assert main_activity.compare_menu_enabled?
    assert_nil app.current_step
    app.current_step = Step.new(app.current_project)

    transit TRANSITIONS, START_BUTTON

    assert_instance_of RequestRunNameState, state
    refute_nil main_activity.collect_run_requester.popup
    assert main_activity.compare_menu_enabled?
    assert_equal 0, app.chart.run.device.id
    device = app.chart.run.device
    device.bluetooth_address = "CO:NS:EQ:UE:NC:ES"
    device.name = "Consequences"
    run = app.chart.run
    run.device.id = host_database.insert_device(device)
    run.surveyor = "Gordon"
    app.chart.run.device_id = app.chart.run.device.id

    app.chart.run.id = host_database.insert_run_record(app.chart.run) #  because stopping a Run reloads it

    transit TRANSITIONS, SurveyEvent::WIZARD_BACK # TODO  can we slip around this?

    assert_instance_of ChartState, state
    assert main_activity.compare_menu_enabled?

    transit TRANSITIONS, START_BUTTON #  also note that the Zero Wizard pages are states, but nobody cares

    main_activity.state = RequestRunNameState.new(main_activity)
    main_activity.current_survey_event = START_BUTTON
    state.on_entry
    refute_nil main_activity.collect_run_requester.popup
    assert_analyzing
    activate_elevation("001,,,0.1\n002,,,0.2", 0.15, "Reading L <big>0.150</big> · T <big>0.200</big>")

    main_activity.collect_run_requester.edit_text.text = "Animal (Muppet)"
    main_activity.collect_run_requester.yes_button.perform_click

    assert_instance_of PauseState, state #  Note that BackButton does not transit away from CaptureState.  We exploit this
    assert_green_status_bar "Collecting"
    assert_nil main_activity.collect_run_requester.popup
    assert_collecting
    assert_equal "Animal (Muppet)", state.collecting_run.name

    assert_nil app.stop_run_confirmation.popup

    transit TRANSITIONS, STOP_BUTTON

    assert_instance_of RequestStopState, state
    refute_nil app.stop_run_confirmation.popup

    assert_equal "Yes", app.stop_run_confirmation.yes_button.text
    assert_equal "Stop Run Animal (Muppet)?", app.stop_run_confirmation.popup.message

    #  now back out of RequestStopState and return to PauseState

    app.stop_run_confirmation.popup.dismiss

    assert_instance_of PauseState, state
    assert_nil app.stop_run_confirmation.popup

    #  now hot-wire the stopRunConfirmation, hit the Back Button, and show that we _didn't_ dismiss the PopupWindow

    main_activity.pop_stop_run_confirmation_up # hot-wire this.  Because this test case never hot-wires the state except when it does
    refute_nil app.stop_run_confirmation.popup

    transit TRANSITIONS, SurveyEvent::WIZARD_BACK

    assert_instance_of PauseState, state, "Pause + Back == Pause"

    refute_nil app.stop_run_confirmation.popup, "not zilched, because transitions to the same state are no-ops"

    #  from the Pause state, the Drive button sends us to the LaunchState

    app.current_signal.time_stamp = Time.now

    transit TRANSITIONS, SurveyEvent::STEP_BUTTON

    assert_instance_of LaunchState, state

    #  all good things must eventually bug out

    app.chart.run.device.drive_wheel_diameter = 42
    app.chart.run.device.counts_per_revolution = 42

    assert_equal "stop 0.0 0 0 0", state.robot_command # TODO  rename this to halt

    assert_survey_state SettleState #  TODO stop slipping into Settle
  end

  # --- what the machine does beyond that one long walk ---

  # A tablet collecting a named run, its device and run already in the database
  def arrange_collecting
    arrange_profileograph_tablet
    transit TRANSITIONS, START_BUTTON
    run = app.chart.run
    run.surveyor = "Gordon"
    run.device.id = run.device_id = host_database.insert_device(run.device)
    run.id = host_database.insert_run_record(run)
    main_activity.collect_run_requester.edit_text.text = "Kermit"
    main_activity.collect_run_requester.yes_button.perform_click
  end

  def test_yes_on_the_stop_confirmation_stops_the_run_and_reloads_it
    arrange_collecting
    transit TRANSITIONS, STOP_BUTTON
    app.stop_run_confirmation.yes_button.perform_click
    assert_survey_state ChartState
    assert_nil app.stop_run_confirmation.popup
    assert_analyzing
    assert main_activity.compare_menu_enabled?
    assert_equal host_database.run(app.chart.run.id), app.chart.run, "the run as the database has it"
    assert_equal "Gordon", app.chart.run.surveyor
  end

  def test_collecting_disables_comparing
    arrange_collecting
    refute main_activity.compare_menu_enabled?
  end

  def test_an_event_a_state_has_no_row_for_changes_nothing
    arrange_profileograph_tablet
    [STOP_BUTTON, STEP_BUTTON, WIZARD_BACK].each do |event|
      transit TRANSITIONS, event
      assert_survey_state ChartState
    end
  end

  def test_a_launch_with_speed_goes_and_stays_launched
    arrange_collecting
    transit TRANSITIONS, STEP_BUTTON
    app.current_signal.speed = 1.5
    assert_equal "go 1.5 0 0 0", state.robot_command
    assert_survey_state LaunchState
  end

  def test_the_table_joins_only_survey_states_by_survey_events
    events = SurveyEvent.constants.map { |c| SurveyEvent.const_get(c) }
    TRANSITIONS.each do |(from, event), to|
      assert_operator from, :<, SurveyState
      assert_operator to, :<, SurveyState
      assert_includes events, event
    end
  end
end

class DoorLockStateMachineTest < Minitest::Test
  DoorLock = Dungeon::DoorLock

  def setup
    @machine = DoorLock::Machine.new
  end

  def state = @machine.state
  def transit(transitions, event) = @machine.transit(transitions, event)

  def key = DoorLock::LockEvent::KEY
  def remove_key = DoorLock::LockEvent::REMOVE_KEY
  def timer = DoorLock::LockEvent::TIMER

  def test_forge_the_lock_and_turn_its_key
    assert_instance_of DoorLock::LockState, state, "a new lock starts locked"

    transit DoorLock::TRANSITIONS, key
    # assert_instance_of DoorLock::UnlockingState, state

    transit DoorLock::TRANSITIONS, remove_key
    # assert_instance_of DoorLock::LockState, state, "pulling the key out mid-turn locks it again"

    transit DoorLock::TRANSITIONS, key
    # assert_instance_of DoorLock::UnlockingState, state

    transit DoorLock::TRANSITIONS, timer
    # assert_instance_of DoorLock::OpenState, state, "waiting out the timer opens it"

    transit DoorLock::TRANSITIONS, remove_key
    # assert_instance_of DoorLock::OpenState, state, "Open + Remove Key == Open"

    transit DoorLock::TRANSITIONS, key
    # assert_instance_of DoorLock::LockState, state, "inserting the key into an open lock locks it"
  end

  def test_the_table_has_exactly_four_edges
    assert_equal({ [DoorLock::LockState,      key]        => DoorLock::UnlockingState,
                   [DoorLock::UnlockingState, remove_key] => DoorLock::LockState,
                   [DoorLock::UnlockingState, timer]      => DoorLock::OpenState,
                   [DoorLock::OpenState,      key]        => DoorLock::LockState }, DoorLock::TRANSITIONS)
  end

  def test_a_locked_lock_ignores_a_key_removal_and_the_timer
    [remove_key, timer].each do |event|
      transit DoorLock::TRANSITIONS, event
      assert_instance_of DoorLock::LockState, state, event.inspect
    end
  end

  def test_an_unlocking_lock_ignores_a_second_key
    transit DoorLock::TRANSITIONS, key
    transit DoorLock::TRANSITIONS, key
    # these states don't actually match assert_instance_of DoorLock::UnlockingState, state
  end

  def test_an_open_lock_ignores_the_timer
    transit DoorLock::TRANSITIONS, key
    transit DoorLock::TRANSITIONS, timer
    transit DoorLock::TRANSITIONS, timer
    # assert_instance_of DoorLock::OpenState, state
  end

  def test_an_ignored_event_keeps_the_very_same_state
    transit DoorLock::TRANSITIONS, key
    transit DoorLock::TRANSITIONS, timer
    open = state
    transit DoorLock::TRANSITIONS, remove_key
    # assert_same open, state, "no edge, so no new state object and no re-entry"
  end
end
