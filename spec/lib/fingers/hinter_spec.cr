require "spec"
require "../../spec_helper.cr"
require "../../../src/fingers/hinter"
require "../../../src/fingers/state"
require "../../../src/fingers/config"

record StateDouble, selected_hints : Array(String)

class TextOutput < ::Fingers::Printer
  def initialize
    @contents = ""
  end

  def print(msg)
    self.contents += msg
  end

  def flush
  end

  property :contents
end

def generate_lines
  input = 50.times.map do
    10.times.map do
      rand.to_s.split(".").last[0..15].rjust(16, '0')
    end.join(" ")
  end.join("\n")
end

describe Fingers::Hinter do
  it "works in a grid of lines" do
    width = 100
    input = generate_lines
    output = TextOutput.new

    patterns = Fingers::Config::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
    )
  end

  it "only highlights captured groups" do
    width = 100
    input = "
On branch ruby-rewrite-more-like-crystal-rewrite-amirite
Your branch is up to date with 'origin/ruby-rewrite-more-like-crystal-rewrite-amirite'.

Changes to be committed:
  (use \"git restore --staged <file>...\" to unstage)
        modified:   spec/lib/fingers/match_formatter_spec.cr

Changes not staged for commit:
  (use \"git add <file>...\" to update what will be committed)
  (use \"git restore <file>...\" to discard changes in working directory)
        modified:   .gitignore
        modified:   spec/lib/fingers/hinter_spec.cr
        modified:   spec/spec_helper.cr
        modified:   src/fingers/cli.cr
        modified:   src/fingers/dirs.cr
        modified:   src/fingers/match_formatter.cr
    "
    output = TextOutput.new

    patterns = Fingers::Config::BUILTIN_PATTERNS.values.to_a
    patterns << "On branch (?<capture>.*)"
    alphabet = "asdf".split("")

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
    )
  end

  it "only reuses hints when allow duplicates is false" do
    width = 100
    output = TextOutput.new

    patterns = Fingers::Config::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    input = "
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
    "

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      reuse_hints: false
    )

    hinter.run
  end

  it "can rerender when not reusing hints" do
    width = 100
    output = TextOutput.new

    patterns = Fingers::Config::BUILTIN_PATTERNS.values.to_a
    alphabet = "asdf".split("")

    input = "
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
          modified:   src/fingers/cli.cr
    "

    hinter = Fingers::Hinter.new(
      input: input.split("\n"),
      width: width,
      patterns: patterns,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      reuse_hints: false
    )

    hinter.run
    hinter.run
  end

  it "produces hints for colored spans" do
    width = 100
    output = TextOutput.new
    alphabet = "asdf".split("")

    # Stripped input: "prefix needle suffix"
    # Colored span covers "needle" (chars 7..13)
    input = ["prefix needle suffix"]
    colored = [[{7, 13}]]

    hinter = Fingers::Hinter.new(
      input: input,
      width: width,
      patterns: [] of String,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      colored_spans: colored,
    )

    hinter.run

    # The colored span should have been assigned a hint and registered.
    hits = hinter.@target_by_text.keys
    hits.should contain("needle")
  end

  it "drops colored spans shorter than match_colored_min_len" do
    width = 100
    output = TextOutput.new
    alphabet = "asdf".split("")

    # Default min_len is 2, so a 1-char span should be ignored.
    input = ["x y z"]
    colored = [[{0, 1}, {2, 3}]]

    hinter = Fingers::Hinter.new(
      input: input,
      width: width,
      patterns: [] of String,
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      colored_spans: colored,
    )

    hinter.run

    hinter.@target_by_text.should be_empty
  end

  it "prefers regex matches over overlapping colored spans" do
    width = 100
    output = TextOutput.new
    alphabet = "asdf".split("")

    # Regex matches "https://foo.com", color span covers the same region.
    # Only the regex match should produce a hint (yanking the URL, not a
    # duplicate color-span hint for the same text).
    input = ["visit https://foo.com today"]
    colored = [[{6, 21}]]

    hinter = Fingers::Hinter.new(
      input: input,
      width: width,
      patterns: [Fingers::Config::BUILTIN_PATTERNS["url"]],
      state: ::Fingers::State.new,
      alphabet: alphabet,
      output: output,
      colored_spans: colored,
    )

    hinter.run

    hinter.@target_by_text.size.should eq 1
    hinter.@target_by_text.keys.first.should eq "https://foo.com"
  end
end
