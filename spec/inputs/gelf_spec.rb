# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/gelf"
require_relative "../support/helpers"
require "gelf"
require "flores/random"

describe LogStash::Inputs::Gelf do
  context "when interrupting the plugin" do
    let(:port) { Flores::Random.integer(1024..65535) }
    let(:host) { "127.0.0.1" }
    let(:chunksize) { 1420 }
    let(:producer) { InfiniteGelfProducer.new(host, port, chunksize) }
    let(:config) {  { "host" => host, "port" => port } }

    before { producer.run }
    after { producer.stop }


    it_behaves_like "an interruptible input plugin"
  end

  it "reads chunked gelf messages " do
    port = 12209
    host = "127.0.0.1"
    chunksize = 1420
    gelfclient = GELF::Notifier.new(host, port, chunksize)

    conf = <<-CONFIG
      input {
        gelf {
          port => "#{port}"
          host => "#{host}"
        }
      }
    CONFIG

    large_random = 2000.times.map{32 + rand(126 - 32)}.join("")

    messages = [
      "hello",
      "world",
      large_random,
      "we survived gelf!"
    ]

    events = input(conf) do |pipeline, queue|
      # send a first message until plugin is up and receives it
      while queue.size <= 0
        gelfclient.notify!("short_message" => "prime")
        sleep(0.1)
      end
      gelfclient.notify!("short_message" => "start")

      e = queue.pop
      while (e["message"] != "start")
        e = queue.pop
      end

      messages.each do |m|
  	    gelfclient.notify!("short_message" => m)
      end

      messages.map{queue.pop}
    end

    events.each_with_index do |e, i|
      insist { e["message"] } == messages[i]
      insist { e["host"] } == Socket.gethostname
    end
  end

  it "reads nested gelf messages " do
    port = 12210
    host = "127.0.0.1"
    chunksize = 1420
    gelfclient = GELF::Notifier.new(host, port, chunksize)

    conf = <<-CONFIG
      input {
        gelf {
          port => "#{port}"
          host => "#{host}"
          nested_objects => true
        }
      }
    CONFIG

    result = input(conf) do |pipeline, queue|
      # send a first message until plugin is up and receives it
      while queue.size <= 0
        gelfclient.notify!("short_message" => "prime")
        sleep(0.1)
      end
      gelfclient.notify!("short_message" => "start")

      e = queue.pop
      while (e.get("message") != "start")
        e = queue.pop
      end

      gelfclient.notify!({
        "short_message" => "test nested",
        "_toto.titi" => "objectValue",
        "_foo.0" => "first",
        "_foo.1" => "second",
        "_ca.0.titi" => "1",
        "_ca.1.titi" => "2",
        "_empty." => "pouet",
        "_not_an_array.0" => "bob",
        "_not_an_array.1" => "alice",
        "_not_an_array.length" => "carol",
      })

      queue.pop
    end

    insist { result.get("message") } == "test nested"
    insist { result.get("toto")["titi"] } == "objectValue"
    insist { result.get("foo") } == ["first", "second"]
    insist { result.get("ca")[0]["titi"] } == "1"
    insist { result.get("ca")[1]["titi"] } == "2"
    insist { result.get("empty")[""]} == "pouet"
    insist { result.get("not_an_array")["0"]} == "bob"
    insist { result.get("not_an_array")["1"]} == "alice"
    insist { result.get("not_an_array")["length"]} == "carol"
    insist { result.get("host") } == Socket.gethostname
  end

  context "timestamp coercion" do
    # these test private methods, this is advisable for now until we roll out this coercion in the Timestamp class
    # and remove this

    context "integer numeric values" do
      it "should coerce" do
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800).to_iso8601).to eq("2000-01-01T05:00:00.000Z")
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800).usec).to eq(0)
      end
    end

    context "float numeric values" do
      # using explicit and certainly useless to_f here just to leave no doubt about the numeric type involved

      it "should coerce and preserve millisec precision in iso8601" do
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.1.to_f).to_iso8601).to eq("2000-01-01T05:00:00.100Z")
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.12.to_f).to_iso8601).to eq("2000-01-01T05:00:00.120Z")
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.123.to_f).to_iso8601).to eq("2000-01-01T05:00:00.123Z")
      end

      it "should coerce and preserve usec precision" do
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.1.to_f).usec).to eq(100000)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.12.to_f).usec).to eq(120000)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.123.to_f).usec).to eq(123000)

        # since Java Timestamp in 2.3+ relies on JodaTime which supports only millisec precision
        # the usec method will only be precise up to millisec.
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.1234.to_f).usec).to be_within(1000).of(123400)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.12345.to_f).usec).to be_within(1000).of(123450)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(946702800.123456.to_f).usec).to be_within(1000).of(123456)
      end
    end

    context "BigDecimal numeric values" do
      it "should coerce and preserve millisec precision in iso8601" do
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.1")).to_iso8601).to eq("2000-01-01T05:00:00.100Z")
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.12")).to_iso8601).to eq("2000-01-01T05:00:00.120Z")
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.123")).to_iso8601).to eq("2000-01-01T05:00:00.123Z")
      end

      it "should coerce and preserve usec precision" do
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.1")).usec).to eq(100000)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.12")).usec).to eq(120000)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.123")).usec).to eq(123000)

        # since Java Timestamp in 2.3+ relies on JodaTime which supports only millisec precision
        # the usec method will only be precise up to millisec.
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.1234")).usec).to be_within(1000).of(123400)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.12345")).usec).to be_within(1000).of(123450)
        expect(LogStash::Inputs::Gelf.coerce_timestamp(BigDecimal.new("946702800.123456")).usec).to be_within(1000).of(123456)
      end
    end
  end

  context "json timestamp coercion" do
    # these test private methods, this is advisable for now until we roll out this coercion in the Timestamp class
    # and remove this

    it "should coerce integer numeric json timestamp input" do
      event = LogStash::Inputs::Gelf.new_event("{\"timestamp\":946702800}", "dummy")
      expect(event.timestamp.to_iso8601).to eq("2000-01-01T05:00:00.000Z")
    end

    it "should coerce float numeric value and preserve milliseconds precision in iso8601" do
      event = LogStash::Inputs::Gelf.new_event("{\"timestamp\":946702800.123}", "dummy")
      expect(event.timestamp.to_iso8601).to eq("2000-01-01T05:00:00.123Z")
    end

    it "should coerce float numeric value and preserve usec precision" do
      # since Java Timestamp in 2.3+ relies on JodaTime which supports only millisec precision
      # the usec method will only be precise up to millisec.

      event = LogStash::Inputs::Gelf.new_event("{\"timestamp\":946702800.123456}", "dummy")
      expect(event.timestamp.usec).to be_within(1000).of(123456)
    end
  end

  context "when an invalid JSON is fed to the listener" do
    subject { LogStash::Inputs::Gelf.new_event(message, "host") }
    let(:message) { "Invalid JSON message" }

    if LogStash::Event.respond_to?(:from_json)
      context "default :from_json parser output" do
        it { should be_a(LogStash::Event) }

        it "falls back to plain-text" do
          expect(subject["message"]).to eq(message)
        end

        it "tags message with _jsonparsefailure" do
          expect(subject["tags"]).to include("_jsonparsefailure")
        end

        it "tags message with _fromjsonparser" do
          expect(subject["tags"]).to include("_fromjsonparser")
        end
      end
    else
      context "legacy JSON parser output" do
        it { should be_a(LogStash::Event) }

        it "falls back to plain-text" do
          expect(subject["message"]).to eq(message)
        end

        it "tags message with _jsonparsefailure" do
          expect(subject["tags"]).to include("_jsonparsefailure")
        end

        it "tags message with _legacyjsonparser" do
          expect(subject["tags"]).to include("_legacyjsonparser")
        end
      end
    end
  end
end
