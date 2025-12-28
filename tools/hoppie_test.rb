#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "net-http"
end

require "net/http"
require "uri"

if ARGV.length < 2
  puts "Usage: #{$0} <hoppie_logon> <callsign> [message]"
  puts "Example: #{$0} mylogoncode EJU15GB 'Test message from Ruby'"
  exit 1
end

logon = ARGV[0]
callsign = ARGV[1]
message = ARGV[2] || "Test message from JTB"

uri = URI("https://www.hoppie.nl/acars/system/connect.html")

form_data = {
  "logon" => logon,
  "from" => "TEST",
  "to" => callsign,
  "type" => "telex",
  "packet" => message
}

response = Net::HTTP.post_form(uri, form_data)

puts "HTTP status code: #{response.code}"
puts "Response body: #{response.body.inspect}"
