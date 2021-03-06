# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/json"
require "logstash/timestamp"
require "stud/interval"
require "date"
require "socket"

# This input will read GELF messages as events over the network,
# making it a good choice if you already use Graylog2 today.
#
# The main use case for this input is to leverage existing GELF
# logging libraries such as the GELF log4j appender. A library used
# by this plugin has a bug which prevents it parsing uncompressed data.
# If you use the log4j appender you need to configure it like this to force
# gzip even for small messages:
#
#   <Socket name="logstash" protocol="udp" host="logstash.example.com" port="5001">
#      <GelfLayout compressionType="GZIP" compressionThreshold="1" />
#   </Socket>
#
#
class LogStash::Inputs::Gelf < LogStash::Inputs::Base
  config_name "gelf"

  default :codec, "plain"

  # The IP address or hostname to listen on.
  config :host, :validate => :string, :default => "0.0.0.0"

  # The port to listen on. Remember that ports less than 1024 (privileged
  # ports) may require root to use.
  config :port, :validate => :number, :default => 12201

  # Whether or not to remap the GELF message fields to Logstash event fields or
  # leave them intact.
  #
  # Remapping converts the following GELF fields to Logstash equivalents:
  #
  # * `full\_message` becomes `event["message"]`.
  # * if there is no `full\_message`, `short\_message` becomes `event["message"]`.
  config :remap, :validate => :boolean, :default => true

  # Whether or not to remove the leading `\_` in GELF fields or leave them
  # in place. (Logstash < 1.2 did not remove them by default.). Note that
  # GELF version 1.1 format now requires all non-standard fields to be added
  # as an "additional" field, beginning with an underscore.
  #
  # e.g. `\_foo` becomes `foo`
  #
  config :strip_leading_underscore, :validate => :boolean, :default => true

  # Whether or not to process dots in fields or leave them in place
  config :nested_objects, :validate => :boolean, :default => false

  RECONNECT_BACKOFF_SLEEP = 5
  TIMESTAMP_GELF_FIELD = "timestamp".freeze
  SOURCE_HOST_FIELD = "source_host".freeze
  MESSAGE_FIELD = "message"
  TAGS_FIELD = "tags"
  PARSE_FAILURE_TAG = "_jsonparsefailure"
  PARSE_FAILURE_LOG_MESSAGE = "JSON parse failure. Falling back to plain-text"

  public
  def initialize(params)
    super
    BasicSocket.do_not_reverse_lookup = true
  end # def initialize

  public
  def register
    require 'gelfd'
  end # def register

  public
  def run(output_queue)
    begin
      # udp server
      udp_listener(output_queue)
    rescue => e
      unless stop?
        @logger.warn("gelf listener died", :exception => e, :backtrace => e.backtrace)
        Stud.stoppable_sleep(RECONNECT_BACKOFF_SLEEP) { stop? }
        retry unless stop?
      end
    end # begin
  end # def run

  public
  def stop
    @udp.close
  rescue IOError # the plugin is currently shutting down, so its safe to ignore theses errors
  end

  private
  def udp_listener(output_queue)
    @logger.info("Starting gelf listener", :address => "#{@host}:#{@port}")

    @udp = UDPSocket.new(Socket::AF_INET)
    @udp.bind(@host, @port)

    while !stop?
      line, client = @udp.recvfrom(8192)

      begin
        data = Gelfd::Parser.parse(line)
      rescue => ex
        @logger.error("Gelfd failed to parse a message, skipping", :exception => ex, :backtrace => ex.backtrace, :line => line)
        next
      end

      # Gelfd parser outputs null if it received and cached a non-final chunk
      next if data.nil?

      begin
        event = self.class.new_event(data, client[3])
        next if event.nil?
      rescue => ex
        @logger.error("Could not create event, skipping", :exception => ex, :backtrace => ex.backtrace, :data => data)
        next
      end

      begin
        remap_gelf(event) if @remap
        strip_leading_underscore(event) if @strip_leading_underscore
        nested_objects(event) if @nested_objects
        decorate(event)
      rescue => ex
        @logger.error("Could not process event, skipping", :exception => ex, :backtrace => ex.backtrace, :event => event)
        next
      end

      output_queue << event
    end
  end # def udp_listener

  # generate a new LogStash::Event from json input and assign host to source_host event field.
  # @param json_gelf [String] GELF json data
  # @param host [String] source host of GELF data
  # @return [LogStash::Event] new event with parsed json gelf, assigned source host and coerced timestamp
  def self.new_event(json_gelf, host)
    event = parse(json_gelf)
    return if event.nil?

    event.set(SOURCE_HOST_FIELD, host)

    if (gelf_timestamp = event.get(TIMESTAMP_GELF_FIELD)).is_a?(Numeric)
      event.timestamp = self.coerce_timestamp(gelf_timestamp)
      event.remove(TIMESTAMP_GELF_FIELD)
    end

    event
  end

  # transform a given timestamp value into a proper LogStash::Timestamp, preserving microsecond precision
  # and work around a JRuby issue with Time.at loosing fractional part with BigDecimal.
  # @param timestamp [Numeric] a Numeric (integer, float or bigdecimal) timestampo representation
  # @return [LogStash::Timestamp] the proper LogStash::Timestamp representation
  def self.coerce_timestamp(timestamp)
    # bug in JRuby prevents correcly parsing a BigDecimal fractional part, see https://github.com/elastic/logstash/issues/4565
    timestamp.is_a?(BigDecimal) ? LogStash::Timestamp.at(timestamp.to_i, timestamp.frac * 1000000) : LogStash::Timestamp.at(timestamp)
  end

  # from_json_parse uses the Event#from_json method to deserialize and directly produce events
  def self.from_json_parse(json)
    # from_json will always return an array of item.
    # in the context of gelf, the payload should be an array of 1
    LogStash::Event.from_json(json).first
  rescue LogStash::Json::ParserError => e
    logger.error(PARSE_FAILURE_LOG_MESSAGE, :error => e, :data => json)
    LogStash::Event.new(MESSAGE_FIELD => json, TAGS_FIELD => [PARSE_FAILURE_TAG, '_fromjsonparser'])
  end # def self.from_json_parse

  # legacy_parse uses the LogStash::Json class to deserialize json
  def self.legacy_parse(json)
    o = LogStash::Json.load(json)
    LogStash::Event.new(o)
  rescue LogStash::Json::ParserError => e
    logger.error(PARSE_FAILURE_LOG_MESSAGE, :error => e, :data => json)
    LogStash::Event.new(MESSAGE_FIELD => json, TAGS_FIELD => [PARSE_FAILURE_TAG, '_legacyjsonparser'])
  end # def self.parse

  # keep compatibility with all v2.x distributions. only in 2.3 will the Event#from_json method be introduced
  # and we need to keep compatibility for all v2 releases.
  class << self
    alias_method :parse, LogStash::Event.respond_to?(:from_json) ? :from_json_parse : :legacy_parse
  end

  private
  def remap_gelf(event)
    if event.get("full_message") && !event.get("full_message").empty?
      event.set("message", event.get("full_message").dup)
      event.remove("full_message")
      if event.get("short_message") == event.get("message")
        event.remove("short_message")
      end
    elsif event.get("short_message") && !event.get("short_message").empty?
      event.set("message", event.get("short_message").dup)
      event.remove("short_message")
    end
  end # def remap_gelf

  private
  def strip_leading_underscore(event)
     # Map all '_foo' fields to simply 'foo'
     event.to_hash.keys.each do |key|
       next unless key[0,1] == "_"
       new_key = key[1..-1]
       # https://github.com/logstash-plugins/logstash-input-gelf/issues/25
       next if ['version', 'host', 'short_message', 'full_message', 'timestamp', 'level', 'facility', 'line', 'file'].include? new_key # GELF inner fields
       event.set(new_key, event.get(key))
       event.remove(key)
     end
  end # deef removing_leading_underscores

  private
  def nested_objects(event)
    # process nested, create objects as needed, when key is 0, create an array. if object already exists and is an array push it.
    base_target = event.to_hash
    base_target.keys.each do |key|
      next unless key.include? "."
      value = event.get(key)
      previous_key = nil
      first_key = nil
      target = base_target

      keys = key.split(".")
      if key =~ /\.$/
        keys.push("");
      end

      keys.each do |subKey|
        if previous_key.nil?
          first_key = subKey
        else#skip first subKey
          if !container_has_element?(target, previous_key)
            if subKey =~ /^\d+$/
              target = set_container_element(target, previous_key, Array.new)
            else
              target = set_container_element(target, previous_key, Hash.new)
            end
          end
          target = get_container_element(target, previous_key)
        end
        previous_key = subKey
      end
      target = set_container_element(target, previous_key, value)
      event.remove(key)
      event.set(first_key, base_target[first_key])
    end
  end

  private
  def get_container_element(container, key)
    if container.is_a?(Array)
      container[Integer(key)]
    elsif container.is_a?(Hash)
      container[key]
    else #Event
      raise "not an array or hash"
    end
  end

  private
  def set_container_element(container, key, value)
    if container.is_a?(Array)
      if !/\A\d+\z/.match(key)
        #key is not an integer, so we need to convert array to hash
        container = Hash[container.map.with_index { |x, i| [i, x] }]
        container[key] = value
        return container
      else
        container[Integer(key)] = value
      end
    elsif container.is_a?(Hash)
      container[key] = value
    else #Event
      raise "not an array or hash"
    end

    return container
  end

  private
  def container_has_element?(container, key)
    if container.is_a?(Array)
      if !/\A\d+\z/.match(key)
        return false
      else
        !container[Integer(key)].nil?
      end
    elsif container.is_a?(Hash)
      container.key?(key)
    else
      raise "not an array or hash"
    end
  end
end # class LogStash::Inputs::Gelf
