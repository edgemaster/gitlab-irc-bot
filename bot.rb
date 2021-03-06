#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'

require 'sinatra/base'
require 'cinch'
require 'json'
require 'yaml'
require 'digest/sha2'

$config = YAML.load_file('config.yml')
channels = ($config['travis'].values + $config['gitlab'].values).map { |c| c['channel'] }

class App < Sinatra::Application
  class << self
    attr_accessor :ircbot
  end
  @@ircbot = nil

  configure do
    set :environment, :production
    set :bind, '127.0.0.1'
    set :port, $config['sinatra']['port']
    disable :traps
  end

  post '/gitlab-ci' do
    request.body.rewind
    body = request.body.read
    data = JSON.parse body
    logger.info data

    project_name = data['project_name']
    if $config['gitlab'].include? project_name
      build_status = format_status data['build_status']

      sha = data['sha'][0..7]
      branch = data['ref']
      user = data['push_data']['user_name']
      message = data['push_data']['commits'][0]['message'].lines.first

      commit_count = data['push_data']['total_commits_count']
      commit_count_str = (commit_count > 1) ? "(#{commit_count} commits) " : ""

      ch = $config['gitlab'][project_name]['channel']

      App.ircbot.Channel(ch).send("#{project_name} (#{branch}) build #{build_status} - #{user} #{commit_count_str}#{sha}: #{message}")
    else
      logger.info "Discarding unknown project: #{project_name}"
    end
    200
  end

  post '/travis-ci' do
    data = JSON.parse params[:payload]

    if travis_valid_request?
      owner = data['repository']['owner_name']
      project_name = data['repository']['name']
      build_status = format_travis_status data['status'], data['status_message']

      sha = data['commit'][0..7]
      branch = data['branch']
      user = data['author_name']
      message = data['message'].lines.first

      ch = $config['travis'][repo_slug]['channel']

      App.ircbot.Channel(ch).send("#{owner} / #{project_name} (#{branch}) build #{build_status} - #{user} #{sha}: #{message}")
    end
    200
  end

  post '/buildbot' do
    array = JSON.parse params[:packets]
    array.each do |status|
      if $config['buildbot'].include? status['project']
        ch = $config['buildbot'][status['project']]['channel']

        if status['event'] == 'buildStarted'
        elsif status['event'] == 'buildETAUpdate'
        elsif status['event'] == 'buildFinished'
          build = status['payload']['build']
          builderName = build['builderName']
          build_status = format_status build['text'].join(" ")
          number = build['number']
          
          uri_match = /^(.*)\/steps\/.*/.match(build['logs'][0][1])
          uri = uri_match && uri_match[1] || ""

          App.ircbot.Channel(ch).send("#{builderName}##{number} #{build_status}: #{uri}")
        elsif status['event'].start_with?('builder', 'step', 'log', 'slave', 'change', 'change', 'request')
	elsif status['event'] == 'start'
        elsif status['event'] == 'shutdown'
        elsif status['event'] == 'buildsetSubmitted'
        elsif status['event'] == 'buildedRemoved'
        else
          logger.info "Unknown buildbot event #{status[event]}"
          logger.info status['payload']
        end
      end
    end
    200
  end

  not_found do
    'not found'
  end

  error do
    'error'
  end

  def format_travis_status(status, status_message)
    c = :red
    if status == 0
      c = :green
    elsif status_message == "Pending"
      c = :yellow
    end

    Cinch::Formatting.format(c, status_message)
  end

  def format_status(str)
    if /failed/ =~ str
      colour = :red
    elsif /success/ =~ str
      colour = :green
    else
      colour = :yellow
    end

    Cinch::Formatting.format(colour, str)
  end

  def travis_valid_request?
    slug = repo_slug
    if $config['travis'].include? slug
      token = $config['travis'][slug]['token']
      digest = Digest::SHA2.new.update("#{slug}#{token}")
      return digest.to_s == authorization
    end
    false
  end

  def authorization
    env['HTTP_AUTHORIZATION']
  end

  def repo_slug
    env['HTTP_TRAVIS_REPO_SLUG']
  end
end

bot = Cinch::Bot.new do
  configure do |c|
    c.load! $config['irc']
    c.channels = channels
  end
end
bot.loggers.first.level = :info

App.ircbot = bot

t_bot = Thread.new {
  bot.start
}
t_app = Thread.new {
  App.start!
}

trap_block = proc {
  App.quit!
  Thread.new {
    bot.quit
  }
}
Signal.trap("SIGINT", &trap_block)
Signal.trap("SIGTERM", &trap_block)

t_bot.join
