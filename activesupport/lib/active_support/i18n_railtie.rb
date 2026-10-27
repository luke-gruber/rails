# :markup: markdown
# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/array/wrap"
require "rails/railtie"

# :enddoc:

module I18n
  class Railtie < Rails::Railtie
    config.i18n = ActiveSupport::OrderedOptions.new
    config.i18n.railties_load_path = []
    config.i18n.load_path = []
    config.i18n.fallbacks = ActiveSupport::OrderedOptions.new

    config.eager_load_namespaces << I18n

    # Make sure i18n is ready before eager loading, in case any eager loaded
    # code needs it.
    config.before_eager_load do |app|
      I18n::Railtie.initialize_i18n(app)
    end

    # i18n initialization needs to run after application initialization, since
    # initializers may configure i18n.
    #
    # If the application eager loaded, this was done on before_eager_load. The
    # hook is still OK, though, because initialize_i18n is idempotent.
    config.after_initialize do |app|
      I18n::Railtie.initialize_i18n(app)
    end

    initializer "i18n.ractorize" do
      ActiveSupport.on_load(:before_ractorize) do
        I18n::Railtie.make_shareable!
      end
    end

    @i18n_inited = false

    # Setup i18n configuration.
    def self.initialize_i18n(app)
      return if @i18n_inited

      fallbacks = app.config.i18n.delete(:fallbacks)

      # Avoid issues with setting the default_locale by disabling available locales
      # check while configuring.
      enforce_available_locales = app.config.i18n.delete(:enforce_available_locales)
      enforce_available_locales = I18n.enforce_available_locales if enforce_available_locales.nil?
      I18n.enforce_available_locales = false

      reloadable_paths = []
      app.config.i18n.each do |setting, value|
        case setting
        when :railties_load_path
          reloadable_paths = value
          app.config.i18n.load_path.unshift(*value.flat_map(&:expanded_files))
        when :load_path
          I18n.load_path += value
        when :raise_on_missing_translations
          strict = value == :strict
          setup_raise_on_missing_translations_config(app, strict)
        else
          I18n.public_send("#{setting}=", value)
        end
      end

      init_fallbacks(fallbacks) if fallbacks && validate_fallbacks(fallbacks)

      # Restore available locales check so it will take place from now on.
      I18n.enforce_available_locales = enforce_available_locales

      if app.config.reloading_enabled?
        directories = watched_dirs_with_extensions(reloadable_paths)
        reloader = app.config.file_watcher.new(I18n.load_path, directories) do
          I18n.load_path.delete_if { |path| path.to_s.start_with?(Rails.root.to_s) && !File.exist?(path) }
          I18n.load_path |= reloadable_paths.flat_map(&:existent)
        end

        app.reloaders << reloader
        app.reloader.to_run do
          reloader.execute_if_updated { require_unload_lock! }
        end
      end

      @i18n_inited = true
    end

    def self.setup_raise_on_missing_translations_config(app, strict)
      ActiveSupport.on_load(:action_view) do
        ActionView::Helpers::TranslationHelper.raise_on_missing_translations = app.config.i18n.raise_on_missing_translations
      end

      ActiveSupport.on_load(:active_model_translation) do
        ActiveModel::Translation.raise_on_missing_translations = app.config.i18n.raise_on_missing_translations if strict
      end

      if app.config.i18n.raise_on_missing_translations &&
          I18n.exception_handler.is_a?(I18n::ExceptionHandler) # Only override the i18n gem's default exception handler.

        I18n.exception_handler = ->(exception, *) {
          exception = exception.to_exception if exception.is_a?(I18n::MissingTranslation)
          raise exception
        }
      end
    end

    # ActionView::LookupContext derives its :locale detail from I18n.fallbacks on
    # every request, and active_support/i18n.rb requires i18n/backend/fallbacks
    # unconditionally, so this runs whether or not config.i18n.fallbacks is set.
    #
    # Two lazy writes have to happen on the main Ractor for that read to be legal
    # from a worker: I18n.fallbacks memoizes into the @@fallbacks class variable,
    # and Fallbacks#[] memoizes each computed chain back into itself. Warm a chain
    # for every locale the app can be switched to, then freeze the lot so workers
    # only ever hit the already-populated Hash.
    def self.make_shareable!
      fallbacks = I18n.fallbacks
      locales = I18n.available_locales | [ I18n.default_locale, I18n.locale ]
      locales.each { |locale| fallbacks[locale] }
      ActiveSupport::Ractors.make_shareable(fallbacks)

      # I18n::Config#available_locales opens with `@@available_locales ||= nil`,
      # which writes the class variable on every call while it is still falsy, and
      # #available_locales_set memoizes into @@available_locales_set. Resolving
      # both here leaves workers with plain reads, and the values have to be made
      # shareable because reading a class variable requires a shareable value.
      I18n.available_locales = locales
      I18n.config.available_locales_set
      ActiveSupport::Ractors.make_shareable(I18n::Config.class_variable_get(:@@available_locales))
      ActiveSupport::Ractors.make_shareable(I18n::Config.class_variable_get(:@@available_locales_set))

      # #available_locales above forced the backend to load every file on
      # I18n.load_path, so its translations are complete and can be frozen. The
      # backend lives in the @@backend class variable, which workers cannot read
      # while it holds an unshareable value.
      #
      # Simple#translations auto-vivifies nested hashes through a default_proc,
      # and a Proc whose self is unshareable blocks make_shareable. Dropping it is
      # safe for lookups: Simple#lookup walks the tree with has_key? and never
      # triggers the proc, and a frozen tree could not auto-vivify anyway.
      if I18n.backend.respond_to?(:translations, true)
        strip_default_procs(I18n.backend.send(:translations))
      end
      ActiveSupport::Ractors.make_shareable(I18n.backend)

      # Every remaining I18n::Config reader memoizes into a class variable with
      # `@@name ||= default`, so the first call from a worker would be a write to
      # a class variable the main Ractor created. Calling them all here resolves
      # the defaults up front, then the sweep below makes each value shareable so
      # workers are left with plain class variable reads.
      I18n.config.default_locale
      I18n.config.default_separator
      I18n.config.exception_handler
      I18n.config.load_path
      I18n.config.interpolation_patterns

      # The default #missing_interpolation_argument_handler is a lambda built
      # inside the reader, so its self is the I18n::Config instance and it can
      # never be made shareable. Swap in an equivalent whose self is this class.
      # A handler the app configured is left alone and only frozen, below.
      if I18n.config.missing_interpolation_argument_handler.is_a?(::Proc) &&
          !Ractor.shareable?(I18n.config.missing_interpolation_argument_handler)

        I18n.config.missing_interpolation_argument_handler =
          ActiveSupport::Ractors.shareable_lambda do |missing_key, provided_hash, string|
            raise I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
          end
      end

      [ I18n, I18n::Config ].each do |mod|
        mod.class_variables.each do |name|
          ActiveSupport::Ractors.make_shareable(mod.class_variable_get(name))
        end
      end

      make_normalized_key_cache_ractor_local!

      # Built from RESERVED_KEYS on first interpolation and memoized into a
      # module instance variable, which a worker can neither write nor read
      # while it holds an unshareable value.
      I18n.reserved_keys_pattern

      # interpolate_hash memoizes the union of config.interpolation_patterns into
      # the INTERPOLATION_PATTERNS_CACHE constant. Interpolating once fills the
      # only entry it will ever hold, since the key is the patterns array off the
      # config, which the sweep above already froze in place. The constant is
      # private, so Module#constants skips it and it has to be named here.
      I18n.interpolate("%{ractorize}", ractorize: nil)
      begin
        make_value_shareable(I18n.const_get(:INTERPOLATION_PATTERNS_CACHE, false))
      rescue NameError
        # Older i18n versions build the pattern on every call.
      end

      make_namespace_shareable!(I18n)
    end

    # A worker may not read a constant or a module instance variable holding an
    # unshareable value, and the gem has plenty of both -- I18n::RESERVED_KEYS and
    # I18n.@reserved_keys_pattern are reached by every interpolated translation,
    # so the first render hits them. Walk the namespace rather than naming each
    # one, so whichever i18n submodules the app happens to load are covered.
    #
    # Autoloads are skipped so this does not force-load backends the app never
    # asked for, and anything that refuses to freeze is left for the worker to
    # report: raising here would turn a lookup that may never happen into a boot
    # failure.
    def self.make_namespace_shareable!(mod, seen = {})
      return if seen[mod]
      seen[mod] = true

      mod.instance_variables.each do |name|
        make_value_shareable(mod.instance_variable_get(name))
      end

      mod.constants(false).each do |name|
        next if mod.autoload?(name)

        value = begin
          mod.const_get(name, false)
        rescue NameError, LoadError
          next
        end

        if value.is_a?(Module)
          make_namespace_shareable!(value, seen) if value.name&.start_with?("I18n")
        else
          make_value_shareable(value)
        end
      end
    end

    def self.make_value_shareable(value)
      ActiveSupport::Ractors.make_shareable(value)
    rescue Ractor::IsolationError, Ractor::Error, FrozenError
      value
    end

    # I18n.normalize_key memoizes into the @@normalized_key_cache class variable,
    # a Concurrent::Map of Concurrent::Maps. Concurrent::Map does not implement
    # #freeze, so that cache can never be made shareable, and every translation
    # lookup goes through it -- which makes it a hard stop for workers.
    #
    # The cache only ever needs to hand out something writable, though, and its
    # entries are a pure function of the key and separator. Replace it with a
    # shareable object that vends a per-Ractor Hash instead: the class variable
    # read becomes legal, each worker memoizes into a store only it can see, and
    # the Concurrent::Map's thread safety is no longer needed because the Hash is
    # never shared. The cost is one recomputation per key per Ractor.
    class RactorLocalKeyCache # :nodoc:
      def [](separator)
        ActiveSupport::Ractors.store_if_absent(:"i18n_normalized_key_cache_#{separator}") do
          {}
        end
      end
    end

    def self.make_normalized_key_cache_ractor_local!
      # Defined in I18n::Base, which I18n extends.
      return unless I18n::Base.class_variable_defined?(:@@normalized_key_cache)

      I18n::Base.class_variable_set(
        :@@normalized_key_cache,
        ActiveSupport::Ractors.make_shareable(RactorLocalKeyCache.new)
      )
    end

    def self.strip_default_procs(hash)
      return unless hash.is_a?(::Hash)

      hash.default_proc = nil if hash.default_proc
      hash.each_value { |value| strip_default_procs(value) }
    end

    def self.include_fallbacks_module
      I18n.backend.class.include(I18n::Backend::Fallbacks)
    end

    def self.init_fallbacks(fallbacks)
      include_fallbacks_module

      args = \
        case fallbacks
        when ActiveSupport::OrderedOptions
          [*(fallbacks[:defaults] || []) << fallbacks[:map]].compact
        when Hash, Array
          Array.wrap(fallbacks)
        else # TrueClass
          [I18n.default_locale]
        end

      I18n.fallbacks = I18n::Locale::Fallbacks.new(*args)
    end

    def self.validate_fallbacks(fallbacks)
      case fallbacks
      when ActiveSupport::OrderedOptions
        !fallbacks.empty?
      when TrueClass, Array, Hash
        true
      else
        raise "Unexpected fallback type #{fallbacks.inspect}"
      end
    end

    def self.watched_dirs_with_extensions(paths)
      paths.each_with_object({}) do |path, result|
        result[path.absolute_current] = path.extensions
      end
    end
  end
end
