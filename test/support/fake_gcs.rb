# frozen_string_literal: true

require "socket"

# Google Cloud Storage's JSON API over real HTTP, as far as TranscriptStorage::GcsClient
# uses it: resumable uploads with a precondition and an MD5, metadata, and media by
# generation. Also answers the OAuth token exchange.
class FakeGcs
  Stored = Struct.new(:bytes, :generation, :content_type, :metadata, keyword_init: true)

  attr_reader :objects, :calls
  # Set to a status to answer every request under /upload or /storage with it.
  attr_accessor :refuse
  # A lambda given the stored bytes; what it returns is served instead.
  attr_accessor :tamper
  # Called with (name, body) as an upload completes, before it is checked.
  attr_accessor :before_finish
  # What the upload's Location header is built from; a test points it elsewhere.
  attr_accessor :location_base

  def self.start = new.tap(&:start)

  def initialize
    @objects = {}
    @uploads = {}
    @calls = []
    @generation = 1_000
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @location_base = url
    @thread = Thread.new { loop { Thread.new(@server.accept) { |socket| serve(socket) } } }
    @thread.report_on_exception = false
  end

  def stop
    @thread&.kill
    @server&.close
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  # A key the real ServiceAccount accepts and signs with.
  def self.key_json
    @key_json ||= JSON.generate(client_email: "copier@example.iam.gserviceaccount.com", private_key: OpenSSL::PKey::RSA.new(2048).to_pem)
  end

  private

  def serve(socket)
    verb, target, = socket.gets.to_s.split(" ")
    return if target.nil?

    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s.b
    uri = URI(target)
    query = URI.decode_www_form(uri.query.to_s).to_h
    @calls << [ verb, uri.path, query, headers ]
    status, out, extra = answer(verb, uri.path, query, headers, body)
    out = out.to_s.b
    socket.write("HTTP/1.1 #{status} X\r\nContent-Length: #{out.bytesize}\r\nConnection: close\r\n")
    (extra || {}).each { |k, v| socket.write("#{k}: #{v}\r\n") }
    socket.write("\r\n")
    socket.write(out)
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close
  end

  def answer(verb, path, query, headers, body)
    return [ 200, JSON.generate(access_token: "fake-token", expires_in: 3600) ] if path == "/token"
    return [ refuse, "denied" ] if refuse
    return [ 401, "" ] unless verb == "PUT" || headers["authorization"] == "Bearer fake-token"

    case [ verb, path ]
    in [ "POST", %r{\A/upload/storage/v1/b/[^/]+/o\z} ] then start_upload(query, body)
    in [ "PUT", %r{\A/session/} ] then finish_upload(path.split("/").last, body)
    in [ "GET", %r{\A/storage/v1/b/[^/]+/o/(.+)\z} ] then read(URI.decode_uri_component(path.split("/o/", 2).last), query)
    else [ 404, "" ]
    end
  end

  def start_upload(query, body)
    return [ 412, "" ] if query["ifGenerationMatch"] == "0" && objects.key?(query["name"])

    id = SecureRandom.hex(4)
    @uploads[id] = JSON.parse(body)
    [ 200, "", { "Location" => "#{location_base}/session/#{id}" } ]
  end

  def finish_upload(id, body)
    request = @uploads.delete(id) or return [ 404, "" ]
    before_finish&.call(request["name"], body)
    return [ 412, "" ] if objects.key?(request["name"])
    return [ 400, "" ] if Digest::MD5.base64digest(body) != request["md5Hash"]

    stored = Stored.new(bytes: body, generation: @generation += 1, content_type: request["contentType"], metadata: request["metadata"])
    objects[request["name"]] = stored
    [ 200, JSON.generate(generation: stored.generation.to_s) ]
  end

  def read(name, query)
    stored = objects[name]
    return [ 404, "" ] if stored.nil? || (query["generation"] && query["generation"].to_i != stored.generation)
    return [ 200, JSON.generate(generation: stored.generation.to_s) ] unless query["alt"] == "media"

    [ 200, tamper ? tamper.call(stored.bytes) : stored.bytes ]
  end
end
