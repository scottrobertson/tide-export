#!/usr/bin/env ruby

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rubygems'
require 'commander/import'
require 'rest-client'
require 'json'
require 'csv'
require 'yaml'
require 'qif'
require 'tide/export/version'

program :name, 'tide-export'
program :version, Tide::Export::VERSION
program :description, 'Generate QIF or CSV from Tide.co'

def config_path
  "#{Etc.getpwuid.dir}/.tide-export.json"
end

def perform_request(path)
  raise 'Cannot find config file' unless File.exists?(config_path)

  # @todo handle refresh token
  @_token ||= begin
    file = File.read(config_path)
    params = JSON.parse(file)
    params['access_token']
  end

  url = "https://api.tide.co/tide-backend/rest/api/v1/external#{path}"

  @_requests ||= {}
  @_requests[path] ||= JSON.parse(RestClient.get(url, {:Authorization => "Bearer #{@_token}"}))
end

def account
  @_account ||= begin
    accounts = perform_request("/companies/#{company['companyId']}/accounts")
    if accounts.size > 1
      account_ids = accounts.collect{|c| c['accountId'] }
      accounts.each {|c| puts "#{c['name']}: #{c['accountId']}" }
      account_id = ask("Pick a Account ID from above: ", Integer) { |q| q.in = account_ids }
    else
      account_id = accounts.first['accountId']
    end

    accounts.select{|c| c['accountId'] == account_id}.first
  end
end

def company
  @_company ||= begin
    companies = perform_request('/companies')
    if companies.size > 1
      company_ids = companies.collect{|c| c['companyId'] }
      companies.each {|c| puts "#{c['name']}: #{c['companyId']}" }
      company_id = ask("Pick a Company ID from above: ", Integer) { |q| q.in = company_ids }
      puts
    else
      company_id = companies.first['companyId']
    end

    companies.select{|c| c['companyId'] == company_id}.first
  end
end

def transactions
  perform_request("/accounts/#{account['accountId']}/transactions")
end

command :login do |c|
  c.syntax = 'tide-export login [options]'
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

command :qif do |c|
  c.syntax = 'tide-export qif [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.action do |args, options|
    options.default directory: "#{File.dirname(__FILE__)}/tmp"
    path = "#{options.directory}/tide-#{account['accountId']}-#{Time.now.to_i}.qif"
    Qif::Writer.open(path, type = 'Bank', format = 'dd/mm/yyyy') do |qif|
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

command :csv do |c|
  c.syntax = 'tide-export csv [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.action do |args, options|
    options.default directory: "#{File.dirname(__FILE__)}/tmp"
    path = "#{options.directory}/tide-#{account['accountId']}-#{Time.now.to_i}.csv"

    CSV.open(path, "wb") do |csv|
      csv << [:date, :description, :amount, :balance]
      transactions.reverse.each_with_index do |transaction, index|
        balance = index == 0 ? account['availableBalance'] : nil
        csv << [
          DateTime.parse(transaction['isoTransactionDateTime']).strftime("%d/%m/%y"),
          transaction['description'],
          transaction['amount'],
          balance
        ]
      end
    end

    puts "Wrote to #{path}"
  end
end
