# frozen_string_literal: true

require "net/http"
require "zlib"

module TranscriptStorage
  # The three calls Zimmer makes to Google Cloud Storage: create an object that does not
  # exist, read one object's metadata, and read one object's bytes. There is no overwrite
  # and no delete here, on purpose.
  #
  # No Google SDK, like ParameterStore. Bodies are streamed in both directions, so an
  # object's size is never this process's memory.
  class GcsClient
    include RedactedInspect

    API_BASE = "https://storage.googleapis.com"
    SCOPE = "https://www.googleapis.com/auth/devstorage.read_write"
    OPEN_TIMEOUT = 10
    IO_TIMEOUT = 120

    attr_reader :bucket

    def initialize(bucket:, account:, api_base: API_BASE)
      @bucket = bucket
      @account = account
      @api_base = api_base.chomp("/")
    end

    def redacted_inspect_fields = { bucket: bucket }

    # Creates +name+ from the file at +path+ and returns its generation. If the object is
    # already there its generation is returned and nothing is written: names carry a
    # digest, and the caller verifies what the object holds either way.
    #
    # Looked for first, rather than left to the precondition: an account that may not
    # overwrite could be refused outright before the precondition is weighed. The
    # precondition still settles a race.
    def create(name, path:, content_type:, labels: {})
      existing = generation(name)
      return existing if existing

      session_uri = start_upload(name, path, content_type, labels)
      created = upload(session_uri, name, path, content_type) if session_uri
      created || generation(name) || raise(RequestFailed, "#{name} was neither created nor found")
    end

    # The generation of the live object, or nil when there is none.
    def generation(name)
      uri = object_uri(name)
      response = perform(uri, authorized(Net::HTTP::Get.new(uri)))
      return nil if response.code.to_i == 404

      expect_success!(response, "metadata of #{name}")
      generation_in(response, name)
    end

    # Yields the bytes of exactly that generation, in pieces.
    def read(name, generation:)
      uri = object_uri(name, alt: "media", generation: generation)
      request = authorized(Net::HTTP::Get.new(uri))
      # The stored bytes, not a decoding of them.
      request["Accept-Encoding"] = "identity"
      http(uri) do |connection|
        connection.request(request) do |response|
          raise VerificationFailed, "#{name} has no generation #{generation}" if response.code.to_i == 404

          expect_success!(response, "read of #{name}")
          response.read_body { |piece| yield piece }
        end
      end
      nil
    rescue *NETWORK_ERRORS => e
      raise RequestFailed, "read of #{name} failed: #{e.class}"
    end

    # [SHA-256 of that generation's bytes, how many bytes the object is]. Gunzipped first
    # when asked, and then the whole object must be that one gzip stream.
    def digest(name, generation:, gunzip:)
      sha = Digest::SHA256.new
      size = 0
      inflater = Zlib::Inflate.new(16 + Zlib::MAX_WBITS) if gunzip
      read(name, generation: generation) do |piece|
        size += piece.bytesize
        gunzip ? inflater.inflate(piece) { |part| sha.update(part) } : sha.update(piece)
      end
      raise VerificationFailed, "#{name} is truncated" if gunzip && !inflater.finished?
      raise VerificationFailed, "#{name} holds more than one gzip stream" if gunzip && inflater.total_in != size

      [ sha.hexdigest, size ]
    rescue Zlib::Error => e
      raise VerificationFailed, "#{name} does not decompress: #{e.class}"
    ensure
      inflater&.close
    end

    NETWORK_ERRORS = [ SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError ].freeze

    private

    # The new object's generation, or nil when the name was taken meanwhile.
    def upload(session_uri, name, path, content_type)
      File.open(path, "rb") do |file|
        request = Net::HTTP::Put.new(session_uri)
        request["Content-Type"] = content_type
        request["Content-Length"] = file.size.to_s
        request.body_stream = file
        response = perform(session_uri, request)
        next if response.code.to_i == 412

        expect_success!(response, "upload of #{name}")
        generation_in(response, name)
      end
    end

    def generation_in(response, name)
      Integer(JSON.parse(response.body).fetch("generation"))
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError
      raise RequestFailed, "the answer about #{name} names no generation"
    end

    # The resumable session's URI, or nil when the object already exists. `md5Hash` makes
    # the store reject bytes that were damaged on the way.
    def start_upload(name, path, content_type, labels)
      uri = URI("#{@api_base}/upload/storage/v1/b/#{bucket}/o")
      uri.query = URI.encode_www_form(uploadType: "resumable", name: name, ifGenerationMatch: 0)
      request = authorized(Net::HTTP::Post.new(uri))
      request["Content-Type"] = "application/json; charset=UTF-8"
      request["X-Upload-Content-Type"] = content_type
      request["X-Upload-Content-Length"] = File.size(path).to_s
      request.body = JSON.generate(
        name: name, contentType: content_type, md5Hash: Digest::MD5.file(path).base64digest,
        "metadata" => labels.transform_values(&:to_s)
      )
      response = perform(uri, request)
      return nil if response.code.to_i == 412

      expect_success!(response, "start of upload of #{name}")
      location = URI(response["Location"].to_s)
      # The session URI is a capability; it must be the same store's.
      raise RequestFailed, "upload of #{name} was redirected elsewhere" unless [ location.scheme, location.host, location.port ] == [ uri.scheme, uri.host, uri.port ]

      location
    rescue URI::InvalidURIError
      raise RequestFailed, "start of upload of #{name} returned no usable location"
    end

    def object_uri(name, query = {})
      uri = URI("#{@api_base}/storage/v1/b/#{bucket}/o/#{ERB::Util.url_encode(name)}")
      uri.query = URI.encode_www_form(query) if query.any?
      uri
    end

    def authorized(request)
      request["Authorization"] = "Bearer #{@account.access_token(scope: SCOPE)}"
      request
    rescue ParameterStore::AuthError => e
      raise RequestFailed, "could not get an access token: #{e.message}"
    rescue OpenSSL::PKey::PKeyError, *NETWORK_ERRORS => e
      raise RequestFailed, "could not get an access token: #{e.class}"
    end

    def perform(uri, request)
      http(uri) { |connection| connection.request(request) }
    rescue Zlib::Error, *NETWORK_ERRORS => e
      raise RequestFailed, "#{request.method} failed: #{e.class}"
    end

    def http(uri, &block)
      connection = Net::HTTP.new(uri.hostname, uri.port)
      connection.use_ssl = uri.scheme == "https"
      connection.open_timeout = OPEN_TIMEOUT
      connection.read_timeout = connection.write_timeout = IO_TIMEOUT
      # A retried upload would send the rest of a half-read file as if it were the whole.
      connection.max_retries = 0
      # A body cut short of its Content-Length is an error, not a short answer.
      connection.ignore_eof = false
      connection.start(&block)
    end

    def expect_success!(response, what)
      return if response.is_a?(Net::HTTPSuccess)

      # 400 is what the store says about one request's name or bytes. The rest are about
      # the bucket, the credential or the service.
      raise (response.code.to_i == 400 ? VerificationFailed : RequestFailed), "#{what}: HTTP #{response.code}"
    end
  end
end
