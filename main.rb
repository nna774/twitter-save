require 'mongo'
require 'twitter'
require 'yaml'
require 'json'
require 'net/https'
require 'pry'

config = YAML.load_file(File.join(__dir__, 'config.yml'))

Mongo::Logger.logger = Logger.new(STDERR)
client = Mongo::Client.new([ config[:mongo] ], {:database => config[:db]})

slackcfg = {
  icon_emoji: config[:emoji],
  username: config[:name],
  channel: config[:channel],
  "wh-uri": config[:"slack_wh_uri"]
}

def post2slack(cfg, str)
  payload = {
    "text" => str,
    "icon_emoji" => cfg[:"icon_emoji"],
    "username" => cfg[:username],
    "channel" => cfg[:channel],
  }
  uri = URI.parse(cfg[:"wh-uri"])
  https = Net::HTTP.new(uri.host, uri.port)
  https.use_ssl = true
  req = Net::HTTP::Post.new(uri.request_uri)
  req.body = "payload=" + payload.to_json
  https.request(req)
end

class Saver
  def initialize(client)
    @deletes = client[:deletes]
    @deletes.create if @deletes.nil?
    @dms = client[:dms]
    @dms.create if @dms.nil?
    @tweets = client[:tweets]
    @tweets.create if @tweets.nil?
    @favs = client[:favs]
    @favs.create if @favs.nil?
    @events = client[:events]
    @events.create if @events.nil?
  end
  
  def save(coll, obj)
    coll.insert_one(obj.to_h)
  end
  
  def save_delete(obj)
    save(@deletes, obj)
  end
  def save_dm(obj)
    save(@dms, obj)
  end
  def save_tweet(obj)
    save(@tweets, obj)
  end
  def save_fav(obj)
    binding.pry
    save(@favs, { :source => obj.source.to_h, :target => obj.target.to_h, :"target_object" => obj.target_object.to_h })
    if obj.target_object.media?
      post2slack(slackcfg, obj.target_object.uri)
    end
  end
  def save_other_event(obj)
    save(@events, { :name => obj.name, :source => obj.source.to_h, :target => obj.target.to_h, :"target_object" => obj.target_object.to_h })
  end
end

saver = Saver.new(client)

streaming = Twitter::Streaming::Client.new do |cfg|
  cfg.consumer_key        = config[:"consumer_key"]
  cfg.consumer_secret     = config[:"consumer_secret"]
  cfg.access_token        = config[:"access_token"]
  cfg.access_token_secret = config[:"access_token_secret"]
end

streaming.user do |obj|
  case obj
  when Twitter::Streaming::DeletedTweet
    saver.save_delete(obj)
  when Twitter::DirectMessage
    saver.save_dm(obj)
  when Twitter::Tweet
    saver.save_tweet(obj)
  when Twitter::Streaming::Event
    if obj.name == :favorite
      saver.save_fav(obj)
    else
      saver.save_other_event(obj)
    end
  end
end
