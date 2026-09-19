# frozen_string_literal: true

require_relative "test_helper"

class OutboxTest < Minitest::Test
  def setup
    @dir = Fixture.store_dir
    @outbox = SentryTickets::Outbox.new(@dir)
  end

  def test_open_issue_writes_a_markdown_file
    r = @outbox.open_issue(title: "boom", body: "the body")
    assert_match %r{\Aissue-boom\.[0-9a-f]{8}\.\d{8}-\d{6}\.md\z}, File.basename(r["url"])
    assert_equal "# boom\n\nthe body\n", File.read(r["url"])
    assert_nil r["number"]
  end

  def test_comment_subject_reflects_issue_number
    @outbox.comment(number: 7, body: "text")
    assert_includes File.read(Dir[File.join(@dir, "comment-*.md")].first), "notice for #7"

    @outbox.comment(number: nil, body: "text")
    files = Dir[File.join(@dir, "comment-*.md")]
    assert_equal 2, files.size
    assert_includes File.read(files.last), "recurrence notice"
  end

  def test_same_slug_distinct_bodies_do_not_overwrite
    long = "NoMethodError: undefined method `#{'x' * 40}' for nil:NilClass"
    @outbox.open_issue(title: long, body: "first")
    @outbox.open_issue(title: long.sub("x", "y"), body: "second")

    files = Dir[File.join(@dir, "issue-*.md")]
    assert_equal 2, files.size, "distinct issues must not share an outbox file"
    refute_equal files[0], files[1]
  end

  def test_files_are_owner_readable_only
    r = @outbox.open_issue(title: "boom", body: "the body")
    assert_equal 0o600, File.stat(r["url"]).mode & 0o777
  end

  def test_unwritable_directory_wraps_as_delivery_error
    file = File.join(Dir.mktmpdir, "a-file")
    File.write(file, "x")
    outbox = SentryTickets::Outbox.new(File.join(file, "nope"))
    error = assert_raises(SentryTickets::DeliveryError) do
      outbox.open_issue(title: "t", body: "b")
    end
    assert error.message.valid_encoding?
  end

  def test_slugify
    assert_equal "nomethoderror-undefined-method-name-for-nil-nilclass-nometho",
                 SentryTickets::Outbox.slugify("NoMethodError: undefined method `name' for nil:NilClass (NoMethodError)")
    assert_equal "a-b", SentryTickets::Outbox.slugify("  A_B  ")
  end
end
