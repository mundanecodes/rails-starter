# Rails Application Template
# Usage: rails new myapp -d postgresql -m template.rb

# Gemfile modifications
def setup_gemfile
  # Remove comments and reorganize
  gsub_file "Gemfile", /^#.*\n/, ""

  # Add gems
  gem_group :development, :test do
    gem "dotenv-rails"
    gem "factory_bot_rails"
    gem "faker"
    gem "rspec-rails", ">= 7.0.0"
    gem "shoulda-matchers", ">= 6.0.0"
    gem "webmock"
    gem "database_cleaner-active_record"
    gem "spring-commands-rspec"
    gem "bundler-audit", require: false
    gem "brakeman", require: false
    gem "rubocop-rails-omakase", require: false
    gem "standard", require: false
    gem "ruby-lsp", require: false
  end

  gem "redis", ">= 4.0.1"
  gem "sidekiq"
  gem "dalli"
  gem "httpx"
  gem "aws-sdk-s3"
  gem "groupdate"
  gem "pagy"
  gem "phonelib"
end

def setup_rspec
  generate "rspec:install"

  # Configure rails_helper
  inject_into_file "spec/rails_helper.rb", after: "Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }\n" do
    <<~RUBY

      # Maintain test schema
      begin
        ActiveRecord::Migration.maintain_test_schema!
      rescue ActiveRecord::PendingMigrationError => e
        abort e.to_s.strip
      end

      RSpec.configure do |config|
        config.fixture_paths = [Rails.root.join("spec/fixtures")]
        config.use_transactional_fixtures = false
        config.infer_spec_type_from_file_location!
        config.filter_rails_from_backtrace!
        config.include FactoryBot::Syntax::Methods

        config.before(:suite) do
          Rails.application.eager_load!
        end
      end

      # Shoulda Matchers configuration
      Shoulda::Matchers.configure do |config|
        config.integrate do |with|
          with.test_framework :rspec
          with.library :rails
        end
      end
    RUBY
  end
end

def setup_database_cleaner
  create_file "spec/support/database_cleaner.rb" do
    <<~RUBY
      RSpec.configure do |config|
        config.before(:suite) do
          DatabaseCleaner.clean_with(:truncation)
        end

        config.before do
          DatabaseCleaner.strategy = :transaction
        end

        config.before(:each, js: true) do
          DatabaseCleaner.strategy = :truncation
        end

        config.before do
          DatabaseCleaner.start
        end

        config.after do
          DatabaseCleaner.clean
        end
      end
    RUBY
  end
end

def setup_webmock
  create_file "spec/support/webmock.rb" do
    <<~RUBY
      require 'webmock/rspec'

      WebMock.disable_net_connect!(allow_localhost: true)

      RSpec.configure do |config|
        config.before do
          WebMock.reset!
        end
      end
    RUBY
  end
end

def setup_performance
  create_file "spec/support/performance.rb" do
    <<~RUBY
      RSpec.configure do |config|
        config.before(:suite) do
          GC.disable
        end

        config.after(:suite) do
          GC.enable
          GC.start
        end

        config.around do |example|
          if (example.example_group.examples.index(example) + 1) % 50 == 0
            GC.enable
            GC.start
            example.run
            GC.disable
          else
            example.run
          end
        end
      end
    RUBY
  end
end

def configure_generators
  create_file "config/initializers/generators.rb" do
    <<~RUBY
      Rails.application.config.generators do |g|
        g.test_framework :rspec,
          fixtures: false,
          view_specs: false,
          helper_specs: false,
          routing_specs: false,
          controller_specs: false,
          request_specs: true
        g.fixture_replacement :factory_bot, dir: "spec/factories"
        g.helper false
      end
    RUBY
  end
end

