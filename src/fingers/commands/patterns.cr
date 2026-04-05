require "cling"
require "./load_config"
require "../config"

class Fingers::Commands::Patterns < Cling::Command
  def setup : Nil
    @name = "patterns"
    @description = "Print the currently effective pattern map (builtins + user overrides + user-added)."
  end

  def run(arguments, options) : Nil
    # Re-parse tmux options so the output reflects the current tmux state,
    # not a possibly-stale cache.
    loader = Fingers::Commands::LoadConfig.new
    loader.validate_options!
    loader.parse_tmux_conf

    patterns = Fingers.config.patterns
    builtins = ::Fingers::Config::BUILTIN_PATTERNS

    if patterns.empty?
      puts "No patterns configured."
      return
    end

    rows = patterns.map do |name, regex|
      {name, classify(name, regex, builtins), regex}
    end

    name_w = [rows.max_of { |r| r[0].size }, "NAME".size].max
    src_w = [rows.max_of { |r| r[1].size }, "SOURCE".size].max

    fmt = "%-#{name_w}s  %-#{src_w}s  %s"
    puts fmt % ["NAME", "SOURCE", "PATTERN"]
    puts fmt % ["-" * name_w, "-" * src_w, "-------"]
    rows.each do |r|
      puts fmt % [r[0], r[1], r[2]]
    end
  end

  # Classify a pattern as "builtin" (unchanged default), "override"
  # (same name as a builtin but different regex), or "user" (user-added
  # name that doesn't collide with any builtin).
  private def classify(name : String, regex : String, builtins)
    builtin_keys = builtins.keys.map(&.to_s)
    match = builtin_keys.find { |k| k == name || k.tr("-", "_") == name }

    return "user" unless match

    builtin_regex = builtins[match]?
    return "builtin" if builtin_regex == regex
    "override"
  end
end
