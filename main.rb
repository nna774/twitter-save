require 'mongo'
require 'twitter'
require 'yaml'
require 'json'
require 'net/https'
require 'open-uri'
require 'pry'

config = YAML.load_file(File.join(__dir__, 'config.yml'))

Mongo::Logger.logger = Logger.new(STDERR)
Mongo::Logger.logger.level = Logger::INFO
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

post2slack(slackcfg, '<@U0323ESK6|nona7>: 行くわよ！ しれーかん！')

END {
  post2slack(slackcfg, '<@U0323ESK6|nona7>: 司令官、どこ……？ もう、声が聞こえないわ……。')
}

class Saver
  def initialize(client, slackcfg, savecfg)
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

    @slackcfg = slackcfg
    @savecfg = savecfg
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
    save(@favs, { :source => obj.source.to_h, :target => obj.target.to_h, :"target_object" => obj.target_object.to_h })
    if obj.target_object.media?
      post2slack(@slackcfg, obj.target_object.uri)
      save_media(obj)
    end
  end
  def save_other_event(obj)
    save(@events, { :name => obj.name, :source => obj.source.to_h, :target => obj.target.to_h, :"target_object" => obj.target_object.to_h })
  end

  def save_media(obj)
    obj.target_object.media.each do |media|
      case media
      when Twitter::Media::Photo
        save_image(obj, media)
      when Twitter::Media::AnimatedGif
        save_gif(obj, media)
      when Twitter::Media::Video
        save_video(obj, media)
      end
    end
  end

  def save_image(obj, media)
    to = File.basename(media.attrs[:media_url_https])
    download("#{media.attrs[:media_url_https]}:orig", dir(obj), to)
  end

  def save_gif(obj, media)
    uri = media.attrs.dig(:video_info, :variants, 0, :url)
    to = File.basename(uri)
    download(uri, dir(obj), to)
  end

  def save_video(obj, media)
    uri = media.attrs.dig(:video_info, :variants).select {|v| v[:content_type] == "video/mp4" }.max {|a, b| a[:bitrate] <=> b[:bitrate] }[:url]
    to = File.basename(uri)
    download(uri, dir(obj), to)
  end

  private

  def dir(obj)
    d = File.join(@savecfg[:savedir], obj.target.screen_name, Time.now.strftime("%Y%m"))
    FileUtils.mkdir_p(d)
    d
  end

  def download(uri, dir, filename)
    open(File.join(dir, filename), 'wb') do |output|
      open(uri) do |data|
        output.write(data.read)
      end
    end
  end
end

saver = Saver.new(client, slackcfg, config)

streaming = Twitter::Streaming::Client.new do |cfg|
  cfg.consumer_key        = config[:"consumer_key"]
  cfg.consumer_secret     = config[:"consumer_secret"]
  cfg.access_token        = config[:"access_token"]
  cfg.access_token_secret = config[:"access_token_secret"]
end

cnt = 3
begin
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
rescue EOFError, Mongo::Error::SocketError
  if (cnt -= 1) > 0
    sleep 1
    post2slack(slackcfg, "<@U0323ESK6|nona7>: 応急修理#{['要員', '女神'].sample}発動！")
    retry
  else
    raise e
  end
end
