# Token-set Jaccard overlap for two captions (dedup plan §3). Pure Ruby:
# downcased alphanumeric token sets. The channel is *undefined* (nil) when
# either caption has no tokens — an undefined caption never scores, vetoes, or
# adds weight; it simply drops out of the blend.
class CaptionJaccard
  class << self
    def similarity(a, b)
      left = tokens(a)
      right = tokens(b)
      return nil if left.empty? || right.empty?

      union = (left | right).size
      return 0.0 if union.zero?

      (left & right).size.to_f / union
    end

    def tokens(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).uniq
    end
  end
end
