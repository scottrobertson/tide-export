#!/usr/bin/env ruby

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rubygems'
require 'commander/import'
require 'rest-client'
require 'json'
require 'qif'
require 'tide/to/qif/version'

program :name, 'tide-to-qif'
program :version, Tide::To::Qif::VERSION
program :description, 'Generate QIF from Tide.co'

def config_path
  "#{Etc.getpwuid.dir}/.tide-to-qif.json"
end

def perform_request(path)

  @_token ||= begin
    file = File.read(config_path)
    params = JSON.parse(file)
    params['access_token']
  end

  url = "https://api.tide.co/tide-backend/rest/api/v1/external#{path}"

  JSON.parse(RestClient.get(url, {:Authorization => "Bearer #{@_token}"}))
end

command :login do |c|
  c.syntax = 'tide-to-qif login [options]'
  c.summary = ''
  c.description = ''
  c.option '--client_id STRING', String, 'Your tide.co client id'
  c.action do |args, options|

    if options.client_id
      redirect_url = 'https://scottrobertson.github.io/dump-query-params/index.html'
      system("open", "https://api.tide.co/tide-backend/oauth/index.html?redirect_url=#{redirect_url}&client_id=#{options.client_id}")

      code = ask('Enter the code from the page you were redirected to: ')
      response = RestClient.get("https://api.tide.co/tide-backend/rest/api/v1/oauth2/tokens?code=#{code}")
      config = JSON.parse(response)

      File.open(config_path, "w") do |f|
        f.write(config.to_json)
      end

      puts "Config written to #{config_path}"
    else
      puts 'client_id must be provided'
    end
  end
end

command :generate do |c|
  c.syntax = 'tide-to-qif generate [options]'
  c.summary = ''
  c.description = ''
  c.action do |args, options|
    companies = perform_request('/companies')
    if companies.size > 1
      company_ids = companies.collect{|c| c['companyId'] }
      companies.each {|c| puts "#{c['name']}: #{c['companyId']}" }
      company_id = ask("Pick a Company ID from above: ", Integer) { |q| q.in = company_ids }
      puts
    else
      company_id = companies.first['companyId']
    end

    accounts = perform_request("/companies/#{company_id}/accounts")
    if accounts.size > 1
      account_ids = accounts.collect{|c| c['accountId'] }
      accounts.each {|c| puts "#{c['name']}: #{c['accountId']}" }
      account_id = ask("Pick a Account ID from above: ", Integer) { |q| q.in = account_ids }
    else
      account_id = accounts.first['accountId']
    end

    transactions = perform_request("/accounts/#{account_id}/transactions")

    path = "#{File.dirname(__FILE__)}/tide-#{Time.now.to_i}.qif"
    file = File.open(path, "w")
    Qif::Writer.open(file.path, type = 'Bank', format = 'dd/mm/yyyy') do |qif|
      transactions.each do |transaction|
        qif << Qif::Transaction.new(
          date: DateTime.parse(transaction['isoTransactionDateTime']).to_date,
          amount: transaction['amount'],
          memo: transaction['txnRef'],
          payee: transaction['description']
        )
      end
    end

    puts "Wrote to #{path}"

  end
end
