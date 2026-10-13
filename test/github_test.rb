# frozen_string_literal: true

require_relative "test_helper"

class GitHubTest < Minitest::Test
  def github(api_base)
    Five00Matic::GitHub.new(repo: "you/repo", credentials: Five00Matic::Token.new(token: "t"),
                            labels: ["error-report"], api_base: api_base)
  end

  def test_owns_only_issues_opened_in_its_repo
    assert github("http://unused").owns?({ "repo" => "you/repo", "number" => 7 })
    assert github("http://unused").owns?({ "repo" => "You/Repo", "number" => 7 }), "repo names are case-insensitive"
    refute github("http://unused").owns?({ "repo" => "you/old-repo", "number" => 7 }),
           "#7 of the old repo is not #7 of this one"
    refute github("http://unused").owns?({ "url" => "/data/outbox/issue-boom.md" }), "an outbox issue is not GitHub's"
    refute github("http://unused").owns?(nil)
  end

  def test_open_issue_posts_with_the_credentials_token
    created = '{"number": 7, "html_url": "https://github.com/you/repo/issues/7"}'
    Fixture.answering(["201 Created", created]) do |api_base, requests|
      issue = github(api_base).open_issue(title: "t", body: "b")
      assert_equal({ "repo" => "you/repo", "number" => 7, "url" => "https://github.com/you/repo/issues/7" }, issue)

      method, path, headers, body = requests.first
      assert_equal ["POST", "/repos/you/repo/issues"], [method, path]
      assert_equal "Bearer t", headers["authorization"]
      assert_equal({ "title" => "t", "body" => "b", "labels" => ["error-report"] }, JSON.parse(body))
    end
  end

  def test_comment_on_a_missing_issue_raises_issue_gone
    Fixture.answering(["404 Not Found", '{"message":"Not Found"}']) do |api_base, _requests|
      assert_raises(Five00Matic::IssueGone) { github(api_base).comment({ "number" => 7 }, body: "b") }
    end
  end

  # An AppToken whose installation is gone fails to mint with a 404 of its
  # own, which says nothing about the issue.
  def test_comment_without_a_token_is_not_issue_gone
    no_token = Object.new
    def no_token.token = raise(Five00Matic::DeliveryError.new("GitHub App auth 404: Not Found", status: 404))
    github = Five00Matic::GitHub.new(repo: "you/repo", credentials: no_token, labels: [], api_base: "http://unused")
    error = assert_raises(Five00Matic::DeliveryError) { github.comment({ "number" => 7 }, body: "b") }
    assert_instance_of Five00Matic::DeliveryError, error
  end

  def test_network_error_wraps_as_delivery_error
    error = assert_raises(Five00Matic::DeliveryError) do
      github("http://127.0.0.1:1").open_issue(title: "t", body: "b")
    end
    assert_match(/connection refused/i, error.message)
  end

  # A middlebox can answer GitHub's 2xx with a non-JSON, non-UTF-8 body; the
  # JSON::ParserError message then carries raw bytes, and would otherwise
  # land in state and break every future persist.
  def test_garbage_success_body_wraps_with_valid_utf8_message
    Fixture.answering(["200 OK", "\xFF\xFEbad!".b]) do |api_base, _requests|
      error = assert_raises(Five00Matic::DeliveryError) do
        github(api_base).open_issue(title: "t", body: "b")
      end
      assert_match(/JSON::ParserError/, error.message)
      assert error.message.valid_encoding?, "wrapped error must be valid UTF-8, got #{error.message.inspect}"
    end
  end

  def test_delivery_error_messages_are_valid_utf8
    # Net::HTTP labels bodies binary; valid multibyte text must survive and
    # invalid bytes must not reach the JSON state file.
    assert_equal "GitHub API 422: café", Five00Matic::DeliveryError.new("GitHub API 422: café".b).message
    assert_equal "boom: ��", Five00Matic::DeliveryError.new("boom: \xFF\xFE".b).message
  end
end
