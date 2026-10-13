# frozen_string_literal: true

require_relative "test_helper"

class CredentialsTest < Minitest::Test
  T0 = Time.utc(2026, 10, 13, 12)
  INSTALLATION = ["200 OK", '[{"id": 77, "account": {"login": "you"}}]'].freeze

  def app_token(api_base)
    Five00Matic::AppToken.new(app_id: 5_295_895, private_key: Fixture.private_key.to_pem, api_base: api_base)
  end

  def granted(token, expires_at) = ["201 Created", JSON.generate(token: token, expires_at: expires_at.iso8601)]

  def decode(segment)
    "#{segment.tr('-_', '+/')}#{'=' * ((4 - segment.length % 4) % 4)}".unpack1("m0")
  end

  def test_pat_is_used_as_given
    assert_equal "ghp_x", Five00Matic::Token.new(token: "ghp_x").token
  end

  def test_token_is_minted_for_the_installation_with_a_signed_jwt
    Fixture.answering(INSTALLATION, granted("ghs_abc", T0 + 3600)) do |api_base, requests|
      assert_equal "ghs_abc", app_token(api_base).token(now: T0)

      assert_equal [%w[GET /app/installations], %w[POST /app/installations/77/access_tokens]],
                   requests.map { |method, path, _, _| [method, path] }
      jwt = requests.first[2]["authorization"].delete_prefix("Bearer ")
      header, claims, signature = jwt.split(".")
      assert_equal({ "alg" => "RS256", "typ" => "JWT" }, JSON.parse(decode(header)))
      assert_equal({ "iat" => T0.to_i - 60, "exp" => T0.to_i + 540, "iss" => "5295895" }, JSON.parse(decode(claims)))
      assert Fixture.private_key.public_key.verify(OpenSSL::Digest.new("SHA256"), decode(signature),
                                                   "#{header}.#{claims}")
      assert_equal requests.first[2]["authorization"], requests.last[2]["authorization"],
                   "the same JWT trades for the token"
    end
  end

  def test_token_is_reused_until_it_nears_expiry
    Fixture.answering(INSTALLATION, granted("ghs_abc", T0 + 3600), granted("ghs_def", T0 + 7200)) do |api_base, requests|
      auth = app_token(api_base)
      assert_equal "ghs_abc", auth.token(now: T0)
      assert_equal "ghs_abc", auth.token(now: T0 + 3000), "ten minutes left: still good"
      assert_equal 2, requests.size
      assert_equal "ghs_def", auth.token(now: T0 + 3400), "under five minutes left: minted again"
      assert_equal 3, requests.size, "the installation is looked up once"
      assert_equal %w[POST /app/installations/77/access_tokens], requests.last[0, 2]
    end
  end

  def test_installation_is_looked_up_again_after_a_failed_mint
    gone = ["404 Not Found", '{"message": "Not Found"}']
    reinstalled = ["200 OK", '[{"id": 78, "account": {"login": "you"}}]']
    Fixture.answering(INSTALLATION, granted("ghs_abc", T0 + 3600), gone, reinstalled,
                      granted("ghs_def", T0 + 7200)) do |api_base, requests|
      auth = app_token(api_base)
      assert_equal "ghs_abc", auth.token(now: T0)
      assert_raises(Five00Matic::DeliveryError) { auth.token(now: T0 + 3400) }
      assert_equal "ghs_def", auth.token(now: T0 + 3400), "an app installed again has a new installation id"
      assert_equal [%w[GET /app/installations], %w[POST /app/installations/77/access_tokens],
                    %w[POST /app/installations/77/access_tokens],
                    %w[GET /app/installations], %w[POST /app/installations/78/access_tokens]],
                   requests.map { |method, path, _, _| [method, path] }
    end
  end

  def test_more_than_one_installation_is_refused
    Fixture.answering(["200 OK", '[{"id": 1}, {"id": 2}]']) do |api_base, _requests|
      error = assert_raises(Five00Matic::DeliveryError) { app_token(api_base).token }
      assert_match(/2 installations/, error.message)
    end
  end

  def test_rejected_jwt_is_a_delivery_error
    Fixture.answering(["401 Unauthorized", '{"message": "A JSON web token could not be decoded"}']) do |api_base, _|
      error = assert_raises(Five00Matic::DeliveryError) { app_token(api_base).token }
      assert_equal 401, error.status
      assert_match(/could not be decoded/, error.message)
    end
  end

  def test_unreachable_api_is_a_delivery_error
    error = assert_raises(Five00Matic::DeliveryError) { app_token("http://127.0.0.1:1").token }
    assert_match(/connection refused/i, error.message)
  end

  def test_token_response_that_is_not_an_object_is_a_delivery_error
    Fixture.answering(INSTALLATION, ["201 Created", "null"]) do |api_base, _requests|
      error = assert_raises(Five00Matic::DeliveryError) { app_token(api_base).token }
      assert_match(/not an object/, error.message)
    end
  end

  def test_token_response_without_expiry_is_a_delivery_error
    Fixture.answering(INSTALLATION, ["201 Created", '{"token": "ghs_abc"}']) do |api_base, _requests|
      error = assert_raises(Five00Matic::DeliveryError) { app_token(api_base).token }
      assert_match(/expires_at/, error.message)
    end
  end
end
