module Adapters
  Result = Struct.new(:attributes, :errors, :fatal, keyword_init: true) do
    def valid?
      !fatal && errors.empty?
    end
  end
end
