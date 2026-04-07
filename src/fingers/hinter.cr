require "../huffman"
require "./config"
require "./match_formatter"
require "./types"

module Fingers
  struct Target
    property text : String
    property hint : String
    property offset : Tuple(Int32, Int32)

    def initialize(@text, @hint, @offset)
    end
  end

  class Hinter
    # Internal unified representation of a match in a line, produced by
    # either a regex scan or a colored-span scan.
    private struct LineMatch
      getter start : Int32
      getter stop : Int32
      getter highlight_text : String
      getter captured_text : String
      getter capture_offset : Tuple(Int32, Int32)?

      def initialize(@start, @stop, @highlight_text, @captured_text, @capture_offset)
      end
    end

    @formatter : Formatter
    @patterns : Array(String)
    @alphabet : Array(String)
    @pattern : Regex | Nil
    @hints : Array(String) | Nil
    @n_matches : Int32 | Nil
    @reuse_hints : Bool
    @colored_spans : Array(Array(Tuple(Int32, Int32)))

    def initialize(
      input : Array(String),
      width : Int32,
      state : Fingers::State,
      output : Printer,
      patterns = Fingers.config.patterns,
      alphabet = Fingers.config.alphabet,
      huffman = Huffman.new,
      formatter = ::Fingers::MatchFormatter.new,
      reuse_hints = false,
      colored_spans : Array(Array(Tuple(Int32, Int32))) = [] of Array(Tuple(Int32, Int32))
    )
      @lines = input
      @width = width
      @target_by_hint = {} of String => Target
      @target_by_text = {} of String => Target
      @state = state
      @output = output
      @formatter = formatter
      @huffman = huffman
      @patterns = patterns
      @alphabet = alphabet
      @reuse_hints = reuse_hints
      @colored_spans = colored_spans
    end

    def run
      regenerate_hints!
      lines[0..-2].each_with_index { |line, index| process_line(line, index, "\n") }
      process_line(lines[-1], lines.size - 1, "")

      output.flush
    end

    def lookup(hint) : Target | Nil
      target_by_hint.fetch(hint) { nil }
    end

    # private

    private getter :hints,
      :hints_by_text,
      :offsets_by_hint,
      :input,
      :lookup_table,
      :width,
      :state,
      :formatter,
      :huffman,
      :output,
      :patterns,
      :alphabet,
      :reuse_hints,
      :target_by_hint,
      :target_by_text,
      :colored_spans

    def process_line(line, line_index, ending)
      tab_positions = tab_positions_for(line)
      matches = collect_matches_for(line, line_index)
      result = splice_matches(line, matches, line_index)
      initial_length = result.size
      result = expand_tabs(result, tab_positions)
      tab_correction = result.size - initial_length

      result = Fingers.config.backdrop_style + result
      double_width_correction = ((line.bytesize - line.size) / 3).round.to_i
      padding_amount = (width - line.size - double_width_correction - tab_correction)
      padding = padding_amount > 0 ? " " * padding_amount : ""
      output.print(result + padding + ending)
    end

    # Collects all matches for a line from both sources (regex patterns and
    # colored spans), removes colored spans that overlap regex matches, and
    # returns them sorted by start position.
    private def collect_matches_for(line : String, line_index : Int32) : Array(LineMatch)
      regex_matches = [] of LineMatch
      unless patterns.empty?
        Log.debug { "line[#{line_index}] hex=#{line.bytes.map { |b| "%02x" % b }.join(" ")}" }
        line.scan(pattern) do |md|
          Log.debug { "  match: \"#{md[0]}\" at #{md.begin(0)}..#{md.end(0)} hex=#{md[0].bytes.map { |b| "%02x" % b }.join(" ")}" }
          regex_matches << regex_to_line_match(md)
        end
      end

      color_matches = [] of LineMatch
      spans = @colored_spans[line_index]? || [] of Tuple(Int32, Int32)
      min_len = Fingers.config.match_colored_min_len
      spans.each do |span|
        start_col, stop_col = span
        next if (stop_col - start_col) < min_len
        next if regex_matches.any? { |m| !(stop_col <= m.start || start_col >= m.stop) }
        text = line[start_col...stop_col]
        color_matches << LineMatch.new(start_col, stop_col, text, text, nil)
      end

      (regex_matches + color_matches).sort_by(&.start)
    end

    private def regex_to_line_match(md : Regex::MatchData) : LineMatch
      highlight_text = md[0]
      start = md.begin(0)
      stop = md.end(0)

      capture_idx = capture_indices.find { |i| md[i]? }
      if capture_idx
        captured = md[capture_idx]
        offset = {md.begin(capture_idx) - start, captured.size}
        LineMatch.new(start, stop, highlight_text, captured, offset)
      else
        LineMatch.new(start, stop, highlight_text, highlight_text, nil)
      end
    end

    # Walks the line, splicing the hint-formatted replacement string for each
    # match in place and copying surrounding characters verbatim.
    private def splice_matches(line : String, matches : Array(LineMatch), line_index : Int32) : String
      return line if matches.empty?

      builder = String::Builder.new
      pos = 0
      matches.each do |m|
        # Skip matches that somehow overlap an already-emitted region
        # (shouldn't happen given overlap resolution, but be defensive).
        next if m.start < pos
        builder << line[pos...m.start] if m.start > pos
        builder << replace_match(m, line_index)
        pos = m.stop
      end
      builder << line[pos..] if pos < line.size
      builder.to_s
    end

    private def replace_match(m : LineMatch, line_index : Int32) : String
      absolute_offset = {
        line_index,
        m.start + (m.capture_offset ? m.capture_offset.not_nil![0] : 0),
      }

      hint = hint_for_text(m.captured_text)

      # hint is longer than highlighted text, put it back in hint stack
      if hint.size > m.captured_text.size
        hints.push(hint)
        return m.highlight_text
      end

      build_target(m.captured_text, hint, absolute_offset)

      if !state.input.empty? && !hint.starts_with?(state.input)
        return m.highlight_text
      end

      formatter.format(
        hint: hint,
        highlight: m.highlight_text,
        selected: state.selected_hints.includes?(hint),
        offset: m.capture_offset,
      )
    end

    def pattern : Regex
      @pattern ||= begin
        src = "(#{patterns.join('|')})"
        Log.debug { "compiled pattern: #{src}" }
        Regex.new(src)
      end
    end

    def hints : Array(String)
      return @hints.as(Array(String)) if !@hints.nil?

      regenerate_hints!

      @hints.as(Array(String))
    end

    def regenerate_hints!
      @hints = huffman.generate_hints(alphabet: alphabet.clone, n: n_matches)
      @target_by_hint.clear
      @target_by_text.clear
    end

    def hint_for_text(text)
      return pop_hint! unless reuse_hints

      target = target_by_text[text]?

      if target.nil?
        return pop_hint!
      end

      target.hint
    end

    def pop_hint! : String
      hint = hints.pop?

      if hint.nil?
        raise "Too many matches"
      end

      hint
    end

    def build_target(text, hint, offset)
      target = Target.new(text, hint, offset)

      target_by_hint[hint] = target
      target_by_text[text] = target

      target
    end

    getter capture_indices : Array(Int32) do
      pattern.name_table.compact_map { |k, v| v == "match" ? k : nil }
    end

    def n_matches : Int32
      return @n_matches.as(Int32) if !@n_matches.nil?

      if reuse_hints
        @n_matches = count_unique_matches
      else
        @n_matches = count_matches
      end
    end

    def count_unique_matches
      match_set = Set(String).new

      lines.each_with_index do |line, line_index|
        collect_matches_for(line, line_index).each do |m|
          match_set.add(m.captured_text)
        end
      end

      @n_matches = match_set.size

      match_set.size
    end

    def count_matches
      result = 0

      lines.each_with_index do |line, line_index|
        result += collect_matches_for(line, line_index).size
      end

      result
    end

    def tab_positions_for(line)
      positions = [] of Int32
      offset = 0

      loop do
        index = line.index("\t", offset)

        break unless index
        positions << index
        offset = index + 1
      end

      positions
    end

    def expand_tabs(line, tab_positions)
      correction = 0
      line.gsub(/\t/) do |_|
        tab_position = tab_positions.shift?
        next "\t" unless tab_position
        spaces = 8 - ((tab_position + correction) % 8)
        correction += spaces - 1
        " " * spaces
      end
    end

    private property lines : Array(String)
  end
end
