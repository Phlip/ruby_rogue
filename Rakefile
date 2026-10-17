
  # a Rakefile is a command line aggregator

# rake test
#   runs every test in test_rogue.rb
#
# rake ship eva thang is gonna be all right
#   runs every test, and only if they all pass, commits everything changed (all but .idea/) with the rest of the
#   command line as its message, no quotes needed, then pushes. Rake reads each of those words as one more task
#   to run, so ship exits once it's done, before rake gets to them. Quote anything the shell would eat, such as
#   it's or (parentheses); a word with = in it, or starting with -, goes to rake instead of the message
#
# rake play
#   plays the game in this console
#
# rake god
#   plays it in god mode, where you take no damage
#
# rake claude
#   opens Claude Code in this folder. Words after claude become its first prompt, the same way ship's become
#   the commit message, and the same quoting rules apply

SOUNDS = File.join(__dir__, "sounds")

# Plays sounds/<name>.wav through whichever player this machine has, without waiting for it to finish
def play(name)
  file = File.join(SOUNDS, name.to_s.delete_suffix(".wav") + ".wav")
  File.exist?(file) or return warn("No such sound: #{file}")
  # player = %w[paplay pw-play aplay].find { |p| system("command -v #{p} > /dev/null 2>&1") }
  # player or return warn("No sound player found (paplay, pw-play, or aplay)")
  player = 'aplay'
  sh player, file
  # Process.detach(spawn(player, file, %i[out err] => File::NULL))
end

desc "Run every test in test_rogue.rb; a frog croaks if they pass, a kitten mews if they fail"
task :test do
  ENV['QUIET'] = '1'

  # The run's output tees through tee_sounds.rb, which plays a sound for each E, F, and S as the dots print
  require 'open3'
  Dir.chdir(__dir__)
  status = Open3.pipeline([RbConfig.ruby, "test_rogue.rb"], [RbConfig.ruby, "tee_sounds.rb"]).first
  play(status.success? ? "frog2" : "kitten")
  status.success? or abort "The tests failed (exit status #{status.exitstatus})."

  sh 'figlet tests passed'
end

desc "Play sounds from sounds/ by name, one after another, e.g. rake 'sound[car_horn chimp error]'; with no name, list them"
task :sound do |_t, args|
  names = args.extras.flat_map { |a| a.split(/[\s,]+/) }.reject(&:empty?) # spaces or commas between names
  names.empty? and (next puts(Dir.children(SOUNDS).grep(/\.wav\z/).sort.map { |f| f.delete_suffix(".wav") }))

  names.each do |name|
    playing = play(name)
    # playing.join # < -- Mr Machine thinks play returned an object and join waits until it finishes
  end # each finishes before the next starts
end

task :banner do
  print ' _____         _   _
|_   _|__  ___| |_(_)_ __   __ _
  | |/ _ \/ __| __| | \'_ \ / _\ |
  | |  __/\__ \ |_| | | | | (_| |_ _ _
  |_|\___||___/\__|_|_| |_|\__, (_|_|_)
                           |___/
'

end

desc "Run the tests; only if they all pass, commit with the rest of the command line as the message, and push"
task ship: [:banner, :test] do
  words = Rake.application.top_level_tasks
  message = words.drop((words.index("ship") || words.size) + 1).join(" ")
  abort "Usage: rake ship your commit message here, no quotes needed" if message.empty?

  # ruby "test_rogue.rb" do |ok, status|
  #   play(ok ? 'frog' : 'dogs')
  #   ok or abort "The tests failed (exit status #{status.exitstatus}), so nothing was committed or pushed."
  # end

  sh "git", "add", "--all", "--", ".", ":(exclude).idea"
  if system("git", "diff", "--cached", "--quiet")
    puts "Every test passes, but there's nothing new to commit."
  else
    sh "git", "commit", "-m", message
  end
  sh "git", "push"
  exit
end

desc "Open Claude Code in this folder, with the rest of the command line as its first prompt"
task :claude do
  words = Rake.application.top_level_tasks
  prompt = words.drop((words.index("claude") || words.size) + 1).join(" ")

  # exec hands the terminal straight to claude, and rake never sees the prompt words as tasks
  Dir.chdir(__dir__)
  prompt.empty? ? exec("claude-code") : exec("claude-code", prompt)
end

desc "Play the game in this console"
task :play do
  Dir.chdir(__dir__)
  exec RbConfig.ruby, "ruby_rogue.rb" # exec hands the terminal straight to the game
end

desc "Play the game in god mode, where you take no damage"
task :god do
  Dir.chdir(__dir__)
  exec RbConfig.ruby, "ruby_rogue.rb", "--god", "--level", "6"
end
