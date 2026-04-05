require "spec"
require "../../spec_helper.cr"
require "../../../src/fingers/ansi_scanner"

describe Fingers::AnsiScanner do
  it "returns the original line unchanged when there are no escapes" do
    result = Fingers::AnsiScanner.scan("hello world")
    result.visible.should eq "hello world"
    result.colored_spans.should be_empty
  end

  it "strips a basic SGR sequence and records the colored span" do
    # "foo \e[31mbar\e[0m baz"  — red "bar" in the middle
    result = Fingers::AnsiScanner.scan("foo \e[31mbar\e[0m baz")
    result.visible.should eq "foo bar baz"
    result.colored_spans.should eq [{4, 7}]
  end

  it "handles bright foreground (90-97)" do
    result = Fingers::AnsiScanner.scan("\e[92mgreen\e[0m")
    result.visible.should eq "green"
    result.colored_spans.should eq [{0, 5}]
  end

  it "handles 256-color foreground (38;5;N)" do
    result = Fingers::AnsiScanner.scan("plain \e[38;5;208morange\e[0m tail")
    result.visible.should eq "plain orange tail"
    result.colored_spans.should eq [{6, 12}]
  end

  it "handles truecolor foreground (38;2;R;G;B)" do
    result = Fingers::AnsiScanner.scan("\e[38;2;255;128;0mfire\e[0m")
    result.visible.should eq "fire"
    result.colored_spans.should eq [{0, 4}]
  end

  it "treats 39 (default fg) as closing a colored span" do
    result = Fingers::AnsiScanner.scan("\e[31mred\e[39mplain")
    result.visible.should eq "redplain"
    result.colored_spans.should eq [{0, 3}]
  end

  it "treats bare \\e[m as a reset" do
    result = Fingers::AnsiScanner.scan("\e[31mred\e[mafter")
    result.visible.should eq "redafter"
    result.colored_spans.should eq [{0, 3}]
  end

  it "merges adjacent runs of different non-default colors into one span" do
    # red "ab" immediately followed by green "cd" with no reset between
    result = Fingers::AnsiScanner.scan("\e[31mab\e[32mcd\e[0m")
    result.visible.should eq "abcd"
    result.colored_spans.should eq [{0, 4}]
  end

  it "ignores non-foreground SGR parameters (bold, bg)" do
    # bold + bg blue, no fg change — should NOT create a colored span
    result = Fingers::AnsiScanner.scan("\e[1;44mbold-bg\e[0m")
    result.visible.should eq "bold-bg"
    result.colored_spans.should be_empty
  end

  it "closes an open span at end of line" do
    result = Fingers::AnsiScanner.scan("\e[31munterminated")
    result.visible.should eq "unterminated"
    result.colored_spans.should eq [{0, 12}]
  end

  it "captures multiple separate colored spans" do
    result = Fingers::AnsiScanner.scan("\e[31mA\e[0m B \e[32mC\e[0m")
    result.visible.should eq "A B C"
    result.colored_spans.should eq [{0, 1}, {4, 5}]
  end

  it "passes OSC 8 hyperlinks through transparently" do
    # \e]8;;https://example.com\e\\click\e]8;;\e\\ — visible text is "click"
    input = "\e]8;;https://example.com\e\\click\e]8;;\e\\"
    result = Fingers::AnsiScanner.scan(input)
    result.visible.should eq "click"
    result.colored_spans.should be_empty
  end

  it "handles OSC terminated by BEL" do
    input = "\e]0;window title\aafter"
    result = Fingers::AnsiScanner.scan(input)
    result.visible.should eq "after"
  end

  it "preserves visible characters inside the colored region" do
    result = Fingers::AnsiScanner.scan("before \e[33mmid span\e[0m after")
    result.visible.should eq "before mid span after"
    result.colored_spans.should eq [{7, 15}]
  end

  it "handles unicode inside colored runs using character offsets" do
    # Persian "اوگار" inside red
    result = Fingers::AnsiScanner.scan("x \e[31mاوگار\e[0m y")
    result.visible.should eq "x اوگار y"
    # اوگار is 5 characters — span should be {2, 7}
    result.colored_spans.should eq [{2, 7}]
  end
end
