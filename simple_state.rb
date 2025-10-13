# SimpleState is a lightweight state machine module for ActiveRecord models.
# It supports state transitions, optional guards, timestamps, and emits
# ActiveSupport::Notifications events for each transition outcome.
#
# Example usage:
#
#   class Employee < ApplicationRecord
#     include SimpleState
#
#     state_column :state
#
#     enum state: { created: 0, invited: 1, enrolled: 2, suspended: 3, terminated: 4 }
#
#     # Transition with guard and timestamp
#     transition :reactivate, from: [:suspended, :terminated], to: :enrolled,
#                timestamp: true, guard: :eligible_for_reactivation?
#   end
#
module SimpleState
  extend ActiveSupport::Concern

  # Raised when an invalid transition is attempted
  class TransitionError < StandardError
    attr_reader :record, :to, :from, :event

    # @param record [ActiveRecord::Base] the record being transitioned
    # @param to [Symbol] the target state
    # @param from [Symbol] the current state
    # @param event [Symbol] the transition event
    def initialize(record:, to:, from:, event:)
      @record, @to, @from, @event = record, to, from, event
      super("Invalid transition: #{record.class} ##{record.id} from #{from.inspect} -> #{to.inspect} on #{event}")
    end
  end

  included do
    class_attribute :simple_state_column, instance_writer: false
    class_attribute :simple_state_transitions, instance_writer: false, default: {}

    # Performs a state transition
    #
    # @param to [Symbol] target state
    # @param allowed_from [Symbol, Array<Symbol>] states allowed to transition from
    # @param event [Symbol] transition event name
    # @param timestamp_field [Symbol, true, nil] column to update with current time; true will auto-generate "#{to}_at"
    # @param guard [Symbol, Proc, nil] optional guard method or block that must return true
    # @yield optional block to execute after state update
    # @return [Boolean] true if transition succeeds
    # @raise [TransitionError] if transition is invalid or guard fails
    # @raise [ActiveRecord::RecordInvalid] if update! fails
    def transition_state(to:, allowed_from:, event:, timestamp_field: nil, guard: nil, &block)
      allowed_from = Array(allowed_from).map(&:to_sym).freeze
      current_state_value = public_send(self.class.simple_state_column)
      fail_transition!(to:, from: nil, event:, outcome: :invalid) if current_state_value.nil?

      current_state = current_state_value.to_sym

      fail_transition!(to:, from: current_state, event:, outcome: :invalid) unless allowed_from.include?(current_state)

      if guard
        result = guard.is_a?(Symbol) ? send(guard) : instance_exec(&guard)
        fail_transition!(to:, from: current_state, event:, outcome: :invalid) unless result
      end

      transaction do
        attrs = {self.class.simple_state_column => to}

        # Simple timestamp support: true => "#{to}_at", or custom column
        if timestamp_field
          column = (timestamp_field == true) ? "#{to}_at" : timestamp_field
          attrs[column] = Time.current
        end

        update!(attrs)

        # Ensure block exceptions are tracked as failures
        begin
          instance_exec(&block) if block
        rescue => e
          publish_state_event(outcome: :failed, to:, from: current_state, event:)
          raise e
        end

        publish_state_event(outcome: :success, to:, from: current_state, event:)
      end

      true
    rescue ActiveRecord::RecordInvalid => e
      publish_state_event(outcome: :failed, to:, from: current_state, event:)
      raise e
    end

    # Checks if the record can perform a given transition
    #
    # @param name [Symbol] transition name
    # @return [Boolean] true if allowed and guard passes
    def can_transition?(name)
      transition = self.class.simple_state_transitions[name.to_sym]
      return false unless transition

      allowed_from = Array(transition[:from]).map(&:to_sym)
      current_state_value = public_send(self.class.simple_state_column)
      return false if current_state_value.nil?

      current_state = current_state_value.to_sym
      guard = transition[:guard]

      allowed_from.include?(current_state) &&
        (guard.nil? || (guard.is_a?(Symbol) ? send(guard) : instance_exec(&guard)))
    end

    private

    # Publishes a failed transition and raises TransitionError
    #
    # @param to [Symbol] target state
    # @param from [Symbol] current state
    # @param event [Symbol] transition event
    # @param outcome [Symbol] event outcome (:invalid, :failed)
    # @raise [TransitionError]
    def fail_transition!(to:, from:, event:, outcome:)
      publish_state_event(outcome:, to:, from:, event:)
      raise TransitionError.new(record: self, to:, from:, event:)
    end

    # Publishes an ActiveSupport::Notifications event
    #
    # @param outcome [Symbol] :success, :failed, :invalid
    # @param to [Symbol] target state
    # @param from [Symbol] current state
    # @param event [Symbol] transition event
    def publish_state_event(outcome:, to:, from:, event:)
      event_name = [
        self.class.name.underscore,
        event.to_s.underscore,
        outcome.to_s.underscore
      ].join(".")

      ActiveSupport::Notifications.instrument(event_name, {
        record: self,
        record_id: id,
        from_state: from,
        to_state: to,
        event:,
        timestamp: Time.current
      })
    end
  end

  class_methods do
    # Sets the column used for state
    #
    # @param column_name [Symbol]
    def state_column(column_name)
      self.simple_state_column = column_name
    end

    def validate_state_exists!(state)
      return unless simple_state_column

      enum_accessor = simple_state_column.to_s.pluralize
      return unless respond_to?(enum_accessor)

      valid_states = public_send(enum_accessor).keys.map(&:to_sym)
      unless valid_states.include?(state.to_sym)
        raise ArgumentError, "Invalid state :#{state} for #{simple_state_column}. Valid states: #{valid_states.join(", ")}"
      end
    end

    # Defines a transition method
    #
    # @param name [Symbol] method name for the transition
    # @param to [Symbol] target state
    # @param from [Symbol, Array<Symbol>] allowed source states
    # @param timestamp [Symbol, true, nil] column to update with current time
    # @param guard [Symbol, Proc, nil] optional guard method/block
    # @yield block executed after state update
    def transition(name, to:, from:, timestamp: nil, guard: nil, &block)
      # Validate that target and source states exist in the enum
      validate_state_exists!(to)
      Array(from).each { |state| validate_state_exists!(state) }

      self.simple_state_transitions = simple_state_transitions.merge(
        name.to_sym => {to:, from:, timestamp:, guard:, block:}.freeze
      ).freeze

      define_method(name) do
        transition_state(
          to:,
          allowed_from: from,
          event: name,
          timestamp_field: timestamp,
          guard:,
          &block
        )
      end
    end
  end
end
