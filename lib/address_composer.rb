# frozen_string_literal: true

require "address_composer/version"
require "yaml"
require "mustache"
require "uri"

class AddressComposer
  GEM_ROOT = Gem::Specification.find_by_name("address_composer").gem_dir
  Templates = YAML.safe_load(IO.read(File.join(GEM_ROOT, "address-formatting", "conf", "countries", "worldwide.yaml")), aliases: true, symbolize_names: true)
  ComponentsList = begin
                     c_list = Psych.load_stream(File.read(File.join(GEM_ROOT,"address-formatting", "conf","components.yaml")), symbolize_names: true)
                     c_list.each do |component_hash|
                       component_hash[:name] = component_hash[:name].to_sym
                       component_hash[:aliases]&.map!(&:to_sym)
                     end
                     c_list
                   end
  AllComponents = ComponentsList.map { |h| h[:name] } + ComponentsList.flat_map { |h| h[:aliases] }.compact
  StateCodes = YAML.safe_load(IO.read(File.join(GEM_ROOT, "address-formatting", "conf", "state_codes.yaml")), aliases: true, symbolize_names: true)
  CountyCodes = YAML.safe_load(IO.read(File.join(GEM_ROOT, "address-formatting", "conf", "county_codes.yaml")), aliases: true, symbolize_names: true)
  CountryToLanguage = begin
                        c2l = YAML.safe_load(IO.read(File.join(GEM_ROOT, "address-formatting", "conf", "country2lang.yaml")), aliases: true, symbolize_names: true)
                        c2l.transform_values! do |v|
                          v.split(",").map(&:to_sym)
                        end
                        c2l.freeze
                      end
  Abbreviations = begin
                    abbr = {}
                    Dir.each_child(File.join(GEM_ROOT, "address-formatting", "conf", "abbreviations")) do |file|
                      country_code, = file.split(".", 2)
                      abbr[country_code.to_sym] = YAML.safe_load(IO.read(File.join(GEM_ROOT, "address-formatting", "conf", "abbreviations", file)), aliases: true, symbolize_names: true)
                    end
                    abbr.freeze
                  end

  class Template < Mustache
    def first
      lambda do |template|
        render(template.strip).split("||").map(&:strip).reject(&:empty?).first
      end
    end
  end

  def self.compose(components)
    new(components).compose
  end

  attr_accessor :components

  def initialize(components)
    self.components = components.dup
    @should_abbreviate = self.components.delete(:should_abbreviate) || false

    normalize_components
  end

  def compose
    if components[:country_code]
      result = Template.render(template, components).squeeze("\n").lstrip.gsub(/\s*\n\s*/, "\n")
      result = clean(result)
      result = post_format_replace(result)
    else
      result = components.values.join(" ")
    end

    clean(result)
  end

  private

  attr_reader :should_abbreviate

  def clean(result)
    # Remove duplicated spaces
    result = result.squeeze(" ")

    # Remove duplicated returns and add one at the end
    result = "#{result.split("\n").uniq.join("\n")}\n"

    result.gsub!(/,\s*,/, ",") # multiple commas to one

    # Remove spaces and commas before and after return
    result = result.gsub(/[,|\s]*\n[\s|,]*/, "\n")

    # Remove duplicated consecutive words
    result = result.gsub(/([[:alnum:]]+),\s+\1/, '\1') # remove duplicates

    # Remove trailing non-word characters
    result.sub(/^[,|\s|-]*/, "")
  end

  def template
    @template ||= if (components.keys & %i[road postcode]).empty?
                    formatting_rule[:fallback_template] || Templates[:default][:fallback_template]
                  else
                    formatting_rule[:address_template]
                  end
  end

  def formatting_rule
    formatting_rules.last
  end

  def country_code
    @country_code || components[:country_code_sym]
  end

  def formatting_rules
    return @formatting_rules if @formatting_rules

    initial_rule = Templates[country_code]
    if initial_rule
      initial_rule[:use_country] = initial_rule[:use_country].to_sym if initial_rule.key?(:use_country)
      fallback_rule = Templates[initial_rule[:use_country]&.to_sym]
    else
      initial_rule = Templates[:default]
    end

    @formatting_rules = [initial_rule, fallback_rule].compact
  end

  def normalize_components
    components.transform_values!(&:to_s)
    components[:country_code] = components[:country_code].to_s.upcase
    components[:country_code_sym] = components[:country_code].to_sym

    fix_countries
    fix_states
    apply_formatting_rules
    apply_aliases
    normalize_aliases
    abbreviate if should_abbreviate
  end

  def abbreviate
    langs = CountryToLanguage[components[:country_code_sym]]
    return unless langs

    langs.each do |lang|
      next unless Abbreviations[lang]

      Abbreviations[lang].each_key do |abbrev_component|
        next unless components[abbrev_component]

        Abbreviations[lang][abbrev_component].each do |k, v|
          components[abbrev_component].sub!(/(^|\s)#{k}\b/, "\\1#{v}")
        end
      end
    end
  end

  def fix_countries
    if components[:country_code] == "NL" && components[:state]
      if components[:state] == "Curaçao"
        components[:country_code_sym] = :CW
        components[:country_code] = components[:country_code_sym].name
        components[:country] = "Curaçao"
      elsif components[:state].match?(/sint maarten/i)
        components[:country_code_sym] = :SX
        components[:country_code] = components[:country_code_sym].name
        components[:country] = "Sint Maarten"
      elsif components[:state].match?(/aruba/i)
        components[:country_code_sym] = :AW
        components[:country_code] = components[:country_code_sym].name
        components[:country] = "Aruba"
      end
    end
  end

  def fix_states
    if components[:state]&.match?(/^washington,? d\.?c\.?/i)
      components[:state_code] = "DC"
      components[:state] = "District of Columbia"
      components[:city] = "Washington"
    end
  end

  def apply_formatting_rules
    formatting_rules.each do |rule|
      new_component = rule[:add_component]
      use_country = rule[:use_country]
      change_country = rule[:change_country]
      replaces = rule[:replace]

      if use_country
        @use_country = use_country
        components[:country_code] = @use_country.name
        components[:country_code_sym] = components[:country_code].to_sym
      end

      if change_country
        components[:country] = change_country.gsub(/\$state/, components[:state].to_s)
      end

      if replaces
        replace(replaces)
      end

      if new_component
        key, value = new_component.split("=")
        components[key.to_sym] = value
      end
    end
  end

  SMALL_DISTRICT_COUNTRIES = %i[
    BR
    CR
    ES
    NI
    PY
    RO
    TG
    TM
    XK
  ].freeze

  def apply_aliases
    sdc = SMALL_DISTRICT_COUNTRIES.include?(components[:country_code_sym])
    district = components[:district]
    components[:state_district] = district if district && !sdc

    components.keys.each do |key|
      next if !sdc && key == :district
      component = ComponentsList.detect { |member| member[:aliases].to_a.include?(key) }
      components[component[:name]] ||= components[key] if component
    end

    unknown_components = components.keys - AllComponents - [:country_code_sym]

    components[:attention] = unknown_components.map do |unknown|
      components.delete(unknown)
    end.join(" ")
  end

  def get_county_code(county, country_code)
    # TODO what if county is actually the countyCode?
    upcase_county = county.upcase
    pair = CountyCodes[country_code]&.find do |_, value|
      if value.respond_to?(:upcase)
        value.upcase == upcase_county
      else
        value.values.any? { |val| val.upcase == upcase_county }
      end
    end
    pair&.first
  end

  def normalize_aliases
    state_group = [components[:state]&.upcase, components[:state_code]&.upcase].compact
    # TODO: This will upcase names for the state codes every time we pass by here. Probably should be memoized for performance
    state_code, state = StateCodes[@use_country || components[:country_code_sym]]&.select do |k, v|
      if v.is_a? Hash
        ([k&.name&.upcase, v.values.map(&:upcase)] & state_group).any?
      else
        ([k&.name&.upcase, v&.upcase] & state_group).any?
      end
    end.to_a.flatten
    components[:state_code] = state_code unless state_code.nil?
    components[:state] = state unless state.nil?

    if components[:county] && !components[:county_code]
      components[:county_code] = get_county_code(components[:county], components[:country_code_sym])
    end

    if components[:postcode]&.include?(";")
      components.delete(:postcode)
    end

    if components[:postcode]&.include?(",")
      components[:postcode] = components[:postcode].split(",").first
    end

    # If country is a number use the state as country
    if components[:state] && components[:country]&.match?(/^\d+$/)
      components[:country] = components[:state]
    end

    # Clean values with "", nil or []
    self.components = components.reject { |_, v| v.nil? || v.empty? }

    # Remove components with URL
    components.delete_if { |_, v| v.respond_to?(:match?) && v.match?(URI::DEFAULT_PARSER.make_regexp) }
  end

  def replace(replaces)
    replaces.each do |rule|
      from, to = rule
      to = to.tr("$", "\\") # FIX: Solo numeros $1, $2...

      if from.match?(/^.*=/)
        attr, value = from.split("=")
        attr = attr.to_sym
        components[attr] = components[attr]&.gsub(/#{value}/, to)
      else
        components.keys.each do |key|
          next if key == :country_code_sym
          components[key] = components[key]&.gsub(Regexp.new(from), to)
        end
      end
    end
  end

  def post_format_replace(string)
    return string unless formatting_rule[:postformat_replace]

    formatting_rule[:postformat_replace].each do |rule|
      from = rule.first
      to = rule.last.tr("$", "\\")
      string = string.gsub(/#{from}/, to)
    end

    string
  end
end
