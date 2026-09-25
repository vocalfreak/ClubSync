# Hand-rolled cosine over two float arrays (dedup plan §3.1 — no pgvector).
# Returns nil when either side is empty or the lengths differ; 0.0 when a
# vector is all zeros. Used for the caption-embedding tiebreaker gate.
class CosineSimilarity
  class << self
    def cosine(a, b)
      return nil if a.nil? || b.nil? || a.empty? || b.empty?
      return nil unless a.size == b.size

      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      a.each do |x|
        norm_a += x * x
      end
      b.each do |y|
        norm_b += y * y
      end
      return 0.0 if norm_a.zero? || norm_b.zero?

      dot = a.each_with_index.sum { |x, i| x * b[i] }
      dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
    end
  end
end
