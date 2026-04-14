require "./dirs"

module Fingers
  class InputSocket
    @path : String
    @fd : File | Nil

    def initialize(path = Fingers::Dirs::SOCKET_PATH.to_s)
      @path = path
    end

    # Create the FIFO and open it, but don't start reading yet.  Split
    # from on_input so callers can establish the IPC channel BEFORE
    # flipping external state (e.g. tmux key-table) that must be undone
    # on failure.
    def prepare
      remove_socket_file
      create_fifo

      # Open read-write so the read end never sees EOF when a writer
      # disconnects — our own write fd keeps the pipe open.
      # Non-blocking mode lets Crystal's event loop schedule other fibers
      # while waiting for data.
      @fd = File.open(path, "r+")
      @fd.not_nil!.blocking = false
    end

    def on_input
      prepare if @fd.nil?

      loop do
        line = @fd.not_nil!.gets
        # gets returns nil only on EOF/error — with r+ we hold a
        # write-end ourselves so EOF shouldn't happen.  If it does,
        # avoid a tight busy-loop that burns CPU forever.
        break if line.nil?
        yield line
      end
    ensure
      @fd.try(&.close)
      @fd = nil
    end

    def send_message(cmd)
      # O_WRONLY | O_NONBLOCK: if no reader is attached (e.g. main
      # fingers process already died), open returns ENXIO immediately
      # instead of blocking forever.  The caller's `|| switch-client -T
      # root` fallback then fires and the user gets unstuck.
      fd = LibC.open(path, LibC::O_WRONLY | LibC::O_NONBLOCK)
      raise File::Error.from_errno("no reader on fifo", file: path) if fd < 0

      file = IO::FileDescriptor.new(fd, blocking: true)
      begin
        file.puts(cmd)
      ensure
        file.close
      end
    end

    def close
      @fd.try(&.close)
      @fd = nil
      remove_socket_file
    end

    private getter :path

    private def create_fifo
      status = Process.run("mkfifo", [path])
      unless status.success?
        raise "mkfifo failed for #{path} (exit status #{status.exit_code})"
      end
    end

    def remove_socket_file
      File.delete(path) if File.exists?(path)
    end
  end
end
