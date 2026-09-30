class ObjectStore
  # Cloudflare picks cache eligibility by file extension, not MIME type, so the
  # key must carry a recognised suffix or every response comes back DYNAMIC and
  # each view spends B2's daily Class B transaction allowance. The extension is a
  # constant suffix on the content hash, so identical bytes still map to exactly
  # one object and the year-long TTL's immutability assumption holds.
  EXTENSIONS = {
    "image/webp" => ".webp",
    "image/jpeg" => ".jpg",
    "image/png" => ".png"
  }.freeze

  def initialize(client: nil, bucket: nil)
    @client = client || Aws::S3::Client.new(
      access_key_id: ENV["B2_KEY_ID"],
      secret_access_key: ENV["B2_APPLICATION_KEY"],
      endpoint: ENV["B2_ENDPOINT"],
      region: ENV["B2_REGION"],
      force_path_style: true
    )
    @bucket = bucket || ENV["B2_BUCKET"]
  end

  def put(bytes, content_type: "image/jpeg")
    key = "#{Digest::SHA256.hexdigest(bytes)}#{EXTENSIONS.fetch(content_type, '.bin')}"
    @client.put_object(
      bucket: @bucket,
      key: key,
      body: bytes,
      content_type: content_type
    )
    key
  end

  # PUBLIC_IMAGE_BASE_URL points at the Cloudflare-served image host, e.g.
  # https://files.cyberjayahappenings.me, where Transform Rules rewrite requests
  # onto this bucket and hold the response at the edge. Going through the edge is
  # what keeps repeat page views off B2's 2,500/day free Class B transaction
  # allowance, since every direct browser load is its own b2_download_file_by_name.
  #
  # Unset -- local dev, or on the box before the image host exists -- this falls
  # back to the raw path-style S3 URL, which still works for a public bucket.
  def get_url(key)
    base = ENV["PUBLIC_IMAGE_BASE_URL"].presence&.chomp("/") || "#{ENV['B2_ENDPOINT']}/#{@bucket}"
    "#{base}/#{key}"
  end

  def get(b2_key)
    @client.get_object(bucket: @bucket, key: b2_key).body.read
  end

  # Server-side copy inside the bucket — no bytes through the box. Used only by
  # the one-off `clubsync:rekey_images`, to give objects written before `put`
  # derived an extension the key shape a fresh upload of the same bytes gets.
  #
  # `metadata_directive: "COPY"` is the point of the call: without it the copy's
  # content type is not guaranteed to survive, and a `.webp` key advertising
  # octet-stream is a lie the image host would serve.
  #
  # S3 wants `copy_source` URL-encoded. Our keys are a hex digest plus a dot, so
  # they are already URL-safe; a key with a slash or a space would need escaping.
  def copy(from_key, to_key)
    @client.copy_object(
      bucket: @bucket,
      key: to_key,
      copy_source: "#{@bucket}/#{from_key}",
      metadata_directive: "COPY"
    )
    to_key
  end

  # Existence check that doesn't spend a download. B2 counts a HEAD as a Class B
  # transaction, same as a full read, which is why this asks rather than fetches.
  def exists?(key)
    @client.head_object(bucket: @bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    false
  end
end