def setup_sidekiq
  create_file "config/initializers/sidekiq.rb" do
    <<~RUBY
      Sidekiq.configure_server do |config|
        config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
      end

      Sidekiq.configure_client do |config|
        config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
      end
    RUBY
  end

  create_file "config/sidekiq.yml" do
    <<~YAML
      :concurrency: 5
      :queues:
        - default
        - mailers
        - critical

      production:
        :concurrency: 10

      development:
        :concurrency: 3

      test:
        :concurrency: 1
    YAML
  end

  create_file "config/routes/sidekiq.rb" do
    <<~RUBY
      # HTTP Basic Authentication for Sidekiq Web UI
      Sidekiq::Web.use Rack::Auth::Basic do |username, password|
        ActiveSupport::SecurityUtils.secure_compare(
          ::Digest::SHA256.hexdigest(username),
          ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_USERNAME"))
        ) & ActiveSupport::SecurityUtils.secure_compare(
          ::Digest::SHA256.hexdigest(password),
          ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_PASSWORD"))
        )
      end

      mount Sidekiq::Web => "/wera"
    RUBY
  end

  inject_into_file "config/routes.rb", after: "Rails.application.routes.draw do\n" do
    <<-RUBY
  # Sidekiq Web UI
  draw :sidekiq

    RUBY
  end

  inject_into_file "config/routes.rb", before: "Rails.application.routes.draw do\n" do
    <<~RUBY
      require "sidekiq/web"

    RUBY
  end
end

def setup_cache
  create_file "config/initializers/cache.rb" do
    <<~RUBY
      Rails.application.configure do
        if ENV["MEMCACHED_SERVERS"].present?
          config.cache_store = :mem_cache_store, ENV["MEMCACHED_SERVERS"],
            {
              namespace: "#{app_name}_\#{Rails.env}",
              compress: true,
              pool_size: 5,
              expires_in: 1.day
            }
        end
      end
    RUBY
  end
end

def setup_uuid
  generate :migration, "EnableUuidExtension"

  in_root do
    migration = Dir.glob("db/migrate/*enable_uuid_extension.rb").first
    gsub_file migration, /def change\n  end/ do
      <<~RUBY
        def change
            enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
          end
      RUBY
    end
  end

  create_file "config/initializers/uuid_v7.rb" do
    <<~RUBY
      Rails.application.config.after_initialize do
        ActiveRecord::Base.include(Module.new do
          def self.included(base)
            base.class_eval do
              def self.generate_uuid_v7
                require "securerandom"
                SecureRandom.uuid_v7
              end
            end
          end
        end)
      end
    RUBY
  end
end

def setup_robots_blocking
  create_file "app/middleware/block_robots.rb" do
    <<~RUBY
      class BlockRobots
        def initialize(app)
          @app = app
        end

        def call(env)
          status, headers, response = @app.call(env)
          headers["X-Robots-Tag"] = "noindex, nofollow, noarchive, nosnippet, noimageindex, nocache"
          [status, headers, response]
        end
      end
    RUBY
  end

  create_file "public/robots.txt", force: true do
    <<~TXT
      # Block all robots and crawlers
      User-agent: *
      Disallow: /

      # Block common AI scrapers
      User-agent: GPTBot
      Disallow: /

      User-agent: ChatGPT-User
      Disallow: /

      User-agent: CCBot
      Disallow: /

      User-agent: anthropic-ai
      Disallow: /

      User-agent: Claude-Web
      Disallow: /

      User-agent: Google-Extended
      Disallow: /

      User-agent: PerplexityBot
      Disallow: /

      User-agent: Bytespider
      Disallow: /

      User-agent: Amazonbot
      Disallow: /
    TXT
  end
end

def configure_application
  inject_into_file "config/application.rb", after: "config.load_defaults 8.1\n" do
    <<-RUBY
    config.autoload_lib(ignore: %w[assets tasks])
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc
    config.generators.system_tests = nil

    config.generators do |generate|
      generate.orm :active_record, primary_key_type: :uuid
    end

    config.silence_healthcheck_path += ["/health", "/healthz", "/ping", "/status"]
    config.middleware.use BlockRobots
    RUBY
  end
