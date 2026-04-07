require "./dirs"

module Fingers
  class InputSocket
    @path : String
    @fd : File | Nil

    def initialize(path = Fingers::Dirs::SOCKET_PATH.to_s)
      @path = path
    end

    def on_input
      remove_socket_file
      create_fifo

      # Open read-write so the read end never sees EOF when a writer
      # disconnects — our own write fd keeps the pipe open.
      # Non-blocking mode lets Crystal's event loop schedule other fibers
      # while waiting for data.
      @fd = File.open(path, "r+")
      @fd.not_nil!.blocking = false

      loop do
        line = @fd.not_nil!.gets
        yield (line || "")
      end
    ensure
      @fd.try(&.close)
      @fd = nil
    end

    def send_message(cmd)
      File.open(path, "w") do |f|
        f.puts(cmd)
      end
    end

    def close
      @fd.try(&.close)
      @fd = nil
      remove_socket_file
    end

    private getter :path

    private def create_fifo
      Process.run("mkfifo", [path])
    end

    def remove_socket_file
      File.delete(path) if File.exists?(path)
    end
  end
end
