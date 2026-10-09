
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
# rake claude
#   opens Claude Code in this folder. Words after claude become its first prompt, the same way ship's become
#   the commit message, and the same quoting rules apply

SOUNDS = File.join(__dir__, "sounds")

# Plays sounds/<name>.wav through whichever player this machine has, without waiting for it to finish
def play(name)
  file = File.join(SOUNDS, name.to_s.delete_suffix(".wav") + ".wav")
  File.exist?(file) or return warn("No such sound: #{file}")
  player = %w[paplay pw-play aplay].find { |p| system("command -v #{p} > /dev/null 2>&1") }
  player or return warn("No sound player found (paplay, pw-play, or aplay)")
  Process.detach(spawn(player, file, %i[out err] => File::NULL))
end

desc "Run every test in test_rogue.rb; a frog croaks if they pass, a kitten mews if they fail"
task :test do
  ruby "test_rogue.rb" do |ok, status|
    play(ok ? "frog2" : "kitten")
    ok or abort "The tests failed (exit status #{status.exitstatus})."
  end
  sh 'figlet tests passed'
end

desc "Play sounds from sounds/ by name, one after another, e.g. rake 'sound[car_horn chimp error]'; with no name, list them"
task :sound do |_t, args|
  names = args.extras.flat_map { |a| a.split(/[\s,]+/) }.reject(&:empty?) # spaces or commas between names
  next puts(Dir.children(SOUNDS).grep(/\.wav\z/).sort.map { |f| f.delete_suffix(".wav") }) if names.empty?

  names.each { |name| play(name)&.join } # each finishes before the next starts
end

desc "Run the tests; only if they all pass, commit with the rest of the command line as the message, and push"
task :ship do
  words = Rake.application.top_level_tasks
  message = words.drop((words.index("ship") || words.size) + 1).join(" ")
  abort "Usage: rake ship your commit message here, no quotes needed" if message.empty?

  ruby "test_rogue.rb" do |ok, status|
    play(ok ? 'frog' : 'dogs')
    ok or abort "The tests failed (exit status #{status.exitstatus}), so nothing was committed or pushed."
  end

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
  prompt.empty? ? exec("claude") : exec("claude", prompt)
end
