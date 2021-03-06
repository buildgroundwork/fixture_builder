module FixtureBuilder
  class Builder
    include Delegations::Namer
    include Delegations::Configuration

    def initialize(configuration, namer, builder_block)
      @configuration = configuration
      @namer = namer
      @builder_block = builder_block
    end

    def generate!
      say "Building fixtures"
      clean_out_old_data
      create_fixture_objects
      names_from_ivars!
      write_data_to_files
      after_build.call if after_build
    end

    protected

    def create_fixture_objects
      load_legacy_fixtures if legacy_fixtures.present?
      surface_errors { instance_eval &@builder_block }
    end

    def load_legacy_fixtures
      legacy_fixtures.each do |fixture_file|
        fixtures_class = if Rails::VERSION::MAJOR >= 4
          ActiveRecord::FixtureSet
        else
          defined?(ActiveRecord::Fixtures) ? ActiveRecord::Fixtures : ::Fixtures
        end
        fixtures = fixtures_class.create_fixtures(File.dirname(fixture_file), File.basename(fixture_file, '.*'))
        populate_custom_names(fixtures)
      end
    end

    def surface_errors
      yield
    rescue Object => error
      puts
      say "There was an error building fixtures", error.inspect
      puts
      puts error.backtrace
      puts
      exit!
    end

    def names_from_ivars!
      instance_values.each do |var, value|
        name(var, value) if value.is_a? ActiveRecord::Base
      end
    end

    def write_data_to_files
      delete_yml_files
      dump_empty_fixtures_for_all_tables
      dump_tables
    end

    def clean_out_old_data
      delete_tables
      delete_yml_files
    end

    def delete_tables
      ActiveRecord::Base.connection.disable_referential_integrity do
        tables.each { |t| ActiveRecord::Base.connection.delete(delete_sql % ActiveRecord::Base.connection.quote_table_name(t)) }
      end
    end

    def delete_yml_files
      FileUtils.rm(Dir.glob(fixtures_dir('*.yml'))) rescue nil
    end

    def say(*messages)
      puts messages.map { |message| "=> #{message}" }
    end

    def dump_empty_fixtures_for_all_tables
      tables.each do |table_name|
        write_fixture_file({}, table_name)
      end
    end

    def dump_tables
      default_date_format = Date::DATE_FORMATS[:default]
      Date::DATE_FORMATS[:default] = Date::DATE_FORMATS[:db]
      begin
        fixtures = tables.inject([]) do |files, table_name|
          rows = rows(table_name)
          next files if rows.empty?

          row_index = '000'
          fixture_data = rows.inject({}) do |hash, record|
            hash.merge(record_name(record, table_name, row_index) => record)
          end

          write_fixture_file fixture_data, table_name

          files + [File.basename(fixture_file(table_name))]
        end
      ensure
        Date::DATE_FORMATS[:default] = default_date_format
      end
      say "Built #{fixtures.to_sentence}"
    end

    def rows(table_name)
      table_klass = table_name.classify.constantize rescue nil
      if table_klass && table_klass < ActiveRecord::Base
        table_klass.unscoped do
          table_klass.all.collect { |obj| fixture_attributes_for(obj) }
        end
      else
        ActiveRecord::Base.connection.select_all(select_sql % ActiveRecord::Base.connection.quote_table_name(table_name))
      end
    end

    if Rails::VERSION::MAJOR > 4 || Rails::VERSION::MAJOR == 4 && Rails::VERSION::MINOR >= 2
      def fixture_attributes_for(model)
        model.class.columns.inject({}) do |memo, column|
          memo.merge(column.name => column.type_cast_for_database(model.attributes[column.name]))
        end
      end
    else
      def fixture_attributes_for(model)
        attrs = model.attributes
        attrs.inject({}) do |hash, (attr_name, value)|
          hash.merge(attr_name => fixture_value_for(model, attr_name, value))
        end
      end

      def fixture_value_for(model, attr_name, value)
        if model.serialized_attributes.has_key?(attr_name)
          model.serialized_attributes[attr_name].dump(value)
        else
          value
        end
      end
    end

    def write_fixture_file(fixture_data, table_name)
      File.open(fixture_file(table_name), 'w') do |file|
        file.write fixture_data.to_yaml
      end
    end

    def fixture_file(table_name)
      fixtures_dir("#{table_name}.yml")
    end
  end
end
