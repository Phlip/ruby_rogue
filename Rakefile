
  # a Rakefile is a command line aggregator

# rake test
#   runs every test in test_rogue.rb
#
# rake ship eva thang is gonna be all right
#   runs every test, and only if they all pass, commits everything changed (all but .idea/) with the rest of the
#   command line as its message, no quotes needed, then pushes. Rake reads each of those words as one more task
#   to run, so ship exits once it's done, before rake gets to them. Quote anything the shell would eat, such as
#   it's or (parentheses); a word with = in it, or starting with -, goes to rake instead of the message

desc "Run every test in test_rogue.rb"
task :test do
  ruby "test_rogue.rb"
end

desc "Run the tests; only if they all pass, commit with the rest of the command line as the message, and push"
task :ship do
  words = Rake.application.top_level_tasks
  message = words.drop((words.index("ship") || words.size) + 1).join(" ")
  abort "Usage: rake ship your commit message here, no quotes needed" if message.empty?

  ruby "test_rogue.rb" do |ok, status|
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
