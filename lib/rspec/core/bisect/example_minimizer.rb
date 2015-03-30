RSpec::Support.require_rspec_core "bisect/subset_enumerator"

module RSpec
  module Core
    module Bisect
      # @private
      # Contains the core bisect logic. Searches for examples we can ignore by
      # repeatedly running different subsets of the suite.
      class ExampleMinimizer
        attr_reader :runner, :reporter, :all_example_ids, :failed_example_ids

        def initialize(runner, reporter)
          @runner   = runner
          @reporter = reporter
        end

        def find_minimal_repro
          prep

          remaining_ids = non_failing_example_ids

          each_bisect_round(lambda { remaining_ids }) do |subsets|
            ids_to_ignore = subsets.find do |ids|
              get_same_failures?(remaining_ids - ids)
            end

            next :done unless ids_to_ignore

            remaining_ids -= ids_to_ignore
            notify(:bisect_ignoring_ids, :ids_to_ignore => ids_to_ignore, :remaining_ids => remaining_ids)
          end

          remaining_ids + failed_example_ids
        end

      private

        def prep
          notify(:bisect_starting, :original_cli_args => runner.original_cli_args)

          _, duration = track_duration do
            original_results    = runner.original_results
            @all_example_ids    = original_results.all_example_ids
            @failed_example_ids = original_results.failed_example_ids
          end

          notify(:bisect_original_run_complete, :failed_example_ids => failed_example_ids,
                                                :non_failing_example_ids => non_failing_example_ids,
                                                :duration => duration)
        end

        def non_failing_example_ids
          @non_failing_example_ids ||= all_example_ids - failed_example_ids
        end

        def get_same_failures?(ids)
          ids_to_run = ids + failed_example_ids
          notify(:bisect_individual_run_start, :command => runner.repro_command_from(ids_to_run))

          results, duration = track_duration { runner.run(ids_to_run) }
          notify(:bisect_individual_run_complete, :duration => duration, :results => results)

          abort_if_ordering_inconsistent(results)
          results.failed_example_ids == failed_example_ids
        end

        INFINITY = (1.0 / 0) # 1.8.7 doesn't define Float::INFINITY so we define our own...

        def each_bisect_round(get_remaining_ids, &block)
          last_round, duration = track_duration do
            1.upto(INFINITY) do |round|
              break if :done == bisect_round(round, get_remaining_ids.call, &block)
            end
          end

          notify(:bisect_complete, :round => last_round, :duration => duration,
                                   :original_non_failing_count => non_failing_example_ids.size,
                                   :remaining_count => get_remaining_ids.call.size)
        end

        def bisect_round(round, remaining_ids)
          value, duration = track_duration do
            subsets = SubsetEnumerator.new(remaining_ids)
            notify(:bisect_round_started, :round => round,
                                          :subset_size => subsets.subset_size,
                                          :remaining_count => remaining_ids.size)

            yield subsets
          end

          notify(:bisect_round_finished, :duration => duration)
          value
        end

        def track_duration
          start = ::RSpec::Core::Time.now
          [yield, ::RSpec::Core::Time.now - start]
        end

        def abort_if_ordering_inconsistent(results)
          expected_order = all_example_ids & results.all_example_ids
          return if expected_order == results.all_example_ids

          raise BisectFailedError, "\n\nThe example ordering is inconsistent. " \
                "`--bisect` relies upon consistent ordering (e.g. by passing " \
                "`--seed` if you're using random ordering) to work properly."
        end

        def notify(*args)
          reporter.publish(*args)
        end
      end
    end
  end
end
