require "bundler/setup"
require "sinatra"
require 'sinatra/browserid'
require "sinatra/flash"
require "sinatra/reloader" if development?
require "data_mapper"
require "digest/md5"
require "httparty"
require "json"

Sinatra.register Sinatra::BrowserID
Sinatra.register Sinatra::Flash
set :browserid_login_button, :blue
set :sessions, true

DBURL = ENV["DATABASE_URL"] || File.join("sqlite3://#{Dir.pwd}", "captn.db")
DataMapper::Logger.new($stdout, :debug) if development?
DataMapper.setup(:default, DBURL)

class Captainship
  include DataMapper::Resource
  property :id,         Serial
  property :url,        String
  property :name,       String
  property :avatar,     String
  property :email,      String,   :required => true
  property :started_at, DateTime, :required => true
  property :created_at, DateTime

  def to_hash
    Digest::MD5.hexdigest(@email)
  end
end

DataMapper.finalize

helpers do
  def get_timeline_string(date)
    today = Date.today
    return "current" if date.cweek == today.cweek
    date > today ? "future" : "past"
  end

  def pretty_date(date)
    date.strftime "%A %e %B %G"
  end

  def md5_email(email)
    Digest::MD5.hexdigest(email)
  end

  def lookup_user(email)
    @cache = {} unless @cache
    hash = md5_email(email)
    user = @cache[hash]

    unless user
      url = "http://who.theskiff.org/profiles/#{hash}.json"
      begin
        request = HTTParty.get(url, :timeout => 5)
        user = JSON.parse(request.body)
        @cache[hash] = user
      rescue
        user = {}
      end
    end
    user
  end

  def lookup_captain(captain)
    user = lookup_user(captain.email)
    captain.name   = user["real_name"]
    captain.avatar = user["profile_image"]
    captain.url    = user["html"]
    captain
  end

  def valid_cweek?(cweek)
    cweek.to_s =~ /^\d{1,2}$/ and (1..52) === cweek.to_i
  end

  def date_for_cweek(cweek, year=nil)
    year = Date.today.year if year.nil?
    Date.commercial(year, cweek, 1, Date::ENGLAND)
  end

  def render_weeks_for_range(start_cweek, end_cweek, year=nil)
    weeks = []

    first = date_for_cweek(start_cweek, year)
    last  = date_for_cweek(end_cweek, year)

    captains = Captainship.all(
      :started_at.lt  => last,
      :started_at.gte => first,
      :order          => :started_at
    )

    captains_hash = {}
    captains.each { |c| captains_hash[c.started_at.to_date.iso8601] = c }

    first.step(last, 7) do |date|
      captain = captains_hash[date.iso8601]

      week = {:date => date}
      week[:captain] = lookup_captain(captain) if captain
      weeks << week
    end

    if accept_json?
      render_weeks_as_json(weeks)
    else 
      render_weeks_as_html(weeks)
    end
  end

  def render_weeks_as_html(weeks)
    user = lookup_user(authorized_email) if authorized?
    erb :index, :locals => {
      :user  => user,
      :weeks => weeks,
      :render_login_button => render_login_button
    }
  end

  def render_weeks_as_json(weeks)
    list = []
    weeks.each do |week|
      list << {
        :hash => week[:captain] ? md5_email(week[:captain].email) : nil,
        :week => week[:date].iso8601
      }
    end
    render_json_list list
  end

  def render_json(response)
    content_type :json
    body = response.to_json
    if params[:callback]
      content_type :js
      body = "#{params[:callback]}(#{body})"
    end
    body
  end

  def render_json_list(items=[])
    render_json({
      :meta => {
        :total => items.length
      },
      :items => items
    })
  end

  def accept_json?
    # This seems incredibly hacky but #accept? returns a string?
    is_jsonp = !!(params[:callback] and request.accept?("text/javascript"))
    is_json = request.preferred_type(%w[text/html application/json]) == "application/json"
    is_json or is_jsonp
  end
end

get "/" do
  today = Date.today
  render_weeks_for_range(today.cweek - 1, today.cweek + 11)
end

get "/logout/" do
  logout!
  redirect back
end

get "/captain.json" do
  start = date_for_cweek(Date.today.cweek)
  captain = Captainship.first(:started_at => start)

  response = {:captain => nil}
  if captain
    response[:captain] = {
      :week => start.iso8601,
      :hash => md5_email(captain.email)
    }
  end

  render_json response
end

post "/captainships/" do
  authorize!

  week  = params[:week].to_i
  year  = params[:year]
  year  = year.to_i unless year.nil?
  notice = {:type => :error}

  if valid_cweek? week
    started_at = date_for_cweek(week, year)

    exists = Captainship.first(:started_at => started_at)
    if exists
      notice[:msg] = "There is already a Captain for this week"
    else
      Captainship.create(
        :email => authorized_email,
        :started_at => date_for_cweek(week, year)
      )
      notice = {
        :type => :success,
        :msg  => "Thanks for volunteering!"
      }
    end
  end

  unless notice[:msg]
    notice[:msg] = "There was an error when trying to save this date"
  end

  flash[:notice] = notice
  redirect back
end

delete "/captainships/" do
  authorize!

  week  = params[:week].to_i
  year  = params[:year]
  year  = year.to_i unless year.nil?

  if valid_cweek? week
    started_at = date_for_cweek(week, year)
    captn = Captainship.all(:started_at => started_at, :email => authorized_email)
    if captn and captn.destroy()
      flash[:notice] = {
        :type => :success,
        :msg  => "Cancelled your captainship!"
      }
    end
  end
  redirect back
end

get "/:year/from/:start/to/:end/" do
  start = params[:start]
  last  = params[:end]

  if valid_cweek? start and valid_cweek? last
    render_weeks_for_range(start.to_i, last.to_i, params[:year].to_i)
  else
    pass
  end
end

