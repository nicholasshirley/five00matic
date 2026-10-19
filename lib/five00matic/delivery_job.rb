# frozen_string_literal: true

require "active_job"

module Five00Matic
  # Delivers what a group is owed, through the tracker that
  # before_send(delivery: :active_job) set up in this process. A failed
  # delivery is retried with growing waits for about four hours. After the
  # last attempt the failure stays on the group, and the error's next
  # occurrence queues another delivery.
  class DeliveryJob < ActiveJob::Base
    retry_on DeliveryError, wait: :polynomially_longer, attempts: 10 do |_job, _error|
      # Not raised again: the failure is on the group, and a job that
      # raised would be reported to Sentry.
    end

    def perform(fingerprint, payload)
      tracker = Five00Matic.queued_tracker
      raise "five00matic: no tracker to deliver with; before_send needs delivery: :active_job" if tracker.nil?

      action, group = tracker.deliver(fingerprint, payload)
      # The tracker keeps a failed delivery on the group rather than
      # raising it; raising it here is what makes the job retry.
      raise DeliveryError, group.last_error if %i[opened commented].include?(action) && group.last_error
    end
  end
end
