module Delayed
  # Error recovery around job reservation, shared by Worker#work_off and
  # Delayed::Poller. Gives up with FatalBackendError after repeated failures.
  module ReservationGuard
    MAX_FAILED_RESERVATIONS = 10

  protected

    # Yields to reserve jobs; on error, lets the backend recover and returns
    # `fallback` (nothing reserved) until too many consecutive failures.
    def guard_reservation(fallback)
      result = yield
      @failed_reserve_count = 0
      result
    rescue ::Exception => error # rubocop:disable RescueException
      say "Error while reserving job: #{error}"
      Delayed::Job.recover_from(error)
      @failed_reserve_count = (@failed_reserve_count || 0) + 1
      raise FatalBackendError if @failed_reserve_count >= MAX_FAILED_RESERVATIONS
      fallback
    end
  end
end
