require "minitest/autorun"
require "greeting"

class GreetingTest < Minitest::Test
  def test_shared_gem
    assert_equal "hello two words", Greeting.for("two words")
  end
end
