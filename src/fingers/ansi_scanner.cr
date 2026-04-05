module Fingers
  # Result of scanning a line with ANSI escape sequences.
  # `visible` is the stripped text (what the hinter should match against).
  # `colored_spans` is a list of {start, end} character offsets into
  # `visible` where the foreground color was non-default.
  struct AnsiScanResult
    getter visible : String
    getter colored_spans : Array(Tuple(Int32, Int32))

    def initialize(@visible : String, @colored_spans : Array(Tuple(Int32, Int32)))
    end
  end

  # Strips ANSI escape sequences from a line and records where the foreground
  # color differed from the terminal default.
  #
  # Recognized escape forms:
  #   CSI SGR:  \e[...m   — foreground state tracked, other attributes ignored
  #   CSI any:  \e[...X   — consumed, ignored
  #   OSC:      \e]...\a  or  \e]...\e\\  — consumed, ignored (covers OSC 8 hyperlinks)
  #   Other:    \eX       — intro byte consumed, next byte consumed
  #
  # Colored spans merge adjacent runs of non-default foreground, even if
  # the specific color changes (red → green → default yields a single span).
  class AnsiScanner
    def self.scan(line : String) : AnsiScanResult
      visible = String::Builder.new
      spans = [] of Tuple(Int32, Int32)
      visible_col = 0
      span_start : Int32? = nil
      fg_active = false

      chars = line.chars
      i = 0
      while i < chars.size
        ch = chars[i]
        if ch == '\e'
          i += 1
          break if i >= chars.size
          intro = chars[i]
          if intro == '['
            i += 1
            params_start = i
            # Read CSI parameter bytes (0x20-0x3f) then the single final byte (0x40-0x7e).
            while i < chars.size
              c_ord = chars[i].ord
              break if c_ord >= 0x40 && c_ord <= 0x7e
              i += 1
            end
            if i < chars.size
              final = chars[i]
              params = chars[params_start...i].join
              i += 1
              if final == 'm'
                new_active = apply_sgr(params, fg_active)
                if new_active && !fg_active
                  span_start = visible_col
                elsif !new_active && fg_active
                  spans << {span_start.not_nil!, visible_col}
                  span_start = nil
                end
                fg_active = new_active
              end
            end
          elsif intro == ']'
            # OSC: consume until BEL (\a) or ST (\e\)
            i += 1
            while i < chars.size
              c = chars[i]
              if c == '\a'
                i += 1
                break
              elsif c == '\e'
                i += 1
                if i < chars.size && chars[i] == '\\'
                  i += 1
                end
                break
              end
              i += 1
            end
          else
            # Unknown escape form: skip one byte and move on.
            i += 1
          end
        else
          visible << ch
          visible_col += 1
          i += 1
        end
      end

      # Close any span that's still open at end of line.
      if fg_active && !span_start.nil?
        spans << {span_start.not_nil!, visible_col}
      end

      AnsiScanResult.new(visible.to_s, spans)
    end

    # Applies an SGR parameter list to the current foreground-active state
    # and returns the new state.
    #
    # Foreground-affecting codes:
    #   0      reset all           → inactive
    #   30-37  basic fg            → active
    #   38;5;N 256-color fg        → active (consumes 2 extra params)
    #   38;2;R;G;B truecolor fg    → active (consumes 4 extra params)
    #   39     default fg          → inactive
    #   90-97  bright fg           → active
    # Everything else (bold, italic, underline, bg, reverse, …) is ignored.
    private def self.apply_sgr(params : String, current : Bool) : Bool
      return false if params.empty? # bare \e[m is equivalent to \e[0m
      parts = params.split(';').map { |p| p.empty? ? 0 : (p.to_i? || 0) }
      active = current
      i = 0
      while i < parts.size
        n = parts[i]
        case n
        when 0
          active = false
        when 30..37, 90..97
          active = true
        when 38
          if i + 1 < parts.size
            if parts[i + 1] == 5 && i + 2 < parts.size
              active = true
              i += 2
            elsif parts[i + 1] == 2 && i + 4 < parts.size
              active = true
              i += 4
            end
          end
        when 39
          active = false
        end
        i += 1
      end
      active
    end
  end
end
