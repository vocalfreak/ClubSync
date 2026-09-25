require "vips"

# 64-bit perceptual hash over a 9x8 grayscale gradient (dedup plan §3). Each
# of the 64 bits is one adjacent-pixel comparison on the resized source; Hamming
# distance between two 16-char hex hashes counts differing bits. Pure computed
# state — never network, never raises beyond Vips::Error for undecodable bytes.
class DHashService
  WIDTH = 9
  HEIGHT = 8
  BITS = 64
  HEX_LENGTH = BITS / 4

  class << self
    def compute(bytes)
      compute_image(Vips::Image.new_from_buffer(bytes, "", access: :sequential))
    end

    def compute_image(image)
      grey = image.colourspace(:b_w)
      small = grey.resize(WIDTH.to_f / grey.width, vscale: HEIGHT.to_f / grey.height, kernel: :nearest)
      pixels = small.to_a

      bits = pixels.map do |row|
        row.each_cons(2).map { |left, right| first_band(left) > first_band(right) ? "1" : "0" }
      end.join

      bits.to_i(2).to_s(16).rjust(HEX_LENGTH, "0")
    end

    def first_band(pixel)
      pixel.is_a?(Array) ? pixel[0] : pixel
    end

    def hamming(a, b)
      (Integer(a, 16) ^ Integer(b, 16)).to_s(2).count("1")
    end

    def similarity(a, b)
      1.0 - hamming(a, b).to_f / BITS
    end
  end
end
