module RSpec
  module Mocks
    # @private
    # Provides a default space implementation for outside
    # the scope of an example. Called "root" because it serves
    # as the root of the space stack.
    class RootSpace
      def proxy_for(*args)
        raise_lifecycle_message
      end

      def any_instance_recorder_for(*args)
        raise_lifecycle_message
      end

      def any_instance_proxy_for(*args)
        raise_lifecycle_message
      end

      def register_constant_mutator(mutator)
        raise_lifecycle_message
      end

      def any_instance_recorders_from_ancestry_of(object)
        raise_lifecycle_message
      end

      def reset_all
      end

      def verify_all
      end

      def registered?(object)
        false
      end

      def new_scope
        Space.new
      end

    private

      def raise_lifecycle_message
        raise OutsideOfExampleError,
          "The use of doubles or partial doubles from rspec-mocks outside of the per-test lifecycle is not supported."
      end
    end

    # @private
    class Space
      attr_reader :proxies, :any_instance_recorders, :proxy_mutex, :any_instance_mutex

      def initialize
        @proxies                 = {}
        @any_instance_recorders  = {}
        @constant_mutators       = []
        @expectation_ordering    = OrderGroup.new
        @proxy_mutex             = new_mutex
        @any_instance_mutex      = new_mutex
      end

      def new_scope
        NestedSpace.new(self)
      end

      def verify_all
        proxies.values.each { |proxy| proxy.verify }
        any_instance_recorders.each_value { |recorder| recorder.verify }
      end

      def reset_all
        proxies.each_value { |proxy| proxy.reset }
        @constant_mutators.reverse.each { |mut| mut.idempotently_reset }
        any_instance_recorders.each_value { |recorder| recorder.stop_all_observation! }
        any_instance_recorders.clear
      end

      def register_constant_mutator(mutator)
        @constant_mutators << mutator
      end

      def constant_mutator_for(name)
        @constant_mutators.find { |m| m.full_constant_name == name }
      end

      def any_instance_recorder_for(klass, only_return_existing = false)
        any_instance_mutex.synchronize do
          id = klass.__id__
          any_instance_recorders.fetch(id) do
            return nil if only_return_existing
            any_instance_recorder_not_found_for(id, klass)
          end
        end
      end

      def any_instance_proxy_for(klass)
        AnyInstance::Proxy.new(any_instance_recorder_for(klass), proxies_of(klass))
      end

      def proxies_of(klass)
        proxies.values.select { |proxy| klass === proxy.object }
      end

      def proxy_for(object)
        proxy_mutex.synchronize do
          id = id_for(object)
          proxies.fetch(id) { proxy_not_found_for(id, object) }
        end
      end

      alias ensure_registered proxy_for

      def registered?(object)
        proxies.has_key?(id_for object)
      end

      def any_instance_recorders_from_ancestry_of(object)
        # Optimization: `any_instance` is a feature we generally
        # recommend not using, so we can often early exit here
        # without doing an O(N) linear search over the number of
        # ancestors in the object's class hierarchy.
        return [] if any_instance_recorders.empty?

        # We access the ancestors through the singleton class, to avoid calling
        # `class` in case `class` has been stubbed.
        (class << object; ancestors; end).map do |klass|
          any_instance_recorders[klass.__id__]
        end.compact
      end

    private

      # We don't want to depend on the stdlib ourselves, but if the user is
      # using threads then a Mutex will be available to us. If not, we don't
      # need to synchronize anyway.
      def new_mutex
        defined?(::Mutex) ? ::Mutex.new : FakeMutex
      end

      # @private
      module FakeMutex
        def self.synchronize
          yield
        end
      end

      def proxy_not_found_for(id, object)
        proxies[id] = case object
          when NilClass   then ProxyForNil.new(@expectation_ordering)
          when TestDouble then object.__build_mock_proxy(@expectation_ordering)
          when Class
            if RSpec::Mocks.configuration.verify_partial_doubles?
              VerifyingPartialClassDoubleProxy.new(self, object, @expectation_ordering)
            else
              PartialClassDoubleProxy.new(self, object, @expectation_ordering)
            end
          else
            if RSpec::Mocks.configuration.verify_partial_doubles?
              VerifyingPartialDoubleProxy.new(object, @expectation_ordering)
            else
              PartialDoubleProxy.new(object, @expectation_ordering)
            end
        end
      end

      def any_instance_recorder_not_found_for(id, klass)
        any_instance_recorders[id] = AnyInstance::Recorder.new(klass)
      end

      if defined?(::BasicObject) && !::BasicObject.method_defined?(:__id__) # for 1.9.2
        require 'securerandom'

        def id_for(object)
          id = object.__id__

          return id if object.equal?(::ObjectSpace._id2ref(id))
          # this suggests that object.__id__ is proxying through to some wrapped object

          object.instance_exec do
            @__id_for_rspec_mocks_space ||= ::SecureRandom.uuid
          end
        end
      else
        def id_for(object)
          object.__id__
        end
      end
    end

    # @private
    class NestedSpace < Space
      def initialize(parent)
        @parent = parent
        super()
      end

      def proxies_of(klass)
        super + @parent.proxies_of(klass)
      end

      def constant_mutator_for(name)
        super || @parent.constant_mutator_for(name)
      end

      def registered?(object)
        super || @parent.registered?(object)
      end

    private

      def proxy_not_found_for(id, object)
        @parent.proxies[id] || super
      end

      def any_instance_recorder_not_found_for(id, klass)
        @parent.any_instance_recorders[id] || super
      end
    end
  end
end