end

def setup_development_config
  inject_into_file "config/environments/development.rb", before: "  # Raise error when a before_action" do
    <<-RUBY
  # Allow ngrok tunnels
  config.hosts << /[a-z0-9-]+\\.ngrok-free\\.app/
  config.hosts << /[a-z0-9-]+\\.ngrok\\.io/

  # Allow .localhost domains
  config.hosts << /[a-z0-9-]+\\.localhost/

    RUBY
  end
end

def setup_production_config
  gsub_file "config/environments/production.rb", /# config.active_job.queue_adapter = :resque/, "config.active_job.queue_adapter = :sidekiq"

  inject_into_file "config/environments/production.rb", after: "config.active_job.queue_adapter = :sidekiq\n" do
    <<-RUBY

  # Store uploaded files on AWS S3.
  config.active_storage.service = :amazon
    RUBY
  end
end

def create_docker_files
  create_file "docker-compose.yml" do
    <<~YAML
      version: '3.8'

      services:
        db:
          image: postgres:16-alpine
          volumes:
            - postgres_data:/var/lib/postgresql/data
          environment:
            POSTGRES_USER: postgres
            POSTGRES_PASSWORD: postgres
            POSTGRES_DB: #{app_name}_development
          ports:
            - "5432:5432"
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U postgres"]
            interval: 10s
            timeout: 5s
            retries: 5

        redis:
          image: redis:7-alpine
          volumes:
            - redis_data:/data
          ports:
            - "6379:6379"
          command: redis-server --appendonly yes
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 10s
            timeout: 5s
            retries: 5

        memcached:
          image: memcached:1.6-alpine
          ports:
            - "11211:11211"
          command: memcached -m 64
          healthcheck:
            test: ["CMD", "nc", "-z", "localhost", "11211"]
            interval: 10s
            timeout: 5s
            retries: 5

        web:
          build: .
          command: bash -c "rm -f tmp/pids/server.pid && bundle exec rails server -b 0.0.0.0 -p 3007"
          volumes:
            - .:/rails
            - bundle_cache:/usr/local/bundle
          ports:
            - "3007:3007"
          depends_on:
            db:
              condition: service_healthy
            redis:
              condition: service_healthy
            memcached:
              condition: service_healthy
          environment:
            DATABASE_URL: postgres://postgres:postgres@db:5432/#{app_name}_development
            REDIS_URL: redis://redis:6379/0
            MEMCACHED_SERVERS: memcached:11211
            RAILS_ENV: development
          stdin_open: true
          tty: true

        sidekiq:
          build: .
          command: bundle exec sidekiq
          volumes:
            - .:/rails
            - bundle_cache:/usr/local/bundle
          depends_on:
            db:
              condition: service_healthy
            redis:
              condition: service_healthy
            memcached:
              condition: service_healthy
          environment:
            DATABASE_URL: postgres://postgres:postgres@db:5432/#{app_name}_development
            REDIS_URL: redis://redis:6379/0
            MEMCACHED_SERVERS: memcached:11211
            RAILS_ENV: development

      volumes:
        postgres_data:
        redis_data:
        bundle_cache:
    YAML
  end

  create_file ".env.example" do
    <<~ENV
      # Database
      DATABASE_URL=postgres://postgres:postgres@localhost:5432/#{app_name}_development

      # Redis
      REDIS_URL=redis://localhost:6379/0

      # Memcached
      MEMCACHED_SERVERS=localhost:11211

      # Rails Performance
      RAILS_ENV=development
      RAILS_MAX_THREADS=5
      RAILS_MIN_THREADS=5
      WEB_CONCURRENCY=2
      PORT=3007

      # Ngrok (optional - for tunneling)
      NGROK_AUTH_TOKEN=your_ngrok_token_here

      # Sidekiq Web UI
      SIDEKIQ_USERNAME=admin
      SIDEKIQ_PASSWORD=changeme

      # AWS S3 (for production)
      AWS_ACCESS_KEY_ID=
      AWS_SECRET_ACCESS_KEY=
      AWS_REGION=us-east-1
      AWS_BUCKET=

      # Action Mailer
      SMTP_ADDRESS=
      SMTP_PORT=587
      SMTP_DOMAIN=
      SMTP_USERNAME=
      SMTP_PASSWORD=

      # Application
      SECRET_KEY_BASE=
    ENV
  end
