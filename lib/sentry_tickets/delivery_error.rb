# frozen_string_literal: true

module SentryTickets
  # A ticket or notice that did not reach its destination. The failure is
  # recorded on the group and delivery is retried on its next occurrence.
  class DeliveryError < StandardError
    # The HTTP status GitHub answered with, when there was a response at all.
    attr_reader :status

    # The message is persisted in state and echoed in responses, both JSON,
    # but its text can come from anywhere: Net::HTTP labels response bodies
    # binary, and a middlebox's garbage lands in a parser error's message.
    def initialize(message = nil, status: nil)
      @status = status
      super(message&.dup&.force_encoding(Encoding::UTF_8)&.scrub)
    end
  end

  # The issue a notice was meant for no longer exists at the destination:
  # deleted on GitHub, or its repo re-created.
  class IssueGone < DeliveryError; end
end
