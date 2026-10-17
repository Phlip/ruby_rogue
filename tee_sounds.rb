# A tee for the test run: everything on stdin goes straight through to stdout, a character at a time, and while
# Minitest's progress line is printing, the first E (an error), the first F (a failure), and the first S (a skip)
# each play their own sound through aplay, once; later ones are quiet. Usage: ruby test_ruby_rogue.rb | ruby tee_sounds.rb

SOUNDS = File.join(__dir__, "sounds")
EFFECTS = { "E" => "error", "F" => "car_horn", "S" => "cowbell" }.freeze

def play(name)
  Process.detach(spawn("aplay", "-q", File.join(SOUNDS, "#{name}.wav"), %i[out err] => File::NULL))
rescue SystemCallError
  nil # no aplay: the output still comes through
end

$stdout.sync = true
played = [] # the kinds of letter already heard, each only the once
line = +""
# Where the stream is: :before Minitest's "# Running:", :running from there through the blank line after it, on
# the line of dots, and :after once that line ends, so "Finished" and the failure reports below play nothing
stage = :before

while (char = $stdin.getc)
  $stdout.write(char)
  if char == "\n"
    stage = :running if stage == :before && line == "# Running:"
    stage = :after if stage == :running && !line.empty? && line != "# Running:"
    line = +""
    next
  end

  line << char
  next unless stage == :running && (effect = EFFECTS[char]) && !played.include?(char)

  played << char
  play(effect)
end