end

def create_github_actions
  create_file ".github/workflows/ci.yml" do
    <<~YAML
      name: CI

      on:
        pull_request:
        push:
          branches: [ main ]

      env:
        RUBY_VERSION: 3.4.3
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgres
        POSTGRES_DB: #{app_name}_test
        RAILS_ENV: test

      jobs:
        test:
          name: Tests
          runs-on: ubuntu-latest

          services:
            postgres:
              image: postgres:16-alpine
              env:
                POSTGRES_USER: postgres
                POSTGRES_PASSWORD: postgres
                POSTGRES_DB: #{app_name}_test
              ports:
                - 5432:5432
              options: >-
                --health-cmd pg_isready
                --health-interval 10s
                --health-timeout 5s
                --health-retries 5

            redis:
              image: redis:7-alpine
              ports:
                - 6379:6379
              options: >-
                --health-cmd "redis-cli ping"
                --health-interval 10s
                --health-timeout 5s
                --health-retries 5

          env:
            DATABASE_URL: postgres://postgres:postgres@localhost:5432/#{app_name}_test
            REDIS_URL: redis://localhost:6379/0

          steps:
            - name: Checkout code
              uses: actions/checkout@v5

            - name: Set up Ruby
              uses: ruby/setup-ruby@v1
              with:
                ruby-version: ${{ env.RUBY_VERSION }}
                bundler-cache: true

            - name: Setup database
              run: |
                bin/rails db:create
                bin/rails db:schema:load

            - name: Run tests
              run: bundle exec rspec --format documentation

        scan_ruby:
          name: Security Scan
          runs-on: ubuntu-latest

          steps:
            - name: Checkout code
              uses: actions/checkout@v5

            - name: Set up Ruby
              uses: ruby/setup-ruby@v1
              with:
                bundler-cache: true

            - name: Scan for common Rails security vulnerabilities
              run: bin/brakeman --no-pager

            - name: Scan for known security vulnerabilities in gems
              run: bin/bundler-audit

        lint:
          name: Lint
          runs-on: ubuntu-latest

          steps:
            - name: Checkout code
              uses: actions/checkout@v5

            - name: Set up Ruby
              uses: ruby/setup-ruby@v1
              with:
                bundler-cache: true

            - name: Lint code for consistent style
              run: bin/rubocop -f github

            - name: Run Standard
              run: bundle exec standardrb
    YAML
  end
end

# Run the setup
after_bundle do
  setup_gemfile
  run "bundle install"

  setup_rspec
  setup_database_cleaner
  setup_webmock
  setup_performance
  configure_generators
  setup_sidekiq
  setup_cache
  setup_uuid
  setup_robots_blocking
  configure_application
  setup_development_config
  setup_production_config
  create_docker_files
  create_github_actions

  generate "active_storage:install"

  git :init
  git add: "."
  git commit: "-m 'Initial commit with custom template'"

  say "✅ Rails app created with custom template!", :green
  say "Next steps:", :yellow
  say "  1. cp .env.example .env"
  say "  2. Set SIDEKIQ_USERNAME and SIDEKIQ_PASSWORD in .env"
  say "  3. bin/rails db:create db:migrate"
  say "  4. bin/rails server -p 3007"
  say "  5. Visit: http://#{app_name}.localhost:3007"
end
