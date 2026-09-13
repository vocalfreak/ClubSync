class ObjectStore
  def initialize
    @client = Aws::S3::Client.new(
      access_key_id: ENV["B2_KEY_ID"],
      secret_access_key: ENV["B2_APPLICATION_KEY"],
      endpoint: ENV["B2_ENDPOINT"],
      region: ENV["B2_REGION"],
      force_path_style: true
    )
    @bucket = ENV["B2_BUCKET"]
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

  def get_url(key)
    "#{ENV['B2_ENDPOINT']}/#{ENV['B2_BUCKET']}/#{key}"
  end
end