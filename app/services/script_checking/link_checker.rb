require 'net/http'
require 'uri'
require 'google_safe_browsing'
require 'js_executor'

class ScriptChecking::LinkChecker
  class << self
    def check(script_version)
      result = scan_for_direct_url_references(script_version)
      return result if result

      redirect_urls = scan_for_redirect_urls(script_version)
      redirect_destinations = redirect_urls.map { |url| resolve(url) }.compact.to_set
      result = checked_for_blocked_urls(redirect_destinations)
      return result if result

      urls_from_execution = (JsExecutor.extract_urls(script_version.code) - redirect_urls).to_set
      result = checked_for_blocked_urls(urls_from_execution)
      return result if result

      redirect_urls_from_execution = urls_from_execution.select {|url| redirect_url_pattern.match?(url) }
      redirect_destinations_from_execution = redirect_urls_from_execution.map { |url| resolve(url) }.compact.to_set
      result = checked_for_blocked_urls(redirect_destinations_from_execution)
      return result if result

      google_blocked_urls = check_with_google_safe_browsing(redirect_urls + redirect_destinations + urls_from_execution + redirect_urls_from_execution + redirect_destinations_from_execution)
      return ScriptChecking::Result.new(ScriptChecking::Result::RESULT_CODE_BLOCK, "Script contains URLs flagged by Google Safe Browsing.", "Google Safe Browsing blocked: #{google_blocked_urls}") if google_blocked_urls.any?

      ScriptChecking::Result.new(ScriptChecking::Result::RESULT_CODE_OK)
    end

    def checked_for_blocked_urls(urls)
      return nil if urls.empty?
      bsu = BlockedScriptUrl.find_by(url: urls.map{ |u| u.sub(/[?#&].*/, '') }.to_a)
      return nil if bsu.nil?
      return ScriptChecking::Result.new(ScriptChecking::Result::RESULT_CODE_BAN, bsu.public_reason, bsu.private_reason, bsu)
    end

    def scan_for_direct_url_references(script_version)
      attributes_to_check(script_version).each do |thing_to_check|
        BlockedScriptUrl.all.each do |bu|
          return ScriptChecking::Result.new(ScriptChecking::Result::RESULT_CODE_BAN, bu.public_reason, bu.private_reason, bu) if thing_to_check.include?(bu.url)
        end
      end
      nil
    end

    def scan_for_redirect_urls(script_version)
      attributes_to_check(script_version).map { |thing_to_check| thing_to_check.scan(redirect_url_pattern) }.compact.flatten.to_set
    end

    def attributes_to_check(script_version)
      ([script_version.code] + script_version.active_localized_attributes.select { |aa| aa.attribute_key == 'additional_info'}.map(&:attribute_value)).compact
    end

    def redirect_url_pattern
      Regexp.new(/https?:\/\//i.to_s + Regexp.union(*RedirectServiceDomain.pluck(:domain)).to_s + /\/[a-z0-9\-]+/i.to_s  )
    end

    def resolve(url, remaining_tries: 5)
      res = Net::HTTP.get_response(URI(url))
      return url if res['location'].nil? || remaining_tries == 0
      resolve(res['location'], remaining_tries: remaining_tries - 1)
    end

    def check_with_google_safe_browsing(urls)
      GoogleSafeBrowsing.check(urls)
    end
  end
end