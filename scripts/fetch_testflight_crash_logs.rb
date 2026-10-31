#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads TestFlight crash logs for Decaid from the App Store Connect API.
# fastlane has no action for this: pilot only lists builds and testers, and
# spaceship has no crash-submission model, so this talks to the API directly.
#
#   ruby scripts/fetch_testflight_crash_logs.rb --api-key-path /tmp/asc_key.json
#
# The key JSON is the same one deliver uses (see fastlane/README.md). Output
# holds tester and device data, so it defaults to a directory outside the repo.

require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

HOST = "https://api.appstoreconnect.apple.com"

class NotFound < StandardError; end

options = {
  api_key_path: "/tmp/asc_key.json",
  bundle_id: "net.tadel.reaprime",
  out: "/tmp/testflight-crash-logs",
  list_only: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
  opts.on("--api-key-path PATH", "App Store Connect API key JSON") { |value| options[:api_key_path] = value }
  opts.on("--bundle-id ID", "Bundle identifier") { |value| options[:bundle_id] = value }
  opts.on("--out DIR", "Directory for crash logs") { |value| options[:out] = value }
  opts.on("--list-only", "List submissions without downloading") { options[:list_only] = true }
end.parse!

def b64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

def api_token(config)
  key = OpenSSL::PKey.read(config.fetch("key"))
  now = Time.now.to_i
  header = b64url(JSON.generate({alg: "ES256", kid: config.fetch("key_id"), typ: "JWT"}))
  claims = b64url(JSON.generate({iss: config.fetch("issuer_id"), iat: now, exp: now + 900, aud: "appstoreconnect-v1"}))
  signing_input = "#{header}.#{claims}"
  der = key.sign("SHA256", signing_input)
  raw = OpenSSL::ASN1.decode(der).value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
  "#{signing_input}.#{b64url(raw)}"
end

def get(token, path)
  uri = URI(path.start_with?("http") ? path : HOST + path)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  body = JSON.parse(response.body)
  return body if response.code == "200"

  detail = body.dig("errors", 0, "detail") || response.body[0, 200]
  raise NotFound, detail if response.code == "404"

  abort "GET #{uri.path} failed: #{response.code} #{detail}"
end

def each_page(token, path)
  body = get(token, path)
  loop do
    body.fetch("data", []).each { |item| yield item }
    next_url = body.dig("links", "next")
    break unless next_url

    body = get(token, next_url)
  end
end

def log_filename(submission)
  created = submission.dig("attributes", "createdDate").to_s.tr(":", "-")
  "#{created}__#{submission.fetch("id")}.crash"
end

def log_text(token, submission_id)
  log = get(token, "/v1/betaFeedbackCrashSubmissions/#{submission_id}/crashLog")
  log.dig("data", "attributes", "logText") || raise(NotFound, "no logText in the response")
end

config = JSON.parse(File.read(options[:api_key_path]))
token = api_token(config)

bundle_id = URI.encode_www_form_component(options[:bundle_id])
apps = get(token, "/v1/apps?filter[bundleId]=#{bundle_id}&fields[apps]=name,bundleId")
app = apps.fetch("data", []).first || abort("No app found for #{options[:bundle_id]}")
puts "#{app.dig("attributes", "name")} (#{options[:bundle_id]}) app=#{app.fetch("id")}"

submissions = []
each_page(token, "/v1/apps/#{app.fetch("id")}/betaFeedbackCrashSubmissions?limit=200") { |item| submissions << item }
puts "#{submissions.size} crash submissions"

if options[:list_only]
  submissions.each do |submission|
    attributes = submission.fetch("attributes")
    puts [attributes["createdDate"], attributes["deviceModel"], attributes["osVersion"], attributes["comment"].to_s[0, 60], submission.fetch("id")].join(" | ")
  end
  exit 0
end

written = 0
skipped = 0
missing = 0
submissions.each do |submission|
  id = submission.fetch("id")
  path = File.join(options[:out], id, log_filename(submission))
  if File.exist?(path)
    skipped += 1
    next
  end

  begin
    text = log_text(token, id)
  rescue NotFound => error
    warn "Skipped #{id}: #{error.message}"
    missing += 1
    next
  end

  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, text)
  written += 1
end

puts "Wrote #{written} crash logs to #{options[:out]} (#{skipped} already present, #{missing} unavailable)"
