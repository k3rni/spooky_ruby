require 'pp'
require 'byebug'
require 'logger'

Event = Struct.new(:time, :direction) do
  def inspect
    "<#{direction == :up ? 'U' : 'D'} %.2f>" % time
  end
end

def man_demo
  # 0xFF55 , which is eight short pulses followed by four longer ones
  header = %w(_-_-_-_-_-_-_-_- -__--__--__--__-)
  # 5
  length = %(-_-_-_-_-__--__-)
  # 0x8a, which is 0x75 bit-flipped
  cs = "-__-_-_--__--__-"
  # H E L L O
  message = %w(_--__-_--__-_-_-
               _--__-_-_--__--_
               _--__-_--_-__-_-
               _--__-_--_-__-_-
               _--__-_--_-_-_-_)
  build_events [*header, length, cs, *message].join('')
end

def build_events(str, clock=50, jitter=3)
  start = 0 # Process.clock_gettime Process::CLOCK_MONOTONIC
  pos = 0
  rx = /(\-_|_\-)/
  events = []
  while match = str.match(rx, pos)
    pat = match[1]
    pos = match.begin(0) + 1
    time = start + match.begin(0) * clock + rand() * jitter
    events << Event.new(time, pat == "_-" ? :up : :down)
  end
  events
end

class SpookyDecoder
  MAX_POSSIBLE_DELAY = 255
  SHORT_TRANSITIONS = 8
  RINGBUF_SIZE = 16
  MASK = 15

  def initialize
    reset
    @last = -1
    @index = 0
    @timings = Array.new(RINGBUF_SIZE, 0)
    @output_buffer = []
    @checksum = 0
  end

  def logger
    @logger ||= Logger.new(STDERR)
  end

  def body
    @output_buffer
  end

  def reset
    @mode = :header
    @ticks = 0
    @bit_index = 0x80
    @interval = 0
    @bit_accum = 0
    @payload_length = 0
    @pre_ticks = 0
  end

  def feed(bit)
    logger.info("mode = #{@mode} bit = %d" % bit)
    @ticks += 1
    case @mode
    when :header
      step_header(bit)
      return nil
    when :length
      step_length(bit)
      return nil
    when :checksum
      step_checksum(bit)
      return nil
    when :payload
      if step_payload(bit)
        return :done
      end
    end
  end

  def approx_eq(a, b)
    tol = b < 4 ? 1 : b / 4
    (a - b).abs < tol
  end

  def append_to_ringbuf(offset)
    @timings[@index & MASK] = @index == 0 ? MAX_POSSIBLE_DELAY : @ticks - offset
    log_ringbuf
    @index += 1
  end

  def log_ringbuf
    rb = @timings.each_with_index.map do |tm, i|
      if i == @index % MASK
        "*#{tm}"
      else
        "#{tm}"
      end
    end.join(" ")
    logger.info("[#{rb}]")
  end

  def step_header(bit)
    return if bit == @last

    append_to_ringbuf(0)
    @ticks = 0

    total = 0
    avg = 0
    long_count = 0

    (0...RINGBUF_SIZE).each do |i|
      idx = (@index + i) & MASK
      val = @timings[idx]
      break if val == MAX_POSSIBLE_DELAY

      if i < RINGBUF_SIZE - 8
        total += val
        if i == RINGBUF_SIZE - 8 - 1
          avg = total / (RINGBUF_SIZE - 8)
          logger.info("total = #{total} avg = #{avg}")
        end
      elsif avg > 0
        long_count += 1 if approx_eq(val, 2*avg)
        logger.info("long = #{long_count}")
      end
    end

    if long_count == 8
      @mode = :length
      @ticks = 0
      @interval = avg
    end
    @last = bit
  end

  def longer_than_tolerance_allows(t, i)
    max = i + (i / 4)
    t > max
  end

  def sink_bit_cb(bit, save_ticks=false)
    res = false

    if bit == @last
      if longer_than_tolerance_allows(@ticks - @pre_ticks, 2 * @interval)
        reset
      end
      return res
    end

    @last = bit

    if approx_eq(@ticks, @interval) && @pre_ticks == 0 # Setup edge
      if save_ticks
        append_to_ringbuf(0)
        @pre_ticks = @ticks
      end
    elsif approx_eq(@ticks, 2 * @interval) # Actual edge
      append_to_ringbuf(@pre_ticks) if save_ticks
      @pre_ticks = 0
      @ticks = 0
      if sink_bit(bit)
        res = yield
        @bit_accum = 0
      end
    end

    res
  end

  def step_length(bit)
    sink_bit_cb(bit) do
      @payload_length = @bit_accum
      # Verify that it's not zero, because we don't care if too long
      if @payload_length == 0
        reset
      else
        @mode = :checksum
      end
    end

    return false
  end

  def step_checksum(bit)
    sink_bit_cb(bit) do
      @checksum = @bit_accum
      logger.info("Checksum is %02x" % @checksum)
      @index = 0
      @mode = :payload
    end

    return false
  end

  def step_payload(bit)
    sink_bit_cb(bit) do
      byte = @bit_accum
      logger.info("Got byte %02x" % byte)
      @output_buffer.push(byte)
      @index += 1
      if @index == @payload_length
        cs = calculate_checksum
        logger.info("Checksum expected %02x got %02x" % [@checksum, cs])
        if cs == @checksum
          logger.info("success! %d bytes" % @index)
          # Original code would invoke another callback here
        else
          logger.error("checksum failure")
        end
        reset
        @index = 0
        return true
      end
    end
    return false
  end

  def sink_bit(bit)
    if bit == 0
      # nothing to do
    else
      @bit_accum |= @bit_index
    end

    @bit_index >>= 1
    if @bit_index == 0
      @bit_index = 0x80
      return true
    end

    return false
  end

  def calculate_checksum
    s = @output_buffer.inject(0) { |acc, b| (acc + b) % 0xFF }
    s ^ 0xFF # Invert bits
  end
end

events = man_demo
puts events.inspect
dec = SpookyDecoder.new
dec.logger.level = Logger::INFO
dec.logger.formatter = -> (s, d, p, msg) { "#{d.tv_sec}.#{d.tv_usec} #{msg}\n" }
slen = events.max_by(&:time).time
SAMPLING = 16
t = 0
while t < slen + 50
  ev = events.select { |ev| ev.time <= t }.last
  if ev
    res = dec.feed(ev.direction == :up ? 1 : 0)
    # puts "#{t} #{res}"
  end
  t += SAMPLING
end
