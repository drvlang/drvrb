require "base64"
require "greeting/native"

module Greeting
  def self.for(name)
    PREFIX + Base64.strict_decode64(Base64.strict_encode64(name))
  end
end
