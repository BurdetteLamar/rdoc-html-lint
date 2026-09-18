# frozen_string_literal: true

require "test_helper"

class Rdoc::Html::TestLint < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Rdoc::Html::Lint::VERSION
  end

end
