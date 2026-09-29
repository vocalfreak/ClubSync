class ObjectStore
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
    key = Digest::SHA256.hexdigest(bytes)
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
end
