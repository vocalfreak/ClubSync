require "test_helper"

class DHashServiceTest < ActiveSupport::TestCase
  def setup
    @bytes = File.binread(Rails.root.join("test.jpg"))
  end

  def unrelated_bytes
    Vips::Image.black(200, 100).colourspace(:srgb).write_to_buffer(".jpg")
  end

  test "returns a 64-bit hash as 16 lowercase hex chars" do
    hash = DHashService.compute(@bytes)
    assert_match(/\A\h{16}\z/, hash)
    assert_equal 64, Integer(hash, 16).to_s(2).length
  end

  test "is deterministic: the same bytes produce the same hash" do
    assert_equal DHashService.compute(@bytes), DHashService.compute(@bytes)
  end

  test "hamming distance between identical hashes is zero" do
    hash = DHashService.compute(@bytes)
    assert_equal 0, DHashService.hamming(hash, hash)
  end

  test "unrelated images have a nonzero hamming distance" do
    distance = DHashService.hamming(DHashService.compute(@bytes), DHashService.compute(unrelated_bytes))
    assert distance.positive?, "two unrelated images must not collide"
  end

  test "similarity is 1 - hamming/64" do
    distance = DHashService.hamming(DHashService.compute(@bytes), DHashService.compute(unrelated_bytes))
    assert_in_delta 1.0 - distance / DHashService::BITS.to_f, DHashService.similarity(
      DHashService.compute(@bytes),
      DHashService.compute(unrelated_bytes)
    ), 1e-9
  end

  test "a re-encoded copy stays a near match (visually the same image)" do
    webp = Vips::Image.new_from_buffer(@bytes, "", access: :sequential).write_to_buffer(".webp")
    distance = DHashService.hamming(DHashService.compute(@bytes), DHashService.compute(webp))
    assert_operator distance, :<=, DHashService::BITS / 8, "lossy re-encode should barely move the hash"
  end

  test "compute_image on a Vips image matches compute on its encoded bytes" do
    image = Vips::Image.new_from_buffer(@bytes, "", access: :sequential)
    assert_equal DHashService.compute(@bytes), DHashService.compute_image(image)
  end

  test "raises Vips::Error for undecodable bytes" do
    assert_raises(Vips::Error) { DHashService.compute("\x00\x01not-an-image") }
  end
end
